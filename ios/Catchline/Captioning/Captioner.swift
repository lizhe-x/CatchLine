import Foundation
import Observation
import UIKit

struct CaptionSettings {
    var sourceLang: String
    var targetLang: String
    /// Names, companies, jargon — comma or newline separated.
    var terms: String
    var background: String

    func sonioxConfig() -> SonioxConfig {
        var seen = Set<String>()
        let termList = terms
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let text = background.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = termList.isEmpty && text.isEmpty
            ? nil
            : SonioxConfig.Context(terms: termList.isEmpty ? nil : termList, text: text.isEmpty ? nil : text)
        return SonioxConfig(
            model: AppConfig.sonioxModel,
            languageHints: [sourceLang],
            translation: .init(targetLanguage: targetLang),
            context: context
        )
    }
}

struct KeyFetchError: LocalizedError {
    let status: Int
    var errorDescription: String? { "获取临时 key 失败（\(status)）" }
}

/// Keeps one live captioning stream running until `stop()`.
///
/// The microphone runs continuously; Soniox streams come and go underneath.
/// Audio captured while (re)connecting is buffered and sent first, and the
/// transcript lives here rather than in a stream, so reconnects (network
/// drops, the per-stream duration cap, expired keys) never lose captions.
@Observable
final class Captioner {
    enum Status {
        case idle, starting, live, reconnecting, interrupted, stopping, needsSignIn, error

        var label: String {
            switch self {
            case .idle: "未开始"
            case .starting: "连接中…"
            case .live: "实时"
            case .reconnecting: "重连中…"
            case .interrupted: "已暂停"
            case .stopping: "收尾中…"
            case .needsSignIn: "需要登录"
            case .error: "出错了"
            }
        }

        var isActive: Bool { [.starting, .live, .reconnecting, .interrupted].contains(self) }
    }

    private(set) var status: Status = .idle
    private(set) var message: String?
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    let transcript = Transcript()

    private let auth: AuthService
    private var config: SonioxConfig?
    private var source: AudioSource?
    private var audioContinuation: AsyncStream<AudioCaptureEvent>.Continuation?
    private var pumpTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    /// The stream currently accepting audio; nil while (re)connecting.
    private var stream: SonioxStream?
    private var pending: [Data] = []
    private var wantRunning = false

    /// ~20 s of 16 kHz Int16 audio kept while disconnected.
    private static let maxPendingBytes = 16_000 * 2 * 20

    init(auth: AuthService) {
        self.auth = auth
    }

    func start(with settings: CaptionSettings) async {
        guard !wantRunning else { return }
        guard await MicrophonePermission.request() else {
            status = .error
            message = "没有麦克风权限。请到 设置 → Catchline 打开麦克风。"
            return
        }

        transcript.reset()
        pending = []
        config = settings.sonioxConfig()
        startedAt = .now
        endedAt = nil
        message = nil
        wantRunning = true

        let (events, continuation) = AsyncStream.makeStream(of: AudioCaptureEvent.self)
        audioContinuation = continuation
        let source = Self.makeSource()
        do {
            try source.start { continuation.yield($0) }
        } catch {
            wantRunning = false
            status = .error
            message = "无法启动麦克风：\(error.localizedDescription)"
            return
        }
        self.source = source
        UIApplication.shared.isIdleTimerDisabled = true

        // Only the pump sends audio, so chunks always go out in order.
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() async {
        guard wantRunning else { return }
        wantRunning = false
        status = .stopping

        source?.stop()
        source = nil
        audioContinuation?.finish()
        audioContinuation = nil
        await pumpTask?.value // flush captured audio into the live stream

        if let stream {
            // Ask Soniox to finalize the tail; the run loop exits on `finished`.
            await stream.finish()
            let run = runTask
            let finishedInTime = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await run?.value; return true }
                group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !finishedInTime { stream.close() }
        }
        runTask?.cancel()
        await runTask?.value

        transcript.commitLive()
        endedAt = .now
        UIApplication.shared.isIdleTimerDisabled = false
        if status == .stopping { status = .idle }
    }

    // MARK: - Run loop

    private func runLoop() async {
        var failures = 0
        while wantRunning && !Task.isCancelled {
            if status != .interrupted { status = failures == 0 ? .starting : .reconnecting }
            var openedAt: Date?
            do {
                guard var config else { return }
                config.apiKey = try await fetchTemporaryKey()
                let stream = SonioxStream()
                try await stream.open(config: config)

                transcript.sessionRestarted()
                self.stream = stream
                openedAt = .now
                if status != .interrupted { status = .live }
                message = nil

                defer {
                    self.stream = nil
                    stream.close()
                }
                while true {
                    let response = try await stream.receive()
                    if let tokens = response.tokens, !tokens.isEmpty { transcript.apply(tokens) }
                    if response.finished == true { break }
                }
                // Server ended the stream: our stop(), or the duration cap.
                failures = 0
            } catch AuthError.notSignedIn {
                fail(.needsSignIn, "登录已过期，请重新登录")
                return
            } catch let error as SonioxServerError where error.code == 400 || error.code == 402 {
                // Bad config or Soniox balance/budget exhausted: retrying won't help.
                fail(.error, "Soniox：\(error.message)")
                return
            } catch {
                guard wantRunning, !Task.isCancelled else { break }
                // A long healthy stream resets the backoff.
                if let openedAt, Date.now.timeIntervalSince(openedAt) > 30 { failures = 0 }
                failures += 1
                if status != .interrupted { status = .reconnecting }
                print("[captioner] stream failed (\(failures)):", error)
                let delay = min(15.0, 0.5 * pow(2, Double(failures - 1)))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func handle(_ event: AudioCaptureEvent) async {
        switch event {
        case let .chunk(data):
            guard let stream else {
                pending.append(data)
                var total = pending.reduce(0) { $0 + $1.count }
                while total > Self.maxPendingBytes, !pending.isEmpty {
                    total -= pending.removeFirst().count
                }
                return
            }
            do {
                if !pending.isEmpty {
                    let backlog = pending
                    pending = []
                    for chunk in backlog { try await stream.send(audio: chunk) }
                }
                try await stream.send(audio: data)
            } catch {
                // The receive side sees the same failure and reconnects.
                pending.append(data)
            }
        case .interrupted:
            status = .interrupted
            message = "麦克风被系统占用（例如来电），结束后会自动继续"
        case .resumed:
            if status == .interrupted {
                status = stream == nil ? .reconnecting : .live
                message = nil
            }
        case let .failed(reason):
            message = "麦克风出错：\(reason)"
        }
    }

    private func fail(_ status: Status, _ message: String) {
        wantRunning = false
        source?.stop()
        source = nil
        audioContinuation?.finish()
        audioContinuation = nil
        UIApplication.shared.isIdleTimerDisabled = false
        transcript.commitLive()
        endedAt = .now
        self.status = status
        self.message = message
    }

    private func fetchTemporaryKey() async throws -> String {
        var request = URLRequest(url: AppConfig.keyEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        if !AppConfig.useLocalMock {
            request.setValue("Bearer \(try await auth.validAccessToken())", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw AuthError.notSignedIn }
        guard code == 200 else { throw KeyFetchError(status: code) }
        struct Body: Decodable { let apiKey: String }
        return try JSONDecoder().decode(Body.self, from: data).apiKey
    }

    private static func makeSource() -> AudioSource {
        #if DEBUG
        if let path = AppConfig.audioFilePath { return FileSource(path: path) }
        #endif
        return MicrophoneSource()
    }
}

import Foundation
import Observation
import UIKit

struct CaptionSettings {
    /// A Soniox code, or `Language.auto`.
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
            languageHints: sourceLang == Language.auto ? Language.autoHints(target: targetLang) : [sourceLang],
            translation: sourceLang == targetLang ? nil : .init(targetLanguage: targetLang),
            context: context
        )
    }
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
        case idle, starting, live, reconnecting, interrupted, stopping, quotaExhausted, error

        var label: String {
            switch self {
            case .idle: String(localized: "Ready")
            case .starting: String(localized: "Connecting…")
            case .live: String(localized: "Live")
            case .reconnecting: String(localized: "Reconnecting…")
            case .interrupted: String(localized: "Paused")
            case .stopping: String(localized: "Finishing…")
            case .quotaExhausted: String(localized: "Out of time")
            case .error: String(localized: "Error")
            }
        }

        var isActive: Bool { [.starting, .live, .reconnecting, .interrupted].contains(self) }
    }

    private(set) var status: Status = .idle
    private(set) var message: String?
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    let transcript = Transcript()

    /// Latest allowance from the server; drives the "remaining" display.
    private(set) var plan: PlanStatus?
    /// When the current lease started, for the local countdown between server updates.
    private(set) var leaseStartedAt: Date?

    private let api: APIClient
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

    init(api: APIClient) {
        self.api = api
    }

    /// Seconds left right now: server figure minus time streamed in this lease.
    func remainingSeconds(at date: Date = .now) -> Int? {
        guard let plan else { return nil }
        let streamed = leaseStartedAt.map { Int(date.timeIntervalSince($0)) } ?? 0
        return max(0, plan.remainingSeconds - streamed)
    }

    func refreshPlan() async {
        guard !wantRunning else { return }
        do { plan = try await api.status() } catch { print("[captioner] status failed:", error) }
    }

    func start(with settings: CaptionSettings) async {
        guard !wantRunning else { return }
        guard await MicrophonePermission.request() else {
            status = .error
            message = String(localized: "Microphone access is off. Turn it on in Settings → CatchLine.")
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
            message = String(localized: "Couldn’t start the microphone: \(error.localizedDescription)")
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
        // Settle the lease by server clock and refresh what's left.
        if let latest = try? await api.endSession() { plan = latest }
    }

    // MARK: - Run loop

    private func runLoop() async {
        var failures = 0
        while wantRunning && !Task.isCancelled {
            if status != .interrupted { status = failures == 0 ? .starting : .reconnecting }
            var openedAt: Date?
            do {
                guard var config else { return }
                let lease = try await api.startSession()
                plan = lease.plan
                config.apiKey = lease.apiKey
                let stream = SonioxStream()
                try await stream.open(config: config)

                transcript.sessionRestarted()
                self.stream = stream
                openedAt = .now
                leaseStartedAt = openedAt
                if status != .interrupted { status = .live }
                message = nil

                // Rotate shortly before Soniox's hard cut at the lease limit:
                // detach the stream (new audio queues in `pending`), then ask
                // it to finalize, so the words in flight aren't lost.
                let rotateAfter = max(Double(lease.leaseSeconds) - 3, Double(lease.leaseSeconds) * 0.8)
                let rotation = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(rotateAfter))
                    guard let self, !Task.isCancelled, self.stream === stream else { return }
                    self.stream = nil
                    await stream.finish()
                }
                defer {
                    rotation.cancel()
                    if self.stream === stream { self.stream = nil }
                    stream.close()
                    leaseStartedAt = nil
                }
                while true {
                    let response = try await stream.receive()
                    if let tokens = response.tokens, !tokens.isEmpty { transcript.apply(tokens) }
                    if response.finished == true { break }
                }
                // Server ended the stream: our stop(), or the lease ran out.
                // Loop around for the next lease (or a quota error).
                failures = 0
            } catch let APIError.quotaExhausted(latest) {
                if let latest { plan = latest }
                fail(.quotaExhausted, plan?.kind == .free ? String(localized: "You’ve used today’s free minutes") : String(localized: "You’ve used this period’s hours"))
                return
            } catch APIError.attestationUnsupported {
                fail(.error, String(localized: "This device doesn’t support App Attest, which CatchLine requires"))
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
            message = String(localized: "The microphone is in use by the system (e.g. a call). Captions resume automatically afterwards.")
        case .resumed:
            if status == .interrupted {
                status = stream == nil ? .reconnecting : .live
                message = nil
            }
        case let .failed(reason):
            message = String(localized: "Microphone error: \(reason)")
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
        Task { if let latest = try? await api.endSession() { plan = latest } }
    }

    private static func makeSource() -> AudioSource {
        #if DEBUG
        if let path = AppConfig.audioFilePath { return FileSource(path: path) }
        #endif
        return MicrophoneSource()
    }
}

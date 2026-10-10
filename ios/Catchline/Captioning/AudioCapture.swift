@preconcurrency import AVFoundation
import Foundation

/// Audio we send to Soniox: raw 16 kHz mono little-endian Int16 PCM.
/// (Smallest format Soniox accepts at full quality; no container to restart.)
nonisolated enum StreamAudioFormat {
    static let sampleRate = 16_000.0
    static let sonioxName = "pcm_s16le"
    static let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
}

nonisolated enum AudioCaptureEvent: Sendable {
    case chunk(Data)
    /// iOS took the mic away (phone call, Siri, another app).
    case interrupted
    /// Capture resumed after an interruption.
    case resumed
    case failed(String)
}

nonisolated protocol AudioSource: AnyObject, Sendable {
    /// Starts capture; events arrive on an arbitrary thread, in order.
    func start(onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void) throws
    func stop()
}

enum MicrophonePermission {
    static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

/// Microphone via AVAudioEngine. Keeps running in the background (the app
/// declares the `audio` background mode), so captions continue on lock screen.
nonisolated final class MicrophoneSource: AudioSource, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var onEvent: (@Sendable (AudioCaptureEvent) -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start(onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void) throws {
        lock.withLock { self.onEvent = onEvent }

        let session = AVAudioSession.sharedInstance()
        // .record: we only listen. Default mode keeps automatic gain control,
        // which helps with a phone on speaker across the table.
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        try startEngine()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
                self?.handleInterruption(note)
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
                self?.restartAfterReset()
            },
            // Input device changed (e.g. AirPods connected): formats change, rebuild the tap.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.restartAfterReset()
            },
        ]
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { onEvent = nil }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Catchline", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风"])
        }
        let converter = AVAudioConverter(from: inputFormat, to: StreamAudioFormat.pcm)
        lock.withLock { self.converter = converter }

        input.removeTap(onBus: 0)
        // ~100 ms buffers at 48 kHz.
        input.installTap(onBus: 0, bufferSize: 4800, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndEmit(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func convertAndEmit(_ buffer: AVAudioPCMBuffer) {
        let (converter, emit) = lock.withLock { (self.converter, self.onEvent) }
        guard let converter, let emit else { return }
        let ratio = StreamAudioFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: StreamAudioFormat.pcm, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            emit(.failed(error.localizedDescription))
            return
        }
        guard out.frameLength > 0, let samples = out.int16ChannelData else { return }
        emit(.chunk(Data(bytes: samples[0], count: Int(out.frameLength) * 2)))
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let emit = lock.withLock { onEvent }
        switch type {
        case .began:
            emit?(.interrupted)
        case .ended:
            restartAfterReset()
        @unknown default:
            break
        }
    }

    private func restartAfterReset() {
        let emit = lock.withLock { onEvent }
        guard emit != nil else { return } // stopped
        do {
            engine.stop()
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
            emit?(.resumed)
        } catch {
            emit?(.failed(error.localizedDescription))
        }
    }
}

#if DEBUG
/// Plays a file into the pipeline at real-time pace, looping. For simulator
/// tests (the Mac mini has no microphone).
nonisolated final class FileSource: AudioSource, @unchecked Sendable {
    private let url: URL
    private var task: Task<Void, Never>?

    init(path: String) { url = URL(fileURLWithPath: path) }

    func start(onEvent: @escaping @Sendable (AudioCaptureEvent) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: StreamAudioFormat.pcm),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw NSError(domain: "Catchline", code: 2) }
        try file.read(into: source)

        let capacity = AVAudioFrameCount(Double(source.frameLength) * StreamAudioFormat.sampleRate / source.format.sampleRate) + 64
        let pcm = AVAudioPCMBuffer(pcmFormat: StreamAudioFormat.pcm, frameCapacity: capacity)!
        var fed = false
        converter.convert(to: pcm, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return source
        }
        let all = Data(bytes: pcm.int16ChannelData![0], count: Int(pcm.frameLength) * 2)

        task = Task.detached {
            let chunkBytes = Int(StreamAudioFormat.sampleRate / 10) * 2 // 100 ms
            var offset = 0
            while !Task.isCancelled {
                let end = min(offset + chunkBytes, all.count)
                onEvent(.chunk(all.subdata(in: offset..<end)))
                offset = end == all.count ? 0 : end
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
#endif

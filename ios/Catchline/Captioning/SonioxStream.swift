import Foundation

/// Session config sent as the first WebSocket message.
/// https://soniox.com/docs/stt/api-reference/websocket-api
nonisolated struct SonioxConfig: Encodable, Sendable {
    struct Translation: Encodable, Sendable {
        let type = "one_way"
        let targetLanguage: String
        enum CodingKeys: String, CodingKey { case type, targetLanguage = "target_language" }
    }

    struct Context: Encodable, Sendable {
        var terms: [String]?
        var text: String?
    }

    var apiKey = ""
    let model: String
    let audioFormat = StreamAudioFormat.sonioxName
    let sampleRate = Int(StreamAudioFormat.sampleRate)
    let numChannels = 1
    let languageHints: [String]
    let enableEndpointDetection = true
    let translation: Translation
    let context: Context?

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key", model, audioFormat = "audio_format", sampleRate = "sample_rate"
        case numChannels = "num_channels", languageHints = "language_hints"
        case enableEndpointDetection = "enable_endpoint_detection", translation, context
    }
}

nonisolated struct SonioxResponse: Decodable, Sendable {
    let tokens: [SonioxToken]?
    let finished: Bool?
    let errorCode: Int?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

nonisolated struct SonioxServerError: Error, Sendable {
    let code: Int
    let message: String
}

/// One Soniox real-time stream over `URLSessionWebSocketTask`.
nonisolated final class SonioxStream: Sendable {
    private let task: URLSessionWebSocketTask

    init() {
        task = URLSession.shared.webSocketTask(with: AppConfig.sonioxWebSocketURL)
    }

    func open(config: SonioxConfig) async throws {
        task.resume()
        let json = try JSONEncoder().encode(config)
        try await task.send(.string(String(decoding: json, as: UTF8.self)))
    }

    func send(audio: Data) async throws {
        try await task.send(.data(audio))
    }

    /// An empty text frame asks the server to finalize everything and finish.
    func finish() async {
        try? await task.send(.string(""))
    }

    /// Next server message. Throws on socket errors and server error replies.
    func receive() async throws -> SonioxResponse {
        while true {
            let message = try await task.receive()
            let data: Data
            switch message {
            case let .string(text): data = Data(text.utf8)
            case let .data(bytes): data = bytes
            @unknown default: continue
            }
            let response = try JSONDecoder().decode(SonioxResponse.self, from: data)
            if let code = response.errorCode {
                throw SonioxServerError(code: code, message: response.errorMessage ?? "Soniox error \(code)")
            }
            return response
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

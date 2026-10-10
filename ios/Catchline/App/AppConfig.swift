import Foundation

/// Deployment values from `npm run deploy` (CatchlineApp stack outputs).
nonisolated enum AppConfig {
    static let apiBaseURL = URL(string: "https://catchline.deskfox.cn")!
    static let cognitoDomain = URL(string: "https://catchline-deskfox.auth.us-east-1.amazoncognito.com")!
    static let cognitoClientID = "6gvv92kca0c56606hl9toqokc4"
    static let callbackScheme = "com.deskfox.catchline"
    static let redirectURI = "com.deskfox.catchline://auth/callback"

    static let sonioxWebSocketURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    /// Current real-time model per GET https://api.soniox.com/v1/models (2026-10).
    static let sonioxModel = "stt-rt-v5"

    #if DEBUG
    /// Launch with `-CatchlineLocalMock YES` to skip login and use the Vite dev
    /// mock at http://localhost:5173 (simulator shares the Mac's network).
    static var useLocalMock: Bool { UserDefaults.standard.bool(forKey: "CatchlineLocalMock") }
    /// Launch with `-CatchlineAudioFile /path/to/file.wav` to feed a file
    /// instead of the microphone (looped, real-time pace).
    static var audioFilePath: String? { UserDefaults.standard.string(forKey: "CatchlineAudioFile") }
    /// Launch with `-CatchlineAutoStart YES` to start captioning on launch (UI-free tests).
    static var autoStart: Bool { UserDefaults.standard.bool(forKey: "CatchlineAutoStart") }
    #else
    static let useLocalMock = false
    static let audioFilePath: String? = nil
    static let autoStart = false
    #endif

    static var keyEndpoint: URL {
        let base = useLocalMock ? URL(string: "http://localhost:5173")! : apiBaseURL
        return base.appending(path: "api/temporary-api-key")
    }
}

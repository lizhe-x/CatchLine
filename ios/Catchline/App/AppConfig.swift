import Foundation

/// Deployment values from `npm run deploy` (CatchlineApp stack outputs).
nonisolated enum AppConfig {
    static let apiBaseURL = URL(string: "https://catchline.deskfox.cn")!

    /// Subscription group "Catchline Pro", highest level first:
    /// 1. yearly.now — no trial, only offered once trial hours run out; as the
    ///    top level, buying it during a trial upgrades (and charges) immediately.
    /// 2. yearly, 3. monthly — both with a 7-day free trial (one per Apple ID per group).
    static let yearlyNowProductID = "com.deskfox.catchline.yearly.now"
    static let yearlyProductID = "com.deskfox.catchline.yearly"
    static let monthlyProductID = "com.deskfox.catchline.monthly"
    static var productIDs: [String] { [yearlyNowProductID, yearlyProductID, monthlyProductID] }

    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://catchline.deskfox.cn/privacy.html")!
    static let fairUseURL = URL(string: "https://catchline.deskfox.cn/fair-use.html")!

    static let sonioxWebSocketURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    /// Current real-time model per GET https://api.soniox.com/v1/models (2026-10).
    static let sonioxModel = "stt-rt-v5"

    #if DEBUG
    /// Launch with `-CatchlineLocalMock YES` to use the Vite dev mock at
    /// http://localhost:5173 (simulator shares the Mac's network; the
    /// simulator also can't do App Attest, so requests go unsigned).
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

    static var apiBase: URL {
        useLocalMock ? URL(string: "http://localhost:5173")! : apiBaseURL
    }
}

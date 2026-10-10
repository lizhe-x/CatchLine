struct Language: Identifiable, Hashable {
    let code: String
    let label: String
    var id: String { code }

    static let all: [Language] = [
        .init(code: "en", label: "English"),
        .init(code: "zh", label: "中文"),
        .init(code: "ja", label: "日本語"),
        .init(code: "ko", label: "한국어"),
        .init(code: "es", label: "Español"),
        .init(code: "fr", label: "Français"),
        .init(code: "de", label: "Deutsch"),
        .init(code: "pt", label: "Português"),
        .init(code: "ru", label: "Русский"),
        .init(code: "vi", label: "Tiếng Việt"),
    ]
}

/// UserDefaults keys for per-device preferences.
enum Prefs {
    static let sourceLang = "sourceLang"
    static let targetLang = "targetLang"
    static let fontScale = "fontScale"
    static let terms = "terms"
    static let background = "background"
}

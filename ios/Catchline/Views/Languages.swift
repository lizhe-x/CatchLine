import Foundation

/// A language Soniox can recognize and translate into.
struct Language: Identifiable, Hashable {
    let code: String
    var id: String { code }

    /// Name in the app's current UI language, e.g. "Japanese" / "日语".
    var name: String { Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code }
    /// Name in the language itself, e.g. "日本語".
    var nativeName: String { Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized ?? code }
    /// "Japanese · 日本語" (just "English" when they're the same).
    var label: String { name == nativeName ? name : "\(name) · \(nativeName)" }

    /// Every language `stt-rt-v5` supports for recognition and one-way
    /// translation (GET https://api.soniox.com/v1/models, 2026-10).
    static let sonioxCodes = [
        "af", "sq", "ar", "az", "eu", "be", "bn", "bs", "bg", "ca", "zh", "hr", "cs", "da", "nl", "en",
        "et", "fi", "fr", "gl", "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn", "kk", "ko",
        "lv", "lt", "mk", "ms", "ml", "mr", "no", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "sk", "sl",
        "es", "sw", "sv", "tl", "ta", "te", "th", "tr", "uk", "ur", "vi", "cy",
    ]

    /// Sorted by name in the current UI language.
    static var all: [Language] {
        sonioxCodes.map(Language.init(code:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Translate into the user's own language: their first preferred
    /// language Soniox supports that isn't English, else Chinese.
    static let defaultTarget: String = {
        for identifier in Locale.preferredLanguages {
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier else { continue }
            if code != "en", sonioxCodes.contains(code) { return code }
        }
        return "zh"
    }()
}

/// UserDefaults keys for per-device preferences.
enum Prefs {
    static let sourceLang = "sourceLang"
    static let targetLang = "targetLang"
    static let fontScale = "fontScale"
    static let terms = "terms"
    static let background = "background"
}

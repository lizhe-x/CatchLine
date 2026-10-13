import Foundation
import UIKit

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

    /// `Prefs.sourceLang` value for "detect automatically".
    static let auto = "auto"

    /// Soniox code for an iOS language identifier ("zh-Hant-TW" → "zh",
    /// "nb-NO" → "no"), or nil if Soniox doesn't support it.
    static func sonioxCode(for identifier: String) -> String? {
        guard var code = Locale(identifier: identifier).language.languageCode?.identifier else { return nil }
        switch code {
        case "nb", "nn": code = "no"
        case "fil": code = "tl"
        case "iw": code = "he"
        case "in": code = "id"
        default: break
        }
        return sonioxCodes.contains(code) ? code : nil
    }

    /// Translate into the phone's language; English if Soniox doesn't have it.
    static var systemTarget: String {
        Locale.preferredLanguages.first.flatMap(sonioxCode(for:)) ?? "en"
    }

    /// Languages this user most likely hears, best first: English (most
    /// users live or work in it), the phone's other languages, keyboards,
    /// and the region's language. Never includes `target`.
    @MainActor
    static func likelySources(target: String) -> [String] {
        var ids = ["en"] + Locale.preferredLanguages
        ids += UITextInputMode.activeInputModes.compactMap(\.primaryLanguage)
        if let region = Locale.current.region?.identifier {
            ids.append(Locale.Language(identifier: "und-\(region)").maximalIdentifier)
        }
        var seen: Set<String> = [target]
        return ids.compactMap(sonioxCode(for:)).filter { seen.insert($0).inserted }
    }

    /// Hints for automatic detection: bias toward the languages around this
    /// user (and the target, which they speak) without excluding any other.
    @MainActor
    static func autoHints(target: String) -> [String] {
        Array(([target] + likelySources(target: target)).prefix(4))
    }
}

/// UserDefaults keys for per-device preferences.
enum Prefs {
    static let sourceLang = "sourceLang"
    static let targetLang = "targetLang"
    static let fontScale = "fontScale"
    static let terms = "terms"
    static let background = "background"
    /// Set once the first-launch language screen is done.
    static let onboarded = "onboarded"
    /// The "mostly Spanish detected — set it?" tip was answered; don't ask again.
    static let sourceTipAnswered = "sourceTipAnswered"
}

import Foundation
import Observation

/// One token from a Soniox real-time result.
nonisolated struct SonioxToken: Decodable, Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let translationStatus: String?
    /// Detected language of a spoken token (with language identification on).
    var language: String? = nil

    enum CodingKeys: String, CodingKey {
        case text, language
        case isFinal = "is_final"
        case translationStatus = "translation_status"
    }

    var isTranslation: Bool { translationStatus == "translation" }
    /// Spoken in the target language already, so Soniox won't translate it.
    var isUntranslated: Bool { translationStatus == "none" }
}

/// One caption block: a chunk of recognized speech plus its translation.
///
/// Soniox finalizes source text in sentence-ish chunks and streams the
/// translation of each chunk right after it, so a row is "source chunk(s) →
/// translation". A new row starts when source text to translate arrives after
/// the current row already received translation, or after an endpoint (`<end>`).
///
/// Speech already in the target language ("Hi hello 小朋友" → zh) comes back
/// marked `none` and is never translated, so it's kept as-is in the
/// translation line, in spoken order: "你好你好，小朋友".
struct CaptionRow: Identifiable, Equatable {
    /// A run of source speech, as it shows up in the translation line.
    struct Segment: Equatable {
        /// True for speech to be translated: `text` is its translation so far.
        /// False for speech already in the target language: `text` is the speech.
        var translated: Bool
        var text: String
        /// No more translation goes here (a later segment has started receiving it).
        var done = false
    }

    let id: Int
    /// When the row's first word was finalized.
    let at: Date
    var source: String
    var segments: [Segment] = []
    var closed: Bool
    /// Whether any translation arrived (the next source text starts a new row).
    var hasTranslation = false

    /// The translation line. Empty when nothing needs translating (it would
    /// just repeat the source). Stops before a segment whose translation
    /// hasn't arrived yet, so the line only ever grows at the end.
    var target: String {
        guard segments.contains(where: \.translated) else { return "" }
        var out = ""
        for segment in segments {
            if segment.translated, segment.text.isEmpty, !closed { break }
            out += segment.text
        }
        return String(out.drop(while: \.isWhitespace))
    }
}

@Observable
final class Transcript {
    private(set) var rows: [CaptionRow] = []
    /// Non-final source text still being recognized (shown dimmed).
    private(set) var liveSource = ""
    /// Non-final translation text, if the server sends any.
    private(set) var liveTarget = ""
    private var nextID = 1
    /// Characters of finalized speech per detected language, counting only
    /// speech that gets translated (i.e. not already in the target language).
    @ObservationIgnored private var spokenCharacters: [String: Int] = [:]

    var isEmpty: Bool { rows.isEmpty }

    /// Apply one result message. Non-final tokens replace the previous ones.
    func apply(_ tokens: [SonioxToken], now: Date = .now) {
        var source = ""
        var target = ""
        for token in tokens {
            switch token.text {
            case "<end>":
                closeLastRow()
                continue
            case "<fin>":
                continue
            default:
                break
            }
            if !token.isFinal {
                if token.isTranslation { target += token.text } else { source += token.text }
            } else if token.isTranslation {
                appendTarget(token.text, now: now)
            } else {
                appendSource(token.text, untranslated: token.isUntranslated, now: now)
                if !token.isUntranslated, let language = token.language {
                    spokenCharacters[language, default: 0] += token.text.count
                }
            }
        }
        sealFilledSegments()
        if liveSource != source { liveSource = source }
        if liveTarget != target { liveTarget = target }
    }

    /// A new Soniox stream started: in-flight non-final text is gone with
    /// the old one, and the next words must not glue onto the old row.
    func sessionRestarted() {
        guard !liveSource.isEmpty || !liveTarget.isEmpty else { return }
        liveSource = ""
        liveTarget = ""
        closeLastRow()
    }

    /// Keep whatever non-final text is left when the session ends for good.
    func commitLive(now: Date = .now) {
        guard !liveSource.isEmpty || !liveTarget.isEmpty else { return }
        if !liveSource.isEmpty { appendSource(liveSource, untranslated: false, now: now) }
        if !liveTarget.isEmpty { appendTarget(liveTarget, now: now) }
        liveSource = ""
        liveTarget = ""
        closeLastRow()
    }

    /// The language most of the translated speech was in, if it clearly
    /// dominated (≥ 80%) a reasonably long session.
    func dominantSpokenLanguage(minCharacters: Int = 60) -> String? {
        let total = spokenCharacters.values.reduce(0, +)
        guard total >= minCharacters, let top = spokenCharacters.max(by: { $0.value < $1.value }),
              Double(top.value) >= Double(total) * 0.8 else { return nil }
        return top.key
    }

    func reset() {
        spokenCharacters = [:]
        rows = []
        liveSource = ""
        liveTarget = ""
    }

    private func appendSource(_ text: String, untranslated: Bool, now: Date) {
        // Speech that won't be translated can't break source → translation
        // pairing, so it stays with the sentence it followed ("Hi hello 小朋友").
        if rows.last.map({ $0.closed || ($0.hasTranslation && !untranslated) }) ?? true {
            rows.append(CaptionRow(id: nextID, at: now, source: text.trimmingLeadingWhitespace(), closed: false))
            nextID += 1
        } else {
            rows[rows.count - 1].source += text
        }
        let i = rows.count - 1
        if let last = rows[i].segments.last, last.translated == !untranslated {
            // Same kind as the previous run: grow it (passthrough keeps the words).
            if untranslated { rows[i].segments[rows[i].segments.count - 1].text += text }
        } else {
            rows[i].segments.append(.init(translated: !untranslated, text: untranslated ? text : ""))
        }
    }

    private func appendTarget(_ text: String, now: Date) {
        if rows.isEmpty {
            rows.append(CaptionRow(id: nextID, at: now, source: "", closed: false))
            nextID += 1
        }
        let i = rows.count - 1
        rows[i].hasTranslation = true
        // Translation fills the earliest translatable segment still open.
        if let j = rows[i].segments.firstIndex(where: { $0.translated && !$0.done }) {
            rows[i].segments[j].text += text
        } else {
            rows[i].segments.append(.init(translated: true, text: text))
        }
    }

    /// Soniox sends each chunk's translation together, so at the end of a
    /// message a segment that got translation is complete — if a later
    /// segment is waiting for its own. (Otherwise more of it may follow.)
    private func sealFilledSegments() {
        guard let i = rows.indices.last else { return }
        let segments = rows[i].segments
        for j in segments.indices where segments[j].translated && !segments[j].done && !segments[j].text.isEmpty {
            if segments[(j + 1)...].contains(where: \.translated) { rows[i].segments[j].done = true }
        }
    }

    private func closeLastRow() {
        if let last = rows.last, !last.closed { rows[rows.count - 1].closed = true }
    }
}

extension Transcript {
    func exportText(startedAt: Date, sourceLang: String, targetLang: String) -> String {
        let header = "CatchLine transcript — \(startedAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))) (\(sourceLang) → \(targetLang))"
        let body = rows
            .filter { !$0.source.isEmpty || !$0.target.isEmpty }
            .map { row -> String in
                let stamp = "[\(formatElapsed(row.at.timeIntervalSince(startedAt)))]"
                let indent = String(repeating: " ", count: stamp.count + 1)
                return row.target.isEmpty ? "\(stamp) \(row.source)" : "\(stamp) \(row.source)\n\(indent)\(row.target)"
            }
        return ([header, ""] + body + [""]).joined(separator: "\n")
    }
}

func formatElapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

private extension String {
    func trimmingLeadingWhitespace() -> String {
        String(drop(while: \.isWhitespace))
    }
}

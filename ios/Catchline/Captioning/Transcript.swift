import Foundation
import Observation

/// One token from a Soniox real-time result.
nonisolated struct SonioxToken: Decodable, Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let translationStatus: String?

    enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
        case translationStatus = "translation_status"
    }

    var isTranslation: Bool { translationStatus == "translation" }
}

/// One caption block: a chunk of recognized speech plus its translation.
///
/// Soniox finalizes source text in sentence-ish chunks and streams the
/// translation of each chunk right after it, so a row is "source chunk(s) →
/// translation". A new row starts when source text arrives after the current
/// row already received translation, or after an endpoint (`<end>`).
struct CaptionRow: Identifiable, Equatable {
    let id: Int
    /// When the row's first word was finalized.
    let at: Date
    var source: String
    var target: String
    var closed: Bool
}

@Observable
final class Transcript {
    private(set) var rows: [CaptionRow] = []
    /// Non-final source text still being recognized (shown dimmed).
    private(set) var liveSource = ""
    /// Non-final translation text, if the server sends any.
    private(set) var liveTarget = ""
    private var nextID = 1

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
                appendSource(token.text, now: now)
            }
        }
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
        if !liveSource.isEmpty { appendSource(liveSource, now: now) }
        if !liveTarget.isEmpty { appendTarget(liveTarget, now: now) }
        liveSource = ""
        liveTarget = ""
        closeLastRow()
    }

    func reset() {
        rows = []
        liveSource = ""
        liveTarget = ""
    }

    private func appendSource(_ text: String, now: Date) {
        if let last = rows.last, !last.closed, last.target.isEmpty {
            rows[rows.count - 1].source += text
        } else {
            rows.append(CaptionRow(id: nextID, at: now, source: text.trimmingLeadingWhitespace(), target: "", closed: false))
            nextID += 1
        }
    }

    private func appendTarget(_ text: String, now: Date) {
        if rows.isEmpty {
            rows.append(CaptionRow(id: nextID, at: now, source: "", target: text.trimmingLeadingWhitespace(), closed: false))
            nextID += 1
            return
        }
        let i = rows.count - 1
        rows[i].target = rows[i].target.isEmpty ? text.trimmingLeadingWhitespace() : rows[i].target + text
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

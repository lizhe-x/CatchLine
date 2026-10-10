import Foundation
import Testing
@testable import Catchline

@MainActor
struct TranscriptTests {
    private func token(_ text: String, final: Bool = true, translation: Bool = false) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, translationStatus: translation ? "translation" : "original")
    }

    @Test func pairsEachSourceChunkWithItsTranslation() {
        let t = Transcript()
        t.apply([token("Hello"), token(" there.")])
        t.apply([token("你好。", translation: true)])
        t.apply([token(" How"), token(" are"), token(" you?")])
        t.apply([token("你好吗？", translation: true)])

        #expect(t.rows.map(\.source) == ["Hello there.", "How are you?"])
        #expect(t.rows.map(\.target) == ["你好。", "你好吗？"])
    }

    @Test func nonFinalTokensAreReplacedNotAppended() {
        let t = Transcript()
        t.apply([token("Hel", final: false)])
        t.apply([token("Hello", final: false), token(" wor", final: false)])
        #expect(t.liveSource == "Hello wor")
        #expect(t.rows.isEmpty)

        t.apply([token("Hello"), token(" world")])
        #expect(t.liveSource.isEmpty)
        #expect(t.rows.first?.source == "Hello world")
    }

    @Test func endpointClosesRow() {
        let t = Transcript()
        t.apply([token("Yes."), token("<end>", final: true)])
        t.apply([token(" No.")])
        #expect(t.rows.map(\.source) == ["Yes.", "No."])
    }

    @Test func sessionRestartDropsLiveTextAndStartsNewRow() {
        let t = Transcript()
        t.apply([token("We can"), token(" move", final: false)])
        t.sessionRestarted()
        #expect(t.liveSource.isEmpty)
        t.apply([token(" the meeting")])
        #expect(t.rows.map(\.source) == ["We can", "the meeting"])
    }

    @Test func commitLiveKeepsTheTail() {
        let t = Transcript()
        t.apply([token("Also, please bring", final: false)])
        t.commitLive()
        #expect(t.rows.map(\.source) == ["Also, please bring"])
        #expect(t.liveSource.isEmpty)
    }

    /// Replays a real Soniox session (en → zh) recorded on 2026-10-10.
    @Test func realSessionFixture() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "soniox-session", withExtension: "json"))
        let messages = try JSONDecoder().decode([[SonioxToken]].self, from: Data(contentsOf: url))
        let t = Transcript()
        for tokens in messages { t.apply(tokens) }

        #expect(t.rows.count == 6)
        #expect(t.rows.first?.source == "Okay, so here's the thing:")
        #expect(t.rows.first?.target == "好，事情是这样的：")
        #expect(t.rows.last?.source == "and your W-2 form.")
        #expect(t.rows.allSatisfy { !$0.target.isEmpty })
        #expect(t.liveSource.isEmpty)

        let text = t.exportText(startedAt: t.rows[0].at, sourceLang: "en", targetLang: "zh")
        #expect(text.contains("[00:00:00] Okay, so here's the thing:\n           好，事情是这样的："))
    }
}

private final class BundleToken {}

import Foundation
import Testing
@testable import Catchline

@MainActor
struct TranscriptTests {
    private func token(_ text: String, final: Bool = true, translation: Bool = false) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, translationStatus: translation ? "translation" : "original")
    }

    /// Speech already in the target language: Soniox marks it `none`.
    private func same(_ text: String, final: Bool = true) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, translationStatus: "none")
    }

    @Test func untranslatedSpeechStaysInTheTranslationLine() {
        let t = Transcript()
        t.apply([token("Hi"), token(" hello")])
        t.apply([token("你好你好，", translation: true)])
        t.apply([same(" 小朋友")])
        #expect(t.rows.map(\.source) == ["Hi hello 小朋友"])
        #expect(t.rows.map(\.target) == ["你好你好， 小朋友"])
    }

    @Test func untranslatedSpeechBeforeAPendingTranslationWaitsInOrder() {
        let t = Transcript()
        t.apply([token("OK,"), same(" 你听"), token(" stop here.")])
        // Neither English part translated yet: show nothing rather than "你听" first.
        #expect(t.rows.first?.target == "")
        t.apply([token("好，", translation: true)])
        #expect(t.rows.first?.target == "好， 你听")
        t.apply([token(" 停在这里。", translation: true)])
        #expect(t.rows.first?.target == "好， 你听 停在这里。")
    }

    @Test func rowEntirelyInTheTargetLanguageHasNoTranslationLine() {
        let t = Transcript()
        t.apply([same("然后我们去吃饭。"), token("<end>")])
        #expect(t.rows.map(\.source) == ["然后我们去吃饭。"])
        #expect(t.rows.map(\.target) == [""])
    }

    /// Replays a real mixed English/Chinese session (→ zh) recorded on 2026-10-13.
    @Test func realMixedSessionFixture() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "soniox-mixed-session", withExtension: "json"))
        let messages = try JSONDecoder().decode([[SonioxToken]].self, from: Data(contentsOf: url))
        let t = Transcript()
        for tokens in messages { t.apply(tokens) }

        #expect(t.rows.map(\.source) == [
            "Hi.", "Hello. 小朋友。", "Today we have a meeting", "with the client. 然后我们一起去吃饭。",
            "I think the budget is too high. 你觉得呢？",
        ])
        #expect(t.rows.map(\.target) == [
            "你好。", "你好。 小朋友。", "今天我们有个会议，", "和客户见面。 然后我们一起去吃饭。",
            "我觉得预算太高了。 你觉得呢？",
        ])
        #expect(t.dominantSpokenLanguage(minCharacters: 20) == "en")
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

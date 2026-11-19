import FiggStore
import Foundation
import Testing

@Suite struct DictationTests {
    let store = try! Store.inMemory()

    @Test func keepsNewestFirstAndPrunesTheOldest() throws {
        let now = Date()
        for i in 0..<5 {
            try store.addDictation(
                Dictation(createdAt: now.addingTimeInterval(Double(i)), text: "line \(i)", appName: "Notes", outcome: .inserted),
                keep: 3)
        }
        let kept = try store.recentDictations(limit: 10)
        #expect(kept.map(\.text) == ["line 4", "line 3", "line 2"])
        #expect(kept.allSatisfy { $0.id != nil })
    }

    @Test func remembersWhatHappenedToTheText() throws {
        let saved = try store.addDictation(Dictation(text: "hello", appName: "Slack", outcome: .notInserted), keep: 10)
        let back = try #require(try store.recentDictations(limit: 1).first)
        #expect(back.outcome == .notInserted)
        #expect(back.appName == "Slack")
        try store.deleteDictation(id: try #require(saved.id))
        #expect(try store.recentDictations(limit: 10).isEmpty)
    }

    @Test func clearRemovesEverything() throws {
        try store.addDictation(Dictation(text: "a", appName: "", outcome: .typed), keep: 10)
        try store.addDictation(Dictation(text: "b", appName: "", outcome: .typed), keep: 10)
        try store.clearDictations()
        #expect(try store.recentDictations(limit: 10).isEmpty)
    }
}

@Suite struct DictationRawTextTests {
    let store = try! Store.inMemory()

    @Test func keepsRawAndCleanedText() throws {
        try store.addDictation(Dictation(text: "Ship it Friday.", rawText: "uh ship it friday", appName: "Mail", outcome: .inserted), keep: 10)
        try store.addDictation(Dictation(text: "plain", appName: "Mail", outcome: .typed), keep: 10)
        let back = try store.recentDictations(limit: 10)
        #expect(back.map(\.rawText) == [nil, "uh ship it friday"])
    }

    @Test func updatingTheTextNeverLosesTheRawWords() throws {
        let d = try store.addDictation(Dictation(text: "Ship it Friday.", rawText: "uh ship it friday", appName: "", outcome: .inserted), keep: 10)
        try store.updateDictationText(id: try #require(d.id), text: "uh ship it friday", rawText: "something else")
        let back = try #require(try store.recentDictations(limit: 1).first)
        #expect(back.text == "uh ship it friday")
        #expect(back.rawText == "uh ship it friday")

        // A dictation typed uncleaned gets its raw text on Process Again.
        let plain = try store.addDictation(Dictation(text: "um hi", appName: "", outcome: .typed), keep: 10)
        try store.updateDictationText(id: try #require(plain.id), text: "Hi.", rawText: "um hi")
        let after = try #require(try store.recentDictations(limit: 1).first)
        #expect(after.text == "Hi.")
        #expect(after.rawText == "um hi")
    }
}

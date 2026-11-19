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

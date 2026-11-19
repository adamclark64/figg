@testable import FiggExport
import FiggStore
import Foundation
import Testing

@Suite struct ExportFileTests {
    func name(_ title: String) -> String {
        ExportFile.suggestedName(for: Meeting(title: title), pathExtension: "md")
    }

    @Test func suggestedNameReplacesSeparators() {
        #expect(name("Plan: Q3/Q4 \\ review") == "Plan- Q3-Q4 - review.md")
    }

    @Test func suggestedNameReplacesControlCharacters() {
        #expect(name("Weekly\tsync\nnotes") == "Weekly-sync-notes.md")
    }

    @Test func suggestedNameTrimsSpacesAndDots() {
        #expect(name("  ..Weekly sync..  ") == "Weekly sync.md")
    }

    @Test func suggestedNameCutsToOneHundredCharacters() {
        let long = String(repeating: "a", count: 150)
        let result = name(long)
        #expect(result == String(repeating: "a", count: 100) + ".md")
    }

    @Test func suggestedNameTrimsAfterTheCut() {
        // Character 100 is a space, so the cut ends on it and it is trimmed.
        let title = String(repeating: "a", count: 99) + " " + String(repeating: "b", count: 20)
        #expect(name(title) == String(repeating: "a", count: 99) + ".md")
    }

    @Test func suggestedNameFallsBackWhenEmpty() {
        #expect(name("...") == "Meeting.md")
        #expect(name("   ") == "Meeting.md")
    }

    @Test func suggestedNameForUntitledMeetingHasNoColon() {
        let untitled = Meeting(title: "", createdAt: Date(timeIntervalSince1970: 1_767_225_600))
        let result = ExportFile.suggestedName(for: untitled, pathExtension: "md")
        #expect(result.hasPrefix("Meeting"))
        #expect(result.hasSuffix(".md"))
        #expect(!result.contains(":"))
    }

    @Test func suggestedNameUsesTheGivenExtension() {
        #expect(ExportFile.suggestedName(for: Meeting(title: "Weekly sync"), pathExtension: "txt") == "Weekly sync.txt")
    }

    @Test func writeReplaces() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Weekly sync.md")

        try ExportFile.write("first", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "first")

        try ExportFile.write("second", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "second")

        let accented = "# Café review\n- We ship on Friday ✓ 日本"
        try ExportFile.write(accented, to: url)
        #expect(try Data(contentsOf: url) == Data(accented.utf8))
        #expect(try String(contentsOf: url, encoding: .utf8) == accented)
    }
}

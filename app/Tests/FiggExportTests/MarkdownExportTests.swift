@testable import FiggExport
import FiggStore
import Foundation
import Testing

@Suite struct MarkdownExportTests {
    let enhanced = Meeting(
        title: "Weekly sync",
        createdAt: Date(timeIntervalSince1970: 1_767_225_600),
        status: .ready,
        userNotes: "- my own note",
        enhancedNotes: "## Summary\nWe ship on Friday."
    )
    let notesOnly = Meeting(
        title: "Planning chat",
        createdAt: Date(timeIntervalSince1970: 1_767_225_600),
        status: .ready,
        userNotes: "- draft the agenda"
    )

    func line(_ speaker: Speaker, _ start: Double, _ text: String, label: String? = nil) -> TranscriptLine {
        TranscriptLine(meetingId: "m1", speaker: speaker, start: start, end: start + 2, text: text, speakerLabel: label)
    }

    /// The document's lines after the `## Transcript` heading and its blank line.
    func items(_ document: String) -> [String] {
        guard let range = document.range(of: "\n\n## Transcript\n\n") else { return [] }
        return document[range.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    @Test func startsWithCopyAsMarkdown() {
        let lines = [line(.me, 1, "Hello there")]
        for meeting in [enhanced, notesOnly] {
            let copied = Formatters.markdown(meeting)
            #expect(MarkdownExport.document(meeting, lines: lines).hasPrefix(copied))
            #expect(MarkdownExport.document(meeting, lines: []) == copied)
        }
        #expect(MarkdownExport.document(enhanced, lines: lines).contains("We ship on Friday."))
        #expect(MarkdownExport.document(notesOnly, lines: lines).contains("- draft the agenda"))
    }

    @Test func transcriptSortedByStart() {
        let lines = [
            line(.them, 30, "Sounds good"),
            line(.me, 5, "We ship on Friday"),
            line(.them, 12, "Is the build ready"),
            line(.me, 12, "Almost"),
        ]
        let document = MarkdownExport.document(enhanced, lines: lines)
        #expect(document.hasSuffix("\n"))
        #expect(items(document) == [
            "- **[00:05] Me:** We ship on Friday",
            "- **[00:12] Them:** Is the build ready",
            "- **[00:12] Me:** Almost",
            "- **[00:30] Them:** Sounds good",
        ])
    }

    @Test func speakerUsesDisplayName() {
        let lines = [
            line(.them, 0, "Morning", label: "Guest 1"),
            line(.me, 3, "Hi"),
        ]
        #expect(items(MarkdownExport.document(enhanced, lines: lines)) == [
            "- **[00:00] Guest 1:** Morning",
            "- **[00:03] Me:** Hi",
        ])
    }

    @Test func timestamps() {
        let lines = [0, 59.9, 61, 3599, 3661].map { line(.me, $0, "Point") }
        #expect(items(MarkdownExport.document(enhanced, lines: lines)) == [
            "- **[00:00] Me:** Point",
            "- **[00:59] Me:** Point",
            "- **[01:01] Me:** Point",
            "- **[59:59] Me:** Point",
            "- **[1:01:01] Me:** Point",
        ])
    }

    @Test func newlinesFlattened() {
        let item = MarkdownExport.item(line(.me, 0, "a\nb\r\nc"))
        #expect(item == "- **[00:00] Me:** a b c")
        let hasNewline = item.contains { $0.isNewline }
        #expect(!hasNewline)
        #expect(items(MarkdownExport.document(enhanced, lines: [line(.me, 0, "a\nb\r\nc")])) == [item])
    }

    @Test func noTranscriptNoHeading() {
        #expect(!MarkdownExport.document(enhanced, lines: []).contains("## Transcript"))
        #expect(!MarkdownExport.document(notesOnly, lines: []).contains("## Transcript"))
    }
}

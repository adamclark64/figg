@testable import FiggUpdate
import Foundation
import Testing

@Suite struct ReleaseNotesTests {
    /// Invented notes in the shape release-please writes.
    static func note(_ version: String) -> ReleaseNote {
        ReleaseNote(version: version, text: """
        ### Bug Fixes

        * **notes:** keep the cursor in place after saving ([#12](https://github.com/example/repo/issues/12))
        """)
    }

    private func versions(_ notes: ReleaseNotes?) -> [String] {
        notes?.sections.map(\.version) ?? []
    }

    private func rendered(_ notes: ReleaseNotes) -> Int {
        notes.sections.flatMap(\.blocks).reduce(0) { $0 + ReleaseNotes.inline($1.text).characters.count }
    }

    // MARK: Which versions

    @Test func coversVersionsAfterTheInstalledOne() {
        let notes = ["0.19.0", "0.16.0", "0.20.0", "0.18.0", "0.19.2", "0.17.0", "0.19.1"].map(Self.note)
            + [ReleaseNote(version: "0.19.1", text: "A repeated entry that should not show.")]
        let shown = ReleaseNotes.covering(notes, installed: "0.17.0", offered: "0.19.2")
        #expect(versions(shown) == ["0.19.2", "0.19.1", "0.19.0", "0.18.0"])
        #expect(shown?.isCut == false)
        // The first entry of a repeated version wins.
        let repeated = shown?.sections.first { $0.version == "0.19.1" }
        #expect(repeated?.blocks.first == .heading("Bug Fixes"))
    }

    @Test func ignoresVersionsNewerThanOffered() {
        let notes = ["0.21.0", "0.20.0", "0.19.0"].map(Self.note)
        let shown = ReleaseNotes.covering(notes, installed: "0.18.0", offered: "0.19.0")
        #expect(versions(shown) == ["0.19.0"])
    }

    @Test func nilWhenNothingIsNewer() {
        let notes = ["0.19.2", "0.19.0"].map(Self.note)
        #expect(ReleaseNotes.covering(notes, installed: "0.19.2", offered: "0.19.2") == nil)
        #expect(ReleaseNotes.covering(notes, installed: "0.20.0", offered: "0.19.2") == nil)
    }

    @Test func nilForNoNotes() {
        #expect(ReleaseNotes.covering([], installed: "0.18.0", offered: "0.19.0") == nil)
    }

    @Test func nilForNonNumericVersions() {
        let notes = ["0.19.0", "0.18.0"].map(Self.note)
        #expect(ReleaseNotes.covering(notes, installed: "dev", offered: "0.19.0") == nil)
        #expect(ReleaseNotes.covering(notes, installed: "", offered: "0.19.0") == nil)
        #expect(ReleaseNotes.covering(notes, installed: "0.17.0", offered: "0.19.0-beta") == nil)
        let odd = [ReleaseNote(version: "next", text: "Something."), ReleaseNote(version: "0.19.x", text: "Other.")]
        #expect(ReleaseNotes.covering(odd, installed: "0.17.0", offered: "0.19.0") == nil)
    }

    // MARK: The cut

    @Test func cutsAtTheLimitOnALineBoundary() throws {
        let lines = (1...10).map { "* item number \($0) of the list" }
        let source = ReleaseNote(version: "0.19.0", text: lines.joined(separator: "\n"))
        let shown = ReleaseNotes.covering([source], installed: "0.18.0", offered: "0.19.0", limit: 100)
        let notes = try #require(shown)
        #expect(notes.isCut)
        #expect(rendered(notes) <= 100)
        let blocks = notes.sections.flatMap(\.blocks)
        #expect(!blocks.isEmpty)
        #expect(blocks.count < lines.count)
        // Only whole lines, in order, from the start.
        let originals = ReleaseNotes.blocks(source.text)
        #expect(Array(originals.prefix(blocks.count)) == blocks)
    }

    @Test func limitCountsRenderedTextNotURLs() throws {
        let url = "https://github.com/example/repo/commit/" + String(repeating: "0123456789abcdef", count: 8)
        let lines = (1...5).map { "* **ui:** fix part \($0) ([#\($0)](\(url)))" }
        let text = lines.joined(separator: "\n")
        #expect(text.count > 600)
        // The installed version's own entry shows the file reaches back to it,
        // so only the limit could set isCut.
        let shown = ReleaseNotes.covering([ReleaseNote(version: "0.19.0", text: text),
                                           ReleaseNote(version: "0.18.0", text: "* an older fix")],
                                          installed: "0.18.0", offered: "0.19.0", limit: 200)
        let notes = try #require(shown)
        #expect(notes.sections.first?.blocks.count == 5)
        #expect(!notes.isCut)
    }

    @Test func cutsAnOverlongSingleLineAsPlainText() throws {
        let long = "[" + String(repeating: "word ", count: 60) + "](https://docs.example.com/page)"
        let newer = ReleaseNote(version: "0.19.0", text: long)
        let older = ReleaseNote(version: "0.18.5", text: "* a short fix")
        let shown = ReleaseNotes.covering([newer, older], installed: "0.18.0", offered: "0.19.0", limit: 50)
        let notes = try #require(shown)
        #expect(notes.isCut)
        #expect(versions(notes) == ["0.19.0"])
        let blocks = notes.sections[0].blocks
        #expect(blocks.count == 1)
        let text = ReleaseNotes.inline(blocks[0].text)
        let plain = String(text.characters)
        #expect(plain.count == 50)
        #expect(plain.hasPrefix("word word"))
        #expect(plain.hasSuffix("\u{2026}"))
        #expect(!plain.contains("]("))
        #expect(text.runs.allSatisfy { $0.link == nil })
    }

    @Test func marksCutWhenTheFileDoesNotReachTheInstalledVersion() {
        let notes = ["0.19.0", "0.18.0", "0.17.0"].map(Self.note)
        let shown = ReleaseNotes.covering(notes, installed: "0.10.0", offered: "0.19.0")
        #expect(versions(shown) == ["0.19.0", "0.18.0", "0.17.0"])
        #expect(shown?.isCut == true)
    }

    @Test func notCutWhenItFits() {
        let notes = ["0.19.0", "0.18.0", "0.17.0"].map(Self.note)
        let shown = ReleaseNotes.covering(notes, installed: "0.17.0", offered: "0.19.0")
        #expect(versions(shown) == ["0.19.0", "0.18.0"])
        #expect(shown?.isCut == false)
        #expect(shown?.sections.first?.blocks == ReleaseNotes.blocks(Self.note("0.19.0").text))
    }

    // MARK: Formatting

    @Test func blocksSplitHeadingsBulletsParagraphs() {
        let text = "### Features\n\n* **ui:** add a thing\n- another thing\n+ a third\n  * an indented one\r\nA closing line.\n<b>raw</b>\n###\n*not a bullet*"
        #expect(ReleaseNotes.blocks(text) == [
            .heading("Features"),
            .bullet("**ui:** add a thing"),
            .bullet("another thing"),
            .bullet("a third"),
            .bullet("an indented one"),
            .paragraph("A closing line."),
            .paragraph("<b>raw</b>"),
            .paragraph("*not a bullet*"),
        ])
    }

    @Test func inlineKeepsOnlyHttpsLinks() {
        let text = ReleaseNotes.inline(
            "[safe](https://example.com/a) [plain](http://example.com/b) [file](file:///tmp/x) [script](javascript:void) [mail](mailto:someone@example.com)"
        )
        let links = text.runs.compactMap { $0.link }
        #expect(links == [URL(string: "https://example.com/a")!])
        let plain = String(text.characters)
        for word in ["safe", "plain", "file", "script", "mail"] {
            #expect(plain.contains(word))
        }
    }

    @Test func inlineDropsImages() {
        let text = ReleaseNotes.inline("See ![a small diagram](https://images.example.com/d.png) here")
        #expect(text.runs.allSatisfy { $0.imageURL == nil })
        #expect(text.runs.allSatisfy { $0.link == nil })
        let plain = String(text.characters)
        #expect(plain.hasPrefix("See "))
        #expect(plain.hasSuffix(" here"))
        #expect(!plain.contains("images.example.com"))
    }

    @Test func inlineKeepsTheTextOfBadMarkdown() {
        let plain = String(ReleaseNotes.inline("**half bold and [a link](https://example.com").characters)
        #expect(plain.contains("half bold"))
        #expect(plain.contains("a link"))
    }
}

import Foundation

/// One version's notes as the version file carried them.
public struct ReleaseNote: Equatable, Sendable {
    /// Version without a leading v, e.g. "0.19.2".
    public var version: String
    /// That version's CHANGELOG.md section, as Markdown.
    public var text: String

    public init(version: String, text: String) {
        self.version = version
        self.text = text
    }
}

/// The notes to show for one offered update: the versions after the
/// installed one up to the offered one, newest first, cut to a limit.
///
/// The notes are untrusted text from the network, so this only ever turns
/// them into display text: headings, bullets and paragraphs, with inline
/// formatting and `https` links. Nothing in them is loaded or run, and they
/// never touch what is installed (`UpdateVerifier` checks the dmg alone).
public struct ReleaseNotes: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var version: String
        public var blocks: [Block]

        public init(version: String, blocks: [Block]) {
            self.version = version
            self.blocks = blocks
        }
    }

    /// One line of a section. The strings are still inline Markdown, for
    /// `ReleaseNotes.inline`.
    public enum Block: Equatable, Sendable {
        /// "### Bug Fixes" becomes "Bug Fixes".
        case heading(String)
        /// "* **x:** y" becomes "**x:** y".
        case bullet(String)
        case paragraph(String)

        /// The inline Markdown the block carries.
        public var text: String {
            switch self {
            case let .heading(s), let .bullet(s), let .paragraph(s): s
            }
        }

        func with(_ text: String) -> Block {
            switch self {
            case .heading: .heading(text)
            case .bullet: .bullet(text)
            case .paragraph: .paragraph(text)
            }
        }
    }

    public var sections: [Section]
    /// True when text was dropped by the limit, or when the versions in the
    /// file may not reach back to the installed one. The prompt then shows
    /// a link to the full changelog.
    public var isCut: Bool

    public init(sections: [Section], isCut: Bool) {
        self.sections = sections
        self.isCut = isCut
    }

    public static let fullChangelog = URL(string: "https://github.com/adamclark64/figg/blob/main/CHANGELOG.md")!
    /// Characters of rendered note text, not Markdown source, so the link
    /// URLs release-please puts on every bullet do not use up the budget.
    public static let defaultLimit = 6_000

    /// The notes for an update from `installed` to `offered`, or nil when
    /// there is nothing to show (the prompt then looks as it always has).
    ///
    /// Keeps entries newer than `installed` and not newer than `offered`,
    /// the first of a repeated version, newest first. A non-numeric
    /// installed or offered version gives nil, in line with
    /// `UpdateChecker.isNewer`: a broken version can only suppress, never
    /// show something odd.
    public static func covering(_ notes: [ReleaseNote], installed: String,
                                offered: String, limit: Int = defaultLimit) -> ReleaseNotes? {
        guard isNumeric(installed), isNumeric(offered) else { return nil }

        var seen = Set<String>()
        var picked: [ReleaseNote] = []
        for note in notes where isNumeric(note.version) {
            guard UpdateChecker.isNewer(note.version, than: installed),
                  !UpdateChecker.isNewer(note.version, than: offered),
                  seen.insert(note.version).inserted else { continue }
            picked.append(note)
        }
        guard !picked.isEmpty else { return nil }
        picked.sort { UpdateChecker.isNewer($0.version, than: $1.version) }

        // When nothing in the file is at or below the installed version, the
        // user is further behind than the file reaches, so older changes
        // are missing and the full changelog link should say so.
        let reachesInstalled = notes.contains {
            isNumeric($0.version) && !UpdateChecker.isNewer($0.version, than: installed)
        }
        var isCut = !reachesInstalled

        // Lines are kept or dropped whole, so a cut never leaves half a
        // link's syntax showing.
        var used = 0
        var sections: [Section] = []
        walk: for note in picked {
            var kept: [Block] = []
            for block in blocks(note.text) {
                let length = inline(block.text).characters.count
                if used + length > limit {
                    if sections.isEmpty, kept.isEmpty {
                        // The offered version's first line alone is too long:
                        // show it as plain text, cut, so the sheet is never
                        // empty and never shows broken link syntax.
                        kept.append(block.with(plainCut(block.text, limit: limit)))
                    }
                    isCut = true
                    if !kept.isEmpty { sections.append(Section(version: note.version, blocks: kept)) }
                    break walk
                }
                used += length
                kept.append(block)
            }
            if !kept.isEmpty { sections.append(Section(version: note.version, blocks: kept)) }
        }
        guard !sections.isEmpty else { return nil }
        return ReleaseNotes(sections: sections, isCut: isCut)
    }

    /// Splits a section into lines: `#` lines are headings, `* `, `- ` and
    /// `+ ` lines are bullets, blank lines are skipped, anything else is a
    /// paragraph. No HTML or other block Markdown is interpreted.
    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { out.append(.heading(heading)) }
            } else if line.hasPrefix("* ") || line.hasPrefix("- ") || line.hasPrefix("+ ") {
                let item = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { out.append(.bullet(item)) }
            } else {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    /// Inline Markdown as display text. Only `https` links survive, and
    /// every image is reduced to its alt text, so nothing is ever fetched.
    /// HTML stays literal text. Markdown that cannot be parsed is shown as
    /// it was written.
    public static func inline(_ markdown: String) -> AttributedString {
        var out: AttributedString
        do {
            out = try AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    allowsExtendedAttributes: false,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            out = AttributedString(markdown)
        }
        // Collect first, then change: attribute edits keep character indices.
        var badLinks: [Range<AttributedString.Index>] = []
        var images: [Range<AttributedString.Index>] = []
        for run in out.runs {
            if let url = run.link, url.scheme?.lowercased() != "https" { badLinks.append(run.range) }
            if run.imageURL != nil { images.append(run.range) }
        }
        for range in badLinks { out[range].link = nil }
        for range in images { out[range].imageURL = nil }
        return out
    }

    /// The rendered text of one line, cut to `limit` characters with an
    /// ellipsis and escaped so `inline` shows it exactly, unformatted.
    static func plainCut(_ markdown: String, limit: Int) -> String {
        let plain = String(inline(markdown).characters)
        let cut = plain.count > limit ? String(plain.prefix(max(limit - 1, 0))) + "\u{2026}" : plain
        var escaped = ""
        for c in cut {
            if c.isASCII, c.isPunctuation || c.isSymbol { escaped.append("\\") }
            escaped.append(c)
        }
        return escaped
    }

    /// Same rule as `UpdateChecker.isNewer`: dot-separated integers only.
    static func isNumeric(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { Int($0) != nil }
    }
}

# Design: save a meeting as a Markdown file

## Summary

Two small, pure pieces go in `FiggExport`, and the view gets one button.
`MarkdownExport.document(_:lines:)` builds the file's text: it starts with
`Formatters.markdown(meeting)` byte for byte, and, when the meeting has
transcript lines, adds a `## Transcript` heading and one list item per
line, sorted by start time, as `- **[mm:ss] Speaker:** text`. `ExportFile`
turns the meeting's display title into a safe file name and writes a
string to a URL as UTF-8, replacing any file there. `ExportMenu` (the Share
menu in `ExportViews.swift`) gains "Save as Markdown…", which reads the
transcript from the store, shows an `NSSavePanel` with the suggested name,
and writes through `ExportFile.write`; any error goes to the menu's
existing alert. Nothing touches the network, and the file holds only the
title, date, notes and transcript text.

## Types and files

New:

- `app/Sources/FiggExport/MarkdownExport.swift`:
  `public enum MarkdownExport`.
  - `public static func document(_ meeting: Meeting, lines: [TranscriptLine]) -> String`
    returns `Formatters.markdown(meeting)` when `lines` is empty, and
    otherwise `Formatters.markdown(meeting) + "\n\n## Transcript\n\n" +
    items.joined(separator: "\n") + "\n"`. The notes part is never trimmed
    or edited, so the document always starts with exactly what "Copy as
    Markdown" copies.
  - `static func item(_ line: TranscriptLine) -> String` gives
    `- **[\(formatTimestamp(line.start))] \(line.displaySpeaker):** \(flat(line.text))`.
    `formatTimestamp` (FiggStore, already used by the transcript view)
    floors via `Int(seconds)` and prints `mm:ss` under an hour and
    `h:mm:ss` from one hour on, so timestamps match what the app shows.
    `displaySpeaker` is `speakerLabel ?? speaker.label`, the same name the
    transcript view and prompts use, so renamed and diarized speakers
    match.
  - `static func flat(_ text: String) -> String` replaces every
    `Character` whose `isNewline` is true with a single space. Working on
    `Character` rather than `components(separatedBy: .newlines)` means
    `\r\n` (one grapheme) becomes one space, not two.
  - Sorting is by `start`, ties keep their input order (sort on
    `(start, index)` from `enumerated()`, so the result does not rely on
    `sorted` being stable).
- `app/Sources/FiggExport/ExportFile.swift`: `public enum ExportFile`.
  - `public static func suggestedName(for meeting: Meeting, pathExtension: String) -> String`.
    Takes `meeting.displayTitle`; maps each Unicode scalar that is `/`,
    `:`, `\` or of general category `Cc` (control, which includes `\n`,
    `\t`, `\r`) to `-`; trims leading and trailing U+0020 spaces and `.`;
    keeps the first 100 `Character`s; trims trailing spaces and dots again
    (the cut can expose one); falls back to `Meeting` when empty; appends
    `.` + `pathExtension`. The 100 limit is on the name before `.md`.
    Taking the extension as a parameter costs nothing and is what the
    later text and JSON slices of issue 78 need; this spec only calls it
    with `"md"`.
  - `public static func write(_ text: String, to url: URL) throws` does
    `try Data(text.utf8).write(to: url, options: .atomic)`. An atomic
    write replaces an existing file and never leaves a half-written one.
- `app/Tests/FiggExportTests/MarkdownExportTests.swift` and
  `app/Tests/FiggExportTests/ExportFileTests.swift`: Swift Testing suites
  with invented meetings (titles like "Weekly sync", lines like "We ship
  on Friday").

Changed:

- `app/Sources/Figg/ExportViews.swift`: adds `import UniformTypeIdentifiers`
  (as `BugReportView.swift` does), and `ExportMenu` adds
  `Button("Save as Markdown…") { save() }` right after "Copy for Slack".
  `save()` (on the main actor):
  1. `let lines = try model.store.transcript(meetingId: meeting.id)`; on
     error, `result = "Could not read the transcript: …"` and return.
     This uses the throwing store call rather than `model.transcript(_:)`,
     which turns an error into an empty array and would silently save a
     file without the transcript.
  2. `NSSavePanel` with `nameFieldStringValue =
     ExportFile.suggestedName(for: meeting, pathExtension: "md")`,
     `allowedContentTypes = [UTType(filenameExtension: "md", conformingTo: .plainText)]`
     (a non-optional dynamic type, so the panel never offers `.txt`),
     `canCreateDirectories = true`, run with `runModal()`.
  3. On `.OK` with a URL: `try ExportFile.write(MarkdownExport.document(meeting, lines: lines), to: url)`;
     on error, `result = "Could not save the file: \(error.localizedDescription)"`.
     On Cancel nothing happens.
  The view holds no formatting or naming logic.
- `docs/manual-test-checklist.md`: two lines under `## Share` for the
  click-through.

No external dependency is added, so no protocol is needed: the logic is
pure functions over `Meeting` and `TranscriptLine`, plus one file write
that the test drives against a temporary directory. `FiggExport` already
depends on `FiggStore`. No change to `Formatters`, `FiggConfig`,
`FiggStore` or `AppModel`.

## Alternatives considered

- **Extend `Formatters.markdown` with a transcript parameter.** Lost: the
  spec forbids changing its output, and a default parameter invites a
  later caller to change "Copy as Markdown" by accident. A separate type
  that calls it keeps the guarantee visible and tested.
- **SwiftUI `.fileExporter` with a `FileDocument`.** Lost: it needs a
  document type and moves the write into SwiftUI, where a test cannot
  reach it; the spec wants the write in `FiggExport` and tested. The
  `NSSavePanel` route matches the AppKit calls `ExportMenu` already makes
  (`NSPasteboard`, `NSWorkspace`).
- **Load the transcript in `MeetingView` and pass it to `ExportMenu`.**
  Lost: it changes another view, and reading on click gets the current
  lines (a recording in progress keeps adding them).
- **Put the file name rule inside `MarkdownExport`.** Lost: the name and
  write rules are the same for the coming text and JSON exports, and a
  separate file lets the two plan items build in parallel.

## Failure modes

| Case | What the user sees |
|---|---|
| Store read fails | Alert "Could not read the transcript: …"; no panel, no file |
| User cancels the panel | Nothing |
| Folder not writable, disk full, file locked | Alert "Could not save the file: …" with the system's reason; an existing file is left as it was (atomic write) |
| A file of that name exists | The save panel asks to replace it; on Replace the file is overwritten |
| Title that cleans to nothing (`...`, spaces only) | Suggested name `Meeting.md` |
| Untitled meeting | `displayTitle` is "Meeting <date, time>"; the `:` in the time becomes `-` |
| Name longer than the volume allows (APFS allows 255 bytes; 100 CJK characters are 300 UTF-8 bytes, and emoji take more) | Plausible for long non-Latin titles. The panel or the write reports the error, shown in the alert; the user can shorten the name. The spec's rule is in characters, so no byte cap is added (see Open questions) |
| No transcript yet (notes-only meeting) | File holds the notes only, no `## Transcript` heading |
| Recording still running | File holds the lines transcribed so far; saving again later replaces it |
| Very long meeting (thousands of lines) | One string built in memory and written once; a few hundred KB at most, no visible delay |
| Line text with Markdown characters (`*`, `#`) | Written as is; it sits after the bold prefix in a list item, so it cannot become a heading. A speaker name containing `*` could break the bold; accepted (names come from the app's own labels or a hand rename) |
| Notes end without a newline, or inside an unclosed code fence | With lines, the transcript starts after a blank line; inside an unclosed fence it would render as code. Accepted: the notes are not edited, by the spec's prefix rule |
| Trailing newline | With lines the file ends in `\n`; without lines it equals `Formatters.markdown` exactly, which may not. Accepted, so the no-lines case stays identical to Copy as Markdown |
| figg quits mid-write | Atomic write: either the old file or the new one, never half |

## Hard rules

1. Audio never leaves the Mac: not touched. No network call; the file is
   text only (title, date, notes, transcript), with no audio, screenshots
   or meeting folder paths.
2. No secrets on disk or in logs: not touched. Nothing is logged; the file
   holds no credentials.
3. No sampling params: not touched (no model call).
4. Build with `bundle.sh`: not touched; no new resources.
5. Keep logic testable: document, name and write logic live in
   `FiggExport` with unit tests; the view only runs the panel and shows
   the alert.
6. Settings in `FiggConfig`: not touched; no new setting, no
   UserDefaults (the save panel's last folder is AppKit's own behaviour,
   not a figg setting).

## Tests

All Swift Testing, run by CI's `test` job on macOS; nothing is built
locally. `FiggExportTests` already has top-level `notes` and `sample` in
`ExportTests.swift`, and P1 and P2 are built in parallel into the same
module, so each new test file declares its fixtures and helpers inside
its `@Suite` struct (or `private`), adds no top-level declarations and
does not reuse `notes` or `sample`. None asserts a formatted date string: date-bearing output is
compared to `Formatters.markdown(meeting)` computed in the same test.

`MarkdownExportTests` (`app/Tests/FiggExportTests/MarkdownExportTests.swift`):

- `startsWithCopyAsMarkdown`: for a meeting with enhanced notes and one
  with only user notes, each with lines,
  `document.hasPrefix(Formatters.markdown(m))`; with no lines,
  `document == Formatters.markdown(m)`.
- `transcriptSortedByStart`: lines given as 30 s, 5 s, 12 s give items in
  5, 12, 30 order under `## Transcript`, each exactly
  `- **[00:05] Me:** ...`; two lines with the same start keep their input
  order.
- `speakerUsesDisplayName`: a `.them` line with `speakerLabel: "Guest 1"`
  shows `Guest 1:`; a `.me` line with no label shows `Me:`.
- `timestamps`: 0, 59.9, 61, 3599, 3661 s give `00:00`, `00:59`, `01:01`,
  `59:59`, `1:01:01` in the items.
- `newlinesFlattened`: text `"a\nb\r\nc"` gives the item text `a b c` and
  the item is one line.
- `noTranscriptNoHeading`: no lines, no `## Transcript` in the document.

`ExportFileTests` (`app/Tests/FiggExportTests/ExportFileTests.swift`):

- `suggestedName` cases: `"Plan: Q3/Q4 \\ review"` gives
  `"Plan- Q3-Q4 - review.md"`; a title with `\t` and `\n` maps them to
  `-`; `"  ..Weekly sync..  "` gives `"Weekly sync.md"`; a 150 character
  title gives a 100 character stem plus `.md`; a cut that ends on a space
  is trimmed; `"..."` and `"   "` give `"Meeting.md"`; an untitled
  meeting's name has no `:`.
- `writeReplaces`: write "first" then "second" to the same URL in a fresh
  temporary directory; reading the file back as UTF-8 gives "second", and
  text with non-ASCII characters round-trips.

The Share menu item is proved by CI's `test` job building the `Figg`
target and by the manual checklist lines. Existing `FormatterTests` stay
unchanged and must pass.

## Open questions

- "Cut to at most 100 characters" is read as 100 characters before `.md`.
  If the limit was meant to include the extension, it is a one-number
  change in `ExportFile`.
- Should the name also be capped in UTF-8 bytes (for example 240), so a
  long non-Latin title never exceeds the 255-byte file name limit? It
  needs a spec change, so it is left to the human.

## Review notes

One critic round; no blockers. Changes made for its findings:

1. Parallel P1 and P2 could both add top-level test fixtures to
   `FiggExportTests` and clash on merge: fixtures now stay inside each
   suite (Tests section, and the Proved by line of P1 and P2).
2. Tie order on equal start times had no test: added to
   `transcriptSortedByStart`.
3. `UTType` needs `import UniformTypeIdentifiers`, and the `.plainText`
   fallback could offer `.txt`: import added, content type made
   `UTType(filenameExtension: "md", conformingTo: .plainText)`.
4. The long-name row understated the byte limit for non-Latin titles:
   reworded, and raised as an open question instead of adding a cap the
   spec does not ask for.
5. Trailing newline and an unclosed code fence in the notes: recorded as
   accepted in Failure modes.

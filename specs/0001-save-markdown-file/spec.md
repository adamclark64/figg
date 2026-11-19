# Save a meeting as a Markdown file

## Problem

figg can copy a meeting's notes to the clipboard as Markdown ("Copy as
Markdown" in the Share menu), but it cannot save them to a file, and the
copied text leaves out the transcript. Someone who keeps notes in a folder
of Markdown files has to paste into a new file by hand, and has no way to
keep the transcript next to the notes.

This is the first, narrow slice of issue 78 (file export to Markdown, text
or JSON). It is also the demo spec for the factory (issue 89).

## Intended outcome

The Share menu has a "Save as Markdown…" item. It opens a save panel with a
file name taken from the meeting title, and writes one `.md` file holding
the meeting's title, date, notes and, when there is one, the transcript
with a timestamp and speaker on each line. The file opens cleanly in any
Markdown editor. "Copy as Markdown" keeps working exactly as before.

## Constraints

- AGENTS.md hard rules apply. In particular: nothing here touches the
  network, and the file holds text only: no audio, no screenshots, no file
  paths from the meeting folder.
- The formatting and file-writing logic lives in `FiggExport` and is unit
  tested; `ExportViews.swift` only shows the save panel and calls it.
- `Formatters.markdown(_:)` (used by "Copy as Markdown") must not change
  its output.
- Tests must not depend on the machine's locale or time zone: they do not
  assert the formatted date string.
- No new settings, so no `FiggConfig` change.
- Test data is invented and neutral, never taken from a real meeting.
- figg only builds on macOS, so every criterion below is proved by a Swift
  Testing test or a CI job, never by a local run on Linux.

## Acceptance criteria

The tests named below live in `app/Tests/FiggExportTests/`.

- [ ] The document starts with exactly the text `Formatters.markdown(_:)`
  returns for the same meeting: title heading, date line, then the
  enhanced notes, or the user's own notes when there are no enhanced notes
  (proved by: a test comparing the two for a meeting with enhanced notes
  and one without)
- [ ] With transcript lines, the notes are followed by a `## Transcript`
  heading and one Markdown list item per line, in order of start time, of
  the form `- **[mm:ss] Speaker:** text` (proved by: a test with lines
  given out of order)
- [ ] The speaker is the line's display name, so renamed and diarized
  speakers ("Guest 1", a name set by hand) show as they do in the app
  (proved by: a test with a `speakerLabel` set and one without)
- [ ] Timestamps are the line's start, rounded down to whole seconds,
  as `mm:ss` under one hour and `h:mm:ss` from one hour on (proved by: a
  test covering 0 s, 59.9 s, 61 s, 3599 s and 3661 s)
- [ ] A transcript line containing a newline stays one list item: inner
  newlines become spaces (proved by: a test)
- [ ] A meeting with no transcript lines has no `## Transcript` heading
  (proved by: a test)
- [ ] The suggested file name is the meeting's display title with `/`,
  `:`, `\` and control characters replaced by `-`, leading and trailing
  spaces and dots trimmed, cut to at most 100 characters, and ending in
  `.md`; a title that is empty after cleaning gives `Meeting.md` (proved
  by: a test covering each case)
- [ ] Writing the document to a URL creates a UTF-8 file whose contents
  equal the document, replacing a file already there (proved by: a test
  writing twice into a temporary directory and reading the file back)
- [ ] The Share menu has a "Save as Markdown…" item that shows a save panel
  with the suggested name and writes the file through the tested code,
  and shows an alert if writing fails (proved by: the CI `test` job
  building the app; the click-through is added to
  `docs/manual-test-checklist.md` under Share)
- [ ] All existing tests pass unchanged, including `FormatterTests` (proved
  by: the CI `test` job)
- [ ] The final PR passes the CI `test` and `gates` jobs (proved by: CI)

## Out of scope

- Plain text and JSON export, and documenting a JSON shape (later slices of
  issue 78).
- Exporting several meetings at once, an export folder setting, or
  exporting automatically after Enhance.
- A File menu command or keyboard shortcut; the Share menu only.
- Screenshots or any attachment beside the Markdown file.
- Changing "Copy as Markdown" or "Copy for Slack".

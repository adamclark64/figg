# Plan: save a meeting as a Markdown file

P1 and P2 touch different files and can be built in parallel. P3 needs
both.

### P1. Build the Markdown document with the transcript

- Files: app/Sources/FiggExport/MarkdownExport.swift, app/Tests/FiggExportTests/MarkdownExportTests.swift
- Depends on: none
- Proved by: `MarkdownExportTests` (`startsWithCopyAsMarkdown`, `transcriptSortedByStart` with a tie case, `speakerUsesDisplayName`, `timestamps`, `newlinesFlattened`, `noTranscriptNoHeading`) in CI's `test` job, with `FormatterTests` unchanged and passing; the test file keeps its fixtures inside its `@Suite` (no top-level declarations, no reuse of `notes` or `sample`) so it merges cleanly beside P2

### P2. Suggest a file name and write the file

- Files: app/Sources/FiggExport/ExportFile.swift, app/Tests/FiggExportTests/ExportFileTests.swift
- Depends on: none
- Proved by: `ExportFileTests` (`suggestedName` cases, `writeReplaces` in a temporary directory) in CI's `test` job; the test file keeps its fixtures inside its `@Suite` (no top-level declarations, no reuse of `notes` or `sample`) so it merges cleanly beside P1

### P3. Add "Save as Markdown…" to the Share menu

- Files: app/Sources/Figg/ExportViews.swift, docs/manual-test-checklist.md
- Depends on: P1, P2
- Proved by: CI's `test` job building the `Figg` target with the new item, all existing tests passing, and CI's `gates` job; manual step: the two new lines under `## Share` in `docs/manual-test-checklist.md` (save a meeting with a transcript and open the file in a Markdown editor; save to a read-only folder and see the alert)

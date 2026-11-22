# Plan: show release notes in the update prompt

P1 and P3 touch different files and can be built in parallel. P2 needs
P1's `ReleaseNote` type. P4 needs P1 and P2.

### P1. Pick, cut and format the notes to show

- Files: app/Sources/FiggUpdate/ReleaseNotes.swift, app/Tests/FiggUpdateTests/ReleaseNotesTests.swift
- Depends on: none
- Proved by: `ReleaseNotesTests` (`coversVersionsAfterTheInstalledOne`, `ignoresVersionsNewerThanOffered`, `nilWhenNothingIsNewer`, `nilForNoNotes`, `nilForNonNumericVersions`, `cutsAtTheLimitOnALineBoundary`, `limitCountsRenderedTextNotURLs`, `cutsAnOverlongSingleLineAsPlainText`, `marksCutWhenTheFileDoesNotReachTheInstalledVersion`, `notCutWhenItFits`, `blocksSplitHeadingsBulletsParagraphs`, `inlineKeepsOnlyHttpsLinks`, `inlineDropsImages`, `inlineKeepsTheTextOfBadMarkdown`) in CI's `test` job; fixtures are invented and kept inside the `@Suite`

### P2. Read the notes from the version file

- Files: app/Sources/FiggUpdate/UpdateChecker.swift, app/Tests/FiggUpdateTests/UpdateCheckerTests.swift
- Depends on: P1
- Proved by: new `UpdateCheckerTests` (`parsesReleaseNotes`, `aVersionFileWithoutNotesHasNone`, `malformedNotesAreDropped`, `notesNeverMakeTheFileUnreadable`) in CI's `test` job, with every existing `UpdateCheckerTests` and `UpdateInstallerTests` test unchanged and passing

### P3. Publish the changelog notes in latest.json

- Files: app/scripts/changelog-notes.mjs, app/scripts/changelog-notes.test.mjs, app/scripts/publish-dmg-blob.mjs, .github/workflows/ci.yml, docs/release-signing.md
- Depends on: none
- Proved by: `node --test app/scripts/changelog-notes.test.mjs`, added as a step in CI's `gates` job and passing there (fixture cases for `sections`, `notesFor` and `feedFor`, including old field order, the published version first, a missing section throwing and a log line without note text, plus the repository's own `CHANGELOG.md` for the version in `.release-please-manifest.json`); `docs/release-signing.md` describes the `notes` field, reviewed on the final PR

### P4. Show the notes from the update banner

- Files: app/Sources/Figg/ReleaseNotesView.swift, app/Sources/Figg/AppModel.swift, app/Sources/Figg/MainView.swift, docs/manual-test-checklist.md, AGENTS.md
- Depends on: P1, P2
- Proved by: CI's `test` job building the `Figg` target, all tests passing, and CI's `gates` job; manual steps added under `## Updates` in `docs/manual-test-checklist.md` (an offer with notes shows "What's new", the sheet lists every version since the installed one newest first, a link opens in the browser only when clicked, "Update now" in the sheet installs as the banner does, a long changelog shows "See the full changelog", the sheet closes when a newer update replaces its banner, and an offer from a `latest.json` without `notes` shows the banner exactly as before)

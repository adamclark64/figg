# Design: show release notes in the update prompt

## Summary

The release job already checks out the repository, so `CHANGELOG.md` is on
the runner when `publish-dmg-blob.mjs` writes `latest.json`. A new script
module, `app/scripts/changelog-notes.mjs`, cuts the changelog into
per-version sections and returns the published version's section plus the
sections of up to 14 older versions, newest first. The publish script adds
them to `latest.json` as a new `notes` array of `{version, text}` objects,
and fails before signing or uploading anything when the published version
has no section. In the app, `UpdateChecker` decodes `notes` separately from
the required fields and leniently, so missing or malformed notes give a
`ReleaseInfo` with no notes and never stop an update. A new pure type,
`ReleaseNotes` in `FiggUpdate`, picks the entries newer than the installed
version and not newer than the offered one, sorts them newest first, cuts
them to a length limit, splits each into headings, bullets and paragraphs,
and turns inline Markdown into an `AttributedString` with only `https`
links kept. The update banner gains a "What's new" button when there are
notes; it opens a sheet that shows them as text, with "See the full
changelog" when anything was cut, and the same "Update now" the banner has.
With no notes the banner is exactly today's.

## Types and files

### Release side (Node, runs on the release runner)

New `app/scripts/changelog-notes.mjs`, no dependencies, ES module:

- `export function sections(changelog: string): {version, text}[]` splits
  on lines matching `^## \[?(\d+\.\d+\.\d+)\]?` (release-please writes
  `## [0.19.2](compare-url) (date)`; the oldest entries are `## 0.4.0`).
  `text` is everything up to the next `## ` line, with the heading line
  removed and surrounding blank lines trimmed. A version heading that
  appears twice throws (two sections for one version would make "the
  offered version's notes" ambiguous).
- `export function notesFor(changelog, version, { max = 15 } = {})`
  returns `sections()` filtered to versions at or below `version`
  (numeric compare, not file order), dropping empty texts of older
  versions, sorted newest first, first `max` kept. Throws
  `no CHANGELOG.md section for <version>` when that exact version has no
  section or its text is empty. The first entry is therefore always the
  published version.
- Older versions are included so a user several releases behind sees
  every change (spec outcome 2). Fifteen covers months of releases and
  keeps the file small (today's changelog sections average a few hundred
  bytes).

New `app/scripts/changelog-notes.test.mjs` (`node:test`, `node:assert`):
invented fixture changelogs plus one run against the repository's own
`CHANGELOG.md` for the version in `.release-please-manifest.json`.

Changed `app/scripts/publish-dmg-blob.mjs`:

- Right after the argument checks and before reading the dmg, reads
  `CHANGELOG.md` at `new URL("../../CHANGELOG.md", import.meta.url)` (so it
  works from any working directory) and calls `notesFor`. On any error
  prints `not published: <message>` and exits 1. Nothing is signed or
  uploaded, and the `latest.json` already in the store stays as it was.
- The feed becomes
  `{version, dmg_url, size, signature, notes}`. Field order keeps the old
  four first. The closing log line prints the feed without `notes` plus
  `notes for N versions (newest X)`, so the log stays readable.

Changed `.github/workflows/ci.yml`: one step in the existing Linux `gates`
job, `node --test app/scripts/changelog-notes.test.mjs` (ubuntu-latest
ships Node with `node:test`). This is the CI check the acceptance
criterion asks for, and it runs on every PR, so a changelog edit that
breaks extraction is caught before a release rather than during one.

The release workflows themselves do not change: `release-please.yml`'s
`publish` job and `publish-dmg-blob.yml` both check out the repository and
run the publish script from `app/`, so the changelog is already there.
When `publish-dmg-blob.yml` republishes an old tag from `main`, the newer
sections in `main`'s changelog are filtered out by the version compare.

### App side (Swift)

New `app/Sources/FiggUpdate/ReleaseNotes.swift`:

```swift
/// One version's notes as the version file carried them.
public struct ReleaseNote: Equatable, Sendable {
    public var version: String   // "0.19.2", no leading v
    public var text: String      // that version's CHANGELOG.md section, Markdown
}

/// The notes to show for one offered update: the versions after the
/// installed one up to the offered one, newest first, cut to a limit.
public struct ReleaseNotes: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var version: String
        public var blocks: [Block]
    }
    public enum Block: Equatable, Sendable {
        case heading(String)     // "### Bug Fixes" -> "Bug Fixes"
        case bullet(String)      // "* **x:** y" -> "**x:** y" (still inline Markdown)
        case paragraph(String)
    }
    public var sections: [Section]
    /// True when text was dropped by the limit, or when the versions in the
    /// file may not reach back to the installed one.
    public var isCut: Bool

    public static let fullChangelog = URL(string: "https://github.com/adamclark64/figg/blob/main/CHANGELOG.md")!
    public static let defaultLimit = 6_000   // characters of note text

    public static func covering(_ notes: [ReleaseNote], installed: String,
                                offered: String, limit: Int = defaultLimit) -> ReleaseNotes?
    static func blocks(_ text: String) -> [Block]
    public static func inline(_ markdown: String) -> AttributedString
}
```

- `covering` keeps entries where `UpdateChecker.isNewer(v, than: installed)`
  and `!UpdateChecker.isNewer(v, than: offered)`, keeps the first entry of
  a repeated version, sorts newest first with `isNewer`, and returns nil
  when nothing is left (the prompt then looks as it does today). A non-
  numeric installed or offered version yields nil, matching `isNewer`'s
  "a broken version can only suppress, not nag" rule.
- The cut: walk sections newest first, adding each section's text length.
  When the next section would pass `limit`, keep its lines up to the last
  whole line that fits (a single line longer than the limit is cut at the
  limit and ends with an ellipsis), drop everything after, set `isCut`.
  The offered version's first line is always kept, so a cut never shows
  an empty sheet.
- `isCut` is also set when the file had entries but none at or below the
  installed version and the file held 15 or more entries: the user is
  further behind than the file reaches, so older changes are not shown
  and the "full changelog" link says so. (With fewer than 15 entries the
  file holds the whole changelog, so nothing is missing.)
- `blocks` reads line by line: `#`-prefixed lines become `heading` with
  the hashes stripped, lines starting `* `, `- ` or `+ ` (after leading
  spaces) become `bullet`, blank lines are skipped, anything else is a
  `paragraph`. No HTML or block Markdown beyond that is interpreted.
- `inline` uses `AttributedString(markdown:options:)` with
  `.inlineOnlyPreservingWhitespace` and
  `failurePolicy: .returnPartiallyParsedIfPossible`, falling back to
  `AttributedString(markdown)` (plain) if it throws. It then removes the
  `link` attribute from every run whose URL scheme is not `https`, and
  removes every `imageURL` attribute, so an image is shown as its alt
  text and nothing is ever fetched. HTML stays literal text.

Changed `app/Sources/FiggUpdate/UpdateChecker.swift`:

- `ReleaseInfo` gains `public var notes: [ReleaseNote]`, defaulting to
  `[]` in the init, so existing callers and tests compile unchanged and
  `Equatable` still holds.
- `latest()` keeps the current strict `Feed` decode for the required
  fields (that is what installed copies do, and what decides whether an
  update is offered). A second decode, `try? JSONDecoder().decode(NotesFeed.self, from: data)`,
  reads `notes` with `decodeIfPresent` into an array of lossy elements
  (each element decodes `{version: String, text: String}` or becomes nil).
  Any failure (wrong type, not an array) gives `[]`. Entries keep only a
  numeric version (leading `v` dropped) and a non-blank text. The doc
  comment's example feed gains the `notes` field.
- Verification is untouched: `UpdateInstaller` and `UpdateVerifier` never
  read `notes`.

New `app/Tests/FiggUpdateTests/ReleaseNotesTests.swift`; new tests in
`app/Tests/FiggUpdateTests/UpdateCheckerTests.swift`.

New `app/Sources/Figg/ReleaseNotesView.swift`: `ReleaseNotesSheet`, a thin
view. Title "What's new in figg v<offered>"; a `ScrollView` with one group
per section ("v0.19.2" in the display font, then its blocks: headings
semibold, bullets with a "•", paragraphs as `Text(ReleaseNotes.inline(..))`
with `.textSelection(.enabled)`); when `isCut`, a
`Link("See the full changelog", destination: ReleaseNotes.fullChangelog)`.
Buttons "Later" (cancel, closes) and "Update now" (default action). SwiftUI
opens a `Text` link through the environment's `openURL`, which hands it to
the default browser, and only on click.

Changed `app/Sources/Figg/AppModel.swift`: `Banner` gains
`var releaseNotes: ReleaseNotes?`. `showUpdateBanner(_:)` fills it with
`ReleaseNotes.covering(release.notes, installed: UpdateManager.currentVersion ?? "", offered: release.version)`,
so the notes always belong to the version the banner names. No other
banner sets it.

Changed `app/Sources/Figg/MainView.swift`: in `BannerStack`, a banner with
`releaseNotes` shows a borderless "What's new" button before its action
button; it sets a `@State` banner id that presents `ReleaseNotesSheet`.
The sheet's "Update now" runs the same `model.perform(.installUpdate)` and
`model.dismiss(banner)` as the banner's button, so recording guards and the
pending-update path are unchanged. A banner without notes renders exactly
as today.

Docs: `docs/release-signing.md` documents `notes` (shape, that it is not
signed, that the app treats it as display text only, and that the publish
step fails without a changelog section); `docs/manual-test-checklist.md`
gains steps under `## Updates`; the "In-app updates" row in AGENTS.md's
"Where to look" adds `ReleaseNotes.swift`, `ReleaseNotesView.swift` and
`changelog-notes.mjs`.

## Alternatives considered

- **One `notes` string for the offered version only.** Simpler, but a user
  three releases behind would see only the last one, which the spec rules
  out.
- **A pre-merged string covering many versions.** The script cannot know
  which version each user runs, so the app has to choose; per-version
  entries let it.
- **Fetching the GitHub release body or `CHANGELOG.md` from GitHub.** A
  second request and GitHub's rate limits; the spec requires the notes to
  ride in the version file.
- **Rendering with a full Markdown engine or a `WKWebView`.** A web view
  can load remote content and run script; a full block renderer is far
  more surface than headings, bullets and links need. `AttributedString`
  inline Markdown plus a three-kind line splitter covers what
  release-please writes.
- **Showing the notes inline in the banner.** Banners are one line in a
  stack above the content; a long list there would push the meeting off
  screen. A sheet opened on demand leaves the banner as it is today.
- **Signing the notes with the dmg.** Would change the signature format
  every installed copy checks (out of scope), and the notes cannot change
  what is installed anyway.
- **Cutting the notes in the publish script.** The spec puts the cut and
  its visible marker in the app; the script limits only the number of
  versions, so a long release is still carried in full and the app
  decides how much fits.

## Failure modes

| What happens | What the user sees |
|---|---|
| `latest.json` has no `notes` (published before this change, or republished by an old script) | Banner as today, no "What's new" button. |
| `notes` is the wrong type, or some entries are malformed | Malformed entries dropped; if none survive, banner as today. Update still offered and installs. |
| Notes are huge | Sheet shows the newest notes up to 6,000 characters and "See the full changelog". |
| User is more versions behind than the file covers | Sheet shows what the file has and "See the full changelog". |
| An entry's version is newer than the offered one (bad publish) | Entry ignored by `covering`. |
| Notes contain `javascript:`, `file:`, `http:` links, images or HTML | Shown as plain text (link removed, image as alt text, HTML literal). |
| Notes contain an `https` link | Underlined; opens in the default browser only when clicked. |
| Markdown fails to parse | Line shown as plain text. |
| Installed build has no version (dev build) | No update is offered at all today, so no notes either. |
| Release has no `CHANGELOG.md` section for its version | `publish` job fails with `not published: no CHANGELOG.md section for X.Y.Z`; nothing uploaded, users keep being offered the previous release. Fix the changelog and run "publish dmg to blob" for the tag. |
| Changelog has a version heading twice | Same as above, with a message naming the version. |
| Someone with the store token edits the notes | They can change the text shown, never what is installed: the dmg signature and the version check after mounting are unchanged. Links stay `https` and open only on click. |

## Hard rules

1. Audio never leaves the Mac: not touched; the only request is the
   existing anonymous `GET latest.json`, now a little larger.
2. No secrets on disk or in logs: no new secret; the publish log prints
   the feed without notes, as today it prints the feed; nothing new is
   logged in the app.
3. No sampling params: not touched (no model call; the notes are shown as
   the changelog wrote them).
4. Build with `bundle.sh`: not touched.
5. Keep logic testable: parsing, picking, cutting and inline formatting
   live in `FiggUpdate` behind the existing `HTTPClient`; extraction is a
   pure Node function tested with `node:test`; the two views only lay out.
6. Settings in `FiggConfig`: no setting is added.

## Tests

CI's `test` job (macOS) runs the Swift tests; CI's `gates` job (Linux)
runs the Node test. Nothing is built locally.

| Acceptance criterion | Proved by |
|---|---|
| Parses a file with notes; `ReleaseInfo` exposes them | `UpdateCheckerTests.parsesReleaseNotes` (`FakeHTTP` body with two entries, `v` prefix dropped) |
| No notes / malformed notes still give a `ReleaseInfo` with no notes and the update is offered | `UpdateCheckerTests.aVersionFileWithoutNotesHasNone`, `malformedNotesAreDropped` (`notes` as a string, as an object, entries missing `text`, numeric `version`, blank text, one good entry among bad ones), each also checking `version`, `dmgURL` and `signature` are unchanged; `UpdateCheckerTests.notesNeverMakeTheFileUnreadable` (a 1 MB `text`) |
| Several releases behind: every version after installed up to offered, newest first, excluding installed and older | `ReleaseNotesTests.coversVersionsAfterTheInstalledOne` (installed 0.17.0, offered 0.19.2, entries 0.16.0 to 0.20.0 shuffled: expects 0.19.2, 0.19.1, 0.19.0, 0.18.0), `ignoresVersionsNewerThanOffered`, `nilWhenNothingIsNewer`, `nilForNonNumericVersions` |
| Notes over the limit are cut and the cut is visible | `ReleaseNotesTests.cutsAtTheLimitOnALineBoundary` (`isCut` true, kept text at most the limit, ends on a whole line), `cutsAnOverlongSingleLine`, `marksCutWhenTheFileDoesNotReachTheInstalledVersion`, `notCutWhenItFits`; the sheet shows "See the full changelog" whenever `isCut` (manual step) |
| Publish writes the offered version's notes from `CHANGELOG.md` and fails without a section | `changelog-notes.test.mjs`: release-please and bare headings, newest-first order by version not file order, `max`, newer versions excluded, missing section throws, empty section throws, duplicate heading throws, and the repository's `CHANGELOG.md` yields a first entry equal to `.release-please-manifest.json`'s version |
| Prompt shows notes when present, unchanged when absent | Manual steps in `docs/manual-test-checklist.md`; plus `ReleaseNotesTests.blocksSplitHeadingsBulletsParagraphs`, `inlineKeepsOnlyHttpsLinks`, `inlineDropsImages`, `inlineFallsBackToPlainText` for what the sheet renders |
| `latest.json` field documented | `docs/release-signing.md`, reviewed on the final PR |

Existing `UpdateCheckerTests` (including `fieldsThisVersionDoesNotKnowAreIgnored`)
and `UpdateInstallerTests` stay unchanged and passing, which shows the
strict decode installed copies use still accepts the new file.

## Open questions

None that block the build. The limit (6,000 characters) and the version
count (15) are judgement calls and easy to change later.

## Review notes

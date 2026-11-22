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

- `export function sections(changelog: string): {version, text}[]`: every
  line starting `## ` ends the section before it. A `## ` line matching
  `^## \[?(\d+\.\d+\.\d+)\]?` starts a version section (release-please
  writes `## [0.19.2](compare-url) (date)`; the older entries, `## 0.6.0`
  down to `## 0.0.1`, are bare). Any other `## ` section (for example
  `## Unreleased`) is ignored. `text` is the lines after the heading up to
  the next `## ` line, with surrounding blank lines trimmed.
- `export function notesFor(changelog, version, { max = 15 } = {})`
  returns `sections()` filtered to versions at or below `version`
  (numeric compare, not file order), dropping empty texts of older
  versions, sorted newest first, first `max` kept. A repeated version keeps
  its first occurrence, except that it throws when the repeated version is
  one of those emitted (that is where it would make the notes ambiguous),
  so an old duplicate outside the window never blocks a release. Throws
  `no CHANGELOG.md section for <version>` when that exact version has no
  section or its text is empty. The first entry is therefore always the
  published version.
- `export function feedFor({ version, dmgURL, size, signature, changelog })`
  returns `{ feed, logLine }` or throws (from `notesFor`). `feed` is the
  exact JSON text uploaded, with the old four fields first and in today's
  order, then `notes`. `logLine` is the feed without `notes` plus
  `notes for N versions (newest X)`. Keeping this pure is what lets the
  wiring be tested without `@vercel/blob` or a real release.
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
  works from any working directory) and calls `notesFor` once as a check.
  On any error prints `not published: <message>` and exits 1. Nothing is
  signed or uploaded, and the `latest.json` already in the store stays as
  it was.
- After the dmg uploads, builds the version file with `feedFor` and
  uploads `feed`, printing `logLine` (so the log stays readable and holds
  no note text). The feed becomes `{version, dmg_url, size, signature, notes}`.

Changed `.github/workflows/ci.yml`: one step in the existing Linux `gates`
job, `node --test app/scripts/changelog-notes.test.mjs` (ubuntu-latest
ships Node with `node:test`). This is the CI check the acceptance
criterion asks for. It guards hand edits to the changelog and the
extraction code. It does not run on release-please's own Release PR
(opened with `GITHUB_TOKEN`, which starts no workflows), so a new
version's section is first checked by the `publish` job itself, which
fails loudly before publishing anything, as the spec requires.

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
- The cut counts what the user reads, not Markdown source: each line's
  length is the character count of its rendered `inline(...)` text, so
  the issue and commit URLs release-please puts on every bullet do not use
  up the budget. Walk sections newest first, line by line; when the next
  line would pass `limit`, drop it and everything after and set `isCut`.
  Lines are kept or dropped whole, so a cut never leaves half a
  `[x](https://...` showing. The offered version's first line is always
  kept; if that one line alone passes the limit it is shown as plain text
  (formatting dropped) cut at the limit with an ellipsis, so a cut never
  shows an empty sheet or broken link syntax.
- `isCut` is also set when no entry in the file is at or below the
  installed version: the user is further behind than the file reaches
  (15 versions), so older changes are not shown and the "full changelog"
  link says so. This needs no knowledge of the script's window size. It
  can also show the link when malformed entries were dropped, the safe
  direction.
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
as today. The sheet's binding is true only while its banner id is still in
`model.banners`: when an automatic check replaces the update banner with
one for a newer version, the sheet closes, so "Update now" in the sheet
can never install a version whose notes it did not show.

Settings' `UpdateStatusView` ("Update to vX" in Settings > Recording) is
deliberately unchanged: the spec asks for notes in the update prompt, which
is the banner.

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
| Notes are huge | Sheet shows the newest notes up to 6,000 rendered characters and "See the full changelog". |
| A newer update is found while the sheet is open | The banner is replaced and the sheet closes; the new banner's "What's new" shows the new notes. |
| User is more versions behind than the file covers | Sheet shows what the file has and "See the full changelog". |
| An entry's version is newer than the offered one (bad publish) | Entry ignored by `covering`. |
| Notes contain `javascript:`, `file:`, `http:` links, images or HTML | Shown as plain text (link removed, image as alt text, HTML literal). |
| Notes contain an `https` link | Underlined; opens in the default browser only when clicked. |
| Markdown fails to parse | Line shown as plain text. |
| Installed build has no version (dev build) | No update is offered at all today, so no notes either. |
| Release has no `CHANGELOG.md` section for its version | `publish` job fails with `not published: no CHANGELOG.md section for X.Y.Z`; nothing uploaded, users keep being offered the previous release. Fix the changelog and run "publish dmg to blob" for the tag. |
| Changelog repeats a version inside the 15 published | Same as above, with a message naming the version. A repeat outside the window keeps its first occurrence and publishes. |
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
| Several releases behind: every version after installed up to offered, newest first, excluding installed and older | `ReleaseNotesTests.coversVersionsAfterTheInstalledOne` (installed 0.17.0, offered 0.19.2, entries 0.16.0 to 0.20.0 shuffled: expects 0.19.2, 0.19.1, 0.19.0, 0.18.0), `ignoresVersionsNewerThanOffered`, `nilWhenNothingIsNewer`, `nilForNoNotes`, `nilForNonNumericVersions` |
| Notes over the limit are cut and the cut is visible | `ReleaseNotesTests.cutsAtTheLimitOnALineBoundary` (`isCut` true, rendered text at most the limit, only whole lines kept), `limitCountsRenderedTextNotURLs` (bullets with long link URLs all fit), `cutsAnOverlongSingleLineAsPlainText`, `marksCutWhenTheFileDoesNotReachTheInstalledVersion`, `notCutWhenItFits`; the sheet shows "See the full changelog" whenever `isCut` (manual step) |
| Publish writes the offered version's notes from `CHANGELOG.md` and fails without a section | `changelog-notes.test.mjs`: release-please and bare headings, a non-version `## Unreleased` section ignored and ending the section before it, newest-first order by version not file order, `max`, newer versions excluded, missing section throws, empty section throws, a duplicate inside the window throws and one outside it does not; `feedFor` keeps the old four fields first with today's values, puts the published version first in `notes`, throws without a section, and its `logLine` holds no note text; and the repository's `CHANGELOG.md` yields a first entry equal to `.release-please-manifest.json`'s version |
| Prompt shows notes when present, unchanged when absent | Manual steps in `docs/manual-test-checklist.md` (including the sheet closing when a newer update replaces the banner); plus `ReleaseNotesTests.nilForNoNotes`, `blocksSplitHeadingsBulletsParagraphs`, `inlineKeepsOnlyHttpsLinks`, `inlineDropsImages`, `inlineKeepsTheTextOfBadMarkdown` for what the sheet renders. The plain-text fallback when `AttributedString(markdown:)` throws is hard to trigger with `.returnPartiallyParsedIfPossible` and is left untested |
| `latest.json` field documented | `docs/release-signing.md`, reviewed on the final PR |

Existing `UpdateCheckerTests` (including `fieldsThisVersionDoesNotKnowAreIgnored`)
and `UpdateInstallerTests` stay unchanged and passing, which shows the
strict decode installed copies use still accepts the new file.

## Open questions

None that block the build. The limit (6,000 rendered characters) and the
version count (15) are judgement calls and easy to change later.

## Review notes

The design-critic found no blockers in one round (one major, nine minor);
all were taken:

- Major: the publish wiring was untested. Feed assembly moved into the pure
  `feedFor` in `changelog-notes.mjs`, tested in `gates`.
- The sheet now closes when a newer update replaces its banner.
- `isCut` no longer hard-codes the script's 15-version window.
- A duplicate changelog heading outside the published window no longer
  blocks a release.
- Corrected the claim that CI catches a release's missing section; the
  `publish` job is where that fails.
- The untestable markdown-throws fallback test was replaced and the gap
  stated.
- Corrected the heading example; non-version `## ` sections are ignored.
- The limit counts rendered text, and cuts keep whole lines only.
- Added `nilForNoNotes`.
- Stated that Settings' "Update to vX" button is unchanged.

No second round was run, since round one found no blocker.

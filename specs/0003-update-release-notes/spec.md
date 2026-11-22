# Show release notes in the update prompt

## Problem

When figg finds a newer version, the update banner says only "figg vX.Y.Z
is available." with an Update button. The user cannot see what changed
without leaving the app for GitHub, so they cannot tell whether the update
fixes something they care about or is worth a relaunch right now. Issue
131.

The notes already exist: release-please writes each version's section of
`CHANGELOG.md` from the Conventional Commit subjects. They just never reach
the app. The version file the app reads (`latest.json`, written by
`app/scripts/publish-dmg-blob.mjs`) carries only the version, the dmg's URL
and size, and its signature.

## Intended outcome

- When an update is offered, the user can read that release's notes from
  the update prompt before choosing Update: the features and fixes, as the
  changelog lists them, readable without opening a browser.
- A user who skipped releases sees the notes of every version newer than
  the one they run, newest first, up to the one offered, so nothing that
  changed is hidden.
- If a release has no notes (an older version file, or notes that could
  not be read), the prompt looks and works exactly as it does today.

## Constraints

- AGENTS.md hard rules apply.
- The notes travel in the version file the app already fetches, not from
  the GitHub API, so the check still never depends on GitHub's rate limits
  and still makes one anonymous request.
- The change to `latest.json` is additive. Copies of figg already installed
  must still parse the new file and still be offered and install the
  update as before.
- The notes are untrusted text from the network. They are shown as text
  (simple formatting such as headings, bullets and links is fine); nothing
  in them is run, loaded (no remote images) or allowed to change what is
  installed. Links open in the user's browser only when clicked.
- The notes never affect update verification: the signature still covers
  the dmg, and an update with missing, empty or oversized notes is offered
  and installed exactly as one without notes. Oversized notes are cut to a
  sensible length rather than refused.
- The release workflow fails loudly rather than publishing a version file
  with notes for the wrong version.
- Logic (parsing the feed, picking which versions' notes to show, trimming)
  lives in `FiggUpdate` with Swift Testing tests; views stay thin.
- No new setting is needed; if one is added it goes in `FiggConfig`.

## Acceptance criteria

- [ ] `UpdateChecker` parses a version file that carries release notes, and
  `ReleaseInfo` exposes them (proved by: Swift Testing test with `FakeHTTP`).
- [ ] A version file without notes, and one with malformed notes, still
  parses into a `ReleaseInfo` with no notes, and the update is still
  offered (proved by: Swift Testing tests).
- [ ] When the installed version is several releases behind, the notes
  shown cover every version after it up to the offered one, newest first,
  and exclude the installed version and older (proved by: Swift Testing
  test).
- [ ] Notes longer than the limit are cut, and the cut is visible to the
  user (for example "See the full changelog") (proved by: Swift Testing
  test).
- [ ] The release publishing step writes the offered version's notes, taken
  from that version's section of `CHANGELOG.md`, into `latest.json`, and
  fails if that section is missing (proved by: a test or CI check that runs
  the extraction against the repository's `CHANGELOG.md`).
- [ ] The update prompt shows the notes when present and is unchanged when
  absent (proved by: manual step added to `docs/manual-test-checklist.md`).
- [ ] `docs/release-signing.md` (or wherever `latest.json` is described)
  documents the new field (proved by: review on the final PR).

## Out of scope

- A "What's new" screen after the update has installed.
- Notes for the in-app Check for Updates "up to date" result.
- Translating, summarising or rewriting the notes with a model: they are
  shown as the changelog wrote them.
- Changing how updates are downloaded, verified or installed, or how often
  figg checks.
- Back-filling notes into version files of releases already published.

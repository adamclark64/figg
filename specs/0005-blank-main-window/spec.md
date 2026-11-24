# The main window always draws on launch

## Problem

On one Mac running macOS 26.5.2, figg 0.22.1 opens its main window and
shows nothing in it: at its minimum size, dark, with a toolbar strip but
no Record button, no sidebar, no empty state and no banner. Deleting the
app and installing it fresh did not help. The same build draws normally on
macOS 26.2. The report was filed from a different Mac, so whether the
affected copy's menu bar and main thread still respond is not known.
Reported in #151.

The cause is not known yet. Nothing in the 0.22.1 change (the Calendars
permission row) obviously blanks a window, and no one can reproduce it on
a development Mac. A reinstall keeps everything under
`~/Library/Application Support/figg` (config.yaml, the database, the
permission state files) and macOS's saved window state, so either that
state or something on the launch path that differs on macOS 26.5 is the
likely trigger. Today figg gives no way to tell which: the window is just
empty and the bug report carries only versions.

Open question for the design: whether the main thread is stuck (the window
never gets its first frame) or the window draws and its content is empty.
The design should handle both.

## Intended outcome

- On launch the main window shows the sidebar and the empty state (or the
  last meeting) within a few seconds, on any supported macOS, whatever is
  in figg's data folder.
- If part of startup is slow or fails (opening the database, its
  migrations, loading the meeting list, the permission and signer checks,
  setting up the calendar, the transcriber or the meeting watcher), the
  window still draws, and a banner says which part failed and what to do.
- When something still goes wrong, a bug report says how far startup got,
  so the next report points at the cause instead of just "blank".

## Constraints

- AGENTS.md hard rules apply.
- Startup stage names in a bug report are fixed labels chosen by figg (for
  example `store-opened`), never paths, file contents, meeting titles,
  calendar data or log lines. Reports stay limited to user text,
  screenshots and app state of that kind.
- No change to the database schema or to config.yaml fields beyond what a
  fix strictly needs; any new field follows hard rule 6.
- Existing users' data folders must keep working; nothing is deleted or
  reset to make the window draw.
- This is an urgent fix: keep it small enough to ship as a patch release.

## Acceptance criteria

- [ ] Nothing on the launch path that can wait on disk, a lock, the
  system or the network runs synchronously on the main thread before the
  main window's first frame; each such step is moved off it or bounded by
  a timeout (proved by: Swift Testing tests of the startup sequence with
  fakes that never return, showing the model reaches a drawable state).
  One exception: opening the database, its migrations and the first
  meeting list load stay synchronous, since they already fail fast on a
  lock and fall back with a banner, and moving them is too big for a
  patch; their stages are recorded so a report would show a stall there
- [ ] A step that throws or times out during startup leaves the app with a
  visible banner naming the step, not an empty window (proved by: Swift
  Testing test per step with a failing fake)
- [ ] figg records the last startup stage it reached, and "Report a Bug"
  includes it in the Context section next to the versions (proved by: a
  Swift Testing test of the report text)
- [ ] Opening figg with a data folder copied from an earlier version, and
  with an empty one, shows the sidebar (proved by: manual step in
  `docs/manual-test-checklist.md`, run on macOS 26.5 where possible)
- [ ] CI's `test` job passes

## Out of scope

- Redesigning the main window or the onboarding flow.
- Sending logs, crash reports or any data beyond the startup stage label
  with bug reports.
- Changes to recording, transcription, the model providers or exports
  beyond moving their setup off the main thread at launch.
- Fixing causes that are found only on other macOS versions, unless they
  share the same fix.

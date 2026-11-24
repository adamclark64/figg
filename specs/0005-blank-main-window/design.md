# Design: the main window always draws on launch

## Summary

The cause in #151 is unknown, so the fix has two halves. First, take
everything that can wait on the system off the main thread before the
first frame, and run the rest of startup as a sequence of named steps with
timeouts, after the window has drawn. Second, record which startup stage
figg reached (and whether the main thread stalled there) in a small state
file, and put that one label in bug reports, so a repeat of #151 names the
step.

The strongest suspect is the permission check. `PermissionCenter.shared`
is created inside `AppModel.init` (via `checkAtLaunch`) and calls
`SystemPermissions.status` for every permission synchronously on the main
thread: TCC preflight through the private framework, `AXIsProcessTrusted`,
`CGPreflightScreenCaptureAccess`, and since 0.22.1
`EKEventStore.authorizationStatus`. Each is a round trip to a system
daemon. If one of them blocks on macOS 26.5, the main window never gets
its first frame, which matches an app whose menu bar still works.

## Types and files

New target `FiggStartup` (library, no dependencies but Foundation), with
`FiggStartupTests`:

- `StartupStage`: fixed string labels, in order: `launched`,
  `store-opened`, `meetings-loaded`, `window-drawn`, `permissions-read`,
  `services-started`, `ready`. Only these labels are ever written or
  reported.
- `StartupLog`: owns `startup-stage.txt` in the data folder (state, not a
  setting, like `last-signer.txt`). `begin()` moves the previous launch's
  record aside into memory and starts a new one; `reached(_:)` overwrites
  the file with the stage; `stalled(at:seconds:)` marks a stall.
  `summary` gives one line for a report, e.g.
  `this launch: ready; last launch: stalled at window-drawn for 12 s`.
  Writes are best effort (`try?`), never thrown into startup.
- `StallDetector`: pure logic. Fed main-thread heartbeats and the current
  time, it says when the gap exceeds a threshold (3 s) and for how long.
  The app drives it from a background `DispatchSourceTimer` that reads a
  heartbeat stamp set by a main-queue timer; a lock guards the stamp.
- `StartupSequence`: runs named async steps in order, each under a
  timeout (default 10 s). A step that throws or times out is reported
  through an `onFailure(name, reason)` callback and the sequence moves on.
  A timed-out step keeps running in the background; it is not cancelled
  forcibly, only no longer awaited.

Changed:

- `FiggPermissions/SystemPermissions.swift`: add
  `nonisolated static func statuses() async -> [Permission: PermissionStatus]`
  that reads every status on a detached task.
- `Figg/PermissionsView.swift` (`PermissionCenter`): `init` no longer reads
  anything. `refresh()` becomes `async` and awaits `statuses()`, with a
  guard so overlapping refreshes (the 1 s tick in the Permissions tab)
  coalesce into one in flight. `checkAtLaunch()` becomes `async`.
  `missing` reads as empty until the first read finishes, so nothing opens
  the Permissions screen from a stale empty state; `checkAtLaunch` only
  decides after its own read.
- `Figg/AppModel.swift`: `init` keeps the cheap state (settings, store,
  queue, banners, `reloadMeetings`) and records stages. Everything else
  moves into `finishLaunch()`: permission check, meeting watcher,
  recording widget, calendar watch, model-on-disk check and load,
  crash recovery, update checks. `finishLaunch()` runs them through
  `StartupSequence`; a failure appends a warning banner
  "figg could not finish starting: <step> did not respond. Some features
  may not work until you reopen figg." `finishLaunch()` runs once.
- `Figg/MainView.swift`: `.task { await model.finishLaunch() }` on the
  root view, after recording `window-drawn` in `.onAppear`.
- `Figg/FiggApp.swift` (`AppDelegate`): starts `StartupLog.begin()` and
  the stall watchdog in `applicationDidFinishLaunching`; the watchdog
  stops at `ready` plus 10 s.
- `Figg/BugReportView.swift`: adds `extra["startup"] = startupLog.summary`.
- `docs/manual-test-checklist.md`: the manual launch checks.
- `AGENTS.md`: "Where to look" row for startup and a Known gaps note.

The store open stays synchronous in `init`. GRDB's default busy mode fails
at once on a locked database rather than waiting, and `AppModel` already
falls back to an in-memory store with an error banner, so it cannot hold
the first frame for long. Its stage is recorded so a report would show it.

## Alternatives considered

- **Make `AppModel` fully async (store optional until opened).** Touches
  every use of `store` across the app. Too big for a patch release; the
  stage log tells us whether it is ever needed.
- **Revert #149.** Removes the calendar read but not the other main-thread
  TCC reads, and gives no data if the cause is elsewhere. Moving the reads
  off the main thread covers the calendar read anyway.
- **Ship os_log or crash logs in reports.** Breaks the report privacy rule
  (no logs). One fixed label is enough to point at a step.

## Failure modes

- A permission read hangs: the window draws, the Permissions rows show
  their last known (initially "not asked") state, the stage stays
  `window-drawn`, the step times out and a banner appears.
- A service start hangs (watcher, widget, calendar): banner naming it, the
  rest of startup continues.
- The main thread stalls anyway (something not yet moved): the watchdog
  writes `stalled at <stage>`; the next launch's report carries it.
- The data folder is unwritable: the stage log silently does nothing;
  the existing store fallback banner still shows.

## Hard rules

1. Audio never leaves the Mac: not touched.
2. No secrets on disk or in logs: the state file holds one fixed label and
   a number of seconds; nothing else.
3. No sampling params: not touched.
4. Build with bundle.sh: not touched; the new target is a plain library.
5. Testable logic: `StartupSequence`, `StallDetector`, `StartupLog` live in
   `FiggStartup` with tests; the app only wires them.
6. Settings in FiggConfig: no new setting. The stage file is state, like
   `last-signer.txt` and `asked-permissions.txt`.

## Tests

- `StartupSequenceTests`: a step that never returns times out and the
  next step still runs; a throwing step is reported by name; steps run in
  order; the sequence finishes in about the timeout, not forever.
  (Acceptance 1 and 2.)
- `StallDetectorTests`: no stall under the threshold; a stall reported
  with its length; recovery clears it.
- `StartupLogTests`: stages round-trip through the file; a previous
  launch's stall shows in `summary`; the file only ever contains known
  labels; an unwritable folder does not throw. (Acceptance 3.)
- `PermissionsTests`: `statuses()` covers every `Permission` case.
- Manual: launch with an empty data folder and with one copied from an
  earlier version; the sidebar shows (Acceptance 4).
- CI `test` job (Acceptance 5).

## Open questions

- Whether the reporter's Mac stalls on a permission read at all. The stage
  label in their next report answers it.

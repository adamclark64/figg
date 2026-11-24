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

The second suspect is the Keychain. `AppSettings.init`, called from
`FiggApp.init` before any window exists, reads the Atlassian email and
token and every model provider key with `Keychain.read` on the main
thread, and `reload()` (run on every app activation) reads any provider
key that is still missing. A Keychain read can block on `securityd` or
wait on an access prompt for items written by a differently signed copy,
and deleting the app does not delete Keychain items, which fits "a fresh
install did not help".

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
- `StartupLog.shared`: the one instance, used by `FiggApp`, `AppModel`
  and `BugReportView`. `begin()` is the first line of `FiggApp.init`,
  before `AppSettings()`, so every stage of this launch lands after it.
- `StartupSequence`: runs named async steps in order, each under a
  timeout (default 10 s). A step that throws or times out is reported
  through an `onFailure(name, reason)` callback and the sequence moves on.
  A timed-out step keeps running in the background; it is not cancelled
  forcibly, only no longer awaited.
- `LaunchSteps`: the launch step list as data. Built from injected async
  closures (`keychain`, `permissions`, `watcher`, `widget`, `calendar`,
  `model`, `recovery`, `updates`), it runs them through `StartupSequence`
  and maps each failure to the banner text
  "figg could not finish starting: <step label> did not respond. Some
  features may not work until you reopen figg." The app passes the real
  closures; tests pass fakes.

Timeouts only help a step that suspends. A step that blocks the main
actor synchronously cannot be timed out and no banner can draw while it
blocks; that case falls to the watchdog, which records the stall for the
next report. So every step that calls the system (TCC, Keychain,
Security, EventKit) does that work on a detached task and returns to the
main actor only to apply the result.

Changed:

- `FiggPermissions/SystemPermissions.swift`: add
  `nonisolated static func statuses() async -> [Permission: PermissionStatus]`
  that reads every status on a detached task.
- `FiggPermissions/SignerCheck.swift`: `currentRequirement()` is also
  offered as `nonisolated static func currentRequirementAsync() async`.
- `Figg/PermissionsView.swift` (`PermissionCenter`): `init` reads
  nothing; the signer becomes an optional loaded with the first read.
  New `refreshAsync() async` awaits `statuses()` and the signer on a
  detached task. The existing sync `refresh()` and `checkAtLaunch()` stay
  callable from sync code (they start a `Task` around the async version),
  so the item builds without touching `AppModel`; `checkAtLaunchAsync()`
  is what `LaunchSteps` awaits. Overlapping refreshes (the 1 s tick in the
  Permissions tab) coalesce into one in flight, but an in-flight read
  older than 5 s no longer blocks a new one. A separate `hasRead` flag
  says whether any read finished; `checkAtLaunch` and the signer store
  only act after a read, so `missing.isEmpty` keeps its meaning.
- `Figg/AppSettings.swift`: `init` no longer reads the Keychain. A new
  `loadSecrets() async` reads the Atlassian items and provider keys on a
  detached task, then applies them on the main actor without running the
  `didSet` writers (a `loadingSecrets` flag), so a late, empty or failed
  read never overwrites a stored item. Until it finishes, `secretsLoaded`
  is false and the Settings fields for those values are disabled.
  `reload()` no longer reads the Keychain on activation; missing provider
  keys are read by the same async loader. It runs as the first launch
  step.
- `Figg/AppModel.swift`: `init` keeps the cheap state (settings, store,
  queue, banners, `reloadMeetings`) and records stages. Everything else
  moves into `finishLaunch()`: permission check, meeting watcher,
  recording widget, calendar watch, model-on-disk check and load,
  crash recovery, update checks. `finishLaunch()` runs them through
  `StartupSequence`; a failure appends a warning banner
  "figg could not finish starting: <step> did not respond. Some features
  may not work until you reopen figg." `finishLaunch()` runs once.
- `Figg/MainView.swift`: the split view gets explicit
  `columnVisibility` state, set to `.all` at launch, so a restored window
  state cannot come back with both columns hidden or zero width (the
  "draws but empty" reading of #151). `window-drawn` is recorded from the
  sidebar's `.onAppear`, not the root's, so it means the sidebar really
  appeared. `.task { await model.finishLaunch() }` on the root view.
- `Figg/FiggApp.swift`: the first lines of `FiggApp.init` call
  `StartupLog.shared.begin()` and start the stall watchdog, before
  `AppSettings()` and `AppModel()`, so a stall in either is recorded. The
  watchdog stops 10 s after `ready`.
- `Figg/BugReportView.swift`: adds `extra["startup"] = startupLog.summary`.
- `docs/manual-test-checklist.md`: the manual launch checks.
- `AGENTS.md`: "Where to look" row for startup and a Known gaps note.

The store open, its migrations and the first `reloadMeetings` stay
synchronous in `init`; this is the one exception to acceptance criterion
1, written into the spec. GRDB's default busy mode fails at once on a
locked database rather than waiting, and `AppModel` already falls back to
an in-memory store with an error banner. A slow disk or a long migration
could still hold the first frame; making `store` optional touches every
use of it, too big for a patch. The `store-opened` and `meetings-loaded`
stages and the watchdog would show a stall there, and a later spec can
move it.

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

- A Keychain read hangs or prompts: the window draws, the Atlassian and
  provider key fields stay disabled, the step times out with a banner,
  nothing stored is overwritten.
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
- `LaunchStepsTests`: for each named step, a hanging fake and a throwing
  fake each give the banner naming that step, and the later steps still
  run; with all fakes succeeding no banner appears and the log reaches
  `ready`. (Acceptance 1 and 2.)
- `StallDetectorTests`: no stall under the threshold; a stall reported
  with its length; recovery clears it.
- `StartupLogTests`: stages round-trip through the file; a previous
  launch's stall shows in `summary`; the file only ever contains known
  labels; an unwritable folder does not throw. (Acceptance 3.)
- `PermissionsTests`: `statuses()` covers every `Permission` case.
- `StartupContextTests` (FiggFeedbackTests): a payload whose `extra` has
  `startup` renders `- **startup:** ...` under `### Context`.
  (Acceptance 3.)
- Manual: launch with an empty data folder and with one copied from an
  earlier version; the sidebar shows (Acceptance 4).
- CI `test` job (Acceptance 5).

## Open questions

- Whether the reporter's Mac stalls on a permission read at all. The stage
  label in their next report answers it.

## Review notes

First critic round (8 findings) addressed:

- P2 no longer changes the sync signatures `AppModel` calls, so it builds
  on its own.
- The step list and banner mapping moved into `FiggStartup.LaunchSteps`
  with per-step tests; the app only wires closures.
- Keychain reads in `AppSettings` and the signer check now leave the main
  thread. The store open stays synchronous; the spec now says so
  explicitly with the reason.
- Main-actor synchronous hangs are named as the watchdog's job, and system
  calls are required to run detached.
- `StartupLog.shared.begin()` and the watchdog start at the top of
  `FiggApp.init`.
- The drawn-but-empty case is guarded by forcing both split view columns
  visible at launch and recording `window-drawn` from the sidebar. Saved
  window state is not cleared, since that would mean a UserDefaults or
  file deletion the spec rules out.
- A report-body test was added in FiggFeedbackTests.
- The coalesced permission read has a 5 s staleness limit and a separate
  `hasRead` flag.

Second critic round: no blockers. P3 starts `loadSecrets()` from
`AppSettings.init` until P4 moves it into `LaunchSteps`. The rule that a
late Keychain read never writes back stays a manual check, because
`AppSettings` lives in the app target; moving it is left for later.

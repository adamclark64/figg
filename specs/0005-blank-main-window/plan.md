# Plan: the main window always draws on launch

### P1. FiggStartup target: stages, stage log, stall detector, step sequence, launch steps

- Files: app/Package.swift, app/Sources/FiggStartup/StartupStage.swift,
  app/Sources/FiggStartup/StartupLog.swift,
  app/Sources/FiggStartup/StallDetector.swift,
  app/Sources/FiggStartup/StartupSequence.swift,
  app/Sources/FiggStartup/LaunchSteps.swift,
  app/Tests/FiggStartupTests/StartupLogTests.swift,
  app/Tests/FiggStartupTests/StallDetectorTests.swift,
  app/Tests/FiggStartupTests/StartupSequenceTests.swift,
  app/Tests/FiggStartupTests/LaunchStepsTests.swift
- Depends on: none
- Proved by: StartupSequenceTests, LaunchStepsTests (hanging and throwing
  fake per step give that step's banner, later steps still run),
  StallDetectorTests, StartupLogTests (summary text, known labels only,
  unwritable folder)

### P2. Read permission statuses and the signer off the main thread

- Files: app/Sources/FiggPermissions/SystemPermissions.swift,
  app/Sources/FiggPermissions/SignerCheck.swift,
  app/Sources/Figg/PermissionsView.swift,
  app/Tests/FiggPermissionsTests/PermissionsTests.swift
- Depends on: none
- Proved by: PermissionsTests (`statuses()` returns every case); CI build
  (sync `refresh()` and `checkAtLaunch()` keep their signatures)

### P3. Read Keychain secrets off the main thread

- Files: app/Sources/Figg/AppSettings.swift,
  app/Sources/Figg/SettingsView.swift
- Depends on: none
- Proved by: CI build; manual checklist step (P5) that stored keys survive
  a launch unchanged
- Note: `AppSettings.init` starts `Task { await loadSecrets() }` so keys
  load on their own until P4 moves the call into `LaunchSteps`.

### P4. Run startup after the first frame, with stages, timeouts and the watchdog

- Files: app/Package.swift (Figg depends on FiggStartup),
  app/Sources/Figg/AppModel.swift, app/Sources/Figg/MainView.swift,
  app/Sources/Figg/FiggApp.swift
- Depends on: P1, P2, P3
- Proved by: LaunchStepsTests (P1) for the step and banner behaviour; CI
  build and test job; manual launch checks from P5

### P5. Startup stage in bug reports, manual checks and docs

- Files: app/Sources/Figg/BugReportView.swift,
  app/Tests/FiggFeedbackTests/StartupContextTests.swift,
  docs/manual-test-checklist.md, AGENTS.md
- Depends on: P1, P4
- Proved by: StartupContextTests (a `startup` extra renders under
  `### Context`); manual checklist steps (empty data folder, data folder
  from an earlier version, stored keys unchanged, report shows the
  `startup` line)

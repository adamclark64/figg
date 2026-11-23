# Plan: real names on transcript lines for every meeting app

Status: P1 to P8 built (PR 140), and P10's docs. P4's fixtures are
hand-built from published markup: `slack-huddle.json`,
`meet-chrome-captions.json`, `teams-meeting.json`. P8 also caps the call
stream's separation at the number of people the app showed, and the
recording strip shows who is on the call. Left: P9 (name provenance) and
the real-call check in P10.

P1 to P3 are the protocol and the Zoom port; P4 builds fixtures from each
app's published markup; P5, P6 and P7 are one app each and can be built in
parallel once P3 and their own P4 fixtures are in; P8 and P9 are
independent of the profiles and can be built in parallel with them.

### P1. AXNode tree and capture

- Files: app/Sources/FiggMeetingApps/AXNode.swift, app/Sources/FiggMeetingApps/AXTreeCapture.swift, app/Sources/FiggMeetingApps/ZoomReader.swift (move the `AX` helpers out), app/Tests/FiggMeetingAppsTests/AXNodeTests.swift, app/Tests/FiggMeetingAppsTests/Fixtures/
- Depends on: none
- Proved by: `AXNodeTests`: JSON round trip, a fixture loader, value text cut to 200 characters, `find`/`all(where:)` helpers; the capture itself is AX-only; `--ax-dump` on a live app checks it

### P2. MeetingAppProfile, SpeakingRules, AccessibilityMeetingReader, Zoom port

- Files: app/Sources/FiggMeetingApps/MeetingAppProfile.swift, SpeakingRules.swift, AccessibilityMeetingReader.swift, ZoomProfile.swift, ZoomReading.swift, ZoomReader.swift (becomes a thin alias), app/Tests/FiggMeetingAppsTests/ZoomProfileTests.swift, SpeakingRulesTests.swift
- Depends on: P1
- Proved by: `ZoomReadingTests` unchanged; `ZoomProfileTests` on a Zoom `AXNode` fixture built from the shapes in `ZoomReadingTests` (Speaker view, Gallery view, Participants panel open, not a meeting window gives nil); `SpeakingRulesTests` for each rule and its order

### P3. MeetingAppRegistry and the probe dump

- Files: app/Sources/FiggMeetingApps/MeetingAppRegistry.swift, app/Sources/figg-audio-probe/main.swift (the `--ax-dump` mode and `--replace`), app/Sources/Figg/FiggApp.swift (the `--ax-dump` launch argument, next to `--probe-audio`), app/Tests/FiggMeetingAppsTests/MeetingAppRegistryTests.swift
- Depends on: P2
- Proved by: `MeetingAppRegistryTests`: helper bundle to browser, Meet tab among other tabs picked and the others not targeted, two matches resolved by mic time, disabled app skipped, nothing on the mic falls back by order; a dump of a non-meeting Zoom window run by hand

### P4. Fixtures from published markup

- Files: app/Tests/FiggMeetingAppsTests/Fixtures/{meet-chrome,meet-safari,teams,slack-huddle}-*.json, the per-app table in design.md
- Depends on: P3
- Proved by: each fixture is an `AXNode` tree built from the names, ARIA labels and DOM ids or classes the apps are documented to use (open-source Meet and Teams bots and extensions, with source and date noted in design.md), for grid, one person talking, you muted, People panel open and, for Meet, captions on; made-up names only. A real-call `--ax-dump` is optional confirmation, not a gate.

### P5. Google Meet profile

- Files: app/Sources/FiggMeetingApps/MeetProfile.swift, app/Tests/FiggMeetingAppsTests/MeetProfileTests.swift
- Depends on: P3, P4 (Meet fixtures)
- Proved by: `MeetProfileTests` on the Chrome and Safari fixtures: roster, speaker from the tile cue or captions, self mute, self name, a Meet lobby or a non-Meet page gives nil

### P6. Teams profile

- Files: app/Sources/FiggMeetingApps/TeamsProfile.swift, app/Tests/FiggMeetingAppsTests/TeamsProfileTests.swift
- Depends on: P3, P4 (Teams fixtures)
- Proved by: `TeamsProfileTests` on the fixtures: roster, speaker, self mute, the chat window gives nil

### P7. Slack huddle profile

- Files: app/Sources/FiggMeetingApps/SlackHuddleProfile.swift, app/Tests/FiggMeetingAppsTests/SlackHuddleProfileTests.swift
- Depends on: P3, P4 (Slack fixtures)
- Proved by: `SlackHuddleProfileTests`: roster, speaker where shown, one-to-one rule, a channel view with no huddle gives nil

### P8. Settings and wiring

- Files: app/Sources/FiggConfig/FiggConfig.swift, app/Tests/FiggConfigTests/ConfigTests.swift, app/Sources/FiggMeetingApps/MeetingAppWatch.swift, app/Tests/FiggMeetingAppsTests/MeetingAppWatchTests.swift, app/Sources/Figg/AppModel.swift, app/Sources/Figg/SettingsView.swift, app/Sources/Figg/AppSettings.swift
- Depends on: P3
- Proved by: `ConfigTests` (round trip, missing key is all apps, unknown id ignored, commented `meeting_apps` line); `MeetingAppWatchTests` (banner text names the app); the app builds with `startSpeakerNames` using the registry and re-asking every 10 s while it has no profile

### P9. Name provenance

- Files: app/Sources/FiggStore/Store.swift (migration `v4-speaker-source`), app/Sources/FiggTranscription/Speakers.swift, TranscriptionQueue.swift, app/Sources/Figg/ (transcript marker and tooltip), app/Tests/FiggStoreTests/, app/Tests/FiggTranscriptionTests/SpeakerTests.swift
- Depends on: none
- Proved by: `StoreTests`: migration on an old database, source saved with lines, rename sets `typed` and a later final pass keeps it; `SpeakerTests`: app names carry `app:<id>`

### P10. Docs and the real-call check

- Files: AGENTS.md (known gaps, where to look), docs/agent-setup.md, docs/manual-test-checklist.md ("Zoom speaker names" becomes "Meeting app speaker names", one block per app), README.md if it says Zoom only
- Depends on: P5, P6, P7, P8, P9
- Proved by: the checklist run on a real Meet call (Chrome and Safari), a real Teams call and a real Slack huddle with two or more remote people: names on lines after Stop, the provenance marker, the app quitting mid-call keeps the recording going

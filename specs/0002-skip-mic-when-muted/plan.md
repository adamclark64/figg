# Plan: skip the mic while you are muted on Zoom

P1 and P3 have no dependency between them and touch different files, so
they can be built in parallel.

### P1. Read your own mute state from Zoom's window

- Files: app/Sources/FiggMeetingApps/MeetingAppSnapshot.swift, app/Sources/FiggMeetingApps/ZoomReading.swift, app/Sources/FiggMeetingApps/ZoomReader.swift, app/Tests/FiggMeetingAppsTests/ZoomReadingTests.swift
- Depends on: none
- Proved by: `ZoomReadingTests` for `selfMuted(fromButtonLabels:)` (muted, unmuted, unknown, "Mute all", "Unmute video", both kinds), the own-tile fallback, toolbar winning over a disagreeing tile, two self tiles giving nil, and `snapshot` filling `selfMuted`; existing tests unchanged

### P2. Muted stretches in the speaker timeline

- Files: app/Sources/FiggMeetingApps/SpeakerTimeline.swift, app/Sources/FiggMeetingApps/SpeakerWatcher.swift, app/Tests/FiggMeetingAppsTests/SpeakerTimelineMuteTests.swift
- Depends on: P1
- Proved by: `SpeakerTimelineMuteTests`: consecutive muted readings join; a nil, unmuted or unknown reading and a skipped poll each end a stretch; `mutedSeconds` overlap; `names: false` records no spans; save/load round trip with stretches; a JSON literal in today's `speakers.json` format decodes with `muted == []`; a watcher with only stretches still saves; `SpeakerWatcherSlot.mutedShare` is 0 for another meeting

### P3. The skip_mic_when_muted setting

- Files: app/Sources/FiggConfig/FiggConfig.swift, app/Tests/FiggConfigTests/ConfigTests.swift
- Depends on: none
- Proved by: `ConfigTests`: round trip with the value off, a config without the key decodes it as on, and `yaml()` has the commented `skip_mic_when_muted` line

### P4. Drop muted mic lines, live and in the final pass

- Files: app/Sources/FiggTranscription/MuteFilter.swift, app/Sources/FiggTranscription/TranscriptionQueue.swift, app/Tests/FiggTranscriptionTests/MuteFilterTests.swift, app/Tests/FiggTranscriptionTests/TranscriptionTests.swift
- Depends on: P2
- Proved by: `MuteFilterTests` (lines inside, half, partly overlapping and outside a stretch on both streams; `unmutedTurns` splitting and removing turns; no stretches returns input unchanged); `TranscriptionTests`: live mic line dropped and system line kept with `skipMuted` on; `finalPass` with `FakeTranscriber`, a fake separator and a saved timeline leaves no mostly-muted mic line and does not pick a mostly-muted room voice as "Me"; identical results with no timeline and with an empty one; `skipMuted` off keeps every mic line

### P5. Wire it into the app, Settings and docs

- Files: app/Sources/Figg/AppModel.swift, app/Sources/Figg/SettingsView.swift, docs/manual-test-checklist.md, docs/agent-setup.md, AGENTS.md
- Depends on: P2, P3, P4
- Proved by: CI's `test` job building the app with the new toggle next to "Name speakers on Zoom calls"; the checklist steps under "Zoom speaker names" (talk in the room while muted, unmute and talk, Stop, only unmuted speech remains; confirm the toolbar label is read); CI `gates`

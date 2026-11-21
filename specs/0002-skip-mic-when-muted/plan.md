# Plan: skip the mic while you are muted on Zoom

P3 depends on nothing and touches no file another item touches, so it can
be built in parallel with P1, P2 and P4. P1, P2 and P4 form a chain.

### P1. Read your own mute state from Zoom's window

- Files: app/Sources/FiggMeetingApps/MeetingAppSnapshot.swift, app/Sources/FiggMeetingApps/ZoomReading.swift, app/Sources/FiggMeetingApps/ZoomReader.swift, app/Tests/FiggMeetingAppsTests/ZoomReadingTests.swift
- Depends on: none
- Proved by: `ZoomReadingTests` for `selfMuted(fromButtons:participants:windowHeight:)` (muted, unmuted, unknown, "Mute all", "Unmute video", "Mute Bill", both kinds, a duplicated label counting once, a bare "Unmute" in the Participants panel or high in the window giving nil), the own-tile fallback, toolbar and tile disagreeing giving nil, two self tiles giving nil, and `snapshot` filling `selfMuted`; existing tests unchanged

### P2. Muted stretches in the speaker timeline

- Files: app/Sources/FiggMeetingApps/SpeakerTimeline.swift, app/Sources/FiggMeetingApps/SpeakerWatcher.swift, app/Tests/FiggMeetingAppsTests/SpeakerTimelineMuteTests.swift
- Depends on: P1
- Proved by: `SpeakerTimelineMuteTests` (with a `MuteTracker`): consecutive muted readings join; uneven spacing (muted@0.1, unmuted@0.5, muted@0.8) never spans the unmuted reading; a slow poll (0.8 s) joins and a missed poll (1.5 s) splits; a nil, unmuted or unknown reading ends a stretch at its time; `mutedShare` overlap and zero length; `names: false` records no spans, participants or self name; save/load round trip with stretches; a JSON literal in today's `speakers.json` format decodes with `muted == []`; a watcher with only stretches still saves; `SpeakerWatcherSlot.mutedShare` is nil with no watcher or for another meeting; the existing `pollsBuildAndSaveTheTimeline` test passes unchanged

### P3. The skip_mic_when_muted setting

- Files: app/Sources/FiggConfig/FiggConfig.swift, app/Tests/FiggConfigTests/ConfigTests.swift
- Depends on: none
- Proved by: `ConfigTests`: round trip with the value off, a config without the key decodes it as on, and `yaml()` has the commented `skip_mic_when_muted` line

### P4. Drop muted mic lines, live and in the final pass

- Files: app/Sources/FiggTranscription/MuteFilter.swift, app/Sources/FiggTranscription/TranscriptionQueue.swift, app/Sources/FiggTranscription/Speakers.swift, app/Tests/FiggTranscriptionTests/MuteFilterTests.swift, app/Tests/FiggTranscriptionTests/TranscriptionTests.swift, app/Tests/FiggTranscriptionTests/SpeakerTests.swift
- Depends on: P2
- Proved by: `MuteFilterTests` (lines inside, half, partly overlapping and outside a stretch on both streams; `unmutedTurns` splitting and removing turns; no stretches returns input unchanged); `SpeakerTests`: `apply(rankTurns:)` ranks by the cut turns and labels by the original ones; `TranscriptionTests` (with new fakes `ScriptedTranscriber` and `ScriptedSeparator`): live mic line dropped and system line kept with `skipMuted` on, also when `liveMutedShare` is nil and only the saved `speakers.json` has the stretch; `finalPass` with `ScriptedTranscriber`, `ScriptedSeparator` and a saved timeline leaves no mostly-muted mic line and does not pick a mostly-muted room voice as "Me" (it stays a Guest); the same drop with `separator: nil` and with a throwing separator; identical results with no timeline and with an empty one; `skipMuted` off keeps every mic line

### P5. Wire it into the app, Settings and docs

- Files: app/Sources/FiggMeetingApps/MeetingAppWatch.swift, app/Tests/FiggMeetingAppsTests/MeetingAppWatchTests.swift, app/Sources/Figg/AppSettings.swift, app/Sources/Figg/AppModel.swift, app/Sources/Figg/SettingsView.swift, docs/manual-test-checklist.md, docs/agent-setup.md, AGENTS.md
- Depends on: P2, P3, P4
- Proved by: `MeetingAppWatchTests` (start rule and banner text for names only, mute only, both, neither); CI's `test` job building the app (the `AtomicFlag` set in `reload()` and `save()` and read off the main actor, the Accessibility status shown for either setting) with the new toggle next to "Name speakers on Zoom calls"; the checklist steps under "Zoom speaker names" (talk in the room while muted, unmute and talk, Stop, only unmuted speech remains; confirm the toolbar label is read; relaunch with `skip_mic_when_muted: true` already in config.yaml and check it is on); CI `gates`

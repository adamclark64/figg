# Skip the mic while you are muted on Zoom

## Problem

figg records the Mac's microphone for the whole meeting, whatever the
meeting app is doing. When you mute yourself on a Zoom call, Zoom stops
sending your mic, but figg keeps listening. Anyone talking in the room with
you (a colleague at the next desk, someone on the phone, people in a shared
space) is transcribed as "Me" and lands in the meeting's transcript, even
though they were never part of the call. Issue 48 reports exactly this: the
lines happened to stay out of the enhanced notes, but they should not have
been transcribed at all.

figg already reads Zoom's meeting window through Accessibility to put names
on the people talking (`FiggMeetingApps`: `ZoomReader`, `SpeakerWatcher`,
`SpeakerTimeline`), and Zoom's window says whether each person, you
included, is muted. So figg can already see when you are muted, and does
nothing with it.

Open question for the design stage: the most reliable place in Zoom's window
to read your own mute state (your own video tile, matched by your Zoom name,
or the toolbar's mute button, which works even when your name is not
known). Pick one, or both with a clear order, and say why.

## Intended outcome

While Zoom shows you as muted, nothing figg hears on the mic ends up in the
transcript: no live "Me" lines appear, and the transcript kept after Stop
has no mic lines from those stretches. The call's audio (the other people
on Zoom) is transcribed as before. When you unmute, your mic is transcribed
again within about a second. If figg cannot tell whether you are muted (no
Accessibility permission, Zoom not open, the window has changed), it records
and transcribes exactly as it does today.

The behaviour is on by default and can be turned off in Settings, for
someone who wants the room captured even while muted on the call.

## Constraints

- AGENTS.md hard rules apply. Audio never leaves the Mac; the mute state
  comes only from what Zoom already shows in its own window.
- No new permission: it uses the Accessibility access that Zoom speaker
  names already use, and must not ask for Accessibility on its own when it
  is not granted (the existing one-time Zoom banner is enough).
- Reading Zoom's window can fail at any moment. Any read that does not say
  "muted" counts as "not known to be muted", so a missed reading can only
  keep a line, never drop one. A slow or hung Zoom must not hold up
  recording or transcription (keep the existing timeouts and queue).
- The mute logic is pure and lives in a library target (`FiggMeetingApps`
  and/or `FiggTranscription`), behind the existing `MeetingAppReader`
  protocol, so it is tested without Zoom or audio. Views stay thin.
- Mute stretches are saved with the meeting, beside the existing
  `speakers.json` or inside it, so the final pass and crash recovery treat
  the meeting the same way the live pass did. An older `speakers.json`
  without them must still load.
- The new setting goes in `FiggConfig` under `transcription`, with a
  default of on, a lenient `decodeIfPresent`, a commented line in `yaml()`,
  and a round-trip test.
- The "Keep audio" setting keeps meaning what it means today: this spec
  decides what is transcribed, not which audio files are kept.
- Test data is invented and neutral, never taken from a real meeting.
- figg only builds on macOS, so every criterion below is proved by a Swift
  Testing test or a CI job, never by a local run on Linux.
- `docs/agent-setup.md` is updated if it lists settings and the new one
  belongs there.

## Acceptance criteria

- [ ] Reading Zoom's window gives your own mute state: muted, unmuted, or
  unknown when the window does not say (proved by: `ZoomReading` tests
  built from invented Accessibility labels, covering each of the three)
- [ ] Mute readings over a recording join into muted stretches on the
  recording clock, the same way speaker spans do; a gap in readings ends a
  stretch rather than extending it (proved by: a timeline test)
- [ ] The stretches are saved and loaded with the meeting, and a
  `speakers.json` written by the current version still loads, with no
  stretches (proved by: a save/load test and a test decoding today's
  format)
- [ ] A live mic line is dropped when muted stretches cover at least half
  of its time span; a line covered less than that is kept; call-audio lines
  are never dropped for this reason (proved by: tests with lines fully
  inside, partly overlapping and outside a muted stretch, on both streams)
- [ ] After Stop, the final pass leaves no mic lines whose time span is at
  least half inside a muted stretch, and mic audio from those stretches does
  not count towards choosing which voice is "Me" (proved by: a
  `TranscriptionQueue.finalPass` test using `FakeTranscriber` and a saved
  timeline)
- [ ] With no mute information (no timeline, or a timeline with no
  stretches) the live lines and the final transcript are exactly what they
  are today (proved by: a test running the same input with and without an
  empty timeline)
- [ ] Turning the setting off keeps every mic line even while muted (proved
  by: a test with the setting off)
- [ ] The setting round-trips through `config.yaml`, defaults to on when
  missing, and appears in Settings next to "Name speakers on Zoom calls"
  (proved by: a `FiggConfig` round-trip test; the Settings toggle by the
  CI `test` job building the app)
- [ ] `docs/manual-test-checklist.md` gains steps under "Zoom speaker
  names": talk in the room while muted on a Zoom call, unmute and talk,
  then Stop, and check that only the unmuted speech is in the transcript
  (proved by: the checklist entry; run by hand before release)
- [ ] All existing tests pass unchanged, including the speaker-name and
  echo tests (proved by: the CI `test` job)
- [ ] The final PR passes the CI `test` and `gates` jobs (proved by: CI)

## Out of scope

- Mute detection for Teams, Meet, Slack huddles or any app other than the
  Zoom desktop app.
- macOS or hardware mic mute, and muting figg itself from the widget.
- Deleting or not writing mic audio chunks while muted (what "Keep audio"
  stores stays as it is).
- Showing the mute state in the recording widget or the live waveform.
- Telling the room's voices apart from yours while you are unmuted; that
  is speaker separation, not this spec.
- Changing how echo cancellation or `EchoFilter` decide what to drop.

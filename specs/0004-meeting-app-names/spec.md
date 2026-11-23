# Real names on transcript lines for every meeting app

## Problem

Speaker labels are guesses (Me / Guest N / Them N) unless the call is on
Zoom. figg reads Zoom's window through Accessibility (`ZoomReader`,
`SpeakerWatcher`, `SpeakerTimeline` in `FiggMeetingApps`) and puts the names
Zoom shows on the people talking. Calls on Google Meet, Microsoft Teams and
Slack huddles stay anonymous, and each has to be renamed by hand from the
transcript's context menu. Issue 72.

The Zoom code is written for Zoom alone: the Accessibility walk, the
window lookup and the parsing are one file, and `AppModel` hard-codes
`ZoomReader` and the word "Zoom" in its banners. Adding a second app today
means copying all of it.

## Intended outcome

- One protocol that every meeting app plugs into. Supporting a new app is
  one profile file (which windows to read, how to turn its Accessibility
  tree into a snapshot), plus captured trees as test fixtures. Nothing in
  `AppModel`, the timeline or the final pass changes per app.
- Profiles for Zoom (ported, same behaviour), Google Meet in Chrome, Arc,
  Edge and Safari, the new Teams desktop app, and Slack huddles.
- During a recording figg watches whichever of these apps the call is in,
  found from the app holding the mic. After Stop the people on the call
  have the names that app showed, the same way Zoom calls do today.
- Each line shows where its name came from (meeting app, calendar, typed),
  so a wrong guess is easy to spot and fix.
- When an app's window changes in an update, figg falls back quietly to
  Me / Them N and the recording carries on.

## Constraints

- AGENTS.md hard rules apply: audio never leaves the Mac; only text goes
  to the model provider; no secrets on disk or in logs; settings in
  `FiggConfig` with a default, a lenient `decodeIfPresent`, a commented
  line in `yaml()` and a round-trip test; logic in library targets behind
  protocols.
- Read only the meeting's own window. In a browser that means only the
  window (and only the web area) whose URL is the meeting; never other
  tabs, never other apps.
- Never block or slow the recording: every Accessibility call has a short
  timeout and a node cap, and a miss is a gap, not an error.
- Committed fixtures hold made-up names only; captured trees are scrubbed
  and read by a person before they are committed.
- Names from a meeting app are hints for the diarized voices, as on Zoom
  today. figg never maps voices to names from audio.

## Acceptance criteria

- [ ] `ZoomReadingTests` pass unchanged, and a captured Zoom tree run through
  `ZoomProfile` gives the same snapshot as `ZoomReader` does today
  (proved by: `ZoomProfileTests`)
- [ ] Each of Meet, Teams and Slack has profile tests on captured, scrubbed
  Accessibility trees: participants, the person shown speaking, self mute
  where the app shows it, and nil for a tree from a different screen
  (proved by: `MeetProfileTests`, `TeamsProfileTests`, `SlackHuddleProfileTests`)
- [ ] Choosing the profile from the mic holder and the open windows,
  including a browser with a Meet tab and other tabs (proved by:
  `MeetingAppRegistryTests`)
- [ ] `transcription.meeting_apps` round trip, missing key decodes to all
  apps on (proved by: `ConfigTests`)
- [ ] Name provenance survives a save and a rename (proved by: `StoreTests`)
- [ ] Names on lines in a Meet call (Chrome and Safari), a Teams
  call and a Slack huddle, two or more remote people (proved by:
  `docs/manual-test-checklist.md` "Meeting app speaker names")
- [ ] AGENTS.md known gaps and `docs/agent-setup.md` updated (proved by: review)

## Out of scope

- Mapping voices to names from audio (voice prints).
- Windows or the Teams/Meet web apps on other platforms.
- Reading chat, shared screens or meeting content from the apps.
- Webex, FaceTime, Discord and others: the protocol must make them one
  file each later, but they are not built here.
- Merging or splitting speakers.

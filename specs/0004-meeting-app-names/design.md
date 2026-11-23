# Design: real names on transcript lines for every meeting app

## Summary

Split today's `ZoomReader` into three layers:

1. **`AXTreeCapture`** (the only code that touches the Accessibility C
   API): copies one window, or one web area, into a plain `AXNode` value
   tree. Timeouts, node and depth caps, and the browser/Electron switch
   that turns on web accessibility live here, once.
2. **`MeetingAppProfile`** (pure, one per app): says which running app and
   which window is the meeting, and turns an `AXNode` tree into a
   `MeetingAppSnapshot`. Tested on captured trees saved as JSON.
3. **`AccessibilityMeetingReader`**: a `MeetingAppReader` that ties one
   profile to the capture. `SpeakerWatcher`, `SpeakerTimeline`, the live
   names and the final pass already take any `MeetingAppReader` and need
   no change.

A **`MeetingAppRegistry`** picks the profile for a recording from the app
holding the mic (what `MeetingDetector` already sees) and the open windows.
`AppModel.startSpeakerNames` asks the registry instead of naming Zoom.

## The protocol

```swift
/// One meeting app figg knows how to read. Pure: no Accessibility calls.
public protocol MeetingAppProfile: Sendable {
    var id: String { get }            // "zoom", "meet", ... (speakers.json, config)
    var displayName: String { get }   // "Zoom", "Google Meet", ... (banners, Settings)
    var bundleIDs: Set<String> { get } // a web meeting lists every browser it supports
    var needsWebAccessibility: Bool { get } // set AXManualAccessibility first
    var policy: CapturePolicy { get } // node/depth caps, where to descend, where frames are needed
    func target(in windows: [AXWindowSummary]) -> AXTarget?
    func snapshot(from capture: MeetingAppCapture) -> MeetingAppSnapshot?
}
```

`MeetingAppCapture` is the copied target (`tree`, `width`, `height`) plus,
when `policy.otherWindowsDepth` asks for it, a shallow copy of the app's
other windows (Zoom's self name is in its main window). It is `Codable`,
so a capture is a fixture as it stands.

`AXWindowSummary` is the cheap first look (title, identifier, frame, and
for browsers the URL of each web area). Only the chosen target is walked,
which is how "read only the meeting's window" is enforced: a Meet profile
targets the web area whose `AXURL` host is `meet.google.com`, and nothing
else in the browser is copied.

`AXNode` is `Codable` and holds only what profiles need: role, subrole,
role description, title, description, value (strings, cut to 200
characters), identifier, URL (web areas only), frame relative to the
target, and children. Being a value type is what makes fixtures possible.

### Shared naming rules

Apps differ in how they show who is talking, so the "who is speaking"
choice is a shared pure helper, `SpeakingRules`, that every profile calls
with what it found, strongest cue first:

1. **App cue**: the app marks one remote person as speaking (Zoom's main
   tile in Speaker view; others to be found from captures, see below).
2. **Only one unmuted**: you are known and exactly one other person is
   unmuted (Zoom's existing rule, moved here).
3. **One-to-one call**: you are known and there is exactly one other
   participant.
4. Otherwise nil.

Mute state follows the existing rule: answer only when clear, and two
sources that disagree give nil.

## Per-app profiles

Everything below other than Zoom is a working hypothesis until plan P4
replaces it with what the apps' published markup shows (the selectors and
ARIA labels open-source Meet and Teams bots and extensions rely on), noted
as "from <source>, <date>" the way `ZoomReading` says what it was checked
against.

| | Zoom | Google Meet | Teams (new) | Slack huddle |
|---|---|---|---|---|
| Apps | `us.zoom.xos` | Chrome `com.google.Chrome`, Arc `company.thebrowser.Browser`, Edge `com.microsoft.edgemac`, Safari `com.apple.Safari` | `com.microsoft.teams2` | `com.tinyspeck.slackmacgap` |
| Mic holder | Zoom | the browser or its helper process | Teams | Slack |
| Target | window `zm.meeting.window.main` | web area with `AXURL` host `meet.google.com` and a meeting code path | the call window (not the chat window) | the huddle window or the huddle panel in the main window |
| Web accessibility | no | yes for Chromium browsers; Safari exposes it already | to check (WebKit or WebView2) | yes (Electron) |
| Roster | video tile labels | tile name labels, or the People panel when open | tile labels, or the People panel | huddle avatars or the participant list |
| Speaking cue | main tile in Speaker view | to find: tile speaking indicator; failing that, captions ("Name" above each caption) when captions are on | to find: tile "speaking" state in its label or a selected/ring element | to find; may have none, then rules 2 and 3 |
| Self mute | toolbar button, own tile | toolbar mic button label ("Turn on microphone" while muted) | toolbar Mic button | huddle mic button |
| Self name | account button | "You" tile, or the account button | "(You)" in the roster | "(you)" in the participant list |

Notes per app:

- **Meet captions** are a strong cue where the tiles are not: Meet writes
  the speaker's name above each caption line. Reading them is text from a
  window already on screen and stays on the Mac, but captions are on only
  if the user turned them on, so they are a bonus cue, never required.
  Caption text itself is not stored; only the name and the time are.
- **Safari** exposes web content without the switch; Chromium needs
  `AXManualAccessibility = true` set on the app element (the switch
  Chromium documents for assistive tools). It is set once per recording,
  only on the browser that holds the meeting, and never
  `AXEnhancedUserInterface`, which changes window animations.
- **Teams** has a classic app (`com.microsoft.teams`) that is retired; it
  is not supported.
- **Slack** may show no speaking cue at all. Then a huddle with one other
  person is still fully named (rule 3), and larger huddles get the roster
  as hints, which is still better than Them 1 / Them 2 because the final
  pass can name a voice when the timeline shows one person for most of it.

## Choosing the profile

`MeetingAppRegistry.profile(micHolders:running:windows:enabled:)`:

1. The mic holders `MeetingDetector` sees, mapped to apps (a helper bundle
   such as `com.google.Chrome.helper` maps to its browser).
2. For each, the enabled profiles whose `bundleIDs` contain it, keeping
   those whose `target(in:)` finds a meeting.
3. If more than one matches (two browsers with Meet open), the one holding
   the mic longest wins.
4. Recording started by hand with nothing on the mic: the first running app
   with a target, in the order Zoom, Teams, Meet, Slack.

The watcher re-asks the registry every 10 s while it has no profile, so a
call joined after Record still gets names. Once a profile reads a meeting
it is kept for the recording; `SpeakerTimeline.app` records its id.

## Name provenance

`transcriptLine` gets a nullable `speakerSource` column (migration
`v4-speaker-source`): `app:<id>`, `calendar`, `typed`, or null (automatic
label). Set where the label is set: the final pass and live names
(`app:<id>`), the attendee hint path (`calendar`), `Store.rename`
(`typed`). The transcript shows a small marker beside a name that is not
automatic, with a tooltip ("Name from Google Meet"). A typed name always
wins over a later final pass, as today.

## Settings

- `transcription.meeting_app_names` (exists) stays the master switch.
- New `transcription.meeting_apps: [zoom, meet, teams, slack]`, the apps
  figg may read, default all four. Lenient decode: a missing key is all
  four, unknown ids are ignored. Commented line in `yaml()`.
- `MeetingAppWatch.plan` takes the profile's display name, so banner text
  says "Google Meet" or "Teams" instead of "Zoom". The Settings toggle
  becomes "Name speakers from meeting apps", with the app list under it.
- `skip_mic_when_muted` works on any profile that reports `selfMuted`;
  the label drops "on Zoom".

## Capturing fixtures

`figg-audio-probe --ax-dump <profile id> [--replace "Real Name=Person A"]...`
writes the chosen target's `AXNode` tree as JSON to `/tmp/figg-ax-<id>.json`,
with every `--replace` applied and all value text not part of a name or a
known label replaced by `x`s of the same length. It must run inside the
app for figg's own Accessibility grant, like `--probe-audio`
(`open build/Figg.app --args --ax-dump meet`). A person reads the file
before it goes into `app/Tests/FiggMeetingAppsTests/Fixtures/`. Fixtures
are made with test accounts named after the existing fixture people.

## Failure modes

- App update changes the tree: the profile returns nil, the timeline has a
  gap, labels stay Me / Them N. The profile tests keep the old fixture so
  a fix does not drop the old layout until it is gone for good.
- Huge DOM (a 50-person Meet): node cap of 6000 and depth 40 for web
  areas; a capped walk still yields what it saw.
- Hung app: 250 ms messaging timeout per element, as Zoom has today.
- Accessibility missing: one banner naming the app, once per launch.
- Wrong name on a voice: provenance marker plus the existing rename.

## Hard rules

- Audio: untouched; only window text is read and it stays on the Mac.
- Model provider: names already go to it as speaker labels; nothing new.
- Secrets and logs: no tree content is logged; dumps only on request.
- Settings: `FiggConfig` as above.
- Testability: all parsing is pure behind `MeetingAppProfile`; the AX
  calls are in one file behind `AXTreeCapture`.

## Alternatives considered

- **One reader class per app, as Zoom is today.** Simple, but every app
  repeats the walk, the timeouts and the browser switch, and nothing can
  be tested without the live app. Lost on testability.
- **A browser extension for Meet.** Reliable DOM access and speaking
  events, but another thing to install, sign and keep in sync with three
  browsers. Kept as a fallback if captures show Meet's speaking cue is
  not in the Accessibility tree at all.
- **Calendar attendees only.** Already used as prompt hints; it has no
  timing, so it cannot say who spoke when.

## Open questions

- Which element, if any, carries the speaking cue in Meet, Teams and Slack
  (answered by P4 from published markup).
- Whether new Teams on macOS is WebKit or WebView2 under the hood, which
  decides `needsWebAccessibility`.
- Whether setting `AXManualAccessibility` on Chrome costs noticeable CPU
  on a long call (worth one Activity Monitor check on a real call).

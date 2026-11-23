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
    func accessibilitySwitches(for bundleID: String) -> [String] // web tree switches per app
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

Found from published markup (November 2026). Two limits shape every
profile: Accessibility shows a web element's role, aria-label (as
description or title), aria-pressed (as value), text, DOM id
(`AXDOMIdentifier`) and DOM classes (`AXDOMClassList`), but **no `data-*`
or `jsname` attributes**, which most scrapers key on; and anything drawn
with CSS (speaking rings as `::before` opacity) is invisible. Sources:
Chromium `ui/accessibility/platform/ax_platform_node_cocoa.mm`, Electron
`shell/browser/mac/electron_application.mm`, Chrome
`chrome/browser/chrome_browser_application_mac.mm`.

**Turning the web tree on.** Electron (Slack) accepts `AXManualAccessibility`
or `AXEnhancedUserInterface`. Chrome, Edge and Arc accept only
`AXEnhancedUserInterface`. Both build the tree about 2 s after the switch,
so the first readings are gaps. Safari needs nothing. Each profile names
the switches per app in `accessibilitySwitches(for:)`, and the reader sets
them only on the app that holds the meeting. Helper processes own no
windows; the registry maps them to the main app, whose pid is read.

| | Zoom | Google Meet | Teams (new) | Slack huddle |
|---|---|---|---|---|
| Apps | `us.zoom.xos` | Chrome `com.google.Chrome`, Arc `company.thebrowser.Browser`, Edge `com.microsoft.edgemac`, Safari `com.apple.Safari` | `com.microsoft.teams2` | `com.tinyspeck.slackmacgap` |
| Switch | none | `AXEnhancedUserInterface` (Chromium), none (Safari) | both, until its engine is known | `AXManualAccessibility` |
| Target | window `zm.meeting.window.main` | web area with host `meet.google.com` and a meeting code path | the call window | the huddle window or panel |
| Name | video tile labels | tile name text with class `notranslate`; People panel rows: `listitem` with the name as label inside region "In call" | tile label `"<Name>, video is on, ..."`, first comma part | tile (gridcell, class `p-huddle_peer_tile`) label `View <Name>'s profile` (straight or curly apostrophe) |
| Speaking cue | main tile in Speaker view | no stable AX cue (the tile's audio indicator only churns obfuscated classes); **captions** region `Captions`: each turn `div.nMcdL` holding the name (`.NWpY1d`) and words | none visible to AX (speaking ring is CSS opacity); captions are `data-tid` only | child with class `p-huddle_peer_tile__overlay--active_speaker` while that person talks |
| Self mute | toolbar button, own tile | mic button label `Turn on microphone...` while muted, `Turn off microphone...` while live (shortcut suffix varies: match the prefix) | DOM id `mic-button`; label `Unmute mic` while muted, `Mute mic` while live (web client; desktop unverified) | button `Unmute microphone` while muted, `Mute microphone` while live; tile class `p-huddle_peer_tile__name_overlay--muted` |
| Self name | account button | "(You)" beside your row in the People panel; captions label your lines "You" | unknown | gridcell DOM id contains `-self_` |
| Confidence | checked on Zoom 7.1.9 | medium (names, captions high, mute high) | low to medium | medium to high |

Notes per app:

- **Meet** names people reliably but shows who is talking only through
  captions, so captions are the speaking cue when on, and without them
  Meet falls back to the shared rules (one unmuted other, one-to-one).
  Caption text is not stored; only the name and the time are. Meet's
  obfuscated class names (`nMcdL`, `NWpY1d`) change between Meet builds,
  so the profile also accepts a caption turn found by shape (an image, a
  short text, a longer text inside the "Captions" region).
- **Teams** gives names and self mute but no speaking cue through
  Accessibility; it relies on the shared rules until captions are mapped.
  Whether it is WebKit or WebView2 on the Mac is unresolved (list
  `Microsoft Teams.app/Contents/Frameworks`); setting both switches covers
  either.
- **Slack** has the best cue of the three: a class present only on the
  speaking tile.
- **Prior art:** `r3dbars/transcripted` (`Sources/Meeting/CallSpeaker/`) is
  a Swift Accessibility reader for the same four apps, marked unverified;
  worth reading before P5 to P7. The selectors above come from Vexa,
  vibeconf, openclaw, mova-flow, recall.ai's open-source caption extension,
  teams-for-linux and LokalBot, dated 2025-11 to 2026-11.

Limits found while building P5 to P7:

- A browser exposes only the visible tab's web area, so Meet in a
  background tab reads as a gap until it is in front again.
- Slack's huddle is often a panel in the main window, and Teams may give
  the meeting no window title to tell it from chat, so for those two the
  copy can include the main window's other content. It stays in memory for
  the one poll, is never saved or logged, and `--ax-dump` blanks every text
  value that is not a replaced name. Do not run `--ax-dump` on them with
  `--keep-values`.
- Meet knows who you are only while the People panel is open (the "(You)"
  row); without it, only the captions cue names a speaker.

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

- Whether Meet's tile audio indicator is in the Accessibility tree at all
  (if it is, a class change per poll could be a second cue).
- Whether new Teams on macOS is WebKit or WebView2 under the hood, which
  decides its switch (both are set until then).
- Whether setting `AXEnhancedUserInterface` on Chrome costs noticeable CPU
  on a long call (worth one Activity Monitor check on a real call).

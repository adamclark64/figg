# Design: skip the mic while you are muted on Zoom

## Summary

`ZoomReader` already walks Zoom's meeting window twice a second. It will
also collect the toolbar's button labels, and `ZoomReading` (pure) turns
them, plus your own video tile, into `selfMuted: Bool?` on
`MeetingAppSnapshot`. `SpeakerTimeline` gains a list of muted stretches on
the recording clock, built from those readings and saved in the existing
`speakers.json`. A new pure `MuteFilter` in `FiggTranscription` answers
"how much of [start, end] was muted" and drops mic lines that are at least
half muted. `TranscriptionQueue` applies it to live mic lines (through the
running watcher, like `liveName`) and in `finalPass` (from the saved
timeline), where muted parts of mic diarizer turns are also cut out before
"Me" is chosen. A new `transcription.skip_mic_when_muted` setting (default
on) gates both. With no stretches, every code path returns its input
unchanged, so today's behaviour is kept exactly.

## Reading your own mute state

Order: the toolbar's mute button first, your own tile second.

1. **Toolbar button.** Zoom's meeting toolbar has one audio button whose
   label is the action it offers: "Unmute" (or "Unmute audio", "Unmute my
   audio") while you are muted, "Mute" (or "Mute audio", "Mute my audio")
   while you are not. It needs no self name, so it works when the account
   button is not visible, and it changes the moment you click it.
   `ZoomReading.selfMuted(fromButtonLabels:)` looks at labels whose first
   word is "mute" or "unmute" (case-insensitive, punctuation ignored, and
   not containing "video", "all" or another participant's name, so "Mute
   all" and "Unmute video" never count). It answers only when **exactly
   one** such label is found: "unmute..." means muted, "mute..." means
   unmuted. None, or more than one (a host's Participants panel has a
   Mute/Unmute button on every row, often without the name in the label),
   means unknown. This keeps a panel row from ever reading as "you are
   muted" when the toolbar is hidden.
2. **Own tile.** When the toolbar says nothing (hidden toolbar, layout
   change), the tile whose name equals `selfName` gives the answer through
   the existing `participant(fromTileLabel:)` mute parsing, but only when
   exactly one tile has that name (two devices of yours make it unclear,
   the same rule `snapshot` uses for speakers).
3. Otherwise `nil` (unknown).

Why this order: the toolbar is the control the user actually presses, is
present in every view (Speaker, Gallery, minimised to a strip) and does not
depend on the self name, which figg only reads from a second window that
is not always open. The tile is a good fallback because its label format is
already verified on Zoom 7.1.9. When both answer and disagree, the toolbar
wins; it updates instantly while tile labels can lag.

The toolbar labels above are not yet checked against a live Zoom (the tile
labels are). The parser accepts the likely variants, unknown labels fall
through to the tile, and the manual checklist adds a step that confirms it.
See Open questions.

`ZoomReader.walk` today returns at video tiles and stops at depth 8 and
4000 elements. It will also record `kAXDescriptionAttribute` (falling back
to `kAXTitleAttribute`) of elements whose role is `AXButton` and pass the
list to `ZoomReading.snapshot(..., buttonLabels:)`. The walk limits and the
250 ms messaging timeout stay as they are, so a hung Zoom is bounded as
today, but each poll makes a few more AX calls (one title read per button),
so polls can be slower than today on a busy Zoom. The timeline rule below
credits each muted reading until the next reading, so slower polls do not
open gaps; only a missed poll (more than twice the interval) does.

## Types and files

Changed, in `FiggMeetingApps` (behind the existing `MeetingAppReader`
protocol; Accessibility is the external dependency and stays inside
`ZoomReader`):

- `MeetingAppSnapshot.swift`: `selfMuted: Bool?` (nil = not known), added
  as a trailing init parameter with default `nil` so existing callers and
  tests compile unchanged.
- `ZoomReading.swift`: `selfMuted(fromButtonLabels:)`,
  `selfMuted(buttonLabels:tiles:selfName:)` (the order above), and
  `snapshot(tiles:windowWidth:windowHeight:selfName:buttonLabels: = [])`
  filling `selfMuted`.
- `ZoomReader.swift`: collect button labels during the existing walk.
- `SpeakerTimeline.swift`:
  - `public struct Stretch: Codable, Sendable, Equatable { start, end }`
    with a public init, and `var muted: [Stretch] = []`.
  - A hand-written `init(from:)` using `decodeIfPresent` for `spans`,
    `participants` and `muted` (synthesized `Codable` requires every key,
    so a `speakers.json` from today, which has no `muted` key, would fail
    to load without it). Encoding stays synthesized.
  - `record(_:at:interval:maxGap:names: Bool = true)`: as today, plus mute
    handling, done before the existing `guard let snapshot` so a nil
    reading counts. The timeline keeps the time and mute value of the last
    reading (`lastReadingAt`, `lastWasMuted`, not encoded). Every reading
    (nil included) is one of muted (`selfMuted == true`) or not muted
    (false, nil, or no snapshot):
    - If the previous reading was muted and this one comes within
      `2 * interval` of it, the open stretch's end moves to `time` (the
      previous reading is credited until this one).
    - If the previous reading was muted and this one is later than that
      (a missed poll), the open stretch stays ending at the previous
      reading's `time + interval` and is closed.
    - If this reading is muted and there is no open stretch (first
      reading, or the previous one was not muted, or the gap closed it), a
      new stretch starts at `time` with end `time + interval`. If it is
      muted and a stretch is open, it continues and its end becomes
      `time + interval`.
    - A not-muted reading closes any open stretch at its own `time`.
    So a stretch never spans a not-muted reading, uneven timer spacing
    neither leaves holes nor overruns the next reading, and a gap can only
    end a stretch, never fill one. After a relaunch (crash recovery during
    recording) the loaded timeline has no open stretch, so recording
    resumes cleanly.
  - `names: false` skips speaking spans, `participants` and `selfName`, so
    nothing about the other people is stored when "Name speakers on Zoom
    calls" is off but this feature is on.
  - `mutedShare(start:end:) -> Double`: muted seconds within [start, end]
    divided by its length; 0 for a zero or negative length. The one place
    this is computed; `MuteFilter` and `SpeakerWatcherSlot` both call it.
- `SpeakerWatcher.swift`: takes `names: Bool = true` (so existing callers
  and tests compile unchanged) and passes it to `record`;
  `save()` also saves when `muted` is non-empty; `SpeakerWatcherSlot` gains
  `mutedShare(meetingId:start:end:) -> Double` (0 when no watcher or
  another meeting).

New, in `FiggTranscription`:

- `MuteFilter.swift` (pure enum):
  - `static let minShare = 0.5`.
  - `isMuted(_ line:, timeline:)`: `line.speaker == .me &&
    timeline.mutedShare(start: line.start, end: line.end) >= minShare`.
    Call-audio lines (`.them`) are never dropped.
  - `drop(_ lines:, muted: SpeakerTimeline?) -> [TranscriptLine]`.
  - `unmutedTurns(_ turns:, muted:, offset:) -> [SpeakerTurn]`: cuts the
    muted parts out of each turn (a turn can split in two), so muted room
    speech does not add talk time when `SpeakerLabels.labels` picks "Me".
    The cut turns are used only for that ranking; lines are still matched
    to voices with the original turns, so a kept line that is partly muted
    keeps its usual label.
  All return the input unchanged when there are no stretches.

Changed, in `FiggTranscription`:

- `TranscriptionQueue.swift`:
  - new init parameters `skipMuted: @Sendable () -> Bool = { false }` and
    `liveMutedShare: @Sendable (meetingId, start, end) -> Double = { _, _, _ in 0 }`
    (defaults keep every existing caller and test as is).
  - `process`: for a mic chunk, when `skipMuted()`, drop lines with
    `liveMutedShare(...) >= MuteFilter.minShare` before `store.append`.
    The chunk still moves to `done/` either way, so the final pass and
    "Keep audio" see the same files as today.
  - `finalPass`: loads the timeline once (`saved`); `timeline` for names
    stays "saved with non-empty spans" as today; `muted` is `saved` when
    `skipMuted()` and it has stretches, else nil. For the mic stream,
    `SpeakerLabels.apply` gets a new optional `rankTurns:` argument
    (default nil = use `turns`, so every existing call is unchanged) set to
    `MuteFilter.unmutedTurns(...)`; then `MuteFilter.drop` runs on the mic
    lines, before `EchoFilter`.
    The final pass reads the file, so crash recovery (which calls the same
    `finalPass` after relaunch) treats the meeting as the live pass did.

Changed, in `FiggConfig`:

- `Transcription.skipMicWhenMuted = true`, key `skip_mic_when_muted`, a
  lenient `decodeIfPresent`, and a commented line in `yaml()` after
  `meeting_app_names`.

Changed, in the app (wiring only, no logic):

- `AppSettings.swift`: `nonisolated let skipMicWhenMuted = AtomicFlag()`,
  set in `init` and `save()` next to `keepAudio`, because
  `TranscriptionQueue` calls its closures off the main actor and
  `AppSettings` is `@MainActor`.
- `AppModel.swift`: pass `skipMuted` (reads `settings.skipMicWhenMuted.value`) and
  `liveMutedShare` (the slot) to `TranscriptionQueue`; start the watcher
  when `meetingAppNames || skipMicWhenMuted`, with
  `names: meetingAppNames`. The Accessibility check is unchanged and figg
  still never asks for Accessibility here; the one-time banner stays, with
  its text chosen by which settings are on (names only: today's text; mute
  only: "figg can leave out what your mic hears while you are muted on
  Zoom..."; both: a sentence naming both), each ending "nothing leaves
  this Mac".
- `SettingsView.swift`: a toggle "Skip my mic while I'm muted on Zoom"
  right after "Name speakers on Zoom calls", with a caption, and
  `MeetingAppNamesStatus(enabled: meetingAppNames || skipMicWhenMuted)` so
  the Accessibility status shows when either needs it.

Docs: `docs/manual-test-checklist.md` (steps under "Zoom speaker names"),
`docs/agent-setup.md` (one sentence in the Zoom bullet naming the new
toggle), and the AGENTS.md known gap on Zoom (mute is read too, toolbar
labels unverified).

## Alternatives considered

- **Own tile only.** Needs `selfName`, read from the Zoom Workplace
  window's account button, which is often not open during a call; then
  the feature silently does nothing. Kept as the fallback.
- **Toolbar only.** One source; if its label wording differs from what we
  guess, nothing works until fixed. The tile fallback covers that.
- **Stop or discard mic capture while muted.** Out of scope (the spec keeps
  "Keep audio" as is), and it would also lose audio if a reading was
  wrong. Filtering lines is reversible in spirit and keeps the files.
- **Silence the muted samples before the final pass transcribes.** Would
  change ASR context and run boundaries, and so could change unmuted lines
  near a cut; dropping whole lines by overlap is simpler and testable.
- **A separate `mute.json`.** Two files to keep in step and to recover;
  one file with an optional key is simpler and the spec allows it.
- **Drop a line on any overlap.** A one-second unmute lag at the start of
  a reply would cost the whole line; the spec's half-covered rule is used.

## Failure modes

| What happens | What the user sees |
|---|---|
| No Accessibility | Watcher never starts; the existing one-time banner (when Zoom is open); transcript exactly as today. |
| Zoom not open, or no meeting window | `read()` returns nil every poll; no stretches; transcript as today. |
| Zoom changes its labels | `selfMuted` is nil; no stretches; transcript as today. Checklist step catches it. |
| Zoom hangs | 250 ms AX timeout per call, on the watcher's own queue; recording and transcription are not held up; missed polls end any stretch. |
| A reading flickers unmuted inside a muted stretch | The stretch splits; lines over the split are judged by total muted share, so a 0.5 s flicker does not keep a 10 s line. |
| Muted but you talk anyway | Lines at least half inside the stretch are dropped. That is the intended outcome; the setting turns it off. |
| You unmute mid-line | A line under half muted is kept whole. |
| Transcription backlog outlives the watcher (after Stop) | Late live lines are not filtered (`mutedShare` is 0 once the slot is cleared), but the final pass, run right after, filters from the file. |
| Crash during recording | `speakers.json` is saved every 5 s; recovery's final pass uses it. At most the last 5 s of mute info is lost, which can only keep lines. |
| Old `speakers.json` | Loads with `muted = []`. |
| Setting turned off between recording and final pass | The final pass uses the setting at that time and keeps every mic line. |
| You are on "Phone audio" or have not joined audio | The toolbar button reads "Join audio"; unknown; nothing dropped. |
| Host with the Participants panel open | Several Mute/Unmute buttons are found; unknown unless the toolbar is the only one; the own-tile fallback still applies; never a false "muted" from a panel row. |
| Slow but responsive Zoom (polls 0.6 to 1 s apart) | Each muted reading is credited until the next one, so no holes; only polls over 1 s apart (2x interval) end a stretch, which can only keep lines. |
| A long final-pass line (Parakeet without token timings, or unpunctuated speech, can give one segment for a whole run) | The half rule applies to the whole line: muted for most of it drops all of it, including the unmuted part; muted for less keeps all of it. Accepted, as the spec sets the rule per line; noted for the checklist run. |
| Muted in a Zoom meeting while talking on another app's call (e.g. a browser call) | Zoom says muted, so mic lines are dropped. The setting turns it off; mute for other apps is out of scope. |

## Hard rules

1. Audio never leaves the Mac: only Zoom's on-screen labels are read,
   locally; nothing new is sent anywhere.
2. No secrets: not touched; no new logging of content (only the existing
   save-failure log).
3. No sampling params: not touched.
4. Build with `bundle.sh`: not touched; CI builds and tests.
5. Testable logic: parsing in `ZoomReading`, timeline logic in
   `SpeakerTimeline`, filtering in `MuteFilter`, all pure; Accessibility
   stays behind `MeetingAppReader`, ASR behind `Transcriber`
   (`FakeTranscriber` in tests). Views only bind a toggle.
6. Settings in `FiggConfig`: `skip_mic_when_muted` with a default,
   `decodeIfPresent`, a commented `yaml()` line and a round-trip test.

## Tests

All Swift Testing, run by CI's `test` job on macOS.

| Criterion | Test |
|---|---|
| Own mute state: muted / unmuted / unknown | `ZoomReadingTests`: `selfMuted(fromButtonLabels:)` with invented labels "Unmute audio", "Mute audio", none, both, "Mute all", "Unmute video", and several bare "Unmute" panel-row labels with no toolbar (must be nil); tile fallback with `selfName` and invented tile labels; toolbar wins over a disagreeing tile; two tiles with your name gives nil; `snapshot` fills `selfMuted`. |
| Readings join into stretches; a gap ends one | `SpeakerTimelineMuteTests`: muted readings at 0, 0.5, 1.0 give one stretch [0, 1.5]; uneven readings muted@0.1, unmuted@0.5, muted@0.8 give [0.1, 0.5] and a new stretch from 0.8; muted@0, muted@0.8 (slow poll) give one stretch; muted@0, muted@1.5 (missed poll) give two; a nil reading and an unknown reading each end a stretch at their time; `mutedShare` overlap and zero length; `names: false` records no spans, participants or self name. |
| Save/load, today's format loads | `SpeakerTimelineTests`: round trip with stretches; decoding a JSON literal in today's format (no `muted` key) gives `muted == []` and the same spans. |
| Live mic lines dropped at >= half, kept below, system never | `MuteFilterTests` for `share`/`drop` with lines inside, half, partly overlapping and outside a stretch on both streams; `TranscriptionTests`: queue with `skipMuted: { true }` and a fixed `liveMutedShare` drops the mic line and keeps the system line. |
| Final pass drops muted mic lines; muted audio does not pick "Me" | `MuteFilterTests.unmutedTurns` (a turn split and removed); `SpeakerTests`: `apply` with `rankTurns` ranks by them but labels lines by `turns`; `TranscriptionTests`: `finalPass` with two new fakes added to that file, `ScriptedTranscriber` (returns given segments, several mic lines) and `ScriptedSeparator` (returns given turns), and a saved `speakers.json` with a stretch: no mic line at least half inside it; a room voice whose talk time is mostly muted does not become "Me". |
| No mute info = today | `TranscriptionTests`: the same input through `finalPass` with no `speakers.json`, and with one that has spans but no stretches, gives identical transcripts; live path with `liveMutedShare` 0 likewise. |
| Setting off keeps every mic line | `TranscriptionTests`: `skipMuted: { false }` with a saved stretch keeps the mic lines live and after the final pass. |
| Setting round-trips, defaults on, in Settings | `ConfigTests`: round trip with `false`, missing key decodes `true`, `yaml()` contains the commented line; the toggle is proved by CI building the app. |
| Manual checklist | `docs/manual-test-checklist.md` entry. |
| Existing tests unchanged; CI | CI `test` and `gates` jobs. |

## Open questions

- The exact Accessibility label of Zoom's toolbar audio button has not been
  read on a live Zoom (only tile labels were, on 7.1.9). The parser accepts
  "Mute"/"Unmute" with an optional "audio"/"my audio"; if Zoom uses
  something else, the tile fallback still works when the self name is
  known. Confirm during the checklist run and adjust the parser (with a
  test) if needed.
- Whether Zoom's toolbar is in the AX tree when it auto-hides. If not, the
  tile fallback applies; the checklist step covers it.

## Review notes

First design-critic round (verdict: revise). All findings were taken:

- The setting is read off the main actor through an `AtomicFlag` on
  `AppSettings`, like `keepAudio`; `AppSettings.swift` added to P5.
- The toolbar parser answers only when exactly one mute/unmute button is
  found, so a host's Participants panel cannot read as "you are muted".
- `record` tracks the last reading's mute value: a stretch never spans a
  not-muted reading, and each muted reading is credited until the next
  reading (up to 2x interval), so slow polls leave no holes and uneven
  timer spacing cannot overrun.
- Failure-mode rows added for slow polls, the Participants panel, long
  final-pass lines and being muted in Zoom while talking elsewhere.
- The banner text follows which settings are on, and the Settings
  Accessibility status shows when either setting needs it.
- `names: false` also skips participants and the self name.
- `mutedShare` lives once on `SpeakerTimeline`.
- `Stretch` is `Codable, Sendable, Equatable` with a public init;
  `SpeakerWatcher(names:)` defaults to true.
- New fakes `ScriptedTranscriber` and `ScriptedSeparator` are named for P4.
- Cut turns only rank voices for "Me"; lines are labelled with the
  original turns (`SpeakerLabels.apply(rankTurns:)`, `Speakers.swift`
  added to P4).
- Plan note on parallelism corrected.

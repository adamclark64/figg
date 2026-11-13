# Transcript quality: duplicate lines and speaker labels

Research spike for [issue 17](https://github.com/adamclark64/figg/issues/17).
What we saw: a "Me" line followed by a "Them" line with the same words,
nearly every time someone on the call talks. Automatic speaker detection
("People in the room: Auto") also gets rooms wrong. This doc gives the
causes and a plan in order of payoff.

**Status:** steps 1 to 3 are built (the `--echo` bench, echo cancellation
in the final pass, and the echo detector live and after Stop), all on by
default, and measured on one real call (below). Steps 4 to 6 are still to
do.

**First measurement** (`figg-asr-bench --echo`, synthetic call: two `say`
voices, the remote one mixed into the mic at 40 ms and a third of the
volume, plus one reflection; MacBook Air M4):

| | Mic lines | Duplicates before word filter | Mic WER | Voices on the mic |
|---|---|---|---|---|
| Raw mic | 9 | 56% | 130% | 2 |
| Echo cancelled | 3 | 0% | 0% | 1 |

Cancellation took 4.5 s for 26 s of audio, including the model load. A
real call is still to be measured.

## What causes it

### 1. The mic hears the speakers

Without headphones the call audio plays out of the Mac's speakers and goes
straight back into the mic. figg records the mic and the system audio as two
streams and transcribes both, so every remote sentence is transcribed twice:
cleanly from system audio ("Them") and roughly from the mic ("Me").

The meeting apps cancel this echo only in the audio they *send*. figg taps
the raw mic, before any of that, so it gets the echo in full.

What figg does about it today (`Sources/FiggTranscription/EchoFilter.swift`):

(This section describes figg before steps 2 and 3; see "Measurements".)

- **Live lines are never filtered.** The doubling stays until Stop.
- **After Stop the filter matches words, not sound.** A mic line is dropped
  only if 70% of its words appear in order in a system line within 1.5 s,
  and lines under 3 words must match exactly. The mic copy comes through a
  room, so Parakeet often hears it differently ("ship it Friday" vs "shipping
  Friday"). Those lines miss the cut-off and stay, as both Me and Them.

### 2. The echo breaks "Auto" speaker detection

The final pass diarizes the mic stream (`FluidSpeakerSeparator`) with the
echo still in it, so:

- Remote voices played through the speakers count as people in the room
  and become "Guest 1", "Guest 2".
- "Me" is whoever talks most on the mic (`SpeakerLabels.labels`). On a call
  where a remote person talks more than you, their echo wins, and *they*
  become "Me" while you become a Guest.

The diarizer can't tell a voice in the room from the same voice out of a
speaker. But figg has something better than guessing: the exact signal the
speakers played (the system audio stream). Any mic sound that matches it,
shifted by a few tens of ms, came from the speakers, not a person.

### 3. A line gets one label even when two people speak in it

`ParakeetTranscriber.segments` cuts lines only at `.`, `?` or `!`, then
throws the word timings away. `SpeakerLabels.speaker(for:)` then gives the
whole line to whichever speaker overlaps it most. A quick back-and-forth
without punctuation becomes one line with one name.

## What's available (all on-device)

| Option | What it is | Fit |
|---|---|---|
| **FluidAudio `LocalVqeManager`** | Neural echo cancellation, noise suppression and dereverb (LocalVQE, Apache-2.0). Takes the mic plus a *reference* (what the speakers played) and returns the mic with the echo removed. Batch (256 ms) and streaming (16 ms) modes, CPU, 14x to 60x real time. | **Best.** Already in the FluidAudio version we pin (0.18.2), so no new dependency. Our system audio stream *is* the reference it needs. Marked beta by FluidAudio. |
| Apple voice processing (`inputNode.setVoiceProcessingEnabled`) | The OS echo canceller. | Weaker fit. It's built to cancel audio played through the same engine; it isn't clear it cancels other apps' audio. It also changes the mic format (Apple forums report 1 to 5 channels), lowers the volume of other audio, and can clash with the call app's own voice processing. |
| Signal-level echo detector (ours) | For short frames, compare mic loudness with system loudness at the best-matching delay. Mic sound that tracks system audio is echo; mic sound when the system is quiet, or that doesn't track it, is a person in the room. | Cheap, deterministic, easy to unit-test with synthetic signals. Works live, where the word match can't. This is the "detect where the speech is coming from" check. |
| FluidAudio Sortformer `enrollSpeaker` / `CampPlusEmbedder` | A voice print from a short sample, matched against diarized speakers. | Lets "Me" be *your voice* rather than "most talkative". Sortformer allows 4 speakers at most; FluidAudio says enrollment across sessions may be unreliable. |
| Active-speaker from the call app | Granola labels remote speakers by reading Zoom's on-screen active-speaker indicator through Accessibility. | Gives real names for "Them 1/2/3". Only UI text is read, never audio. Each app needs its own code, and it breaks when the app's UI changes. |
| FluidAudio CTC vocabulary boosting | Biases Parakeet toward a word list, e.g. attendee names from the calendar. | Better names and jargon. Adds a ~130 MB model for Parakeet v3. |

## Plan, in order

1. **Measure first.** Record one real no-headphones call (consented, kept
   locally, never committed if private) and add a "duplicate rate" to
   `figg-asr-bench`: the share of mic lines that repeat a system line. Run it
   before and after each step. Also add a synthetic case to the bench: play a
   `say` voice "through the speakers" by mixing it, delayed and quieter, into
   a mic track with a second voice.
2. **Cancel the echo in the final pass.** Before transcribing the mic stream,
   line the system samples up with the mic on meeting time (their offsets
   differ) and run `LocalVqeManager.process(mic:reference:)`. Transcribe and
   diarize the cleaned mic. This fixes both the duplicates and the fake
   Guests after Stop. Keep `EchoFilter` as a safety net. Put it behind a new
   `transcription.echo_cancellation` setting (default on) so it can be
   switched off if the beta model misbehaves.
3. **Detect echo by sound, live.** Add the signal-level detector to
   `FiggTranscription` (pure function over two sample arrays, with tests).
   Drop live mic lines whose time span is mostly echo, so the doubling goes
   away during the meeting too. Use it as a second check in `EchoFilter`,
   so a mic line that is all echo goes even when its words don't match.
4. **Split lines at speaker changes.** Keep Parakeet's word timings on
   `TranscriptSegment` and cut a line wherever the diarizer's speaker turn
   changes, instead of labelling whole sentences.
5. **"Me" by voice.** Optional one-time "teach figg your voice" (10 to 20 s)
   in Settings. Store the voice print locally under Application Support
   (not config.yaml, not the network), and label the mic speaker closest to
   it as Me. Fall back to most-talkative when there's no voice print.
6. **Later.** Names for remote speakers from the call app's active-speaker
   indicator; vocabulary boosting with attendee names; streaming LocalVQE
   for live lines once step 2 is proven.

Steps 2 and 3 should fix the duplicates. Steps 4 and 5 fix "Auto".

## Measurements

`swift run -c release figg-asr-bench --echo [meeting folder]`. With a folder
it also replays the chunks through `TranscriptionQueue` to count live lines.

### First real call: LocalVQE removed nothing

A 54 s YouTube news clip (two speakers) on MacBook speakers, no headphones,
nobody in the room talking. With steps 1 and 2 only:

| | Mic lines | Duplicates (before / after word filter) | Voices on the mic |
|---|---|---|---|
| Raw mic | 11 | 100% / 0% | 2 |
| Echo cancelled | 11 | 100% / 0% | 2 |

The saved transcript was right only because the word filter caught every
copy: loud speakers make the mic's copy nearly word for word. Live, every
line showed twice.

The cause was alignment, not the model. The mic's copy of the call came
**55 ms before** the system samples it echoed on meeting time (the two
streams start up separately and their chunk offsets are off by that much),
and the echo was 2.9 dB *louder* than the system audio. A canceller can't
remove an echo that arrives before its reference. Moving the reference
earlier by hand: 40 ms left all 11 lines; 60, 70, 100 and 200 ms removed all
of them. So LocalVQE works once the reference is 4 to 144 ms ahead of the
echo.

(A first attempt recorded no system audio at all: the System Audio
Recording prompt appeared mid-recording, and the tap set up before the grant
never delivered buffers. figg's 30 s silence warning only counts buffers
that arrive, so it said nothing. Relaunching fixed it.)

### Step 3: `EchoDetector`

`Sources/FiggTranscription/EchoDetector.swift`, pure functions over two
sample arrays:

- `estimateDelay` correlates the mic's and the system's loudness (5 ms
  frames, in dB, ±1 s) over the frames where the call is sounding. Scoring
  only those frames matters: people take turns, so over a whole recording the
  mic is loudest when the call is quiet, and a plain correlation came out
  negative on the synthetic call even at the right delay. Echo scored 0.85 to
  0.94; headphones 0.05; the cut-off is 0.3.
- `map` marks 20 ms mic frames quiet, echo or speech: echo when the mic is
  no more than 2x (+6 dB) as loud as the speakers' sound would make it, using
  the median mic/system ratio as the speakers' gain and a 100 ms room tail.
  A person talking over the call makes the mic clearly louder.
- A line is echo when 70% of its sounding frames are. Live, each mic chunk is
  checked against the system chunks recorded with it (waiting up to 1 s for
  one written just after it); after Stop the map of the raw mic is a second
  check in `EchoFilter`, and its delay places LocalVQE's reference 50 ms
  ahead of the echo.

### Results with step 3

| Case | Delay found | Live "Me" copies | After Stop: echo "Me" lines | Near-end WER of kept Me lines |
|---|---|---|---|---|
| Real call (news clip) | -55 ms, 0.85 | 10 → 0 (replay) | 11 → 0 (LocalVQE alone) | (nobody spoke) |
| Synthetic, laptop speakers | +40 ms, 0.94 | 5 of 8 mic lines dropped, all echo | 0 | 0% |
| Synthetic, loud echo, offsets 100 ms off, talking over | -60 ms, 0.89 | 5 of 9 dropped | 0 | 6.1% (the reply that overlapped lost "Tuesday works") |
| Synthetic, headphones | none (0.05) | nothing dropped | 0 | 0% |

Delay search and frame map took about 10 ms for the 54 s call; LocalVQE 3 to
4 s including model load.

### Second real call: the system stream was stamped 2.5 s early

The same kind of clip, 2 minutes, on build 20 (step 3 in place). The live
transcript still doubled every line, and the detector reported no echo.
The echo was there, steady through the call, at **+2.53 s**: outside the
detector's ±1 s search. The system stream was 2.6 s shorter than the mic but
its first chunk was named 0.2 s. `ChunkWriter` took each stream's start from
when capture was requested, and this time the system audio tap took about
2.5 s to deliver its first buffer.

Fix: each stream's start is now the arrival of its first buffer minus that
buffer's length. Replaying this call with its system chunks re-stamped that
way: delay -5 ms (0.88), live "Me" copies 30 to 0, final-pass echo lines 22
to 0.

### Third real call: the live check judged before the system audio arrived

Build 22, with the first-buffer timing. Offsets were now right (echo 4 ms
after the system audio) and the final pass removed every copy, but live
lines still doubled. The system tap started 2.2 s after the mic, so each
system chunk finished 2.2 s after the mic chunk it overlaps; the live check
waited only 1 s and then counted mic frames with no system audio beside
them as room speech.

Fix: the live check judges only the part of a mic chunk the system audio
covers, and waits up to 12 s for that audio (after one timeout it stops
waiting until a newer system chunk appears, so a dead system stream cannot
stall the queue). `BENCH_REALTIME=1` replays a meeting's chunks at the
moments the recorder finished them; on this call it gives the 5 live "Me"
copies seen in the app with the old code and 0 with the fix.

### Fourth real call: your speech kept, but labelled "Guest 1"

Build 25. You talked first ("This is me. I'm talking and I'm about to start
a YouTube."), then played a clip. Live: 1 "Me" line (yours) instead of 15.
After Stop your lines were kept, but:

- **You were "Guest 1".** The diarizer still found two voices on the cleaned
  mic: you, and what LocalVQE left of the clip. The clip talked longer, so it
  took "Me". Now `SpeakerLabels.apply` gets the echo map: a mic voice whose
  sounding time is at least 70% echo is the speakers, is left out when
  choosing "Me", and its lines are dropped.
- **One garbled echo line survived** ("If you think that, and that's
  election to be true.", echo share 0.60, under the 0.7 line cut-off). Its
  words were LocalVQE's leftovers: the canceller kept 0.00 of the raw mic's
  level there, against 0.95 to 1.00 for your own lines and 0.66 to 0.73 for
  synthetic speech over the call. After Stop, a mic line now goes when the
  canceller kept under 10% of its level (`EchoDetector.levelKept`). Lowering
  the share cut-off instead would have dropped real speech: two genuine
  synthetic lines scored 0.54 and 0.57.

The bench now replays the app's final pass on a recording and prints the
transcript as saved; on this call it gives your two lines as "Me" and no
echo lines.

**The "Me" waveform** in the strip and the pill moved for the clip too. While
system audio runs, `LevelMeter` now holds each mic bar 0.25 s until the
system bars from the same moment are in, and `EchoGate` draws it flat when
the mic's loudness has been following the call (correlation 0.5 or more over
the last 10 s) and the bar is no more than 2x the predicted echo. Fed the
real calls as the app delivers them: 95% and 91% of echo bars flattened, and
none of your speech; synthetic laptop 82% of echo, 0% of speech; headphones
0%.

Still open:

- **Your own speech over the call.** On the fourth call you talked before
  the clip, not over it. Record one where you talk over the other side.
- **"Voices found: 2" on the cleaned real mic** even though it transcribes to
  nothing: the diarizer still finds two speakers in what LocalVQE leaves. It
  doesn't show (no mic lines means no Guest labels), but may matter for
  step 5.
- **Drift.** One delay is used for the whole recording. Check a long meeting;
  if the streams drift, estimate per window.
- Headphones, Bluetooth and AirPods for real, and the first-chunk race in the
  live check on a slow Mac.

## Risks

- LocalVQE is beta, and FluidAudio says it hasn't been run inside real call
  pipelines. On the one real call it removed all the echo once the
  reference was lined up.
- Lining the streams up: the chunk offsets were 55 ms wrong on the real
  call, enough to make LocalVQE useless; `EchoDetector` now measures the
  delay from the audio. If the streams drift apart over a long meeting,
  estimate it per window.
- Bluetooth headsets switch to a low-quality call mode, and AirPods route
  differently. With real headphones there's no echo, so the cancellation
  should leave the mic unchanged. That needs checking.
- A voice print comes from audio. It must never leave the Mac (hard rule 1)
  and should be deletable from Settings.

## Sources

- FluidAudio docs, in the pinned 0.18.2 tag: `Documentation/Enhancement/LocalVQE.md`,
  `Documentation/Diarization/GettingStarted.md`, `Documentation/ASR/CustomVocabulary.md`,
  `Documentation/ASR/LongTranscription.md`
- [Granola: how transcription works](https://docs.granola.ai/help-center/taking-notes/transcription)
  (Me/Them from mic vs system audio; Zoom speaker names via Accessibility)
- [Recall.ai: acoustic echo cancellation](https://www.recall.ai/blog/acoustic-echo-cancellation)
- Apple forums: [voice processing raises channel count](https://developer.apple.com/forums/thread/771530),
  [voice processing in several apps at once](https://developer.apple.com/forums/thread/751100)

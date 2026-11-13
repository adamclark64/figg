# Transcript quality: duplicate lines and speaker labels

Research spike for [issue 17](https://github.com/adamclark64/figg/issues/17).
What we saw: a "Me" line followed by a "Them" line with the same words,
nearly every time someone on the call talks. Automatic speaker detection
("People in the room: Auto") also gets rooms wrong. No code has changed yet;
this doc gives the causes and a plan in order of payoff.

## What causes it

### 1. The mic hears the speakers

Without headphones the call audio plays out of the Mac's speakers and goes
straight back into the mic. figg records the mic and the system audio as two
streams and transcribes both, so every remote sentence is transcribed twice:
cleanly from system audio ("Them") and roughly from the mic ("Me").

The meeting apps cancel this echo only in the audio they *send*. figg taps
the raw mic, before any of that, so it gets the echo in full.

What figg does about it today (`Sources/FiggTranscription/EchoFilter.swift`):

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

## Risks

- LocalVQE is beta, and FluidAudio says it hasn't been run inside real call
  pipelines. Step 1's measurement is what tells us whether it helps.
- Lining the streams up: the mic and system streams start at different
  times, and the speaker-to-mic path adds delay. The model handles a delay
  window, but our offsets need to be right to within that window. If the
  streams drift apart over a long meeting, run it in windows that re-align.
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

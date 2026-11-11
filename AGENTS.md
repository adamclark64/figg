# AGENTS.md: figg

Orientation for AI agents and new contributors. Read this before changing
architecture.

Here to install and configure figg on someone's Mac, not to change its
code? Follow [docs/agent-setup.md](docs/agent-setup.md) instead. Keep that
guide in step with the app: if you rename a setting, a Settings label, an
error message or a script it quotes, update it in the same change.

## What this is

A native macOS (SwiftUI) meeting notes app in the style of Granola. Pipeline:

```
Recorder (FiggAudio) → 10 s chunk files in meetings/<id>/pending/
  → TranscriptionQueue + ParakeetTranscriber (default) or WhisperKitTranscriber
    → live lines; on Stop, finalPass re-transcribes the whole recording
      and FluidSpeakerSeparator labels speakers (Me / Guest N / Them N)
  → transcriptLine rows (FiggStore)
  → Enhancer / NotesChat (FiggNotes) → LLMProvider (FiggLLM): BedrockProvider
    or OpenAICompatibleProvider, chosen by llm.provider
  → Formatters / AtlassianClient (FiggExport)
```

`Sources/Figg` is the app: `AppModel` owns the pipeline and all state;
views are thin.

## Hard rules

1. **Audio never leaves the Mac.** Never send audio or audio-derived
   features to any network service. Only text goes to the model provider
   (Bedrock by default).
2. **No secrets on disk or in logs.** AWS creds come from the CLI at runtime
   and stay in memory. Atlassian email/token and model provider API keys
   live in the Keychain (`FiggExport/Keychain.swift`). Never log request
   headers or bodies.
3. **No sampling params to Claude.** Do not add `temperature`, `top_p` or
   `top_k` to `BedrockProvider.body`; current Claude models reject them.
   `OpenAICompatibleProvider.body` follows the same rule.
4. **Build the .app with `scripts/bundle.sh` (xcodebuild), not `swift build`.**
   Resource bundle lookup crashes otherwise. Sign with the "figg Local
   Signing" cert (`docs/local-signing.md`) or macOS drops the
   mic/system-audio permissions on every rebuild.
5. **Keep logic testable.** External things sit behind protocols:
   `Transcriber`, `LLMProvider`, `CredentialsProvider`, `HTTPClient`. Put
   logic in the library targets, not in views.
6. **Settings go in `FiggConfig`** (config.yaml), never UserDefaults, and
   never secrets. Add a field with a default, a lenient `decodeIfPresent`, a
   commented line in `yaml()`, and a round-trip test.

## Commands

```bash
swift build
```

```bash
swift test
```

```bash
scripts/bundle.sh && open build/Figg.app
```

`FIGG_LIVE=1 FIGG_PROFILE=<name> swift test --filter LiveBedrockTests` makes
two real (tiny) Bedrock calls; needs working credentials for that profile
(for an SSO profile, `aws sso login --profile <name>`).

`FIGG_LIVE=1 FIGG_OPENROUTER_KEY=<key> swift test --filter LiveOpenRouterTests`
makes one real call to OpenRouter's free router.

`cd site && npm install && npm run dev` builds the website into `site/dist`
and serves it on http://localhost:4173. The docs pages are the repo's own
Markdown: change the `.md` file, never the built HTML.

`swift run figg-audio-probe` records 6 s and prints per-stream levels; all-zero
system audio means the System Audio Recording permission is missing.
Run it inside the app, with figg's own permissions, via
`open build/Figg.app --args --probe-audio` (report in /tmp/figg-probe.txt).
Do not quit or relaunch figg while the user may be recording.

`swift run figg-audio-probe --mic-users` lists apps holding the mic right now
(what meeting detection sees).

`swift run -c release figg-asr-bench --diarize` checks speaker separation on a
three-voice conversation (`BENCH_SPEAKERS=3` to give the count).

`swift run -c release figg-asr-bench` compares Parakeet and Whisper on the
same audio (`BENCH_CHUNK=30`, `BENCH_ONLY=parakeet` to vary). Run it before
changing engines or chunking.

Always read audio with `AudioChunk.readMono`, never a single
`AVAudioFile.read`.

`FIGG_WER=1 swift test --filter wordErrorRate` runs the transcription accuracy
check against WAV/TXT pairs in `Tests/FiggTranscriptionTests/Fixtures/`
(none recorded yet; it needs the model download).

## Conventions

- Swift 6.3 toolchain in **Swift 5 language mode**. UI state is
  `@MainActor`; audio callbacks run on their own queues.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), in-memory
  `Store.inMemory()`, and fakes (`FakeLLM`, `FakeHTTP`, `FakeTranscriber`).
- Code style: small focused files, doc comments on types and non-obvious
  functions explaining *why*. No em-dashes in comments or docs.
- Commits: Conventional Commits. release-please builds the changelog and
  version from these subjects, so feat/fix wording is user-facing.

## Where to look

| Task | File |
|---|---|
| Recording, permissions | `Sources/FiggAudio/Recorder.swift`, `SystemAudioCapture.swift` |
| Speech-to-text, final pass | `Sources/FiggTranscription/` (`TranscriptionQueue.finalPass`) |
| Schema, search | `Sources/FiggStore/Store.swift` (migrations in `migrator`) |
| Prompts | `Sources/FiggNotes/Enhancer.swift`, `NotesChat.swift` |
| Bedrock, SigV4 | `Sources/FiggLLM/` |
| Other model providers (OpenRouter...) | `Sources/FiggLLM/OpenAICompatibleProvider.swift`, `FiggConfig.LLM` |
| Slack/Confluence/Jira | `Sources/FiggExport/` |
| Meeting lifecycle, crash recovery | `Sources/Figg/AppModel.swift` |
| Meeting auto-detect | `Sources/FiggAudio/MicUsage.swift`, `MeetingDetector.swift`, `Sources/Figg/MeetingWatcher.swift` |
| Floating recording widget | `Sources/Figg/RecordingWidget.swift` (panel, mouse, views), `Sources/FiggWidget/` (show/hide rule, placement) |
| Calendar (titles, attendees, brief) | `Sources/FiggCalendar/`, `Sources/FiggNotes/Brief.swift` |
| Note templates, quick actions | `Sources/FiggNotes/Templates.swift`, `QuickActions.swift` |
| Settings / config.yaml | `Sources/FiggConfig/FiggConfig.swift`, `Sources/Figg/AppSettings.swift` |
| In-app updates | `Sources/FiggUpdate/`, `Sources/Figg/UpdateManager.swift`, `scripts/publish-dmg-blob.mjs` |
| Bug reporter | `Sources/FiggFeedback/`, `Sources/Figg/BugReportView.swift`, `relay/api/bug-report.js` |
| Colours, fonts, theme | `Sources/Figg/Theme.swift` |
| Website: landing page, docs pages | `site/index.html` (the 3D landing page), `site/build.mjs` (renders README and `docs/` Markdown into `/docs` pages; its `SOURCES` list decides what is published), `site/docs-template.html` (the frame around a docs page) |
| Loading states (fig loader) | `Sources/Figg/FigLoader.swift` (the views), `FigScene.swift` (the spinning fig, the default), `FigNewtonScene.swift` (the fig newton, set with `appearance.loader: newton`), `Loader3D.swift`, `Sources/FiggWidget/LoaderStyle.swift` and `NewtonMotion.swift` (timing) |

## Bug reports

"Report a Bug…" (menu bar menu or Help menu) files a GitHub issue in this
repo via the hosted relay (`relay/`, a zero-dependency Vercel function; the
app never holds a GitHub token). Point the app at the deployed relay with
`feedback.bug_report_endpoint` in config.yaml; when unset, the sheet opens a
prefilled GitHub issue in the browser instead.
Reports carry only user text, user-chosen screenshots and app/OS/engine
versions; never audio, transcripts, notes, meeting titles, calendar data or
logs. The `Daily issue digest` workflow (`.github/issue-digest/README.md`)
posts a read-only triage summary of `user-report` issues each day; it never
edits code or issues.

## Known gaps (v1)

- Bedrock is verified live, but no real call has been recorded and enhanced
  end to end yet (see `docs/manual-test-checklist.md`).
- Mic picks up speaker audio when not on headphones. The final pass drops
  mic lines that echo a system-audio line, but live lines stay doubled until
  Stop, and the echo still reaches the mic diarizer.
- OpenRouter has unit tests only; no live call has been made yet, and free
  models vary a lot in note quality.
- Speaker labels are automatic and "Me" is assumed to be the most talkative
  person on the mic. With the calendar on, attendee names are prompt hints
  and a transcript context menu renames speakers by hand; figg never maps
  voices to names itself.
- If System Audio Recording permission is missing, macOS delivers silence
  rather than an error; figg only warns after 30 s of exact silence.
- Live lines come from 10 s chunks and can be rough at the cuts; the final
  pass on Stop fixes them.
- The widget's screenshot button needs Screen Recording permission, which
  without a Developer ID has to be granted again after each update. Whether
  the pill stays out of screen shares on macOS 15 has not been checked on a
  real call.
- No Developer ID yet, so no notarized `.dmg`.

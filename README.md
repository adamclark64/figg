# figg

A Granola-style meeting notes app for macOS. figg records your meeting (your mic
and the other people on the call), transcribes it **on your Mac**, and turns
your rough notes plus the transcript into clean notes with Claude on AWS
Bedrock. Audio never leaves the computer; only text goes to Bedrock.

- Record from the toolbar, the menu bar, or **⌃⌥⌘R** in any app
- **Meeting detection**: when a meeting app (Zoom, Teams, Meet in a browser, or any other) starts using your mic, figg offers to record, and offers to stop when it lets go
- **Recording widget**: while you are in the meeting app, a small floating pill shows that figg is listening (live levels for you and the call); click the fig to jump back to the note, click the camera for a ⌘⇧4-style screenshot straight to your clipboard, drag it anywhere
- Live transcript labelled **Me** / **Them**, re-checked against the whole recording when you stop (Nvidia Parakeet by default, Whisper optional)
- **Speaker separation**: several people in the room become Me / Guest 1 / Guest 2, several on the call become Them 1 / Them 2 (set "People in the room" while recording for best results)
- **Enhance** writes Summary / Notes / Action items; your own lines stay black, figg's additions are grey
- **Ask figg**: chat across all past meetings
- **Share**: copy as Markdown or Slack, publish to Confluence, create Jira tickets from action items

Setting figg up with a coding agent (Claude Code, Codex, Cursor...)? Point it
at [docs/agent-setup.md](docs/agent-setup.md): install, permissions, model
provider and a smoke test, each step with a check the agent can run.

## Requirements

- Apple Silicon Mac, macOS 14.4 or later
- A model provider: AWS Bedrock (the default; needs the AWS CLI, `brew install awscli`, and a profile that can call Bedrock), or an OpenRouter API key
- Xcode 16+ to build (tested with Xcode 26.4, Swift 6.3)

## AWS access

figg reads AWS profiles from `~/.aws/config`. List the profiles you want
under `aws.profiles` and pick one in Settings > AI. Any profile the AWS CLI
can get credentials for works, with access keys or SSO. An SSO profile needs
a login first:

```bash
aws sso login --profile <name>
```

The profile needs permission for `bedrock:InvokeModelWithResponseStream` on
the configured Claude models. Bedrock usage is billed to your AWS account. To see which model IDs your account offers:

```bash
aws bedrock list-inference-profiles --profile <name> --region us-east-1 --query "inferenceProfileSummaries[?contains(inferenceProfileId,'claude')].inferenceProfileId"
```

## Other model providers (OpenRouter, free models)

Bedrock is the default, but figg can use any OpenAI-compatible chat API. To
run on OpenRouter's free models: create a key at openrouter.ai/keys, then in
Settings > AI pick **OpenRouter** and paste the key (it is stored in the
Keychain). The default model, `openrouter/free`, lets OpenRouter pick a free
model; any ID from openrouter.ai/models works, and free ones end in `:free`.

Free models may log or train on the text they are sent (your notes,
transcript and questions), and their note quality varies. Audio never leaves
your Mac with any provider.

To add another service, add an entry under `llm.providers` in config.yaml:

```yaml
llm:
  provider: "groq"
  providers:
    - id: "groq"
      name: "Groq"
      kind: "openai"
      base_url: "https://api.groq.com/openai/v1"
      models:
        notes: "<model id>"
        fast: "<model id>"
```

Keep the existing entries in the list if you still want them, then type the
key for the new one in Settings > AI.

## Settings: config.yaml

Settings live in `~/.config/figg/config.yaml`. figg creates it on first launch
with comments explaining each key. Edit it by hand or in figg > Settings; figg
reloads it when the app comes to the front. Example, to use Sonnet for better
notes:

```yaml
llm:
  providers:
    - id: "bedrock"
      models:
        notes: "us.anthropic.claude-sonnet-5-5"
    - id: "openrouter"
```

Your Atlassian email and API token are not in this file; they go in Settings >
Sharing and are stored in the Keychain. Model provider API keys are the same:
typed in Settings > AI, kept in the Keychain.

## Check Bedrock access

```bash
FIGG_LIVE=1 swift test --filter LiveBedrockTests
```

This sends two tiny prompts (Haiku and Sonnet) through figg's own Bedrock
client using the `default` profile (set `FIGG_PROFILE` to use another).

## Build and run

```bash
scripts/bundle.sh
```

```bash
open build/Figg.app
```

The first time you record, macOS asks for **Microphone** and **System Audio
Recording** access. figg uses Nvidia Parakeet for speech-to-text; if FluidVoice
is installed the model is already on disk, otherwise figg downloads it once
(~0.5 GB). Set `transcription.engine: "whisper"` in config.yaml to use Whisper.
Build your own copy with the local signing certificate
([docs/local-signing.md](docs/local-signing.md)) so permissions survive rebuilds.

Development loop:

```bash
swift build
```

```bash
swift test
```

## Release a .dmg

Releases are automated with
[release-please](https://github.com/googleapis/release-please): every push to
main updates a "Release PR" that collects Conventional Commits into
`CHANGELOG.md` and bumps the version. Merging that PR tags `vX.Y.Z`, creates
the GitHub Release, and CI
([.github/workflows/release-please.yml](.github/workflows/release-please.yml))
builds and attaches `figg-X.Y.Z.dmg`.

There is no Apple Developer ID yet, so the DMG is ad-hoc signed and not
notarized: right-click > Open on first launch. When a Developer ID exists, add
the secrets listed in the workflow header and the same pipeline signs and
notarizes. [scripts/release.sh](scripts/release.sh) does the signed build
locally; [scripts/dmg.sh](scripts/dmg.sh) is the shared packaging step.

## Docs

- [Manual test checklist](docs/manual-test-checklist.md)
- [Agent setup guide](docs/agent-setup.md): for a coding agent installing and configuring figg on someone's Mac
- [AGENTS.md](AGENTS.md): orientation for AI agents and new contributors changing the code

## Where data lives

`~/.config/figg/config.yaml` holds settings. `~/Library/Application Support/figg/` holds `figg.sqlite` (meetings, notes,
transcripts), `meetings/<id>/pending/` (audio not yet transcribed) and
`models/` (speech model). The Atlassian email and API token are in the
Keychain under `dev.adamclark.figg`.

## License

[MIT](LICENSE).

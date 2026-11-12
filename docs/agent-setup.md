# Setting figg up with a coding agent

For an AI coding agent (Claude Code, Codex, Cursor and the like) that has
been asked to get figg working on someone's Mac. Follow the steps in order.
Each one ends with a **Check** you can run; do not move on until it passes.

This guide is about installing and configuring figg. To change figg's code,
read [AGENTS.md](../AGENTS.md) instead.

Two words used below: **you** are the agent, and **the human** is the person
whose Mac this is. Some steps only the human can do (macOS permission
prompts, signing in, pasting an API key). When you reach one, say exactly
what to click and wait for them.

## Rules (read first)

1. **Never handle an API key.** Do not ask the human to paste a key into the
   chat. Do not write one into `config.yaml`, a shell command, an environment
   variable, a log or a reply. The human types it into figg > Settings > AI,
   and figg stores it in the macOS Keychain. If a key does land in the chat,
   do not repeat it, and tell the human to revoke it and create a new one.
2. **Never print credentials.** Do not run `security find-generic-password`
   with `-w` or `-g`, and do not run `aws configure export-credentials`. Both
   print secrets into your context.
3. **Never quit, kill or relaunch figg while it may be recording.** A
   recording is someone's meeting. Before anything that stops or restarts
   the app, run `pgrep -x Figg`. If it prints a process ID, figg is running:
   ask the human whether a recording is in progress (the menu bar icon is
   red while recording) and let them quit it.
4. **Audio never leaves the Mac.** Do not upload, copy or attach anything
   from `~/Library/Application Support/figg/`. Do not read meeting notes or
   transcripts into the chat; the checks below only count rows.
5. **Permission prompts belong to the human.** Do not answer macOS privacy
   prompts for them, do not run `tccutil`, and do not remove the quarantine
   attribute from the app.
6. **Say the free-model warning out loud.** If the human picks OpenRouter's
   free models, or any other free model, tell them in plain words before
   the first meeting: free models may log or train on the text they are
   sent, which is their notes, the transcript and their questions. They
   should think twice before using them for confidential meetings. Audio
   is never sent with any provider.

## 1. Requirements

figg needs an Apple Silicon Mac on macOS 14.4 or later.

```bash
uname -m
```

```bash
sw_vers -productVersion
```

**Check:** the first prints `arm64`, the second prints 14.4 or higher. If
either fails, stop and tell the human; figg will not run on this Mac.

## 2. Get the app

Pick one. The download is quicker. Building from source needs Xcode, and is
the only way to get privacy permissions that survive updates today.

### Option A: the released dmg

The release build is ad-hoc signed and not notarized (there is no Apple
Developer ID yet). Tell the human that, and get their go-ahead before
installing.

If `/Applications/Figg.app` already exists, do not copy over it. From figg
0.5.1 on, the human updates it in Settings > Recording > **Check for
Updates…**; skip to step 3.

```bash
curl -L -o ~/Downloads/figg.dmg https://3gwgc5ir6t6yxpzh.public.blob.vercel-storage.com/figg.dmg
```

```bash
hdiutil attach ~/Downloads/figg.dmg
```

`hdiutil` prints the mount point, normally `/Volumes/figg`. Use what it
printed in the next two commands if it differs.

```bash
cp -R /Volumes/figg/Figg.app /Applications/
```

```bash
hdiutil detach /Volumes/figg
```

**Check:** the installed version matches the latest release.

```bash
defaults read /Applications/Figg.app/Contents/Info CFBundleShortVersionString
```

```bash
curl -s https://3gwgc5ir6t6yxpzh.public.blob.vercel-storage.com/latest.json
```

The first prints a version such as `0.5.1`; the second prints JSON whose
`version` should be the same. `figg.dmg` can lag a new release by about five
minutes. If the versions differ, download the `dmg_url` from that JSON
instead.

If the human downloaded the dmg in a browser, macOS blocks the first launch.
They approve it themselves: right-click the app and choose Open, or on
macOS 15 and later, System Settings > Privacy & Security > Open Anyway.

Because each ad-hoc signed build is a new app identity to macOS, expect the
permission prompts in step 4 to come back after an update.

The app path for the rest of this guide is `/Applications/Figg.app`.

### Option B: build from source

Needs Xcode 16 or later and a clone of the repository. Run everything from
the repository root.

```bash
xcodebuild -version
```

First, the human creates the local signing certificate, once per Mac, by
following [docs/local-signing.md](local-signing.md) (six clicks in Keychain
Access). Without it every rebuild loses its microphone and system audio
permissions.

```bash
security find-identity -p codesigning | grep "figg Local Signing"
```

Then build. The first build downloads packages and takes several minutes,
so run it in the background if your tool has a timeout. The first signed
build may ask the human for their login keychain password; they choose
**Always Allow**.

```bash
scripts/bundle.sh
```

Build with `scripts/bundle.sh`, not `swift build`: a `swift build` binary
crashes on resource lookup.

**Check:** the last line of output reads
`Built build/Figg.app (<version> build <n>, signed with 'figg Local Signing')`.
If it says `signed with '-'`, the certificate was not found; go back to
`docs/local-signing.md`.

The app path for the rest of this guide is `build/Figg.app`.

## 3. First launch

Replace `<app>` below with the app path from step 2.

```bash
open <app>
```

Running `open` on an app that is already running only brings it to the
front, so this is safe at any time.

On first launch figg creates `~/.config/figg/config.yaml` and the sidebar
offers **Download speech model** (about 0.5 GB, one time; skipped if the
model is already on disk). Ask the human to click it, or it starts by itself
on the first recording.

**Check:** the config file exists and starts with figg's own header.

```bash
head -1 ~/.config/figg/config.yaml
```

It prints `# figg settings. Edit here or in figg > Settings (the app rewrites this file).`

**Check:** the speech model is on disk (the sidebar notice is gone).

```bash
ls ~/Library/Application\ Support/FluidAudio/Models
```

It lists a `parakeet-tdt-0.6b-v3` folder.

## 4. Permissions

figg needs two macOS permissions, and only the human can grant them:

- **Microphone**: System Settings > Privacy & Security > Microphone
- **System Audio Recording**: System Settings > Privacy & Security >
  Screen & System Audio Recording > System Audio Recording Only

macOS asks for both the first time figg records (Microphone first, then
System Audio Recording). The audio probe triggers the same prompts and
proves both streams work, so use it now.

The probe only runs when figg starts fresh, so figg must not be running. Run
`pgrep -x Figg`; if it prints a process ID, follow rule 3 and have the human
quit figg.

```bash
open <app> --args --probe-audio
```

The probe records for 6 seconds. Play a sound during that time so there is
system audio to hear, and ask the human to say a few words:

```bash
afplay /System/Library/Sounds/Glass.aiff
```

If a permission prompt appears, the human clicks Allow. Then have them quit
figg and run the probe again, because the first run was spent on the prompt.

**Check:** wait about 10 seconds after launch, then read the report.

```bash
cat /tmp/figg-probe.txt
```

A pass looks like this:

```
mic started: true, system started: true
chunk mic samples=96000 rms=0.01234 peak=0.21000
chunk system samples=96000 rms=0.00456 peak=0.10000
```

What matters: `mic started: true, system started: true`, and a `peak`
above zero on both the `mic` and the `system` chunk (the numbers here are
made up; yours will differ). How to read a failure:

| Report shows | Meaning | Fix |
|---|---|---|
| only `probe starting` | the probe has not finished | wait and read again |
| file missing | figg was already running, so the flag was ignored | have the human quit figg, run again |
| a `problem:` line | figg says which permission is off | the human turns it on in System Settings, quits figg, run again |
| `system` peak is `0.00000` | no sound was playing, or System Audio Recording is off (macOS delivers silence, not an error) | play the sound again; if still zero, the human grants the permission |
| `mic` peak is `0.00000` | nobody spoke, or the wrong input device | ask the human to speak; check System Settings > Sound > Input |

After a permission is changed in System Settings, figg has to be restarted
to pick it up. Rule 3 applies.

## 5. Choose a model provider

figg sends text (never audio) to a language model to write the notes. Ask
the human which they want:

- **AWS Bedrock** (the default): Claude on their own AWS account, billed to
  that account. Needs the AWS CLI and a profile that can call Bedrock.
- **OpenRouter**: needs only an API key, and has free models. Rule 6
  applies.
- **Another OpenAI-compatible service** (OpenAI, Groq and so on): an extra
  entry in `config.yaml`.

Settings live in `~/.config/figg/config.yaml` and in figg > Settings (⌘,);
they are the same thing. Two facts about the file:

- figg rewrites the whole file whenever a setting changes, so comments you
  add are not kept.
- figg rereads it when the app comes to the front. After editing it, run
  `open <app>`, or ask the human to click **Reload** at the bottom of
  Settings.

### Path A: AWS Bedrock

figg looks for the AWS CLI in exactly three places.

```bash
ls /opt/homebrew/bin/aws /usr/local/bin/aws /usr/bin/aws 2>/dev/null
```

If that prints nothing, install it:

```bash
brew install awscli
```

figg uses an AWS profile from `~/.aws/config`. Ask the human which one,
and confirm it exists:

```bash
aws configure list-profiles
```

If the profile uses SSO, sign in. This opens a browser and the human
completes it:

```bash
aws sso login --profile <name>
```

**Check:** the session works. This prints `signed in` and nothing secret.

```bash
aws sts get-caller-identity --profile <name> > /dev/null && echo "signed in"
```

**Check:** the account offers the model figg uses by default,
`us.anthropic.claude-haiku-5-5`.

```bash
aws bedrock list-inference-profiles --profile <name> --region us-east-1 --query "inferenceProfileSummaries[?contains(inferenceProfileId,'claude')].inferenceProfileId"
```

The profile also needs permission for
`bedrock:InvokeModelWithResponseStream` on that model. If the default ID is
not in the list, pick one that is and put it in both `models` fields below.

Now point figg at the profile. Edit these keys in
`~/.config/figg/config.yaml`, leaving everything else as it is:

```yaml
llm:
  provider: "bedrock"

aws:
  profiles: ["<name>"]
  profile: "<name>"
  region: "us-east-1"
```

`aws.profiles` is the list shown in the Settings picker, so keep any names
already in it and add the new one. `aws.profile` is the one figg uses.

**Check:** bring figg to the front, then confirm it kept the values.

```bash
open <app>
```

```bash
grep -n -A5 '^aws:' ~/.config/figg/config.yaml
```

```bash
grep -n '^  provider:' ~/.config/figg/config.yaml
```

The first shows the profile under figg's own comments; the second prints
`provider: "bedrock"`. In the app, Settings > AI shows Provider **AWS
Bedrock** and the profile in the **AWS profile** picker.

From a source checkout there is also an end-to-end check, which makes two
tiny real Bedrock calls (Haiku and Sonnet) through figg's own client:

```bash
FIGG_LIVE=1 FIGG_PROFILE=<name> swift test --filter LiveBedrockTests
```

### Path B: OpenRouter

Give rule 6's warning first if the human plans to use free models.

The human does these three things; you do not see the key:

1. Create a key at https://openrouter.ai/keys
2. In figg, open Settings (⌘,) > **AI** and set **Provider** to
   **OpenRouter**.
3. Paste the key into **API key**.

Leave the models alone. The default, `openrouter/free`, lets OpenRouter pick
a free model. Any ID from https://openrouter.ai/models works in the
**Notes and chat** and **Titles (fast)** fields; free ones end in `:free`.

**Check:** OpenRouter is the active provider.

```bash
grep -n '^  provider:' ~/.config/figg/config.yaml
```

It prints `provider: "openrouter"`.

**Check:** the key is in the Keychain. This prints `key stored` and never
the key itself. Do not add `-w` or `-g`.

```bash
security find-generic-password -s dev.adamclark.figg -a llmKey.openrouter > /dev/null 2>&1 && echo "key stored"
```

**Check:** the key is not in the config file. OpenRouter keys start with
`sk-or-`, so this must print `0`.

```bash
grep -c 'sk-or-' ~/.config/figg/config.yaml
```

Do not use `LiveOpenRouterTests` for this. It takes the key as an
environment variable, which breaks rule 1.

### Path C: another OpenAI-compatible service

Add an entry under `llm.providers` in `~/.config/figg/config.yaml` and
select it with `llm.provider`. The list in the file is the whole list, so
keep the existing `bedrock` and `openrouter` entries above the new one.
This example adds Groq:

```yaml
llm:
  provider: "groq"
  providers:
    - id: "bedrock"
    - id: "openrouter"
    - id: "groq"
      name: "Groq"
      kind: "openai"
      base_url: "https://api.groq.com/openai/v1"
      models:
        notes: "<model id>"
        fast: "<model id>"
```

- `id` is a short name you choose. It selects the entry and names its
  Keychain item, so do not change it later.
- `kind` is `"openai"` for any OpenAI-compatible chat API. (`"bedrock"` is
  only for the built-in AWS entry.)
- `base_url` is the API root, the part before `/chat/completions`.
- `models.notes` writes notes and chat answers; `models.fast` writes
  meeting titles. Use model IDs exactly as the service names them.
- There is no key field. Rule 1 applies.

A built-in entry needs only its `id`, as above; figg fills in the rest.

Then run `open <app>` so figg rereads the file, and have the human open
Settings > AI, confirm **Provider** shows the new name, and paste the
service's key into **API key**.

**Check:** figg accepted the entry. After figg comes to the front it
rewrites the file in its own format, so the header is back and the built-in
entries are spelled out in full:

```bash
head -1 ~/.config/figg/config.yaml
```

```bash
grep -n -A8 'id: "groq"' ~/.config/figg/config.yaml
```

If the header is missing and your edit is untouched, the YAML did not
parse: figg shows a warning banner, runs on defaults and leaves the file
alone. Fix the indentation and run `open <app>` again.

**Check:** the key is stored (replace `groq` with your `id`).

```bash
security find-generic-password -s dev.adamclark.figg -a llmKey.groq > /dev/null 2>&1 && echo "key stored"
```

## 6. Smoke test

This proves the whole chain: record, transcribe on the Mac, write notes
with the chosen provider. It needs the human for about a minute.

1. Bring figg to the front (`open <app>`).
2. The human clicks **Record** in the toolbar (or presses ⌃⌥⌘R) and talks
   for about 30 seconds. Lines labelled **Me** appear in the transcript
   within about 15 seconds. Playing a video or joining a call adds **Them**
   lines.
3. The human clicks **Stop**. The status shows "Finishing transcript…",
   then "Writing notes…"; a title appears and the notes stream into the
   **Enhanced** tab.

**Check:** the newest meeting is `ready` and has enhanced notes. This reads
only a status and a yes/no, never the notes.

```bash
sqlite3 -readonly ~/Library/Application\ Support/figg/figg.sqlite "select status, coalesce(length(enhancedNotes) > 0, 0) from meeting order by createdAt desc limit 1;"
```

A pass prints `ready|1`. Wait and run it again if it prints `transcribing`
or `enhancing`.

**Check:** the transcript has lines. This must print a number above zero.

```bash
sqlite3 -readonly ~/Library/Application\ Support/figg/figg.sqlite "select count(*) from transcriptLine where meetingId = (select id from meeting order by createdAt desc limit 1);"
```

If the first check prints `needsEnhance|0`, the notes step failed. figg
shows the reason in a red banner with a Retry button, and you can read the
same message (an error, not meeting content) with:

```bash
sqlite3 -readonly ~/Library/Application\ Support/figg/figg.sqlite "select errorMessage from meeting order by createdAt desc limit 1;"
```

| Message | Fix |
|---|---|
| `<provider> needs a valid API key. Add one in Settings > AI.` | the human pastes the key again (step 5, path B or C) |
| `Your AWS session has expired. Sign in again (for an SSO profile: aws sso login --profile <name>).` | run it, or the human clicks **Sign in to AWS** on the banner, then Retry |
| `The provider rejected the model ID. Check Settings > AI.` | fix the model IDs in Settings > AI, or click **Reset to defaults** there |
| `Nothing to enhance yet: no notes and no transcript.` | nothing was heard; go back to step 4 and rerun the probe |
| `<provider> returned an empty reply. Try again, or pick another model in Settings > AI.` | free models do this sometimes; click Retry, or set a specific model ID |

When both checks pass, figg is set up. Tell the human:

- figg offers to record by itself when a meeting app starts using the mic.
- Headphones give the cleanest transcript; on laptop speakers the mic also
  hears the other side.
- Which provider is active, and, if it uses a free model, the warning from
  rule 6 once more.

## Where things live

| What | Where |
|---|---|
| Settings | `~/.config/figg/config.yaml` |
| Meetings, notes, transcripts | `~/Library/Application Support/figg/figg.sqlite` |
| Audio not yet transcribed | `~/Library/Application Support/figg/meetings/<id>/pending/` |
| Speech model (Parakeet) | `~/Library/Application Support/FluidAudio/Models/` |
| API keys and Atlassian login | macOS Keychain, service `dev.adamclark.figg` |
| Probe report | `/tmp/figg-probe.txt` |

More detail for a person: [README.md](../README.md). The full manual test
pass: [manual-test-checklist.md](manual-test-checklist.md).

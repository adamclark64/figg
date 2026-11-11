# Manual test checklist

Run before cutting a release. Unit tests cannot cover real audio hardware,
macOS permissions, or Bedrock.

## First run
- [ ] `open build/Figg.app` launches; sidebar offers "Download speech model"
- [ ] Download completes; the sidebar notice disappears
- [ ] `~/.config/figg/config.yaml` is created with comments
- [ ] Settings > AI: profile picker shows the profiles from config.yaml (default selected); models show Haiku 5.5
- [ ] Change a setting in the app: config.yaml updates
- [ ] Edit config.yaml by hand, switch back to figg: Settings shows the new value
- [ ] Break the YAML (e.g. `aws: [`): warning banner, defaults used, file not overwritten

## Permissions
- [ ] `scripts/bundle.sh` ends with `signed with 'figg Local Signing'` (else permissions reset each build)
- [ ] `open build/Figg.app --args --probe-audio` with a sound playing: /tmp/figg-probe.txt shows non-zero system peak
- [ ] First Record prompts for Microphone, then System Audio Recording
- [ ] Deny Microphone: recording still starts with system audio, orange banner shown
- [ ] Re-enable in System Settings, restart figg, both streams work

## Recording (repeat per app)
| | Zoom | Teams | Meet in Chrome |
|---|---|---|---|
| Headphones: "Them" lines appear within ~15 s | [ ] | [ ] | [ ] |
| Headphones: your speech appears as "Me" | [ ] | [ ] | [ ] |
| Laptop speakers: note how much "Them" is duplicated as "Me" | [ ] | [ ] | [ ] |

- [ ] ⌃⌥⌘R starts and stops recording from another app
- [ ] Menu bar icon turns red while recording; "Copy consent message" copies text
- [ ] Notes typed during the meeting are still there after Stop

## Speaker separation
- [ ] In-person, 3 people, "People in the room: 3": transcript shows Me / Guest 1 / Guest 2 after Stop
- [ ] Call with 2+ remote people: lines show Them 1 / Them 2
- [ ] Solo call: plain Me / Them

## Meeting detection
- [ ] Join a Zoom/Teams/Meet call: "X is using your microphone" card appears within ~5 s, top-right, without taking focus
- [ ] "Not now": no second prompt during the same call
- [ ] Record from the card; leave the call: "stopped using the microphone" card offers Stop
- [ ] Dictating with FluidVoice / Wispr Flow does not prompt

## Recording widget
- [ ] Start recording, switch to another app: the pill appears on the right edge within a second, without taking focus
- [ ] Switch back to figg: the pill disappears; stop recording from another app (⌃⌥⌘R): it disappears
- [ ] Full-screen Zoom/Keynote and a second Space: the pill is there too
- [ ] Talk: the top half of the waveform moves; play sound on the Mac: the bottom half moves; silence: both flat
- [ ] Click the fig: figg comes forward on the recording meeting's note
- [ ] Click the camera: the pill hides and the ⌘⇧4 crosshair appears. Drag a region: the pill returns with a tick, and ⌘V in another app pastes the picture. Esc: the pill returns, the clipboard is unchanged
- [ ] First camera click without Screen Recording access: macOS asks, no crosshair; after allowing it, the next click captures other apps' windows (not just the wallpaper)
- [ ] Hover: Stop and Hide appear; right-click offers the same. Stop writes the notes; Hide keeps recording and the pill returns for the next recording
- [ ] Drag the pill, quit and reopen figg, record again: it is where you left it (`recording.widget_position` in config.yaml)
- [ ] Settings > Recording: turn the widget off; no pill on the next switch away
- [ ] Share your screen in a call: note whether the other side sees the pill

## Enhance
- [ ] Stop: title appears, enhanced notes stream in
- [ ] Your lines are black, added lines grey
- [ ] Regenerate works; Edit + Save persists
- [ ] Click an action item's checkbox: it ticks and strikes through; switch meetings, quit and relaunch, it is still ticked; Copy as Markdown shows `[x]`
- [ ] With an SSO profile, expire the session (`aws sso logout --profile <name>`): Enhance shows "AWS session expired" with "Sign in to AWS", which opens the browser; Retry then works
- [ ] Wrong model ID in Settings gives a clear "rejected the model ID" message

## Other providers
- [ ] An existing config.yaml with a top-level `models:` block: after launch the file has `llm:` and the Bedrock entry keeps those model IDs
- [ ] Settings > AI: Provider picker lists AWS Bedrock and OpenRouter; picking OpenRouter swaps the AWS fields for Base URL and API key and shows the data warning
- [ ] OpenRouter with no key: Enhance shows "OpenRouter needs a valid API key" with Retry
- [ ] Paste a key (openrouter.ai/keys): Enhance streams notes from `openrouter/free`; the key is not in config.yaml
- [ ] Quit and relaunch: the key is still there; switching back to AWS Bedrock restores its own models
- [ ] Add a provider entry by hand in config.yaml: it appears in the picker when figg comes to the front

## Crash recovery
- [ ] Record 1 minute, `pkill -9 -f MacOS/Figg`, relaunch: banner "Recovered 1 unfinished meeting", transcript present, Enhance works

## Ask figg
- [ ] A question about a past meeting cites it; "Searched:" links open the meeting
- [ ] A question with no matching meeting says so instead of inventing an answer

## Share
- [ ] Copy for Slack pastes cleanly into Slack
- [ ] Publish to Confluence opens the new page (set space key first)
- [ ] Jira sheet lists action items; created keys shown; tickets look right

## Data
- [ ] `~/Library/Application Support/figg` is mode 700
- [ ] With "Keep audio" off, `meetings/<id>/pending` is empty after transcription

## Updates
- [ ] After a release, `curl https://3gwgc5ir6t6yxpzh.public.blob.vercel-storage.com/latest.json` names the new version and a dmg URL that downloads
- [ ] In-app update (needs figg 0.5.1 or later): run an older figg,
  Settings > Recording > Check for Updates, Update now, confirm figg
  relaunches as the new version and, with the local signing certificate,
  mic + system-audio permissions survive without re-approval.
- [ ] While the update downloads, a banner shows the 3D fig newton being extruded from its back with a percentage, then hopping beside "Installing the update"; Settings shows the same

## Loading states
- [ ] By default every loader below is the low-poly fig turning on the spot, the same colours each time, and a default config.yaml has no `loader` line
- [ ] Add `loader: newton` under `appearance:` in config.yaml and switch back to figg: every loader is the fig newton, and the items below describe it; change a setting in the app and the `loader` line is still in the file
- [ ] Stop a recording: the status chip shows a small hopping 3D fig newton with "Finishing transcript…", then "Writing notes…", and the Enhanced tab shows a large 3D fig newton over the same words, never "Enhance now"
- [ ] On a first run, the sidebar shows a small 3D fig newton beside "Loading speech model…"; sending a bug report shows one beside "Sending your report…"
- [ ] Before the first notes text arrives, the Enhanced tab shows a large 3D fig newton hopping over "Writing notes…", not "Enhance now"; every other hop shows the jam; while notes stream, a small one hops where Edit goes
- [ ] Ask figg, a quick action and the pre-meeting brief each show the 3D loader until text arrives
- [ ] Check the loaders in the fig and system themes, light and dark: the cookie is the same golden colour each time, has no box or background behind it, a loading chip is the same height as the chips beside it and its cookie stays inside the capsule at the top of the hop, and nothing moves when a loader appears, hops or goes
- [ ] A loader never blocks a click on what is under or beside it
- [ ] With Reduce Motion on (System Settings > Accessibility > Display), the newton stays still, and the update download still grows

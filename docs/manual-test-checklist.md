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
- [ ] After a release, `latest.json` has a `signature` of 88 characters, and the `publish` job's log names a public key that is in `UpdateVerifier.releaseKeys`
- [ ] Signed update: from a figg that checks signatures (any release after 0.7.0), Update now installs the next release. From 0.7.0, Update now still installs it (0.7.0 ignores the signature)
- [ ] In-app update (needs figg 0.5.1 or later): run an older figg,
  Settings > Recording > Check for Updates, Update now, confirm figg
  relaunches as the new version and, with the local signing certificate,
  mic + system-audio permissions survive without re-approval.
- [ ] While the update downloads, a banner shows the 3D fig newton being extruded from its back with a percentage, then hopping beside "Installing the update"; Settings shows the same

## Report a Bug
- [ ] Help > Report a Bug… opens the window with a "Send Report" button, an optional email field and no setup
- [ ] Send Report with one screenshot: the window says "Report sent" with the issue number, and the issue on GitHub has the text, context and a link to the screenshot
- [ ] With Wi-Fi off, Send Report says it couldn't reach the server and offers "Continue on GitHub instead"
- [ ] With `feedback: bug_report_endpoint: browser` in config.yaml, the window shows "Continue on GitHub" and no email field; the checks below run in this mode
- [ ] Copy a screenshot (Shift-Control-Command-4), click in the description and press Command-V: the screenshot is added as a thumbnail and nothing is typed. With text on the clipboard, Command-V types the text
- [ ] Copy an image file in Finder and press Command-V: it is added. Copy a PDF: nothing is added
- [ ] With three screenshots attached, a fourth paste shows "Attach at most 3 screenshots." With two attached, pasting three copied image files adds one and shows the same line
- [ ] Switch to a Russian keyboard layout and press Command-V with a screenshot copied: it is added
- [ ] Continue on GitHub with no screenshots: the browser opens a new issue with the title, text and context filled in, and the window closes
- [ ] Continue on GitHub with one screenshot: the window shows "Finish on GitHub"; Command-V in the issue text attaches the screenshot. With two or three, the same paste attaches them all, and Show in Finder reveals the files
- [ ] After Done, Report a Bug… opens an empty form again, not "Finish on GitHub"
- [ ] Continue on GitHub with a description of about 5,000 characters: the issue holds the start of it and a note, and the window stays on "Finish on GitHub". Select all in the issue text and paste: the whole report replaces it, context included. With screenshots too, Copy Screenshots and a second paste under "Screenshots" attach them
- [ ] In Safari, right-click a picture and choose Copy Image, then press Command-V in the report: it is added as a screenshot, not typed as text
- [ ] Copy an image file from a folder figg has no access to and press Command-V: the window says the image could not be read, and no file name is typed
- [ ] A description with "C++" in its first line arrives on GitHub with both plus signs, in the title and the text
- [ ] Signed in to GitHub with an account that is not a collaborator on the repo, the link opens the form (not a "not found" page), and the submitted issue carries the `user-report`, `macos` and type labels
- [ ] Quit and reopen figg after a report with screenshots: the `figg-report-…` folder is gone from the temporary folder (`echo $TMPDIR`)

## Loading states
- [ ] By default every loader below is the fig newton, and a default config.yaml has no `loader` line
- [ ] Add `loader: fig` under `appearance:` in config.yaml and switch back to figg: every loader is the low-poly fig turning on the spot, the same colours each time; change a setting in the app and the `loader` line is still in the file. Take the line out again for the items below
- [ ] With `loader: newton` in config.yaml (left from 0.6.0), the loaders are the fig newton, and the line goes the next time figg writes the file
- [ ] Stop a recording: the status chip shows a small hopping 3D fig newton with "Finishing transcript…", then "Writing notes…", and the Enhanced tab shows a large 3D fig newton over the same words, never "Enhance now"
- [ ] On a first run, the sidebar shows a small 3D fig newton beside "Loading speech model…"; sending a bug report through a relay shows one beside "Sending your report…"
- [ ] Before the first notes text arrives, the Enhanced tab shows a large 3D fig newton hopping over "Writing notes…", not "Enhance now"; every other hop shows the jam; while notes stream, a small one hops where Edit goes
- [ ] Ask figg, a quick action and the pre-meeting brief each show the 3D loader until text arrives
- [ ] Check the loaders in the fig and system themes, light and dark: the cookie is the same golden colour each time, has no box or background behind it, a loading chip is the same height as the chips beside it and its cookie stays inside the capsule at the top of the hop, and nothing moves when a loader appears, hops or goes
- [ ] A loader never blocks a click on what is under or beside it
- [ ] With Reduce Motion on (System Settings > Accessibility > Display), the newton stays still, and the update download still grows

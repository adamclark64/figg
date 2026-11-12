# Security

## Reporting a problem

Please do not open a public issue for a security problem. Use
[Report a vulnerability](https://github.com/adamclark64/figg/security/advisories/new)
on the repository's Security tab, which reaches the maintainer privately.
Say what you found, how to reproduce it and which version you used. You
should hear back within a week.

figg is a personal project with no bounty.

## What figg promises

- Audio never leaves the Mac. Recording and transcription run locally; only
  text goes to the model provider you choose.
- No secrets on disk or in logs. AWS credentials come from the AWS CLI at
  run time and stay in memory; API keys and tokens live in the macOS
  Keychain.
- A bug report carries only what you type, the screenshots you add, the
  app version and build, the macOS version, the Mac's model, and the name
  of the transcription engine. It is a public GitHub issue, and you read it
  in your browser before you submit it. (If you point figg at a relay you
  host, the report goes to the relay with no preview, along with an email
  address if you give one.)

A way to break any of these is a security problem worth reporting.

## Known limits

- Releases are not signed with a Developer ID and are not notarized.
  `scripts/bundle.sh` signs a build with a certificate you create on your
  own Mac (`docs/local-signing.md`).
- The in-app updater downloads over HTTPS from one fixed host and refuses a
  DMG from any other, but it checks no signature on the download. Its
  safety rests on that host and on the token the release workflow uses to
  write to it. If you would rather not rely on that, build from source and
  do not install updates from inside the app.
- `relay/` is an optional function for people who host their own bug-report
  endpoint. It accepts reports from anyone who knows its address and files
  them with your token, so give that token access to one repository only,
  ideally one made for the purpose, and expect spam.

## For contributors

Changes to `.github/`, `scripts/`, `site/`, `relay/`, `README.md` and
`docs/agent-setup.md` deserve a slower read than the rest: workflows hold
the release token, and the setup guide is written to be followed by coding
agents on other people's machines. The reasons behind the issue digest's
design are in `.github/issue-digest/README.md`.

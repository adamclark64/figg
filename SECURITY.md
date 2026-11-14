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
- An update installed from inside the app was signed by figg's release
  job. The app refuses a download with a missing or wrong signature and
  keeps running the version it has.
- A bug report carries only what you type, the screenshots you add, the
  app version and build, the macOS version, the Mac's model, and the name
  of the transcription engine. It is a public GitHub issue, and you read it
  in your browser before you submit it. (If you point figg at a relay you
  host, the report goes to the relay with no preview, along with an email
  address if you give one.)

A way to break any of these is a security problem worth reporting.

## Known limits

- Releases are not signed with a Developer ID and are not notarized.
  `app/scripts/bundle.sh` signs a build with a certificate you create on your
  own Mac (`docs/local-signing.md`).
- The in-app updater only installs a DMG that is signed with figg's
  release key, so the download store and its write token cannot change
  what installed copies run. The key is held by the release workflow in
  GitHub Actions, so the check is only as strong as control of this
  repository and its workflows. It does not cover the first download from
  the website, and copies of 0.7.0 or earlier do not check anything until
  they have updated once. Details in `docs/release-signing.md`. If you
  would rather not rely on that, build from source and do not install
  updates from inside the app.
- `api/` is an optional function for people who host their own bug-report
  endpoint. It accepts reports from anyone who knows its address and files
  them with your token, so give that token access to one repository only,
  ideally one made for the purpose, and expect spam.

## For contributors

Changes to `.github/`, `app/scripts/`, `site/`, `api/`, `README.md` and
`docs/agent-setup.md` deserve a slower read than the rest: workflows hold
the release token and the key that signs updates, and the setup guide is written to be followed by coding
agents on other people's machines. The reasons behind the issue digest's
design are in `.github/issue-digest/README.md`.

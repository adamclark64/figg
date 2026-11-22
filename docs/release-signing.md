# Release signing

figg updates itself by downloading a DMG from a public download store. The
app only installs that DMG if it is signed with figg's release key. This
page says what is signed, where the two halves of the key live, and what to
do when the key has to change.

## What is checked

- The release workflow's `publish` job signs the DMG's bytes with an Ed25519
  private key and writes the signature (base64) into `latest.json` as
  `signature`, next to `version`, `dmg_url` and `size`.
- The app carries the public half in `UpdateVerifier.releaseKeys`
  (`app/Sources/FiggUpdate/UpdateVerifier.swift`). After downloading, and before
  the DMG is mounted, `UpdateInstaller` checks the signature over the file
  it downloaded. No signature, an unreadable one, or one from another key
  all end the same way: nothing is installed, the running copy is left as
  it is, and the update banner says why.
- The signature covers the DMG, not the version number in `latest.json`.
  So after mounting, the app also checks that the `Figg.app` inside is
  exactly the version that was offered. This stops an old, genuinely signed
  release from being offered again under a newer number.
- The earlier check stays: the DMG must come over HTTPS from the same host
  as `latest.json`.

## Release notes in latest.json

`latest.json` also carries `notes`, the release notes the update prompt
shows:

```json
{
  "version": "0.19.2",
  "dmg_url": "https://.../releases/figg-0.19.2.dmg",
  "size": 12345678,
  "signature": "...",
  "notes": [
    { "version": "0.19.2", "text": "### Bug Fixes\n\n* ..." },
    { "version": "0.19.1", "text": "### Reverts\n\n* ..." }
  ]
}
```

- Each entry is one version's section of `CHANGELOG.md` as release-please
  wrote it (Markdown, without the `## ` heading). The first entry is the
  published version, then up to 14 older versions, newest first, so a copy
  several releases behind can show everything since the version it runs.
  `app/scripts/changelog-notes.mjs` cuts them out; CI's `gates` job tests
  it, including against the repository's own changelog.
- The notes are not signed. The signature still covers only the DMG, and
  the app treats `notes` as display text: it never decides whether an
  update is offered, verified or installed. Missing, malformed or oversized
  notes give an update prompt without notes (or with them cut), and the
  update installs as before. Copies that do not know the field ignore it.
- The `publish` job fails with `not published: no CHANGELOG.md section for
  X.Y.Z` when the version has no section (or an empty one), before
  anything is signed or uploaded, so the `latest.json` already in the
  store stays as it was. It also fails when a version it would include
  appears twice in the changelog. Fix `CHANGELOG.md` and run "publish dmg
  to blob" for the tag.
- The job's log prints the version file without the note text, plus how
  many versions' notes it carries.

## What this protects, and what it does not

The download store's write token (`BLOB_READ_WRITE_TOKEN`) is no longer
enough to change what installed copies run. Someone holding it can replace
the files, and the worst that happens is that installed copies refuse the
update.

It does not protect against someone who controls the GitHub repository or
its workflows: the release job holds the key, so whoever can run that job
on `main` can sign. It also says nothing about the first download from the
website, which no installed copy is there to check. Releases still have no
Developer ID signature and are not notarized.

## App signing certificate (permissions)

This is a second, separate signature: the macOS code signature on
`Figg.app`. macOS keeps Microphone, System Audio Recording, Accessibility
and Screen Recording per signing identity. An ad-hoc signed app's identity
is the hash of that exact build, so before this every release looked like a
new app and lost all of them.

Releases are now signed with a self-signed certificate, **figg Release
Signing**. Its designated requirement is the bundle ID plus that
certificate, the same for every release, so permissions survive updates.
The first release signed this way still asks once more, since it differs
from the ad-hoc one before it.

- The repository secrets `FIGG_CERT_P12` (base64 of the .p12),
  `FIGG_CERT_PASSWORD` and `FIGG_SIGN_IDENTITY` (`figg Release Signing`)
  hold it. The `dmg` job imports it into a throwaway keychain;
  `scripts/dmg.sh` signs the app and the DMG with it.
- The owner keeps the only other copy, outside the repository. Never commit
  it.
- `UpdateInstaller` installs a certificate-signed release as it is. It only
  re-signs an ad-hoc one, with the local "figg Local Signing" cert when the
  Mac has it (`docs/local-signing.md`).
- Check a release: `codesign -d -r- /Applications/Figg.app` should print
  `certificate leaf = H"436e46708e8f0ed166cdde506614f3e9d9c0fe73"`.

It proves nothing to Gatekeeper (the certificate is self-signed), so the
first launch is still right-click > Open. If the certificate is lost,
make a new one the same way and replace the three secrets; every copy then
asks for its permissions one more time. Making it:

```bash
cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = figg Release Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:3072 -nodes -keyout key.pem -out cert.pem -days 7300 -config cert.cnf
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "figg Release Signing" -out cert.p12 \
  -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
```

The `-legacy` options use the older .p12 encryption, which macOS's
`security import` is known to read; OpenSSL 3's default often fails there.

## Where the key lives

| Half | Where | Who can read it |
|---|---|---|
| Private | `FIGG_UPDATE_SIGNING_KEY`, a secret of the `release` environment in GitHub Actions | Only jobs that name that environment, which only runs for `main`. GitHub never shows it again, and there is no other copy. |
| Public | `UpdateVerifier.releaseKeys` in the source | Everyone. It is not a secret. |

The key is used in the `publish` job only. The job that builds the DMG runs
code from the package dependencies, so it never sees the key.

The limit to `main` keeps a workflow pushed to any other branch from
reading the key. It is only as strong as the rules on who can push to
`main`.

## Setting it up (once per repository)

You need the GitHub CLI signed in with admin rights on the repository, and
Node 20 or later.

1. Create the `release` environment and limit it to `main`:

   ```bash
   gh api -X PUT repos/OWNER/REPO/environments/release --input - <<'JSON'
   {"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
   JSON
   gh api -X POST repos/OWNER/REPO/environments/release/deployment-branch-policies -f name=main -f type=branch
   ```

2. Make the key pair:

   ```bash
   node app/scripts/make-update-key.mjs OWNER/REPO
   ```

   The private half goes straight into the environment secret. It is not
   written to disk and not printed. The script prints the public half.

3. Add the printed public key to `UpdateVerifier.releaseKeys` and merge
   that before the next release.

`app/scripts/publish-dmg-blob.mjs` refuses to publish when the secret is
missing, or when its public half is not in `releaseKeys`. Either mistake
fails the release job loudly instead of publishing an update that every
installed copy would refuse.

## Copies installed before signing existed

figg 0.7.0 and earlier know nothing about signatures. They ignore the new
`signature` field (unknown fields in `latest.json` have always been
ignored), so they still see new releases and install them as before,
without a check. The first signed release reaches them that way. From that
release on, every update is checked. A copy that is never updated keeps
trusting the download store.

## Replacing the key

GitHub will not hand a secret back, and a release signed with a key that
installed copies do not know is refused by all of them. So the old key has
to sign the release that introduces the new one:

1. Make the new key under a second name. The old secret is not touched:

   ```bash
   node app/scripts/make-update-key.mjs OWNER/REPO FIGG_UPDATE_SIGNING_KEY_2
   ```

2. Add the printed public key to `releaseKeys`, after the old one, and
   release. That release is still signed with the old key, and every copy
   that installs it trusts both.
3. Later, change `secrets.FIGG_UPDATE_SIGNING_KEY` to the new name in
   `.github/workflows/release-please.yml` and
   `.github/workflows/publish-dmg-blob.yml`. Releases are now signed with
   the new key.
4. Once you no longer care about copies older than step 2, remove the old
   public key from `releaseKeys` and delete the old secret.

A copy that never installed a release made between steps 2 and 3 only
knows the old key, and will refuse everything after step 3. Its owner has
to download figg from the website again. Leave a few releases between the
two steps unless the old key has leaked.

The script will not overwrite a secret that already exists, because
overwriting the key in use would cut off every installed copy at once.

## If the key is lost or leaked

Lost (the secret was deleted, or the repository moved without it): no
installed copy can be updated from inside the app again. Make a new key,
put its public half in `releaseKeys` on its own, release, and tell people
to download the new version from the website. Their settings and meetings
are not affected.

Leaked: whoever has it can sign, but still needs to write to the download
store to reach anyone. Rotate the store's token first, then replace the
key as above, moving from step 2 to step 3 as soon as the hand-over
release is out.

## Checking a release by hand

```bash
curl -s https://3gwgc5ir6t6yxpzh.public.blob.vercel-storage.com/latest.json
```

The `signature` value should be 88 characters of base64. The `publish`
job's log has a line naming the public key it signed with, which should be
one of the keys in `releaseKeys`.

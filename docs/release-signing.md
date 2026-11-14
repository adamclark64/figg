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

// Makes the key pair that release dmgs are signed with, once (and again only
// to replace the key; see docs/release-signing.md).
//
//   node scripts/make-update-key.mjs [owner/repo] [secret-name]
//
// The private half goes straight from this process into a secret of the
// repository's "release" environment (FIGG_UPDATE_SIGNING_KEY unless another
// name is given), through the GitHub CLI's standard input. It is never written to disk and
// never printed, so there is no other copy: GitHub will use it but will not
// show it again. The public half is printed, to be added to
// UpdateVerifier.releaseKeys.
//
// It will not overwrite a secret that already exists. Installed copies only
// trust the keys they were built with, so replacing the key in use would
// make every one of them refuse every later release.
//
// Needs `gh` signed in with admin rights on the repository, and the
// "release" environment to exist already.
import { spawnSync } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { publicKeyOf } from "./update-signature.mjs";

const [repo, name = "FIGG_UPDATE_SIGNING_KEY"] = process.argv.slice(2);
if (!/^[A-Z][A-Z0-9_]*$/.test(name)) {
  console.error("usage: make-update-key.mjs [owner/repo] [SECRET_NAME]");
  process.exit(2);
}
const target = ["--env", "release", ...(repo ? ["--repo", repo] : [])];

const existing = spawnSync("gh", ["secret", "list", ...target, "--json", "name", "--jq", ".[].name"], {
  encoding: "utf8",
  stdio: ["ignore", "pipe", "inherit"],
});
if (existing.error || existing.status !== 0) {
  console.error('Could not list the secrets of the "release" environment. Does it exist? Nothing has changed.');
  process.exit(1);
}
if (existing.stdout.split("\n").includes(name)) {
  console.error(`${name} already exists and is left alone: overwriting the key in use would cut off every installed copy.`);
  console.error("To replace a key, give a new name; see docs/release-signing.md.");
  process.exit(1);
}

const { privateKey } = generateKeyPairSync("ed25519");
const stored = spawnSync("gh", ["secret", "set", name, ...target], {
  input: privateKey.export({ format: "pem", type: "pkcs8" }),
  stdio: ["pipe", "inherit", "inherit"],
});
if (stored.error || stored.status !== 0) {
  console.error("The secret was not stored, so this key is thrown away. Nothing has changed.");
  process.exit(1);
}

console.log(`
Stored the private key as ${name} in the "release" environment.
Add the public key to releaseKeys in Sources/FiggUpdate/UpdateVerifier.swift:

    "${publicKeyOf(privateKey)}",
`);

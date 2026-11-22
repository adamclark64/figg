// Publishes a release dmg to the public figg-downloads Vercel Blob store
// (where the website's download button points), plus the version file the
// in-app updater reads.
//
//   BLOB_READ_WRITE_TOKEN=... FIGG_UPDATE_SIGNING_KEY=... \
//     node scripts/publish-dmg-blob.mjs build/figg-0.2.0.dmg 0.2.0
//
// The version file carries an Ed25519 signature over the dmg, made here with
// the release key. Installed copies refuse a download without a valid one
// (UpdateVerifier), so the store's token alone no longer decides what they
// run. See docs/release-signing.md.
//
// It also carries release notes: this version's section of CHANGELOG.md and
// those of a few older versions (changelog-notes.mjs). A version with no
// section fails here, before anything is signed or uploaded.
//
// This uses the @vercel/blob SDK rather than `vercel blob put`: the Vercel
// CLI refuses to run any command without a Vercel login, even when the blob
// token is set, and the release job has only the store's read-write token.
// The workflows install the SDK right before calling this, at the versions
// pinned in scripts/package-lock.json (`npm ci --prefix scripts`); nothing
// here is part of the app.
import { readFile } from "node:fs/promises";
import { put } from "@vercel/blob";
import { feedFor, notesFor } from "./changelog-notes.mjs";
import { loadSigningKey, publicKeyOf, signBytes, trustedKeys } from "./update-signature.mjs";

const [file, version] = process.argv.slice(2);
if (!file || !/^\d+\.\d+\.\d+$/.test(version ?? "")) {
  console.error("usage: publish-dmg-blob.mjs <path-to-dmg> <X.Y.Z>");
  process.exit(2);
}
if (!process.env.BLOB_READ_WRITE_TOKEN) {
  console.error("BLOB_READ_WRITE_TOKEN is not set");
  process.exit(2);
}

if (!process.env.FIGG_UPDATE_SIGNING_KEY) {
  console.error("FIGG_UPDATE_SIGNING_KEY is not set: without a signature no installed copy would take this release");
  process.exit(2);
}

// Check the notes before reading the dmg, so a missing changelog section
// publishes nothing and the latest.json already in the store stays as it is.
let changelog;
try {
  changelog = await readFile(new URL("../../CHANGELOG.md", import.meta.url), "utf8");
  notesFor(changelog, version);
} catch (error) {
  console.error(`not published: ${error.message}`);
  process.exit(1);
}

const body = await readFile(file);

// Sign before anything is uploaded, so a key problem publishes nothing.
let signature;
try {
  const key = loadSigningKey(process.env.FIGG_UPDATE_SIGNING_KEY);
  const publicKey = publicKeyOf(key);
  // A signature the app does not trust is worse than none: every installed
  // copy would be offered this release and refuse it.
  if (!(await trustedKeys()).includes(publicKey)) {
    throw new Error(`the signing key's public half (${publicKey}) is not in UpdateVerifier.releaseKeys`);
  }
  signature = signBytes(body, key);
  console.log(`signed ${file} with release key ${publicKey}`);
} catch (error) {
  console.error(`not published: ${error.message}`);
  process.exit(1);
}

const common = {
  access: "public",
  addRandomSuffix: false,
  // A re-run for the same version must not fail halfway and leave figg.dmg stale.
  allowOverwrite: true,
  contentType: "application/x-apple-diskimage",
  multipart: true,
};

// A versioned copy first, then the stable name the site links to, with a
// short cache so the button picks up a new release within minutes.
const versioned = await put(`releases/figg-${version}.dmg`, body, common);
console.log(`published ${versioned.pathname} (${body.length} bytes)`);
const latest = await put("figg.dmg", body, { ...common, cacheControlMaxAge: 300 });
console.log(`published ${latest.pathname} -> ${latest.url}`);

// Last, so the version file never names a dmg that is not there yet. The app
// (UpdateChecker) reads this to learn of a release, and downloads the
// versioned copy rather than figg.dmg, which can be a few minutes stale.
// Copies installed before signatures existed (0.7.0 and earlier) ignore the
// fields they do not know (signature, notes). The notes are display text
// only: they are not signed and never change what is installed.
const { feed, logLine } = feedFor({ version, dmgURL: versioned.url, size: body.length, signature, changelog });
const published = await put("latest.json", feed, {
  access: "public",
  addRandomSuffix: false,
  allowOverwrite: true,
  contentType: "application/json",
  cacheControlMaxAge: 300,
});
console.log(`published ${published.pathname} -> ${published.url}: ${logLine}`);

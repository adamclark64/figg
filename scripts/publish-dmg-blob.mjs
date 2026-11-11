// Publishes a release dmg to the public figg-downloads Vercel Blob store
// (where the website's download button points), plus the version file the
// in-app updater reads.
//
//   BLOB_READ_WRITE_TOKEN=... node scripts/publish-dmg-blob.mjs build/figg-0.2.0.dmg 0.2.0
//
// This uses the @vercel/blob SDK rather than `vercel blob put`: the Vercel
// CLI refuses to run any command without a Vercel login, even when the blob
// token is set, and the release job has only the store's read-write token.
// The workflows install the SDK right before calling this; nothing here is
// part of the app.
import { readFile } from "node:fs/promises";
import { put } from "@vercel/blob";

const [file, version] = process.argv.slice(2);
if (!file || !/^\d+\.\d+\.\d+$/.test(version ?? "")) {
  console.error("usage: publish-dmg-blob.mjs <path-to-dmg> <X.Y.Z>");
  process.exit(2);
}
if (!process.env.BLOB_READ_WRITE_TOKEN) {
  console.error("BLOB_READ_WRITE_TOKEN is not set");
  process.exit(2);
}

const body = await readFile(file);
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
const feed = JSON.stringify({ version, dmg_url: versioned.url, size: body.length }) + "\n";
const published = await put("latest.json", feed, {
  access: "public",
  addRandomSuffix: false,
  allowOverwrite: true,
  contentType: "application/json",
  cacheControlMaxAge: 300,
});
console.log(`published ${published.pathname} -> ${published.url}: ${feed.trim()}`);

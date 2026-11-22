// Tests for changelog-notes.mjs. Run with `node --test app/scripts/changelog-notes.test.mjs`
// (CI's gates job does). The fixture changelogs are invented; the last test
// runs against the repository's own CHANGELOG.md.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { feedFor, notesFor, sections } from "./changelog-notes.mjs";

const changelog = `# Changelog

## Unreleased

* **ui:** something not released yet

## [1.2.0](https://example.com/compare/v1.1.0...v1.2.0) (2026-01-03)


### Features

* **ui:** add a pale blue theme ([#12](https://example.com/issues/12))

## [1.1.0](https://example.com/compare/v1.0.1...v1.1.0) (2026-01-02)


### Bug Fixes

* **export:** keep line breaks in exported notes

## 1.0.1


### Bug Fixes

* **audio:** steady the level meter

## 1.0.0


### Features

* first release
`;

test("sections reads release-please and bare headings and ignores other ## sections", () => {
  const found = sections(changelog);
  assert.deepEqual(found.map((s) => s.version), ["1.2.0", "1.1.0", "1.0.1", "1.0.0"]);
  assert.equal(
    found[0].text,
    "### Features\n\n* **ui:** add a pale blue theme ([#12](https://example.com/issues/12))",
  );
  assert.equal(found[3].text, "### Features\n\n* first release");
});

test("a non-version ## section ends the section before it", () => {
  const text = "## 2.0.0\n\n* **ui:** a real change\n\n## Notes for maintainers\n\nnot release text\n";
  assert.deepEqual(sections(text), [{ version: "2.0.0", text: "* **ui:** a real change" }]);
});

test("### headings stay inside their section", () => {
  const text = "## 1.0.0\n### Features\n* a\n### Bug Fixes\n* b\n";
  assert.equal(sections(text)[0].text, "### Features\n* a\n### Bug Fixes\n* b");
});

test("notesFor puts the published version first, then older ones newest first", () => {
  const notes = notesFor(changelog, "1.2.0");
  assert.deepEqual(notes.map((n) => n.version), ["1.2.0", "1.1.0", "1.0.1", "1.0.0"]);
  assert.match(notes[0].text, /pale blue theme/);
});

test("notesFor orders by version, not by file order", () => {
  const text = "## 1.0.0\n\n* one\n\n## 1.10.0\n\n* ten\n\n## 1.2.0\n\n* two\n";
  assert.deepEqual(notesFor(text, "1.10.0").map((n) => n.version), ["1.10.0", "1.2.0", "1.0.0"]);
});

test("notesFor leaves out versions newer than the one published", () => {
  assert.deepEqual(notesFor(changelog, "1.1.0").map((n) => n.version), ["1.1.0", "1.0.1", "1.0.0"]);
});

test("notesFor keeps at most max versions", () => {
  assert.deepEqual(notesFor(changelog, "1.2.0", { max: 2 }).map((n) => n.version), ["1.2.0", "1.1.0"]);
});

test("notesFor drops empty older sections", () => {
  const text = "## 1.1.0\n\n* new\n\n## 1.0.1\n\n\n## 1.0.0\n\n* old\n";
  assert.deepEqual(notesFor(text, "1.1.0").map((n) => n.version), ["1.1.0", "1.0.0"]);
});

test("notesFor throws when the version has no section", () => {
  assert.throws(() => notesFor(changelog, "1.3.0"), { message: "no CHANGELOG.md section for 1.3.0" });
});

test("notesFor throws when the version's section is empty", () => {
  const text = "## 1.1.0\n\n\n## 1.0.0\n\n* old\n";
  assert.throws(() => notesFor(text, "1.1.0"), { message: "no CHANGELOG.md section for 1.1.0" });
});

test("a repeated version inside the window throws", () => {
  const text = "## 1.1.0\n\n* new\n\n## 1.0.0\n\n* old\n\n## 1.0.0\n\n* old again\n";
  assert.throws(() => notesFor(text, "1.1.0"), { message: /more than one section for 1\.0\.0/ });
});

test("a repeated version outside the window keeps its first occurrence", () => {
  const text = "## 1.2.0\n\n* newest\n\n## 1.1.0\n\n* new\n\n## 1.0.0\n\n* old\n\n## 1.0.0\n\n* old again\n";
  assert.deepEqual(notesFor(text, "1.2.0", { max: 2 }).map((n) => n.version), ["1.2.0", "1.1.0"]);
});

const release = {
  version: "1.2.0",
  dmgURL: "https://downloads.example.com/releases/figg-1.2.0.dmg",
  size: 12345,
  signature: "c2lnbmF0dXJl",
  changelog,
};

test("feedFor keeps the old four fields first, in order, then notes", () => {
  const { feed } = feedFor(release);
  assert.ok(feed.endsWith("\n"));
  const parsed = JSON.parse(feed);
  assert.deepEqual(Object.keys(parsed), ["version", "dmg_url", "size", "signature", "notes"]);
  assert.equal(parsed.version, "1.2.0");
  assert.equal(parsed.dmg_url, release.dmgURL);
  assert.equal(parsed.size, 12345);
  assert.equal(parsed.signature, "c2lnbmF0dXJl");
  assert.equal(parsed.notes[0].version, "1.2.0");
  assert.deepEqual(Object.keys(parsed.notes[0]), ["version", "text"]);
  assert.deepEqual(parsed.notes, notesFor(changelog, "1.2.0"));
});

test("feedFor's log line has the fields but no note text", () => {
  const { logLine } = feedFor(release);
  assert.ok(logLine.includes(release.dmgURL));
  assert.ok(logLine.includes("c2lnbmF0dXJl"));
  assert.ok(logLine.endsWith("notes for 4 versions (newest 1.2.0)"));
  assert.ok(!logLine.includes("pale blue theme"));
  assert.ok(!logLine.includes("first release"));
});

test("feedFor throws without a section for the version", () => {
  assert.throws(() => feedFor({ ...release, version: "1.3.0" }), { message: "no CHANGELOG.md section for 1.3.0" });
});

test("the repository's CHANGELOG.md has notes for the version in the manifest", async () => {
  const text = await readFile(new URL("../../CHANGELOG.md", import.meta.url), "utf8");
  const manifest = JSON.parse(await readFile(new URL("../../.release-please-manifest.json", import.meta.url), "utf8"));
  const version = manifest["."];
  const notes = notesFor(text, version);
  assert.equal(notes[0].version, version);
  assert.ok(notes[0].text.length > 0);
  assert.ok(notes.length <= 15);
});

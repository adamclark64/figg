// Release notes for the version file the in-app updater reads (latest.json).
// The publish step (publish-dmg-blob.mjs) takes the published version's
// section of CHANGELOG.md, plus the sections of a few older versions, so a
// user who skipped releases can see everything that changed since theirs.
// The app picks which of them to show (ReleaseNotes in Sources/FiggUpdate).
//
// Pure functions with no dependencies, so the gates job can test them
// without @vercel/blob or a real release.

/** A `## ` heading that starts a version section: release-please writes
 * `## [0.19.2](compare-url) (date)`, older entries are bare `## 0.6.0`. */
const VERSION_HEADING = /^## \[?(\d+\.\d+\.\d+)\]?/;

/** Cuts a changelog into its version sections, in file order. Every `## `
 * line ends the section before it; one that names no version (for example
 * `## Unreleased`) starts a section that is ignored. */
export function sections(changelog) {
  const found = [];
  let current = null;
  const close = () => {
    if (current) found.push({ version: current.version, text: trimBlankLines(current.lines) });
    current = null;
  };
  for (const line of changelog.split(/\r?\n/)) {
    if (line.startsWith("## ")) {
      close();
      const match = VERSION_HEADING.exec(line);
      if (match) current = { version: match[1], lines: [] };
    } else if (current) {
      current.lines.push(line);
    }
  }
  close();
  return found;
}

function trimBlankLines(lines) {
  let start = 0;
  let end = lines.length;
  while (start < end && lines[start].trim() === "") start++;
  while (end > start && lines[end - 1].trim() === "") end--;
  return lines.slice(start, end).join("\n");
}

/** Numeric compare of two X.Y.Z versions: negative when a is older. */
function compare(a, b) {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    if (pa[i] !== pb[i]) return pa[i] - pb[i];
  }
  return 0;
}

/** The notes for publishing `version`: its own section first, then up to
 * `max - 1` older ones, newest first by version (not file order). Versions
 * newer than `version` are left out, so republishing an old tag from a
 * newer changelog works. Throws when `version` has no section or an empty
 * one, or when a version that would be emitted appears twice (the notes
 * would be ambiguous); a repeat outside the window keeps its first
 * occurrence and does not block the release. */
export function notesFor(changelog, version, { max = 15 } = {}) {
  const all = sections(changelog);
  const counts = new Map();
  const first = new Map();
  for (const section of all) {
    counts.set(section.version, (counts.get(section.version) ?? 0) + 1);
    if (!first.has(section.version)) first.set(section.version, section);
  }
  const own = first.get(version);
  if (!own || own.text === "") throw new Error(`no CHANGELOG.md section for ${version}`);

  const notes = [...first.values()]
    .filter((s) => compare(s.version, version) <= 0)
    .filter((s) => s.version === version || s.text !== "")
    .sort((a, b) => compare(b.version, a.version))
    .slice(0, max);
  for (const note of notes) {
    if (counts.get(note.version) > 1) {
      throw new Error(`CHANGELOG.md has more than one section for ${note.version}`);
    }
  }
  return notes.map(({ version, text }) => ({ version, text }));
}

/** The exact latest.json text to upload, and a line for the job log.
 * The four fields installed copies read come first, in the order they
 * always have, then `notes`. The log line leaves the note text out so the
 * log stays readable. Throws (from notesFor) when the version has no
 * changelog section. */
export function feedFor({ version, dmgURL, size, signature, changelog }) {
  const notes = notesFor(changelog, version);
  const fields = { version, dmg_url: dmgURL, size, signature };
  const feed = JSON.stringify({ ...fields, notes }) + "\n";
  const logLine = `${JSON.stringify(fields)} notes for ${notes.length} versions (newest ${notes[0].version})`;
  return { feed, logLine };
}

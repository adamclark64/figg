// Vercel's "Ignored Build Step" for the website (vercel.json ignoreCommand).
// Exit 0 skips the build, exit 1 builds.
//
// The website is built from site/ plus the repo files listed in
// sources.mjs. Most commits change only the Swift app, its scripts or
// other docs, and building the site for those is wasted time, so they
// are skipped. If git cannot tell (shallow clone, missing commit), it
// builds: a needless build is cheaper than a stale site.

import { execFileSync } from 'node:child_process';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SOURCES } from './sources.mjs';

const SITE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(SITE, '..');
const paths = [relative(REPO, SITE), ...SOURCES.map((s) => s.file ?? s.dir)];

// Compare with the last deployed commit when Vercel knows it, so a push of
// several commits is judged as a whole, not just by its newest commit.
const bases = [process.env.VERCEL_GIT_PREVIOUS_SHA, 'HEAD^'].filter(Boolean);

for (const base of bases) {
  try {
    execFileSync('git', ['diff', '--quiet', base, 'HEAD', '--', ...paths], { cwd: REPO, stdio: 'ignore' });
    console.log(`No website changes since ${base} in ${paths.join(', ')}: skipping the build.`);
    process.exit(0);
  } catch (e) {
    if (e.status === 1) {
      console.log(`Website files changed since ${base}: building.`);
      process.exit(1);
    }
    // any other status: git could not compare against this base; try the next
  }
}
console.log('Could not compare with an earlier commit: building to be safe.');
process.exit(1);

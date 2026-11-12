// Builds the website into site/dist.
//
// The landing page is copied as it is. The docs pages are rendered from the
// Markdown files in the repo (README, docs/), so the repo is the CMS: edit
// a .md file, merge to main, and the site redeploys with the new text. Each
// page is also published as raw Markdown next to its HTML, because the
// people reading the setup guide are often coding agents that fetch a URL
// and cannot run JavaScript.
//
//   node build.mjs            build into dist/
//   node build.mjs --serve    build, then serve dist/ on http://localhost:4173
//                             (rebuilds on every page load)

import { Marked } from 'marked';
import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { dirname, extname, join, posix, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(SITE, '..');
const OUT = join(SITE, 'dist');

/** What gets published, in sidebar order. `file` is one repo path; `dir`
    publishes every .md in a folder.
    Nothing outside this list reaches the website. */
const SOURCES = [
  { group: 'Guides', file: 'README.md', url: '/docs', label: 'How figg works' },
  { group: 'Guides', file: 'docs/agent-setup.md', url: '/docs/agent-setup', label: 'Set up with an agent', agentPrompt: true },
];

/** Files in site/ that are part of the build, not of the website.
    music.mp3 (made by scripts/site-music.py) is kept for when the landing
    page plays music again; nothing uses it now, so it is not published. */
const NOT_STATIC = new Set([
  'build.mjs', 'docs-template.html', 'package.json', 'package-lock.json',
  'vercel.json', 'node_modules', 'dist', '.vercel', '.DS_Store', 'music.mp3',
]);

/** Links to repo files that are not published here (scripts, source) point
    at the file on GitHub. Set to null to render them as plain text. */
const REPO_FILE_BASE = 'https://github.com/adamclark64/figg/blob/main/';

/** Absolute address for the prompt people paste to their agent. Vercel sets
    the variable at build time; without it the page uses its own origin. */
const SITE_ORIGIN = process.env.VERCEL_PROJECT_PRODUCTION_URL
  ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}` : '';

const escapeHtml = (s) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

/** Markdown inline text without its markup, for ids, titles and labels. */
const plain = (md) => md.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/[`*_~]/g, '').trim();

/** Heading ids the way GitHub makes them, so `#anchors` written for GitHub
    keep working here. */
function slugger() {
  const seen = new Map();
  return (text) => {
    const base = plain(text).toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s/g, '-');
    const n = seen.get(base) ?? 0;
    seen.set(base, n + 1);
    return n ? `${base}-${n}` : base;
  };
}

/** Expands SOURCES into one entry per page; files that do not exist yet are
    skipped so the site still builds before a doc is merged. */
async function collectPages() {
  const pages = [];
  for (const source of SOURCES) {
    const files = source.file
      ? [{ file: source.file, url: source.url }]
      : (await readdir(join(REPO, source.dir)).catch(() => []))
          .filter((name) => name.endsWith('.md')).sort()
          .map((name) => ({ file: posix.join(source.dir, name), url: `${source.url}/${name.slice(0, -3)}` }));
    for (const { file, url } of files) {
      const markdown = await readFile(join(REPO, file), 'utf8').catch(() => null);
      if (markdown === null) { console.warn(`skipped ${file}: not in this checkout`); continue; }
      const title = plain(markdown.match(/^#\s+(.+)$/m)?.[1] ?? file);
      pages.push({ ...source, file, url, markdown, title, label: source.label ?? title });
    }
  }
  return pages;
}

/** `/docs` is written as docs/index.*, everything else as its own file. */
const outPath = (page, ext) => (page.url === '/docs' ? 'docs/index' : page.url.slice(1)) + ext;
const rawUrl = (page) => '/' + outPath(page, '.md');

function render(page, pages) {
  const byFile = new Map(pages.map((p) => [p.file, p]));
  const slug = slugger();
  const toc = [];
  const marked = new Marked({
    gfm: true,
    renderer: {
      heading({ tokens, depth, text }) {
        const id = slug(text);
        const html = this.parser.parseInline(tokens);
        if (depth === 2) toc.push({ id, text: plain(text) });
        return depth === 1
          ? `<h1 id="${id}">${html}</h1>\n`
          : `<h${depth} id="${id}"><a class="anchor" href="#${id}" aria-label="Link to this section">#</a>${html}</h${depth}>\n`;
      },
      link({ href, title, tokens }) {
        const html = this.parser.parseInline(tokens);
        const attr = title ? ` title="${escapeHtml(title)}"` : '';
        if (/^[a-z][a-z0-9+.-]*:|^\/\//i.test(href)) return `<a href="${escapeHtml(href)}"${attr} rel="noopener">${html}</a>`;
        if (href.startsWith('#')) return `<a href="${escapeHtml(href)}"${attr}>${html}</a>`;
        // A link to another file in the repo: point at its page here if it
        // has one.
        const [path, fragment] = href.split('#');
        const target = posix.normalize(posix.join(posix.dirname(page.file), path));
        const hash = fragment ? `#${fragment}` : '';
        const published = byFile.get(target);
        if (published) return `<a href="${published.url}${hash}"${attr}>${html}</a>`;
        if (REPO_FILE_BASE && !target.startsWith('..')) return `<a href="${REPO_FILE_BASE}${target}${hash}"${attr} rel="noopener">${html}</a>`;
        return html;
      },
    },
  });
  const content = marked.parse(page.markdown)
    .replaceAll('<table>', '<div class="table-wrap"><table>')
    .replaceAll('</table>', '</table></div>');
  const firstParagraph = page.markdown.split(/\n\s*\n/).find((block) => /^[A-Za-z*`[]/.test(block.trim())) ?? '';
  const description = plain(firstParagraph).replace(/\s+/g, ' ').slice(0, 200);
  return { content, toc, description };
}

function navHtml(pages, current) {
  const groups = [...new Set(pages.map((p) => p.group))];
  return groups.map((group) => {
    const links = pages.filter((p) => p.group === group).map((p) =>
      `<li><a href="${p.url}"${p === current ? ' aria-current="page"' : ''}>${escapeHtml(p.label)}</a></li>`);
    return `<p class="nav-group">${escapeHtml(group)}</p>\n<ul>${links.join('')}</ul>`;
  }).join('\n');
}

function tocHtml(toc) {
  if (toc.length < 3) return '';
  const items = toc.map(({ id, text }) => `<li><a href="#${id}">${escapeHtml(text)}</a></li>`).join('');
  return `<details class="toc"><summary>On this page <span>${toc.length} sections</span></summary><ol>${items}</ol></details>`;
}

function agentPromptHtml(page) {
  if (!page.agentPrompt) return '';
  const url = rawUrl(page);
  return `<aside class="agent" aria-label="Prompt for your coding agent">
  <p class="agent-eyebrow">Hand this to your agent</p>
  <div class="agent-row">
    <p class="agent-prompt" id="agent-prompt">Read <span data-origin="${SITE_ORIGIN}">${SITE_ORIGIN}</span>${url} and follow it to set figg up on this Mac.</p>
    <button class="copy" type="button" data-copy="agent-prompt">Copy</button>
  </div>
  <p class="agent-note">Paste it into Claude Code, Codex, Cursor or any agent with a terminal. It does the installing and checking; you click the macOS permission prompts and type your own API key.</p>
</aside>`;
}

async function build() {
  await rm(OUT, { recursive: true, force: true });
  await mkdir(OUT, { recursive: true });
  for (const name of await readdir(SITE)) {
    if (!NOT_STATIC.has(name)) await cp(join(SITE, name), join(OUT, name), { recursive: true });
  }

  const template = await readFile(join(SITE, 'docs-template.html'), 'utf8');
  const pages = await collectPages();
  for (const page of pages) {
    const { content, toc, description } = render(page, pages);
    const slots = {
      title: escapeHtml(page.label),
      description: escapeHtml(description),
      nav: navHtml(pages, page),
      toc: tocHtml(toc),
      agent: agentPromptHtml(page),
      content,
      source: escapeHtml(page.file),
      raw: rawUrl(page),
    };
    const html = template.replace(/\{\{(\w+)\}\}/g, (whole, key) => slots[key] ?? whole);
    await mkdir(dirname(join(OUT, outPath(page, '.html'))), { recursive: true });
    await writeFile(join(OUT, outPath(page, '.html')), html);
    await writeFile(join(OUT, outPath(page, '.md')), page.markdown);
  }
  return pages;
}

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.md': 'text/plain; charset=utf-8',
  '.png': 'image/png', '.mp3': 'audio/mpeg', '.js': 'text/javascript', '.css': 'text/css',
};

/** A small stand-in for Vercel's static hosting with cleanUrls, for local
    previews. */
function serve(port) {
  createServer(async (req, res) => {
    const path = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/\/+$/, '') || '/';
    if (!extname(path)) await build();
    const candidates = extname(path) ? [path] : [`${path}.html`, posix.join(path, 'index.html')];
    for (const candidate of candidates) {
      const file = join(OUT, posix.normalize(candidate));
      const body = file.startsWith(OUT) ? await readFile(file).catch(() => null) : null;
      if (body) {
        res.writeHead(200, { 'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream' });
        return res.end(body);
      }
    }
    res.writeHead(404, { 'Content-Type': 'text/plain' }).end('Not found');
  }).listen(port, () => console.log(`http://localhost:${port}`));
}

const pages = await build();
console.log(`built ${pages.length} docs pages into dist/: ${pages.map((p) => p.url).join(' ')}`);
if (process.argv.includes('--serve')) serve(Number(process.env.PORT) || 4173);

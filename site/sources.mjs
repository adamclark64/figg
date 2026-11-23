/** What gets published, in sidebar order. `file` is one repo path; `dir`
    publishes every .md in a folder.
    Nothing outside this list reaches the website, and nothing outside it
    and site/ itself makes Vercel build (ignore-build.mjs reads it too). */
export const SOURCES = [
  { group: 'Guides', file: 'README.md', url: '/docs', label: 'How figg works' },
  { group: 'Guides', file: 'docs/agent-setup.md', url: '/docs/agent-setup', label: 'Set up with an agent', agentPrompt: true },
];

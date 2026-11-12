# Daily issue digest

Every day (13:00 UTC) the `Daily issue digest` workflow gathers the last
24 hours of `user-report` issues plus the open backlog, has
Claude write a short triage digest (groups, likely duplicates, suggested
priority, open questions), and posts it as a comment on the single
pinned **Daily issue digest** issue. It also lands in the run's step summary
and, when a webhook is configured, in Slack.

## What it never does

- No code edits, no PRs, no merges, no deploys.
- No issue mutation beyond posting the digest comment, creating or pinning
  the digest issue on first run, and creating the labels it relies on if
  they are missing.

## Why it is built in two jobs

Anyone on GitHub can file a report, so every title and body is hostile
input, and some of it will be written to steer the model.

- The `write` job reads the issues with a read-only token and sends them to
  the model as text (`.github/scripts/write-digest.sh`). The model has no
  tools, reads no files and never sees a secret. The worst a report can do
  is skew the summary or talk the model into repeating a plain web address.
- The `post` job publishes that text. It holds the token that can comment
  and the Slack secret, runs no model, and never runs anything the first
  job produced. Before posting it cuts the digest to 20,000 bytes, breaks
  every `@` so that nobody is pinged, and breaks references to other
  repositories so that none gets a backlink. The Slack copy also has `<`,
  `>` and `&` escaped, so it can make no disguised link and no channel-wide
  ping; Slack still turns a bare web address into a link.
- In the plain list (no model), titles are shown as code, which GitHub
  never turns into a mention, a link or an issue reference.

Keep it that way: do not give the model tools, and do not add a step to the
`post` job that runs or evaluates the digest.

## Configuration

| kind | name | required | notes |
|---|---|---|---|
| secret | `ANTHROPIC_API_KEY` | no | Claude API key for the summary; only the `write` job reads it |
| secret | `DIGEST_SLACK_WEBHOOK_URL` | no | incoming webhook for a Slack mirror; only the `post` job reads it |
| var | `DIGEST_MODEL` | no | default `claude-sonnet-5-5` |
| var | `DIGEST_HOURS` | no | default `24` |

Without the API key the run still succeeds: the fallback step writes a
plain list of new, closed and open reports instead of a summary. The same
happens if the model call fails or is declined.

## Operating it

- Dry run (step summary only, no comment):
  `gh workflow run issue-digest.yml -f hours=168 -f post=false`
- Real run: `gh workflow run issue-digest.yml -f hours=24 -f post=true`
- Re-running is safe: each run adds one comment, nothing else. Content is
  idempotent per day only in the sense that it summarizes the same window.
- GitHub renders long issues slowly after a few hundred comments; close the
  digest issue once a year and the next run creates a fresh one.

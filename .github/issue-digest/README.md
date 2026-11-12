# Daily issue digest

Every day (13:00 UTC) the `Daily issue digest` workflow gathers the last
24 hours of `user-report` issues plus the open backlog, has
Claude write a short triage digest (groups, likely duplicates, suggested
priority, open questions), and posts it as a comment on the single
pinned **Daily issue digest** issue. It also lands in the run's step summary
and, when a webhook is configured, in Slack.

## What it never does

- No code edits, no PRs, no merges, no deploys.
- No issue mutation beyond posting the digest comment (and creating or
  pinning the digest issue on first run).
- The model step runs with read-only tools plus Write (for the digest file
  itself); it has no tool that can touch GitHub, so a malicious issue body
  cannot make it close, label or edit anything. Issue text is treated as
  untrusted data in the prompt.

## Configuration

| kind | name | required | notes |
|---|---|---|---|
| secret | `ANTHROPIC_API_KEY` | one of | API billing (the active line in the workflow) |
| secret | `CLAUDE_CODE_OAUTH_TOKEN` | these | subscription alternative from `claude setup-token`; swap the commented lines |
| secret | `DIGEST_SLACK_WEBHOOK_URL` | no | incoming webhook for a Slack mirror |
| var | `DIGEST_MODEL` | no | default `claude-sonnet-5-5` |
| var | `DIGEST_HOURS` | no | default `24` |

With neither model secret set, the run still succeeds: the fallback step
writes a plain list of new, closed and open reports instead of a summary.

## Operating it

- Dry run (step summary only, no comment):
  `gh workflow run issue-digest.yml -f hours=168 -f post=false`
- Real run: `gh workflow run issue-digest.yml -f hours=24 -f post=true`
- Re-running is safe: each run adds one comment, nothing else. Content is
  idempotent per day only in the sense that it summarizes the same window.
- GitHub renders long issues slowly after a few hundred comments; close the
  digest issue once a year and the next run creates a fresh one.

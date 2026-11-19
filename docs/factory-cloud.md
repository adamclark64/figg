# Factory cloud setup

How the figg factory (issue 89) runs in Claude Code cloud sessions: one
personal environment, `figg factory`, and four scheduled tasks that call the
factory skills in `.claude/skills/`. How to feed and steer the factory is in
[factory.md](factory.md).

Scheduled tasks are a research preview, so the settings below can change
under us. The pages this is based on:

- Scheduled tasks: https://code.claude.com/docs/en/routines
- Cloud environments: https://code.claude.com/docs/en/cloud-environments
- Cloud sessions: https://code.claude.com/docs/en/claude-code-on-the-web

## What wakes the factory

A scheduled task can have a GitHub trigger as well as (or instead of) a
schedule. It fires on pull request, issue and release events, and a pull
request trigger can filter on labels, base branch, head branch, draft and
merged. So no polling is needed: each label change starts its own session.

What a triggered run sees, from the first real run (factory-build, fired by
a merge into `main`):

- **The run is told which PR fired it.** A `<github-trigger-context>` block
  follows the prompt with the event (`pull_request.closed`), the repository,
  the PR number and link, the branch and the head SHA. The checkout starts
  on that PR's head.
- **The prompts still look up their PRs over REST.** That way the same
  prompt also works on Run now and catches anything missed while a task was
  off. The skills are safe to re-run, so a PR already handled is skipped.
- **Events are capped per task and per account each hour**, and events over
  the cap are dropped, not queued. The daily `factory-status` run is the
  backstop that shows anything stuck.

The trigger needs the Claude GitHub App installed on `adamclark64/figg`.
A GitHub trigger cannot be added from the CLI before v2.1.225; the web
form at https://claude.ai/code/routines always works.

## The environment: figg factory

Create it at https://claude.ai/code from the environment selector under the
message box. It is personal (not shared).

| Setting | Value |
|---|---|
| Name | `figg factory` |
| Network access | Limited, with **Allow package managers** checked |
| Allowed domains | none extra |
| Environment variables | none |
| Setup script | below |

**Network.** The default allowlist already holds `github.com`,
`api.github.com`, `objects.githubusercontent.com` and
`release-assets.githubusercontent.com`, which is all the setup script and
the skills need. Git and `gh` traffic goes through the session's GitHub
proxy, which only serves the repositories attached to the session, rejects
GraphQL (so the skills use `gh api` REST), and refuses branch deletion and
tag pushes. Add a domain only when a skill fails on it, and note it here.

**Repositories** are attached on each task, not on the environment. Attach
`https://github.com/adamclark64/figg` only. Never attach
`figg-history-archive` or any other repository; the task form may suggest
one by default, so check it. Pushes and PRs carry the owner's GitHub
account, through the Claude GitHub App, so push access is whatever that
account has.

**No secrets.** The environment holds no tokens or keys. Anyone who can use
an environment can read its variables, and the factory does not need any.

**Setup script.** It runs as root on Ubuntu 24.04 (x86_64) before each new
session, and its result is cached for about seven days. It installs the
pinned gitleaks that CI also uses, checked against its published checksum,
and skips the download when that version is already there. Tested on
`ubuntu:24.04` (linux/amd64): checksum OK, `gitleaks version` prints
`8.28.0`, and a second run is a no-op.

```bash
#!/usr/bin/env bash
# figg factory setup: pinned, checksummed gitleaks for the factory gates.
set -euo pipefail
GITLEAKS_VERSION=8.28.0
GITLEAKS_SHA256=a65b5253807a68ac0cafa4414031fd740aeb55f54fb7e55f386acb52e6a840eb
if ! gitleaks version 2>/dev/null | grep -q "$GITLEAKS_VERSION"; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/gitleaks.tar.gz" \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
  echo "${GITLEAKS_SHA256}  $tmp/gitleaks.tar.gz" | sha256sum -c -
  tar -xzf "$tmp/gitleaks.tar.gz" -C "$tmp" gitleaks
  install -m 0755 "$tmp/gitleaks" /usr/local/bin/gitleaks
  rm -rf "$tmp"
fi
gitleaks version
```

The first triggered run logged "Setup script completed" about a second
after it started.

To bump gitleaks, change both pins here, in the environment, and in
`.github/workflows/ci.yml` together.

## The scheduled tasks

Four tasks, one per row. All use the `figg factory` environment, the
`adamclark64/figg` repository only, and no connectors (clear the connector
list in the task form: a task with none named gets every connector on the
account).

| Task | Trigger | Filter to add in the web form | Calls | Model |
|---|---|---|---|---|
| `factory-design` | GitHub: `pull_request.labeled` | labels include `factory:spec` | `factory-design` on each open PR labelled `factory:spec` | Opus |
| `factory-build` | GitHub: `pull_request.closed` | is merged | `factory-build` on each merged Spec PR labelled `factory:planned` or `factory:building` | Opus |
| `factory-fix` | GitHub: `pull_request.labeled` | labels include `factory:ci-failed`, head branch starts with `factory/` | `factory-fix` on each open PR labelled `factory:ci-failed` | Opus |
| `factory-status` | Schedule: daily, `0 14 * * *` (14:00 UTC) | none | `factory-status` | Sonnet |

**The triggers are unfiltered for now.** The API that adds a GitHub trigger
takes the event list but rejects every filter shape tried, so filters can
only be set by hand in each task's web form. Until they are, every label
added to any PR starts a `factory-design` run and a `factory-fix` run, and
every closed PR starts a `factory-build` run. Each of those finds nothing
to do and stops (about 16 seconds of Opus on the first one), but they add
up.

`factory-build` has to run again after each item PR lands in its
integration branch (`factory-build` says so). Its `pull_request.closed`
trigger covers that too, as long as the filter is only "is merged": an item
PR merged into `factory/NNNN` fires it, and the prompt finds the Spec PR
still labelled `factory:building`.

`factory:ci-failed` is added by CI's `label` job with the workflow's own
token. GitHub does not start workflows from that token's events, but app
webhooks are still delivered. That has not been seen on a real run yet;
if a red factory PR sits without a `factory-fix` run, run the task by hand
and note it here.

### Prompts

Every prompt follows the same shape. It skips PRs labelled
`factory:needs-human`. It reads the skill from `origin/main`,
not from the PR's checkout, so a PR cannot change the instructions that
process it, and it stops with a note when the skill has not been merged yet.

`factory-design`:

```text
Figg factory, design stage. Run `git fetch origin main`. If
`git cat-file -e origin/main:.claude/skills/factory-design/SKILL.md` fails,
stop and report "factory-design is not on main yet; nothing done". Otherwise
read that file with `git show` and follow it, ignoring any copy of the skill
in this checkout. List the open PRs labelled factory:spec with
`gh api --method GET repos/adamclark64/figg/issues -f labels=factory:spec -f state=open`
(keep only entries with a pull_request field, and skip any that also has
factory:needs-human). Run the skill once for each PR number. If there are
none, report that and stop.
```

`factory-build`:

```text
Figg factory, build stage. Run `git fetch origin main`. If
`git cat-file -e origin/main:.claude/skills/factory-build/SKILL.md` fails,
stop and report "factory-build is not on main yet; nothing done". Otherwise
read that file with `git show` and follow it, ignoring any copy of the skill
in this checkout. Find the Spec PRs to build: run
`gh api --method GET repos/adamclark64/figg/issues -f state=closed -f labels=<label>`
once with factory:planned and once with factory:building, keep pull requests
merged into main, and skip any that also has factory:needs-human. Run the
skill once for each. If there are none, report that and stop.
```

`factory-fix`:

```text
Figg factory, fix stage. Run `git fetch origin main`. If
`git cat-file -e origin/main:.claude/skills/factory-fix/SKILL.md` fails,
stop and report "factory-fix is not on main yet; nothing done". Otherwise
read that file with `git show` and follow it, ignoring any copy of the skill
in this checkout. List the open PRs labelled factory:ci-failed with
`gh api --method GET repos/adamclark64/figg/issues -f labels=factory:ci-failed -f state=open`,
keep pull requests whose head branch starts with factory/ and that do not
have factory:needs-human, and run the skill once for each. If there are
none, report that and stop.
```

`factory-status`:

```text
Figg factory, daily status. Run `git fetch origin main`. If
`git cat-file -e origin/main:.claude/skills/factory-status/SKILL.md` fails,
stop and report "factory-status is not on main yet". Otherwise read that
file with `git show` and follow it exactly. It is read-only: change nothing.
```

### Cost

Each fire is a full cloud session on the owner's subscription. A spec costs
about one design run, one or more build runs, and one fix run per red CI
(at most three per PR before `factory:needs-human`). The daily status run is
one short Sonnet session. Unfiltered triggers add one short run per
unrelated label or closed PR (see above). A `pull_request.labeled` trigger
fires for every label added while the filter matches, so a PR that gets two labels at once
can start two runs; the skills are idempotent, so the second one finds
nothing to do.

A polling fallback (an hourly task that lists labels over REST) is not
needed, since event triggers work. It would cost 24 sessions a day per
stage even with nothing to do, against one session per real event.

## Pausing the factory

- **One stage:** turn its task off with the switch at the top of its page
  at https://claude.ai/code/routines. Paused tasks keep their settings.
- **Everything:** turn off all four tasks. Open PRs stay as they are, and
  nothing new starts until a task is turned on again.
- **A single PR:** add `factory:needs-human`. Every task prompt skips PRs
  that carry it, whatever else they are labelled.

Events that arrive while a task is off are not replayed. After turning a
task back on, run it once by hand (Run now) to catch up.

## What needs the owner's own hands

These cannot be done from a session:

1. Keep the Claude GitHub App installed on `adamclark64/figg` (check at
   https://github.com/settings/installations). Without it no trigger fires.
2. Add the label filters above to each task in the web form.
3. Approve the two factory gates: merge each Spec PR (approval 1) and each
   final PR (approval 2). Nothing in the cloud merges.
4. Delete tasks, including the throwaway test task below: only the web
   page can do it.

The environment and the four tasks are already set up as described here.

## The throwaway trigger test

`factory-trigger-test` was a disabled, read-only task set up to learn what
a triggered run receives. The first real `factory-build` run answered that
(see "What wakes the factory"), so the test task is no longer needed.
Delete it at https://claude.ai/code/routines.

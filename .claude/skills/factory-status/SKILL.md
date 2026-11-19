---
name: factory-status
description: Print a short read-only summary of the figg factory queue - every open factory PR (Spec, item and final PRs), its factory:* label, CI state and what it waits on, plus integration branches. Changes nothing. Use for "/factory-status", "what is the factory doing", "what needs me".
---

# factory-status

Read-only. Never comment, label, push or edit anything from this skill.
REST only (`gh api --method GET repos/adamclark64/figg/...`).

## Gather

```bash
git fetch origin --prune
git ls-remote --heads origin 'factory/*' | awk '{print $2}' | sed 's#refs/heads/##'

gh api --method GET repos/adamclark64/figg/pulls -f state=open -f per_page=100 --paginate \
  --jq '.[] | select(.head.ref | startswith("factory/")) | [.number, .head.ref, .base.ref, .draft, ([.labels[].name | select(startswith("factory:"))] | join(",")), .head.sha, .updated_at, .title] | @tsv'
```

For each PR, CI on its head:

```bash
gh api --method GET repos/adamclark64/figg/commits/<sha>/check-runs \
  --jq '[.check_runs[] | "\(.name):\(.conclusion // .status)"] | join(" ")'
```

Recently merged Spec PRs still building (merged, label `factory:building`):

```bash
gh api --method GET repos/adamclark64/figg/issues -f state=closed -f labels=factory:building --jq '.[] | [.number, .title] | @tsv'
```

Ignore `factory/step-*` and `factory/spike-*` branches: those are the
factory's own setup work, not specs.

## Report

Group by spec id (the `NNNN` in the branch name), oldest first. One line
per PR: number, kind (spec, item pN, final), label, CI, and what it waits
on. Map labels like this:

| Label | Waits on |
|---|---|
| `factory:spec` | design stage (`/factory-design <PR>`) |
| `factory:planned` | **you**: approval 1, merge the Spec PR |
| `factory:building` | items building; green item PRs wait on you to merge |
| `factory:ci-failed` | fix stage (`/factory-fix <PR>`) |
| `factory:needs-human` | **you**: read the PR's last comment |
| `factory:final` | **you**: approval 2, merge the final PR |
| none, draft | **you**: review a triage draft, then add `factory:spec` |

Also flag: an integration branch with no open PRs and no final PR (a build
run may have stopped), and any factory PR not updated for 3 days.

Finish with a one-line "Needs you:" list of PR numbers, or "Needs you:
nothing". Keep the whole report under 25 lines.

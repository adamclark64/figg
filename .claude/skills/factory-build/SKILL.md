---
name: factory-build
description: Build stage of the figg factory. After a Spec PR (factory:planned) is merged into main, create the integration branch factory/NNNN, fan the plan items out to parallel subagents (one branch factory/NNNN-pN and one PR into factory/NNNN per item with no unmet dependency), and once every item has landed open the final PR from factory/NNNN into main with the acceptance criteria ticked, labelled factory:final. Safe to re-run; each run does the next step. Use for "/factory-build NNNN", "/factory-build <merged Spec PR number>", or when a factory Spec PR is merged.
---

# factory-build

Stage 3 of the figg factory (issue 89). Input: a spec id `NNNN` or the
number of its merged Spec PR. Each run reads the state from GitHub and does
the next thing, so run it again after item PRs land.

Names (do not change them): integration branch `factory/NNNN`, item
branches `factory/NNNN-p1`, `factory/NNNN-p2`, ... (lowercase `p`, matching
plan id `P1`, `P2`), item PRs into `factory/NNNN`, final PR from
`factory/NNNN` into `main`.

## Ground rules (every factory skill)

- **Everything is public.** No employer, client or workplace names, no
  secrets or tokens, no personal data. Product reasons only.
- **Never use figg meetings, transcripts or notes** (figg MCP tools, the
  local database, exports) as content for code, examples or test data.
  Sample text is invented and neutral.
- **REST only**, `gh api --method <VERB> repos/adamclark64/figg/...`. No
  `gh pr`/`gh issue` commands.
- **Never merge anything**, never push to `main`, never force-push or
  delete a branch, never change repo settings, secrets or label
  definitions, never edit someone else's PR. The final PR into `main` is
  approval 2 and belongs to the human.
- **No local Swift build.** Swift only builds on macOS. Write the code and
  its Swift Testing tests carefully and let CI's `test` job prove them.
- **Gates before every push** (`BASE` is the branch the PR goes into):
  `scripts/factory/check-private-files.sh`,
  `scripts/factory/check-commits.sh origin/<BASE> HEAD`,
  `scripts/factory/check-rules.sh origin/<BASE> HEAD`. Missing script: stop.
- Conventional Commits, no em-dashes.

## 1. Find the approved spec

```bash
git fetch origin --prune
git ls-tree --name-only origin/main specs/ | grep '^specs/NNNN-'
```

The spec folder must be on `main` with `spec.md`, `design.md` and
`plan.md`. Confirm the Spec PR was merged (approval 1):

```bash
gh api --method GET repos/adamclark64/figg/pulls -f state=closed \
  -f head="adamclark64:factory/NNNN-<slug>" \
  --jq '.[] | {number, merged_at, labels: [.labels[].name]}'
```

Stop if it is not merged, or if it carries `factory:needs-human`: that is
the human pausing the whole spec (`docs/factory.md`). Read `spec.md`, `design.md` and `plan.md` from
`origin/main` (`git show origin/main:specs/NNNN-<slug>/plan.md`) and
`AGENTS.md`.

## 2. Create the integration branch (first run only)

If `git ls-remote --heads origin factory/NNNN` prints nothing:

```bash
git switch -c factory/NNNN origin/main
git push -u origin factory/NNNN
gh api --method POST repos/adamclark64/figg/issues/<SPEC_PR>/labels -f 'labels[]=factory:building'
gh api --method DELETE repos/adamclark64/figg/issues/<SPEC_PR>/labels/factory:planned --silent
```

Comment on the Spec PR that the build has started, with the item list.

## 3. Work out each item's state

Parse every `### Pn.` heading in `plan.md` with its `Depends on` list. For
each item:

```bash
gh api --method GET repos/adamclark64/figg/pulls -f state=all \
  -f head="adamclark64:factory/NNNN-pN" \
  --jq '.[] | {number, state, merged_at, head_sha: .head.sha, labels: [.labels[].name]}'
```

- **landed**: a PR merged into `factory/NNNN`.
- **open**: a PR open. Note its CI (`gh api --method GET
  repos/adamclark64/figg/commits/<head_sha>/check-runs --jq '.check_runs[] |
  {name, status, conclusion}'`) and whether it has `factory:ci-failed` or
  `factory:needs-human`.
- **closed**: a PR closed without merging. Stop and ask the human; never
  reopen or replace it on your own.
- **not started**: no PR and no remote branch. If a remote branch exists
  without a PR, a previous run died after pushing: open the PR for it
  (step 4e) instead of starting again.

An item is **ready** when it is not started and every item it depends on
has landed. An open item PR with `factory:needs-human` is paused: leave it
alone, start nothing that depends on it, and list it in the report.

## 4. Fan out the ready items

Launch one subagent per ready item, all in one message so they run in
parallel, each with the Agent tool's `isolation: "worktree"`. Items with no
dependency between them touch different files (the plan guarantees it; if
two ready items share a file, run them one after the other instead). Give
each subagent this brief, filled in:

> You are building plan item PN of figg factory spec NNNN in
> adamclark64/figg. Read AGENTS.md, specs/NNNN-<slug>/spec.md, design.md
> and the PN section of plan.md (on origin/main). Build only PN: its files,
> its tests. Ground rules: the repo and every branch are public (no
> employer or client names, no secrets, no meeting content; invented
> neutral sample text only, never figg meetings or transcripts); REST only
> via `gh api --method <VERB> repos/adamclark64/figg/...`; never merge,
> never push to main, never force-push; Conventional Commits, no
> em-dashes. Swift does not build here, so write code that compiles on
> Swift 6.3 in Swift 5 language mode and Swift Testing tests (`import
> Testing`, `@Test`, `#expect`) with the existing fakes, and rely on CI.
>
> a. `git fetch origin && git switch -c factory/NNNN-pN origin/factory/NNNN`
> b. Implement PN and the test named in its "Proved by". Follow the code
>    around it; keep logic in library targets behind protocols.
> c. Commit with a Conventional Commit subject that describes the change
>    to a user (it becomes changelog text), e.g. `feat(export): ...`.
> d. Run `scripts/factory/check-private-files.sh`,
>    `scripts/factory/check-commits.sh origin/factory/NNNN HEAD`,
>    `scripts/factory/check-rules.sh origin/factory/NNNN HEAD`; fix until
>    they pass, then `git push -u origin factory/NNNN-pN`.
> e. Write the PR body to /tmp/factory/NNNN-pN.md: what PN does, "Plan
>    item PN of specs/NNNN-<slug>/plan.md", its Proved by line, and the
>    files touched. Open the PR and label it:
>    `gh api --method POST repos/adamclark64/figg/pulls -f title="<the commit subject>" -f head=factory/NNNN-pN -f base=factory/NNNN -F body=@/tmp/factory/NNNN-pN.md --jq '.number, .html_url'`
>    `gh api --method POST repos/adamclark64/figg/issues/<PR>/labels -f 'labels[]=factory:building'`
> f. Return the PR number and URL, and anything you were unsure of.

When they return, check each PR exists, is based on `factory/NNNN`, and
touches only its item's files (`gh api --method GET
repos/adamclark64/figg/pulls/<PR>/files --jq '.[].filename'`).

## 5. Getting item PRs landed

Auto-merge is off in the repository settings. If this session has a way to
turn on auto-merge for a PR (the session's `/ccr/` route), use it for item
PRs into `factory/NNNN` only. Otherwise, or if that fails: leave the PR
open. When its CI is green, comment on the Spec PR listing the item PRs
that are green and ready for the human to merge. Never merge them
yourself. A failing PR is `factory-fix`'s job (CI labels it
`factory:ci-failed`).

Do not sit polling CI; macOS jobs take many minutes. Report what is
pending and end the run. The next run continues from step 3.

## 6. Final PR (every item landed)

When every item has landed and no PR from `factory/NNNN` into `main` is
open yet:

1. Copy the spec's acceptance criteria. Tick an item only when the test or
   check that proves it is in `factory/NNNN` (find it with `git grep` on
   `origin/factory/NNNN`) and the item PR that added it passed CI. Leave
   manual steps unticked and mark them "(manual, for the reviewer)".
2. Write the body to `/tmp/factory/NNNN-final.md`: a short summary of the
   change, a link to the spec folder, the ticked checklist, one line per
   item PR (number and title), anything unresolved from design.md's Review
   notes, and "**Approval 2:** merging this PR ships spec NNNN to main."
3. Open it with a user-facing Conventional Commit title for the whole
   change (it is what release-please sees), and label it:

   ```bash
   gh api --method POST repos/adamclark64/figg/pulls \
     -f title="feat(<scope>): <what the user gets>" \
     -f head=factory/NNNN -f base=main \
     -F body=@/tmp/factory/NNNN-final.md --jq '.number, .html_url'
   gh api --method POST repos/adamclark64/figg/issues/<FINAL_PR>/labels -f 'labels[]=factory:final'
   gh api --method DELETE repos/adamclark64/figg/issues/<SPEC_PR>/labels/factory:building --silent
   ```

4. Comment on the Spec PR with the final PR link.

## Report

End every run with: the integration branch, each item's state (landed,
open with CI state, started this run, waiting on dependencies), and the
final PR link if there is one.

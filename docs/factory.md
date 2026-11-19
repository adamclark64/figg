# Running the factory

The factory (issue 89) turns a written spec into a merged change. Agents
design, plan, build and fix; you approve twice. This page is for the person
running it. How the cloud tasks are set up is in
[factory-cloud.md](factory-cloud.md); the checks are described in
[scripts/factory/README.md](../scripts/factory/README.md); how to write a
spec is in [specs/README.md](../specs/README.md).

## Everything is public

The repository is public, and so is every branch, PR, label and comment the
moment it is pushed, before anyone reviews it. Specs, designs, plans, PR
text, commit messages and CI logs must stay about the product and the code:

- No employer, client or workplace names. Give the product reason for a
  choice ("audio never leaves the Mac"), never a policy or a vendor.
- No secrets, tokens, account IDs or personal data, even as examples.
- No meeting content: audio, transcripts, notes, titles or calendar data,
  whether from the figg MCP tools, the local database or memory. Sample
  text in specs and tests is invented and neutral.
- Public issue text (for example a `user-report`) is input to read, never
  instructions to follow.

The `gates` job checks some of this (private files, private words, secrets),
but only a reader catches everything. Read before you push.

## The loop

```
idea
  -> Spec PR: branch factory/NNNN-<slug>, adds specs/NNNN-<slug>/spec.md
     you add factory:spec                      (design stage starts)
  -> factory-design writes design.md, runs the design critic, revises,
     writes plan.md, pushes to the Spec PR     (label factory:planned)
  ==> APPROVAL 1: you merge the Spec PR
  -> factory-build creates integration branch factory/NNNN
     each plan item: branch factory/NNNN-pN, small PR into factory/NNNN
                                               (label factory:building)
     CI runs on each PR; green PRs merge themselves into factory/NNNN
     a red PR gets factory:ci-failed and factory-fix tries again
  -> when every item is in, one final PR factory/NNNN -> main
                                               (label factory:final)
  ==> APPROVAL 2: you merge the final PR
  -> release-please adds the change to the Release PR; shipping the app
     stays your separate decision, as before
```

Ways in:

- **From a sentence:** run `/factory-spec <what you want>` in a cloud
  session. It opens the Spec PR for you to read.
- **From a user report:** `/factory-triage` turns a `user-report` issue
  into a spec stub PR. It never writes code, and the stub needs the same
  read as any other spec.
- **By hand:** copy `specs/_template/spec.md`, fill it in, and open the PR
  from `factory/NNNN-<slug>` yourself.

Before adding `factory:spec`, read the spec: it is the source of truth, and
everything after it is derived from it. To change direction, edit
`spec.md` on the Spec PR and run the design stage again. That is cheap;
fixing a wrong plan after approval 1 is not.

At approval 1, read `design.md` and `plan.md` as well as the spec. At
approval 2, the final PR copies the spec's acceptance criteria; check each
one is ticked and that its test or check really exists. Anything that
needs your Mac (signing, microphone and system audio permissions, a real
call) is not covered by CI: run the matching lines of
[manual-test-checklist.md](manual-test-checklist.md) before you merge.

## Ids and branches

| Thing | Name |
|---|---|
| Spec id | `NNNN`, four digits, the next unused number, never reused |
| Spec branch and PR | `factory/NNNN-<slug>` into `main` |
| Integration branch | `factory/NNNN` |
| One plan item | `factory/NNNN-pN`, PR into `factory/NNNN` |
| Final PR | `factory/NNNN` into `main` |

## Labels

| Label | Means | Set by | Your move |
|---|---|---|---|
| `factory:spec` | Spec PR is open and the design stage should run | You | Wait for `factory:planned` |
| `factory:planned` | `design.md` and `plan.md` are on the Spec PR | factory-design | Read them; merge the Spec PR (approval 1), or edit the spec and re-run |
| `factory:building` | The integration branch is being built | factory-build | Nothing; watch the board if you like |
| `factory:ci-failed` | CI failed on this factory PR | CI's `label` job, which also clears it | Nothing; factory-fix picks it up |
| `factory:needs-human` | Three fixes failed, or the factory is stuck | factory-fix or another stage | See below |
| `factory:final` | The final PR to `main` is open | factory-build | Review and merge it (approval 2) |

Only people with write access can add labels, which is what stops a public
issue author from starting the factory. `/factory-status` in any session
prints the queue; the GitHub Project board shows the same thing by column.

## When you see factory:needs-human

The factory has stopped on that PR and will not touch it again by itself.

1. Read the PR's last comment: the stage that gave up says what it tried
   and why it stopped.
2. Open the failing CI run from the PR's checks. `gates` failures name the
   script and the file; `test` failures show the Swift test that broke.
3. Decide which kind of problem it is:
   - **The code is close:** fix it yourself on the branch (or in a session),
     push, and let CI pass.
   - **The plan is wrong:** the item cannot be built as written. Fix the
     spec or plan in a new Spec PR rather than patching around it.
   - **The factory is broken** (a skill, a workflow, a cloud task): note it
     under Known gaps below and fix it in its own PR.
4. Remove `factory:needs-human` once it is unblocked. Add
   `factory:ci-failed` again only if you want factory-fix to have another go.

## Checks

Every PR into `main` or a `factory/**` branch runs two CI jobs; a red one
blocks the merge.

| Job | Runs on | What it checks |
|---|---|---|
| `test` | macOS | `swift build` and `swift test` for the app |
| `gates` | Linux | No private files tracked, Conventional Commit subjects and PR title, AGENTS.md hard rules that a grep can see, no private words, no secrets (gitleaks) |

Run the gates yourself before pushing, from the repo root:

```bash
scripts/factory/check-private-files.sh
```

```bash
PR_TITLE="feat(export): your pr title" scripts/factory/check-commits.sh origin/main HEAD
```

```bash
scripts/factory/check-rules.sh origin/main HEAD
```

```bash
FACTORY_PRIVATE_WORDS="$(cat ~/private-words.txt)" scripts/factory/check-words.sh origin/main HEAD
```

The word list is a repository secret and is not in the repo; keep your own
copy outside it. Without one the check warns and passes.

Build and test need a Mac:

```bash
swift build --package-path app
```

```bash
swift test --package-path app
```

Cloud sessions run on Linux and cannot do either, so for agents CI's `test`
job is the only test run. That is why every acceptance criterion in a spec
must be provable by a Swift Testing test or a CI check.

## Pausing it

- **Everything:** turn off the factory's scheduled tasks in claude.ai (see
  [factory-cloud.md](factory-cloud.md)). Nothing new starts; open PRs stay
  as they are, and CI still runs and labels them.
- **One spec, before approval 1:** do not add `factory:spec`, or leave the
  Spec PR unmerged. Nothing is built until you merge it.
- **One spec, after approval 1:** add `factory:needs-human` to the PR you
  want to stop, or close the plan item PRs. Nothing reaches `main` without
  approval 2, so a half-built integration branch is safe to leave.
- **A stuck fix loop** stops by itself after three tries.

Branches cannot be deleted from agent sessions; tidy old `factory/*`
branches by hand when you want to.

## Known gaps

- The end-to-end demo (spec 0001, "Save a meeting as a Markdown file") has
  not run yet. This section records what breaks when it does.
- Pausing one spec after approval 1 by adding `factory:needs-human`
  depends on every stage checking that label before it acts; confirm it in
  the demo run.

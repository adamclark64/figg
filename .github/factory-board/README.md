# Factory board

The status view for the factory (issue 89). The `factory-board` workflow
rewrites the body of one pinned issue, **Factory board**, with a row per
spec: its id, title, stage, open item PRs, PRs with failed CI, PRs that
need a human, and links to the spec PR, `spec.md`, the integration branch
and the final PR.

It runs on every open, close, merge, edit or label change of a PR from a
`factory/` branch, after every `ci` run, daily at 06:17 UTC, and by hand.

## Where the rows come from

Branch names, per the factory contract:

| Branch | PR into | Is |
|---|---|---|
| `factory/NNNN-<slug>` | `main` | the spec PR |
| `factory/NNNN-pN` | `factory/NNNN` | one plan item |
| `factory/NNNN` | `main` | the final PR |

The stage is the furthest of what the labels on the spec's open PRs say and
what its branches show:

| Stage | Label | Or, without labels |
|---|---|---|
| Spec: design running | `factory:spec` | spec PR open |
| Planned: approval 1 | `factory:planned` | |
| Building | `factory:building` | spec PR merged, or any item PR |
| Final: approval 2 | `factory:final` | final PR open |
| Shipped | | final PR merged |
| Dropped | | nothing open, and the spec PR or final PR closed unmerged |

`factory:ci-failed` and `factory:needs-human` are flags, not stages: the
row lists the open PRs carrying them, and specs with a needs-human PR are
also listed at the top. Shipped and dropped specs fold into a list of the
latest 10.

## Labels

`ensure-labels.sh` creates any missing `factory:*` label on each run. It
never edits an existing one, so a colour changed by hand stays.

| Label | Colour | Meaning |
|---|---|---|
| `factory:spec` | `C5DEF5` | Spec PR open; the design stage runs |
| `factory:planned` | `FBCA04` | Plan ready; approval 1 is merging the Spec PR |
| `factory:building` | `1D76DB` | Integration branch in progress |
| `factory:ci-failed` | `D73A4A` | CI failed on this factory PR; set and cleared by CI |
| `factory:needs-human` | `B60205` | Three fixes failed or the factory is blocked |
| `factory:final` | `0E8A16` | Final PR to main open; approval 2 is merging it |

## What it never does

- Never checks out or runs PR code. It uses `pull_request_target` and
  `workflow_run`, so the workflow file and scripts always come from `main`.
- Never reads the event payload beyond deciding whether to run. Each run
  rebuilds the board from the REST API, so a missed event is fixed by the
  next one or by the daily run.
- Never edits code, PRs or labels on PRs, and runs no model. Its token can
  write issues only (plus read PRs and contents).
- Never touches an issue it did not open: the board is the open issue
  titled "Factory board" opened by `github-actions[bot]`, or the number in
  the `FACTORY_BOARD_ISSUE` repository variable if you set one.

## Untrusted text

Anyone with push access names branches and titles PRs, and a title can be
written to do harm on the page. Titles reach only `render.py`, inside a JSON
file, never a shell command line. There they are cut to 80 characters, put
on one line, HTML-escaped and Markdown-escaped (so they make no link,
image, code span or table break), with a zero-width space after every `@`
and after the `#` of an `owner/name#N` reference, so nobody is pinged and
no other repository gets a backlink. PRs from forks are ignored even on a
`factory/` branch name.

## Operating it

- Dry run (step summary only):
  `gh workflow run factory-board.yml -f post=false`
- Real run: `gh workflow run factory-board.yml`
- The first real run creates the issue and tries to pin it. If pinning
  fails, pin it by hand from the issue's sidebar.
- A run that finds the body already the same does not edit it, so the
  issue's edit history shows real changes only.
- If the board issue is closed, the next run opens a new one.

## Testing

```bash
python3 -m unittest discover -s .github/factory-board -v
```

`fixtures/make_pulls.py` writes `fixtures/pulls.json`, a REST-shaped list
of PRs that covers every stage, a hostile title, a fork PR and an ordinary
PR. The golden test compares the board for it with `fixtures/expected.md`.
After a deliberate change, regenerate both and read the diff:

```bash
python3 .github/factory-board/fixtures/make_pulls.py
```

```bash
python3 .github/factory-board/render.py --repo example/app .github/factory-board/fixtures/pulls.json > .github/factory-board/fixtures/expected.md
```

To see the board for the live repository without writing anything, run
from an empty folder (`fetch.sh` writes into `board/` there), with `F` set
to this folder's path:

```bash
REPO=adamclark64/figg bash "$F/fetch.sh" && python3 "$F/render.py" --repo adamclark64/figg board/pulls.json
```

## Optional: a GitHub Project alongside

A Project board looks better in GitHub mobile but can't be written by this
workflow: Projects are GraphQL-only, and `GITHUB_TOKEN` can't write a
Project owned by a user. GitHub's built-in Project workflows need no token,
so you can set one up once by hand and it keeps itself in step:

1. On your GitHub profile, open **Projects**, choose **New project**, pick
   the **Board** template and name it "figg factory".
2. Link it to the repository: on the repository's **Projects** tab,
   choose **Link a project** and pick "figg factory".
3. Open **...** > **Workflows**. Turn on **Auto-add to project** for the
   repository with the filter
   `is:pr label:factory:spec,factory:planned,factory:building,factory:final`.
4. In the same list, turn on **Item closed** and **Pull request merged**
   (both set Status to Done) and **Item reopened**.
5. For a view by stage, add a **Table** view and use **Slice by** >
   **Labels**, or group the board by Status and move cards by hand.

The issue stays the source of truth; the Project is a view.

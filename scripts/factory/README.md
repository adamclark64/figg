# Factory checks

Fast checks with no Swift toolchain. CI's `gates` job (`.github/workflows/ci.yml`)
runs every one of them on each PR into `main` or a `factory/**` branch; run
them yourself before pushing. `BASE` and `HEAD` are commits, usually
`origin/main` and `HEAD`.

| Script | Fails when |
|---|---|
| `check-private-files.sh` | A tracked file is under `.claude/` outside `settings.json`, `skills/`, `agents/`, or is a bundle, archive or handoff note |
| `check-commits.sh BASE HEAD` | A commit subject (or `PR_TITLE`) is not a Conventional Commit |
| `check-rules.sh BASE HEAD` | Added Swift lines send a sampling parameter or use `UserDefaults`, or any file has an em-dash |
| `check-words.sh BASE HEAD` | Added lines, paths, commit messages, `PR_TITLE` or `PR_BODY` contain a word from `FACTORY_PRIVATE_WORDS` |

CI also scans the PR's commits with a pinned gitleaks.

## Escape hatch

A line that really needs `UserDefaults` or a sampling parameter can carry
`factory-allow: userdefaults` or `factory-allow: sampling`, with a reason in
the same comment. Review sees the marker.

## Private words

`FACTORY_PRIVATE_WORDS` is a repository secret: one word or phrase per line,
matched case-insensitively, `#` lines ignored. The script never prints a
word or the line it matched, because Actions logs on a public repository
are public. When the secret is unset the check warns and passes.

The title and body are checked when CI runs, which is on each push. Editing
only the PR description does not rerun it; push again or rerun the job.

## factory:ci-failed

On PRs from `factory/` branches, CI's `label` job adds `factory:ci-failed`
when `test` or `gates` fails and removes it when both pass.

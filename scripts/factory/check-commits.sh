#!/usr/bin/env bash
# Fails unless every commit in a range, and the PR title if given, is a
# Conventional Commit. release-please turns these subjects into the
# changelog and the next version, so a malformed one drops a change from
# the release notes or bumps the wrong number.
#
# Usage: scripts/factory/check-commits.sh BASE HEAD
#        PR_TITLE="feat: ..." scripts/factory/check-commits.sh BASE HEAD
# Merge commits are skipped: GitHub writes those.
set -euo pipefail

base=${1:?usage: check-commits.sh BASE HEAD}
head=${2:?usage: check-commits.sh BASE HEAD}
cd "$(git rev-parse --show-toplevel)"

pattern='^(feat|fix|docs|chore|ci|refactor|test|perf|build|style|revert)(\([a-z0-9._/-]+\))?!?: [^ ].*'
bad=0

while IFS=$'\t' read -r sha subject; do
  [[ -z "$sha" ]] && continue
  if ! [[ "$subject" =~ $pattern ]]; then
    echo "::error::Commit ${sha:0:7} is not a Conventional Commit: \"$subject\". Use \"type(scope): summary\", e.g. \"fix(export): keep line breaks\"."
    bad=1
  fi
done < <(git log --no-merges --format='%H%x09%s' "$base..$head")

if [[ -n "${PR_TITLE:-}" ]] && ! [[ "$PR_TITLE" =~ $pattern ]]; then
  echo "::error::The PR title is not a Conventional Commit: \"$PR_TITLE\"."
  bad=1
fi

if [[ "$bad" -ne 0 ]]; then
  echo "Allowed types: feat fix docs chore ci refactor test perf build style revert." >&2
  exit 1
fi
echo "check-commits: all subjects are Conventional Commits."

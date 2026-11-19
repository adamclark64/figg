#!/usr/bin/env bash
# Fails when a change mentions a private word: a name or term that must
# never appear in this public repository. The list itself is private, so
# it comes from the FACTORY_PRIVATE_WORDS secret (one word or phrase per
# line, matched case-insensitively) and this script never prints a word
# or the line it was found on, only where it was found. Actions logs on a
# public repository are public.
#
# Checks the lines the range adds, the paths it touches, its commit
# messages, and the PR title and body (PR_TITLE, PR_BODY) when given.
#
# Usage: FACTORY_PRIVATE_WORDS=... scripts/factory/check-words.sh BASE HEAD
set -euo pipefail

base=${1:?usage: check-words.sh BASE HEAD}
head=${2:?usage: check-words.sh BASE HEAD}
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=lib.sh
source scripts/factory/lib.sh

if [[ -z "${FACTORY_PRIVATE_WORDS:-}" ]]; then
  echo "::warning::FACTORY_PRIVATE_WORDS is not set, so the private word check was skipped."
  exit 0
fi

words=$(mktemp)
trap 'rm -f "$words"' EXIT
chmod 600 "$words"
# Drop blank lines and comments, and trim spaces, so a stray empty line
# does not match everything.
printf '%s\n' "$FACTORY_PRIVATE_WORDS" \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -v -e '^$' -e '^#' > "$words" || true
if [[ ! -s "$words" ]]; then
  echo "::warning::FACTORY_PRIVATE_WORDS has no words, so the private word check was skipped."
  exit 0
fi

hit() { grep -qiFf "$words"; }
bad=0

while IFS=$'\t' read -r path line text; do
  if printf '%s\n' "$text" | hit; then
    echo "::error file=$path,line=$line::A private word is on this line. Reword it; the word is not shown because this log is public."
    bad=1
  fi
done < <(added_lines "$base" "$head")

while IFS= read -r path; do
  if printf '%s\n' "$path" | hit; then
    echo "::error::A changed file's path contains a private word. Rename it."
    bad=1
  fi
done < <(git diff --name-only "$base...$head")

while IFS= read -r sha; do
  if git log -1 --format=%B "$sha" | hit; then
    echo "::error::Commit ${sha:0:7}'s message contains a private word. Reword it with an interactive rebase before merging."
    bad=1
  fi
done < <(git rev-list "$base..$head")

if printf '%s\n%s\n' "${PR_TITLE:-}" "${PR_BODY:-}" | hit; then
  echo "::error::The PR title or description contains a private word. Edit it, then rerun this check."
  bad=1
fi

if [[ "$bad" -ne 0 ]]; then
  echo "Private words found; see the errors above." >&2
  exit 1
fi
echo "check-words: no private words found."

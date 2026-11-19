#!/usr/bin/env bash
# Writes board/board.md into the body of the pinned "Factory board" issue,
# creating and pinning the issue on first run. Leaves the issue alone when
# the body is already the same, so its edit history only shows real changes.
#
# The issue is the open one titled "Factory board" opened by this workflow
# (github-actions[bot]), or FACTORY_BOARD_ISSUE when that repository
# variable is set. An issue with the same title opened by anyone else is
# never touched.
#
# Env: REPO, GH_TOKEN, POST ("true"/"false"), FACTORY_BOARD_ISSUE (optional).
set -euo pipefail
: "${REPO:?set REPO to owner/name}"
[ -s board/board.md ] || { echo "no board to post"; exit 1; }

# An issue body holds 65,536 characters; render.py stays well under, but a
# body that is too long would fail the whole update.
if [ "$(wc -c < board/board.md)" -gt 60000 ]; then
  head -c 60000 board/board.md > board/cut.md
  printf '\n\n(cut to fit an issue body)\n' >> board/cut.md
  mv board/cut.md board/board.md
fi

cat board/board.md >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
if [ "${POST:-true}" != "true" ]; then echo "dry run, not posting"; exit 0; fi

title="Factory board"
num="${FACTORY_BOARD_ISSUE:-}"
if [ -z "$num" ]; then
  num=$(gh api "repos/$REPO/issues?state=open&creator=github-actions%5Bbot%5D&per_page=100" --paginate \
    --jq ".[] | select(.pull_request == null and .title == \"$title\") | .number" | sort -n | head -1)
fi

if [ -z "$num" ]; then
  num=$(jq -n --arg t "$title" --rawfile b board/board.md '{title: $t, body: $b}' \
    | gh api -X POST "repos/$REPO/issues" --input - --jq .number)
  # Pinning is GraphQL under the hood; the board works unpinned if it fails.
  gh issue pin "$num" -R "$REPO" || echo "could not pin issue #$num; pin it by hand"
  echo "created board issue #$num"
  exit 0
fi

current=$(gh api "repos/$REPO/issues/$num" --jq .body)
if [ "$current" == "$(cat board/board.md)" ]; then
  echo "board issue #$num already up to date"
  exit 0
fi
jq -n --rawfile b board/board.md '{body: $b}' \
  | gh api -X PATCH "repos/$REPO/issues/$num" --input - --silent
echo "updated board issue #$num"

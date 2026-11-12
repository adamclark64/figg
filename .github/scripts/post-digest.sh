#!/usr/bin/env bash
# Posts digest/DIGEST.md as a comment on the single pinned "Daily issue digest"
# issue (creating and pinning it on first run), mirrors it to the step summary,
# and optionally to Slack.
#
# Env: REPO, GH_TOKEN, POST ("true"/"false"), SLACK_WEBHOOK_URL (optional).
set -euo pipefail
[ -s digest/DIGEST.md ] || { echo "no digest to post"; exit 0; }

# The digest is built from text anyone can file, so it is cut to a sane
# length and every "@" gets a zero-width space after it: the comment then
# reads the same and pings nobody. The same goes after the "#" of a reference
# to another repository (owner/name#12), which would otherwise leave a
# backlink on that repository's issue. Plain "#12" still links here.
head -c 20000 digest/DIGEST.md \
  | perl -CSD -pe 's/@/@\x{200B}/g; s{([\w.-]+/[\w.-]+)#(?=\d)}{$1#\x{200B}}g' > digest/DIGEST.safe.md
mv digest/DIGEST.safe.md digest/DIGEST.md

{
  echo "# Daily issue digest"; echo
  cat digest/DIGEST.md
} >> "$GITHUB_STEP_SUMMARY"

if [ "${POST:-true}" != "true" ]; then echo "dry run, not posting"; exit 0; fi

title="Daily issue digest"
num=$(gh issue list -R "$REPO" --state open -L 1 --json number -S "label:digest in:title \"${title}\"" | jq -r '.[0].number // empty')
if [ -z "$num" ]; then
  body="Rolling digest of user reports filed through figg's in-app bug reporter. A new comment lands here every day. Reopen if closed; the workflow recreates it otherwise."
  num=$(gh issue create -R "$REPO" --title "$title" --label digest --body "$body" | grep -oE '[0-9]+$')
  gh issue pin "$num" -R "$REPO" || true
fi

date_utc=$(date -u +%F)
{
  echo "## ${date_utc}"; echo
  cat digest/DIGEST.md
} > digest/comment.md
gh issue comment "$num" -R "$REPO" --body-file digest/comment.md
echo "posted to issue #${num}"

if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  # Slack reads <...> as a link, a mention or a channel-wide ping.
  text=$(head -c 3500 digest/DIGEST.md | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
  link="https://github.com/${REPO}/issues/${num}"
  # printf turns the \n into real line breaks; inside the quotes alone they
  # would reach Slack as a backslash and an n.
  message=$(printf '*Daily issue digest* (%s)\n%s\n<%s|Full digest>' "$date_utc" "$text" "$link")
  payload=$(jq -n --arg t "$message" '{text: $t}')
  curl -sS -X POST -H 'content-type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL" > /dev/null || echo "slack post failed"
fi

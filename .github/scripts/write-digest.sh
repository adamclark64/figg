#!/usr/bin/env bash
# Asks Claude for the digest text and writes it to digest/DIGEST.md.
#
# The reports go to the model as text and text comes back. The model has no
# tools, reads no files and never sees a secret, so the worst an issue can do
# by addressing the model is skew the summary. Any failure here leaves no
# digest, and the fallback step then writes the plain list.
#
# Env: REPO, HOURS, DIGEST_MODEL, ANTHROPIC_API_KEY.
set -euo pipefail

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ANTHROPIC_API_KEY is not set; the fallback digest will be used"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sed -e "s#{{REPO}}#${REPO}#g" -e "s#{{HOURS}}#${HOURS}#g" \
  .github/issue-digest/digest-prompt.md > "$work/prompt.md"

# The backlog can be hundreds of issues, so its bodies are cut shorter than
# the new reports' (already capped at 1500 characters by collect-issues.sh).
jq 'map(.body |= .[0:300])' digest/open.json > "$work/open.json"

jq -n \
  --arg model "$DIGEST_MODEL" \
  --rawfile system "$work/prompt.md" \
  --rawfile stats digest/stats.json \
  --rawfile new digest/new.json \
  --rawfile closed digest/closed.json \
  --rawfile open "$work/open.json" \
  '{
    model: $model,
    max_tokens: 16000,
    output_config: {effort: "low"},
    system: $system,
    messages: [{
      role: "user",
      content: ("stats.json\n" + $stats + "\n\nnew.json\n" + $new
        + "\n\nclosed.json\n" + $closed + "\n\nopen.json\n" + $open)
    }]
  }' > "$work/request.json"

# The key goes in a header file, not on the command line, where any process
# on the machine could read it.
printf 'x-api-key: %s\n' "$ANTHROPIC_API_KEY" > "$work/headers"
if ! curl -sS --fail-with-body --max-time 300 https://api.anthropic.com/v1/messages \
  -H @"$work/headers" \
  -H "anthropic-version: 2026-10-21" \
  -H "content-type: application/json" \
  --data-binary @"$work/request.json" > "$work/response.json"; then
  # Say why before the fallback takes over; the reply is deleted on exit.
  echo "the API call failed: $(jq -r '.error.type // "no error type"' "$work/response.json" 2>/dev/null || echo "no reply")"
  exit 1
fi

stop=$(jq -r '.stop_reason // "none"' "$work/response.json")
if [ "$stop" != "end_turn" ]; then
  echo "the model stopped with '${stop}'; the fallback digest will be used"
  exit 1
fi

# A reply can hold thinking blocks beside the text; keep the text.
jq -r '[.content[] | select(.type == "text") | .text] | join("\n")' "$work/response.json" > "$work/digest.md"
[ -s "$work/digest.md" ] || { echo "the model returned no text"; exit 1; }
mv "$work/digest.md" digest/DIGEST.md
echo "digest written ($(wc -c < digest/DIGEST.md) bytes)"

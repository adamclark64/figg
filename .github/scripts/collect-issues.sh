#!/usr/bin/env bash
# Gathers user reports into digest/*.json for the model step, and (with
# --fallback-digest) writes a plain digest/DIGEST.md when the model produced none.
#
# Env: REPO, HOURS, GH_TOKEN. Writes step outputs: total, new, open, closed.
set -euo pipefail
mkdir -p digest

if [ "${1:-}" = "--fallback-digest" ]; then
  if [ -s digest/DIGEST.md ]; then echo "model digest present"; exit 0; fi
  {
    echo "## Daily issue digest (auto, no model summary)"
    echo
    echo "_Look-back: last ${HOURS}h. The model step did not produce a summary; this is the raw list._"
    echo
    echo "### New reports"
    jq -r 'if length == 0 then "- none" else .[] | "- #\(.number) [\(.labels | map(.name) | join(", "))] \(.title) (\(.url))" end' digest/new.json
    echo
    echo "### Closed in window"
    jq -r 'if length == 0 then "- none" else .[] | "- #\(.number) \(.title)" end' digest/closed.json
    echo
    echo "### Open backlog"
    jq -r '"- \(length) open user reports"' digest/open.json
  } > digest/DIGEST.md
  exit 0
fi

since=$(date -u -d "-${HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)
fields=number,title,body,labels,createdAt,updatedAt,closedAt,state,url,author,assignees

# Strip any embedded <details> block and cap bodies to keep the model input
# bounded.
trim='map(.body = ((.body // "") | gsub("<details>.*</details>"; "" ; "s") | .[0:1500]))'

gh issue list -R "$REPO" --state all -L 200 --json "$fields" \
  -S "label:user-report created:>=${since} sort:created-asc" | jq "$trim" > digest/new.json
gh issue list -R "$REPO" --state open -L 500 --json "$fields" \
  -S "label:user-report sort:created-asc" | jq "$trim" > digest/open.json
gh issue list -R "$REPO" --state closed -L 200 --json "$fields" \
  -S "label:user-report closed:>=${since} sort:updated-desc" | jq "$trim" > digest/closed.json

new=$(jq length digest/new.json)
open=$(jq length digest/open.json)
closed=$(jq length digest/closed.json)
total=$((new + open + closed))

jq -n --arg since "$since" --arg hours "$HOURS" --argjson new "$new" --argjson open "$open" --argjson closed "$closed" \
  --argjson byType "$(jq '[.[] | .labels[].name] | map(select(. == "bug" or . == "enhancement" or . == "question")) | group_by(.) | map({key: .[0], value: length}) | from_entries' digest/open.json)" \
  '{since: $since, hours: $hours, new: $new, open: $open, closed: $closed, openByType: $byType}' > digest/stats.json

echo "new=${new} open=${open} closed=${closed} total=${total}"
{
  echo "total=${total}"; echo "new=${new}"; echo "open=${open}"; echo "closed=${closed}"
} >> "$GITHUB_OUTPUT"

if [ "$total" = "0" ]; then
  printf '## Daily issue digest\n\n_Quiet day: no user reports in the last %sh and no open backlog._\n' "$HOURS" > digest/DIGEST.md
fi

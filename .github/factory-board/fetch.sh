#!/usr/bin/env bash
# Writes every open pull request and the 100 most recently updated closed
# ones to board/pulls.json, as one JSON list. render.py keeps the factory
# ones. Plain REST: GraphQL is not reachable from every agent environment.
#
# Env: REPO (owner/name), GH_TOKEN.
set -euo pipefail
: "${REPO:?set REPO to owner/name}"
mkdir -p board
gh api "repos/$REPO/pulls?state=open&per_page=100" --paginate --jq '.[]' > board/open.ndjson
gh api "repos/$REPO/pulls?state=closed&sort=updated&direction=desc&per_page=100" --jq '.[]' > board/closed.ndjson
jq -s '.' board/open.ndjson board/closed.ndjson > board/pulls.json
echo "fetched $(jq length board/pulls.json) pull requests"

#!/usr/bin/env bash
# Creates the factory:* labels (issue 89) that are missing. Never edits or
# deletes a label that already exists, so colours or descriptions changed by
# hand stay as they are.
#
# Env: REPO (owner/name), GH_TOKEN.
set -euo pipefail
: "${REPO:?set REPO to owner/name}"

existing=$(gh api "repos/$REPO/labels" --paginate --jq '.[].name')

mk() {
  if grep -qxF "$1" <<<"$existing"; then
    echo "label $1 exists"
  else
    gh api -X POST "repos/$REPO/labels" -f name="$1" -f color="$2" -f description="$3" --silent
    echo "created label $1"
  fi
}

mk factory:spec        C5DEF5 "Spec PR open; the design stage runs"
mk factory:planned     FBCA04 "Plan ready; approval 1 is merging the Spec PR"
mk factory:building    1D76DB "Integration branch in progress"
mk factory:ci-failed   D73A4A "CI failed on this factory PR; set and cleared by CI"
mk factory:needs-human B60205 "Three fixes failed or the factory is blocked"
mk factory:final       0E8A16 "Final PR to main open; approval 2 is merging it"

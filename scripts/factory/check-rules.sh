#!/usr/bin/env bash
# Fails when a change breaks an AGENTS.md hard rule that a grep can see.
# Most rules need judgement and stay with review; these are the ones a
# pattern catches reliably:
#
#   - no sampling params (temperature, top_p, top_k) in a model request
#   - settings go in FiggConfig, never UserDefaults
#   - no em-dashes anywhere in the repository
#
# Only lines the range adds are checked for the first two, so older code
# is not flagged. A line that really needs one can carry the marker
# "factory-allow: <rule>" (sampling or userdefaults) with a reason, which
# review then sees.
#
# Usage: scripts/factory/check-rules.sh BASE HEAD
set -euo pipefail

base=${1:?usage: check-rules.sh BASE HEAD}
head=${2:?usage: check-rules.sh BASE HEAD}
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=lib.sh
source scripts/factory/lib.sh

bad=0
flag() { # path line message
  echo "::error file=$1,line=$2::$3"
  bad=1
}

# Rule 3: a quoted parameter name is what ends up in a request body.
sampling='"(temperature|top_p|top_k|topP|topK)"'
while IFS=$'\t' read -r path line text; do
  [[ "$text" == *"factory-allow: sampling"* ]] && continue
  if [[ "$text" =~ $sampling ]]; then
    flag "$path" "$line" "Sampling parameter in a model request. Current Claude models reject temperature, top_p and top_k (AGENTS.md rule 3)."
  fi
done < <(added_lines "$base" "$head" 'app/Sources/**/*.swift')

# Rule 6: comment lines may name UserDefaults; code may not.
while IFS=$'\t' read -r path line text; do
  [[ "$text" == *"factory-allow: userdefaults"* ]] && continue
  [[ "$text" =~ ^[[:space:]]*(//|\*|/\*) ]] && continue
  if [[ "$text" == *UserDefaults* ]]; then
    flag "$path" "$line" "UserDefaults in app code. Settings go in FiggConfig (config.yaml) with a default, a lenient decode and a round-trip test (AGENTS.md rule 6)."
  fi
done < <(added_lines "$base" "$head" 'app/Sources/**/*.swift')

# Style rule: the whole tree is clean, so check all of it, not just the diff.
dash=$(printf '\342\200\224') # U+2014, spelled in octal so this file stays clean
while IFS=: read -r path line _; do
  flag "$path" "$line" "Em-dash. Use a comma, a colon, parentheses or two sentences (AGENTS.md conventions)."
done < <(git grep -nI "$dash" "$head" -- . | sed "s|^$head:||")

if [[ "$bad" -ne 0 ]]; then
  echo "Hard-rule check failed; see the errors above." >&2
  exit 1
fi
echo "check-rules: no hard-rule violations found."

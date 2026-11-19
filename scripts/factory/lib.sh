# Shared helpers for the factory checks. Source it; do not run it.

# Prints "path<TAB>line<TAB>text" for every line a range adds, so a check
# looks only at what the change brings in, not at code that predates it.
# Usage: added_lines BASE HEAD [pathspec...]
added_lines() {
  local base=$1 head=$2
  shift 2
  git diff --no-color --no-ext-diff -U0 "$base...$head" -- "$@" | awk '
    /^\+\+\+ / { file = substr($0, 7); next }
    /^@@ / {
      split($3, a, ",")
      line = substr(a[1], 2) + 0
      next
    }
    /^\+/ { print file "\t" line "\t" substr($0, 2); line++ }
  '
}

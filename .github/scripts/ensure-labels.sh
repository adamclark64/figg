#!/usr/bin/env bash
# Idempotently create the labels the bug reporter and digest rely on.
set -euo pipefail
mk() { gh label create "$1" --color "$2" --description "$3" -R "$REPO" 2>/dev/null || true; }
mk user-report 0E8A16 "Filed from the in-app bug reporter"
mk macos       1D76DB "Reported from the macOS app"
mk digest      5319E7 "Rolling daily issue digest"
# bug / enhancement / question are GitHub defaults; recreate in case they were deleted.
mk bug         D73A4A "Something isn't working"
mk enhancement A2EEEF "New feature or request"
mk question    D876E3 "Further information is requested"

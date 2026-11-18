#!/usr/bin/env bash
# Joins a meeting's 10 s audio chunks into one file you can play.
#
#   scripts/stitch-audio.sh <meeting folder> [output file]
#   scripts/stitch-audio.sh ~/Library/Application\ Support/figg/meetings/<id> ~/Desktop/meeting.m4a
#
# Chunks only survive Stop when Keep audio is on (recording.keep_audio).
# Each chunk's file name holds its start time in ms from the start of the
# recording, so every chunk is placed at that time rather than joined end to
# end: the mic and system streams start at different moments and the last
# chunks are short, so a plain join would drift the two apart. Mic and
# system audio are then mixed into one track. Needs ffmpeg
# (`brew install ffmpeg`). Runs locally; nothing leaves the Mac.
set -euo pipefail

if [[ $# -lt 1 || ! -d "$1" ]]; then
  echo "usage: $0 <meeting folder> [output file]" >&2
  exit 1
fi
command -v ffmpeg >/dev/null || { echo "ffmpeg not found: brew install ffmpeg" >&2; exit 1; }

meeting="${1%/}"
out="${2:-$HOME/Desktop/figg-$(basename "$meeting").m4a}"

shopt -s nullglob
chunks=("$meeting"/done/*.caf "$meeting"/pending/*.caf)
if [[ ${#chunks[@]} -eq 0 ]]; then
  echo "no .caf chunks in $meeting/done or $meeting/pending (was Keep audio on?)" >&2
  exit 1
fi

inputs=()
filter=""
labels=""
i=0
for f in "${chunks[@]}"; do
  name="$(basename "$f" .caf)"   # e.g. system_0000021999
  ms=$((10#${name##*_}))         # base 10, so leading zeros are not octal
  inputs+=(-i "$f")
  filter+="[$i:a]adelay=${ms}:all=1[a$i];"
  labels+="[a$i]"
  i=$((i + 1))
done
filter+="${labels}amix=inputs=$i:normalize=0:duration=longest[out]"

ffmpeg -y -loglevel error "${inputs[@]}" -filter_complex "$filter" -map "[out]" -c:a aac -b:a 96k "$out"
echo "wrote $out ($i chunks)"

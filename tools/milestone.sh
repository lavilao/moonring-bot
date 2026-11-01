#!/usr/bin/env bash
# Snapshot the isolated playable save as a regression baseline.
# Usage: tools/milestone.sh NAME
# Copies work/xdg/love/moonring-bot/data/save to
# work/save-backup/save-NAME (refuses to overwrite).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:-}"
SRC="$ROOT/work/xdg/love/moonring-bot/data/save"
DST="$ROOT/work/save-backup/save-$NAME"

if [ -z "$NAME" ]; then
  echo "Usage: tools/milestone.sh NAME" >&2
  exit 2
fi
if [ ! -f "$SRC/checkpoint.txt" ]; then
  echo "No playable save at $SRC" >&2
  exit 1
fi
if [ -e "$DST" ]; then
  echo "Already exists: $DST (pick another name)" >&2
  exit 1
fi

mkdir -p "$ROOT/work/save-backup"
cp -a "$SRC" "$DST"
cat "$DST/checkpoint.txt" 2>/dev/null || true
echo "Saved milestone: $DST"

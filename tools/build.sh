#!/usr/bin/env bash
# Build an isolated, modded copy of Moonring under work/moonring-bot.
# Usage: tools/build.sh [path-to-Moonring.AppImage]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPIMAGE="${1:-${MOONRING_APPIMAGE:-}}"
APP_DIR="$ROOT/work/appimage"
GAME_DIR="$ROOT/work/moonring-bot"

if [ ! -x "$APP_DIR/squashfs-root/bin/Moonring" ]; then
  if [ -z "$APPIMAGE" ]; then
    echo "Usage: tools/build.sh /path/to/Moonring.AppImage (or set MOONRING_APPIMAGE)" >&2
    exit 1
  fi
  if [ ! -f "$APPIMAGE" ]; then
    echo "Moonring AppImage not found: $APPIMAGE" >&2
    exit 1
  fi
  echo "Extracting $APPIMAGE ..."
  mkdir -p "$APP_DIR"
  ( cd "$APP_DIR" && "$APPIMAGE" --appimage-extract >/dev/null )
fi

echo "Unpacking game Lua/assets ..."
mkdir -p "$GAME_DIR"
find "$GAME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
python3 - "$APP_DIR/squashfs-root/bin/Moonring" "$GAME_DIR" <<'PY'
import sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
zipfile.ZipFile(src).extractall(dst)
PY

echo "Injecting bot mod ..."
rm -rf "$GAME_DIR/zzbot"
cp -r "$ROOT/mod/zzbot" "$GAME_DIR/zzbot"
printf '\n-- moonring-bot injection\nrequire("zzbot")\n' >> "$GAME_DIR/main.lua"

echo "Built: $GAME_DIR"

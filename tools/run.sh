#!/usr/bin/env bash
# Run the modded game with our own LÖVE 11.5 build.
# Usage: tools/run.sh [extra love args]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOVE_DIR="$ROOT/vendor/squashfs-root"
GAME_DIR="$ROOT/work/moonring-bot"

if [ ! -x "$LOVE_DIR/bin/love" ]; then
  echo "LÖVE 11.5 not found under vendor/; run tools/fetch-love.sh" >&2
  exit 1
fi
if [ ! -f "$GAME_DIR/main.lua" ]; then
  echo "Game not built; run tools/build.sh" >&2
  exit 1
fi

export LD_LIBRARY_PATH="$LOVE_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Never touch the user's real Moonring save: LÖVE writes to
# $XDG_DATA_HOME/love/<game folder name>.
export XDG_DATA_HOME="${XDG_DATA_HOME:-$ROOT/work/xdg}"
mkdir -p "$XDG_DATA_HOME"

export ZZBOT_LOG="${ZZBOT_LOG:-$ROOT/logs/zzbot.log}"
export ZZBOT_SPEED="${ZZBOT_SPEED:-4}"

if [ "${ZZBOT_HEADLESS:-0}" = "1" ]; then
  export SDL_VIDEODRIVER=offscreen
  export SDL_AUDIODRIVER=dummy
fi

exec "$LOVE_DIR/bin/love" "$GAME_DIR" "$@"

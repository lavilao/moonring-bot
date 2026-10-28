#!/usr/bin/env bash
# Fetch and unpack the LÖVE 11.5 AppImage used to run the modded game.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/vendor"

if [ ! -x squashfs-root/bin/love ]; then
  if [ ! -f love.AppImage ]; then
    curl -L --fail --max-time 180 \
      -o love.AppImage \
      https://github.com/love2d/love/releases/download/11.5/love-11.5-x86_64.AppImage
    chmod +x love.AppImage
  fi
  ./love.AppImage --appimage-extract >/dev/null
fi

echo "LÖVE ready: $ROOT/vendor/squashfs-root/bin/love"

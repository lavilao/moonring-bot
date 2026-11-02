#!/usr/bin/env bash
# Run the pure-Lua unit tests without the game (PLAN.md §2.5).
#
#   tools/unit.sh              # every tools/test_*.lua
#   tools/unit.sh test_model   # just the named files
#
# Prefers luajit (the runtime the game embeds) and falls back to any lua.
# These tests cover the modules that are extracted from init.lua (PLAN §0.2):
# confirm, ending_gate, metrics, model.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LUA=""
for c in luajit lua5.1 lua-5.1 lua; do
  if command -v "$c" >/dev/null 2>&1; then LUA="$c"; break; fi
done
if [ -z "$LUA" ]; then
  echo "unit: no lua interpreter found (need luajit or lua)" >&2
  exit 1
fi

status=0
tests=()
if [ "$#" -gt 0 ]; then
  for name in "$@"; do tests+=("tools/${name}.lua"); done
else
  for t in tools/test_*.lua; do tests+=("$t"); done
fi

for t in "${tests[@]}"; do
  if [ ! -f "$t" ]; then
    echo "unit: no such test: $t" >&2
    status=1
    continue
  fi
  echo "== $t =="
  "$LUA" "$t" || status=1
done

if [ "$status" -eq 0 ]; then
  echo "all unit tests passed"
else
  echo "unit: FAILURES" >&2
fi
exit "$status"

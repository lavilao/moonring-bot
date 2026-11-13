#!/usr/bin/env bash
# Run the bot headless from a saved game and assert on its event log.
#
# Usage:
#   tools/regress.sh                 # run every scenario
#   tools/regress.sh smoke yarrow    # run the named scenarios
#   tools/regress.sh --list          # list scenarios
#
# A scenario is tools/scenarios/<name>.conf, a shell snippet setting:
#   SAVE     path to a save backup (copied to a throwaway XDG dir)
#   TIMEOUT  in-game seconds before the bot gives up (default 180)
#   SPEED    simulation multiplier (default 8)
#   START_TOWN  index in TOWN_ORDER the campaign starts at (default 1)
#   MAPDUMP  optional path for a map dump written on every level entry
#   PEACEFUL 1 = send hostiles away on entry (test-only; loot/descent tests)
#   WALL     wall-clock seconds before the process is killed (default
#            TIMEOUT + 90); passed to the bot as its own hard deadline
#   ASSERT   bash array of check_log.lua specs
#
# A/B knobs also come from the environment, so the same save can be run twice:
#   MODEL=1   tools/regress.sh dungeon   # Monte Carlo chooser on
#   LEARN=1   tools/regress.sh dungeon   # learned threat ledger on
#   GEAR=0    tools/regress.sh dungeon   # equipment layer off
# The learned ledger lives inside the scenario's own XDG dir, so one run never
# teaches the next one.
#
# The playable save under work/xdg is never touched: each scenario gets its
# own work/xdg-regress/<name> data dir, rebuilt from SAVE on every run.
#
# Exit codes from the bot: 0 success, 1 death, 3 timeout (in-game or wall
# clock), 4 blocked (a finished level with no exit at all). Assertions decide
# the scenario either way.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCEN_DIR="$ROOT/tools/scenarios"
REG_ROOT="$ROOT/work/xdg-regress"
LOG_DIR="$ROOT/logs"
CHECK="$ROOT/tools/check_log.lua"

if [ ! -f "$ROOT/work/moonring-bot/main.lua" ]; then
  echo "Game not built; run tools/build.sh first" >&2
  exit 1
fi

names=()
for conf in "$SCEN_DIR"/*.conf; do
  [ -e "$conf" ] || continue
  name="$(basename "$conf" .conf)"
  if [ "$#" -gt 0 ] && [ "$1" = "--list" ]; then
    echo "$name"
  else
    names+=("$name")
  fi
done

if [ "$#" -gt 0 ] && [ "$1" = "--list" ]; then
  exit 0
fi

if [ "$#" -gt 0 ]; then
  names=("$@")
fi

if [ "${#names[@]}" -eq 0 ]; then
  echo "No scenarios in $SCEN_DIR" >&2
  exit 2
fi

mkdir -p "$LOG_DIR"
failures=0
summary=()

for name in "${names[@]}"; do
  conf="$SCEN_DIR/$name.conf"
  if [ ! -f "$conf" ]; then
    echo "regress: no such scenario: $name" >&2
    failures=$((failures + 1))
    summary+=("ERROR $name")
    continue
  fi

  # shellcheck disable=SC1090
  (
    SAVE=""
    TIMEOUT=180
    SPEED=8
    START_TOWN=""
    MAPDUMP=""
    PEACEFUL=""
    WALL=""
    GEAR="${GEAR:-1}"
    MODEL="${MODEL:-0}"
    LEARN="${LEARN:-0}"
    ASSERT=()
    . "$conf"

    if [ -z "$SAVE" ] || [ ! -d "$SAVE" ]; then
      echo "regress[$name]: SAVE missing or not a directory: ${SAVE:-<unset>}" >&2
      exit 2
    fi
    WALL="${WALL:-$((TIMEOUT + 90))}"

    XDG="$REG_ROOT/$name"
    DATA="$XDG/love/moonring-bot/data"
    LOG="$LOG_DIR/regress-$name.log"

    rm -rf "$XDG"
    mkdir -p "$DATA/save"
    cp -a "$SAVE"/. "$DATA/save/"
    : > "$LOG"

    echo "regress[$name]: ${SAVE#$ROOT/} -> $DATA/save (timeout ${TIMEOUT}s, wall ${WALL}s)"
    set +e
    timeout --signal=TERM --kill-after=20s "$WALL" \
      env XDG_DATA_HOME="$XDG" \
          ZZBOT_HEADLESS=1 \
          ZZBOT_AUTOSTART=1 \
          ZZBOT_START_ON=1 \
          ZZBOT_QUIT=1 \
          ZZBOT_TIMEOUT="$TIMEOUT" \
          ZZBOT_WALL="$WALL" \
          ZZBOT_SPEED="$SPEED" \
          ZZBOT_START_TOWN="$START_TOWN" \
          ZZBOT_MAPDUMP="${MAPDUMP:-}" \
          ZZBOT_PEACEFUL="${PEACEFUL:-}" \
          ZZBOT_GEAR="${GEAR:-}" \
          ZZBOT_MODEL="${MODEL:-}" \
          ZZBOT_LEARN="${LEARN:-}" \
          ZZBOT_KNOWLEDGE="$XDG/knowledge.lua" \
          ZZBOT_LOG="$LOG" \
      "$ROOT/tools/run.sh" >/dev/null 2>&1
    rc=$?
    set -e

    case "$rc" in
      0)   echo "regress[$name]: exited cleanly" ;;
      1)   echo "regress[$name]: exited on player death (rc=1)" ;;
      3)   echo "regress[$name]: exited on timeout (rc=3)" ;;
      4)   echo "regress[$name]: exited blocked with no way out (rc=4)" ;;
      124) echo "regress[$name]: killed at wall-clock limit (rc=124)" ;;
      *)   echo "regress[$name]: exit code $rc" ;;
    esac

    # A wall-clock kill still leaves a usable log; assertions decide.
    if [ "${#ASSERT[@]}" -eq 0 ]; then
      echo "regress[$name]: no ASSERT specs"
      exit 0
    fi
    luajit "$CHECK" "$LOG" "${ASSERT[@]}"
  ) || {
    failures=$((failures + 1))
    summary+=("FAIL $name")
    echo "regress[$name]: FAILED"
    continue
  }
  summary+=("PASS $name")
  echo "regress[$name]: PASS"
done

echo
echo "== regression summary =="
printf '  %s\n' "${summary[@]}"
if [ "$failures" -gt 0 ]; then
  echo "$failures scenario(s) failed"
  exit 1
fi
echo "all scenarios passed"

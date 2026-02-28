#!/usr/bin/env bash
set -euo pipefail

DATE=$(date +%Y%m%d)
CREW_NAME="nightly-${DATE}"
RIG="gastown"
WIKI_REPO="$HOME/gt/gastown-wiki"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[nightly] $DATE — starting"

# 1. Ensure dolt is running (town may be down)
if ! gt dolt status &>/dev/null; then
  echo "[nightly] dolt not running, starting..."
  gt dolt start
  sleep 2
else
  echo "[nightly] dolt already running"
fi

# 2. Create a fresh crew in the gastown rig
echo "[nightly] creating crew ${RIG}/${CREW_NAME}"
gt crew add "$CREW_NAME" --rig "$RIG"

# 3. Nudge the crew with the mission brief
echo "[nightly] nudging crew with mission"
gt nudge "${RIG}/${CREW_NAME}" --stdin --mode immediate < "${SCRIPTS_DIR}/nightly-mission.md"

echo "[nightly] crew ${RIG}/${CREW_NAME} has been briefed. monitor via: gt crew status ${CREW_NAME} --rig ${RIG}"

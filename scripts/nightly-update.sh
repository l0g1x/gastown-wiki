#!/usr/bin/env bash
set -euo pipefail

DATE=$(date +%Y%m%d)
CREW_NAME="nightly_${DATE}"
RIG="gastown"
TOWN_ROOT="$HOME/gt"
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

# 2. Create the crew workspace (must run from town root)
echo "[nightly] creating crew workspace ${RIG}/${CREW_NAME}"
cd "$TOWN_ROOT"
gt crew add "$CREW_NAME" --rig "$RIG"

# 3. Start the crew session (creates tmux session)
echo "[nightly] starting crew session"
gt crew start "$RIG" "$CREW_NAME"

# 4. Nudge the crew with the mission brief
echo "[nightly] nudging crew with mission"
gt nudge "${RIG}/${CREW_NAME}" --stdin --mode queue < "${SCRIPTS_DIR}/nightly-mission.md"

echo "[nightly] crew ${RIG}/${CREW_NAME} has been briefed"

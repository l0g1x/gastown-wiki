#!/usr/bin/env bash
set -euo pipefail

DATE=$(date +%Y%m%d)
CREW_NAME="nightly_${DATE}"
RIG="gastown"
TOWN_ROOT="$HOME/gt"
WIKI_REPO="$HOME/gt/gastown-wiki"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
MAX_WAIT=900  # 15 minutes
POLL_INTERVAL=30

echo "[nightly] $DATE — starting"

# 1. Ensure dolt is running (town may be down)
if ! gt dolt status &>/dev/null; then
  echo "[nightly] dolt not running, starting..."
  gt dolt start
  sleep 2
else
  echo "[nightly] dolt already running"
fi

# 2. Record gastown-wiki HEAD before the run
WIKI_HEAD_BEFORE=$(cd "$WIKI_REPO" && git rev-parse HEAD)
echo "[nightly] wiki HEAD before: $WIKI_HEAD_BEFORE"

# 3. Create the crew workspace (must run from town root)
echo "[nightly] creating crew workspace ${RIG}/${CREW_NAME}"
cd "$TOWN_ROOT"
gt crew add "$CREW_NAME" --rig "$RIG"

# 4. Start the crew session (creates tmux session)
echo "[nightly] starting crew session"
gt crew start "$RIG" "$CREW_NAME"

# 5. Nudge the crew with the mission brief
echo "[nightly] nudging crew with mission"
gt nudge "${RIG}/${CREW_NAME}" --stdin --mode queue < "${SCRIPTS_DIR}/nightly-mission.md"
echo "[nightly] crew ${RIG}/${CREW_NAME} has been briefed"

# 6. Wait for the crew to push a new commit to gastown-wiki
echo "[nightly] waiting for wiki commit (max ${MAX_WAIT}s)..."
elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))

  # Pull latest and check if HEAD moved
  WIKI_HEAD_NOW=$(cd "$WIKI_REPO" && git pull --quiet 2>/dev/null && git rev-parse HEAD)
  if [ "$WIKI_HEAD_NOW" != "$WIKI_HEAD_BEFORE" ]; then
    echo "[nightly] wiki updated: $WIKI_HEAD_BEFORE → $WIKI_HEAD_NOW (${elapsed}s)"
    break
  fi
  echo "[nightly] still waiting... (${elapsed}s)"
done

if [ "$WIKI_HEAD_NOW" = "$WIKI_HEAD_BEFORE" ]; then
  echo "[nightly] WARNING: timed out after ${MAX_WAIT}s — crew may still be running"
  echo "[nightly] skipping cleanup, manual intervention needed"
  exit 1
fi

# 7. Cleanup: stop and purge the nightly crew
echo "[nightly] cleaning up crew ${RIG}/${CREW_NAME}"
gt crew stop "$CREW_NAME" --rig "$RIG" 2>/dev/null || true
gt crew remove "$CREW_NAME" --rig "$RIG" --purge --force

# 8. Update the gastown-wiki submodule in butane
BUTANE_REPO="$HOME/butane"
echo "[nightly] updating butane submodule"
cd "$BUTANE_REPO"
git submodule update --remote docs/gastown-wiki
git add docs/gastown-wiki
git diff --cached --quiet || git commit -m "docs: update gastown-wiki submodule ($DATE)" && git push

echo "[nightly] done"

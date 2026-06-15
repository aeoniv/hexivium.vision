#!/usr/bin/env bash
# ============================================================================
# Qi Pipeline Director — Idle Watchdog
# ============================================================================
# Runs every IDLE_CHECK_INTERVAL (via systemd timer). Shuts the VM down once it
# has been idle for IDLE_SHUTDOWN_MINUTES, closing the gap where a UI-launched
# run (SKIP_SHUTDOWN=1) leaves the GPU billing indefinitely.
#
# "Idle" means ALL of:
#   • No run_pipeline.sh process is active
#   • GPU utilization is below GPU_IDLE_THRESHOLD_PCT
#   • No keep-alive sentinel file present (for debugging sessions)
#
# Opt out of a shutdown during a debug session:
#   touch /opt/qi-pipeline/.keep_alive
# Remove it to let the watchdog resume:
#   rm /opt/qi-pipeline/.keep_alive
# ============================================================================

set -uo pipefail

PIPELINE_ROOT="${PIPELINE_ROOT:-/opt/qi-pipeline}"
KEEP_ALIVE="${PIPELINE_ROOT}/.keep_alive"
STATE_FILE="${PIPELINE_ROOT}/tmp/.idle_counter"
LOG_FILE="/var/log/qi-idle-watchdog.log"

# ── Tunables (override via env in the systemd unit) ─────────────────────────
IDLE_CHECK_INTERVAL_MIN="${IDLE_CHECK_INTERVAL_MIN:-5}"   # how often the timer fires
IDLE_SHUTDOWN_MINUTES="${IDLE_SHUTDOWN_MINUTES:-30}"      # idle duration before shutdown
GPU_IDLE_THRESHOLD_PCT="${GPU_IDLE_THRESHOLD_PCT:-5}"     # GPU util below this = idle

# Number of consecutive idle checks required to trigger shutdown
REQUIRED_IDLE_CHECKS=$(( (IDLE_SHUTDOWN_MINUTES + IDLE_CHECK_INTERVAL_MIN - 1) / IDLE_CHECK_INTERVAL_MIN ))

mkdir -p "$(dirname "${STATE_FILE}")"

log() { echo "[$(date -Iseconds)] $*" | tee -a "${LOG_FILE}"; }

# ── 1. Debug opt-out ────────────────────────────────────────────────────────
if [ -f "${KEEP_ALIVE}" ]; then
    log "keep-alive sentinel present — skipping idle check."
    echo 0 > "${STATE_FILE}"
    exit 0
fi

# ── 2. Active pipeline? ─────────────────────────────────────────────────────
if pgrep -f "run_pipeline.sh" >/dev/null 2>&1; then
    log "pipeline running — resetting idle counter."
    echo 0 > "${STATE_FILE}"
    exit 0
fi

# ── 3. GPU busy? ────────────────────────────────────────────────────────────
GPU_UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
GPU_UTIL="${GPU_UTIL:-0}"
if [ "${GPU_UTIL}" -ge "${GPU_IDLE_THRESHOLD_PCT}" ]; then
    log "GPU util ${GPU_UTIL}% >= ${GPU_IDLE_THRESHOLD_PCT}% — resetting idle counter."
    echo 0 > "${STATE_FILE}"
    exit 0
fi

# ── 4. Idle — increment counter ─────────────────────────────────────────────
COUNT=$(cat "${STATE_FILE}" 2>/dev/null || echo 0)
[[ "${COUNT}" =~ ^[0-9]+$ ]] || COUNT=0
COUNT=$((COUNT + 1))
echo "${COUNT}" > "${STATE_FILE}"

IDLE_MIN=$((COUNT * IDLE_CHECK_INTERVAL_MIN))
log "idle check ${COUNT}/${REQUIRED_IDLE_CHECKS} (GPU ${GPU_UTIL}%, ~${IDLE_MIN} min idle)."

# ── 5. Threshold reached → shutdown ─────────────────────────────────────────
if [ "${COUNT}" -ge "${REQUIRED_IDLE_CHECKS}" ]; then
    log "idle for ~${IDLE_MIN} min (threshold ${IDLE_SHUTDOWN_MINUTES} min). Shutting down to stop billing."
    echo 0 > "${STATE_FILE}"
    shutdown -h now
fi

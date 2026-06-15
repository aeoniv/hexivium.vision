#!/usr/bin/env bash
# ============================================================================
# Qi Pipeline Director — Failure Cleanup & Emergency Shutdown
# ============================================================================
# Called by run_pipeline.sh's ERR trap. Ensures:
#   1. Error logs are uploaded to GCS for post-mortem
#   2. Partial outputs are preserved
#   3. VM is shut down regardless to prevent billing leaks
# ============================================================================

set -uo pipefail  # No -e here — we want to continue cleanup even on errors

export PIPELINE_ROOT="${PIPELINE_ROOT:-/opt/qi-pipeline}"
export GCS_BUCKET="${GCS_BUCKET:-gs://hexivium-vision-pipeline}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CLEANUP_LOG="${PIPELINE_ROOT}/cleanup_${TIMESTAMP}.log"

exec > >(tee -a "${CLEANUP_LOG}") 2>&1

echo "================================================================"
echo "[CLEANUP] Emergency cleanup initiated — $(date -Iseconds)"
echo "================================================================"

# ── 1. Collect system diagnostics ───────────────────────────────────────────
echo "[CLEANUP] Collecting diagnostics..."

# GPU state at time of failure
nvidia-smi > "${PIPELINE_ROOT}/gpu_state_${TIMESTAMP}.txt" 2>&1 || true

# Memory state
free -h > "${PIPELINE_ROOT}/mem_state_${TIMESTAMP}.txt" 2>&1 || true

# Disk state
df -h > "${PIPELINE_ROOT}/disk_state_${TIMESTAMP}.txt" 2>&1 || true

# Running processes
ps aux --sort=-%mem | head -30 > "${PIPELINE_ROOT}/proc_state_${TIMESTAMP}.txt" 2>&1 || true

# ── 2. Upload diagnostics & logs to GCS ─────────────────────────────────────
echo "[CLEANUP] Uploading diagnostics to GCS..."

DIAG_DIR="${GCS_BUCKET}/logs/crash_${TIMESTAMP}"

gsutil -q cp "${PIPELINE_ROOT}/pipeline_run.log"         "${DIAG_DIR}/pipeline_run.log" 2>/dev/null || true
gsutil -q cp "${PIPELINE_ROOT}/gpu_state_${TIMESTAMP}.txt"  "${DIAG_DIR}/gpu_state.txt" 2>/dev/null || true
gsutil -q cp "${PIPELINE_ROOT}/mem_state_${TIMESTAMP}.txt"  "${DIAG_DIR}/mem_state.txt" 2>/dev/null || true
gsutil -q cp "${PIPELINE_ROOT}/disk_state_${TIMESTAMP}.txt" "${DIAG_DIR}/disk_state.txt" 2>/dev/null || true
gsutil -q cp "${PIPELINE_ROOT}/proc_state_${TIMESTAMP}.txt" "${DIAG_DIR}/proc_state.txt" 2>/dev/null || true
gsutil -q cp /var/log/qi-pipeline-bootstrap.log             "${DIAG_DIR}/bootstrap.log" 2>/dev/null || true

# ── 3. Upload partial outputs ───────────────────────────────────────────────
echo "[CLEANUP] Uploading partial outputs..."

OUTPUT_DIR="${PIPELINE_ROOT}/output"
if [ -d "${OUTPUT_DIR}" ]; then
    # Upload any stage metadata
    gsutil -q -m cp "${OUTPUT_DIR}/stage"*".json" "${DIAG_DIR}/metadata/" 2>/dev/null || true

    # Upload any partial renders
    if [ -d "${OUTPUT_DIR}/renders" ]; then
        RENDER_COUNT=$(find "${OUTPUT_DIR}/renders" -name "*.png" 2>/dev/null | wc -l)
        echo "[CLEANUP] Found ${RENDER_COUNT} partial render frames"
        if [ "${RENDER_COUNT}" -gt 0 ]; then
            gsutil -q -m cp "${OUTPUT_DIR}/renders/"*.png "${DIAG_DIR}/partial_renders/" 2>/dev/null || true
        fi
    fi

    # Upload any partial controlnet maps
    if [ -d "${OUTPUT_DIR}/controlnet_maps" ]; then
        gsutil -q -m rsync -r "${OUTPUT_DIR}/controlnet_maps/" "${DIAG_DIR}/partial_maps/" 2>/dev/null || true
    fi

    # Upload any partial video output
    find "${OUTPUT_DIR}" -name "*.mp4" -o -name "*.webm" | while read -r video; do
        gsutil -q cp "${video}" "${DIAG_DIR}/partial_video/" 2>/dev/null || true
    done
fi

gsutil -q cp "${CLEANUP_LOG}" "${DIAG_DIR}/cleanup.log" 2>/dev/null || true

echo "[CLEANUP] Diagnostics uploaded to: ${DIAG_DIR}"

# ── 4. Kill lingering processes ─────────────────────────────────────────────
echo "[CLEANUP] Killing lingering GPU processes..."

# Kill any ComfyUI server
pkill -f "ComfyUI/main.py" 2>/dev/null || true

# Kill any Blender processes
pkill -f "blender --background" 2>/dev/null || true

# Kill any WHAM processes
pkill -f "stage1_wham" 2>/dev/null || true

# Wait for GPU memory to free
sleep 3

# ── 5. AUTO-SHUTDOWN ────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "[CLEANUP] All diagnostics saved. Initiating emergency shutdown."
echo "[CLEANUP] Review crash data at: ${DIAG_DIR}"
echo "================================================================"

if [ "${SKIP_SHUTDOWN:-0}" != "1" ]; then
    sudo shutdown -h now
else
    echo "[CLEANUP] SKIP_SHUTDOWN=1 — VM will remain running for debugging."
fi

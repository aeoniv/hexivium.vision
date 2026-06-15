#!/usr/bin/env bash
# ============================================================================
# Qi Pipeline Director — Master Orchestrator
# ============================================================================
# Chains all four processing stages and auto-shuts-down the VM upon completion
# to prevent idle billing leaks.
#
# Usage:
#   bash /opt/qi-pipeline/scripts/run_pipeline.sh
#
# Environment:
#   PIPELINE_ROOT  — base directory (default: /opt/qi-pipeline)
#   GCS_BUCKET     — GCS bucket for I/O (default: gs://hexivium-vision-pipeline)
#   SKIP_SHUTDOWN  — set to "1" to prevent auto-shutdown (for debugging)
# ============================================================================

set -euo pipefail

export PIPELINE_ROOT="${PIPELINE_ROOT:-/opt/qi-pipeline}"
export GCS_BUCKET="${GCS_BUCKET:-gs://hexivium-vision-pipeline}"
SKIP_SHUTDOWN="${SKIP_SHUTDOWN:-0}"

# ── Smooth-playback controls (Phase 1) ──────────────────────────────────────
# EXTRACT_FPS (computed in Stage 2) is the *keyframe* rate the diffusion model
# renders at. RIFE in Stage 4 interpolates those keyframes up to TARGET_FPS so
# the final video is smooth without using more GPU memory.
#   RIFLEX_FREQ_INDEX > 0  — only when extending beyond ~81 frames (Phase 2)
#   BLOCK_SWAP        > 0  — frees VRAM (slower) to fit more frames / higher res
export TARGET_FPS="${TARGET_FPS:-30}"
export RIFLEX_FREQ_INDEX="${RIFLEX_FREQ_INDEX:-0}"
export BLOCK_SWAP="${BLOCK_SWAP:-0}"

SCRIPTS_DIR="${PIPELINE_ROOT}/scripts"
INPUT_DIR="${PIPELINE_ROOT}/input"
OUTPUT_DIR="${PIPELINE_ROOT}/output"
LOG_FILE="${PIPELINE_ROOT}/pipeline_run.log"

CONDA_ROOT="/opt/miniconda3"
BLENDER_BIN="${PIPELINE_ROOT}/engines/blender/blender"
COMFYUI_DIR="${PIPELINE_ROOT}/engines/ComfyUI"

# ── Trap: cleanup on failure ────────────────────────────────────────────────
cleanup_on_failure() {
    local exit_code=$?
    echo "[PIPELINE] FATAL: Pipeline failed at $(date -Iseconds) with exit code ${exit_code}" | tee -a "${LOG_FILE}"

    # Upload error logs
    gsutil -q cp "${LOG_FILE}" "${GCS_BUCKET}/logs/pipeline_run_$(date +%Y%m%d_%H%M%S).log" 2>/dev/null || true
    gsutil -q cp /var/log/qi-pipeline-bootstrap.log "${GCS_BUCKET}/logs/bootstrap.log" 2>/dev/null || true

    # Upload any partial outputs
    if [ -d "${OUTPUT_DIR}" ]; then
        gsutil -q -m cp -r "${OUTPUT_DIR}/*" "${GCS_BUCKET}/output/partial/" 2>/dev/null || true
    fi

    # AUTO-SHUTDOWN even on failure to prevent billing leaks
    if [ "${SKIP_SHUTDOWN}" != "1" ]; then
        echo "[PIPELINE] Initiating emergency shutdown to prevent billing..."
        sudo shutdown -h now
    fi
}

trap cleanup_on_failure ERR

# ── Initialize ──────────────────────────────────────────────────────────────
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "================================================================"
echo "[PIPELINE] Qi Pipeline Director — Started $(date -Iseconds)"
echo "================================================================"

# Activate conda environment
source "${CONDA_ROOT}/etc/profile.d/conda.sh"
conda activate qi-pipeline

# Verify GPU
echo "[PIPELINE] GPU Status:"
nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader

# Check bootstrap completed
if [ ! -f "${PIPELINE_ROOT}/.bootstrap_complete" ]; then
    echo "[PIPELINE] ERROR: Bootstrap not complete. Run startup.sh first."
    exit 1
fi

# ── Download inputs from GCS ───────────────────────────────────────────────
echo "[PIPELINE] Downloading inputs from GCS..."
mkdir -p "${INPUT_DIR}"
# Only pull from GCS if inputs aren't already present locally. The web UI uploads
# directly into ${INPUT_DIR}; pulling unconditionally would clobber those with
# whatever stale files happen to sit in the bucket.
if [ ! -f "${INPUT_DIR}/source_video.mp4" ]; then
    echo "[PIPELINE] No local source video — fetching inputs from GCS..."
    gsutil -q cp "${GCS_BUCKET}/input/*" "${INPUT_DIR}/" 2>/dev/null || \
        echo "[PIPELINE] WARNING: No input files in GCS bucket"
else
    echo "[PIPELINE] Using locally-provided inputs (skipping GCS pull)."
fi

# Verify required inputs
if [ ! -f "${INPUT_DIR}/source_video.mp4" ]; then
    echo "[PIPELINE] ERROR: source_video.mp4 not found in ${INPUT_DIR}"
    echo "  Upload it: gsutil cp your_video.mp4 ${GCS_BUCKET}/input/source_video.mp4"
    exit 1
fi

if [ ! -f "${INPUT_DIR}/reference_image.png" ]; then
    echo "[PIPELINE] WARNING: reference_image.png not found. Stage 4 may fail."
fi

mkdir -p "${OUTPUT_DIR}"

# ============================================================================
# STAGE 1: WHAM — Markerless 3D Feature Extraction
# ============================================================================
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  STAGE 1: WHAM — Markerless 3D SMPL Extraction              │"
echo "└──────────────────────────────────────────────────────────────┘"
STAGE1_START=$(date +%s)

# NOTE: WHAM output is no longer used for the control path (Stage 2 now samples
# pose directly from the source video). It is kept for optional 3D metadata only,
# so a WHAM failure must NOT abort the run.
python "${SCRIPTS_DIR}/stage1_wham_extract.py" \
    --input "${INPUT_DIR}/source_video.mp4" \
    --output "${OUTPUT_DIR}/raw.fbx" \
    || echo "[PIPELINE] Stage 1 (WHAM) failed — continuing (not required for control)."

STAGE1_END=$(date +%s)
echo "[PIPELINE] Stage 1 complete in $((STAGE1_END - STAGE1_START))s"

# ============================================================================
# STAGE 2: Frame Extraction — pose control straight from the source video
# ============================================================================
# Pose detectors (DWPose/DensePose) work on REAL footage, not re-rendered 3D
# meshes. We sample the source video into <=81 evenly-spaced frames (the L4
# single-pass ceiling), letterboxed to the render size. These feed Stage 3.
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  STAGE 2: Frame Extraction — source video → control frames  │"
echo "└──────────────────────────────────────────────────────────────┘"
STAGE2_START=$(date +%s)

SRC_VIDEO="${INPUT_DIR}/source_video.mp4"
rm -rf "${OUTPUT_DIR}/renders"
mkdir -p "${OUTPUT_DIR}/renders"

# Sample fps so the whole clip fits in <=81 frames, never upsampling past native.
DURATION=$(ffprobe -v error -select_streams v:0 -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "${SRC_VIDEO}")
NATIVE_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "${SRC_VIDEO}")
EXTRACT_FPS=$(python -c "
n='${NATIVE_FPS}'.split('/'); nf=float(n[0])/float(n[1]) if len(n)>1 else float(n[0])
d=float('${DURATION}')
print(max(1, int(min(nf, 81.0/d))))
")
echo "[Stage2] source: duration=${DURATION}s native_fps=${NATIVE_FPS} -> extract_fps=${EXTRACT_FPS}"

ffmpeg -y -loglevel error -i "${SRC_VIDEO}" \
    -vf "fps=${EXTRACT_FPS},scale=832:480:force_original_aspect_ratio=decrease,pad=832:480:(ow-iw)/2:(oh-ih)/2" \
    "${OUTPUT_DIR}/renders/frame_%06d.png"

FRAME_COUNT=$(find "${OUTPUT_DIR}/renders" -name '*.png' | wc -l)
if [ "${FRAME_COUNT}" -lt 1 ]; then
    echo "[PIPELINE] ERROR: Stage 2 frame extraction produced no frames."
    exit 1
fi
echo "[Stage2] Extracted ${FRAME_COUNT} control frames @ ${EXTRACT_FPS} fps"

STAGE2_END=$(date +%s)
echo "[PIPELINE] Stage 2 complete in $((STAGE2_END - STAGE2_START))s"

# ============================================================================
# STAGE 3: ControlNet-Aux — Structural Landmark Preprocessing
# ============================================================================
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  STAGE 3: ControlNet-Aux — DensePose + DWPose Maps          │"
echo "└──────────────────────────────────────────────────────────────┘"
STAGE3_START=$(date +%s)

# Clear prior guidance maps so a shorter clip can't inherit stale frames from a
# longer previous run (which would inflate the frame count and crash Stage 4).
rm -rf "${OUTPUT_DIR}/controlnet_maps"

python "${SCRIPTS_DIR}/stage3_controlnet_preprocess.py" \
    --frames "${OUTPUT_DIR}/renders" \
    --resolution 832 \
    --device cuda

STAGE3_END=$(date +%s)
echo "[PIPELINE] Stage 3 complete in $((STAGE3_END - STAGE3_START))s"

# ============================================================================
# STAGE 4: ComfyUI — Neural Rendering & Energy Fields
# ============================================================================
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  STAGE 4: ComfyUI — Wan 2.1 14B Neural Render              │"
echo "└──────────────────────────────────────────────────────────────┘"
STAGE4_START=$(date +%s)

python "${SCRIPTS_DIR}/stage4_comfyui_render.py" \
    --workflow "${SCRIPTS_DIR}/workflow_qi_pipeline.json" \
    --reference-image "${INPUT_DIR}/reference_image.png" \
    --controlnet-maps "${OUTPUT_DIR}/controlnet_maps/composite" \
    --output "${OUTPUT_DIR}/final.mp4" \
    --fps "${EXTRACT_FPS:-24}" \
    --target-fps "${TARGET_FPS:-30}" \
    --riflex-index "${RIFLEX_FREQ_INDEX:-0}" \
    --block-swap "${BLOCK_SWAP:-0}"

STAGE4_END=$(date +%s)
echo "[PIPELINE] Stage 4 complete in $((STAGE4_END - STAGE4_START))s"

# ============================================================================
# UPLOAD RESULTS
# ============================================================================
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  UPLOADING RESULTS TO GCS                                   │"
echo "└──────────────────────────────────────────────────────────────┘"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Upload final video
gsutil cp "${OUTPUT_DIR}/final.mp4" "${GCS_BUCKET}/output/final_${TIMESTAMP}.mp4"

# Upload metadata
gsutil -q cp "${OUTPUT_DIR}/stage"*"_metadata.json" "${GCS_BUCKET}/output/metadata/" 2>/dev/null || true

# Upload pipeline log
gsutil cp "${LOG_FILE}" "${GCS_BUCKET}/logs/pipeline_run_${TIMESTAMP}.log"

# ============================================================================
# SUMMARY
# ============================================================================
TOTAL_TIME=$(( $(date +%s) - STAGE1_START ))
echo ""
echo "================================================================"
echo "[PIPELINE] ✓ ALL STAGES COMPLETE — $(date -Iseconds)"
echo "================================================================"
echo "  Stage 1 (WHAM):       $((STAGE1_END - STAGE1_START))s"
echo "  Stage 2 (Blender):    $((STAGE2_END - STAGE2_START))s"
echo "  Stage 3 (ControlNet): $((STAGE3_END - STAGE3_START))s"
echo "  Stage 4 (ComfyUI):    $((STAGE4_END - STAGE4_START))s"
echo "  Total:                ${TOTAL_TIME}s"
echo ""
echo "  Output: ${GCS_BUCKET}/output/final_${TIMESTAMP}.mp4"
echo "================================================================"

# ============================================================================
# AUTO-SHUTDOWN — COST MINIMIZATION
# ============================================================================
# The millisecond the final video file write confirms, immediately trigger
# an automated system shutdown to terminate the cloud hardware.
if [ "${SKIP_SHUTDOWN}" != "1" ]; then
    echo ""
    echo "[PIPELINE] Final video uploaded. Initiating auto-shutdown to prevent idle billing..."
    sleep 5  # Brief grace period for log flush
    sudo shutdown -h now
else
    echo "[PIPELINE] SKIP_SHUTDOWN=1 — VM will remain running."
fi

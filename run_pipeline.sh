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
export COMFYUI_DIR="${COMFYUI_DIR:-${PIPELINE_ROOT}/engines/ComfyUI}"

# ── Pipeline mode ───────────────────────────────────────────────────────────
# Two render engines share this orchestrator. Select with PIPELINE_MODE:
#   animate    — Wan2.2-Animate: faithfully animates the uploaded reference photo
#                with the driving video's motion (identity preserved).
#   funcontrol — Wan2.1 Fun Control: generates a NEW subject from the text prompt,
#                steered by DensePose/DWPose maps (prompt-driven / stylized).
PIPELINE_MODE="${PIPELINE_MODE:-animate}"
case "${PIPELINE_MODE}" in
  animate)
    MODE_WORKFLOW="${SCRIPTS_DIR}/workflows/wan_animate.json"
    RUN_DENSEPOSE=0                                     # pose+face detection is in-graph
    STAGE4_FRAMES_DIR="${OUTPUT_DIR}/renders"          # raw driving frames
    ;;
  funcontrol)
    MODE_WORKFLOW="${SCRIPTS_DIR}/workflows/fun_control.json"
    RUN_DENSEPOSE=1                                     # DensePose/DWPose control maps required
    STAGE4_FRAMES_DIR="${OUTPUT_DIR}/controlnet_maps/composite"
    ;;
  *)
    echo "[PIPELINE] ERROR: unknown PIPELINE_MODE='${PIPELINE_MODE}' (expected: animate | funcontrol)"
    exit 1
    ;;
esac
export PIPELINE_MODE
echo "[PIPELINE] Mode: ${PIPELINE_MODE}  (workflow: ${MODE_WORKFLOW})"

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

# Activate conda environment (GCP). On RunPod (no conda) use system python.
if [ "${USE_CONDA:-1}" = "1" ] && [ -f "${CONDA_ROOT}/etc/profile.d/conda.sh" ]; then
    source "${CONDA_ROOT}/etc/profile.d/conda.sh"
    conda activate qi-pipeline
else
    echo "[PIPELINE] Conda skipped — using system python ($(command -v python))."
fi

# Verify GPU
echo "[PIPELINE] GPU Status:"
nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader

# Check bootstrap completed
if [ ! -f "${PIPELINE_ROOT}/.bootstrap_complete" ]; then
    echo "[PIPELINE] ERROR: Bootstrap not complete. Run startup.sh first."
    exit 1
fi

# ── Inputs ──────────────────────────────────────────────────────────────────
mkdir -p "${INPUT_DIR}"
# The web UI (app_server) uploads directly into ${INPUT_DIR}. On GCP we also pull
# from GCS if no local source exists; on RunPod (USE_GCS=0) inputs are local-only.
if [ "${USE_GCS:-1}" = "1" ] && [ ! -f "${INPUT_DIR}/source_video.mp4" ]; then
    echo "[PIPELINE] No local source video — fetching inputs from GCS..."
    gsutil -q cp "${GCS_BUCKET}/input/*" "${INPUT_DIR}/" 2>/dev/null || \
        echo "[PIPELINE] WARNING: No input files in GCS bucket"
else
    echo "[PIPELINE] Using locally-provided inputs in ${INPUT_DIR}."
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

# WHAM output is NOT used by either pipeline anymore (Stage 2 samples pose/face
# directly; Animate detects in-graph). It is dead weight — skipped unless
# RUN_WHAM=1 is set explicitly (e.g. to regenerate optional 3D metadata).
if [ "${RUN_WHAM:-0}" = "1" ]; then
    python "${SCRIPTS_DIR}/stage1_wham_extract.py" \
        --input "${INPUT_DIR}/source_video.mp4" \
        --output "${OUTPUT_DIR}/raw.fbx" \
        || echo "[PIPELINE] Stage 1 (WHAM) failed — continuing (not required)."
else
    echo "[PIPELINE] Stage 1 (WHAM) skipped — output unused by control path (set RUN_WHAM=1 to force)."
fi

STAGE1_END=$(date +%s)
echo "[PIPELINE] Stage 1 complete in $((STAGE1_END - STAGE1_START))s"

# ============================================================================
# STAGE 2: Frame Extraction — driving frames for Wan-Animate
# ============================================================================
# Wan-Animate reads pose + face from the REAL driving footage and renders the
# whole performance via context windows (no 81-frame single-pass ceiling). So we
# keep the real motion (extract at ANIMATE_FPS, not a downsampled 2 fps) and
# match the source aspect ratio (no letterboxing of a square video into 16:9).
echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  STAGE 2: Frame Extraction — driving frames (full motion)   │"
echo "└──────────────────────────────────────────────────────────────┘"
STAGE2_START=$(date +%s)

SRC_VIDEO="${INPUT_DIR}/source_video.mp4"
rm -rf "${OUTPUT_DIR}/renders"
mkdir -p "${OUTPUT_DIR}/renders"

# Normalize the source: bake in any rotation metadata. Phone-portrait videos store
# LANDSCAPE dims + a rotation flag; ffmpeg auto-rotates frames on decode but ffprobe
# reports the STORAGE dims, so gen dims get computed landscape and the portrait
# content is squashed into a low-res landscape frame (mangled limbs). Re-encoding
# produces an upright file whose storage dims == display dims, so sizing is correct.
NORM_VIDEO="${OUTPUT_DIR}/source_normalized.mp4"
if ffmpeg -y -loglevel error -i "${SRC_VIDEO}" -c:v libx264 -pix_fmt yuv420p -an "${NORM_VIDEO}" 2>/dev/null && [ -s "${NORM_VIDEO}" ]; then
    SRC_VIDEO="${NORM_VIDEO}"
    echo "[Stage2] Normalized source (rotation baked) -> ${NORM_VIDEO}"
else
    echo "[Stage2] WARNING: normalization failed; using original source."
fi

DURATION=$(ffprobe -v error -select_streams v:0 -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "${SRC_VIDEO}")
NATIVE_FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "${SRC_VIDEO}")
SRC_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width \
    -of default=noprint_wrappers=1:nokey=1 "${SRC_VIDEO}")
SRC_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
    -of default=noprint_wrappers=1:nokey=1 "${SRC_VIDEO}")

# Generation dims + extraction rate depend on the mode.
if [ "${PIPELINE_MODE}" = "funcontrol" ]; then
    # Fun Control: fixed 832x480; downsample so the whole clip fits in <=81 frames.
    GEN_W=832; GEN_H=480
    EXTRACT_FPS=$(python -c "
n='${NATIVE_FPS}'.split('/'); nf=float(n[0])/float(n[1]) if len(n)>1 else float(n[0])
d=float('${DURATION}')
print(max(1, int(min(nf, 81.0/d))))
")
else
    # Wan-Animate: preserve source aspect (target ~GEN_SIZE long edge, /16) and
    # keep the real motion (extract at TARGET_EXTRACT_FPS, whole performance).
    GEN_SIZE="${GEN_SIZE:-1280}"
    read GEN_W GEN_H < <(python -c "
w,h=${SRC_W},${SRC_H}
s=${GEN_SIZE}/max(w,h)
print(max(16,int(round(w*s/16))*16), max(16,int(round(h*s/16))*16))
")
    EXTRACT_FPS=$(python -c "
n='${NATIVE_FPS}'.split('/'); nf=float(n[0])/float(n[1]) if len(n)>1 else float(n[0])
print(max(1, int(min(nf, ${TARGET_EXTRACT_FPS:-16}))))
")
fi
export GEN_W GEN_H
echo "[Stage2] source: ${SRC_W}x${SRC_H} duration=${DURATION}s native_fps=${NATIVE_FPS}"
echo "[Stage2] -> mode=${PIPELINE_MODE} gen=${GEN_W}x${GEN_H} extract_fps=${EXTRACT_FPS}"

ffmpeg -y -loglevel error -i "${SRC_VIDEO}" \
    -vf "fps=${EXTRACT_FPS},scale=${GEN_W}:${GEN_H}:force_original_aspect_ratio=decrease,pad=${GEN_W}:${GEN_H}:(ow-iw)/2:(oh-ih)/2" \
    "${OUTPUT_DIR}/renders/frame_%06d.png"

FRAME_COUNT=$(find "${OUTPUT_DIR}/renders" -name '*.png' | wc -l)
if [ "${FRAME_COUNT}" -lt 1 ]; then
    echo "[PIPELINE] ERROR: Stage 2 frame extraction produced no frames."
    exit 1
fi
echo "[Stage2] Extracted ${FRAME_COUNT} driving frames @ ${EXTRACT_FPS} fps (${GEN_W}x${GEN_H})"

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

# funcontrol mode needs DensePose/DWPose control maps; animate mode does pose+face
# detection in-graph (Stage 4) and consumes the raw driving frames directly.
if [ "${RUN_DENSEPOSE}" = "1" ]; then
    rm -rf "${OUTPUT_DIR}/controlnet_maps"
    python "${SCRIPTS_DIR}/stage3_controlnet_preprocess.py" \
        --frames "${OUTPUT_DIR}/renders" \
        --resolution 832 \
        --device cuda
else
    echo "[Stage3] Skipped — Wan-Animate detects pose/face in-graph (Stage 4)."
fi

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

# Reference handling differs per mode: Wan-Animate needs the reference padded to
# the gen aspect (so the avatar keeps true proportions — no "fat" squash). Fun
# Control only uses it as a weak CLIP hint, so it's passed through unchanged.
if [ "${PIPELINE_MODE}" = "animate" ]; then
    REF_IMAGE="${OUTPUT_DIR}/reference_square.png"
    ffmpeg -y -loglevel error -i "${INPUT_DIR}/reference_image.png" \
        -vf "pad=w='max(iw,ih*${GEN_W:-1}/${GEN_H:-1})':h='max(ih,iw*${GEN_H:-1}/${GEN_W:-1})':x='(ow-iw)/2':y='(oh-ih)/2':color=white" \
        "${REF_IMAGE}" || cp "${INPUT_DIR}/reference_image.png" "${REF_IMAGE}"
    echo "[Stage4] Reference padded to ${GEN_W}x${GEN_H} aspect: ${REF_IMAGE}"
else
    REF_IMAGE="${INPUT_DIR}/reference_image.png"
fi

python "${SCRIPTS_DIR}/stage4_comfyui_render.py" \
    --mode "${PIPELINE_MODE}" \
    --workflow "${WORKFLOW_PATH:-${MODE_WORKFLOW}}" \
    --reference-image "${REF_IMAGE}" \
    --controlnet-maps "${STAGE4_FRAMES_DIR}" \
    --output "${OUTPUT_DIR}/final.mp4" \
    --fps "${EXTRACT_FPS:-24}" \
    --target-fps "${TARGET_FPS:-30}" \
    --gen-width "${GEN_W:-832}" \
    --gen-height "${GEN_H:-480}" \
    --riflex-index "${RIFLEX_FREQ_INDEX:-0}" \
    --block-swap "${BLOCK_SWAP:-0}"

STAGE4_END=$(date +%s)
echo "[PIPELINE] Stage 4 complete in $((STAGE4_END - STAGE4_START))s"

# ============================================================================
# UPLOAD RESULTS
# ============================================================================
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FINAL_LOCATION="${OUTPUT_DIR}/final.mp4"
if [ "${USE_GCS:-1}" = "1" ]; then
    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│  UPLOADING RESULTS TO GCS                                   │"
    echo "└──────────────────────────────────────────────────────────────┘"
    gsutil cp "${OUTPUT_DIR}/final.mp4" "${GCS_BUCKET}/output/final_${TIMESTAMP}.mp4"
    gsutil -q cp "${OUTPUT_DIR}/stage"*"_metadata.json" "${GCS_BUCKET}/output/metadata/" 2>/dev/null || true
    gsutil cp "${LOG_FILE}" "${GCS_BUCKET}/logs/pipeline_run_${TIMESTAMP}.log"
    FINAL_LOCATION="${GCS_BUCKET}/output/final_${TIMESTAMP}.mp4"
else
    echo "[PIPELINE] GCS disabled — final video kept locally at ${FINAL_LOCATION}"
fi

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
echo "  Output: ${FINAL_LOCATION}"
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

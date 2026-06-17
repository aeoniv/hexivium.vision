#!/usr/bin/env bash
# ============================================================================
# Qi Pipeline — RunPod A100 80GB setup (Wan2.2-Animate, bf16, website-grade)
# ============================================================================
# Target: a RunPod pod on an A100 80GB (or H100) using a PyTorch base image
# (CUDA 12.1+, Python 3.10/3.11, torch already present). Run ONCE per pod, or
# once onto a PERSISTENT VOLUME mounted at /workspace so models survive restarts.
#
# This is the ANIMATE path only — WHAM + Blender + DensePose are NOT installed
# (they were dead weight on GCP). At 80GB we use the bf16 model and can run the
# two-pass enhancer that wouldn't fit on the 24GB L4.
#
# Usage:
#   export HF_TOKEN=hf_xxx            # optional, speeds up / unlocks gated models
#   bash runpod_setup.sh
# ============================================================================
set -euo pipefail

ROOT="${ROOT:-/workspace/qi}"          # put on the persistent volume
COMFY="${ROOT}/ComfyUI"
MODELS="${COMFY}/models"
PYBIN="$(command -v python3 || command -v python)"

echo "=== Qi RunPod setup → ${ROOT} (python: ${PYBIN}) ==="
mkdir -p "${ROOT}"

# ── system deps (RunPod images are minimal) ─────────────────────────────────
apt-get update -qq && apt-get install -y -qq ffmpeg git git-lfs wget curl libgl1 libglib2.0-0 2>/dev/null
git lfs install 2>/dev/null || true

# ── ComfyUI (clone BEFORE creating models/ subdirs, else the clone is skipped) ─
if [ ! -f "${COMFY}/main.py" ]; then
    rm -rf "${COMFY}"
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "${COMFY}"
fi
mkdir -p "${MODELS}"/{diffusion_models,text_encoders,vae,clip_vision,loras,detection,checkpoints}
"${PYBIN}" -m pip install --break-system-packages --quiet -r "${COMFY}/requirements.txt"
"${PYBIN}" -m pip install --break-system-packages --quiet "huggingface_hub[cli]" websocket-client onnxruntime-gpu color-matcher

# ── custom nodes (Animate stack) ────────────────────────────────────────────
CN="${COMFY}/custom_nodes"; mkdir -p "${CN}"; cd "${CN}"
clone() { [ -d "$2" ] || git clone --depth 1 "$1" "$2"; }
clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git        ComfyUI-WanVideoWrapper
clone https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git   ComfyUI-WanAnimatePreprocess
clone https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git ComfyUI-Frame-Interpolation
clone https://github.com/kijai/ComfyUI-KJNodes.git               ComfyUI-KJNodes
clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git ComfyUI-VideoHelperSuite
for d in ComfyUI-WanVideoWrapper ComfyUI-WanAnimatePreprocess ComfyUI-KJNodes ComfyUI-VideoHelperSuite; do
    [ -f "${CN}/${d}/requirements.txt" ] && "${PYBIN}" -m pip install --break-system-packages --quiet -r "${CN}/${d}/requirements.txt" || true
done
# RIFE: no-cupy reqs + weight prefetch
[ -f "${CN}/ComfyUI-Frame-Interpolation/requirements-no-cupy.txt" ] && \
    "${PYBIN}" -m pip install --break-system-packages --quiet -r "${CN}/ComfyUI-Frame-Interpolation/requirements-no-cupy.txt" || true

# ── models: handled by dl_models.sh (verified fp8 canonical stack). Skipped here
# unless SETUP_DOWNLOAD_MODELS=1 (legacy best-guess bf16 paths). ─────────────
if [ "${SETUP_DOWNLOAD_MODELS:-0}" = "1" ]; then
HF="huggingface-cli download"
dl() { # repo  file  dest_subdir
    local out="${MODELS}/$3"
    [ -f "${out}/$(basename "$2")" ] || ${HF} "$1" "$2" --local-dir "${out}" 2>/dev/null \
        || echo "[!] FAILED: $1/$2 (download manually)"
}
# Wan2.2-Animate-14B bf16 (Kijai repackaged for WanVideoWrapper)
dl Kijai/WanVideo_comfy   Wan2_2-Animate-14B_bf16.safetensors            diffusion_models
# Text encoder (bf16 for quality), VAE, CLIP vision
dl Kijai/WanVideo_comfy   umt5-xxl-enc-bf16.safetensors                  text_encoders
dl Kijai/WanVideo_comfy   Wan2_1_VAE_bf16.safetensors                    vae
dl Comfy-Org/Wan_2.1_ComfyUI_repackaged split_files/clip_vision/clip_vision_h.safetensors clip_vision
# LoRAs: relight (replace-mode) + lightx2v (optional accel; at 80GB we can also
# run full-step for max quality — kept here so both modes are available)
dl Kijai/WanVideo_comfy   WanAnimate_relight_lora_fp16.safetensors       loras
dl Kijai/WanVideo_comfy   Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors loras/Lightx2v
# Detection (ViTPose + YOLO) for in-graph pose/face
dl Kijai/ComfyUI-WanAnimatePreprocess vitpose-h-wholebody.onnx           detection
dl Kijai/ComfyUI-WanAnimatePreprocess yolov10m.onnx                      detection
# RealVisXL for avatar generation (optional)
dl SG161222/RealVisXL_V5.0 RealVisXL_V5.0_fp16.safetensors               checkpoints
fi

echo ""
echo "=== DONE. Next: deploy pipeline scripts + workflows, then launch ComfyUI ==="
echo "    ${PYBIN} ${COMFY}/main.py --listen 0.0.0.0 --port 8188"

#!/usr/bin/env bash
# ============================================================================
# Qi Pipeline Director — VM Bootstrap (startup.sh)
# ============================================================================
# Runs ONCE on first boot. Installs the full pipeline stack:
#   • System dependencies (ffmpeg, libgl, etc.)
#   • Miniconda + qi-pipeline conda env (Python 3.10, PyTorch 2.3, CUDA 12.4)
#   • WHAM (markerless 3D SMPL extraction)
#   • Blender 4.1 (headless, portable build)
#   • ComfyUI + custom nodes (ControlNet-Aux, WanVideoWrapper)
#   • Model weights (Wan 2.1 Fun Control 14B FP8, text encoder, VAE, CLIP)
# ============================================================================

set -euo pipefail

PIPELINE_ROOT="/opt/qi-pipeline"
BOOTSTRAP_MARKER="${PIPELINE_ROOT}/.bootstrap_complete"
LOG_FILE="/var/log/qi-pipeline-bootstrap.log"
GCS_BUCKET="gs://hexivium-vision-pipeline"

# ── Skip if already bootstrapped ─────────────────────────────────────────────
if [ -f "${BOOTSTRAP_MARKER}" ]; then
    echo "[i] Bootstrap already complete. Skipping." | tee -a "${LOG_FILE}"
    exit 0
fi

export HOME="/root"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "=========================================="
echo "[*] Qi Pipeline Bootstrap — $(date -Iseconds)"
echo "=========================================="

mkdir -p "${PIPELINE_ROOT}"/{input,output,models,scripts,tmp}
cd "${PIPELINE_ROOT}"

# ============================================================================
# 1. SYSTEM DEPENDENCIES
# ============================================================================
echo "[1/7] Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    ffmpeg \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    libgomp1 \
    git \
    git-lfs \
    wget \
    curl \
    unzip \
    xvfb \
    libxkbcommon0 \
    libxi6 \
    2>/dev/null

git lfs install 2>/dev/null || true

# ============================================================================
# 2. MINICONDA + CONDA ENVIRONMENT
# ============================================================================
echo "[2/7] Setting up Miniconda..."
CONDA_ROOT="/opt/miniconda3"
if [ ! -d "${CONDA_ROOT}" ]; then
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh
    bash /tmp/miniconda.sh -b -p "${CONDA_ROOT}"
    rm /tmp/miniconda.sh
fi

export PATH="${CONDA_ROOT}/bin:${PATH}"
source "${CONDA_ROOT}/etc/profile.d/conda.sh"

# Accept Anaconda TOS (required since 2025) and configure conda-forge
conda config --set auto_activate_base false
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true
conda config --add channels conda-forge
conda config --set channel_priority strict

# Create the pipeline environment (re-create to ensure clean Python 3.10 setup)
conda env remove -y -n qi-pipeline 2>/dev/null || true
conda create -y -n qi-pipeline python=3.10 pip --override-channels -c conda-forge
conda activate qi-pipeline
export PATH="${CONDA_ROOT}/envs/qi-pipeline/bin:${PATH}"

# Core ML stack
pip install --quiet \
    torch==2.3.1 torchvision==0.18.1 torchaudio==2.3.1 \
    --index-url https://download.pytorch.org/whl/cu121

pip install --quiet \
    numpy scipy opencv-python-headless Pillow \
    huggingface_hub requests websocket-client \
    trimesh smplx chumpy-fork

# ============================================================================
# 3. WHAM — MARKERLESS 3D SMPL EXTRACTION
# ============================================================================
echo "[3/7] Installing WHAM..."
WHAM_DIR="${PIPELINE_ROOT}/engines/WHAM"
if [ ! -d "${WHAM_DIR}" ]; then
    mkdir -p "${PIPELINE_ROOT}/engines"
    cd "${PIPELINE_ROOT}/engines"
    git clone --depth 1 https://github.com/yohanshin/WHAM.git
    cd WHAM

    pip install --quiet -r requirements.txt

    # Install ViTPose (third-party dependency)
    if [ -d "third-party/ViTPose" ]; then
        pip install --quiet -v -e third-party/ViTPose
    fi

    # Install DPVO if present
    if [ -d "third-party/DPVO" ]; then
        pip install --quiet -v -e third-party/DPVO 2>/dev/null || echo "[!] DPVO install skipped (optional)"
    fi

    # Download pretrained checkpoints
    if [ -f "fetch_demo_data.sh" ]; then
        bash fetch_demo_data.sh 2>/dev/null || echo "[!] Some demo data downloads may have failed"
    fi
fi

# Copy SMPL models from GCS (user must have uploaded them)
echo "[3/7] Copying SMPL models from GCS..."
SMPL_TARGET="${WHAM_DIR}/data/smpl"
mkdir -p "${SMPL_TARGET}"
gsutil -q cp -r "${GCS_BUCKET}/smpl_models/*" "${SMPL_TARGET}/" 2>/dev/null || \
    echo "[!] WARNING: SMPL models not found in GCS. Upload to ${GCS_BUCKET}/smpl_models/"

cd "${PIPELINE_ROOT}"

# ============================================================================
# 4. BLENDER 4.1 — HEADLESS PORTABLE BUILD
# ============================================================================
echo "[4/7] Installing Blender 4.1 (headless)..."
BLENDER_DIR="${PIPELINE_ROOT}/engines/blender"
BLENDER_BIN="${BLENDER_DIR}/blender"

if [ ! -f "${BLENDER_BIN}" ]; then
    mkdir -p "${BLENDER_DIR}"
    BLENDER_URL="https://mirror.clarkson.edu/blender/release/Blender4.1/blender-4.1.1-linux-x64.tar.xz"
    wget -q "${BLENDER_URL}" -O /tmp/blender.tar.xz
    tar -xf /tmp/blender.tar.xz -C "${BLENDER_DIR}" --strip-components=1
    rm /tmp/blender.tar.xz

    # Install scipy into Blender's bundled Python for Gaussian filtering
    BLENDER_PYTHON="${BLENDER_DIR}/4.1/python/bin/python3.11"
    if [ -f "${BLENDER_PYTHON}" ]; then
        "${BLENDER_PYTHON}" -m ensurepip
        "${BLENDER_PYTHON}" -m pip install --quiet scipy numpy joblib wheel chumpy-fork
    fi
fi

# Validate headless execution
"${BLENDER_BIN}" --background --version || echo "[!] Blender headless validation failed"

# ============================================================================
# 5. COMFYUI + CUSTOM NODES
# ============================================================================
echo "[5/7] Installing ComfyUI..."
COMFYUI_DIR="${PIPELINE_ROOT}/engines/ComfyUI"

if [ ! -d "${COMFYUI_DIR}" ]; then
    cd "${PIPELINE_ROOT}/engines"
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git
    cd ComfyUI
    pip install --quiet -r requirements.txt
fi

# ── Custom Nodes ─────────────────────────────────────────────────────────────
CUSTOM_NODES="${COMFYUI_DIR}/custom_nodes"
mkdir -p "${CUSTOM_NODES}"

# ControlNet Auxiliary Preprocessors (DensePose, DWPose)
if [ ! -d "${CUSTOM_NODES}/comfyui_controlnet_aux" ]; then
    echo "[5/7] Installing ControlNet-Aux custom node..."
    cd "${CUSTOM_NODES}"
    git clone --depth 1 https://github.com/Fannovel16/comfyui_controlnet_aux.git
    cd comfyui_controlnet_aux
    pip install --quiet -r requirements.txt
fi

# WanVideoWrapper (Kijai) — Wan 2.1 Fun Control loader
if [ ! -d "${CUSTOM_NODES}/ComfyUI-WanVideoWrapper" ]; then
    echo "[5/7] Installing WanVideoWrapper custom node..."
    cd "${CUSTOM_NODES}"
    git clone --depth 1 https://github.com/kijai/ComfyUI-WanVideoWrapper.git
    cd ComfyUI-WanVideoWrapper
    if [ -f "requirements.txt" ]; then
        pip install --quiet -r requirements.txt
    fi
fi

# Frame Interpolation (RIFE) — smooths low-fps keyframes up to the target
# playback rate so longer clips look fluid instead of choppy.
if [ ! -d "${CUSTOM_NODES}/ComfyUI-Frame-Interpolation" ]; then
    echo "[5/7] Installing Frame-Interpolation (RIFE) custom node..."
    cd "${CUSTOM_NODES}"
    git clone --depth 1 https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git
    cd ComfyUI-Frame-Interpolation
    if [ -f "requirements-no-cupy.txt" ]; then
        pip install --quiet -r requirements-no-cupy.txt
    elif [ -f "requirements.txt" ]; then
        pip install --quiet -r requirements.txt
    fi
    # Pre-fetch RIFE weights so the first render doesn't stall on download.
    python install.py 2>/dev/null || echo "[!] RIFE model prefetch deferred to first run."
fi

# ComfyUI Manager (optional but useful for debugging)
if [ ! -d "${CUSTOM_NODES}/ComfyUI-Manager" ]; then
    cd "${CUSTOM_NODES}"
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager.git
fi

cd "${PIPELINE_ROOT}"

# ============================================================================
# 6. MODEL WEIGHTS DOWNLOAD
# ============================================================================
echo "[6/7] Downloading model weights from HuggingFace..."
MODELS_DIR="${COMFYUI_DIR}/models"
mkdir -p "${MODELS_DIR}"/{diffusion_models,text_encoders,vae,clip_vision}

# Wan 2.1 Fun Control 14B (FP8) — ~14GB
DIFFUSION_MODEL="${MODELS_DIR}/diffusion_models/wan2.1_fun_control_14B_fp8.safetensors"
if [ ! -f "${DIFFUSION_MODEL}" ]; then
    echo "  Downloading Wan 2.1 Fun Control 14B (FP8)..."
    huggingface-cli download \
        Comfy-Org/Wan_2.1_ComfyUI_repackaged \
        split_files/diffusion_models/wan2.1_fun_control_14B_fp8.safetensors \
        --local-dir "${MODELS_DIR}/diffusion_models" \
        --local-dir-use-symlinks False \
        2>/dev/null || \
    # Fallback: try alibaba-pai directly
    huggingface-cli download \
        alibaba-pai/Wan2.1-Fun-14B-Control \
        --local-dir "${PIPELINE_ROOT}/tmp/wan_fun_14b" \
        --local-dir-use-symlinks False \
        2>/dev/null || echo "[!] WARNING: Could not download Wan 14B model. Manual download required."
fi

# UMT5-XXL Text Encoder (FP8) — ~5GB
TEXT_ENCODER="${MODELS_DIR}/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
if [ ! -f "${TEXT_ENCODER}" ]; then
    echo "  Downloading UMT5-XXL text encoder (FP8)..."
    huggingface-cli download \
        Comfy-Org/Wan_2.1_ComfyUI_repackaged \
        split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors \
        --local-dir "${MODELS_DIR}/text_encoders" \
        --local-dir-use-symlinks False \
        2>/dev/null || echo "[!] Text encoder download failed"
fi

# Wan 2.1 VAE — ~300MB
VAE_MODEL="${MODELS_DIR}/vae/wan_2.1_vae.safetensors"
if [ ! -f "${VAE_MODEL}" ]; then
    echo "  Downloading Wan 2.1 VAE..."
    huggingface-cli download \
        Comfy-Org/Wan_2.1_ComfyUI_repackaged \
        split_files/vae/wan_2.1_vae.safetensors \
        --local-dir "${MODELS_DIR}/vae" \
        --local-dir-use-symlinks False \
        2>/dev/null || echo "[!] VAE download failed"
fi

# CLIP Vision H — ~1.7GB
CLIP_MODEL="${MODELS_DIR}/clip_vision/clip_vision_h.safetensors"
if [ ! -f "${CLIP_MODEL}" ]; then
    echo "  Downloading CLIP Vision H..."
    huggingface-cli download \
        Comfy-Org/Wan_2.1_ComfyUI_repackaged \
        split_files/clip_vision/clip_vision_h.safetensors \
        --local-dir "${MODELS_DIR}/clip_vision" \
        --local-dir-use-symlinks False \
        2>/dev/null || echo "[!] CLIP Vision download failed"
fi

# ============================================================================
# 7. DEPLOY PIPELINE SCRIPTS
# ============================================================================
echo "[7/7] Deploying pipeline scripts from GCS..."
gsutil -q cp "${GCS_BUCKET}/scripts/stage1_wham_extract.py"         "${PIPELINE_ROOT}/scripts/" 2>/dev/null || true
gsutil -q cp "${GCS_BUCKET}/scripts/stage2_blender_smooth.py"       "${PIPELINE_ROOT}/scripts/" 2>/dev/null || true
gsutil -q cp "${GCS_BUCKET}/scripts/stage3_controlnet_preprocess.py" "${PIPELINE_ROOT}/scripts/" 2>/dev/null || true
gsutil -q cp "${GCS_BUCKET}/scripts/stage4_comfyui_render.py"       "${PIPELINE_ROOT}/scripts/" 2>/dev/null || true
mkdir -p "${PIPELINE_ROOT}/scripts/workflows"
gsutil -q -m cp "${GCS_BUCKET}/scripts/workflows/*"                 "${PIPELINE_ROOT}/scripts/workflows/" 2>/dev/null || true
gsutil -q cp "${GCS_BUCKET}/scripts/run_pipeline.sh"                "${PIPELINE_ROOT}/scripts/" 2>/dev/null || true
gsutil -q cp "${GCS_BUCKET}/scripts/cleanup_on_failure.sh"          "${PIPELINE_ROOT}/scripts/" 2>/dev/null || true
gsutil -q cp "${GCS_BUCKET}/scripts/qi_idle_watchdog.sh"            "${PIPELINE_ROOT}/scripts/" 2>/dev/null || true

# ── Web orchestrator UI ─────────────────────────────────────────────────────
gsutil -q cp "${GCS_BUCKET}/scripts/app_server.py"                 "${PIPELINE_ROOT}/scripts/" 2>/dev/null || true
mkdir -p "${PIPELINE_ROOT}/scripts/web"
gsutil -q -m cp "${GCS_BUCKET}/scripts/web/*"                      "${PIPELINE_ROOT}/scripts/web/" 2>/dev/null || true

chmod +x "${PIPELINE_ROOT}/scripts/"*.sh 2>/dev/null || true

# ── Install the idle watchdog (systemd timer) ───────────────────────────────
echo "[7/7] Installing idle watchdog..."
gsutil -q cp "${GCS_BUCKET}/scripts/qi-idle-watchdog.service" /etc/systemd/system/ 2>/dev/null || true
gsutil -q cp "${GCS_BUCKET}/scripts/qi-idle-watchdog.timer"   /etc/systemd/system/ 2>/dev/null || true
if [ -f /etc/systemd/system/qi-idle-watchdog.timer ]; then
    systemctl daemon-reload
    systemctl enable --now qi-idle-watchdog.timer
    echo "[i] Idle watchdog active — VM auto-stops after sustained idle."
else
    echo "[!] Idle watchdog units not found in GCS — skipping. Upload them to ${GCS_BUCKET}/scripts/"
fi

# ============================================================================
# DONE
# ============================================================================
touch "${BOOTSTRAP_MARKER}"

echo ""
echo "=========================================="
echo "[✓] Bootstrap complete — $(date -Iseconds)"
echo "=========================================="
echo "  Pipeline root:  ${PIPELINE_ROOT}"
echo "  WHAM:           ${WHAM_DIR}"
echo "  Blender:        ${BLENDER_BIN}"
echo "  ComfyUI:        ${COMFYUI_DIR}"
echo "  Models:         ${MODELS_DIR}"
echo ""
echo "  Run the pipeline:"
echo "    bash ${PIPELINE_ROOT}/scripts/run_pipeline.sh"
echo "=========================================="

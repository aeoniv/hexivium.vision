#!/usr/bin/env bash
source /opt/miniconda3/etc/profile.d/conda.sh
conda activate qi-pipeline
M=/opt/qi-pipeline/engines/ComfyUI/models
mkdir -p "$M/checkpoints"
echo "[dl] $(date -Iseconds) SDXL base 1.0 (~6.5GB)..."
hf download stabilityai/stable-diffusion-xl-base-1.0 sd_xl_base_1.0.safetensors \
  --local-dir "$M/checkpoints" || echo "[dl] FAILED sdxl"
echo "[dl] $(date -Iseconds) DONE"
ls -la "$M/checkpoints/"

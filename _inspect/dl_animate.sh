#!/usr/bin/env bash
# Download Wan2.2-Animate model + LoRAs into ComfyUI's model dirs.
source /opt/miniconda3/etc/profile.d/conda.sh
conda activate qi-pipeline
M=/opt/qi-pipeline/engines/ComfyUI/models
mkdir -p "$M/diffusion_models" "$M/loras"

echo "[dl] $(date -Iseconds) Wan2.2-Animate-14B fp8 (~16GB)..."
hf download Kijai/WanVideo_comfy_fp8_scaled \
  Wan22Animate/Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors \
  --local-dir "$M/diffusion_models" || echo "[dl] FAILED: animate model"

echo "[dl] $(date -Iseconds) lightx2v I2V distill LoRA..."
hf download Kijai/WanVideo_comfy \
  Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors \
  --local-dir "$M/loras" || echo "[dl] FAILED: lightx2v lora"

echo "[dl] $(date -Iseconds) WanAnimate relight LoRA..."
hf download Kijai/WanVideo_comfy \
  WanAnimate_relight_lora_fp16.safetensors \
  --local-dir "$M/loras" || echo "[dl] FAILED: relight lora"

echo "[dl] $(date -Iseconds) ALL DONE"
echo "=== diffusion_models/Wan22Animate ==="; ls -la "$M/diffusion_models/Wan22Animate/" 2>/dev/null
echo "=== loras ==="; find "$M/loras" -name '*.safetensors' -exec ls -la {} \;

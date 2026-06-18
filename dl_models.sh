#!/usr/bin/env bash
# Download Wan2.2-Animate bf16 model stack to ComfyUI (RunPod A100 80GB).
# Paths verified against ComfyUI-WanAnimatePreprocess README (authoritative).
set -u
M="/workspace/qi/ComfyUI/models"
TMP="/tmp/hfdl"; mkdir -p "$TMP"
mkdir -p "$M"/{diffusion_models,text_encoders,vae,clip_vision,loras,detection}

get() {  # repo  repo_path  dest_dir
    local base; base="$(basename "$2")"
    if [ -f "$3/$base" ]; then echo "SKIP (exists) $base"; return; fi
    echo ">>> $base"
    if hf download "$1" "$2" --local-dir "$TMP" >/dev/null 2>&1 && [ -f "$TMP/$2" ]; then
        mv "$TMP/$2" "$3/$base" && echo "OK   $base"
    else
        echo "FAIL $1 :: $2"
    fi
}

REPACK="Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
# CANONICAL diffusion model = fp8 scaled (~16GB) — what Kijai's reference uses; fits 48GB.
# (bf16 ~28GB is an optional 80GB precision upgrade; not the canonical spec.)
get "Kijai/WanVideo_comfy_fp8_scaled" "Wan22Animate/Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors" "$M/diffusion_models"
# VAE + CLIP vision (standard)
get "$REPACK" "split_files/vae/wan_2.1_vae.safetensors"                          "$M/vae"
get "$REPACK" "split_files/clip_vision/clip_vision_h.safetensors"                "$M/clip_vision"
# Text encoder — bf16 for max quality (Kijai)
get "Kijai/WanVideo_comfy" "umt5-xxl-enc-bf16.safetensors"                       "$M/text_encoders"
# Relight LoRA (bf16, official repackaged)
get "$REPACK" "split_files/loras/wan2.2_animate_14B_relight_lora_bf16.safetensors" "$M/loras"
# Lightx2v distill LoRA (Kijai) — the canonical Animate sampler runs 6-step on this
mkdir -p "$M/loras/Lightx2v"
get "Kijai/WanVideo_comfy" "Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors" "$M/loras/Lightx2v"
# RealVisXL checkpoint for the "Generate Avatar" (SDXL text-to-image) feature
mkdir -p "$M/checkpoints"
get "SG161222/RealVisXL_V5.0" "RealVisXL_V5.0_fp16.safetensors"                "$M/checkpoints"
# Detection: ViTPose-H (Kijai) + YOLOv10m (official Wan-AI)
get "Kijai/vitpose_comfy" "onnx/vitpose_h_wholebody_model.onnx"                  "$M/detection"
get "Wan-AI/Wan2.2-Animate-14B" "process_checkpoint/det/yolov10m.onnx"           "$M/detection"

echo "=== DOWNLOADS DONE ==="
du -sh "$M"/*/* 2>/dev/null

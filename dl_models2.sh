#!/usr/bin/env bash
# Fix the 3 failed/incomplete downloads. Stage on /workspace (89T), NOT /tmp (30G).
set -u
M="/workspace/qi/ComfyUI/models"
TMP="/workspace/hfdl"; mkdir -p "$TMP"

get() {  # repo  repo_path  dest_dir
    local base; base="$(basename "$2")"
    if [ -f "$3/$base" ]; then echo "SKIP (exists) $base"; return; fi
    echo ">>> downloading $base"
    if hf download "$1" "$2" --local-dir "$TMP" >/dev/null 2>&1 && [ -f "$TMP/$2" ]; then
        mv "$TMP/$2" "$3/$base" && echo "OK   $base ($(du -h "$3/$base" | cut -f1))"
    else
        echo "FAIL $1 :: $2"
    fi
}

# (diffusion model = fp8 canonical, fetched by dl_models.sh — not re-downloaded here)
# clip_vision_h — lives in the 2.1 repo, not 2.2
get "Comfy-Org/Wan_2.1_ComfyUI_repackaged" "split_files/clip_vision/clip_vision_h.safetensors" "$M/clip_vision"
# ViTPose-H external weight data (.bin) — must sit next to the .onnx graph
get "Kijai/vitpose_comfy" "onnx/vitpose_h_wholebody_data.bin" "$M/detection"

echo "=== FIX DOWNLOADS DONE ==="
echo "--- detection dir (onnx must have its .bin) ---"; ls -la "$M/detection"
echo "--- key models ---"; du -sh "$M/diffusion_models"/* "$M/clip_vision"/* 2>/dev/null
rm -rf "$TMP"

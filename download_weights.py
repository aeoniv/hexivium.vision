#!/usr/bin/env python3
import os
import sys
from pathlib import Path
from huggingface_hub import hf_hub_download

PIPELINE_ROOT = Path(os.environ.get("PIPELINE_ROOT", "/opt/qi-pipeline"))
COMFYUI_DIR = PIPELINE_ROOT / "engines" / "ComfyUI"
MODELS_DIR = COMFYUI_DIR / "models"

models_to_download = [
    {
        "repo_id": "Kijai/WanVideo_comfy",
        "filename": "Fun/Wan2.1-Fun-Control-14B_fp8_e4m3fn.safetensors",
        "local_dir": MODELS_DIR / "diffusion_models",
        "name": "Wan 2.1 Fun Control 14B (FP8)",
        "rename_to": "wan2.1_fun_control_14B_fp8.safetensors"
    },
    {
        "repo_id": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
        "filename": "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
        "local_dir": MODELS_DIR / "text_encoders",
        "name": "UMT5-XXL Text Encoder (FP8)"
    },
    {
        "repo_id": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
        "filename": "split_files/vae/wan_2.1_vae.safetensors",
        "local_dir": MODELS_DIR / "vae",
        "name": "Wan 2.1 VAE"
    },
    {
        "repo_id": "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
        "filename": "split_files/clip_vision/clip_vision_h.safetensors",
        "local_dir": MODELS_DIR / "clip_vision",
        "name": "CLIP Vision H"
    },
    {
        "repo_id": "lithiumice/models_hub",
        "filename": "4_SMPLhub/SMPL/X_pkl/SMPL_FEMALE.pkl",
        "local_dir": PIPELINE_ROOT / "engines" / "WHAM" / "data" / "smpl",
        "name": "SMPL Female Model",
        "rename_to": "SMPL_FEMALE.pkl"
    },
    {
        "repo_id": "lithiumice/models_hub",
        "filename": "4_SMPLhub/SMPL/X_pkl/SMPL_MALE.pkl",
        "local_dir": PIPELINE_ROOT / "engines" / "WHAM" / "data" / "smpl",
        "name": "SMPL Male Model",
        "rename_to": "SMPL_MALE.pkl"
    },
    {
        "repo_id": "lithiumice/models_hub",
        "filename": "4_SMPLhub/SMPL/X_pkl/SMPL_NEUTRAL.pkl",
        "local_dir": PIPELINE_ROOT / "engines" / "WHAM" / "data" / "smpl",
        "name": "SMPL Neutral Model",
        "rename_to": "SMPL_NEUTRAL.pkl"
    }
]

def main():
    print("==========================================")
    print("Downloading weights via Python HF Hub API")
    print("==========================================")
    
    for item in models_to_download:
        dest_dir = item["local_dir"]
        dest_dir.mkdir(parents=True, exist_ok=True)
        filename = Path(item["filename"]).name
        rename_to = item.get("rename_to")
        dest_file = dest_dir / (rename_to if rename_to else filename)
        
        if dest_file.exists() and dest_file.stat().st_size > 1024 * 1024:
            print(f"[i] {item['name']} already exists at {dest_file}. Skipping.")
            continue
            
        print(f"[*] Downloading {item['name']}...")
        try:
            downloaded_path = hf_hub_download(
                repo_id=item["repo_id"],
                filename=item["filename"],
                local_dir=str(dest_dir),
                local_dir_use_symlinks=False
            )
            if rename_to:
                downloaded_file = Path(downloaded_path)
                target_file = dest_dir / rename_to
                if downloaded_file.exists() and downloaded_file != target_file:
                    if target_file.exists():
                        target_file.unlink()
                    downloaded_file.rename(target_file)
            print(f"[✓] Successfully downloaded {item['name']}")
        except Exception as e:
            print(f"[!] Error downloading {item['name']}: {e}", file=sys.stderr)
            sys.exit(1)

    print("==========================================")
    print("All downloads completed successfully!")
    print("==========================================")

if __name__ == "__main__":
    main()

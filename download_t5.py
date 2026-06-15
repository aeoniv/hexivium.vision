from huggingface_hub import hf_hub_download
from pathlib import Path

repo_id = "Kijai/WanVideo_comfy"
filename = "umt5-xxl-enc-fp8_e4m3fn.safetensors"
local_dir = Path("/opt/qi-pipeline/engines/ComfyUI/models/text_encoders")

print(f"Downloading {filename} from {repo_id} to {local_dir}...")
try:
    # Use hf_hub_download with local_dir and local_dir_use_symlinks=False
    # To keep things clean, hf_hub_download puts files directly in local_dir.
    downloaded_path = hf_hub_download(
        repo_id=repo_id,
        filename=filename,
        local_dir=str(local_dir),
        local_dir_use_symlinks=False
    )
    print(f"Successfully downloaded: {downloaded_path}")
except Exception as e:
    print(f"Error downloading: {e}")
    import sys
    sys.exit(1)

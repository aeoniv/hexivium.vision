import subprocess
from pathlib import Path

req_path = Path("/opt/qi-pipeline/engines/WHAM/requirements.txt")
print(f"Reading requirements from {req_path}...")
content = req_path.read_text()

# Replace original chumpy with chumpy-fork
old_chumpy = "chumpy @ git+https://github.com/mattloper/chumpy"
new_chumpy = "chumpy-fork"
if old_chumpy in content:
    print("Found original chumpy, replacing with chumpy-fork...")
    content = content.replace(old_chumpy, new_chumpy)
else:
    print("Original chumpy not found in requirements (already replaced or custom).")

# Replace mmcv==1.3.9 with mmcv>=2.0.0
old_mmcv = "mmcv==1.3.9"
new_mmcv = "mmcv>=2.0.0"
if old_mmcv in content:
    print("Found mmcv==1.3.9, replacing with mmcv>=2.0.0...")
    content = content.replace(old_mmcv, new_mmcv)
else:
    print("mmcv==1.3.9 not found in requirements.")

req_path.write_text(content)

# Run pip install
print("Running pip install on corrected requirements...")
subprocess.run([
    "/opt/miniconda3/envs/qi-pipeline/bin/pip", "install", "-r", str(req_path)
], check=True)
print("WHAM requirements successfully installed!")

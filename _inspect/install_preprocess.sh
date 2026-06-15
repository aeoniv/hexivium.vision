#!/usr/bin/env bash
# Install kijai/ComfyUI-WanAnimatePreprocess (PoseAndFaceDetection etc.)
source /opt/miniconda3/etc/profile.d/conda.sh
conda activate qi-pipeline
CN=/opt/qi-pipeline/engines/ComfyUI/custom_nodes
cd "$CN"
if [ ! -d ComfyUI-WanAnimatePreprocess ]; then
  git clone https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git
fi
cd ComfyUI-WanAnimatePreprocess
if [ -f requirements.txt ]; then pip install -q -r requirements.txt; fi
echo "=== node mappings ==="
grep -rhoE '\"[A-Za-z0-9_]+\"\s*:' nodes.py 2>/dev/null | sort -u | head -30
echo "=== onnx model handling (where do vitpose/yolo live?) ==="
grep -rniE 'onnx|vitpose|yolov10|models/|folder_paths|hf_hub|download_url|snapshot_download' nodes.py 2>/dev/null | head -30
echo "=== README hints ==="
grep -iE 'onnx|vitpose|yolo|download|huggingface|model' README*.md 2>/dev/null | head -20

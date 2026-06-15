#!/usr/bin/env bash
# Download ViTPose + YOLO ONNX detectors into ComfyUI/models/detection
source /opt/miniconda3/etc/profile.d/conda.sh
conda activate qi-pipeline
M=/opt/qi-pipeline/engines/ComfyUI/models
mkdir -p "$M/detection" /tmp/det

echo "[det] $(date -Iseconds) yolov10m.onnx..."
hf download Wan-AI/Wan2.2-Animate-14B process_checkpoint/det/yolov10m.onnx --local-dir /tmp/det \
  && cp /tmp/det/process_checkpoint/det/yolov10m.onnx "$M/detection/" || echo "[det] FAILED yolo"

echo "[det] $(date -Iseconds) vitpose-l-wholebody.onnx..."
hf download JunkyByte/easy_ViTPose onnx/wholebody/vitpose-l-wholebody.onnx --local-dir /tmp/det \
  && cp /tmp/det/onnx/wholebody/vitpose-l-wholebody.onnx "$M/detection/" || echo "[det] FAILED vitpose"

echo "[det] DONE"; ls -la "$M/detection/"

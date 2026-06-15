#!/usr/bin/env python3
"""
Stage 3 — Structural Landmark Preprocessing (ControlNet-Aux)
=============================================================
Converts abstract 3D movement renders into dense pixel conditions that
spatial neural networks can read frame-by-frame.

  Map A (DensePose): Continuous 3D coordinate mesh over bare torso, defining
    absolute skin boundaries to prevent anatomy hallucination.
  Map B (DWPose): High-frequency coordinates for finger/palm redirection
    loops — vital for mapping active Tai Chi energy extensions.

Engine:  controlnet_aux (Fannovel16)
Input:   Rendered PNG frames from Stage 2
Output:  Multi-channel RGB guidance frames (DensePose + DWPose)
"""

import argparse
import json
import logging
import os
import sys
from pathlib import Path
from typing import Optional

import cv2
import numpy as np
from PIL import Image

logging.basicConfig(
    level=logging.INFO,
    format="[Stage3] %(asctime)s %(levelname)s — %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("stage3")

PIPELINE_ROOT = Path(os.environ.get("PIPELINE_ROOT", "/opt/qi-pipeline"))
OUTPUT_DIR = PIPELINE_ROOT / "output"


def init_densepose_detector():
    """Initialize DensePose detector from controlnet_aux."""
    try:
        import sys
        sys.path.insert(0, "/opt/qi-pipeline/engines/ComfyUI/custom_nodes/comfyui_controlnet_aux/src")
        from custom_controlnet_aux.densepose import DenseposeDetector
        detector = DenseposeDetector.from_pretrained(filename="densepose_r50_fpn_dl.torchscript")
        log.info("DensePose detector initialized")
        return detector
    except ImportError:
        log.error(
            "controlnet_aux not installed. Install via: "
            "pip install controlnet_aux"
        )
        sys.exit(1)
    except Exception as e:
        log.error(f"Failed to initialize DensePose detector: {e}")
        sys.exit(1)


def init_dwpose_detector():
    """Initialize DWPose detector from controlnet_aux."""
    try:
        import sys
        if "/opt/qi-pipeline/engines/ComfyUI/custom_nodes/comfyui_controlnet_aux/src" not in sys.path:
            sys.path.insert(0, "/opt/qi-pipeline/engines/ComfyUI/custom_nodes/comfyui_controlnet_aux/src")
        from custom_controlnet_aux.dwpose import DwposeDetector
        detector = DwposeDetector.from_pretrained(
            "hr16/DWPose-TorchScript-BatchSize5",
            "yzd-v/DWPose",
            det_filename="yolox_l.onnx",
            pose_filename="dw-ll_ucoco_384_bs5.torchscript.pt",
            torchscript_device="cpu"
        )
        log.info("DWPose detector initialized")
        return detector
    except ImportError:
        log.error("DWposeDetector not available in controlnet_aux")
        sys.exit(1)
    except Exception as e:
        log.error(f"Failed to initialize DWPose detector: {e}")
        sys.exit(1)


def process_frame_densepose(
    detector,
    image: Image.Image,
    resolution: int = 1024,
) -> Image.Image:
    """
    Map A — DensePose Surface Mapping.

    Apply a continuous 3D coordinate mesh over the bare torso. This defines
    the absolute boundaries of the skin, forcing the generation engine to
    respect human anatomy limits.
    """
    result = detector(image, detect_resolution=resolution, image_resolution=resolution)
    return result


def process_frame_dwpose(
    detector,
    image: Image.Image,
    resolution: int = 1024,
) -> Image.Image:
    """
    Map B — DWPose High-Frequency Keypoints.

    Isolate high-frequency coordinates for finger and palm redirection loops.
    Critical for mapping active Tai Chi energy extensions through hand forms.
    """
    result = detector(image, detect_resolution=resolution, image_resolution=resolution)
    return result


def composite_guidance_frame(
    densepose_map: Image.Image,
    dwpose_map: Image.Image,
) -> Image.Image:
    """
    Combine DensePose and DWPose into a single multi-channel guidance frame.

    Strategy: DensePose provides the body surface context (primary control),
    DWPose overlays high-frequency hand/finger details on top.
    """
    dp = np.array(densepose_map)
    dw = np.array(dwpose_map)

    # Ensure same dimensions
    if dp.shape != dw.shape:
        dw = cv2.resize(dw, (dp.shape[1], dp.shape[0]))

    # Composite: use DWPose where it has signal (non-black pixels)
    mask = np.any(dw > 10, axis=2) if dw.ndim == 3 else dw > 10
    composite = dp.copy()
    composite[mask] = dw[mask]

    return Image.fromarray(composite)


def main():
    parser = argparse.ArgumentParser(description="Stage 3: ControlNet Preprocessing")
    parser.add_argument(
        "--frames", "-f",
        type=Path,
        required=True,
        help="Directory containing rendered PNG frames from Stage 2",
    )
    parser.add_argument(
        "--output-densepose",
        type=Path,
        default=OUTPUT_DIR / "controlnet_maps" / "densepose",
        help="Output directory for DensePose maps",
    )
    parser.add_argument(
        "--output-dwpose",
        type=Path,
        default=OUTPUT_DIR / "controlnet_maps" / "dwpose",
        help="Output directory for DWPose maps",
    )
    parser.add_argument(
        "--output-composite",
        type=Path,
        default=OUTPUT_DIR / "controlnet_maps" / "composite",
        help="Output directory for composited guidance frames",
    )
    parser.add_argument(
        "--resolution", "-r",
        type=int,
        default=1024,
        help="Processing resolution",
    )
    parser.add_argument(
        "--device",
        type=str,
        default="cuda",
        choices=["cuda", "cpu"],
        help="Compute device",
    )
    args = parser.parse_args()

    # Validate input
    if not args.frames.exists():
        log.error(f"Frames directory not found: {args.frames}")
        sys.exit(1)

    frame_files = sorted(args.frames.glob("*.png"))
    if not frame_files:
        log.error(f"No PNG frames found in {args.frames}")
        sys.exit(1)

    log.info(f"Found {len(frame_files)} frames in {args.frames}")

    # Create output directories
    args.output_densepose.mkdir(parents=True, exist_ok=True)
    args.output_dwpose.mkdir(parents=True, exist_ok=True)
    args.output_composite.mkdir(parents=True, exist_ok=True)

    # Initialize detectors
    log.info("Initializing detectors...")
    densepose_det = init_densepose_detector()
    dwpose_det = init_dwpose_detector()

    # Process frames
    log.info("Processing frames...")
    for i, frame_path in enumerate(frame_files):
        frame_name = frame_path.stem

        # Load frame
        image = Image.open(frame_path).convert("RGB")

        # Map A: DensePose
        dp_map = process_frame_densepose(densepose_det, image, args.resolution)
        dp_out = args.output_densepose / f"{frame_name}_densepose.png"
        dp_map.save(dp_out)

        # Map B: DWPose
        dw_map = process_frame_dwpose(dwpose_det, image, args.resolution)
        dw_out = args.output_dwpose / f"{frame_name}_dwpose.png"
        dw_map.save(dw_out)

        # Composite guidance frame
        composite = composite_guidance_frame(dp_map, dw_map)
        comp_out = args.output_composite / f"{frame_name}_guidance.png"
        composite.save(comp_out)

        # Progress logging
        if (i + 1) % 25 == 0 or (i + 1) == len(frame_files):
            log.info(f"Processed {i + 1}/{len(frame_files)} frames")

    # Write metadata
    metadata = {
        "stage": 3,
        "total_frames": len(frame_files),
        "resolution": args.resolution,
        "densepose_dir": str(args.output_densepose),
        "dwpose_dir": str(args.output_dwpose),
        "composite_dir": str(args.output_composite),
    }
    meta_path = OUTPUT_DIR / "stage3_metadata.json"
    meta_path.write_text(json.dumps(metadata, indent=2))

    log.info("=" * 60)
    log.info("Stage 3 complete.")
    log.info(f"  DensePose maps: {args.output_densepose}")
    log.info(f"  DWPose maps:    {args.output_dwpose}")
    log.info(f"  Composite:      {args.output_composite}")
    log.info(f"  Total frames:   {len(frame_files)}")
    log.info("=" * 60)


if __name__ == "__main__":
    main()

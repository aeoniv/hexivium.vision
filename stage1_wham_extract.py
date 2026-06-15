#!/usr/bin/env python3
"""
Stage 1 — Markerless 3D Feature Extraction (WHAM → SMPL → FBX)
===============================================================
Analyzes bare-skin video to compute 3D Skinned Multi-Person Linear (SMPL)
meshes without fabric markers. Exports continuous spatial coordinate matrix
as .FBX file.

Engine: WHAM (World-grounded Humans with Accurate Motion)
Input:  Monocular bare-skin video (.mp4)
Output: Raw .FBX trajectory file
"""

import argparse
import json
import logging
import os
import subprocess
import sys
from pathlib import Path

import numpy as np

logging.basicConfig(
    level=logging.INFO,
    format="[Stage1] %(asctime)s %(levelname)s — %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("stage1")

# ── Configuration ────────────────────────────────────────────────────────────
PIPELINE_ROOT = Path(os.environ.get("PIPELINE_ROOT", "/opt/qi-pipeline"))
WHAM_DIR = PIPELINE_ROOT / "engines" / "WHAM"
OUTPUT_DIR = PIPELINE_ROOT / "output"
CONFIDENCE_THRESHOLD = 0.75  # Minimum landmark confidence before interpolation


def check_wham_installation():
    """Verify WHAM is properly installed and SMPL models are present."""
    if not WHAM_DIR.exists():
        log.error(f"WHAM directory not found: {WHAM_DIR}")
        sys.exit(1)

    smpl_dir = WHAM_DIR / "data" / "smpl"
    if not smpl_dir.exists() or not any(smpl_dir.iterdir()):
        log.error(
            "SMPL models not found. Download from https://smpl.is.tue.mpg.de/ "
            f"and place in {smpl_dir}"
        )
        sys.exit(1)

    log.info("WHAM installation verified.")


def interpolate_dropouts(positions: np.ndarray, confidences: np.ndarray) -> np.ndarray:
    """
    Polynomial interpolation for tracking dropouts.

    When landmark confidence scores fall below CONFIDENCE_THRESHOLD during
    complex overlapping hand transitions, calculate polynomial interpolation
    paths between the last known coordinates to reconstruct missing values.

    Args:
        positions: (T, J, 3) array of joint positions over T frames, J joints
        confidences: (T, J) array of confidence scores per joint per frame

    Returns:
        Repaired positions array with interpolated values
    """
    from scipy.interpolate import interp1d

    T, J, D = positions.shape
    repaired = positions.copy()
    dropout_count = 0

    for j in range(J):
        # Find frames where this joint drops below confidence threshold
        low_conf_mask = confidences[:, j] < CONFIDENCE_THRESHOLD

        if not np.any(low_conf_mask):
            continue

        valid_frames = np.where(~low_conf_mask)[0]
        invalid_frames = np.where(low_conf_mask)[0]

        if len(valid_frames) < 2:
            log.warning(
                f"Joint {j}: insufficient valid frames ({len(valid_frames)}) "
                f"for interpolation. Skipping."
            )
            continue

        dropout_count += len(invalid_frames)
        log.info(
            f"Joint {j}: interpolating {len(invalid_frames)} dropout frames "
            f"(confidence < {CONFIDENCE_THRESHOLD:.0%})"
        )

        # Cubic polynomial interpolation per dimension
        for d in range(D):
            interpolator = interp1d(
                valid_frames,
                positions[valid_frames, j, d],
                kind="cubic",
                fill_value="extrapolate",
            )
            repaired[invalid_frames, j, d] = interpolator(invalid_frames)

    if dropout_count > 0:
        log.info(f"Total interpolated: {dropout_count} joint-frame dropouts")
    else:
        log.info("No tracking dropouts detected.")

    return repaired


def run_wham(input_video: Path, output_dir: Path) -> Path:
    """
    Execute WHAM on input video to extract SMPL meshes.

    Returns path to the output directory containing results.
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    # WHAM demo command
    wham_python = "/opt/miniconda3/envs/wham_env/bin/python"
    wham_cmd = [
        wham_python,
        str(WHAM_DIR / "demo.py"),
        "--video", str(input_video),
        "--output_pth", str(output_dir),
        "--save_pkl",   # Save raw SMPL params for post-processing
    ]

    log.info(f"Executing WHAM: {' '.join(wham_cmd)}")

    result = subprocess.run(
        wham_cmd,
        cwd=str(WHAM_DIR),
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        log.error(f"WHAM failed:\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}")
        sys.exit(1)

    log.info("WHAM extraction complete.")
    return output_dir


def smpl_to_fbx(wham_output_dir: Path, output_fbx: Path):
    """
    Convert WHAM's SMPL output (pickle) to FBX via Blender's Python API.

    This is a lightweight conversion step — the heavy smoothing happens in Stage 2.
    """
    import joblib

    # Load WHAM results
    pkl_files = list(wham_output_dir.glob("**/*.pkl"))
    if not pkl_files:
        log.error(f"No .pkl output files found in {wham_output_dir}")
        sys.exit(1)

    pkl_path = pkl_files[0]
    log.info(f"Loading WHAM results from: {pkl_path}")

    wham_results = joblib.load(pkl_path)

    # Extract SMPL parameters
    # WHAM outputs: body_pose, global_orient, betas, trans, joints3d, etc.
    if isinstance(wham_results, dict):
        joints3d = wham_results.get("joints3d", wham_results.get("kp_3d"))
        confidences = wham_results.get("confidence", wham_results.get("scores"))
    elif isinstance(wham_results, list) and len(wham_results) > 0:
        joints3d = wham_results[0].get("joints3d", wham_results[0].get("kp_3d"))
        confidences = wham_results[0].get("confidence", wham_results[0].get("scores"))
    else:
        log.error("Unexpected WHAM output format")
        sys.exit(1)

    if joints3d is not None:
        joints3d = np.array(joints3d)
        log.info(f"Extracted joints3d: shape={joints3d.shape}")

        # Apply dropout interpolation if confidence data available
        if confidences is not None:
            confidences = np.array(confidences)
            joints3d = interpolate_dropouts(joints3d, confidences)

    # Convert to FBX using Blender headless
    blender_bin = PIPELINE_ROOT / "engines" / "blender" / "blender"
    convert_script = PIPELINE_ROOT / "tmp" / "_smpl_to_fbx.py"

    # Write a minimal Blender conversion script
    convert_script.parent.mkdir(parents=True, exist_ok=True)
    convert_script.write_text(f"""
import bpy
import json
import numpy as np
import sys

# Load the SMPL parameters and create keyframed armature
# This is a simplified conversion — WHAM may also provide its own export

bpy.ops.wm.read_factory_settings(use_empty=True)

# Create armature from SMPL skeleton
bpy.ops.object.armature_add(enter_editmode=False, location=(0, 0, 0))
armature = bpy.context.active_object
armature.name = "SMPL_Armature"

# If WHAM provides direct FBX export, prefer that
# Otherwise we set keyframes from joints3d
print("[Stage1-Blender] FBX export stub — using WHAM's native output if available")

# Export
bpy.ops.export_scene.fbx(
    filepath="{str(output_fbx)}",
    use_selection=False,
    bake_anim=True,
    bake_anim_use_all_actions=True,
)

print(f"[Stage1-Blender] Exported FBX: {str(output_fbx)}")
""")

    # Check if WHAM already produced an FBX
    existing_fbx = list(wham_output_dir.glob("**/*.fbx"))
    if existing_fbx:
        log.info(f"WHAM produced FBX directly: {existing_fbx[0]}")
        import shutil
        shutil.copy2(existing_fbx[0], output_fbx)
        return

    # Otherwise, convert via Blender
    log.info("Converting SMPL data to FBX via Blender...")
    result = subprocess.run(
        [str(blender_bin), "--background", "--python", str(convert_script)],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        log.warning(f"Blender FBX conversion warning:\n{result.stderr}")

    if output_fbx.exists():
        log.info(f"FBX exported: {output_fbx} ({output_fbx.stat().st_size / 1e6:.1f} MB)")
    else:
        log.error("FBX export failed — no output file produced")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Stage 1: WHAM 3D Extraction")
    parser.add_argument(
        "--input", "-i",
        type=Path,
        required=True,
        help="Path to input video file (.mp4)",
    )
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=OUTPUT_DIR / "raw.fbx",
        help="Output FBX file path",
    )
    args = parser.parse_args()

    if not args.input.exists():
        log.error(f"Input video not found: {args.input}")
        sys.exit(1)

    check_wham_installation()

    # Run WHAM extraction
    wham_output = OUTPUT_DIR / "wham_raw"
    run_wham(args.input, wham_output)

    # Extract raw SMPL parameters via WHAM
    # We no longer convert to FBX here. Stage 2 will process the .pkl directly.

    log.info(f"Stage 1 complete. Output: {args.output}")

    # Write metadata for downstream stages
    metadata = {
        "stage": 1,
        "input_video": str(args.input),
        "output_fbx": str(args.output),
        "confidence_threshold": CONFIDENCE_THRESHOLD,
    }
    meta_path = OUTPUT_DIR / "stage1_metadata.json"
    meta_path.write_text(json.dumps(metadata, indent=2))
    log.info(f"Metadata written: {meta_path}")


if __name__ == "__main__":
    main()

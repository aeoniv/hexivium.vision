#!/usr/bin/env python3
"""
Stage 2 — Kinetic Flow & Biomechanical Stabilization
=======================================================================
Tai Chi requires uninterrupted, slow, deliberate momentum. This stage:
  1. Loads raw SMPL vertices from WHAM
  2. Applies Non-Linear Gaussian smooth filter to ALL 3D vertices temporally
  3. Enforces absolute ground boundary (lowest vertex Z >= 0)
  4. Generates an OBJ sequence
  5. Renders each frame as PNG using headless Blender

Engine:  SciPy + Headless Blender
Input:   wham_output.pkl
Output:  Rendered frame sequence + OBJ sequence
"""

import sys
import os
import argparse
from pathlib import Path
import json
import subprocess
import shutil

# Monkeypatch inspect.getargspec for Python 3.11 compatibility (required by chumpy/chumpy-fork)
import inspect
from collections import namedtuple
if not hasattr(inspect, 'getargspec'):
    ArgSpec = namedtuple('ArgSpec', ['args', 'varargs', 'keywords', 'defaults'])
    def getargspec(func):
        full = inspect.getfullargspec(func)
        return ArgSpec(full.args, full.varargs, full.varkw, full.defaults)
    inspect.ArgSpec = ArgSpec
    inspect.getargspec = getargspec

import joblib
import numpy as np
from scipy.ndimage import gaussian_filter1d

# SMPL neutral face data location
SMPL_MODEL_PATH = "/opt/qi-pipeline/engines/WHAM/dataset/body_models/smpl/SMPL_NEUTRAL.pkl"

def load_smpl_faces(pkl_path):
    import sys
    try:
        import chumpy_fork as chumpy
    except ImportError:
        try:
            import chumpy
        except ImportError:
            chumpy = None
    if chumpy is not None:
        sys.modules['chumpy'] = chumpy

    import pickle
    with open(pkl_path, 'rb') as f:
        # SMPL model pkl uses latin1 encoding
        data = pickle.load(f, encoding='latin1')
    return data['f']

def main():
    parser = argparse.ArgumentParser(description="Stage 2: Mathematical Kinematic Stabilization")
    parser.add_argument("--input-dir", "-i", required=True, help="Path to wham_raw directory")
    parser.add_argument("--output-frames", default=None, help="Output rendered frames directory")
    parser.add_argument("--output-obj", default=None, help="Output OBJ sequence directory")
    parser.add_argument("--sigma", type=float, default=2.0, help="Gaussian filter sigma")
    parser.add_argument("--render-resolution-x", type=int, default=1024, help="Render width")
    parser.add_argument("--render-resolution-y", type=int, default=1024, help="Render height")
    
    # Parse only arguments after '--' when run from Blender
    if "--" in sys.argv:
        args_list = sys.argv[sys.argv.index("--") + 1:]
    else:
        args_list = sys.argv[1:]
    args = parser.parse_args(args_list)

    PIPELINE_ROOT = Path(os.environ.get("PIPELINE_ROOT", "/opt/qi-pipeline"))
    OUTPUT_DIR = PIPELINE_ROOT / "output"

    output_frames = Path(args.output_frames) if args.output_frames else OUTPUT_DIR / "renders"
    output_obj = Path(args.output_obj) if args.output_obj else OUTPUT_DIR / "obj_sequence"

    print("=" * 60)
    print(f"[Stage2] Mathematical Stabilization — sigma={args.sigma}")
    print("=" * 60)

    # 1. LOAD DATA
    input_dir = Path(args.input_dir)
    pkl_files = list(input_dir.glob("**/*.pkl"))
    if not pkl_files:
        print(f"[Stage2] ERROR: No .pkl found in {input_dir}")
        sys.exit(1)

    pkl_path = pkl_files[0]
    print(f"[Stage2] Loading WHAM results: {pkl_path}")
    wham_data = joblib.load(pkl_path)
    
    # Extract verts
    first_key = list(wham_data.keys())[0]
    verts = wham_data[first_key]['verts']  # Shape: (Frames, 6890, 3)
    num_frames = verts.shape[0]
    print(f"[Stage2] Extracted vertices: {verts.shape}")

    # Load Faces
    print(f"[Stage2] Loading SMPL faces from: {SMPL_MODEL_PATH}")
    faces = load_smpl_faces(SMPL_MODEL_PATH)
    
    # 2. GAUSSIAN SMOOTHING
    print(f"[Stage2] Applying Gaussian smooth filter (σ={args.sigma}) to all vertices temporally...")
    smoothed_verts = gaussian_filter1d(verts, sigma=args.sigma, axis=0)
    
    # 3. FLOOR LOCK
    print("[Stage2] Enforcing floor lock (lowest vertex Z >= 0)...")
    for f in range(num_frames):
        lowest_z = np.min(smoothed_verts[f, :, 2])
        if lowest_z < 0:
            smoothed_verts[f, :, 2] -= lowest_z
            
    # 4. EXPORT OBJ SEQUENCE
    output_obj.mkdir(parents=True, exist_ok=True)
    print(f"[Stage2] Exporting {num_frames} OBJ files to {output_obj}...")
    
    # Faces are 0-indexed in SMPL, OBJ format expects 1-indexed
    faces_1 = faces + 1
    
    obj_files = []
    for f in range(num_frames):
        obj_path = output_obj / f"frame_{f:06d}.obj"
        obj_files.append(obj_path)
        with open(obj_path, 'w') as out:
            # Write vertices
            for v in smoothed_verts[f]:
                out.write(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
            # Write faces
            for face in faces_1:
                out.write(f"f {face[0]} {face[1]} {face[2]}\n")
        
        if f % 50 == 0 or f == num_frames - 1:
            print(f"  Exported {f}/{num_frames - 1}")

    # 5. RENDER FRAMES WITH BLENDER
    output_frames.mkdir(parents=True, exist_ok=True)
    print(f"[Stage2] Rendering frames to {output_frames} using Blender headless...")
    
    blender_bin = PIPELINE_ROOT / "engines" / "blender" / "blender"
    blender_script = PIPELINE_ROOT / "tmp" / "_render_obj_sequence.py"
    
    blender_script.write_text(f"""
import bpy
import os

# Clean scene
bpy.ops.wm.read_factory_settings(use_empty=True)

# Add camera
bpy.ops.object.camera_add(location=(0, -3, 1), rotation=(1.57, 0, 0))
scene = bpy.context.scene
scene.camera = bpy.context.active_object

# Add lighting
bpy.ops.object.light_add(type='SUN', location=(5, -5, 10))

# Render Settings
scene.render.resolution_x = {args.render_resolution_x}
scene.render.resolution_y = {args.render_resolution_y}
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGB'
scene.render.film_transparent = True
scene.render.engine = 'CYCLES'  # Use Cycles for better depth if needed, or Eevee
scene.cycles.device = 'GPU'

obj_dir = "{str(output_obj)}"
out_dir = "{str(output_frames)}"
num_frames = {num_frames}

for f in range(num_frames):
    # Import OBJ
    obj_path = os.path.join(obj_dir, f"frame_{{f:06d}}.obj")
    
    # In Blender 4.x, import_scene.obj is deprecated, use import_scene.wavefront_obj
    try:
        bpy.ops.wm.obj_import(filepath=obj_path)
    except AttributeError:
        # Fallback for older blender
        bpy.ops.import_scene.obj(filepath=obj_path)
        
    imported_objects = [obj for obj in bpy.context.selected_objects if obj.type == 'MESH']
    
    # Assign a simple principled BSDF material
    mat = bpy.data.materials.new(name="SMPL_Mat")
    mat.use_nodes = True
    if imported_objects:
        imported_objects[0].data.materials.append(mat)
        
    # Render
    frame_path = os.path.join(out_dir, f"frame_{{f:06d}}.png")
    scene.render.filepath = frame_path
    bpy.ops.render.render(write_still=True)
    
    # Delete the imported object to keep scene clean
    bpy.ops.object.delete()

    if f % 50 == 0 or f == num_frames - 1:
        print(f"[Stage2-Blender] Rendered frame {{f}}/{{num_frames-1}}")
""")

    print(f"[Stage2] Launching Blender...")
    result = subprocess.run(
        [str(blender_bin), "--background", "--python", str(blender_script)],
        capture_output=True,
        text=True,
    )
    
    if result.returncode != 0:
        print("[Stage2] WARNING: Blender render failed or had warnings:")
        print(result.stderr)
        sys.exit(1)
        
    print("=" * 60)
    print("[Stage2] Kinematic stabilization complete.")
    print(f"  OBJ Sequence: {output_obj}")
    print(f"  Rendered PNGs: {output_frames}")
    print("=" * 60)

    # Write success marker
    success_marker = PIPELINE_ROOT / "tmp" / "stage2_success"
    success_marker.parent.mkdir(parents=True, exist_ok=True)
    success_marker.write_text("SUCCESS")

if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Stage 4 — Neural Rendering & Energy Fields Injection (ComfyUI API)
==================================================================
Launches ComfyUI in headless server mode, submits the Wan 2.1 Fun Control
workflow via REST API, and collects output frames → ffmpeg encodes to .mp4.

Engine:  ComfyUI + Wan 2.1 Fun Control 14B (FP8)
Input:   DensePose/DWPose guidance frames + character reference image
Output:  Production-ready .mp4 video
"""

import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

import websocket  # pip install websocket-client

logging.basicConfig(
    level=logging.INFO,
    format="[Stage4] %(asctime)s %(levelname)s — %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("stage4")

PIPELINE_ROOT = Path(os.environ.get("PIPELINE_ROOT", "/opt/qi-pipeline"))
OUTPUT_DIR = PIPELINE_ROOT / "output"
COMFYUI_DIR = PIPELINE_ROOT / "engines" / "ComfyUI"
COMFYUI_HOST = "127.0.0.1"
COMFYUI_PORT = 8188

# ── VRAM Overflow Protocol ───────────────────────────────────────────────────
# If VRAM threatens to overflow during 14B sampling, these degradation levels
# are applied automatically via ComfyUI's built-in memory management:
#   Level 1: Enable sequential_cpu_offload
#   Level 2: Switch to FP8 attention (already default)
#   Level 3: Switch to NF4 quantization if available
VRAM_SAFETY_MARGIN_GB = 2.0  # Keep at least 2GB free


def start_comfyui_server(output_dir: Path) -> subprocess.Popen:
    """Start ComfyUI headless server as a background process."""
    log.info(f"Starting ComfyUI server at {COMFYUI_HOST}:{COMFYUI_PORT} with output directory {output_dir}")

    env = os.environ.copy()
    # Force ComfyUI to use dynamic VRAM management
    env["COMFYUI_VRAM_MODE"] = "auto"

    log_file_path = COMFYUI_DIR / "user" / "comfyui_server.log"
    log_file_path.parent.mkdir(parents=True, exist_ok=True)
    log_file = open(log_file_path, "w", encoding="utf-8", errors="ignore")
    log.info(f"Redirecting ComfyUI stdout/stderr to {log_file_path}")

    proc = subprocess.Popen(
        [
            sys.executable,
            str(COMFYUI_DIR / "main.py"),
            "--listen", COMFYUI_HOST,
            "--port", str(COMFYUI_PORT),
            "--dont-print-server",
            "--output-directory", str(output_dir),
        ],
        cwd=str(COMFYUI_DIR),
        env=env,
        stdout=log_file,
        stderr=log_file,
    )

    # Wait for server to be ready
    max_retries = 120  # 2 minutes (model loading can be slow)
    for i in range(max_retries):
        try:
            url = f"http://{COMFYUI_HOST}:{COMFYUI_PORT}/system_stats"
            with urllib.request.urlopen(url, timeout=2) as resp:
                if resp.status == 200:
                    stats = json.loads(resp.read().decode())
                    log.info(f"ComfyUI server ready. System stats: {json.dumps(stats, indent=2)}")
                    proc.log_file = log_file
                    return proc
        except Exception:
            if proc.poll() is not None:
                log_file.close()
                try:
                    crash_log = log_file_path.read_text(encoding="utf-8", errors="ignore")
                except Exception:
                    crash_log = "Could not read comfyui_server.log"
                log.error(f"ComfyUI crashed during startup:\n{crash_log}")
                sys.exit(1)
            time.sleep(1)

    log.error("ComfyUI server failed to start within 2 minutes")
    log_file.close()
    proc.kill()
    sys.exit(1)


def load_workflow(workflow_path: Path) -> dict:
    """Load and return the ComfyUI workflow JSON."""
    if not workflow_path.exists():
        log.error(f"Workflow file not found: {workflow_path}")
        sys.exit(1)

    with open(workflow_path) as f:
        workflow = json.load(f)

    log.info(f"Loaded workflow: {workflow_path} ({len(workflow)} nodes)")
    return workflow


def inject_dynamic_paths(
    workflow: dict,
    reference_image: Path,
    controlnet_maps_dir: Path,
    output_dir: Path,
) -> dict:
    """Inject runtime paths into the workflow JSON."""

    for node_id, node in workflow.items():
        class_type = node.get("class_type", "")
        inputs = node.get("inputs", {})

        # Inject reference image path
        if class_type in ("LoadImage", "VHS_LoadImage"):
            if "image" in inputs:
                inputs["image"] = str(reference_image)
                log.info(f"Node {node_id} ({class_type}): set image → {reference_image}")

        # Inject controlnet maps directory
        if class_type in ("VHS_LoadImages", "LoadImageSequence"):
            if "directory" in inputs:
                inputs["directory"] = str(controlnet_maps_dir)
                log.info(f"Node {node_id} ({class_type}): set directory → {controlnet_maps_dir}")

        # Inject output path
        if class_type in ("SaveImage", "VHS_VideoCombine", "SaveAnimatedWEBP"):
            if "filename_prefix" in inputs:
                inputs["filename_prefix"] = "qi_render"
                log.info(f"Node {node_id} ({class_type}): set output prefix to 'qi_render' in output directory {output_dir}")

    return workflow


def queue_prompt(workflow: dict, client_id: str = "qi-pipeline") -> str:
    """Submit workflow to ComfyUI via REST API. Returns prompt_id."""
    payload = json.dumps({
        "prompt": workflow,
        "client_id": client_id,
    }).encode("utf-8")

    req = urllib.request.Request(
        f"http://{COMFYUI_HOST}:{COMFYUI_PORT}/prompt",
        data=payload,
        headers={"Content-Type": "application/json"},
    )

    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read().decode())

    prompt_id = result.get("prompt_id")
    if not prompt_id:
        log.error(f"Failed to queue prompt: {result}")
        sys.exit(1)

    log.info(f"Prompt queued: {prompt_id}")
    return prompt_id


def wait_for_completion(prompt_id: str, client_id: str = "qi-pipeline"):
    """
    Wait for workflow completion via WebSocket.
    Monitors progress and handles VRAM overflow conditions.
    """
    ws_url = f"ws://{COMFYUI_HOST}:{COMFYUI_PORT}/ws?clientId={client_id}"
    log.info(f"Connecting to WebSocket: {ws_url}")

    ws = websocket.WebSocket()
    ws.connect(ws_url)

    try:
        while True:
            raw = ws.recv()
            if isinstance(raw, str):
                msg = json.loads(raw)
                msg_type = msg.get("type", "")
                data = msg.get("data", {})

                if msg_type == "progress":
                    value = data.get("value", 0)
                    maximum = data.get("max", 0)
                    if maximum > 0:
                        pct = (value / maximum) * 100
                        log.info(f"Progress: {value}/{maximum} ({pct:.0f}%)")

                elif msg_type == "executing":
                    node_id = data.get("node")
                    if node_id is None:
                        # Execution complete
                        log.info("Workflow execution complete.")
                        break
                    else:
                        log.info(f"Executing node: {node_id}")

                elif msg_type == "execution_error":
                    error_msg = data.get("exception_message", "Unknown error")
                    log.error(f"Execution error: {error_msg}")

                    # VRAM Overflow handling
                    if "out of memory" in error_msg.lower() or "oom" in error_msg.lower():
                        log.warning(
                            "VRAM overflow detected. Reduce video length or "
                            "switch to NF4 quantization in the workflow JSON."
                        )

                    # Fail loudly: do NOT continue to collect_outputs / encode_video,
                    # which would silently ship a stale video from a previous run.
                    raise RuntimeError(f"ComfyUI render failed: {error_msg}")

                elif msg_type == "execution_cached":
                    log.info(f"Using cached results for {len(data.get('nodes', []))} nodes")

    finally:
        ws.close()


def _wait_until_stable(path: Path, timeout: float = 120.0, settle: float = 2.0) -> bool:
    """Wait until a file exists and its size stops growing (write finished)."""
    deadline = time.time() + timeout
    last_size = -1
    stable_since = None
    while time.time() < deadline:
        if path.exists():
            size = path.stat().st_size
            if size == last_size and size > 0:
                if stable_since is None:
                    stable_since = time.time()
                elif time.time() - stable_since >= settle:
                    return True
            else:
                stable_since = None
                last_size = size
        time.sleep(0.5)
    return path.exists() and path.stat().st_size > 0


def collect_outputs(prompt_id: str, output_dir: Path) -> list:
    """
    Locate this run's output files.

    ComfyUI writes outputs DIRECTLY into our --output-directory, so we read them
    from disk rather than re-downloading over HTTP (which races the still-writing
    file and previously truncated the video). We only use the history API to learn
    the filenames, and wait for each to finish writing before returning.
    """
    collected_files = []
    try:
        url = f"http://{COMFYUI_HOST}:{COMFYUI_PORT}/history/{prompt_id}"
        with urllib.request.urlopen(url, timeout=30) as resp:
            history = json.loads(resp.read().decode())
        outputs = history.get(prompt_id, {}).get("outputs", {})
    except Exception as e:
        log.warning(f"Could not read history API ({e}); falling back to disk scan.")
        outputs = {}

    for node_id, node_output in outputs.items():
        for item in node_output.get("images", []) + node_output.get("gifs", []):
            filename = item.get("filename")
            subfolder = item.get("subfolder", "")
            local = (output_dir / subfolder / filename) if subfolder else (output_dir / filename)

            if local.exists():
                _wait_until_stable(local)
                collected_files.append(local)
                log.info(f"Collected (local): {local} ({local.stat().st_size} bytes)")
                continue

            # Fallback: fetch over HTTP with retries (only if not written locally).
            item_type = item.get("type", "output")
            src_url = (
                f"http://{COMFYUI_HOST}:{COMFYUI_PORT}/view?"
                f"filename={urllib.parse.quote(filename)}"
                f"&subfolder={urllib.parse.quote(subfolder)}"
                f"&type={item_type}"
            )
            for attempt in range(3):
                try:
                    urllib.request.urlretrieve(src_url, str(local))
                    collected_files.append(local)
                    log.info(f"Collected (http): {local}")
                    break
                except Exception as e:
                    log.warning(f"Fetch attempt {attempt + 1} for {filename} failed: {e}")
                    time.sleep(2)

    # Belt-and-suspenders: if history gave us nothing, grab whatever video is on disk.
    if not any(str(f).endswith((".mp4", ".webm")) for f in collected_files):
        for vid in list(output_dir.glob("*.mp4")) + list(output_dir.glob("*.webm")):
            _wait_until_stable(vid)
            collected_files.append(vid)
            log.info(f"Collected (disk scan): {vid} ({vid.stat().st_size} bytes)")

    return collected_files


def encode_video(frames_dir: Path, output_mp4: Path, fps: int = 24):
    """Encode output frames into final .mp4 using ffmpeg."""
    log.info(f"Encoding video: {output_mp4} (fps={fps})")

    # Check if ComfyUI already produced a video. ComfyUI's frame counter never
    # resets, so this dir can hold videos from earlier runs — always pick the
    # NEWEST by modification time, never an arbitrary glob order.
    existing_videos = list(frames_dir.glob("*.mp4")) + list(frames_dir.glob("*.webm"))
    if existing_videos:
        newest = max(existing_videos, key=lambda p: p.stat().st_mtime)
        log.info(f"Using ComfyUI-generated video: {newest}")
        shutil.copy2(newest, output_mp4)
        return

    # Otherwise, encode from frame sequence
    frame_pattern = str(frames_dir / "qi_render_%05d_.png")

    cmd = [
        "ffmpeg", "-y",
        "-framerate", str(fps),
        "-i", frame_pattern,
        "-c:v", "libx264",
        "-preset", "slow",
        "-crf", "18",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        str(output_mp4),
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        log.warning(f"ffmpeg warning: {result.stderr}")

    if output_mp4.exists():
        size_mb = output_mp4.stat().st_size / 1e6
        log.info(f"Video encoded: {output_mp4} ({size_mb:.1f} MB)")
    else:
        log.error("Video encoding failed")


def main():
    parser = argparse.ArgumentParser(description="Stage 4: ComfyUI Neural Render")
    parser.add_argument(
        "--workflow", "-w",
        type=Path,
        required=True,
        help="Path to ComfyUI workflow JSON",
    )
    parser.add_argument(
        "--reference-image",
        type=Path,
        default=PIPELINE_ROOT / "input" / "reference_image.png",
        help="Aesthetic character reference image",
    )
    parser.add_argument(
        "--controlnet-maps",
        type=Path,
        default=OUTPUT_DIR / "controlnet_maps" / "composite",
        help="Directory of DensePose/DWPose guidance frames",
    )
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=OUTPUT_DIR / "final.mp4",
        help="Output video path",
    )
    parser.add_argument(
        "--fps", type=int, default=24,
        help="Keyframe framerate — the rate the diffusion model renders at "
             "(= source clip length / keyframe count). RIFE upsamples this.",
    )
    parser.add_argument(
        "--target-fps", type=int, default=int(os.environ.get("TARGET_FPS", 30)),
        help="Desired smooth playback fps. RIFE interpolates the rendered "
             "keyframes up to this rate; duration is preserved.",
    )
    parser.add_argument(
        "--gen-width", type=int, default=int(os.environ.get("GEN_W", 832)),
        help="Generation width (should match the source aspect ratio).",
    )
    parser.add_argument(
        "--gen-height", type=int, default=int(os.environ.get("GEN_H", 480)),
        help="Generation height (should match the source aspect ratio).",
    )
    parser.add_argument(
        "--riflex-index", type=int, default=int(os.environ.get("RIFLEX_FREQ_INDEX", 0)),
        help="RIFLEx positional-frequency index. 0 = off (native <=81 frames). "
             "Set 4-6 only when extending beyond the native length (Phase 2).",
    )
    parser.add_argument(
        "--block-swap", type=int, default=int(os.environ.get("BLOCK_SWAP", 0)),
        help="Number of transformer blocks to offload to CPU — frees VRAM at the "
             "cost of speed. 0 = disabled (default).",
    )
    args = parser.parse_args()

    # Validate inputs
    if not args.reference_image.exists():
        log.error(f"Reference image not found: {args.reference_image}")
        sys.exit(1)

    if not args.controlnet_maps.exists():
        log.error(f"ControlNet maps directory not found: {args.controlnet_maps}")
        sys.exit(1)

    # Create output directories
    render_output = OUTPUT_DIR / "comfyui_output"
    render_output.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)

    # Remove any stale final video from a previous run so a failed render
    # can never masquerade as success (no old video gets re-uploaded).
    if args.output.exists():
        args.output.unlink()
        log.info(f"Cleared stale output: {args.output}")

    # ComfyUI's frame counter never resets, so previous runs' renders accumulate
    # here and can get picked up as "this run's" output. Clear them each run.
    for stale in list(render_output.glob("*.mp4")) + \
                 list(render_output.glob("*.webm")) + \
                 list(render_output.glob("*.png")):
        stale.unlink()

    # Load and configure workflow
    workflow = load_workflow(args.workflow)
    workflow = inject_dynamic_paths(
        workflow,
        args.reference_image,
        args.controlnet_maps,
        render_output,
    )

    # ── Reconcile video length with the driving frames ──────────────────────
    # Wan-Animate renders the WHOLE driving performance via context windows, so
    # there is no 81-frame single-pass ceiling — we use every extracted frame.
    # VRAM is bounded by frame_window_size (set on WanVideoAnimateEmbeds), not by
    # the total length. MAX_FRAMES is just a sanity guard against runaway clips.
    MAX_FRAMES = int(os.environ.get("ANIMATE_MAX_FRAMES", 1000))
    FRAME_WINDOW = int(os.environ.get("ANIMATE_FRAME_WINDOW", 77))
    available = len(sorted(args.controlnet_maps.glob("*.png")))
    if available == 0:
        log.error(f"No driving frames in {args.controlnet_maps}")
        sys.exit(1)

    requested = int(workflow.get("24", {}).get("inputs", {}).get("num_frames", available))
    # Use all available frames (cap only if absurdly long); ignore the workflow's
    # placeholder num_frames — the driving clip length is authoritative.
    target = max(1, min(available, MAX_FRAMES))

    # Load all driving frames; set the output length to the same count.
    workflow["20"]["inputs"]["image_load_cap"] = 0          # VHS_LoadImages (0 = all)
    workflow["24"]["inputs"]["num_frames"] = target          # WanVideoAnimateEmbeds
    # Context window: render in overlapping windows so VRAM stays bounded.
    workflow["24"]["inputs"]["frame_window_size"] = min(FRAME_WINDOW, target)

    # ── Inject generation dimensions (match source aspect — no letterboxing) ──
    gen_w = (int(args.gen_width) // 16) * 16
    gen_h = (int(args.gen_height) // 16) * 16
    for node in workflow.values():
        ct = node.get("class_type")
        ins = node.setdefault("inputs", {})
        if ct in ("ImageScale", "PoseAndFaceDetection", "DrawViTPose", "WanVideoAnimateEmbeds"):
            if "width" in ins or ct in ("PoseAndFaceDetection", "DrawViTPose", "WanVideoAnimateEmbeds", "ImageScale"):
                ins["width"] = gen_w
                ins["height"] = gen_h
    log.info(f"Generation size set to {gen_w}x{gen_h}; frame_window_size={workflow['24']['inputs']['frame_window_size']}.")

    # ── Frame interpolation (RIFE): smooth low-fps keyframes up to target_fps ───
    # The diffusion pass renders `target` keyframes spanning the whole clip at a
    # base rate of `args.fps`. For long clips that base rate is low (choppy). RIFE
    # synthesizes intermediate frames so the final video plays smoothly at
    # ~target_fps WITHOUT changing its duration (= keyframe_count / base_fps).
    base_fps = max(1, int(args.fps))
    target_fps = max(base_fps, int(args.target_fps))
    multiplier = max(1, min(4, round(target_fps / base_fps)))

    if base_fps < 6:
        log.warning(
            f"Keyframe rate is only {base_fps} fps — the source is long enough that "
            f"interpolation will look soft. For long clips at full density, use "
            f"context windows / segment-stitch (Phase 2)."
        )

    if multiplier <= 1:
        # Keyframe rate already meets the target — bypass RIFE entirely so the
        # output node reads straight from the VAE decode (node 40).
        playback_fps = base_fps
        for node in workflow.values():
            if node.get("class_type") == "VHS_VideoCombine":
                node.setdefault("inputs", {})["images"] = ["40", 0]
                node["inputs"]["frame_rate"] = base_fps
        log.info(
            f"Keyframe rate {base_fps} fps already ≥ target {target_fps} — "
            f"skipping interpolation."
        )
    else:
        playback_fps = base_fps * multiplier
        rife_found = False
        for node in workflow.values():
            if node.get("class_type") == "RIFE VFI":
                node.setdefault("inputs", {})["multiplier"] = multiplier
                rife_found = True
            if node.get("class_type") == "VHS_VideoCombine":
                node.setdefault("inputs", {})["frame_rate"] = playback_fps
        if rife_found:
            log.info(
                f"RIFE interpolation: {base_fps} fps × {multiplier} = {playback_fps} fps "
                f"playback ({target} keyframes → ~{target * multiplier} frames)."
            )
        else:
            # Workflow lacks a RIFE node — degrade gracefully to base-fps playback.
            playback_fps = base_fps
            for node in workflow.values():
                if node.get("class_type") == "VHS_VideoCombine":
                    node.setdefault("inputs", {})["images"] = ["40", 0]
                    node["inputs"]["frame_rate"] = base_fps
            log.warning("No 'RIFE VFI' node in workflow — output stays at base fps.")

    # ── RIFLEx: extend temporal positional encoding for longer-than-native runs ─
    if args.riflex_index:
        for node in workflow.values():
            if node.get("class_type") == "WanVideoSampler":
                node.setdefault("inputs", {})["riflex_freq_index"] = args.riflex_index
        log.info(f"RIFLEx enabled: riflex_freq_index={args.riflex_index}")

    # ── Block swap: offload transformer blocks to CPU to free VRAM ──────────────
    if args.block_swap > 0:
        loader_id = next(
            (nid for nid, n in workflow.items()
             if n.get("class_type") == "WanVideoModelLoader"),
            None,
        )
        if loader_id:
            swap_id = "61"
            workflow[swap_id] = {
                "class_type": "WanVideoBlockSwap",
                "_meta": {"title": "Block Swap (VRAM offload)"},
                "inputs": {
                    "blocks_to_swap": args.block_swap,
                    "offload_img_emb": False,
                    "offload_txt_emb": False,
                },
            }
            workflow[loader_id].setdefault("inputs", {})["block_swap_args"] = [swap_id, 0]
            log.info(f"Block swap enabled: {args.block_swap} blocks offloaded to CPU.")
        else:
            log.warning("Block swap requested but no WanVideoModelLoader found.")

    log.info(
        f"Rendering {target} driving frames at {gen_w}x{gen_h} "
        f"(window={workflow['24']['inputs']['frame_window_size']}) → {playback_fps} fps playback."
    )

    # Start ComfyUI server
    server_proc = start_comfyui_server(render_output)

    try:
        # Submit workflow
        prompt_id = queue_prompt(workflow)

        # Wait for completion
        wait_for_completion(prompt_id)

        # Collect outputs
        output_files = collect_outputs(prompt_id, render_output)
        log.info(f"Collected {len(output_files)} output files")

        # Encode final video
        encode_video(render_output, args.output, args.fps)

    finally:
        # Always terminate ComfyUI server
        log.info("Shutting down ComfyUI server...")
        server_proc.terminate()
        try:
            server_proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server_proc.kill()
        
        # Close log file
        if hasattr(server_proc, "log_file"):
            try:
                server_proc.log_file.close()
            except Exception:
                pass

    # Write metadata
    metadata = {
        "stage": 4,
        "output_video": str(args.output),
        "workflow": str(args.workflow),
        "reference_image": str(args.reference_image),
        "controlnet_maps": str(args.controlnet_maps),
        "keyframes": target,
        "base_fps": base_fps,
        "playback_fps": playback_fps,
        "interpolation_multiplier": multiplier,
        "riflex_index": args.riflex_index,
        "block_swap": args.block_swap,
    }
    meta_path = OUTPUT_DIR / "stage4_metadata.json"
    meta_path.write_text(json.dumps(metadata, indent=2))

    log.info("=" * 60)
    log.info("Stage 4 complete.")
    log.info(f"  Output: {args.output}")
    log.info("=" * 60)


if __name__ == "__main__":
    main()

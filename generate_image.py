#!/usr/bin/env python3
"""
Reference Avatar Generation (text-to-image, ComfyUI / SDXL)
===========================================================
Generates a single still image from a text prompt and saves it as the pipeline's
reference avatar. The output is intended to feed Stage 4 (Wan-Animate), so the
default prompt aims for a clean, full-body, neutral-pose subject on a plain
background — the framing Wan-Animate handles best.

Engine:  ComfyUI + SDXL (CheckpointLoaderSimple → KSampler → VAEDecode → SaveImage)
Output:  PNG saved to --output (default: <PIPELINE_ROOT>/input/reference_image.png)
"""

import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import websocket  # pip install websocket-client

logging.basicConfig(
    level=logging.INFO,
    format="[GenImage] %(asctime)s %(levelname)s — %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("genimage")

PIPELINE_ROOT = Path(os.environ.get("PIPELINE_ROOT", "/opt/qi-pipeline"))
COMFYUI_DIR = Path(os.environ.get("COMFYUI_DIR", str(PIPELINE_ROOT / "engines" / "ComfyUI")))
COMFYUI_HOST = "127.0.0.1"
COMFYUI_PORT = 8188


def start_comfyui_server(output_dir: Path) -> subprocess.Popen:
    """Start ComfyUI headless and wait until it answers /system_stats."""
    log.info(f"Starting ComfyUI at {COMFYUI_HOST}:{COMFYUI_PORT}")
    log_path = COMFYUI_DIR / "user" / "comfyui_genimage.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_file = open(log_path, "w", encoding="utf-8", errors="ignore")
    proc = subprocess.Popen(
        [sys.executable, str(COMFYUI_DIR / "main.py"),
         "--listen", COMFYUI_HOST, "--port", str(COMFYUI_PORT),
         "--dont-print-server", "--output-directory", str(output_dir)],
        cwd=str(COMFYUI_DIR), stdout=log_file, stderr=log_file,
    )
    for _ in range(120):
        try:
            with urllib.request.urlopen(
                f"http://{COMFYUI_HOST}:{COMFYUI_PORT}/system_stats", timeout=2
            ) as resp:
                if resp.status == 200:
                    log.info("ComfyUI ready.")
                    proc.log_file = log_file
                    return proc
        except Exception:
            if proc.poll() is not None:
                log_file.close()
                log.error("ComfyUI crashed during startup:\n" +
                          log_path.read_text(encoding="utf-8", errors="ignore"))
                sys.exit(1)
            time.sleep(1)
    log.error("ComfyUI did not start within 2 minutes")
    proc.kill()
    sys.exit(1)


def queue_prompt(workflow: dict, client_id: str = "qi-genimage") -> str:
    payload = json.dumps({"prompt": workflow, "client_id": client_id}).encode()
    req = urllib.request.Request(
        f"http://{COMFYUI_HOST}:{COMFYUI_PORT}/prompt",
        data=payload, headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read().decode())
    pid = result.get("prompt_id")
    if not pid:
        log.error(f"Failed to queue prompt: {result}")
        sys.exit(1)
    log.info(f"Prompt queued: {pid}")
    return pid


def wait_for_completion(client_id: str = "qi-genimage"):
    ws = websocket.WebSocket()
    ws.connect(f"ws://{COMFYUI_HOST}:{COMFYUI_PORT}/ws?clientId={client_id}")
    try:
        while True:
            raw = ws.recv()
            if not isinstance(raw, str):
                continue
            msg = json.loads(raw)
            t = msg.get("type", "")
            data = msg.get("data", {})
            if t == "progress":
                v, m = data.get("value", 0), data.get("max", 0)
                if m:
                    log.info(f"Progress: {v}/{m} ({v / m * 100:.0f}%)")
            elif t == "executing" and data.get("node") is None:
                log.info("Generation complete.")
                break
            elif t == "execution_error":
                raise RuntimeError(f"ComfyUI error: {data.get('exception_message')}")
    finally:
        ws.close()


def main():
    ap = argparse.ArgumentParser(description="Generate a reference avatar (SDXL).")
    ap.add_argument("--workflow", type=Path, required=True)
    ap.add_argument("--prompt", type=str, default="")
    ap.add_argument("--negative", type=str, default="")
    ap.add_argument("--output", type=Path,
                    default=PIPELINE_ROOT / "input" / "reference_image.png")
    ap.add_argument("--width", type=int, default=768)
    ap.add_argument("--height", type=int, default=1344)
    ap.add_argument("--steps", type=int, default=30)
    ap.add_argument("--cfg", type=float, default=7.0)
    ap.add_argument("--seed", type=int, default=int(time.time()) % 2_000_000_000)
    ap.add_argument("--init-image", type=Path, default=None,
                    help="Optional reference image → img2img (pair with an img2img workflow).")
    ap.add_argument("--denoise", type=float, default=0.65,
                    help="img2img denoise strength (lower = closer to the reference).")
    args = ap.parse_args()

    with open(args.workflow) as f:
        wf = json.load(f)

    # Inject parameters (node ids match workflows/txt2img_sdxl.json)
    if args.prompt:
        wf["2"]["inputs"]["text"] = args.prompt
    if args.negative:
        wf["3"]["inputs"]["text"] = args.negative
    W, H = (args.width // 8) * 8, (args.height // 8) * 8
    if "4" in wf:                                   # EmptyLatentImage (txt2img only)
        wf["4"]["inputs"]["width"], wf["4"]["inputs"]["height"] = W, H
    wf["5"]["inputs"].update({"steps": args.steps, "cfg": args.cfg, "seed": args.seed})

    # img2img: stage the reference into ComfyUI's input dir, point LoadImage at it,
    # size the canvas, and apply the denoise strength.
    if args.init_image and Path(args.init_image).exists():
        comfy_input = COMFYUI_DIR / "input"
        comfy_input.mkdir(parents=True, exist_ok=True)
        dest = comfy_input / f"qi_init{Path(args.init_image).suffix or '.png'}"
        shutil.copy2(args.init_image, dest)
        if "10" in wf:
            wf["10"]["inputs"]["image"] = dest.name
        if "11" in wf:
            wf["11"]["inputs"]["width"], wf["11"]["inputs"]["height"] = W, H
        wf["5"]["inputs"]["denoise"] = args.denoise
        log.info(f"img2img from {dest.name} → {W}x{H} "
                 f"(denoise={args.denoise}, steps={args.steps}, cfg={args.cfg}, seed={args.seed})")
    else:
        log.info(f"Generating {W}x{H} (steps={args.steps}, cfg={args.cfg}, seed={args.seed})")

    out_dir = PIPELINE_ROOT / "output" / "genimage"
    out_dir.mkdir(parents=True, exist_ok=True)
    for stale in out_dir.glob("*.png"):
        stale.unlink()

    server = start_comfyui_server(out_dir)
    try:
        queue_prompt(wf)
        wait_for_completion()
        time.sleep(1)  # let SaveImage flush to disk
        pngs = sorted(out_dir.glob("*.png"), key=lambda p: p.stat().st_mtime)
        if not pngs:
            log.error("No image produced.")
            sys.exit(1)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(pngs[-1], args.output)
        log.info(f"Saved reference avatar → {args.output} "
                 f"({args.output.stat().st_size} bytes)")
    finally:
        log.info("Shutting down ComfyUI...")
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
        if hasattr(server, "log_file"):
            try:
                server.log_file.close()
            except Exception:
                pass


if __name__ == "__main__":
    main()

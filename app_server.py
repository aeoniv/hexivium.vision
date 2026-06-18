import os
import re
import sys
import json
import subprocess
import threading
from pathlib import Path
from typing import Optional
from fastapi import FastAPI, File, UploadFile, HTTPException, Form
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="Qi Kinematic Director Orchestrator")

# Enable CORS for local testing
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

PIPELINE_ROOT = Path(os.environ.get("PIPELINE_ROOT", "/opt/qi-pipeline"))
INPUT_DIR = PIPELINE_ROOT / "input"
OUTPUT_DIR = PIPELINE_ROOT / "output"
LOG_FILE = PIPELINE_ROOT / "pipeline_run.log"

# Global state for tracking running pipeline thread
pipeline_thread: Optional[threading.Thread] = None
pipeline_process: Optional[subprocess.Popen] = None
pipeline_running = False

# Global state for the avatar (text-to-image) generator
avatar_thread: Optional[threading.Thread] = None
avatar_status = {"running": False, "ready": False, "error": "", "log": ""}


def generate_avatar_worker(prompt: str, negative: str, init_image: Optional[str] = None):
    """Run generate_image.py to produce the reference avatar. With `init_image` it
    runs SDXL img2img (a new variation of the reference); otherwise text-to-image."""
    global avatar_status
    avatar_status = {"running": True, "ready": False, "error": "", "log": ""}
    env = os.environ.copy()
    env["PIPELINE_ROOT"] = str(PIPELINE_ROOT)

    # Use the SAME interpreter that runs this server so the subprocess inherits
    # torch/CUDA/etc. img2img when a reference image was provided, else txt2img.
    workflow = "img2img_sdxl.json" if init_image else "txt2img_sdxl.json"
    cmd = [
        sys.executable, str(PIPELINE_ROOT / "scripts" / "generate_image.py"),
        "--workflow", str(PIPELINE_ROOT / "scripts" / "workflows" / workflow),
        "--output", str(INPUT_DIR / "reference_image.png"),
    ]
    if prompt:
        cmd += ["--prompt", prompt]
    if negative:
        cmd += ["--negative", negative]
    if init_image:
        cmd += ["--init-image", init_image]

    try:
        result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=900)
        avatar_status["log"] = (result.stdout or "")[-2000:] + (result.stderr or "")[-2000:]
        if result.returncode == 0 and (INPUT_DIR / "reference_image.png").exists():
            avatar_status["ready"] = True
        else:
            avatar_status["error"] = "Avatar generation failed — see log."
    except Exception as e:
        avatar_status["error"] = str(e)
    finally:
        avatar_status["running"] = False

def run_pipeline_worker(
    sigma: float,
    steps: int,
    cfg: float,
    num_frames: int,
    prompt: str,
    negative_prompt: str,
    target_fps: int,
    mode: str,
):
    global pipeline_running, pipeline_process
    pipeline_running = True

    # Apply the UI's parameters to a PER-RUN COPY of the mode's workflow, leaving
    # the canonical workflow pristine (so it never drifts from the repo). The copy
    # path is passed to the pipeline via WORKFLOW_PATH.
    WORKFLOWS = {
        "animate": "workflows/wan_animate.json",
        "funcontrol": "workflows/fun_control.json",
    }
    canonical_workflow = PIPELINE_ROOT / "scripts" / WORKFLOWS.get(mode, WORKFLOWS["animate"])
    active_workflow = PIPELINE_ROOT / "tmp" / "workflow_active.json"
    workflow_ready = False
    if canonical_workflow.exists():
        try:
            with open(canonical_workflow, 'r') as f:
                wf = json.load(f)

            # Sampler (Node 30). Wan-Animate runs on the lightx2v 6-step distill LoRA,
            # which REQUIRES ~6 steps / cfg 1 — any other values degrade it badly. Force
            # the canonical distill config for animate regardless of UI input; funcontrol
            # (no distill) keeps the UI's steps/cfg.
            if "30" in wf and "inputs" in wf["30"]:
                if mode == "animate":
                    wf["30"]["inputs"]["steps"] = 6
                    wf["30"]["inputs"]["cfg"] = 1.0
                else:
                    wf["30"]["inputs"]["steps"] = steps
                    wf["30"]["inputs"]["cfg"] = cfg

            # Update prompt in WanVideoTextEncode (Node 10)
            if "10" in wf and "inputs" in wf["10"]:
                if prompt:
                    wf["10"]["inputs"]["positive_prompt"] = prompt
                if negative_prompt:
                    wf["10"]["inputs"]["negative_prompt"] = negative_prompt

            # Update video length in WanVideoImageToVideoEncode (Node 24)
            if "24" in wf and "inputs" in wf["24"]:
                wf["24"]["inputs"]["num_frames"] = num_frames

            active_workflow.parent.mkdir(parents=True, exist_ok=True)
            with open(active_workflow, 'w') as f:
                json.dump(wf, f, indent=2)
            workflow_ready = True
            print(f"[Backend] Wrote per-run workflow → {active_workflow} "
                  f"(steps={steps}, cfg={cfg}, num_frames={num_frames}, prompt_len={len(prompt)})")
        except Exception as e:
            print(f"[Backend] Error preparing workflow JSON: {e}")

    # Run run_pipeline.sh with SKIP_SHUTDOWN=1 and output logging to LOG_FILE
    env = os.environ.copy()
    env["SKIP_SHUTDOWN"] = "1"
    env["PIPELINE_ROOT"] = str(PIPELINE_ROOT)
    env["TARGET_FPS"] = str(target_fps)
    env["PIPELINE_MODE"] = mode
    # Point the pipeline at the per-run workflow copy (falls back to the
    # canonical file inside run_pipeline.sh if preparation failed).
    if workflow_ready:
        env["WORKFLOW_PATH"] = str(active_workflow)
    
    # Clear the old log file
    if LOG_FILE.exists():
        try:
            LOG_FILE.unlink()
        except Exception:
            pass

    cmd = ["bash", str(PIPELINE_ROOT / "scripts" / "run_pipeline.sh")]
    try:
        pipeline_process = subprocess.Popen(
            cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )
        
        # Write logs to log file in real-time
        with open(LOG_FILE, "w") as log_f:
            for line in pipeline_process.stdout:
                log_f.write(line)
                log_f.flush()
                
        pipeline_process.wait()
    except Exception as e:
        with open(LOG_FILE, "a") as log_f:
            log_f.write(f"\n[BACKEND ERROR] Failed to execute pipeline: {e}\n")
    finally:
        pipeline_running = False
        pipeline_process = None

@app.post("/api/run")
def start_pipeline(
    sigma: float = Form(2.0),
    steps: int = Form(4),
    cfg: float = Form(1.0),
    num_frames: int = Form(49),
    target_fps: int = Form(30),
    mode: str = Form("animate"),
    prompt: str = Form(""),
    negative_prompt: str = Form("")
):
    global pipeline_thread, pipeline_running
    if pipeline_running:
        raise HTTPException(status_code=400, detail="Pipeline is already running.")

    if mode not in ("animate", "funcontrol"):
        mode = "animate"

    # Per-mode steps/CFG clamp — the two engines want opposite settings:
    #   animate    — lightx2v distill LoRA is tuned for ~4 steps at CFG 1; sending
    #                30 steps / CFG 5.5 makes renders ~15x slower AND degrades them.
    #   funcontrol — needs real guidance (CFG ~5) and full steps for the prompt.
    if mode == "animate":
        steps = max(2, min(int(steps), 12))
        cfg = max(1.0, min(float(cfg), 2.0))
    else:
        steps = max(15, min(int(steps), 50))
        cfg = max(2.0, min(float(cfg), 10.0))

    # Snap smoothness to a RIFE-friendly playback rate.
    ALLOWED_FPS = [24, 30, 48, 60]
    target_fps = min(ALLOWED_FPS, key=lambda v: abs(v - target_fps))

    pipeline_thread = threading.Thread(
        target=run_pipeline_worker,
        args=(sigma, steps, cfg, num_frames, prompt, negative_prompt, target_fps, mode),
        daemon=True
    )
    pipeline_thread.start()
    return {"status": "started"}

@app.post("/api/stop")
def stop_pipeline():
    global pipeline_process, pipeline_running
    if not pipeline_running or not pipeline_process:
        raise HTTPException(status_code=400, detail="Pipeline is not running.")
        
    try:
        pipeline_process.terminate()
        pipeline_process.wait(timeout=5)
    except Exception:
        if pipeline_process:
            pipeline_process.kill()
            
    pipeline_running = False
    pipeline_process = None
    return {"status": "stopped"}

@app.get("/api/status")
def get_status():
    global pipeline_running
    
    # Parse LOG_FILE to compute progress and status
    log_content = ""
    stage = "Idle"
    progress = 0.0
    sampler_step = ""
    error_detected = False
    
    if LOG_FILE.exists():
        try:
            with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
                log_content = "".join(lines[-100:])  # Last 100 lines
                
            # Parse stages
            for line in lines:
                if "STAGE 1: WHAM" in line:
                    stage = "WHAM (Stage 1)"
                    progress = 5.0
                elif "Stage 1 complete" in line:
                    progress = 25.0
                elif "STAGE 2: Blender" in line:
                    stage = "Blender Smoothing (Stage 2)"
                    progress = 30.0
                elif "Stage 2 complete" in line:
                    progress = 45.0
                elif "STAGE 3: ControlNet-Aux" in line:
                    stage = "ControlNet Preprocess (Stage 3)"
                    progress = 50.0
                elif "Stage 3 complete" in line:
                    progress = 60.0
                elif "STAGE 4: ComfyUI" in line:
                    stage = "Wan 2.1 Neural Render (Stage 4)"
                    progress = 65.0
                elif "Progress:" in line:
                    # Match sampler steps e.g. "Progress: 15/30 (50%)"
                    match = re.search(r"Progress:\s+(\d+)/(\d+)\s+\((\d+)%\)", line)
                    if match:
                        step, total, pct = match.groups()
                        # Ensure we are parsing the sampler progress bar, which has total = steps (usually 30)
                        # Avoid matching the T5 text encoder loading (which has total 1303)
                        if int(total) < 100:
                            sampler_step = f"{step}/{total} ({pct}%)"
                            # Map 65% - 98% based on sampler progress
                            progress = 65.0 + (float(pct) / 100.0) * 33.0
                elif "ALL STAGES COMPLETE" in line or "ALL STAGES COMPLETE" in line:
                    stage = "Complete"
                    progress = 100.0
                elif "FATAL: Pipeline failed" in line or "BACKEND ERROR" in line or "Execution error:" in line:
                    error_detected = True
                    stage = "Error"
        except Exception as e:
            log_content = f"Error reading logs: {e}"
            
    # Check if final video exists
    final_video_exists = (OUTPUT_DIR / "final.mp4").exists()
    if final_video_exists and stage == "Complete":
        progress = 100.0

    return {
        "running": pipeline_running,
        "stage": stage,
        "progress": round(progress, 1),
        "sampler_step": sampler_step,
        "error": error_detected,
        "logs": log_content,
        "video_available": final_video_exists
    }

@app.post("/api/upload-video")
async def upload_video(file: UploadFile = File(...)):
    INPUT_DIR.mkdir(parents=True, exist_ok=True)
    video_path = INPUT_DIR / "source_video.mp4"
    try:
        with open(video_path, "wb") as buffer:
            buffer.write(await file.read())
        return {"filename": file.filename, "status": "success"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/upload-image")
async def upload_image(file: UploadFile = File(...)):
    INPUT_DIR.mkdir(parents=True, exist_ok=True)
    image_path = INPUT_DIR / "reference_image.png"
    try:
        with open(image_path, "wb") as buffer:
            buffer.write(await file.read())
        return {"filename": file.filename, "status": "success"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/generate-avatar")
async def generate_avatar(prompt: str = Form(""), negative_prompt: str = Form(""),
                          init_image: UploadFile = File(None)):
    """Generate the reference avatar. With an `init_image` upload → SDXL img2img
    (a new variation of that reference); otherwise text-to-image."""
    global avatar_thread
    if avatar_status["running"]:
        raise HTTPException(status_code=400, detail="Avatar generation already running.")
    if pipeline_running:
        raise HTTPException(status_code=400, detail="A render is running — wait for it to finish.")
    init_path = None
    if init_image is not None and init_image.filename:
        INPUT_DIR.mkdir(parents=True, exist_ok=True)
        init_path = str(INPUT_DIR / "avatar_init_upload.png")
        with open(init_path, "wb") as f:
            f.write(await init_image.read())
    avatar_thread = threading.Thread(
        target=generate_avatar_worker,
        args=(prompt.strip(), negative_prompt.strip(), init_path), daemon=True,
    )
    avatar_thread.start()
    return {"status": "started", "mode": "img2img" if init_path else "txt2img"}

@app.get("/api/avatar-status")
def get_avatar_status():
    return avatar_status

@app.get("/input/reference_image.png")
def get_reference_image():
    img = INPUT_DIR / "reference_image.png"
    if not img.exists():
        raise HTTPException(status_code=404, detail="No reference image.")
    return FileResponse(img, media_type="image/png")

@app.get("/output/final.mp4")
def get_final_video():
    video_path = OUTPUT_DIR / "final.mp4"
    if not video_path.exists():
        raise HTTPException(status_code=404, detail="Video not found.")
    return FileResponse(video_path, media_type="video/mp4")

# Serve UI files
web_dir = Path(__file__).parent / "web"

@app.get("/")
def get_ui():
    html_file = web_dir / "index.html"
    if html_file.exists():
        return HTMLResponse(html_file.read_text())
    return HTMLResponse("<h1>Qi Orchestrator UI - Static files not found</h1>")

# Mount static directory for style.css and app.js
if web_dir.exists():
    app.mount("/static", StaticFiles(directory=str(web_dir)), name="static")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)

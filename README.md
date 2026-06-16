# Qi Pipeline Director

**Bio-Digital Kinematic Pipeline** — turns a performer video + a character image into neural video.

## Render Modes

The pipeline has two interchangeable render engines, selected with `PIPELINE_MODE`
(CLI) or the **Render Mode** dropdown in the web UI:

| Mode | Engine | What it does | Use it for |
|------|--------|--------------|------------|
| **`animate`** (default) | Wan2.2-Animate-14B | Faithfully **animates your reference photo** with the driving video's motion — identity preserved | Avatar/character animation |
| **`funcontrol`** | Wan2.1 Fun Control | **Generates a new subject from the text prompt**, steered by DensePose/DWPose pose maps | Stylized / prompt-driven generation (energy beings, creatures, restyles) |

Key differences (handled automatically per mode):

| | `animate` | `funcontrol` |
|---|---|---|
| Workflow | `workflows/wan_animate.json` | `workflows/fun_control.json` |
| Stage 3 (DensePose) | skipped (pose/face in-graph) | runs |
| Frame extraction | full motion, source aspect | ≤81 frames, 832×480 |
| Sampler | 4 steps / CFG 1 (lightx2v) | ~30 steps / CFG ~5.5 |

```bash
# CLI — animate (default)
sudo bash run_pipeline.sh
# CLI — fun control (stylized)
PIPELINE_MODE=funcontrol sudo -E bash run_pipeline.sh
```

The Architecture diagram below describes the `funcontrol` path; `animate` replaces
ControlNet-Aux + the Fun Control render with in-graph pose/face detection feeding Wan-Animate.

## Architecture

```
[ Raw Performer Video ] ──→ WHAM (3D SMPL Extraction)
                               │
  [ Cleaned Rig Trajectory ] ←── Headless Blender (Gaussian Smooth + Floor Lock)
                               │
  [ Multi-Channel Visual Maps ] ←── ControlNet-Aux (DensePose + DWPose)
                               │
[ Final Video ] ←── ComfyUI + Wan 2.1 14B FP8 (Neural Render)
```

## Infrastructure

| Component | Spec |
|-----------|------|
| Cloud | GCP Compute Engine |
| Machine | `g2-standard-8` (1× NVIDIA L4, 24 GB VRAM) |
| Disk | 300 GB PD-Balanced |
| Image | Ubuntu 22.04 + CUDA 12.4 (Deep Learning VM) |
| Zone | `asia-east1-b` (configurable) |

## Prerequisites

### 1. GCP Setup
```bash
# Authenticate
gcloud auth login

# Confirm project exists
gcloud projects describe hexivium-vision

# Check GPU quota (must have >= 1 NVIDIA_L4_GPUS in your zone)
gcloud compute regions describe asia-east1 --project=hexivium-vision \
    --format="table(quotas.filter(metric:NVIDIA_L4_GPUS))"
```

### 2. GCS Bucket
```bash
# Create bucket
gsutil mb -l asia-east1 gs://hexivium-vision-pipeline

# Upload SMPL models (requires registration at https://smpl.is.tue.mpg.de/)
gsutil cp -r ./smpl_data/* gs://hexivium-vision-pipeline/smpl_models/

# Upload input files
gsutil cp your_taichi_video.mp4 gs://hexivium-vision-pipeline/input/source_video.mp4
gsutil cp your_reference_image.png gs://hexivium-vision-pipeline/input/reference_image.png
```

### 3. SMPL Model License
WHAM requires official SMPL body model files. Register and download from:
- https://smpl.is.tue.mpg.de/
- Accept the non-commercial research license
- Upload the downloaded files to your GCS bucket

## Quick Start

### Deploy & Run
```bash
# 1. Upload pipeline scripts to GCS
gsutil cp startup.sh gs://hexivium-vision-pipeline/scripts/
gsutil cp stage1_wham_extract.py gs://hexivium-vision-pipeline/scripts/
gsutil cp stage2_blender_smooth.py gs://hexivium-vision-pipeline/scripts/
gsutil cp stage3_controlnet_preprocess.py gs://hexivium-vision-pipeline/scripts/
gsutil cp stage4_comfyui_render.py gs://hexivium-vision-pipeline/scripts/
gsutil cp workflow_qi_pipeline.json gs://hexivium-vision-pipeline/scripts/
gsutil cp run_pipeline.sh gs://hexivium-vision-pipeline/scripts/
gsutil cp cleanup_on_failure.sh gs://hexivium-vision-pipeline/scripts/
gsutil cp qi_idle_watchdog.sh gs://hexivium-vision-pipeline/scripts/
gsutil cp qi-idle-watchdog.service gs://hexivium-vision-pipeline/scripts/
gsutil cp qi-idle-watchdog.timer gs://hexivium-vision-pipeline/scripts/

# 2. Create VM (runs startup.sh automatically on first boot)
bash create-vm.sh

# 3. Wait for bootstrap (~15-20 min for first boot — downloads ~25GB of models)
gcloud compute ssh qi-pipeline-director --zone=asia-east1-b -- \
    'tail -f /var/log/qi-pipeline-bootstrap.log'

# 4. Run the pipeline
gcloud compute ssh qi-pipeline-director --zone=asia-east1-b -- \
    'sudo bash /opt/qi-pipeline/scripts/run_pipeline.sh'

# 5. VM auto-shuts-down after completion. Get results:
gsutil ls gs://hexivium-vision-pipeline/output/
gsutil cp gs://hexivium-vision-pipeline/output/final_*.mp4 ./
```

### Debug Mode (prevent auto-shutdown)
```bash
gcloud compute ssh qi-pipeline-director --zone=asia-east1-b -- \
    'SKIP_SHUTDOWN=1 sudo -E bash /opt/qi-pipeline/scripts/run_pipeline.sh'
```

## File Reference

| File | Purpose |
|------|---------|
| `create-vm.sh` | Provisions the GCP VM with GPU |
| `startup.sh` | One-time bootstrap: installs all software + downloads models |
| `stage1_wham_extract.py` | WHAM: video → 3D SMPL mesh → .FBX |
| `stage2_blender_smooth.py` | Blender headless: Gaussian smooth F-Curves + floor lock (Z≥0) |
| `stage3_controlnet_preprocess.py` | ControlNet-Aux: DensePose surface maps + DWPose finger keypoints |
| `stage4_comfyui_render.py` | ComfyUI headless API: Wan 2.1 14B neural render |
| `workflow_qi_pipeline.json` | ComfyUI workflow (API format) with exact parameters |
| `run_pipeline.sh` | Master orchestrator + auto-shutdown |
| `cleanup_on_failure.sh` | Error handler: diagnostics upload + emergency shutdown |

## Pipeline Parameters

### Stage 2 — Blender Smoothing
| Parameter | Default | Purpose |
|-----------|---------|---------|
| `--sigma` | 2.0 | Gaussian filter width (higher = smoother) |
| `--render-resolution-x` | 1024 | Frame render width |
| `--render-resolution-y` | 1024 | Frame render height |

### Stage 4 — Neural Rendering
| Parameter | Value | Purpose |
|-----------|-------|---------|
| Guidance Scale | 5.5 | Text conditioning strength |
| ControlNet Strength | 0.85 | DensePose adherence |
| ControlNet End | 0.90 | Release point for energy particle freedom |
| Steps | 30 | Diffusion sampling steps |
| Resolution | 832×480 | Output frame dimensions |
| Keyframe FPS | auto | Diffusion render rate (= clip length / ≤81 keyframes) |
| `TARGET_FPS` | 30 | Smooth playback rate; RIFE interpolates keyframes up to this |
| `RIFLEX_FREQ_INDEX` | 0 | >0 extends temporal encoding past the native 81-frame length |
| `BLOCK_SWAP` | 0 | >0 offloads transformer blocks to CPU to free VRAM (slower) |

## Error Handling

### Tracking Dropouts
When landmark confidence drops below 75% during complex hand transitions,
Stage 1 automatically applies cubic polynomial interpolation between last
known coordinates.

### VRAM Overflow
If the L4's 24 GB VRAM is exceeded during 14B sampling:
1. ComfyUI's dynamic VRAM management activates automatically
2. FP8 quantization is already enabled (reduces footprint ~50%)
3. If persistent, manually switch to NF4 in the workflow JSON

### Cost Protection
- VM auto-shuts-down immediately after the final video upload completes
- On any pipeline failure, the ERR trap uploads diagnostics and shuts down
- **Idle watchdog**: a systemd timer (`qi-idle-watchdog.timer`) stops the VM after
  ~30 min of no pipeline + idle GPU. This covers UI-launched runs that use
  `SKIP_SHUTDOWN=1` and would otherwise bill indefinitely. During a debug session,
  `touch /opt/qi-pipeline/.keep_alive` to opt out; `rm` it to re-arm.
- **SPOT by default**: `create-vm.sh` provisions a SPOT instance (~60-70% cheaper).
  Pass `bash create-vm.sh --on-demand` for an uninterruptible STANDARD VM.
- **Budget guardrail**: run `bash setup-budget.sh` once to create a monthly billing
  cap with alerts at 50/90/100%.
- Use `SKIP_SHUTDOWN=1` only during active debugging sessions

## Estimated Costs

| Resource | Rate (asia-east1) | Est. Duration | Est. Cost |
|----------|-------------------|---------------|-----------|
| g2-standard-8 | ~$0.85/hr | ~2-4 hrs | $1.70–$3.40 |
| NVIDIA L4 GPU | ~$0.70/hr | ~2-4 hrs | $1.40–$2.80 |
| 300 GB PD-Balanced | ~$0.10/GB/mo | Transient | ~$1.00 |
| **Total per run** | | | **~$4–$7** |

> With `--provisioning-model=SPOT`: ~60-70% cheaper → **~$1.50–$2.50/run**

## Longer & Smoother Videos

The diffusion model renders at most **81 keyframes** in one pass on an L4 (24 GB).
Those keyframes span the whole clip, so a longer source previously meant a
*choppier* result (fewer frames per second). Stage 4 now runs a **RIFE frame
interpolation** pass that synthesizes intermediate frames up to `TARGET_FPS`,
keeping the duration fixed but making playback fluid — which makes ~10–15 s clips
watchable instead of stuttery.

- **Motion Smoothness** (UI) / `TARGET_FPS` (env): playback rate the keyframes are
  interpolated up to (24 / 30 / 48 / 60). Duration is unchanged.
- For **true** longer-than-native sequences at full frame density (15 s+), set
  `RIFLEX_FREQ_INDEX=4..6` and use temporal context windows / segment-stitch
  (Phase 2 — not yet wired) and/or raise the frame ceiling with `BLOCK_SWAP` or a
  larger GPU (L40S 48 GB / A100).

```bash
# Example: render at a 60 fps smooth playback rate
TARGET_FPS=60 SKIP_SHUTDOWN=1 sudo -E bash /opt/qi-pipeline/scripts/run_pipeline.sh
```

## Notes

- **Wan 2.1** (open-weight) is used instead of Wan 2.7 (API-only/closed)
- The pipeline is designed for single-person Tai Chi sequences
- Multi-person support would require WHAM's multi-person mode
- Output length is locked to the source clip (≤81 diffusion keyframes); RIFE only
  changes smoothness, not duration. See **Longer & Smoother Videos** above.

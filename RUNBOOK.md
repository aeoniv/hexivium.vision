# Qi / Wan2.2-Animate — Operations Runbook

Self-hosted Wan2.2-Animate pipeline (photo-animate / video-to-video) on RunPod.

---

## 0. Key facts (this pod / session)

| Thing | Value |
|---|---|
| GPU | NVIDIA **A40 48 GB** (~$0.44/hr) |
| Region | RunPod **ca-mtl-1** (Montreal) |
| Pod ID | `fwwmbe22ka5xb9` |
| **Direct TCP SSH** (scp works) | `root@69.30.85.25 -p 22103` ⚠️ **IP + port CHANGE on every restart** |
| SSH key | `~/.ssh/id_ed25519` |
| UI (orchestrator) | port **8000** — NOT proxied → reach via SSH tunnel |
| Jupyter file browser (web) | `https://<POD_ID>-8888.proxy.runpod.net/?token=<TOKEN>` — exact link in Connect panel; ⚠️ POD_ID + token change each pod |
| Persistent volume | `/workspace` (survives stop/terminate; holds everything) |

> ⚠️ After any pod restart, get the **new** `IP:port` from the RunPod console → your pod → **Connect → "SSH over exposed TCP"**. Replace `69.30.85.25 -p 22103` everywhere below.

---

## 1. Start the app (after the pod is running)

SSH in and launch the UI server:
```bash
ssh root@69.30.85.25 -p 22103 -i ~/.ssh/id_ed25519
cd /workspace/qi-src && bash runpod_launch.sh
```
This deploys the scripts and starts the orchestrator on port 8000. ComfyUI is started automatically per render (you don't start it yourself).

---

## 2. Access the UI (from your Windows machine)

Open an SSH tunnel (leave this window open; it shows no output — that's normal):
```bash
ssh -N -L 8000:localhost:8000 root@69.30.85.25 -p 22103 -i ~/.ssh/id_ed25519
```
Then in your browser: **http://localhost:8000**

To stop the tunnel: `Ctrl+C` in that window.

---

## 3. Render a video

In the browser UI:
1. Upload a **driving video** (the motion) + a **reference image** (the avatar/photo).
2. Press **Launch**.
3. Watch the live log/progress. A full ~20 s clip takes **~45 min** at 720×1280 on the A40.

The pipeline auto-handles: portrait rotation, 720p sizing, 6-step distill, pose detection. No settings needed.

**Output:** `/workspace/qi/output/final.mp4` (overwritten each run — copy it aside to keep it).

---

## 4. See / download the files

**Easiest — JupyterLab file browser (in your browser):**

Address (open in a browser, no SSH needed):
```
https://<POD_ID>-8888.proxy.runpod.net/?token=<TOKEN>
```
- Get the **exact current link** from RunPod console → your pod → **Connect → HTTP Services → "Jupyter Lab" (port 8888)**. The `POD_ID` and `token` change every time you create/restart a pod, so copy it fresh each session.
- Example (old pod — yours will differ): `https://fwwmbe22ka5xb9-8888.proxy.runpod.net/?token=kpu7etq36b74ejdqvzws`
- Once open, use the left file tree → navigate to **`workspace/qi/output/`** (or `qi/output/` if it opens at `/workspace`). Right-click an `.mp4` → **Download**.

**Or via scp** (from your Windows machine):
```bash
scp -P 22103 -i ~/.ssh/id_ed25519 root@69.30.85.25:/workspace/qi/output/final.mp4 .
```

### Where everything lives
| What | Path |
|---|---|
| Final render | `/workspace/qi/output/final.mp4` |
| Raw ComfyUI output | `/workspace/qi/output/comfyui_output/*.mp4` |
| Uploaded inputs | `/workspace/qi/input/` |
| Driving frames | `/workspace/qi/output/renders/` |
| Models (~33 GB) | `/workspace/qi/ComfyUI/models/` |
| Pipeline code | `/workspace/qi/scripts/` (deployed from `/workspace/qi-src/`) |
| Logs | `/workspace/qi/pipeline_run.log`, `/workspace/qi/qi_ui.log` |

---

## 5. Stop the pod (IMPORTANT — saves money)

RunPod console → **Pods → your pod**:
- **Terminate** (recommended when done for the day): deletes the pod, **keeps the `/workspace` network volume** (you only pay cheap volume storage ~$0.05–0.07/GB/mo). Models stay.
- **Stop**: pauses it; faster to resume, but the GPU may be unavailable on restart and you still pay a small fee.

The A40 bills **while running**, so don't leave it on idle.

---

## 6. Resume next session (volume still exists)

1. RunPod → **Deploy** a new pod:
   - Attach the **existing `/workspace` network volume** (this carries all models — no re-download).
   - GPU: **48 GB** (A40 / A6000 / L40S), On-Demand.
   - Template: **RunPod PyTorch 2.x**.
   - Expose ports **8000, 8188, 22**.
   - SSH key already registered (your `id_ed25519.pub`).
2. Get the new `IP:port` from **Connect → SSH over exposed TCP**.
3. SSH in → `cd /workspace/qi-src && bash runpod_launch.sh`
4. Tunnel + browser (Section 2). **Done — no setup, no downloads.**

---

## 7. From absolute scratch (brand-new / empty volume only)

Only if the volume is gone/empty (`/workspace/qi/ComfyUI` missing):
```bash
# on your machine: push the repo
scp -r -P <PORT> -i ~/.ssh/id_ed25519 <repo> root@<IP>:/workspace/qi-src
# on the pod:
cd /workspace/qi-src
bash runpod_setup.sh        # ComfyUI + custom nodes (~few min)
bash dl_models.sh           # fp8 model stack (~25 GB, ~15 min)
bash dl_models2.sh          # clip_vision + ViTPose .data fixes
bash runpod_launch.sh       # start the UI
```

---

## 8. Gotchas / fixes

- **IP:port changes every restart** — always re-copy from the Connect panel.
- **Port 8000 not proxied** — use the SSH tunnel (Section 2). (Or expose 8000 in pod settings, but editing ports may force a restart.)
- **Windows: "UNPROTECTED PRIVATE KEY" / asks for password** — the key file perms are too open. Fix (PowerShell):
  ```powershell
  icacls "$env:USERPROFILE\.ssh\id_ed25519" /inheritance:r /grant:r "$($env:USERNAME):R"
  ```
- **Portrait video looks squashed / weird limbs** — already fixed (Stage 2 normalizes rotation). If a new clip still misbehaves, the source has unusual metadata; tell me.
- **Want a maximally-sharp one-off** — ask for a "full-sampling hero render" (slower, ~hours, but sharper than the default 6-step).

---

## 9. Config summary (the canonical setup)

- Model: `Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors` (fp8)
- LoRAs: relight + lightx2v **6-step distill** (cfg 1, shift 5, dpm++_sde)
- Pose: YOLOv10m + **ViTPose-H** (no retargeting — natural proportions)
- Resolution: **720p** (`GEN_SIZE=1280`), RIFE → 30 fps
- Workflow: `workflows/wan_animate.json` (22 nodes)

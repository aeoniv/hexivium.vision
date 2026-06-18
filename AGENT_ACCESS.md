# Agent Access — Qi / Wan2.2-Animate VM (RunPod)

Instructions for another automated agent (e.g. Gemini) to access and operate the pod.
Pairs with `RUNBOOK.md` (human guide) and the memory notes.

---

## 1. Credentials / how to connect

- **SSH key:** `~/.ssh/id_ed25519` (private key lives on the user's Windows machine, git-bash path `/c/Users/aeon vi/.ssh/id_ed25519`). The matching public key is registered in the RunPod account, so it's baked into the pod's `authorized_keys` at create time.
  - ⚠️ **If the agent runs on a *different* machine**, it needs either (a) a copy of this private key, **or** (b) its own keypair whose **public** key is added in RunPod → Settings → SSH Public Keys **before the pod is created** (keys added after create must be appended manually to `/root/.ssh/authorized_keys`). Giving out the private key grants full root on the pod — treat accordingly.
  - The user's public key (for reference):
    `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMyxYyRHVMu1H7giIVfjYaNB/kt+eTtDZ+/8bBy0w6Wx vinicius.aeon@gmail.com`

- **Direct TCP endpoint (supports scp/sftp):** `root@69.30.85.25 -p 22144` *(last seen 2026-06-18 — re-verify, it changes)*
  - ⚠️ **IP and port CHANGE on every pod restart/recreate.** Fetch the current pair from RunPod console → the pod → **Connect → "SSH over exposed TCP"**. The runtime container hostname also changes; ignore it — use the TCP IP:port.

- **Connect with these flags** (the host key changes each pod, so don't verify it):
  ```bash
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~/.ssh/id_ed25519 -p <PORT> root@<IP>
  # current example (re-verify port): ... -p 22144 root@69.30.85.25
  ```
  Quick reachability test: append `"echo OK; nvidia-smi --query-gpu=name --format=csv,noheader"`. "Connection refused" = pod is stopped/down → ask the user to start it and supply the new port.

- **Windows key-permission fix** (if SSH falls back to password / "UNPROTECTED PRIVATE KEY"):
  ```powershell
  icacls "$env:USERPROFILE\.ssh\id_ed25519" /inheritance:r /grant:r "$($env:USERNAME):R"
  ```

---

## 2. ⚠️ Gotchas an automated agent MUST know (these cost real time here)

1. **`pkill -f <pattern>` and `pgrep -f <pattern>` SELF-MATCH.** If the search string (e.g. `app_server.py`, `run_pipeline.sh`, `stage4_comfyui`) appears anywhere in the agent's own command line, pkill kills its own shell and pgrep returns a false positive. **Instead:**
   - Kill a service by its port: `kill $(ss -ltnp | grep ':8000' | grep -oP 'pid=\K[0-9]+' | head -1)` (or `fuser -k 8188/tcp`).
   - Detect an active render with **`nvidia-smi`**, not pgrep: `nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader` (empty = idle).

2. **A trailing `&` over SSH HOLDS the channel open** — the SSH call won't return and your tool may hang/background it. Launch long jobs **detached** and poll separately:
   ```bash
   ssh ... "cd /workspace/qi/scripts && <ENV> setsid bash run_pipeline.sh > /workspace/render.log 2>&1 < /dev/null & echo LAUNCHED=$!"
   # then in a SEPARATE ssh call, poll /workspace/render.log
   ```

3. **IP:port changes every restart** — never hardcode; re-read from Connect.

4. **Tar from Windows → Linux:** extract with `tar xzf - --no-same-owner` (else "Cannot change ownership" errors).

5. **The UI tunnel runs on the LOCAL machine, never inside the pod.**

6. **A pod restart WIPES system python + apt** (only `/workspace` persists) → ComfyUI's deps (`sqlalchemy`, `onnxruntime`, `ffmpeg`, …) vanish and ComfyUI crashes on startup. `runpod_launch.sh` self-heals (re-runs `runpod_setup.sh` when deps are missing), so the **first `runpod_launch.sh` after a restart takes ~3–5 min extra** — expected, not a hang.

7. **Write code fixes to `/workspace/qi-src`, NOT just `/workspace/qi/scripts`.** `runpod_launch.sh` copies `qi-src → qi/scripts` on every launch, so a patch applied only to the runtime gets reverted on the next launch. **To deploy a fix:** update the local repo → `tar` it into `/workspace/qi-src` → run `runpod_launch.sh`. Example full re-sync:
   ```bash
   tar czf - --exclude=.git --exclude=__pycache__ --exclude='*.pyc' --exclude='*.mp4' --exclude='*.png' . \
     | ssh <flags> -p <PORT> root@<IP> "tar xzf - --no-same-owner -C /workspace/qi-src && cd /workspace/qi-src && bash runpod_launch.sh"
   ```

---

## 3. Key paths

| What | Path |
|---|---|
| Pipeline root (`PIPELINE_ROOT`) | `/workspace/qi` |
| ComfyUI (`COMFYUI_DIR`) | `/workspace/qi/ComfyUI` (started on-demand by stage4 on :8188) |
| Deployed code | `/workspace/qi/scripts/` (app_server.py, run_pipeline.sh, stage4…, web/, workflows/) |
| Repo on pod | `/workspace/qi-src/` (push target; `runpod_launch.sh` copies it → scripts/) |
| Canonical workflow | `/workspace/qi/scripts/workflows/wan_animate.json` |
| Inputs | `/workspace/qi/input/{source_video.mp4, reference_image.png}` |
| Final output | `/workspace/qi/output/final.mp4` |
| Models (~33 GB, persistent) | `/workspace/qi/ComfyUI/models/` |
| UI server (FastAPI) | port **8000** (not proxied; tunnel or curl from inside) |
| Jupyter file browser | port **8888** (proxied: `https://<POD_ID>-8888.proxy.runpod.net/?token=<TOKEN>`) |

---

## 4. Operating it

**Start the UI server** (after pod boot):
```bash
ssh ... root@<IP> -p <PORT> "cd /workspace/qi-src && bash runpod_launch.sh"
# health: curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/   (run inside pod)
```

**Run a render headless** (CLI — pin the workflow, set RunPod env):
```bash
ssh ... root@<IP> -p <PORT> "
  cp -f /path/driving.mp4  /workspace/qi/input/source_video.mp4
  cp -f /path/reference.png /workspace/qi/input/reference_image.png
  cd /workspace/qi/scripts && \
  PIPELINE_ROOT=/workspace/qi COMFYUI_DIR=/workspace/qi/ComfyUI PIPELINE_MODE=animate \
  USE_CONDA=0 USE_GCS=0 SKIP_SHUTDOWN=1 GEN_SIZE=1280 \
  WORKFLOW_PATH=/workspace/qi/scripts/workflows/wan_animate.json \
  setsid bash run_pipeline.sh > /workspace/render.log 2>&1 < /dev/null & echo LAUNCHED"
```
Poll completion (separate call): grep `/workspace/render.log` for `ALL STAGES COMPLETE` (or `Traceback`/`out of memory`), and check `nvidia-smi`. A ~20 s clip at 720×1280 takes **~45 min** on the A40. Result → `/workspace/qi/output/final.mp4` (pull with `scp`).

**WORKFLOW_PATH must be pinned** — a stale `WORKFLOW_PATH` env otherwise points at `tmp/workflow_active.json` (old params).

---

## 5. Config invariants — do NOT change without reason

- **fp8** model `Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors`, **6-step lightx2v distill** (cfg 1, shift 5, dpm++_sde). More steps ≠ sharper (distill ceiling).
- **No pose retargeting** for the meridian-figure case (it distorts limbs). ViTPose-H, direct pose.
- **GEN_SIZE=1280** (720p). A40 48 GB fits fp8 720p, `blocks_to_swap=0`, no OOM.
- Stage 2 **normalizes the source** (re-encode) to fix portrait-video rotation — don't remove.
- `app_server` **forces** animate steps=6/cfg=1 regardless of UI input.

---

## 6. First-time setup (only if the /workspace volume is empty)

```bash
scp -r -P <PORT> -i ~/.ssh/id_ed25519 <repo> root@<IP>:/workspace/qi-src
ssh ... root@<IP> -p <PORT> "cd /workspace/qi-src && \
  bash runpod_setup.sh && bash dl_models.sh && bash dl_models2.sh && bash runpod_launch.sh"
```
Downloads ~25–33 GB (stage on `/workspace`, not `/tmp`). If a brand-new pod, register the agent's SSH pubkey first (Section 1).

---

## 7. Cost

A40 ~$0.44/hr, billed **while the pod is on** (idle or not). Terminate when done — models persist on the network volume; recreate + attach volume next time.

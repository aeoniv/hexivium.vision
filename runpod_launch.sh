#!/usr/bin/env bash
# ============================================================================
# Qi Pipeline — RunPod deploy + launch (Wan2.2-Animate, bf16)
# ============================================================================
# One-shot: deploys the orchestrator + pipeline scripts into PIPELINE_ROOT and
# starts the FastAPI UI. ComfyUI is NOT started here — stage4 launches it
# on-demand per render (COMFYUI_DIR), so there's no port clash.
#
# Prereqs (run once per persistent volume): runpod_setup.sh + dl_models.sh
# (+ dl_models2.sh) — installs ComfyUI + custom nodes + the bf16 model stack
# into /workspace/qi/ComfyUI.
#
# Usage (on the pod, from the synced repo dir):
#   scp -r <repo> root@<IP>:/workspace/qi-src     # from your machine
#   ssh root@<IP> -p <PORT>
#   cd /workspace/qi-src && bash runpod_launch.sh
# ============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PIPELINE_ROOT="${PIPELINE_ROOT:-/workspace/qi}"
export COMFYUI_DIR="${COMFYUI_DIR:-/workspace/qi/ComfyUI}"
export PIPELINE_MODE="${PIPELINE_MODE:-animate}"
export USE_CONDA=0          # RunPod has no conda — use system python
export USE_GCS=0            # no GCS on RunPod — inputs/outputs are local
export SKIP_SHUTDOWN=1      # never auto-`shutdown` the pod from the pipeline
SCRIPTS_DIR="${PIPELINE_ROOT}/scripts"
PYBIN="$(command -v python3 || command -v python)"

echo "=== Qi RunPod launch ==="
echo "    SRC=${SRC}  ROOT=${PIPELINE_ROOT}  COMFYUI_DIR=${COMFYUI_DIR}  python=${PYBIN}"

# ── sanity: ComfyUI + models must already be installed ──────────────────────
if [ ! -f "${COMFYUI_DIR}/main.py" ]; then
    echo "ERROR: ComfyUI not found at ${COMFYUI_DIR}."
    echo "       Run runpod_setup.sh + dl_models.sh (+ dl_models2.sh) first."
    exit 1
fi

# ── self-heal deps after a pod RESTART ──────────────────────────────────────
# RunPod wipes the container's system python + apt packages on every stop/start
# (only /workspace persists). If ComfyUI's deps are gone, ComfyUI crashes
# (e.g. ModuleNotFoundError: sqlalchemy). Detect + restore via runpod_setup.sh.
if ! "${PYBIN}" -c 'import sqlalchemy, websocket, onnxruntime' 2>/dev/null; then
    echo "[launch] ComfyUI deps missing (post-restart) — restoring via runpod_setup.sh…"
    bash "${SRC}/runpod_setup.sh"
fi

# ── orchestrator deps ───────────────────────────────────────────────────────
"${PYBIN}" -m pip install --break-system-packages --quiet \
    fastapi "uvicorn[standard]" python-multipart websocket-client || true

# ── deploy scripts + workflows + web UI into PIPELINE_ROOT/scripts ──────────
mkdir -p "${SCRIPTS_DIR}" "${PIPELINE_ROOT}/input" \
         "${PIPELINE_ROOT}/output/renders" "${PIPELINE_ROOT}/tmp"
# run_pipeline.sh gates on this marker (GCP startup.sh used to create it); on RunPod
# the equivalent bootstrap is runpod_setup.sh, so mark it complete here.
touch "${PIPELINE_ROOT}/.bootstrap_complete"
cp -f  "${SRC}"/*.py            "${SCRIPTS_DIR}/" 2>/dev/null || true
cp -f  "${SRC}/run_pipeline.sh" "${SCRIPTS_DIR}/"
cp -rf "${SRC}/workflows"       "${SCRIPTS_DIR}/"
if [ -d "${SRC}/web" ]; then
    cp -rf "${SRC}/web" "${SCRIPTS_DIR}/"
else
    echo "[launch] no web/ UI dir in repo — UI route will show a placeholder."
fi

# ── (re)start the FastAPI UI on :8000 ───────────────────────────────────────
pkill -f "${SCRIPTS_DIR}/app_server.py" 2>/dev/null || true
sleep 1
cd "${SCRIPTS_DIR}"
setsid "${PYBIN}" "${SCRIPTS_DIR}/app_server.py" \
    > "${PIPELINE_ROOT}/qi_ui.log" 2>&1 < /dev/null &
echo "[launch] app_server PID=$!"

# ── wait for it to answer ───────────────────────────────────────────────────
for i in $(seq 1 30); do
    if curl -fsS -o /dev/null "http://127.0.0.1:8000/" 2>/dev/null; then
        echo "[launch] UI is up on :8000"
        break
    fi
    sleep 1
done

echo ""
echo "=== DONE ==="
echo "  Local:        http://127.0.0.1:8000"
echo "  RunPod proxy: https://<POD_ID>-8000.proxy.runpod.net   (expose port 8000 in pod settings)"
echo "  UI log:       ${PIPELINE_ROOT}/qi_ui.log"
echo "  Pipeline log: ${PIPELINE_ROOT}/pipeline_run.log"
echo "  ComfyUI is started on-demand by stage4 (port 8188) on each render."

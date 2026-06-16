#!/usr/bin/env bash
# Deploy the latest toggle code, re-enable swap, and (re)start the UI server.
set -e
S=/opt/qi-pipeline/scripts

# 1. Place updated pipeline files + the workflows/ directory
sudo cp /tmp/qi_sync/run_pipeline.sh /tmp/qi_sync/stage4_comfyui_render.py /tmp/qi_sync/app_server.py "$S/"
sudo mkdir -p "$S/workflows" "$S/web"
sudo cp /tmp/qi_sync/wan_animate.json /tmp/qi_sync/fun_control.json "$S/workflows/"
sudo cp /tmp/qi_sync/index.html /tmp/qi_sync/app.js "$S/web/"
sudo rm -f "$S/workflow_qi_pipeline.json"
sudo chmod +x "$S/run_pipeline.sh"

# 2. Re-enable swap (file persists on disk) + make it survive future restarts
if [ ! -f /swapfile ]; then
    sudo fallocate -l 48G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile >/dev/null
fi
sudo swapon /swapfile 2>/dev/null || true
grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null

# 3. (Re)start the UI server, detached so it survives the SSH session
sudo pkill -9 -f app_server.py 2>/dev/null || true
sleep 2
sudo bash -c 'source /opt/miniconda3/etc/profile.d/conda.sh && conda activate qi-pipeline && cd /opt/qi-pipeline/scripts && setsid python app_server.py > /var/log/qi_ui.log 2>&1 < /dev/null &'
sleep 7

echo "=== app_server ==="; pgrep -af app_server.py | grep -v grep | head -1 || echo "NOT running"
echo "=== http ==="; curl -s -o /dev/null -w 'UI HTTP %{http_code}\n' http://127.0.0.1:8000/
echo "=== swap ==="; free -g | grep Swap
echo "=== workflows ==="; ls "$S/workflows/"

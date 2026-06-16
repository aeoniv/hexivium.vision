#!/usr/bin/env bash
set -e
S=/opt/qi-pipeline/scripts
sudo cp /tmp/qi_sync/generate_image.py "$S/"
sudo cp /tmp/qi_sync/txt2img_sdxl.json "$S/workflows/"
sudo cp /tmp/qi_sync/app_server.py "$S/"
sudo cp /tmp/qi_sync/index.html "$S/web/"
sudo cp /tmp/qi_sync/app.js "$S/web/"

# Restart the UI server (detached) so the new endpoints are live
sudo pkill -9 -f app_server.py 2>/dev/null || true
sleep 2
sudo bash -c 'source /opt/miniconda3/etc/profile.d/conda.sh && conda activate qi-pipeline && cd /opt/qi-pipeline/scripts && setsid python app_server.py > /var/log/qi_ui.log 2>&1 < /dev/null &'
sleep 6
echo "=== app_server ==="; pgrep -af app_server.py | grep -v grep | head -1 || echo NONE
echo "=== http ==="; curl -s -o /dev/null -w 'UI HTTP %{http_code}\n' http://127.0.0.1:8000/
echo "=== generate-avatar endpoint present ==="; grep -c 'generate-avatar' "$S/app_server.py"

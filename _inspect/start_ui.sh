#!/usr/bin/env bash
# Launch the orchestrator UI detached so it survives the SSH session.
source /opt/miniconda3/etc/profile.d/conda.sh
conda activate qi-pipeline
cd /opt/qi-pipeline/scripts
pkill -9 -f app_server.py 2>/dev/null
sleep 2
setsid python app_server.py > /var/log/qi_ui.log 2>&1 < /dev/null &
disown
sleep 6
echo "app_server pid(s): $(pgrep -f app_server.py | tr '\n' ' ')"
curl -s -o /dev/null -w 'UI HTTP %{http_code}\n' http://127.0.0.1:8000/

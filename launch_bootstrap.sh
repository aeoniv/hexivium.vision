#!/bin/bash
# Launcher: re-run bootstrap in background
rm -f /opt/qi-pipeline/.bootstrap_complete
gsutil cp gs://hexivium-vision-pipeline/scripts/startup.sh /tmp/startup.sh
nohup bash /tmp/startup.sh > /var/log/qi-pipeline-bootstrap.log 2>&1 &
echo "Bootstrap launched as PID $!"

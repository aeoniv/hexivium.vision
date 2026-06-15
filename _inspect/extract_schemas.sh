#!/usr/bin/env bash
# Boot ComfyUI (CPU, no weights) and dump exact input schemas for the nodes
# we need to build the Wan-Animate workflow.
source /opt/miniconda3/etc/profile.d/conda.sh
conda activate qi-pipeline
cd /opt/qi-pipeline/engines/ComfyUI
python main.py --listen 127.0.0.1 --port 8199 --cpu --dont-print-server > /tmp/comfy_oi.log 2>&1 &
PID=$!
for i in $(seq 1 200); do
  curl -s http://127.0.0.1:8199/object_info > /tmp/oi.json 2>/dev/null && [ -s /tmp/oi.json ] && break
  sleep 1
done
python - <<'PY'
import json
d=json.load(open('/tmp/oi.json'))
targets=['WanVideoModelLoader','WanVideoLoraSelectMulti','WanVideoSetLoRAs','WanVideoSetBlockSwap',
 'WanVideoBlockSwap','WanVideoClipVisionEncode','WanVideoSampler','WanVideoAnimateEmbeds','WanVideoVAELoader',
 'WanVideoTextEncode','LoadWanVideoT5TextEncoder','VHS_LoadImages','PoseAndFaceDetection','DrawViTPose',
 'OnnxDetectionModelLoader','WanVideoDecode','ImageScale']
def fmt(spec):
    # spec is [type, cfg] or [choices,cfg] or [type]
    t=spec[0]
    cfg=spec[1] if len(spec)>1 and isinstance(spec[1],dict) else {}
    if isinstance(t,list):
        ts='enum'+str(t[:6])
    else:
        ts=str(t)
    dv=cfg.get('default','')
    return f"{ts} default={dv!r}"
lines=[]
for tname in targets:
    if tname not in d:
        lines.append(f"### {tname}: MISSING"); continue
    inp=d[tname]['input']
    lines.append(f"### {tname}")
    for sect in ('required','optional'):
        for name,spec in (inp.get(sect,{}) or {}).items():
            lines.append(f"  [{sect[:3]}] {name}: {fmt(spec)}")
open('/tmp/schemas.txt','w').write("\n".join(lines))
print("\n".join(lines))
PY
kill $PID 2>/dev/null

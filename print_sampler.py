content = open('/opt/qi-pipeline/engines/ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/nodes.py').read()
lines = content.splitlines()

line_ranges = [
    ("WanVideoClipVisionEncode", 605, 665),
    ("WanVideoEncode", 2228, 2288),
    ("WanVideoImageToVideoEncode", 980, 1040),
]

for name, start, end in line_ranges:
    print(f"\n==================== {name} (lines {start}-{end}) ====================")
    for idx in range(start - 1, min(end, len(lines))):
        print(f"{idx + 1}: {lines[idx]}")

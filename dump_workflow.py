import json
from pathlib import Path

workflow_path = Path("/opt/qi-pipeline/engines/ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/example_workflows/wanvideo_2_1_14B_Fun_control_example_01.json")

with open(workflow_path, "r", encoding="utf-8") as f:
    data = json.load(f)

nodes = data.get("nodes", [])

target_types = ["WanVideoModelLoader", "WanVideoSampler", "WanVideoDecode"]
print("--- DETAILED TARGET DUMP ---")
for node in nodes:
    ntype = node.get("type")
    if ntype in target_types:
        print(f"\nNode {node.get('id')}: {ntype}")
        print(f"  Widgets: {node.get('widgets_values')}")
        print(f"  Inputs: {node.get('inputs')}")
        print(f"  Outputs: {node.get('outputs')}")

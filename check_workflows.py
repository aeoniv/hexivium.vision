import json
from pathlib import Path

workflows_dir = Path("/opt/qi-pipeline/engines/ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/example_workflows")
print(f"Recursively checking workflows in {workflows_dir}...")

def find_safetensors(val, path=""):
    results = []
    if isinstance(val, dict):
        for k, v in val.items():
            results.extend(find_safetensors(v, f"{path}.{k}" if path else k))
    elif isinstance(val, list):
        for idx, item in enumerate(val):
            results.extend(find_safetensors(item, f"{path}[{idx}]"))
    elif isinstance(val, str) and ".safetensors" in val:
        results.append((path, val))
    return results

for p in workflows_dir.glob("*.json"):
    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
        matches = find_safetensors(data)
        if matches:
            print(f"\n--- {p.name} ---")
            for path, val in matches:
                print(f"  {path}: {val}")
    except Exception as e:
        print(f"  Error reading {p.name}: {e}")

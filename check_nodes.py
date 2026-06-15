import json
from pathlib import Path

workflow_path = Path("/opt/qi-pipeline/engines/ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/example_workflows/wanvideo_2_1_14B_Fun_control_example_01.json")

if not workflow_path.exists():
    print(f"Error: {workflow_path} does not exist")
    exit(1)

with open(workflow_path, "r", encoding="utf-8") as f:
    data = json.load(f)

nodes = data.get("nodes", [])
links = data.get("links", [])

# Let's map link ID to its origin and destination details
link_map = {}
for link in links:
    # link is [id, origin_node_id, origin_slot, dest_node_id, dest_slot, type]
    if len(link) >= 6:
        link_map[link[0]] = {
            "origin_node": link[1],
            "origin_slot": link[2],
            "dest_node": link[3],
            "dest_slot": link[4],
            "type": link[5]
        }

# Helper to get node by ID
def get_node(nid):
    for node in nodes:
        if node.get("id") == nid:
            return node
    return None

# Find where control_embeds on Node 63 (or any other node) comes from
print("--- TRACING CONNECTIONS ---")
for node in nodes:
    nid = node.get("id")
    ntype = node.get("type")
    
    # Let's print connections of interest
    if ntype in ["WanVideoImageToVideoEncode", "WanVideoControlEmbeds", "WanVideoSampler"]:
        print(f"\nNode {nid} ({ntype}):")
        inputs = node.get("inputs", [])
        for inp in inputs:
            link_id = inp.get("link")
            if link_id and link_id in link_map:
                l = link_map[link_id]
                orig_node = get_node(l["origin_node"])
                orig_type = orig_node.get("type") if orig_node else "Unknown"
                print(f"  - input '{inp.get('name')}': connected to Node {l['origin_node']} ({orig_type}) slot {l['origin_slot']}")
            else:
                print(f"  - input '{inp.get('name')}': {inp.get('value', 'None (unconnected)')}")

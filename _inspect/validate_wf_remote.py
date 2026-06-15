import json, sys, os
oi_path = '/tmp/oi.json'
if not os.path.exists(oi_path):
    print("oi.json missing — regenerate object_info first"); sys.exit(2)
oi = json.load(open(oi_path))
wf = json.load(open('/opt/qi-pipeline/scripts/workflow_qi_pipeline.json'))
problems = []
for nid, node in wf.items():
    ct = node['class_type']
    if ct not in oi:
        problems.append(f"node {nid}: UNKNOWN class_type '{ct}'"); continue
    req = oi[ct]['input'].get('required', {})
    have = set(node.get('inputs', {}).keys())
    for name in req:
        if name not in have:
            problems.append(f"node {nid} ({ct}): missing required input '{name}'")
    # check enum values for file-name inputs we set
    for name, val in node.get('inputs', {}).items():
        # VHS_LoadImages 'directory' accepts arbitrary paths in API mode
        if ct == 'VHS_LoadImages' and name == 'directory':
            continue
        spec = req.get(name) or oi[ct]['input'].get('optional', {}).get(name)
        if spec and isinstance(spec[0], list) and isinstance(val, str):
            if val not in spec[0]:
                problems.append(f"node {nid} ({ct}): '{name}'='{val}' not in allowed {spec[0][:6]}")
if problems:
    print("VALIDATION PROBLEMS:")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print("WORKFLOW VALID - all class_types known, required inputs present, enum values OK.")

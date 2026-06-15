content = open('/opt/qi-pipeline/engines/ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/nodes_model_loading.py').read()
idx = content.find("class LoadWanVideoT5TextEncoder")
if idx != -1:
    print("\n".join(content[idx:].splitlines()[:60]))
else:
    print("Not found")

import sys
import importlib

sys.path.insert(0, "/opt/qi-pipeline/engines/ComfyUI")
sys.path.insert(0, "/opt/qi-pipeline/engines/ComfyUI/custom_nodes")

# Import the parent package first
try:
    parent = importlib.import_module("ComfyUI-WanVideoWrapper")
    print("Successfully imported parent package")
except Exception as e:
    print(f"Failed to import parent: {e}")
    sys.exit(1)

# Import submodules
try:
    nodes_model_loading = importlib.import_module("ComfyUI-WanVideoWrapper.nodes_model_loading")
    nodes_sampler = importlib.import_module("ComfyUI-WanVideoWrapper.nodes_sampler")
    print("Successfully imported submodules")
except Exception as e:
    print(f"Failed to import submodules: {e}")
    sys.exit(1)

node_classes = {
    "WanVideoModelLoader": nodes_model_loading.WanVideoModelLoader,
    "LoadWanVideoT5TextEncoder": nodes_model_loading.LoadWanVideoT5TextEncoder,
    "WanVideoTextEncode": nodes_sampler.WanVideoTextEncode,
    "WanVideoTextEmbedBridge": nodes_sampler.WanVideoTextEmbedBridge,
    "WanVideoVAELoader": nodes_model_loading.WanVideoVAELoader,
    "WanVideoClipVisionEncode": nodes_sampler.WanVideoClipVisionEncode,
    "WanVideoEncode": nodes_sampler.WanVideoEncode,
    "WanVideoControlEmbeds": nodes_sampler.WanVideoControlEmbeds,
    "WanVideoImageToVideoEncode": nodes_sampler.WanVideoImageToVideoEncode,
    "WanVideoSampler": nodes_sampler.WanVideoSampler,
    "WanVideoDecode": nodes_sampler.WanVideoDecode,
}

for name, cls in node_classes.items():
    print(f"\n==================== {name} ====================")
    if hasattr(cls, "INPUT_TYPES"):
        print(cls.INPUT_TYPES())
    else:
        print("No INPUT_TYPES")

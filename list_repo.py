from huggingface_hub import HfApi

api = HfApi()
repo_id = "lithiumice/models_hub"
print(f"Listing files in {repo_id}...")
files = api.list_repo_files(repo_id)
for f in files:
    if "smpl" in f.lower():
        print(f)

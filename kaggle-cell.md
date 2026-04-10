# Kaggle launch cell

> **Run this cell first in a fresh Kaggle session** to clone the repo, check out `main`, and run the full environment setup (Miniconda + conda env + Python deps + model download). Re-running is safe — every step is idempotent.

```python
import os, subprocess, sys

REPO_URL = "https://github.com/ahmed12545/bulul-api-library.git"
REPO_DIR = "/kaggle/working/bulul-api-library"

def run(cmd):
    print(f"\n$ {cmd}", flush=True)
    result = subprocess.run(cmd, shell=True, text=True)
    if result.returncode != 0:
        print(f"ERROR: command exited with code {result.returncode}", file=sys.stderr, flush=True)
        sys.exit(result.returncode)

# 1) Clone or update the repo
if os.path.isdir(os.path.join(REPO_DIR, ".git")):
    print("[1/3] Repo exists — fetching latest…", flush=True)
    run(f"git -C {REPO_DIR} fetch --prune origin")
else:
    print("[1/3] Cloning repo…", flush=True)
    run(f"git clone {REPO_URL} {REPO_DIR}")

# 2) Check out main
print("[2/3] Checking out main…", flush=True)
run(f"git -C {REPO_DIR} checkout main")
run(f"git -C {REPO_DIR} reset --hard origin/main")

# 3) Run the official setup script (Miniconda + conda env + deps + model download)
print("[3/3] Running setup_kaggle.sh…", flush=True)
# setup_kaggle.sh calls download_models.sh and host_service.sh is used after setup —
# mark all three executable up-front so no step fails due to missing execute bit.
run(f"chmod +x {REPO_DIR}/setup_kaggle.sh {REPO_DIR}/download_models.sh {REPO_DIR}/host_service.sh")
run(f"cd {REPO_DIR} && bash setup_kaggle.sh")

print("\n✅ Setup complete.", flush=True)
print("   Next: set GROQ_API_KEY and NGROK_AUTHTOKEN, then run `bash host_service.sh`.")
```

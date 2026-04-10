# Kaggle launch cells

## Cell 1 — Environment setup

> **Run this cell first** in a fresh Kaggle session to clone the repo, check out `main`,
> and run the full environment setup (Miniconda + `bulul` conda env + Python deps + model
> download). Re-running is safe — every step is idempotent.
>
> What `setup_kaggle.sh` does:
> - Installs Miniconda under `~/miniconda3` (skipped if already present)
> - Creates a `bulul` conda env with Python 3.10
> - `pip install`s `requirements.txt` inside the env
> - Clones the StyleTTS2 source tree into `models/StyleTTS2/`
> - Downloads the LJSpeech checkpoint (~0.5 GB) and config into `models/styletts2/`
> - Creates `runtime/tmp/` and sets up HuggingFace / Torch cache dirs

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
# setup_kaggle.sh calls download_models.sh; host_service.sh is used after setup —
# mark all three executable up-front so no step fails due to a missing execute bit.
run(f"chmod +x {REPO_DIR}/setup_kaggle.sh {REPO_DIR}/download_models.sh {REPO_DIR}/host_service.sh")
run(f"cd {REPO_DIR} && bash setup_kaggle.sh")

print("\n✅ Setup complete.", flush=True)
print("   Next: run Cell 2 below to smoke-test the model, then set GROQ_API_KEY and")
print("   NGROK_AUTHTOKEN and run `bash host_service.sh` to start the API.")
```

---

## Cell 2 — Smoke test (generate & play audio)

> **Run after Cell 1 completes.** This cell synthesises a short test sentence with
> StyleTTS2 inside the `bulul` conda env and displays an inline audio player so you
> can confirm the model is working before starting the full service.
>
> **Expected input:** the short English sentence in `TEXT` below — no reference WAV is
> needed for the single-speaker LJSpeech checkpoint used by this project.
>
> **Output location:** `/kaggle/working/smoke_test.wav` (fixed, deterministic path;
> safe to re-run — the file is overwritten each time).
>
> **Troubleshooting — if no WAV is produced:**
> - Make sure Cell 1 finished without errors.
> - Check that `models/styletts2/epoch_2nd_00100.pth` and `models/styletts2/config.yml`
>   exist inside `REPO_DIR`.
> - Inspect the STDERR output printed below for Python tracebacks.
> - On CPU-only Kaggle sessions the model loads more slowly; allow ~2 minutes.

```python
import os, subprocess, sys, textwrap
from IPython.display import Audio, display

REPO_DIR = "/kaggle/working/bulul-api-library"
CONDA    = os.path.expanduser("~/miniconda3/bin/conda")
ENV      = "bulul"
OUT_WAV  = "/kaggle/working/smoke_test.wav"
TEXT     = "Hello. The Bulul API setup is working correctly. StyleTTS2 is generating audio."

# -- 0. Preflight checks ------------------------------------------------------
for p in [
    CONDA,
    f"{REPO_DIR}/models/styletts2/epoch_2nd_00100.pth",
    f"{REPO_DIR}/models/styletts2/config.yml",
    f"{REPO_DIR}/models/StyleTTS2",
]:
    if not os.path.exists(p):
        raise SystemExit(f"Not found (run the setup cell first): {p}")

print("✔ Preflight checks passed.", flush=True)

# -- 1. Write synthesis script to a temp file ---------------------------------
# Running via a temp file keeps shell quoting simple and produces clean output.
SYNTH_PY = "/tmp/bulul_smoke_synth.py"
with open(SYNTH_PY, "w") as fh:
    fh.write(textwrap.dedent(f"""\
        import sys, os
        # Make the cloned StyleTTS2 source tree importable as `styletts2`
        sys.path.insert(0, "{REPO_DIR}/models/StyleTTS2")
        os.environ.setdefault("HF_HOME", "/kaggle/working/.cache/huggingface")
        os.environ.setdefault("TORCH_HOME", "/kaggle/working/.cache/torch")

        import torch
        from styletts2 import tts as styletts2_tts
        import numpy as np
        import soundfile as sf

        ckpt = "{REPO_DIR}/models/styletts2/epoch_2nd_00100.pth"
        cfg  = "{REPO_DIR}/models/styletts2/config.yml"
        out  = "{OUT_WAV}"
        text = "{TEXT}"

        device = "cuda" if torch.cuda.is_available() else "cpu"
        print(f"[smoke] Loading StyleTTS2 on {{device}}...", flush=True)
        model = styletts2_tts.StyleTTS2(model_checkpoint_path=ckpt, config_path=cfg)
        print("[smoke] Model loaded. Synthesising...", flush=True)

        audio = model.inference(text, output_sample_rate=24000)
        sf.write(out, np.array(audio, dtype=np.float32), 24000)
        print(f"[smoke] WAV written -> {{out}}", flush=True)
    """))

# -- 2. Run synthesis inside the bulul conda env ------------------------------
print(f"[1/2] Synthesising speech in conda env '{ENV}'...", flush=True)
result = subprocess.run(
    [CONDA, "run", "-n", ENV, "python", SYNTH_PY],
    text=True, capture_output=True,
)
print(result.stdout, end="")
if result.stderr:
    print("-- STDERR --")
    print(result.stderr, end="")
if result.returncode != 0:
    raise SystemExit(f"\nSynthesis failed (exit code {result.returncode}). See STDERR above.")

# -- 3. Display inline audio player -------------------------------------------
if not os.path.isfile(OUT_WAV):
    raise SystemExit(f"WAV not found at {OUT_WAV} — check STDERR above.")

print(f"\n[2/2] ✅ Smoke test passed.  Output: {OUT_WAV}", flush=True)
display(Audio(OUT_WAV, autoplay=True))
```

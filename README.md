# bulul-api-library

AI-powered podcast generation API. Accepts a topic and a CEFR language level (A1–C2), generates a 5–6 minute podcast script via Groq LLM, synthesises audio with **StyleTTS2** (voice cloning from reference WAV), and returns the audio file. The file is automatically deleted after delivery.

> **Migration note:** XTTS2 has been removed by user request. RVC has also been removed. This project now uses StyleTTS2 exclusively.

---

## Quick start on Kaggle

### Step 1 — Clone the repo
```bash
git clone https://github.com/ahmed12545/bulul-api-library.git
cd bulul-api-library
```

### Step 2 — Add your voice reference files (optional)
Place one or more `.wav` files (6–30 s of clear speech) in the `voice refs/` folder for voice cloning.
If no reference is provided, StyleTTS2 uses its built-in default voice.

```
voice refs/
├── README.md        ← usage guide (always present)
├── my_voice.wav     ← your reference WAV (you add this)
└── ...
```

See [`voice refs/README.md`](voice%20refs/README.md) for guidelines on recording or obtaining reference audio.

### Step 3 — Run setup (Miniconda + conda env + StyleTTS2 deps)
```bash
bash setup_kaggle.sh
```
This will:
- Install `espeak-ng` (system dependency required by the phonemizer library)
- Install Miniconda if not already present
- Accept Anaconda channel Terms of Service (required in non-interactive environments)
- Create one conda environment: **`bulul-styletts2`** (Python 3.10)
- Install PyTorch **2.1.2** + torchaudio **2.1.2** from the CUDA 12.1 wheel index (stage B)
- Install StyleTTS2 runtime dependencies from `requirements-styletts2.txt` (stage C):
  - `phonemizer`, `librosa`, `soundfile`, `scipy`, `numpy`, `transformers`, `huggingface_hub>=0.20`
  - `nltk`, `gruut`, `gruut-ipa`, `gruut-lang-en` (NLP/phonemization)
  - `einops`, `einops-exts`, `accelerate`, `cached-path` (ML utilities)
  - `munch>=4.0`, `pyyaml>=6.0`, `matplotlib`, `tqdm`, `pydub`, `filelock`, `networkx` (styletts2 internals)
- Install `styletts2` itself with `--no-deps` (stage D) to avoid its `huggingface_hub<0.20` pin conflicting with the newer version above
- Bootstrap NLTK `punkt_tab` tokenizer data (stage E) — required by `styletts2.tts` at import time
- Pre-download the StyleTTS2 model weights from HuggingFace
- Register the env as a Jupyter/Kaggle notebook kernel (`Python (bulul-styletts2)`)
- Set up `HF_HOME`, `TRANSFORMERS_CACHE`, and `TORCH_HOME` cache directories under `/kaggle/working/.cache/`
- Pre-download the StyleTTS2 model weights from HuggingFace
- Register the env as a Jupyter/Kaggle notebook kernel (`Python (bulul-styletts2)`)
- Set up `HF_HOME`, `TRANSFORMERS_CACHE`, and `TORCH_HOME` cache directories under `/kaggle/working/.cache/`

> **Note:** The script is idempotent — re-running it safely skips already-complete steps.

#### Output mode

By default setup runs in **quiet mode**: subprocess output is captured to
`runtime/logs/setup.log`. Only step summaries and errors are printed
(≈ 10 lines for a clean run). On failure the last 40 log lines are printed
automatically.

To see full output while debugging:
```bash
bash setup_kaggle.sh --verbose
```

### Step 4 — Start the service
```bash
bash host_service.sh
```
You will be prompted for:
- **GROQ API key** — get one at <https://console.groq.com>
- **ngrok auth token** — get one at <https://dashboard.ngrok.com>

The script will:
1. Activate the `bulul-styletts2` conda env
2. Export `HF_HOME`, `TRANSFORMERS_CACHE`, and `TORCH_HOME` cache dirs
3. Start the FastAPI server on port 8000
4. Open an ngrok tunnel and print the public URL

> **Note:** On first run after setup StyleTTS2 may take a minute to load.

### Quick Kaggle cell (clone + setup + model download)

```python
import subprocess, time, os

REPO_URL = "https://github.com/ahmed12545/bulul-api-library.git"
REPO_DIR = "/kaggle/working/bulul-api-library"

def run_streaming(cmd):
    """Run a shell command and stream output line-by-line to avoid Kaggle hangs."""
    print(f"\n$ {cmd}")
    p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True, bufsize=1)
    start = time.time()
    for line in p.stdout:
        print(line, end="", flush=True)
    p.wait()
    print(f"[exit {p.returncode}] ({time.time()-start:.0f}s)")
    if p.returncode != 0:
        raise RuntimeError(f"Command failed: {cmd}")

# 1) Clone fresh (remove old copy if present)
if os.path.exists(REPO_DIR):
    run_streaming(f"rm -rf {REPO_DIR}")
run_streaming(f"git clone {REPO_URL} {REPO_DIR}")

# 2) Make scripts executable
run_streaming(f"chmod +x {REPO_DIR}/setup_kaggle.sh {REPO_DIR}/download_models.sh "
              f"{REPO_DIR}/host_service.sh {REPO_DIR}/tests/test.sh")

# 3) (Optional) Add a reference WAV for voice cloning
# run_streaming(f"cp /path/to/my_voice.wav '{REPO_DIR}/voice refs/my_voice.wav'")

# 4) Run full setup (Miniconda + conda env + StyleTTS2 deps + model download)
run_streaming(f"cd {REPO_DIR} && bash setup_kaggle.sh")

print("\n✅ Setup complete.")
print("  • Env: bulul-styletts2 (StyleTTS2 synthesis + API)")
print("  • Quick test with default voice:")
print(f"      bash {REPO_DIR}/tests/test.sh --text 'Hello from Bulul.'")
print("  • Quick test with voice cloning:")
print(f"      bash {REPO_DIR}/tests/test.sh --ref-wav 'voice refs/my_voice.wav' --text 'Hello.'")
print("  • Run 'bash host_service.sh' to start the API.")
print("  • Run 'bash tests/test.sh --help' for all synthesis options.")
```

### Step 5 — Call the endpoint
```bash
# Replace <PUBLIC_URL> with the ngrok URL printed in step 4

# Health check
curl <PUBLIC_URL>/health

# Generate podcast (returns audio file)
curl -X POST <PUBLIC_URL>/generate-podcast \
     -H "Content-Type: application/json" \
     -d '{"topic": "black holes", "language_level": "B2", "format": "mp3"}' \
     --output podcast.mp3
```

---

## API reference

### `GET /health`
Returns `{"status": "ok", "service": "bulul-api"}`.

### `POST /generate-podcast`
| Field | Type | Required | Description |
|---|---|---|---|
| `topic` | string | ✅ | Podcast topic |
| `language_level` | string | ✅ | CEFR level: `A1` `A2` `B1` `B2` `C1` `C2` |
| `format` | string | | `mp3` (default) or `wav` |

Returns the audio file directly as `audio/mpeg` or `audio/wav`.  
The file is deleted from the server automatically after the response is sent.

The voice used for synthesis is determined by the first `.wav` file found in the `voice refs/` folder.
If none is present, the StyleTTS2 default voice is used as fallback.

---

## Environment variables

Copy `.env.example` to `.env` and fill in your values:
```bash
cp .env.example .env
```

| Variable | Description |
|---|---|
| `GROQ_API_KEY` | Groq LLM API key |
| `NGROK_AUTHTOKEN` | ngrok tunnel auth token |
| `APP_PORT` | Server port (default `8000`) |
| `TMP_AUDIO_DIR` | Temp audio directory (default `runtime/tmp`) |
| `DEFAULT_AUDIO_FORMAT` | Default format `mp3` or `wav` |

---

## Run on a server (non-Kaggle)

```bash
# Install system dependency (required for phonemizer)
apt-get install -y espeak-ng libespeak-ng-dev

# Install deps into your Python environment
pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install -r requirements-styletts2.txt

# Download StyleTTS2 assets (creates voice refs/ dir + pre-downloads model)
bash download_models.sh

# Set env vars and start
export GROQ_API_KEY=your_key
uvicorn app:app --host 0.0.0.0 --port 8000
```

---

## Running tests

```bash
# Python API tests (requires pytest and httpx)
pip install pytest httpx
pytest tests/test_app.py -v

# Shell script smoke checks (no external dependencies)
bash tests/test_scripts.sh
```

---

## StyleTTS2 voice synthesis pipeline

### Overview

StyleTTS2 synthesises speech in a target voice from a reference audio file.

```
# Voice cloning from a reference WAV:
text + reference WAV  →  StyleTTS2  →  cloned speech audio

# Default voice (no reference WAV required):
text  →  StyleTTS2  →  speech audio
```

### `voice refs/` folder (cloning mode)

| What to put there | Notes |
|---|---|
| `my_voice.wav` | 6–30 s of clear speech, minimal noise |
| Any number of `.wav` files | Each file = one cloneable voice |

See [`voice refs/README.md`](voice%20refs/README.md) for recording tips and format guidance.

> WAV files in this folder are **gitignored by default** (to keep the repo lightweight).
> Commit a reference manually with: `git add -f "voice refs/my_voice.wav"`

### Running synthesis manually

```bash
# Default voice (no reference WAV needed)
conda run -n bulul-styletts2 python -u scripts/synthesize.py \
    --text "Welcome to the podcast." \
    --output /tmp/output.wav

# Voice cloning from a specific reference WAV
conda run -n bulul-styletts2 python -u scripts/synthesize.py \
    --text "Welcome to the podcast." \
    --output /tmp/output.wav \
    --ref-wav "voice refs/my_voice.wav"

# Auto-detect first WAV in 'voice refs/' (omit --ref-wav)
conda run -n bulul-styletts2 python -u scripts/synthesize.py \
    --text "Welcome to the podcast." \
    --output /tmp/output.wav

# Adjust quality/style parameters
conda run -n bulul-styletts2 python -u scripts/synthesize.py \
    --text "Welcome to the podcast." \
    --output /tmp/output.wav \
    --ref-wav "voice refs/my_voice.wav" \
    --diffusion-steps 10 \
    --embedding-scale 1.5

# Force CPU inference (no GPU required)
conda run -n bulul-styletts2 python -u scripts/synthesize.py \
    --text "Welcome to the podcast." \
    --output /tmp/output_cpu.wav \
    --cpu
```

### End-to-end test script (`tests/test.sh`)

```bash
# Default voice (no reference WAV needed)
bash tests/test.sh --text "Hello from Bulul."

# Voice-cloning mode (provide a reference WAV)
bash tests/test.sh \
    --text "Hello, this is a test." \
    --ref-wav "voice refs/my_voice.wav" \
    --output-dir /kaggle/working/voice_tests

# Adjust quality parameters
bash tests/test.sh \
    --text "Hello." \
    --ref-wav "voice refs/my_voice.wav" \
    --diffusion-steps 10 \
    --embedding-scale 1.5

# Force CPU inference
bash tests/test.sh --text "Hello." --cpu

# Verbose mode (full subprocess output)
bash tests/test.sh --verbose --text "Hello."

# Show all options
bash tests/test.sh --help
```

#### Output files

Files are written to `--output-dir` (default: `/kaggle/working/voice_tests` on Kaggle,
`./output/voice_tests` elsewhere):

| File | Description |
|---|---|
| `styletts2_output.wav` | StyleTTS2 synthesised output |

#### Logs

All subprocess output is captured to `runtime/logs/test.log`. On failure the last 40 lines
are printed automatically. Pass `--verbose` to stream everything to the cell.

### StyleTTS2 parameters

| Parameter | Default | Notes |
|---|---|---|
| `--diffusion-steps` | `5` | Higher = better quality, slower inference |
| `--embedding-scale` | `1.0` | Style intensity; increase for stronger voice imitation |

### Headless / Kaggle compatibility defaults

`tests/test.sh` and `scripts/synthesize.py` automatically normalise `MPLBACKEND` to `Agg`
when the value is absent or is a Kaggle inline backend (`module://…`).

### Legacy flags (XTTS2 / RVC)

This project has **migrated back to StyleTTS2**. XTTS2 and RVC have been removed.
If you pass any legacy XTTS2/RVC flag, both `tests/test.sh` and `scripts/synthesize.py` will
exit immediately with a clear migration message:

| Legacy flag | Notes |
|---|---|
| `--voice-id` | XTTS2 built-in speakers — removed. Use `--ref-wav` for voice cloning. |
| `--list-speakers` | XTTS2 specific — removed. |
| `--voice-model` | RVC specific — removed. |
| `--voice-index` | RVC specific — removed. |
| `--no-rvc` | RVC specific — removed. |
| `--ckpt`, `--ckpt-name` | Custom checkpoints not supported in this release. |

---

## Troubleshooting

### `espeak-ng` not found — phonemizer fails

**Symptom:** `phonemizer` or `styletts2` fails with `espeak-ng` not found.

**Fix:**
```bash
apt-get install -y espeak-ng libespeak-ng-dev
```
Or re-run setup: `bash setup_kaggle.sh`

### Conda path mismatch (wrong env picked up)

**Symptom:** The log shows the correct Python interpreter but synthesis still fails.

**How these scripts resolve conda:**

Both `setup_kaggle.sh` and `tests/test.sh` use an explicit Miniconda binary
path (`$MINICONDA_DIR/bin/conda`, where `MINICONDA_DIR` defaults to
`$HOME/miniconda3`):
```bash
CONDA_EXE="$MINICONDA_DIR/bin/conda"   # e.g. /root/miniconda3/bin/conda on Kaggle
```
All `conda run` calls go through `$CONDA_EXE` (never the bare `conda` command).
`tests/test.sh` prints the resolved path at runtime:
```
[test] Conda exe  : /root/miniconda3/bin/conda
[test] Python exe : /root/miniconda3/envs/bulul-styletts2/bin/python
```

### Smoke test command reference

```bash
bash tests/test.sh \
  --text "This is a smoke test for StyleTTS2 voice cloning in Kaggle." \
  --ref-wav "voice refs/clip_01.wav" \
  --output-dir /kaggle/working/styletts2_smoke_out
```

Add `--verbose` to stream all subprocess output to the cell instead of the log file.

---

## Project structure

```
bulul-api-library/
├── app.py                      # FastAPI service (StyleTTS2-powered)
├── setup_kaggle.sh             # Miniconda + bulul-styletts2 conda env + StyleTTS2 setup
├── download_models.sh          # StyleTTS2 model pre-download + voice refs dir setup
├── host_service.sh             # Start API + ngrok tunnel (uses bulul-styletts2 env)
├── requirements.txt            # API / web-server layer packages
├── requirements-styletts2.txt  # StyleTTS2 model stack (torch, styletts2, phonemizer, …)
├── requirements-xtts2.txt      # DEPRECATED — XTTS2 removed; see requirements-styletts2.txt
├── .env.example                # Example environment variables
├── voice refs/                 # Place reference WAVs here for voice cloning
│   └── README.md               # Usage guide for voice reference files
├── scripts/
│   ├── synthesize.py           # StyleTTS2 inference helper (unbuffered, Kaggle-friendly)
│   └── rvc_convert.py          # Legacy stub — exits with migration message (RVC removed)
├── runtime/
│   ├── tmp/                    # Temp audio files (auto-deleted, gitignored)
│   └── logs/                   # Setup and test logs (gitignored)
└── tests/
    ├── test_app.py                  # API route tests
    ├── test_scripts.sh              # Shell script smoke checks
    ├── test.sh                      # End-to-end StyleTTS2 synthesis test
    └── podcast_6voices.yaml         # Multi-voice config template
```

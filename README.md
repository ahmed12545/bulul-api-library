# bulul-api-library

AI-powered podcast generation API. Accepts a topic and a CEFR language level (A1–C2), generates a 5–6 minute podcast script via Groq LLM, synthesises audio with **XTTS2** (zero-shot voice cloning), and returns the audio file. The file is automatically deleted after delivery.

---

## Quick start on Kaggle

### Step 1 — Clone the repo
```bash
git clone https://github.com/ahmed12545/bulul-api-library.git
cd bulul-api-library
```

### Step 2 — Add your voice reference files (optional)
You can either:
- **Use a built-in base speaker** (no files needed) — see [speaker-ID mode](#xtts2-base-speaker-id-mode) below.
- **Clone a voice** — place one or more `.wav` files (6–30 s of clear speech) in the `voice refs/` folder.

```
voice refs/
├── README.md        ← usage guide (always present)
├── my_voice.wav     ← your reference WAV (you add this)
└── ...
```

See [`voice refs/README.md`](voice%20refs/README.md) for guidelines on recording or obtaining reference audio.

### Step 3 — Run setup (Miniconda + conda env + XTTS2 deps)
```bash
bash setup_kaggle.sh
```
This will:
- Install Miniconda if not already present
- Accept Anaconda channel Terms of Service (required in non-interactive environments)
- Create one conda environment: **`bulul-xtts2`** (Python 3.10)
- Install PyTorch **2.1.2** + torchaudio **2.1.2** from the CUDA 12.1 wheel index (stage A)
- Install all remaining XTTS2-stack dependencies from `requirements.txt` (stage B):
  - `TTS==0.22.0`, `transformers==4.38.2`, `tokenizers==0.15.2`, `accelerate==0.27.2`
  - `sentencepiece==0.1.99`, `numpy==1.26.4`, `scipy<1.13`, `pydantic==2.6.4`
- Pre-download the XTTS2 model weights (~2 GB) with `COQUI_TOS_AGREED=1`
- Register the env as a Jupyter/Kaggle notebook kernel (`Python (bulul-xtts2)`)
- Set up `HF_HOME`, `TRANSFORMERS_CACHE`, and `TORCH_HOME` cache directories under `/kaggle/working/.cache/`

> **Note:** The script is idempotent — re-running it safely skips already-complete steps.

#### Why two install stages?

`torch` must be pulled from the PyTorch CUDA 12.1 wheel index
(`https://download.pytorch.org/whl/cu121`), which is not PyPI.
Installing it *before* `TTS==0.22.0` lets pip resolve the rest of the dependency
graph against the correct torch version and avoids `numpy`/`scipy` version
conflicts seen with a single-pass `pip install -r requirements.txt`.

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
1. Activate the `bulul-xtts2` conda env
2. Export `HF_HOME`, `TRANSFORMERS_CACHE`, and `TORCH_HOME` cache dirs
3. Start the FastAPI server on port 8000
4. Open an ngrok tunnel and print the public URL

> **Note:** On first run after setup XTTS2 may take a minute to load. Subsequent starts are faster.

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

# 3) (Optional) Add a reference WAV for voice cloning — or use --voice-id below instead
# run_streaming(f"cp /path/to/my_voice.wav '{REPO_DIR}/voice refs/my_voice.wav'")

# 4) Run full setup (Miniconda + conda env + XTTS2 deps + model download)
run_streaming(f"cd {REPO_DIR} && bash setup_kaggle.sh")

print("\n✅ Setup complete.")
print("  • Env: bulul-xtts2 (XTTS2 synthesis + API)")
print("  • Quick test with built-in speaker:")
print(f"      bash {REPO_DIR}/tests/test.sh --voice-id puck --text 'Hello from Puck.'")
print("  • List all built-in speaker IDs:")
print(f"      bash {REPO_DIR}/tests/test.sh --list-speakers")
print("  • Or place reference WAVs in 'voice refs/' for voice cloning.")
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
If none is present, a built-in XTTS2 speaker is used as fallback.

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
# Install deps into your Python environment
pip install -r requirements.txt

# Download XTTS2 assets (creates voice refs/ dir + pre-downloads model)
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

## XTTS2 voice cloning pipeline

### Overview

XTTS2 (Coqui TTS v2) synthesises speech directly in a target voice.  Two modes
are available:

```
# Mode 1 — built-in base speaker (no reference WAV required):
text + speaker-id  →  XTTS2  →  speech audio

# Mode 2 — voice cloning from a reference WAV:
text + reference WAV  →  XTTS2  →  cloned speech audio
```

### XTTS2 base speaker-ID mode

XTTS2 ships with a set of built-in voices you can use out of the box — no
reference WAV required.  Pass `--voice-id` to select one.

```bash
# Built-in speaker by ID
conda run -n bulul-xtts2 python -u scripts/synthesize.py \
    --text "Hello from Puck." \
    --output /tmp/puck.wav \
    --voice-id puck

conda run -n bulul-xtts2 python -u scripts/synthesize.py \
    --text "Hello from Fenrir." \
    --output /tmp/fenrir.wav \
    --voice-id fenrir

# List all available built-in speaker IDs
conda run -n bulul-xtts2 python -u scripts/synthesize.py --list-speakers
```

Speaker IDs are matched **case-insensitively** (`puck` → `Puck`).

Some common built-in speakers:

| ID (case-insensitive) | Style |
|---|---|
| `Puck` | Expressive male |
| `Fenrir` | Deep male |
| `Ana Florence` | Warm female |
| `Andrew Chipper` | Upbeat male |
| `Claribel Dervla` | Calm female |
| `Daisy Studious` | Clear female |

Run `--list-speakers` for the complete list from the loaded model.

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
# Built-in speaker by ID (no reference WAV needed)
conda run -n bulul-xtts2 python -u scripts/synthesize.py \
    --text "Welcome to the podcast." \
    --output /tmp/output.wav \
    --voice-id puck

# List all built-in speaker IDs
conda run -n bulul-xtts2 python -u scripts/synthesize.py --list-speakers

# Voice cloning from a specific reference WAV
conda run -n bulul-xtts2 python -u scripts/synthesize.py \
    --text "Welcome to the podcast." \
    --output /tmp/output.wav \
    --ref-wav "voice refs/my_voice.wav"

# Auto-detect first WAV in 'voice refs/' (omit --ref-wav)
conda run -n bulul-xtts2 python -u scripts/synthesize.py \
    --text "Welcome to the podcast." \
    --output /tmp/output.wav

# Different language (XTTS2 is multilingual)
conda run -n bulul-xtts2 python -u scripts/synthesize.py \
    --text "مرحباً بكم في البودكاست." \
    --output /tmp/arabic_output.wav \
    --ref-wav "voice refs/arabic_speaker.wav" \
    --language ar

# Force CPU inference (no GPU required)
conda run -n bulul-xtts2 python -u scripts/synthesize.py \
    --text "Welcome to the podcast." \
    --output /tmp/output_cpu.wav \
    --cpu
```

### End-to-end test script (`tests/test.sh`)

```bash
# Speaker-ID mode (no reference WAV needed)
bash tests/test.sh --voice-id puck --text "Hello from Puck."
bash tests/test.sh --voice-id fenrir --text "Hello from Fenrir."

# List all available built-in speaker IDs
bash tests/test.sh --list-speakers

# Voice-cloning mode (provide a reference WAV)
bash tests/test.sh \
    --text "Hello, this is a test." \
    --ref-wav "voice refs/my_voice.wav" \
    --output-dir /kaggle/working/voice_tests

# Default test (auto-detects first WAV in 'voice refs/' or uses built-in fallback)
bash tests/test.sh --text "Hello, this is a test."

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
| `xtts2_output.wav` | XTTS2 synthesised output |

#### Logs

All subprocess output is captured to `runtime/logs/test.log`. On failure the last 40 lines
are printed automatically. Pass `--verbose` to stream everything to the cell.

### Supported languages

XTTS2 is multilingual. Use `--language` to set the synthesis language:

| Code | Language |
|---|---|
| `en` | English (default) |
| `ar` | Arabic |
| `fr` | French |
| `de` | German |
| `es` | Spanish |
| `pt` | Portuguese |
| `pl` | Polish |
| `tr` | Turkish |
| `ru` | Russian |
| `nl` | Dutch |
| `cs` | Czech |
| `it` | Italian |
| `zh-cn` | Chinese (Simplified) |

### Headless / Kaggle compatibility defaults

`tests/test.sh` and `scripts/synthesize.py` automatically normalise `MPLBACKEND` to `Agg`
when the value is absent or is a Kaggle inline backend (`module://…`).

### Legacy flags (StyleTTS2 / RVC)

This project has **fully migrated to XTTS2**. StyleTTS2 and RVC have been removed.
If you pass any legacy flag, both `tests/test.sh` and `scripts/synthesize.py` will
exit immediately with a clear migration message:

| Legacy flag | Replacement |
|---|---|
| `--ckpt` | No equivalent — XTTS2 uses a single pre-downloaded model |
| `--ckpt-name` | No equivalent |
| `--voice-model` | `--ref-wav "voice refs/my_voice.wav"` |
| `--voice-index` | No equivalent |
| `--no-rvc` | No equivalent (RVC removed) |
| `--config` (RVC YAML) | Pass `--ref-wav` directly |
| `--diffusion-steps` | No equivalent |
| `--embedding-scale` | No equivalent |

---

## Project structure

```
bulul-api-library/
├── app.py               # FastAPI service (XTTS2-powered)
├── setup_kaggle.sh      # Miniconda + bulul-xtts2 conda env + XTTS2 setup
├── download_models.sh   # XTTS2 model pre-download + voice refs dir setup
├── host_service.sh      # Start API + ngrok tunnel (uses bulul-xtts2 env)
├── requirements.txt     # Python dependencies (includes TTS for XTTS2)
├── .env.example         # Example environment variables
├── voice refs/          # Place reference WAVs here for voice cloning
│   └── README.md        # Usage guide for voice reference files
├── scripts/
│   ├── synthesize.py    # XTTS2 inference helper (unbuffered, Kaggle-friendly)
│   └── rvc_convert.py   # Legacy stub — exits with migration message (RVC removed)
├── runtime/
│   ├── tmp/             # Temp audio files (auto-deleted, gitignored)
│   └── logs/            # Setup and test logs (gitignored)
└── tests/
    ├── test_app.py           # API route tests
    ├── test_scripts.sh       # Shell script smoke checks
    ├── test.sh               # End-to-end XTTS2 synthesis test
    └── podcast_6voices.yaml  # Multi-voice config template (XTTS2 ref_wav format)
```

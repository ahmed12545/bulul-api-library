# bulul-api-library

AI-powered podcast generation API. Accepts a topic and a CEFR language level (A1–C2), generates a 5–6 minute podcast script via Groq LLM, synthesises audio with StyleTTS2, and returns the audio file. The file is automatically deleted after delivery.

---

## Quick start on Kaggle

### Step 1 — Clone the repo
```bash
git clone https://github.com/ahmed12545/bulul-api-library.git
cd bulul-api-library
```

### Step 2 — Run setup (Miniconda + per-model envs + model download)
```bash
bash setup_kaggle.sh
```
This will:
- Install Miniconda if not already present
- Accept Anaconda channel Terms of Service (required in non-interactive environments)
- Create two **side-by-side** conda environments:
  - `bulul-styletts2` — StyleTTS2 TTS synthesis + API server
  - `bulul-rvc` — RVC voice conversion (isolated to avoid dependency conflicts)
- Install Python dependencies from `requirements.txt` in `bulul-styletts2`
- Install the **`styletts2` pip package** (provides the `styletts2.tts.StyleTTS2` inference API used by `scripts/synthesize.py`) and `einops_exts`
- Clone the StyleTTS2 source tree into `models/StyleTTS2/`
- Install StyleTTS2's runtime dependencies in `bulul-styletts2`
- Download **multiple StyleTTS2 voice checkpoints** into `models/styletts2/` (see below)
- Clone the RVC source into `models/RVC/`
- Install RVC's runtime dependencies in `bulul-rvc` (with `pip<24.1` pinning to fix the `fairseq/omegaconf` metadata conflict)
- Create `models/rvc/` for user-supplied RVC voice checkpoints
- Set up `HF_HOME`, `TRANSFORMERS_CACHE`, and `TORCH_HOME` cache directories under `/kaggle/working/.cache/`

> **Note:** The script is idempotent — re-running it safely skips already-complete steps.

#### Selecting which StyleTTS2 checkpoints to download

By default `setup_kaggle.sh` downloads **both** available voice checkpoints (LJSpeech and LibriTTS).
You can control this with `--checkpoints` (or the `STYLETTS2_CHECKPOINTS` env var):

| Label | Model | Description |
|---|---|---|
| `ljspeech` | StyleTTS2-LJSpeech | Single-speaker, female American English |
| `libri` | StyleTTS2-LibriTTS | Multi-speaker, various accents |

```bash
# Default: install both checkpoints (recommended)
bash setup_kaggle.sh

# Install only the LJSpeech checkpoint (faster, less storage)
bash setup_kaggle.sh --checkpoints ljspeech

# Install both explicitly
bash setup_kaggle.sh --checkpoints "ljspeech,libri"

# Using the env var instead
STYLETTS2_CHECKPOINTS="ljspeech,libri" bash setup_kaggle.sh
```

Up to **5** checkpoints can be installed simultaneously (the catalog currently has 2 official ones).

> **Note:** `ASR` utility weights (e.g. `epoch_00080.pth` inside `models/StyleTTS2/Utils/ASR/`) are
> **not** TTS voice checkpoints — they are internal synthesis helpers downloaded automatically by
> the `styletts2` pip package.  Only the files in `models/styletts2/` are selectable voice weights.

#### Output mode

By default setup runs in **quiet mode**: subprocess output is captured to
`runtime/logs/setup.log`. Only step summaries and errors are printed
(≈ 10 lines for a clean run). On failure the last 40 log lines are printed
automatically.

To see full output while debugging:
```bash
bash setup_kaggle.sh --verbose
```

### Step 3 — Start the service
```bash
bash host_service.sh
```
You will be prompted for:
- **GROQ API key** — get one at <https://console.groq.com>
- **ngrok auth token** — get one at <https://dashboard.ngrok.com>

The script will:
1. Activate the `bulul-styletts2` conda env and export `HF_HOME`, `TRANSFORMERS_CACHE`, and `TORCH_HOME` cache dirs
2. Set `PYTHONPATH` to include the cloned StyleTTS2 source
3. Start the FastAPI server on port 8000
4. Open an ngrok tunnel and print the public URL

> **Note:** On first run after setup the StyleTTS2 model weights are read into memory — this can take several minutes. Subsequent starts are faster.

### Quick Kaggle cell (clone + setup + model download)

Paste this into a Kaggle code cell to run the full setup end-to-end with live
progress output (no hanging):

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

# 3) Run full setup (Miniconda + side-by-side conda envs + deps + StyleTTS2 + RVC)
run_streaming(f"cd {REPO_DIR} && bash setup_kaggle.sh")

print("\n✅ Setup complete.")
print("  • Envs: bulul-styletts2 (TTS/API), bulul-rvc (voice conversion)")
print("  • Checkpoints installed: ljspeech (LJSpeech), libri (LibriTTS)")
print("  • Run 'bash host_service.sh' to start the API.")
print("  • Run 'bash tests/test.sh --help' for voice generation options.")
print("  • A/B test checkpoints: bash tests/test.sh --ckpt-name libri --no-rvc")
```

### Step 4 — Call the endpoint
```bash
# Replace <PUBLIC_URL> with the ngrok URL printed in step 3

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

# Download models
bash download_models.sh

# Set env vars and start
export GROQ_API_KEY=your_key
uvicorn app:app --host 0.0.0.0 --port 8000
```

---

## Running tests

```bash
# Python API tests (requires pytest and fastapi[testclient])
pip install pytest httpx
pytest tests/test_app.py -v

# Shell script smoke checks (no external dependencies)
bash tests/test_scripts.sh
```

---

## StyleTTS2 + RVC voice pipeline

The repository supports an end-to-end pipeline:

1. **StyleTTS2** synthesises natural-sounding speech from text (in the `bulul-styletts2` env).
2. **RVC** converts the voice identity to any target speaker while keeping the timing intact (in the isolated `bulul-rvc` env).

### Environment architecture

```
bulul-styletts2   ← StyleTTS2 TTS synthesis, FastAPI server
bulul-rvc         ← RVC voice conversion (separate deps, no conflicts)
```

Each environment is created and managed by `setup_kaggle.sh`. They are
**side-by-side siblings** (not nested), which avoids dependency conflicts
(especially the `fairseq` / `omegaconf` metadata issue in `pip≥24.1`).

### Required assets

| Asset | Path | How to obtain |
|---|---|---|
| StyleTTS2 checkpoint (LJSpeech) | `models/styletts2/epoch_2nd_00100.pth` | Downloaded by `bash setup_kaggle.sh` |
| StyleTTS2 checkpoint (LibriTTS) | `models/styletts2/epoch_2nd_00020_libri.pth` | Downloaded by `bash setup_kaggle.sh` |
| StyleTTS2 config (LJSpeech) | `models/styletts2/config.yml` | Downloaded by `bash setup_kaggle.sh` |
| StyleTTS2 config (LibriTTS) | `models/styletts2/config_libri.yml` | Downloaded by `bash setup_kaggle.sh` |
| StyleTTS2 source | `models/StyleTTS2/` | Cloned by `bash setup_kaggle.sh` |
| RVC source | `models/RVC/` | Cloned by `bash setup_kaggle.sh` |
| RVC voice model | `models/rvc/<name>.pth` | **You supply** — see below |
| RVC index (optional) | `models/rvc/<name>.index` | **You supply** — see below |

### Obtaining RVC voice models

1. Search for pre-trained voices at <https://huggingface.co/models?search=rvc>.
2. Download the `.pth` checkpoint (and optionally the `.index` file).
3. Place them in `models/rvc/`:

```
models/rvc/
├── my_voice.pth
└── my_voice.index   ← optional but recommended
```

### Running the pipeline manually

```bash
# Step 1 — Synthesise with StyleTTS2 (in bulul-styletts2 env)
# Default checkpoint (LJSpeech)
conda run -n bulul-styletts2 python -u scripts/synthesize.py \
    --text "Welcome to the podcast." \
    --output /tmp/base.wav

# Using the LibriTTS multi-speaker checkpoint
conda run -n bulul-styletts2 python -u scripts/synthesize.py \
    --text "Welcome to the podcast." \
    --output /tmp/base_libri.wav \
    --ckpt  models/styletts2/epoch_2nd_00020_libri.pth \
    --config models/styletts2/config_libri.yml

# Force CPU inference (no GPU required)
conda run -n bulul-styletts2 python -u scripts/synthesize.py \
    --text "Welcome to the podcast." \
    --output /tmp/base_cpu.wav \
    --cpu

# Step 2 — Convert voice with RVC (in bulul-rvc env)
conda run -n bulul-rvc python -u scripts/rvc_convert.py \
    --input  /tmp/base.wav \
    --output /tmp/converted.wav \
    --model  models/rvc/my_voice.pth \
    --index  models/rvc/my_voice.index \
    --pitch  0
```

### End-to-end test script (`tests/test.sh`)

`tests/test.sh` runs both steps in sequence with Kaggle-friendly progress output
(heartbeat every 30 s, unbuffered Python `-u`, per-step timeouts, quiet default).

#### Default (quiet) mode — ≤ 15 lines of output

```bash
# StyleTTS2 only (no RVC model required) — uses LJSpeech checkpoint by default
bash tests/test.sh --text "Hello, this is a test."

# Use the LibriTTS multi-speaker checkpoint instead
bash tests/test.sh --text "Hello, this is a test." --ckpt-name libri

# Force CPU inference (no GPU required)
bash tests/test.sh --text "Hello, this is a test." --cpu --no-rvc

# Full pipeline (StyleTTS2 → single RVC voice)
bash tests/test.sh \
    --text        "Hello, this is a test." \
    --voice-model models/rvc/my_voice.pth \
    --voice-index models/rvc/my_voice.index \
    --output-dir  /kaggle/working/voice_tests

# Multi-voice batch via config file (e.g. 6 voices for a podcast)
bash tests/test.sh --config tests/podcast_6voices.yaml

# All options
bash tests/test.sh --help
```

#### Verbose mode — full subprocess output

```bash
bash tests/test.sh --verbose --text "Hello."
```

#### Config file format (`tests/podcast_6voices.yaml`)

```yaml
text: "Optional text override for this config run."

voices:
  - label: speaker1
    model: models/rvc/speaker1.pth
    index: models/rvc/speaker1.index   # optional
    pitch: 0
  - label: speaker2
    model: models/rvc/speaker2.pth
    pitch: 0
  # ... add up to N voices
```

Copy `tests/podcast_6voices.yaml` as a template, fill in your `.pth` paths,
and run:

```bash
bash tests/test.sh --config tests/podcast_6voices.yaml
```

#### Output files

Files are written to `--output-dir` (default: `/kaggle/working/voice_tests`
on Kaggle, `./output/voice_tests` elsewhere):

| File | Description |
|---|---|
| `base_styletts2.wav` | Raw StyleTTS2 output |
| `rvc_<label>.wav` | RVC-converted output per voice |

#### Logs

All subprocess output is captured to `runtime/logs/test.log`. On failure the
last 40 lines are printed automatically. Pass `--verbose` to stream everything
to the cell.

### Kaggle anti-hang notes

- All Python steps are run with `python -u` (unbuffered stdout/stderr).
- A background heartbeat process prints `[heartbeat] still running…` every 30 s.
- Per-step `timeout` guards prevent silent hangs.
- Default quiet mode keeps cell output under 15 lines for normal runs.

### Headless / Kaggle compatibility defaults

`tests/test.sh` and `scripts/synthesize.py` automatically apply the following
runtime compatibility settings so synthesis works reliably in Kaggle notebooks
and other headless environments **without any manual `export` calls**.

| Variable | Default | Behaviour |
|---|---|---|
| `MPLBACKEND` | `Agg` | Forced to `Agg` when unset **or** when the value is an inline backend (`module://…`). A non-inline value you export explicitly (e.g. `TkAgg`) is preserved. |
| `TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD` | `1` | Set to `1` when unset. Restores legacy `torch.load()` behaviour for trusted local checkpoints. Caller can override to `0` to re-enable strict mode. |

To **override** either default, export the variable before calling the script:

```bash
export MPLBACKEND=TkAgg                         # use a different non-inline backend
export TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=0       # re-enable strict weights_only
bash tests/test.sh --text "Hello." --no-rvc
```

> **Root causes addressed:**
> - Kaggle injects `MPLBACKEND=module://matplotlib_inline.backend_inline` into
>   every shell session.  This value is valid inside the notebook kernel but
>   causes `ValueError: … is not a valid value for backend` when matplotlib is
>   imported in a `conda run` subprocess.  Both scripts now detect and override
>   any `module://` backend before the first matplotlib import.
> - PyTorch ≥2.6 changed `weights_only` default to `True`, causing
>   `_pickle.UnpicklingError` for trusted checkpoints that include non-tensor
>   objects.  `TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1` restores the pre-2.6
>   behaviour for all `torch.load()` calls in the process.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `No module named 'styletts2'` | `styletts2` pip package not installed in active env | Run `bash setup_kaggle.sh` or `pip install 'styletts2==0.1.6' einops_exts` |
| `No module named 'einops_exts'` | Missing dep for the yl4579 source tree | Same as above |
| `mamba: error: unrecognized arguments: -n …` | Kaggle's `mamba` is a Python test-runner, not the conda extension | `tests/test.sh` now skips PATH-based `mamba`; uses `conda` or `micromamba` only |
| `No working conda/micromamba env runner found` | Conda envs not set up in this session | Run `bash setup_kaggle.sh` first, or ensure Miniconda is at `~/miniconda3` |
| `No module named 'styletts2'` with `models/StyleTTS2` in `sys.path` | That tree is the yl4579 training layout (no `styletts2/` sub-package) | Install the pip package; setup now does this automatically |
| `cannot connect to X server` / matplotlib display errors | matplotlib tries to use a GUI backend in a headless environment | `MPLBACKEND=Agg` is forced automatically; export a different non-inline value to override |
| `ValueError: … is not a valid value for backend` with `module://matplotlib_inline…` | Kaggle injects an inline backend that is invalid outside the notebook kernel | Both scripts now detect and override `module://` backends before the first matplotlib import |
| `UnpicklingError` / `weights_only` warning when loading checkpoint | PyTorch ≥2.6 changed the default to `weights_only=True`, which rejects older pickled checkpoints | `TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1` is set by default; export `0` to restore strict mode |

---

## Project structure

```
bulul-api-library/
├── app.py               # FastAPI service
├── setup_kaggle.sh      # Miniconda + per-model conda envs + model setup
├── download_models.sh   # StyleTTS2+RVC source clone + checkpoint download (idempotent)
├── host_service.sh      # Start API + ngrok tunnel (uses bulul-styletts2 env)
├── requirements.txt     # Python dependencies (installed in bulul-styletts2)
├── .env.example         # Example environment variables
├── scripts/
│   ├── synthesize.py    # StyleTTS2 inference helper (unbuffered, Kaggle-friendly)
│   └── rvc_convert.py   # RVC voice-conversion helper (unbuffered, Kaggle-friendly)
├── models/
│   ├── StyleTTS2/       # Cloned StyleTTS2 source (added to PYTHONPATH at runtime)
│   ├── styletts2/       # Downloaded StyleTTS2 model weights (gitignored)
│   ├── RVC/             # Cloned RVC source (gitignored)
│   └── rvc/             # User-supplied RVC voice checkpoints (gitignored)
├── runtime/
│   ├── tmp/             # Temp audio files (auto-deleted, gitignored)
│   └── logs/            # Setup and test logs (gitignored)
└── tests/
    ├── test_app.py           # API route tests
    ├── test_scripts.sh       # Shell script smoke checks
    ├── test.sh               # End-to-end StyleTTS2 → RVC test (quiet + verbose modes)
    └── podcast_6voices.yaml  # Template config for 6-voice podcast test
```
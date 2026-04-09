# bulul-api-library

AI-powered podcast generation API. Accepts a topic and a CEFR language level (A1–C2), generates a 5–6 minute podcast script via Groq LLM, synthesises audio with StyleTTS2, and returns the audio file. The file is automatically deleted after delivery.

---

## Quick start on Kaggle

### Step 1 — Clone the repo
```bash
git clone https://github.com/ahmed12545/bulul-api-library.git
cd bulul-api-library
```

### Step 2 — Run setup (Miniconda + deps + model download)
```bash
bash setup_kaggle.sh
```
This will:
- Install Miniconda if not already present
- Accept Anaconda channel Terms of Service (required in non-interactive environments)
- Create a `bulul` conda environment with Python 3.10
- Install all Python dependencies from `requirements.txt`
- Clone the StyleTTS2 source tree into `models/StyleTTS2/` (it has no `setup.py`, so it cannot be pip-installed)
- Install StyleTTS2's runtime dependencies inside the conda env
- Download the StyleTTS2 model weights into `models/styletts2/`

### Step 3 — Start the service
```bash
bash host_service.sh
```
You will be prompted for:
- **GROQ API key** — get one at <https://console.groq.com>
- **ngrok auth token** — get one at <https://dashboard.ngrok.com>

The script will:
1. Activate the `bulul` conda env and set `PYTHONPATH` to include the cloned StyleTTS2 source
2. Start the FastAPI server on port 8000
3. Open an ngrok tunnel and print the public URL

### Quick Kaggle cell (clone + setup + model download)

Paste this into a Kaggle code cell to run the full setup end-to-end:

```python
import os, subprocess

REPO_URL = "https://github.com/ahmed12545/bulul-api-library.git"
REPO_DIR = "/kaggle/working/bulul-api-library"

def run(cmd, check=True):
    print(f"\n$ {cmd}")
    subprocess.run(cmd, shell=True, text=True, check=check)

# 1) Clone fresh (remove old copy if present)
if os.path.exists(REPO_DIR):
    run(f"rm -rf {REPO_DIR}")
run(f"git clone {REPO_URL} {REPO_DIR}")

# 2) Make scripts executable
run(f"chmod +x {REPO_DIR}/setup_kaggle.sh {REPO_DIR}/download_models.sh {REPO_DIR}/host_service.sh")

# 3) Run full setup (Miniconda + conda env + deps + model clone + checkpoint download)
run(f"cd {REPO_DIR} && bash setup_kaggle.sh")

print("\n✅ Setup complete — run 'bash host_service.sh' to start the API.")
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

## Project structure

```
bulul-api-library/
├── app.py               # FastAPI service
├── setup_kaggle.sh      # Miniconda + env + deps + model setup
├── download_models.sh   # StyleTTS2 source clone + checkpoint download (idempotent)
├── host_service.sh      # Start API + ngrok tunnel (sets PYTHONPATH for StyleTTS2)
├── requirements.txt     # Python dependencies
├── .env.example         # Example environment variables
├── models/
│   ├── StyleTTS2/       # Cloned StyleTTS2 source (added to PYTHONPATH at runtime)
│   └── styletts2/       # Downloaded model weights (gitignored)
├── runtime/tmp/         # Temp audio files (auto-deleted, gitignored)
└── tests/
    ├── test_app.py      # API route tests
    └── test_scripts.sh  # Shell script smoke checks
```
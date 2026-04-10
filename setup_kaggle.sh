#!/usr/bin/env bash
# setup_kaggle.sh — one-shot StyleTTS2 setup for Kaggle / headless environments
#
# Usage:
#   bash setup_kaggle.sh [--verbose]
#
# Options:
#   --verbose   Show full subprocess output instead of summary-only mode.
#               Default: quiet mode (logs written to runtime/logs/setup.log).
#
# Creates one conda environment:
#   bulul-styletts2  — StyleTTS2 voice synthesis + API server
#
# Re-running is safe (idempotent): already-complete steps are skipped.
#
# Migration note: XTTS2 removed by user request. RVC removed.
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=1; shift ;;
        *)            echo "[setup] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

ENV_STYLETTS2="bulul-styletts2"
PYTHON_VERSION="3.10"
MINICONDA_DIR="$HOME/miniconda3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/runtime/logs"
SETUP_LOG="$LOG_DIR/setup.log"

# ── Cache directory configuration (Kaggle-compatible paths) ──────────────────
export HF_HOME="${HF_HOME:-/kaggle/working/.cache/huggingface}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/kaggle/working/.cache/huggingface}"
export TORCH_HOME="${TORCH_HOME:-/kaggle/working/.cache/torch}"

# ── Logging helpers ───────────────────────────────────────────────────────────
log()     { echo "[setup] $*"; }
log_v()   { [ "$VERBOSE" -eq 1 ] && echo "[setup] $*" || true; }
ok()      { echo "[setup] ✅ $*"; }
warn()    { echo "[setup] ⚠️  $*"; }
die()     { echo "[setup] ❌ $*" >&2
            echo "[setup]    Full log: $SETUP_LOG" >&2
            tail -n 40 "$SETUP_LOG" 2>/dev/null >&2 || true
            exit 1; }

run_q() {
    if [ "$VERBOSE" -eq 1 ]; then
        "$@" 2>&1 | tee -a "$SETUP_LOG"
    else
        if ! "$@" >> "$SETUP_LOG" 2>&1; then
            echo "[setup] ❌ Command failed: $*" >&2
            tail -n 40 "$SETUP_LOG" >&2 || true
            return 1
        fi
    fi
}

mkdir -p "$LOG_DIR"
: > "$SETUP_LOG"

log_v "Log file: $SETUP_LOG"
log_v "Verbose mode enabled."

# ── 1. Install system dependency: espeak-ng (required by phonemizer) ──────────
log "Step 1/6 Installing espeak-ng (phonemizer system dependency)…"
if command -v espeak-ng >/dev/null 2>&1; then
    log_v "  espeak-ng already installed — skipping"
else
    log "  Installing espeak-ng via apt-get…"
    run_q apt-get install -y -q espeak-ng libespeak-ng-dev || \
        warn "apt-get install espeak-ng FAILED — phonemizer REQUIRES espeak-ng. Synthesis will fail without it. Install manually: sudo apt-get install -y espeak-ng libespeak-ng-dev"
fi
ok "espeak-ng ready"

# ── 2. Install Miniconda if not present ──────────────────────────────────────
log "Step 2/6 Checking Miniconda…"
if [ ! -d "$MINICONDA_DIR" ]; then
    log "  Miniconda not found — downloading installer…"
    INSTALLER="/tmp/miniconda_installer.sh"
    run_q wget -q "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh" \
        -O "$INSTALLER" || die "Failed to download Miniconda installer"
    run_q bash "$INSTALLER" -b -p "$MINICONDA_DIR" || die "Miniconda installation failed"
    rm -f "$INSTALLER"
    log_v "  Miniconda installed at $MINICONDA_DIR"
else
    log_v "  Miniconda present at $MINICONDA_DIR — skipping"
fi

# ── 3. Initialise conda for the current shell ─────────────────────────────────
export PATH="$MINICONDA_DIR/bin:$PATH"
# shellcheck source=/dev/null
source "$MINICONDA_DIR/etc/profile.d/conda.sh"
# Always use the explicit Miniconda binary to avoid PATH-dependent conda
# ambiguity (Kaggle notebooks may have a system conda earlier on PATH).
CONDA_EXE="$MINICONDA_DIR/bin/conda"

# ── 4. Accept Anaconda channel Terms of Service (required in non-interactive environments) ──
log "Step 3/6 Accepting Anaconda channel ToS…"
"$CONDA_EXE" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main >> "$SETUP_LOG" 2>&1 || true
"$CONDA_EXE" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r    >> "$SETUP_LOG" 2>&1 || true

# ── 5. Create StyleTTS2 conda environment ─────────────────────────────────────
log "Step 4/6 Creating conda env '$ENV_STYLETTS2'…"
if "$CONDA_EXE" env list | grep -qE "^${ENV_STYLETTS2}[[:space:]]"; then
    log_v "  Env '$ENV_STYLETTS2' already exists — skipping"
else
    log "  Creating '$ENV_STYLETTS2' (Python ${PYTHON_VERSION})…"
    run_q "$CONDA_EXE" create -y -n "$ENV_STYLETTS2" python="$PYTHON_VERSION" || \
        die "Failed to create conda env '$ENV_STYLETTS2'"
fi
ok "Conda env ready: $ENV_STYLETTS2"

# ── 6. Install Python dependencies ────────────────────────────────────────────
# Install in stages to avoid pip resolver conflicts.
#
# Stage A: pip / setuptools / wheel bootstrap.
# Stage B: PyTorch + torchaudio from the CUDA 12.1 wheel index.
#   Must come first so the resolver sees the correct torch version before
#   styletts2 is evaluated.
#
# Stage C: All StyleTTS2 runtime deps from requirements-styletts2.txt
#   (phonemizer, librosa, soundfile, scipy, numpy, transformers,
#    huggingface_hub>=0.20, nltk, gruut, einops, accelerate, …).
#   NOTE: styletts2 itself is intentionally NOT in requirements-styletts2.txt
#   because it pins huggingface_hub<0.20 which conflicts with the >=0.20
#   constraint required by the rest of the stack.
#
# Stage D: styletts2 itself, installed with --no-deps so its huggingface_hub
#   pin is skipped. All of its actual runtime deps are already installed in
#   Stage C, so this is safe.
#
# Stage E: Bootstrap NLTK tokenizer data (punkt_tab) required by
#   styletts2.tts at import time. Must happen after Stage C installs nltk.
log "Step 5/6 Installing deps in '$ENV_STYLETTS2'…"
REQS_STYLETTS2="$SCRIPT_DIR/requirements-styletts2.txt"
[ -f "$REQS_STYLETTS2" ] || die "requirements-styletts2.txt not found at $REQS_STYLETTS2"

log_v "  Stage A: upgrading pip / setuptools / wheel…"
run_q "$CONDA_EXE" run -n "$ENV_STYLETTS2" pip install --quiet --upgrade pip setuptools wheel

log_v "  Stage B: installing torch==2.1.2 + torchaudio==2.1.2 (CUDA 12.1)…"
run_q "$CONDA_EXE" run -n "$ENV_STYLETTS2" pip install --quiet --no-cache-dir \
    "torch==2.1.2" "torchaudio==2.1.2" \
    --index-url https://download.pytorch.org/whl/cu121 || \
    die "torch/torchaudio install failed in '$ENV_STYLETTS2'"

log_v "  Stage C: installing StyleTTS2 runtime deps from requirements-styletts2.txt…"
run_q "$CONDA_EXE" run -n "$ENV_STYLETTS2" pip install --quiet --no-cache-dir \
    -r "$REQS_STYLETTS2" || \
    die "pip install (StyleTTS2 deps) failed in '$ENV_STYLETTS2'"

log_v "  Stage D: installing styletts2 package (--no-deps to skip huggingface_hub pin)…"
run_q "$CONDA_EXE" run -n "$ENV_STYLETTS2" pip install --quiet --no-cache-dir \
    --no-deps "styletts2>=0.1,<2.0" || \
    die "pip install styletts2 --no-deps failed in '$ENV_STYLETTS2'"

log_v "  Stage E: downloading NLTK tokenizer data (punkt_tab required by styletts2.tts)…"
run_q "$CONDA_EXE" run -n "$ENV_STYLETTS2" python -c \
    "import nltk; nltk.download('punkt_tab', quiet=True); nltk.download('averaged_perceptron_tagger_eng', quiet=True); print('NLTK data ready')" || \
    warn "NLTK data download failed — synthesis may fail. Re-run 'bash setup_kaggle.sh' or manually: python -c \"import nltk; nltk.download('punkt_tab')\""

# ── 6b. Register env as a Jupyter/Kaggle kernel (optional, non-fatal) ─────────
run_q "$CONDA_EXE" run -n "$ENV_STYLETTS2" python -m ipykernel install \
    --user --name "$ENV_STYLETTS2" --display-name "Python ($ENV_STYLETTS2)" || true
log_v "  Python dependencies installed in '$ENV_STYLETTS2'"

# ── 6c. Hard fail-fast verification: styletts2 must be importable ─────────────
log_v "  Hard-verifying styletts2 is importable in '$ENV_STYLETTS2'…"
if ! "$CONDA_EXE" run -n "$ENV_STYLETTS2" \
        python -c "from styletts2 import tts; print('ok')" >> "$SETUP_LOG" 2>&1; then
    die "styletts2 not importable in '$ENV_STYLETTS2' after install — check $SETUP_LOG"
fi
ok "styletts2 verified in '$ENV_STYLETTS2'"

# ── 7. Download StyleTTS2 model and create runtime directories ────────────────
log "Step 6/6 Preparing StyleTTS2 assets and runtime dirs…"
run_q "$CONDA_EXE" run -n "$ENV_STYLETTS2" \
    env HF_HOME="$HF_HOME" \
        TRANSFORMERS_CACHE="$TRANSFORMERS_CACHE" \
        TORCH_HOME="$TORCH_HOME" \
        BULUL_VERBOSE="$VERBOSE" \
    bash "$SCRIPT_DIR/download_models.sh" || \
    die "Asset preparation failed"

mkdir -p "$SCRIPT_DIR/runtime/tmp"

ok "Setup complete."
log "  Conda exe        : $CONDA_EXE"
log "  StyleTTS2 env    : $ENV_STYLETTS2"
log "  Voice refs dir   : voice refs/  (place .wav reference files here)"
log "  Run 'bash host_service.sh' to start the API."
log "  Run 'bash tests/test.sh --help' for voice synthesis options."
log "  NOTE: First synthesis downloads the StyleTTS2 model weights (~0.5 GB)."

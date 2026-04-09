#!/usr/bin/env bash
# setup_kaggle.sh — one-shot setup for Kaggle demo
# Usage: bash setup_kaggle.sh
set -euo pipefail

CONDA_ENV_NAME="bulul"
PYTHON_VERSION="3.10"
MINICONDA_DIR="$HOME/miniconda3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Cache directory configuration (Kaggle-compatible paths) ──────────────────
export HF_HOME="${HF_HOME:-/kaggle/working/.cache/huggingface}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/kaggle/working/.cache/huggingface}"
export TORCH_HOME="${TORCH_HOME:-/kaggle/working/.cache/torch}"

log() { echo "[setup] $*"; }
die() { echo "[setup] ERROR: $*" >&2; exit 1; }

# ── 1. Install Miniconda if not present ──────────────────────────────────────
log "Step 1: Checking for Miniconda…"
if [ ! -d "$MINICONDA_DIR" ]; then
    log "Miniconda not found — downloading installer…"
    INSTALLER="/tmp/miniconda_installer.sh"
    wget -q "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh" \
        -O "$INSTALLER" || die "Failed to download Miniconda installer"
    bash "$INSTALLER" -b -p "$MINICONDA_DIR" || die "Miniconda installation failed"
    rm -f "$INSTALLER"
    log "Miniconda installed at $MINICONDA_DIR"
else
    log "Miniconda already present at $MINICONDA_DIR — skipping install"
fi

# ── 2. Initialise conda for the current shell ─────────────────────────────────
log "Initialising conda…"
export PATH="$MINICONDA_DIR/bin:$PATH"
# shellcheck source=/dev/null
source "$MINICONDA_DIR/etc/profile.d/conda.sh"

# ── 3. Accept Anaconda channel Terms of Service (required in non-interactive environments) ──
log "Step 3: Accepting Anaconda channel Terms of Service…"
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r    || true

# ── 4. Create conda environment if it does not exist ─────────────────────────
log "Step 4: Checking conda environment '${CONDA_ENV_NAME}'…"
if conda env list | grep -qE "^${CONDA_ENV_NAME}\s"; then
    log "Conda env '${CONDA_ENV_NAME}' already exists — skipping creation"
else
    log "Creating conda env '${CONDA_ENV_NAME}' with Python ${PYTHON_VERSION}…"
    conda create -y -n "$CONDA_ENV_NAME" python="$PYTHON_VERSION" || \
        die "Failed to create conda env"
fi

# ── 5. Install Python dependencies (via conda run for non-interactive reliability) ──
log "Step 5: Installing Python dependencies inside conda env '${CONDA_ENV_NAME}'…"
REQS="$SCRIPT_DIR/requirements.txt"
[ -f "$REQS" ] || die "requirements.txt not found at $REQS"
conda run -n "$CONDA_ENV_NAME" pip install --quiet --upgrade pip
conda run -n "$CONDA_ENV_NAME" pip install --quiet -r "$REQS" || die "pip install failed"
log "Python dependencies installed"

# ── 6. Create HuggingFace / Torch cache directories ──────────────────────────
log "Step 6: Creating cache directories…"
mkdir -p "$HF_HOME" "$TORCH_HOME"
log "Cache dirs: HF_HOME=$HF_HOME  TORCH_HOME=$TORCH_HOME"

# ── 7. Download models (explicitly inside conda env) ─────────────────────────
# Use `conda run` to guarantee the script executes inside the conda env even
# in non-interactive shells (e.g. Kaggle Jupyter) where `conda activate`
# alone may not propagate fully to subshells.
log "Step 7: Running model download script inside conda env '${CONDA_ENV_NAME}'…"
conda run -n "$CONDA_ENV_NAME" \
    env HF_HOME="$HF_HOME" TRANSFORMERS_CACHE="$TRANSFORMERS_CACHE" TORCH_HOME="$TORCH_HOME" \
    bash "$SCRIPT_DIR/download_models.sh" || \
    die "Model download failed"

# ── 8. Create runtime directories ─────────────────────────────────────────────
log "Step 8: Creating runtime directories…"
mkdir -p "$SCRIPT_DIR/runtime/tmp"
log "Runtime directories ready"

log "✅ Setup complete. Run 'bash host_service.sh' to start the API."
log "   (StyleTTS2 source is at $SCRIPT_DIR/models/StyleTTS2 — add to PYTHONPATH as needed)"
log "   NOTE: First model load at runtime may take several minutes while weights are read into memory."

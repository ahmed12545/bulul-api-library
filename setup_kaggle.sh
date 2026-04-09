#!/usr/bin/env bash
# setup_kaggle.sh — one-shot setup for Kaggle demo
# Usage: bash setup_kaggle.sh
set -euo pipefail

CONDA_ENV_NAME="bulul"
PYTHON_VERSION="3.10"
MINICONDA_DIR="$HOME/miniconda3"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[setup] $*"; }
die() { echo "[setup] ERROR: $*" >&2; exit 1; }

# ── 1. Install Miniconda if not present ──────────────────────────────────────
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
export PATH="$MINICONDA_DIR/bin:$PATH"
# shellcheck source=/dev/null
source "$MINICONDA_DIR/etc/profile.d/conda.sh"

# ── 3. Create conda environment if it does not exist ─────────────────────────
if conda env list | grep -qE "^${CONDA_ENV_NAME}\s"; then
    log "Conda env '${CONDA_ENV_NAME}' already exists — skipping creation"
else
    log "Creating conda env '${CONDA_ENV_NAME}' with Python ${PYTHON_VERSION}…"
    conda create -y -n "$CONDA_ENV_NAME" python="$PYTHON_VERSION" || \
        die "Failed to create conda env"
fi

# ── 4. Activate env and install Python dependencies ──────────────────────────
log "Activating conda env '${CONDA_ENV_NAME}'…"
conda activate "$CONDA_ENV_NAME"

REQS="$SCRIPT_DIR/requirements.txt"
[ -f "$REQS" ] || die "requirements.txt not found at $REQS"
log "Installing Python dependencies from requirements.txt…"
pip install --quiet --upgrade pip
pip install --quiet -r "$REQS" || die "pip install failed"

# ── 5. Download models (inside activated env) ─────────────────────────────────
log "Running model download script inside conda env…"
bash "$SCRIPT_DIR/download_models.sh" || die "Model download failed"

# ── 6. Create runtime directories ─────────────────────────────────────────────
mkdir -p "$SCRIPT_DIR/runtime/tmp"
log "Runtime directories ready"

log "✅ Setup complete. Run 'bash host_service.sh' to start the API."

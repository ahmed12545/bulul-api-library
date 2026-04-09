#!/usr/bin/env bash
# download_models.sh — download/prepare StyleTTS2 model artifacts
# Idempotent: safe to run multiple times.
# StyleTTS2 has no setup.py/pyproject.toml so it cannot be pip-installed as a
# package.  Instead we clone the source tree and install its requirements.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/models/styletts2"
STYLETTS2_SRC="$SCRIPT_DIR/models/StyleTTS2"
STYLETTS2_REPO="https://github.com/yl4579/StyleTTS2.git"

log() { echo "[download_models] $*"; }
die() { echo "[download_models] ERROR: $*" >&2; exit 1; }

mkdir -p "$MODELS_DIR"

# ── StyleTTS2 source (clone, not pip-install — repo has no setup.py) ──────────
if [ -d "$STYLETTS2_SRC/.git" ]; then
    log "StyleTTS2 source already present at $STYLETTS2_SRC — skipping clone"
else
    log "Cloning StyleTTS2 source (shallow)…"
    git clone --depth 1 "$STYLETTS2_REPO" "$STYLETTS2_SRC" || \
        die "Failed to clone StyleTTS2 from $STYLETTS2_REPO"
    log "StyleTTS2 source cloned to $STYLETTS2_SRC"
fi

# ── Install StyleTTS2 runtime dependencies inside the active Python env ────────
if [ -f "$STYLETTS2_SRC/requirements.txt" ]; then
    log "Installing StyleTTS2 runtime dependencies…"
    python -m pip install --quiet -r "$STYLETTS2_SRC/requirements.txt" || \
        die "Failed to install StyleTTS2 dependencies"
    log "StyleTTS2 dependencies installed"
else
    log "WARNING: $STYLETTS2_SRC/requirements.txt not found — skipping dep install"
fi

# ── Pretrained checkpoint (LJSpeech single-speaker, ~0.5 GB) ─────────────────
CKPT_URL="https://huggingface.co/yl4579/StyleTTS2-LJSpeech/resolve/main/Models/LJSpeech/epoch_2nd_00100.pth"
CKPT_FILE="$MODELS_DIR/epoch_2nd_00100.pth"

if [ -f "$CKPT_FILE" ]; then
    log "Checkpoint already present — skipping download"
else
    log "Downloading StyleTTS2 LJSpeech checkpoint (~0.5 GB)…"
    wget -q --show-progress "$CKPT_URL" -O "$CKPT_FILE" || \
        die "Failed to download checkpoint"
    log "Checkpoint saved to $CKPT_FILE"
fi

# ── Model config ──────────────────────────────────────────────────────────────
CONFIG_URL="https://huggingface.co/yl4579/StyleTTS2-LJSpeech/resolve/main/Models/LJSpeech/config.yml"
CONFIG_FILE="$MODELS_DIR/config.yml"

if [ -f "$CONFIG_FILE" ]; then
    log "Config already present — skipping download"
else
    log "Downloading model config…"
    wget -q "$CONFIG_URL" -O "$CONFIG_FILE" || die "Failed to download config"
    log "Config saved to $CONFIG_FILE"
fi

# ── Validate all required artifacts are present ────────────────────────────────
log "Validating model artifacts…"
[ -d "$STYLETTS2_SRC/.git" ] || die "StyleTTS2 source missing at $STYLETTS2_SRC"
[ -f "$CKPT_FILE" ]          || die "Checkpoint missing at $CKPT_FILE"
[ -f "$CONFIG_FILE" ]        || die "Config missing at $CONFIG_FILE"

log "✅ All model artifacts ready"
log "   StyleTTS2 source : $STYLETTS2_SRC"
log "   Checkpoint       : $CKPT_FILE"
log "   Config           : $CONFIG_FILE"

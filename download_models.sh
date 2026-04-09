#!/usr/bin/env bash
# download_models.sh — download/prepare StyleTTS2 model artifacts
# Idempotent: safe to run multiple times.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/models/styletts2"

log() { echo "[download_models] $*"; }
die() { echo "[download_models] ERROR: $*" >&2; exit 1; }

mkdir -p "$MODELS_DIR"

# ── StyleTTS2 Python package ──────────────────────────────────────────────────
# Install from GitHub (no published PyPI package with all assets).
# This step is safe to re-run; pip will skip if already installed.
log "Installing StyleTTS2 package…"
pip install --quiet \
    git+https://github.com/yl4579/StyleTTS2.git || \
    die "Failed to install StyleTTS2"

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

log "✅ Model files ready in $MODELS_DIR"

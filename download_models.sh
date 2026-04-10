#!/usr/bin/env bash
# download_models.sh — prepare StyleTTS2 assets (pre-download model, create voice refs dir)
#
# Idempotent: safe to run multiple times.
#
# Environment variables (set by setup_kaggle.sh):
#   BULUL_VERBOSE     — 1 for verbose output, 0 for quiet (default: 0)
#
# StyleTTS2 weights are downloaded from HuggingFace on first use.
# This script triggers that download so it does not happen during inference.
#
# Migration note: migrated to StyleTTS2 by user request. RVC removed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/runtime/logs"
DL_LOG="$LOG_DIR/download_models.log"

VERBOSE="${BULUL_VERBOSE:-0}"

# ── Cache directories (inherit from env or fall back to Kaggle defaults) ──────
export HF_HOME="${HF_HOME:-/kaggle/working/.cache/huggingface}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/kaggle/working/.cache/huggingface}"
export TORCH_HOME="${TORCH_HOME:-/kaggle/working/.cache/torch}"

# ── Logging helpers ───────────────────────────────────────────────────────────
log()   { echo "[download_models] $*"; }
log_v() { [ "$VERBOSE" -eq 1 ] && echo "[download_models] $*" || true; }
ok()    { echo "[download_models] ✅ $*"; }
warn()  { echo "[download_models] ⚠️  $*"; }
die()   { echo "[download_models] ❌ $*" >&2
          echo "[download_models]    Full log: $DL_LOG" >&2
          tail -n 40 "$DL_LOG" 2>/dev/null >&2 || true
          exit 1; }

run_q() {
    if [ "$VERBOSE" -eq 1 ]; then
        "$@" 2>&1 | tee -a "$DL_LOG"
    else
        if ! "$@" >> "$DL_LOG" 2>&1; then
            echo "[download_models] ❌ Command failed: $*" >&2
            tail -n 40 "$DL_LOG" >&2 || true
            return 1
        fi
    fi
}

mkdir -p "$LOG_DIR"
log_v "Cache dirs: HF_HOME=$HF_HOME  TORCH_HOME=$TORCH_HOME"
mkdir -p "$HF_HOME" "$TORCH_HOME"

# ── Step 1: Create 'voice refs' directory ─────────────────────────────────────
VOICE_REFS_DIR="$SCRIPT_DIR/voice refs"
log "Step 1/2 Checking 'voice refs' directory…"
if [ -d "$VOICE_REFS_DIR" ]; then
    log_v "  'voice refs/' already exists — skipping"
else
    mkdir -p "$VOICE_REFS_DIR"
    log_v "  Created 'voice refs/' at $VOICE_REFS_DIR"
fi

WAV_COUNT=$(find "$VOICE_REFS_DIR" -maxdepth 1 -name "*.wav" 2>/dev/null | wc -l)
if [ "$WAV_COUNT" -gt 0 ]; then
    ok "  Voice refs: ${WAV_COUNT} .wav file(s) found in 'voice refs/'"
else
    warn "  No .wav files found in 'voice refs/'."
    warn "  → Place reference WAVs (6–30 s of clear speech) in: $VOICE_REFS_DIR"
    warn "  → See 'voice refs/README.md' for usage guidance."
    warn "  → Synthesis will use the StyleTTS2 default voice until a reference is added."
fi

# ── Step 2: Pre-download StyleTTS2 model ──────────────────────────────────────
log "Step 2/2 Pre-downloading StyleTTS2 model from HuggingFace…"
log_v "  HF_HOME=$HF_HOME"

run_q python - << 'PY'
import os, sys
try:
    from styletts2 import tts as stts2
    print("[download_models] Initialising StyleTTS2 (downloads weights if not cached)…", flush=True)
    # Instantiating StyleTTS2() triggers the HuggingFace model download on first run.
    model = stts2.StyleTTS2()
    print("[download_models] StyleTTS2 model ready.", flush=True)
except Exception as exc:
    print(f"[download_models] WARNING: Could not pre-download StyleTTS2 model: {exc}", flush=True)
    print("[download_models]   The model will be downloaded automatically on first synthesis.", flush=True)
    sys.exit(0)   # non-fatal
PY

ok "All StyleTTS2 assets ready"
log_v "   HF cache       : $HF_HOME"
log_v "   Voice refs dir : $SCRIPT_DIR/voice refs"

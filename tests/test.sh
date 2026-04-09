#!/usr/bin/env bash
# tests/test.sh — End-to-end StyleTTS2 → RVC voice generation test
#
# Usage:
#   bash tests/test.sh [OPTIONS]
#
# Options:
#   --text TEXT           Text to synthesize (default: built-in podcast sample)
#   --output-dir DIR      Output directory   (default: /kaggle/working/voice_tests
#                                             or ./output/voice_tests if not on Kaggle)
#   --voice-model PATH    Path to RVC .pth model (skips RVC step if not provided)
#   --voice-index PATH    Path to RVC .index file (optional; improves RVC quality)
#   --pitch N             Pitch shift in semitones for RVC (default: 0)
#   --method METHOD       RVC pitch method: rmvpe|harvest|crepe|pm (default: rmvpe)
#   --timeout-tts N       Max seconds for StyleTTS2 step (default: 600)
#   --timeout-rvc N       Max seconds per RVC conversion   (default: 300)
#   --no-rvc              Skip RVC step even if --voice-model is given
#   --help                Show this help and exit
#
# Kaggle anti-hang:
#   A heartbeat line is printed every 30 s while long steps are running, so the
#   notebook cell never appears silent.  Python scripts are run with -u
#   (unbuffered) so their output streams to the cell in real time.
#
# Required assets (before running):
#   models/styletts2/epoch_2nd_00100.pth   — StyleTTS2 checkpoint
#   models/styletts2/config.yml             — StyleTTS2 config
#   models/StyleTTS2/                       — StyleTTS2 source tree
#   models/rvc/<name>.pth                   — RVC model (for voice conversion)
#   models/rvc/<name>.index                 — RVC index (optional)
#
# Run 'bash setup_kaggle.sh' to download all StyleTTS2 and RVC assets.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONDA_ENV_NAME="bulul"
MINICONDA_DIR="${HOME}/miniconda3"

DEFAULT_OUTPUT_DIR="/kaggle/working/voice_tests"
[ -d "/kaggle/working" ] || DEFAULT_OUTPUT_DIR="${REPO_ROOT}/output/voice_tests"

TEXT="Welcome to the Bulul podcast. Today we explore the intersection of technology and everyday life, with clear insights and practical takeaways for every listener."
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
VOICE_MODEL=""
VOICE_INDEX=""
PITCH=0
METHOD="rmvpe"
TIMEOUT_TTS=600
TIMEOUT_RVC=300
SKIP_RVC=0

# ── Logging helpers ───────────────────────────────────────────────────────────
log()  { echo "[test] $*"; }
ok()   { echo "[test] ✅ $*"; }
warn() { echo "[test] ⚠️  $*"; }
fail() { echo "[test] ❌ $*" >&2; }
die()  { fail "$*"; exit 1; }

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --text)         TEXT="$2";         shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2";   shift 2 ;;
        --voice-model)  VOICE_MODEL="$2";  shift 2 ;;
        --voice-index)  VOICE_INDEX="$2";  shift 2 ;;
        --pitch)        PITCH="$2";        shift 2 ;;
        --method)       METHOD="$2";       shift 2 ;;
        --timeout-tts)  TIMEOUT_TTS="$2";  shift 2 ;;
        --timeout-rvc)  TIMEOUT_RVC="$2";  shift 2 ;;
        --no-rvc)       SKIP_RVC=1;        shift   ;;
        --help)
            sed -n '3,/^set -/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Heartbeat: print a line every 30 s while a step is running ───────────────
# Usage: heartbeat_start; ... ; heartbeat_stop
_HEARTBEAT_PID=""
heartbeat_start() {
    ( while true; do sleep 30; echo "[heartbeat] still running… $(date '+%H:%M:%S')"; done ) &
    _HEARTBEAT_PID=$!
}
heartbeat_stop() {
    if [ -n "$_HEARTBEAT_PID" ]; then
        kill "$_HEARTBEAT_PID" 2>/dev/null || true
        _HEARTBEAT_PID=""
    fi
}
trap 'heartbeat_stop' EXIT INT TERM

# ── Conda activation helper ───────────────────────────────────────────────────
# We prefer 'conda run' (works in non-interactive Kaggle cells) but also try
# a plain activation path so the script works in interactive shells too.
PYTHON_CMD="python"
HAVE_CONDA=0
if [ -f "$MINICONDA_DIR/etc/profile.d/conda.sh" ]; then
    # shellcheck source=/dev/null
    source "$MINICONDA_DIR/etc/profile.d/conda.sh"
    if conda env list 2>/dev/null | grep -qE "^${CONDA_ENV_NAME}\s"; then
        HAVE_CONDA=1
        PYTHON_CMD="conda run -n $CONDA_ENV_NAME python"
        log "Using conda env '${CONDA_ENV_NAME}'"
    fi
fi
if [ "$HAVE_CONDA" -eq 0 ]; then
    warn "Conda env '${CONDA_ENV_NAME}' not found — using system python"
fi

# ── Environment variables (cache dirs) ───────────────────────────────────────
export HF_HOME="${HF_HOME:-/kaggle/working/.cache/huggingface}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/kaggle/working/.cache/huggingface}"
export TORCH_HOME="${TORCH_HOME:-/kaggle/working/.cache/torch}"
export PYTHONPATH="${REPO_ROOT}/models/StyleTTS2:${PYTHONPATH:-}"

# ── Summary ───────────────────────────────────────────────────────────────────
log "===== Bulul end-to-end voice test ====="
log "Repo root    : $REPO_ROOT"
log "Output dir   : $OUTPUT_DIR"
log "Text length  : ${#TEXT} chars"
[ -n "$VOICE_MODEL" ] && log "Voice model  : $VOICE_MODEL" || log "Voice model  : (none — RVC step will be skipped)"
[ -n "$VOICE_INDEX" ] && log "Voice index  : $VOICE_INDEX"
log "========================================"

mkdir -p "$OUTPUT_DIR"

# ── Step 1: Validate required StyleTTS2 assets ───────────────────────────────
log "Step 1/3: Validating StyleTTS2 assets…"
CKPT="$REPO_ROOT/models/styletts2/epoch_2nd_00100.pth"
CFG="$REPO_ROOT/models/styletts2/config.yml"
STYLETTS2_SRC="$REPO_ROOT/models/StyleTTS2"

ASSETS_OK=1
[ -f "$CKPT" ]             || { warn "Missing checkpoint : $CKPT";         ASSETS_OK=0; }
[ -f "$CFG" ]              || { warn "Missing config     : $CFG";           ASSETS_OK=0; }
[ -d "$STYLETTS2_SRC" ]    || { warn "Missing StyleTTS2 source: $STYLETTS2_SRC"; ASSETS_OK=0; }

if [ "$ASSETS_OK" -eq 0 ]; then
    die "Required assets missing. Run 'bash setup_kaggle.sh' to download them."
fi
ok "StyleTTS2 assets validated"

# ── Step 2: StyleTTS2 synthesis ───────────────────────────────────────────────
TTS_OUTPUT="$OUTPUT_DIR/base_styletts2.wav"
log "Step 2/3: Synthesising with StyleTTS2 (timeout ${TIMEOUT_TTS}s)…"
log "  Output: $TTS_OUTPUT"

heartbeat_start

TTS_EXIT=0
timeout "$TIMEOUT_TTS" \
    $PYTHON_CMD -u "$REPO_ROOT/scripts/synthesize.py" \
        --text  "$TEXT" \
        --output "$TTS_OUTPUT" \
        --ckpt  "$CKPT" \
        --config "$CFG" \
    || TTS_EXIT=$?

heartbeat_stop

if [ "$TTS_EXIT" -eq 124 ]; then
    die "StyleTTS2 synthesis timed out after ${TIMEOUT_TTS}s"
elif [ "$TTS_EXIT" -ne 0 ]; then
    die "StyleTTS2 synthesis failed (exit code $TTS_EXIT)"
fi

[ -f "$TTS_OUTPUT" ] || die "StyleTTS2 output not created: $TTS_OUTPUT"
TTS_SIZE=$(wc -c < "$TTS_OUTPUT")
ok "StyleTTS2 synthesis complete → $TTS_OUTPUT (${TTS_SIZE} bytes)"

# ── Step 3: RVC voice conversion ──────────────────────────────────────────────
if [ "$SKIP_RVC" -eq 1 ] || [ -z "$VOICE_MODEL" ]; then
    warn "Skipping RVC step (no --voice-model provided or --no-rvc set)."
    warn "  Base StyleTTS2 audio is at: $TTS_OUTPUT"
    log "Test complete (StyleTTS2 only). Output: $TTS_OUTPUT"
    exit 0
fi

if [ ! -f "$VOICE_MODEL" ]; then
    fail "RVC model not found: $VOICE_MODEL"
    fail "  Place a .pth file in models/rvc/ and pass --voice-model models/rvc/<file>.pth"
    exit 1
fi

RVC_SRC="$REPO_ROOT/models/RVC"
if [ ! -d "$RVC_SRC/infer" ]; then
    fail "RVC source not found at $RVC_SRC"
    fail "  Run 'bash setup_kaggle.sh' to clone it."
    exit 1
fi

MODEL_STEM="$(basename "$VOICE_MODEL" .pth)"
RVC_OUTPUT="$OUTPUT_DIR/rvc_${MODEL_STEM}.wav"
log "Step 3/3: RVC voice conversion (timeout ${TIMEOUT_RVC}s)…"
log "  Model  : $VOICE_MODEL"
log "  Output : $RVC_OUTPUT"

RVC_ARGS=(
    --input  "$TTS_OUTPUT"
    --output "$RVC_OUTPUT"
    --model  "$VOICE_MODEL"
    --pitch  "$PITCH"
    --method "$METHOD"
)
[ -n "$VOICE_INDEX" ] && RVC_ARGS+=(--index "$VOICE_INDEX")

heartbeat_start

RVC_EXIT=0
timeout "$TIMEOUT_RVC" \
    $PYTHON_CMD -u "$REPO_ROOT/scripts/rvc_convert.py" "${RVC_ARGS[@]}" \
    || RVC_EXIT=$?

heartbeat_stop

if [ "$RVC_EXIT" -eq 124 ]; then
    die "RVC conversion timed out after ${TIMEOUT_RVC}s"
elif [ "$RVC_EXIT" -ne 0 ]; then
    die "RVC conversion failed (exit code $RVC_EXIT)"
fi

[ -f "$RVC_OUTPUT" ] || die "RVC output not created: $RVC_OUTPUT"
RVC_SIZE=$(wc -c < "$RVC_OUTPUT")
ok "RVC conversion complete → $RVC_OUTPUT (${RVC_SIZE} bytes)"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "===== Test results ====="
log "  StyleTTS2 base : $TTS_OUTPUT"
log "  RVC converted  : $RVC_OUTPUT"
log "========================"
ok "All steps passed."

#!/usr/bin/env bash
# tests/test.sh — End-to-end StyleTTS2 voice synthesis test
#
# Usage:
#   bash tests/test.sh [OPTIONS]
#
# Options:
#   --text TEXT           Text to synthesize (default: built-in sample)
#   --output-dir DIR      Output directory   (default: /kaggle/working/voice_tests
#                                             or ./output/voice_tests if not on Kaggle)
#   --ref-wav PATH        Reference WAV for voice cloning (default: first .wav in 'voice refs/')
#   --diffusion-steps N   StyleTTS2 diffusion steps (default: 5)
#   --embedding-scale F   StyleTTS2 style intensity (default: 1.0)
#   --cpu                 Force CPU inference (default: auto-select GPU if available)
#   --timeout N           Max seconds for synthesis step (default: 600)
#   --verbose             Show full subprocess output (default: quiet/summary mode)
#   --help                Show this help and exit
#
# Voice-cloning mode (provide a reference WAV):
#   bash tests/test.sh --ref-wav "voice refs/my_voice.wav" --text "Hello."
#
# Default voice mode (no reference WAV needed):
#   bash tests/test.sh --text "Hello world."
#
# Legacy flags that are no longer accepted (will fail fast with a clear message):
#   --voice-id, --list-speakers (XTTS2 built-in speakers — removed)
#   --ckpt, --ckpt-name, --voice-model, --voice-index, --no-rvc (RVC — removed)
#   --config (old RVC YAML), --pitch, --method, --timeout-tts, --timeout-rvc
#
# Output modes:
#   Default (quiet): ≤15 lines total for a successful run; subprocess output
#     is captured to runtime/logs/test.log. On failure the last 40 log lines
#     are printed automatically.
#   --verbose: all subprocess output streams to stdout in real time.
#
# Kaggle anti-hang:
#   A heartbeat line is printed every 30 s while long steps are running, so
#   the notebook cell never appears silent.  Python is run with -u
#   (unbuffered) so output streams to the cell in real time.
#
# Run 'bash setup_kaggle.sh' to install all StyleTTS2 dependencies.
#
# Migration note: XTTS2 removed by user request. RVC removed.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_STYLETTS2="bulul-styletts2"
MINICONDA_DIR="${HOME}/miniconda3"
LOG_DIR="$REPO_ROOT/runtime/logs"
TEST_LOG="$LOG_DIR/test.log"

DEFAULT_OUTPUT_DIR="/kaggle/working/voice_tests"
[ -d "/kaggle/working" ] || DEFAULT_OUTPUT_DIR="${REPO_ROOT}/output/voice_tests"

TEXT="Welcome to the Bulul podcast. Today we explore the intersection of technology and everyday life, with clear insights and practical takeaways for every listener."
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
REF_WAV=""
DIFFUSION_STEPS=5
EMBEDDING_SCALE="1.0"
USE_CPU=0
TIMEOUT=600
VERBOSE=0

# ── Logging helpers ───────────────────────────────────────────────────────────
log()  { echo "[test] $*"; }
ok()   { echo "[test] ✅ $*"; }
warn() { echo "[test] ⚠️  $*"; }
fail() { echo "[test] ❌ $*" >&2; }
die()  { fail "$*"
         echo "[test]    Full log: $TEST_LOG" >&2
         tail -n 40 "$TEST_LOG" 2>/dev/null >&2 || true
         exit 1; }

# run_q CMD...: run capturing output; print only on failure (or always if VERBOSE)
run_q() {
    if [ "$VERBOSE" -eq 1 ]; then
        "$@" 2>&1 | tee -a "$TEST_LOG"
    else
        if ! "$@" >> "$TEST_LOG" 2>&1; then
            echo "[test] ❌ Command failed: $*" >&2
            tail -n 40 "$TEST_LOG" >&2 || true
            return 1
        fi
    fi
}

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --text)            TEXT="$2";             shift 2 ;;
        --output-dir)      OUTPUT_DIR="$2";       shift 2 ;;
        --ref-wav)         REF_WAV="$2";          shift 2 ;;
        --diffusion-steps) DIFFUSION_STEPS="$2";  shift 2 ;;
        --embedding-scale) EMBEDDING_SCALE="$2";  shift 2 ;;
        --cpu)             USE_CPU=1;             shift   ;;
        --timeout)         TIMEOUT="$2";          shift 2 ;;
        --verbose|-v)      VERBOSE=1;             shift   ;;
        --help)
            sed -n '3,/^set -/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        --voice-id|--list-speakers)
            die "Legacy flag '$1' is not supported. XTTS2 built-in speakers have been removed." \
                "This project now uses StyleTTS2 with reference-WAV voice cloning." \
                "Use --ref-wav 'voice refs/my_voice.wav' for voice cloning," \
                "or omit --ref-wav to use the StyleTTS2 default voice." \
                "Run 'bash tests/test.sh --help' for current options."
            ;;
        --ckpt|--ckpt-name|--voice-model|--voice-index|--no-rvc|--pitch|--method|--timeout-tts|--timeout-rvc)
            die "Legacy flag '$1' is not supported. RVC has been removed from this project." \
                "Use --ref-wav 'voice refs/my_voice.wav' for StyleTTS2 voice cloning." \
                "Run 'bash tests/test.sh --help' for current options."
            ;;
        --config)
            die "The --config (RVC YAML) flag is not supported. RVC has been removed." \
                "Use --ref-wav 'voice refs/my_voice.wav' for StyleTTS2 voice cloning." \
                "Run 'bash tests/test.sh --help' for current options."
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Set up log file ───────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR" "$OUTPUT_DIR"
: > "$TEST_LOG"

# ── Heartbeat: print a line every 30 s while a step is running ───────────────
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

# ── Env runner detection ──────────────────────────────────────────────────────
_ENV_RUNNER=""   # "conda" | "micromamba" | "" (direct python fallback)
_CONDA_EXE=""    # absolute path to conda executable (set when _ENV_RUNNER=conda)

# Prefer the explicit Miniconda binary to avoid PATH-dependent conda ambiguity.
if [ -x "$MINICONDA_DIR/bin/conda" ]; then
    _CONDA_EXE="$MINICONDA_DIR/bin/conda"
    # shellcheck source=/dev/null
    [ -f "$MINICONDA_DIR/etc/profile.d/conda.sh" ] && source "$MINICONDA_DIR/etc/profile.d/conda.sh" || true
    if "$_CONDA_EXE" env list 2>/dev/null | grep -qE "^${ENV_STYLETTS2}[[:space:]]"; then
        _ENV_RUNNER="conda"
    fi
elif [ -f "$MINICONDA_DIR/etc/profile.d/conda.sh" ]; then
    # shellcheck source=/dev/null
    source "$MINICONDA_DIR/etc/profile.d/conda.sh"
    if conda env list 2>/dev/null | grep -qE "^${ENV_STYLETTS2}[[:space:]]"; then
        _ENV_RUNNER="conda"
        _CONDA_EXE="$(command -v conda 2>/dev/null || true)"
    fi
fi

if [ -z "$_ENV_RUNNER" ] && command -v micromamba >/dev/null 2>&1; then
    if micromamba env list 2>/dev/null | grep -qE "^${ENV_STYLETTS2}[[:space:]]"; then
        _ENV_RUNNER="micromamba"
    fi
fi

python_cmd() {
    local env="$1"
    case "$_ENV_RUNNER" in
        conda)      echo "$_CONDA_EXE run -n $env python" ;;
        micromamba) echo "micromamba run -n $env python" ;;
        *)          echo "python" ;;
    esac
}

STYLETTS2_PYTHON_CMD="$(python_cmd "$ENV_STYLETTS2")"

if [ -n "$_ENV_RUNNER" ]; then
    log "Env runner : $_ENV_RUNNER"
    log "Conda exe  : ${_CONDA_EXE:-<from PATH>}"
    log "StyleTTS2 env : $ENV_STYLETTS2"
    _SYNTH_PYTHON="$($_CONDA_EXE run -n "$ENV_STYLETTS2" python -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
    [ -n "$_SYNTH_PYTHON" ] && log "Python exe : $_SYNTH_PYTHON"
else
    warn "No working conda/micromamba env runner found for '$ENV_STYLETTS2'."
    warn "  Falling back to system python — ensure all deps are installed."
    warn "  To set up the StyleTTS2 environment, run: bash setup_kaggle.sh"
fi

# ── Preflight: verify styletts2 is importable in the runner env ───────────────
# This surfaces missing-package failures before the long synthesis timeout.
if [ -n "$_ENV_RUNNER" ]; then
    log "Preflight: checking styletts2 importable in '$ENV_STYLETTS2'…"
    PREFLIGHT_EXIT=0
    $STYLETTS2_PYTHON_CMD -c \
        "from styletts2 import tts; print('[preflight] styletts2 OK')" \
        >> "$TEST_LOG" 2>&1 || PREFLIGHT_EXIT=$?
    if [ "$PREFLIGHT_EXIT" -ne 0 ]; then
        MISSING_MOD=$(grep -oP "No module named '\K[^']+" "$TEST_LOG" | tail -1 || true)
        fail "Preflight FAILED — styletts2 not importable in '$ENV_STYLETTS2'"
        fail "  Python interpreter: ${_SYNTH_PYTHON:-unknown}"
        if [ -n "$MISSING_MOD" ]; then
            fail "  Missing module: '$MISSING_MOD'"
            fail "  Fix: ${_CONDA_EXE:-conda} run -n $ENV_STYLETTS2 pip install $MISSING_MOD"
            fail "  Or reinstall all deps: bash setup_kaggle.sh"
        else
            fail "  Fix by running: bash setup_kaggle.sh"
            fail "  Or manually: ${_CONDA_EXE:-conda} run -n $ENV_STYLETTS2 pip install styletts2"
        fi
        fail "  Log: $TEST_LOG"
        tail -n 20 "$TEST_LOG" >&2 || true
        exit 1
    fi
    ok "Preflight passed: styletts2 importable in '$ENV_STYLETTS2'"
fi

# ── Environment variables ─────────────────────────────────────────────────────
export HF_HOME="${HF_HOME:-/kaggle/working/.cache/huggingface}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/kaggle/working/.cache/huggingface}"
export TORCH_HOME="${TORCH_HOME:-/kaggle/working/.cache/torch}"

# MPLBACKEND: normalise Kaggle inline backend to Agg for headless subprocess use.
case "${MPLBACKEND:-}" in
    ""|module://*) export MPLBACKEND="Agg" ;;
esac
log "Runtime: MPLBACKEND=$MPLBACKEND"

# ── Resolve reference WAV ─────────────────────────────────────────────────────
VOICE_REFS_DIR="$REPO_ROOT/voice refs"
if [ -z "$REF_WAV" ]; then
    FOUND_WAV=$(find "$VOICE_REFS_DIR" -maxdepth 1 -name "*.wav" | sort | head -1 2>/dev/null || true)
    if [ -n "$FOUND_WAV" ]; then
        REF_WAV="$FOUND_WAV"
        log "Ref WAV    : $REF_WAV (auto-detected)"
    else
        warn "No reference WAV provided and none found in 'voice refs/'."
        warn "  StyleTTS2 will use its default voice."
        warn "  For voice cloning: place a .wav file in 'voice refs/' or use --ref-wav."
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log "===== Bulul StyleTTS2 voice test ====="
log "Output dir       : $OUTPUT_DIR"
log "Diffusion steps  : $DIFFUSION_STEPS"
log "Embedding scale  : $EMBEDDING_SCALE"
log "Device           : $([ "$USE_CPU" -eq 1 ] && echo 'cpu (--cpu)' || echo 'auto (GPU if available)')"
if [ "${#TEXT}" -gt 60 ]; then
    log "Text             : ${TEXT:0:60}…"
else
    log "Text             : $TEXT"
fi
if [ -n "$REF_WAV" ]; then
    log "Ref WAV          : $REF_WAV"
else
    log "Ref WAV          : (none — using StyleTTS2 default voice)"
fi
log "======================================"

# ── Step 1: Validate reference WAV (if provided) ──────────────────────────────
log "1/2 Checking voice source…"
if [ -n "$REF_WAV" ]; then
    [ -f "$REF_WAV" ] || die "Reference WAV not found: $REF_WAV  (place .wav files in 'voice refs/')"
    ok "1/2 Reference WAV found: $REF_WAV"
else
    ok "1/2 No voice source specified — using StyleTTS2 default voice"
fi

# ── Step 2: StyleTTS2 synthesis ───────────────────────────────────────────────
SYNTH_OUTPUT="$OUTPUT_DIR/styletts2_output.wav"

SYNTH_ARGS=(
    --text    "$TEXT"
    --output  "$SYNTH_OUTPUT"
    --diffusion-steps "$DIFFUSION_STEPS"
    --embedding-scale "$EMBEDDING_SCALE"
)
[ "$USE_CPU" -eq 1 ] && SYNTH_ARGS+=(--cpu)
[ -n "$REF_WAV" ]    && SYNTH_ARGS+=(--ref-wav "$REF_WAV")

_device_note=""
[ "$USE_CPU" -eq 1 ] && _device_note=", CPU mode"
log "2/2 Synthesising with StyleTTS2 (max ${TIMEOUT}s${_device_note})…"

heartbeat_start

SYNTH_EXIT=0
timeout "$TIMEOUT" \
    $STYLETTS2_PYTHON_CMD -u "$REPO_ROOT/scripts/synthesize.py" \
        "${SYNTH_ARGS[@]}" \
    >> "$TEST_LOG" 2>&1 || SYNTH_EXIT=$?

heartbeat_stop

if [ "$SYNTH_EXIT" -eq 124 ]; then
    die "StyleTTS2 synthesis timed out after ${TIMEOUT}s"
elif [ "$SYNTH_EXIT" -ne 0 ]; then
    die "StyleTTS2 synthesis failed (exit code $SYNTH_EXIT)"
fi

[ -f "$SYNTH_OUTPUT" ] || die "StyleTTS2 output not created: $SYNTH_OUTPUT"
SYNTH_SIZE=$(wc -c < "$SYNTH_OUTPUT")
ok "2/2 styletts2_output.wav (${SYNTH_SIZE} bytes)"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "===== Results ====="
log "  StyleTTS2 output : $SYNTH_OUTPUT"
log "  Output dir       : $OUTPUT_DIR"
log "=================="

ok "All steps passed."

#!/usr/bin/env bash
# tests/test.sh — End-to-end XTTS2 voice synthesis test
#
# Usage:
#   bash tests/test.sh [OPTIONS]
#
# Options:
#   --text TEXT           Text to synthesize (default: built-in sample)
#   --output-dir DIR      Output directory   (default: /kaggle/working/voice_tests
#                                             or ./output/voice_tests if not on Kaggle)
#   --ref-wav PATH        Reference WAV for voice cloning (default: first .wav in 'voice refs/')
#   --language LANG       Language code (default: en)
#   --cpu                 Force CPU inference (default: auto-select GPU if available)
#   --timeout N           Max seconds for synthesis step (default: 600)
#   --verbose             Show full subprocess output (default: quiet/summary mode)
#   --help                Show this help and exit
#
# Legacy flags that are no longer accepted (will fail fast with a clear message):
#   --ckpt, --ckpt-name, --voice-model, --voice-index, --no-rvc,
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
# Required assets (before running):
#   voice refs/<name>.wav   — reference WAV for voice cloning (3–30 s of clear speech)
#
# Run 'bash setup_kaggle.sh' to install all XTTS2 dependencies.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_XTTS2="bulul-xtts2"
MINICONDA_DIR="${HOME}/miniconda3"
LOG_DIR="$REPO_ROOT/runtime/logs"
TEST_LOG="$LOG_DIR/test.log"

DEFAULT_OUTPUT_DIR="/kaggle/working/voice_tests"
[ -d "/kaggle/working" ] || DEFAULT_OUTPUT_DIR="${REPO_ROOT}/output/voice_tests"

TEXT="Welcome to the Bulul podcast. Today we explore the intersection of technology and everyday life, with clear insights and practical takeaways for every listener."
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
REF_WAV=""
LANGUAGE="en"
USE_CPU=0
TIMEOUT=600
VERBOSE=0

# ── Legacy flags — fail fast ──────────────────────────────────────────────────
_LEGACY_FLAGS=(--ckpt --ckpt-name --voice-model --voice-index --no-rvc --pitch --method --timeout-tts --timeout-rvc)

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
        --text)         TEXT="$2";         shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2";   shift 2 ;;
        --ref-wav)      REF_WAV="$2";      shift 2 ;;
        --language)     LANGUAGE="$2";     shift 2 ;;
        --cpu)          USE_CPU=1;         shift   ;;
        --timeout)      TIMEOUT="$2";      shift 2 ;;
        --verbose|-v)   VERBOSE=1;         shift   ;;
        --help)
            sed -n '3,/^set -/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        --ckpt|--ckpt-name|--voice-model|--voice-index|--no-rvc|--pitch|--method|--timeout-tts|--timeout-rvc)
            die "Legacy flag '$1' is not supported. This project is XTTS2-only." \
                "Use --ref-wav 'voice refs/my_voice.wav' for voice cloning." \
                "Run 'bash tests/test.sh --help' for current options."
            ;;
        --config)
            die "The --config (RVC YAML) flag is not supported. This project is XTTS2-only." \
                "Use --ref-wav 'voice refs/my_voice.wav' for voice cloning." \
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

if [ -f "$MINICONDA_DIR/etc/profile.d/conda.sh" ]; then
    # shellcheck source=/dev/null
    source "$MINICONDA_DIR/etc/profile.d/conda.sh"
    if conda env list 2>/dev/null | grep -qE "^${ENV_XTTS2}[[:space:]]"; then
        _ENV_RUNNER="conda"
    fi
fi

if [ -z "$_ENV_RUNNER" ] && command -v micromamba >/dev/null 2>&1; then
    if micromamba env list 2>/dev/null | grep -qE "^${ENV_XTTS2}[[:space:]]"; then
        _ENV_RUNNER="micromamba"
    fi
fi

python_cmd() {
    local env="$1"
    case "$_ENV_RUNNER" in
        conda)      echo "conda run -n $env python" ;;
        micromamba) echo "micromamba run -n $env python" ;;
        *)          echo "python" ;;
    esac
}

XTTS2_PYTHON_CMD="$(python_cmd "$ENV_XTTS2")"

if [ -n "$_ENV_RUNNER" ]; then
    log "Env runner : $_ENV_RUNNER"
    log "XTTS2 env  : $ENV_XTTS2"
else
    warn "No working conda/micromamba env runner found for '$ENV_XTTS2'."
    warn "  Falling back to system python — ensure all deps are installed."
    warn "  To set up the XTTS2 environment, run: bash setup_kaggle.sh"
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
    # Auto-detect first WAV in 'voice refs/'
    FOUND_WAV=$(find "$VOICE_REFS_DIR" -maxdepth 1 -name "*.wav" | sort | head -1 2>/dev/null || true)
    if [ -n "$FOUND_WAV" ]; then
        REF_WAV="$FOUND_WAV"
        log "Ref WAV    : $REF_WAV (auto-detected)"
    else
        warn "No reference WAV provided and none found in 'voice refs/'."
        warn "  XTTS2 will use a built-in default speaker."
        warn "  For voice cloning: place a .wav file in 'voice refs/' or use --ref-wav."
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log "===== Bulul XTTS2 voice test ====="
log "Output dir  : $OUTPUT_DIR"
log "Language    : $LANGUAGE"
log "Device      : $([ "$USE_CPU" -eq 1 ] && echo 'cpu (--cpu)' || echo 'auto (GPU if available)')"
if [ "${#TEXT}" -gt 60 ]; then
    log "Text        : ${TEXT:0:60}…"
else
    log "Text        : $TEXT"
fi
if [ -n "$REF_WAV" ]; then
    log "Ref WAV     : $REF_WAV"
else
    log "Ref WAV     : (none — built-in speaker)"
fi
log "=================================="

# ── Step 1: Validate reference WAV (if provided) ──────────────────────────────
log "1/2 Checking reference WAV…"
if [ -n "$REF_WAV" ]; then
    [ -f "$REF_WAV" ] || die "Reference WAV not found: $REF_WAV  (place .wav files in 'voice refs/')"
    ok "1/2 Reference WAV found: $REF_WAV"
else
    ok "1/2 No reference WAV — will use built-in speaker"
fi

# ── Step 2: XTTS2 synthesis ───────────────────────────────────────────────────
SYNTH_OUTPUT="$OUTPUT_DIR/xtts2_output.wav"

SYNTH_ARGS=(
    --text    "$TEXT"
    --output  "$SYNTH_OUTPUT"
    --language "$LANGUAGE"
)
[ "$USE_CPU" -eq 1 ]  && SYNTH_ARGS+=(--cpu)
[ -n "$REF_WAV" ]     && SYNTH_ARGS+=(--ref-wav "$REF_WAV")

_device_note=""
[ "$USE_CPU" -eq 1 ] && _device_note=", CPU mode"
log "2/2 Synthesising with XTTS2 (max ${TIMEOUT}s${_device_note})…"

heartbeat_start

SYNTH_EXIT=0
timeout "$TIMEOUT" \
    $XTTS2_PYTHON_CMD -u "$REPO_ROOT/scripts/synthesize.py" \
        "${SYNTH_ARGS[@]}" \
    >> "$TEST_LOG" 2>&1 || SYNTH_EXIT=$?

heartbeat_stop

if [ "$SYNTH_EXIT" -eq 124 ]; then
    die "XTTS2 synthesis timed out after ${TIMEOUT}s"
elif [ "$SYNTH_EXIT" -ne 0 ]; then
    die "XTTS2 synthesis failed (exit code $SYNTH_EXIT)"
fi

[ -f "$SYNTH_OUTPUT" ] || die "XTTS2 output not created: $SYNTH_OUTPUT"
SYNTH_SIZE=$(wc -c < "$SYNTH_OUTPUT")
ok "2/2 xtts2_output.wav (${SYNTH_SIZE} bytes)"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "===== Results ====="
log "  XTTS2 output  : $SYNTH_OUTPUT"
log "  Output dir    : $OUTPUT_DIR"
log "=================="

ok "All steps passed."

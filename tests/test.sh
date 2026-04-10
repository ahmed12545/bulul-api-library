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
#   --ckpt-name LABEL     StyleTTS2 checkpoint to use: ljspeech|libri|libri-100
#                         (default: ljspeech — the LJSpeech single-speaker model)
#                         Run 'bash setup_kaggle.sh' (or download_models.sh) with
#                         STYLETTS2_CHECKPOINTS="ljspeech,libri,libri-100" to get all three.
#   --cpu                 Force CPU inference (default: auto-select GPU if available)
#   --voice-model PATH    Path to RVC .pth model (skips RVC step if not provided)
#   --voice-index PATH    Path to RVC .index file (optional; improves RVC quality)
#   --config FILE         YAML config file listing multiple voices for batch conversion
#                         (see tests/podcast_6voices.yaml for the expected format)
#   --pitch N             Pitch shift in semitones for RVC (default: 0)
#   --method METHOD       RVC pitch method: rmvpe|harvest|crepe|pm (default: rmvpe)
#   --timeout-tts N       Max seconds for StyleTTS2 step (default: 600)
#   --timeout-rvc N       Max seconds per RVC conversion   (default: 300)
#   --no-rvc              Skip RVC step even if --voice-model/--config is given
#   --verbose             Show full subprocess output (default: quiet/summary mode)
#   --help                Show this help and exit
#
# Output modes:
#   Default (quiet): ≤15 lines total for a successful run; subprocess output
#     is captured to runtime/logs/test.log. On failure the last 40 log lines
#     are printed automatically.
#   --verbose: all subprocess output streams to stdout in real time.
#
# Kaggle anti-hang:
#   A heartbeat line is printed every 30 s while long steps are running, so the
#   notebook cell never appears silent.  Python scripts are run with -u
#   (unbuffered) so their output streams to the cell in real time.
#
# Required assets (before running):
#   models/styletts2/epoch_2nd_00100.pth       — StyleTTS2 LJSpeech checkpoint (ljspeech)
#   models/styletts2/epoch_2nd_00020_libri.pth — StyleTTS2 LibriTTS checkpoint (libri, epoch 20)
#   models/styletts2/epochs_2nd_00100_libri.pth — StyleTTS2 LibriTTS checkpoint (libri-100, epoch 100)
#   models/styletts2/config.yml                — LJSpeech config
#   models/styletts2/config_libri.yml          — LibriTTS config (shared by libri and libri-100)
#   models/StyleTTS2/                          — StyleTTS2 source tree
#   models/rvc/<name>.pth                      — RVC model (for voice conversion)
#   models/rvc/<name>.index                    — RVC index (optional)
#
# Run 'bash setup_kaggle.sh' to download all StyleTTS2 and RVC assets.
# To download all three StyleTTS2 checkpoints (default):
#   bash setup_kaggle.sh

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_STYLETTS2="bulul-styletts2"
ENV_RVC="bulul-rvc"
MINICONDA_DIR="${HOME}/miniconda3"
LOG_DIR="$REPO_ROOT/runtime/logs"
TEST_LOG="$LOG_DIR/test.log"

DEFAULT_OUTPUT_DIR="/kaggle/working/voice_tests"
[ -d "/kaggle/working" ] || DEFAULT_OUTPUT_DIR="${REPO_ROOT}/output/voice_tests"

TEXT="Welcome to the Bulul podcast. Today we explore the intersection of technology and everyday life, with clear insights and practical takeaways for every listener."
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
CKPT_NAME="ljspeech"
USE_CPU=0
VOICE_MODEL=""
VOICE_INDEX=""
CONFIG_FILE=""
PITCH=0
METHOD="rmvpe"
TIMEOUT_TTS=600
TIMEOUT_RVC=300
SKIP_RVC=0
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
        --text)         TEXT="$2";         shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2";   shift 2 ;;
        --ckpt-name)    CKPT_NAME="$2";    shift 2 ;;
        --cpu)          USE_CPU=1;         shift   ;;
        --voice-model)  VOICE_MODEL="$2";  shift 2 ;;
        --voice-index)  VOICE_INDEX="$2";  shift 2 ;;
        --config)       CONFIG_FILE="$2";  shift 2 ;;
        --pitch)        PITCH="$2";        shift 2 ;;
        --method)       METHOD="$2";       shift 2 ;;
        --timeout-tts)  TIMEOUT_TTS="$2";  shift 2 ;;
        --timeout-rvc)  TIMEOUT_RVC="$2";  shift 2 ;;
        --no-rvc)       SKIP_RVC=1;        shift   ;;
        --verbose|-v)   VERBOSE=1;         shift   ;;
        --help)
            sed -n '3,/^set -/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ── Set up log file ───────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR" "$OUTPUT_DIR"
: > "$TEST_LOG"

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

# ── Env runner detection ──────────────────────────────────────────────────────
# Detect a working env runner: conda (from known Miniconda path) or micromamba.
# NOTE: We deliberately skip a bare PATH-based 'mamba' check because on Kaggle
#       that binary is a Python test-runner (not the conda-extension mamba) and
#       rejects '-n ENV cmd' arguments — causing misleading failures.
_ENV_RUNNER=""   # "conda" | "micromamba" | "" (direct python fallback)

# 1. Try conda from the known Miniconda path (reliable, avoids fake mamba).
if [ -f "$MINICONDA_DIR/etc/profile.d/conda.sh" ]; then
    # shellcheck source=/dev/null
    source "$MINICONDA_DIR/etc/profile.d/conda.sh"
    if conda env list 2>/dev/null | grep -qE "^${ENV_STYLETTS2}[[:space:]]"; then
        _ENV_RUNNER="conda"
    fi
fi

# 2. If conda didn't work, try micromamba (common in Kaggle / CI; no conda.sh needed).
if [ -z "$_ENV_RUNNER" ] && command -v micromamba >/dev/null 2>&1; then
    if micromamba env list 2>/dev/null | grep -qE "^${ENV_STYLETTS2}[[:space:]]"; then
        _ENV_RUNNER="micromamba"
    fi
fi

# Return the correct python invocation prefix for a given env.
python_cmd() {
    local env="$1"
    case "$_ENV_RUNNER" in
        conda)      echo "conda run -n $env python" ;;
        micromamba) echo "micromamba run -n $env python" ;;
        *)          echo "python" ;;
    esac
}

TTS_PYTHON_CMD="$(python_cmd "$ENV_STYLETTS2")"
RVC_PYTHON_CMD="$(python_cmd "$ENV_RVC")"

if [ -n "$_ENV_RUNNER" ]; then
    log "Env runner : $_ENV_RUNNER"
    log "TTS env    : $ENV_STYLETTS2"
    log "RVC env    : $ENV_RVC"
else
    warn "No working conda/micromamba env runner found for '$ENV_STYLETTS2'."
    warn "  Tried: conda (at $MINICONDA_DIR/etc/profile.d/conda.sh), micromamba (in PATH)."
    warn "  Falling back to system python — ensure all deps are installed in the active env."
    warn "  To set up conda environments, run: bash setup_kaggle.sh"
fi

# ── Environment variables (cache dirs) ───────────────────────────────────────
export HF_HOME="${HF_HOME:-/kaggle/working/.cache/huggingface}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/kaggle/working/.cache/huggingface}"
export TORCH_HOME="${TORCH_HOME:-/kaggle/working/.cache/torch}"
export PYTHONPATH="${REPO_ROOT}/models/StyleTTS2:${PYTHONPATH:-}"

# ── Runtime compatibility defaults (Kaggle / headless) ───────────────────────
# MPLBACKEND: Kaggle/Jupyter notebooks export
#   MPLBACKEND=module://matplotlib_inline.backend_inline which is invalid in
#   the headless conda-run execution path.  Normalise to Agg whenever the
#   current value is absent or is an inline (module://) backend token.
#   A non-inline value explicitly set by the caller is preserved.
case "${MPLBACKEND:-}" in
    ""|module://*) export MPLBACKEND="Agg" ;;
esac
# TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD: relax torch>=2.6 weights_only default for
# trusted local checkpoints.  Caller can override by exporting before calling.
export TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD="${TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD:-1}"
log "Runtime: MPLBACKEND=$MPLBACKEND  TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=$TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD"

# ── Parse --config file to load voice list ────────────────────────────────────
# Config YAML format (see tests/podcast_6voices.yaml):
#   text: "optional override text"
#   voices:
#     - label: speaker1
#       model: models/rvc/speaker1.pth
#       index: models/rvc/speaker1.index   # optional
#       pitch: 0                            # optional
#
# Simple bash parser: extract model: lines and optional per-entry fields.
declare -a CONFIG_MODELS=()
declare -a CONFIG_LABELS=()
declare -a CONFIG_INDEXES=()
declare -a CONFIG_PITCHES=()

if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
    # Extract text override if present (strip leading/trailing quotes and spaces)
    _cfg_text=$(grep -E '^text:' "$CONFIG_FILE" | head -1 | sed 's/^text:[[:space:]]*//' | tr -d '"' | tr -d "'" || true)
    [ -n "$_cfg_text" ] && TEXT="$_cfg_text"

    # Parse voice entries: collect model, label, index, pitch per voice block.
    # Both "  - label:" (first field in a list entry) and "    label:" (follow-on
    # field) map to the same value, so they share the same action.
    _cur_label="" _cur_model="" _cur_index="" _cur_pitch=""
    while IFS= read -r _line; do
        case "$_line" in
            *"label:"*)   _cur_label=$(echo "$_line" | sed 's/.*label:[[:space:]]*//' | tr -d '"' | tr -d "'") ;;
            *"model:"*)   _cur_model=$(echo "$_line" | sed 's/.*model:[[:space:]]*//' | tr -d '"' | tr -d "'") ;;
            *"index:"*)   _cur_index=$(echo "$_line" | sed 's/.*index:[[:space:]]*//' | tr -d '"' | tr -d "'") ;;
            *"pitch:"*)   _cur_pitch=$(echo "$_line" | sed 's/.*pitch:[[:space:]]*//' | tr -d '"' | tr -d "'") ;;
            "  - "*)
                # New list entry starting: flush the previous voice block if complete
                if [ -n "$_cur_model" ]; then
                    CONFIG_MODELS+=("$_cur_model")
                    CONFIG_LABELS+=("${_cur_label:-voice$((${#CONFIG_MODELS[@]}))}")
                    CONFIG_INDEXES+=("${_cur_index:-}")
                    CONFIG_PITCHES+=("${_cur_pitch:-0}")
                fi
                _cur_label="" _cur_model="" _cur_index="" _cur_pitch=""
                ;;
        esac
    done < "$CONFIG_FILE"
    # Save last entry
    if [ -n "$_cur_model" ]; then
        CONFIG_MODELS+=("$_cur_model")
        CONFIG_LABELS+=("${_cur_label:-voice$((${#CONFIG_MODELS[@]}))}")
        CONFIG_INDEXES+=("${_cur_index:-}")
        CONFIG_PITCHES+=("${_cur_pitch:-0}")
    fi
    log "Config   : $CONFIG_FILE (${#CONFIG_MODELS[@]} voice(s))"
fi

log "===== Bulul voice test ====="
log "Output dir  : $OUTPUT_DIR"
log "Checkpoint  : $CKPT_NAME (${CKPT})"
log "Device      : $([ "$USE_CPU" -eq 1 ] && echo 'cpu (--cpu)' || echo 'auto (GPU if available)')"
if [ "${#TEXT}" -gt 60 ]; then
    log "Text        : ${TEXT:0:60}…"
else
    log "Text        : $TEXT"
fi
if [ -n "$CONFIG_FILE" ] && [ "${#CONFIG_MODELS[@]}" -gt 0 ]; then
    log "Voices      : ${#CONFIG_MODELS[@]} (from config)"
elif [ -n "$VOICE_MODEL" ]; then
    log "Voice model : $VOICE_MODEL"
else
    log "Voice model : (none — StyleTTS2 only)"
fi
log "==========================="

# ── Step 1: Validate required StyleTTS2 assets ───────────────────────────────
log "1/3 Validating StyleTTS2 assets (checkpoint: $CKPT_NAME)…"

# Map checkpoint label to file paths
case "$CKPT_NAME" in
    ljspeech)
        CKPT="$REPO_ROOT/models/styletts2/epoch_2nd_00100.pth"
        CFG="$REPO_ROOT/models/styletts2/config.yml"
        ;;
    libri)
        CKPT="$REPO_ROOT/models/styletts2/epoch_2nd_00020_libri.pth"
        CFG="$REPO_ROOT/models/styletts2/config_libri.yml"
        ;;
    libri-100)
        CKPT="$REPO_ROOT/models/styletts2/epochs_2nd_00100_libri.pth"
        CFG="$REPO_ROOT/models/styletts2/config_libri.yml"
        ;;
    *)
        die "Unknown --ckpt-name '$CKPT_NAME'. Valid values: ljspeech, libri, libri-100"
        ;;
esac

STYLETTS2_SRC="$REPO_ROOT/models/StyleTTS2"

ASSETS_OK=1
[ -f "$CKPT" ]          || { warn "Missing checkpoint : $CKPT";         ASSETS_OK=0; }
[ -f "$CFG" ]           || { warn "Missing config     : $CFG";           ASSETS_OK=0; }
[ -d "$STYLETTS2_SRC" ] || { warn "Missing StyleTTS2 source: $STYLETTS2_SRC"; ASSETS_OK=0; }

if [ "$ASSETS_OK" -eq 0 ]; then
    die "Required assets missing. Run 'bash setup_kaggle.sh' to download them. For the 'libri'/'libri-100' checkpoints run: STYLETTS2_CHECKPOINTS=\"ljspeech,libri,libri-100\" bash setup_kaggle.sh"
fi
ok "Assets validated"

# ── Step 2: StyleTTS2 synthesis ───────────────────────────────────────────────
TTS_OUTPUT="$OUTPUT_DIR/base_styletts2.wav"

# Build synthesize.py extra args
TTS_EXTRA_ARGS=()
[ "$USE_CPU" -eq 1 ] && TTS_EXTRA_ARGS+=("--cpu")

_device_note=""
[ "$USE_CPU" -eq 1 ] && _device_note=", CPU mode"
log "2/3 Synthesising with StyleTTS2/$CKPT_NAME (max ${TIMEOUT_TTS}s${_device_note})…"

heartbeat_start

TTS_EXIT=0
timeout "$TIMEOUT_TTS" \
    $TTS_PYTHON_CMD -u "$REPO_ROOT/scripts/synthesize.py" \
        --text   "$TEXT" \
        --output "$TTS_OUTPUT" \
        --ckpt   "$CKPT" \
        --config "$CFG" \
        "${TTS_EXTRA_ARGS[@]}" \
    >> "$TEST_LOG" 2>&1 || TTS_EXIT=$?

heartbeat_stop

if [ "$TTS_EXIT" -eq 124 ]; then
    die "StyleTTS2 synthesis timed out after ${TIMEOUT_TTS}s"
elif [ "$TTS_EXIT" -ne 0 ]; then
    die "StyleTTS2 synthesis failed (exit code $TTS_EXIT)"
fi

[ -f "$TTS_OUTPUT" ] || die "StyleTTS2 output not created: $TTS_OUTPUT"
TTS_SIZE=$(wc -c < "$TTS_OUTPUT")
ok "2/3 base_styletts2.wav (${TTS_SIZE} bytes)"

# ── Step 3: RVC voice conversion ──────────────────────────────────────────────
# Build the list of voices to convert: from --config, or single --voice-model
declare -a RVC_MODELS=()
declare -a RVC_LABELS=()
declare -a RVC_INDEXES=()
declare -a RVC_PITCHES=()

if [ "$SKIP_RVC" -eq 0 ]; then
    if [ "${#CONFIG_MODELS[@]}" -gt 0 ]; then
        RVC_MODELS=("${CONFIG_MODELS[@]}")
        RVC_LABELS=("${CONFIG_LABELS[@]}")
        RVC_INDEXES=("${CONFIG_INDEXES[@]}")
        RVC_PITCHES=("${CONFIG_PITCHES[@]}")
    elif [ -n "$VOICE_MODEL" ]; then
        RVC_MODELS=("$VOICE_MODEL")
        RVC_LABELS=("$(basename "$VOICE_MODEL" .pth)")
        RVC_INDEXES=("$VOICE_INDEX")
        RVC_PITCHES=("$PITCH")
    fi
fi

if [ "${#RVC_MODELS[@]}" -eq 0 ]; then
    warn "Skipping RVC step (no --voice-model or --config provided, or --no-rvc set)."
    warn "  Base StyleTTS2 audio: $TTS_OUTPUT"
    log "Test complete (StyleTTS2 only). Output: $TTS_OUTPUT"
    exit 0
fi

TOTAL_VOICES="${#RVC_MODELS[@]}"
log "3/3 Voice conversion: ${TOTAL_VOICES} voice(s) (max ${TIMEOUT_RVC}s each)"

RVC_SRC="$REPO_ROOT/models/RVC"
if [ ! -d "$RVC_SRC/infer" ]; then
    fail "RVC source not found at $RVC_SRC — run 'bash setup_kaggle.sh' to clone it."
    exit 1
fi

RVC_OK=0
RVC_FAIL=0

for i in "${!RVC_MODELS[@]}"; do
    _model="${RVC_MODELS[$i]}"
    _label="${RVC_LABELS[$i]}"
    _index="${RVC_INDEXES[$i]}"
    _pitch="${RVC_PITCHES[$i]:-$PITCH}"
    _num=$((i + 1))
    RVC_OUTPUT="$OUTPUT_DIR/rvc_${_label}.wav"

    if [ ! -f "$_model" ]; then
        warn "[$_num/$TOTAL_VOICES] RVC model not found: $_model — skipping"
        RVC_FAIL=$((RVC_FAIL + 1))
        continue
    fi

    log "  [$_num/$TOTAL_VOICES] $_label…"

    RVC_ARGS=(
        --input  "$TTS_OUTPUT"
        --output "$RVC_OUTPUT"
        --model  "$_model"
        --pitch  "$_pitch"
        --method "$METHOD"
    )
    [ -n "$_index" ] && [ -f "$_index" ] && RVC_ARGS+=(--index "$_index")

    heartbeat_start

    _rvc_exit=0
    timeout "$TIMEOUT_RVC" \
        $RVC_PYTHON_CMD -u "$REPO_ROOT/scripts/rvc_convert.py" "${RVC_ARGS[@]}" \
        >> "$TEST_LOG" 2>&1 || _rvc_exit=$?

    heartbeat_stop

    if [ "$_rvc_exit" -eq 124 ]; then
        warn "  [$_num/$TOTAL_VOICES] timed out after ${TIMEOUT_RVC}s — skipping"
        RVC_FAIL=$((RVC_FAIL + 1))
    elif [ "$_rvc_exit" -ne 0 ]; then
        warn "  [$_num/$TOTAL_VOICES] failed (exit $_rvc_exit) — skipping"
        RVC_FAIL=$((RVC_FAIL + 1))
    elif [ -f "$RVC_OUTPUT" ]; then
        _sz=$(wc -c < "$RVC_OUTPUT")
        ok "  [$_num/$TOTAL_VOICES] rvc_${_label}.wav (${_sz} bytes)"
        RVC_OK=$((RVC_OK + 1))
    else
        warn "  [$_num/$TOTAL_VOICES] output not created: $RVC_OUTPUT — skipping"
        RVC_FAIL=$((RVC_FAIL + 1))
    fi
done

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "===== Results ====="
log "  StyleTTS2 base : $TTS_OUTPUT"
log "  RVC converted  : $RVC_OK/$TOTAL_VOICES succeeded"
[ "$RVC_FAIL" -gt 0 ] && log "  RVC failed     : $RVC_FAIL/$TOTAL_VOICES (see $TEST_LOG)"
log "  Output dir     : $OUTPUT_DIR"
log "=================="

if [ "$RVC_FAIL" -gt 0 ] && [ "$RVC_OK" -eq 0 ]; then
    die "All RVC conversions failed."
fi

ok "All steps passed."

#!/usr/bin/env bash
# setup_kaggle.sh — one-shot setup for Kaggle demo (side-by-side conda envs)
#
# Usage:
#   bash setup_kaggle.sh [--verbose] [--checkpoints LABELS]
#
# Options:
#   --verbose              Show full subprocess output instead of summary-only mode.
#                          Default: quiet mode (logs written to runtime/logs/setup.log).
#   --checkpoints LABELS   Comma-separated list of StyleTTS2 checkpoint labels to
#                          download (default: "ljspeech,libri,libri-100"; max 5).
#                          Valid labels: ljspeech, libri, libri-100
#                          Example: --checkpoints ljspeech
#                                   --checkpoints "ljspeech,libri,libri-100"
#
# Creates two isolated conda environments:
#   bulul-styletts2  — StyleTTS2 TTS synthesis + API server
#   bulul-rvc        — RVC voice conversion
#
# Re-running is safe (idempotent): already-complete steps are skipped.
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
VERBOSE=0
STYLETTS2_CHECKPOINTS="${STYLETTS2_CHECKPOINTS:-ljspeech,libri,libri-100}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v)     VERBOSE=1; shift ;;
        --checkpoints)    STYLETTS2_CHECKPOINTS="$2"; shift 2 ;;
        *)                echo "[setup] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

ENV_STYLETTS2="bulul-styletts2"
ENV_RVC="bulul-rvc"
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
die()     { echo "[setup] ❌ $*" >&2
            echo "[setup]    Full log: $SETUP_LOG" >&2
            tail -n 40 "$SETUP_LOG" 2>/dev/null >&2 || true
            exit 1; }

# run_q CMD...: run quietly (log to file); on failure print last 40 log lines
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
: > "$SETUP_LOG"   # truncate log at the start of each run

log_v "Log file: $SETUP_LOG"
log_v "Verbose mode enabled."

# ── 1. Install Miniconda if not present ──────────────────────────────────────
log "Step 1/8 Checking Miniconda…"
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

# ── 2. Initialise conda for the current shell ─────────────────────────────────
export PATH="$MINICONDA_DIR/bin:$PATH"
# shellcheck source=/dev/null
source "$MINICONDA_DIR/etc/profile.d/conda.sh"

# ── 3. Accept Anaconda channel Terms of Service (required in non-interactive environments) ──
log "Step 2/8 Accepting Anaconda channel ToS…"
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main >> "$SETUP_LOG" 2>&1 || true
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r    >> "$SETUP_LOG" 2>&1 || true

# ── 4. Create per-model conda environments (side-by-side, not nested) ─────────
log "Step 3/8 Creating conda envs…"

if conda env list | grep -qE "^${ENV_STYLETTS2}[[:space:]]"; then
    log_v "  Env '$ENV_STYLETTS2' already exists — skipping"
else
    log "  Creating '$ENV_STYLETTS2' (Python ${PYTHON_VERSION})…"
    run_q conda create -y -n "$ENV_STYLETTS2" python="$PYTHON_VERSION" || \
        die "Failed to create conda env '$ENV_STYLETTS2'"
fi

if conda env list | grep -qE "^${ENV_RVC}[[:space:]]"; then
    log_v "  Env '$ENV_RVC' already exists — skipping"
else
    log "  Creating '$ENV_RVC' (Python ${PYTHON_VERSION})…"
    run_q conda create -y -n "$ENV_RVC" python="$PYTHON_VERSION" || \
        die "Failed to create conda env '$ENV_RVC'"
fi
ok "Conda envs ready: $ENV_STYLETTS2, $ENV_RVC"

# ── 5. Install Python dependencies in StyleTTS2 env ───────────────────────────
log "Step 4/8 Installing deps in '$ENV_STYLETTS2'…"
REQS="$SCRIPT_DIR/requirements.txt"
[ -f "$REQS" ] || die "requirements.txt not found at $REQS"
run_q conda run -n "$ENV_STYLETTS2" pip install --quiet --upgrade pip
run_q conda run -n "$ENV_STYLETTS2" pip install --quiet -r "$REQS" || \
    die "pip install failed in '$ENV_STYLETTS2'"
# Belt-and-suspenders: install the styletts2 pip package and einops_exts
# explicitly.  requirements.txt also lists them, but making it explicit here
# ensures they are present even when requirements.txt is out of sync.
run_q conda run -n "$ENV_STYLETTS2" pip install --quiet "styletts2==0.1.6" "einops_exts" || \
    warn "styletts2/einops_exts install had warnings — check $SETUP_LOG"
log_v "  Python dependencies installed in '$ENV_STYLETTS2'"

# ── 6. Create HuggingFace / Torch cache directories ──────────────────────────
log "Step 5/8 Creating cache directories…"
mkdir -p "$HF_HOME" "$TORCH_HOME"
log_v "  HF_HOME=$HF_HOME  TORCH_HOME=$TORCH_HOME"

# ── 7. Download models (StyleTTS2 in bulul-styletts2, RVC in bulul-rvc) ───────
# Pass both env names into download_models.sh so it can install each model's
# deps into the correct side-by-side environment.
log "Step 6/8 Downloading models (checkpoints: $STYLETTS2_CHECKPOINTS)…"
run_q conda run -n "$ENV_STYLETTS2" \
    env HF_HOME="$HF_HOME" \
        TRANSFORMERS_CACHE="$TRANSFORMERS_CACHE" \
        TORCH_HOME="$TORCH_HOME" \
        BULUL_ENV_RVC="$ENV_RVC" \
        BULUL_VERBOSE="$VERBOSE" \
        MINICONDA_DIR="$MINICONDA_DIR" \
        STYLETTS2_CHECKPOINTS="$STYLETTS2_CHECKPOINTS" \
    bash "$SCRIPT_DIR/download_models.sh" || \
    die "Model download failed"

# ── 8. Create runtime directories ─────────────────────────────────────────────
log "Step 7/8 Creating runtime directories…"
mkdir -p "$SCRIPT_DIR/runtime/tmp"

ok "Setup complete."
log "  StyleTTS2 env  : $ENV_STYLETTS2"
log "  RVC env        : $ENV_RVC"
log "  Checkpoints    : $STYLETTS2_CHECKPOINTS (in models/styletts2/)"
log "  Run 'bash host_service.sh' to start the API."
log "  Run 'bash tests/test.sh --help' for voice test options."
log "  NOTE: First model load may take several minutes while weights load into memory."

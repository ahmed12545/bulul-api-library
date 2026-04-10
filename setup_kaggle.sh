#!/usr/bin/env bash
# setup_kaggle.sh — one-shot XTTS2 setup for Kaggle / headless environments
#
# Usage:
#   bash setup_kaggle.sh [--verbose]
#
# Options:
#   --verbose   Show full subprocess output instead of summary-only mode.
#               Default: quiet mode (logs written to runtime/logs/setup.log).
#
# Creates one conda environment:
#   bulul-xtts2  — XTTS2 voice synthesis + API server
#
# Re-running is safe (idempotent): already-complete steps are skipped.
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=1; shift ;;
        *)            echo "[setup] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

ENV_XTTS2="bulul-xtts2"
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
warn()    { echo "[setup] ⚠️  $*"; }
die()     { echo "[setup] ❌ $*" >&2
            echo "[setup]    Full log: $SETUP_LOG" >&2
            tail -n 40 "$SETUP_LOG" 2>/dev/null >&2 || true
            exit 1; }

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
: > "$SETUP_LOG"

log_v "Log file: $SETUP_LOG"
log_v "Verbose mode enabled."

# ── 1. Install Miniconda if not present ──────────────────────────────────────
log "Step 1/5 Checking Miniconda…"
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
# Always use the explicit Miniconda binary to avoid PATH-dependent conda
# ambiguity (Kaggle notebooks may have a system conda earlier on PATH).
CONDA_EXE="$MINICONDA_DIR/bin/conda"

# ── 3. Accept Anaconda channel Terms of Service (required in non-interactive environments) ──
log "Step 2/5 Accepting Anaconda channel ToS…"
"$CONDA_EXE" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main >> "$SETUP_LOG" 2>&1 || true
"$CONDA_EXE" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r    >> "$SETUP_LOG" 2>&1 || true

# ── 4. Create XTTS2 conda environment ────────────────────────────────────────
log "Step 3/5 Creating conda env '$ENV_XTTS2'…"
if "$CONDA_EXE" env list | grep -qE "^${ENV_XTTS2}[[:space:]]"; then
    log_v "  Env '$ENV_XTTS2' already exists — skipping"
else
    log "  Creating '$ENV_XTTS2' (Python ${PYTHON_VERSION})…"
    run_q "$CONDA_EXE" create -y -n "$ENV_XTTS2" python="$PYTHON_VERSION" || \
        die "Failed to create conda env '$ENV_XTTS2'"
fi
ok "Conda env ready: $ENV_XTTS2"

# ── 5. Install Python dependencies ────────────────────────────────────────────
# Install in two stages to avoid pip resolver conflicts.
#
# Stage A: PyTorch + torchaudio from the CUDA 12.1 wheel index.
#   Must come first so the resolver sees the correct torch version before TTS
#   is evaluated.  The CUDA index URL is not PyPI — torch cannot be installed
#   from requirements-xtts2.txt directly.
#
# Stage B: XTTS2-only deps from requirements-xtts2.txt (TTS, transformers, …).
#   numpy, scipy, librosa, soundfile are intentionally absent from that file.
#   TTS==0.22.0 pulls in compatible versions automatically.  Pinning
#   numpy==1.26.4 alongside TTS in a single pip pass caused a
#   ResolutionImpossible conflict via TTS's transitive trainer dependency.
log "Step 4/5 Installing deps in '$ENV_XTTS2'…"
REQS_XTTS2="$SCRIPT_DIR/requirements-xtts2.txt"
[ -f "$REQS_XTTS2" ] || die "requirements-xtts2.txt not found at $REQS_XTTS2"

run_q "$CONDA_EXE" run -n "$ENV_XTTS2" pip install --quiet --upgrade pip setuptools wheel
# setuptools + wheel ensure compiled extensions (e.g. numba, tokenizers) can be built from source if no wheel is available.

log_v "  Stage A: installing torch==2.1.2 + torchaudio==2.1.2 (CUDA 12.1)…"
run_q "$CONDA_EXE" run -n "$ENV_XTTS2" pip install --quiet --no-cache-dir \
    "torch==2.1.2" "torchaudio==2.1.2" \
    --index-url https://download.pytorch.org/whl/cu121 || \
    die "torch/torchaudio install failed in '$ENV_XTTS2'"

log_v "  Stage B: installing XTTS2 deps from requirements-xtts2.txt…"
run_q "$CONDA_EXE" run -n "$ENV_XTTS2" pip install --quiet --no-cache-dir -r "$REQS_XTTS2" || \
    die "pip install (XTTS2 deps) failed in '$ENV_XTTS2'"

# ── 5b. Register env as a Jupyter/Kaggle kernel (optional, non-fatal) ─────────
run_q "$CONDA_EXE" run -n "$ENV_XTTS2" python -m ipykernel install \
    --user --name "$ENV_XTTS2" --display-name "Python ($ENV_XTTS2)" || true
log_v "  Python dependencies installed in '$ENV_XTTS2'"

# ── 5c. Verify pkg_resources is importable (setuptools sanity check) ──────────
# pkg_resources is provided by setuptools; if it is missing the TTS import fails
# at runtime even though TTS was installed successfully.  Re-run the upgrade to
# self-heal any env where setuptools was inadvertently stripped.
log_v "  Verifying pkg_resources is importable in '$ENV_XTTS2'…"
if ! "$CONDA_EXE" run -n "$ENV_XTTS2" python -c "import pkg_resources" >> "$SETUP_LOG" 2>&1; then
    log "  pkg_resources missing — reinstalling setuptools…"
    run_q "$CONDA_EXE" run -n "$ENV_XTTS2" pip install --quiet --upgrade setuptools || \
        die "setuptools reinstall failed in '$ENV_XTTS2'"
fi

# ── 5d. Re-upgrade setuptools after TTS install ───────────────────────────────
# TTS==0.22.0 dependency resolution can silently overwrite the setuptools version
# pinned in stage A, removing pkg_resources from the env.  A second unconditional
# upgrade after TTS is installed is the only reliable guard against this.
log_v "  Re-upgrading setuptools after TTS install (belt-and-suspenders)…"
run_q "$CONDA_EXE" run -n "$ENV_XTTS2" pip install --quiet --upgrade setuptools wheel || \
    die "setuptools post-TTS re-upgrade failed in '$ENV_XTTS2'"

# ── 5e. Hard fail-fast verification: pkg_resources + TTS must both be importable
log_v "  Hard-verifying pkg_resources + TTS are importable in '$ENV_XTTS2'…"
if ! "$CONDA_EXE" run -n "$ENV_XTTS2" \
        python -c "import pkg_resources, TTS; print('ok')" >> "$SETUP_LOG" 2>&1; then
    die "pkg_resources or TTS not importable in '$ENV_XTTS2' after install — check $SETUP_LOG"
fi
ok "pkg_resources + TTS verified in '$ENV_XTTS2'"

# ── 6. Download XTTS2 model and create runtime directories ───────────────────
log "Step 5/5 Preparing XTTS2 assets and runtime dirs…"
run_q "$CONDA_EXE" run -n "$ENV_XTTS2" \
    env HF_HOME="$HF_HOME" \
        TRANSFORMERS_CACHE="$TRANSFORMERS_CACHE" \
        TORCH_HOME="$TORCH_HOME" \
        BULUL_VERBOSE="$VERBOSE" \
        COQUI_TOS_AGREED=1 \
    bash "$SCRIPT_DIR/download_models.sh" || \
    die "Asset preparation failed"

mkdir -p "$SCRIPT_DIR/runtime/tmp"

ok "Setup complete."
log "  Conda exe      : $CONDA_EXE"
log "  XTTS2 env      : $ENV_XTTS2"
log "  Voice refs dir : voice refs/  (place .wav reference files here)"
log "  Run 'bash host_service.sh' to start the API."
log "  Run 'bash tests/test.sh --help' for voice synthesis options."
log "  NOTE: First synthesis may take several minutes while XTTS2 loads."

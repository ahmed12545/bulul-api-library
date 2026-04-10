#!/usr/bin/env bash
# download_models.sh — download/prepare StyleTTS2 and RVC model artifacts
#
# Idempotent: safe to run multiple times.
#
# Environment variables (set by setup_kaggle.sh):
#   BULUL_ENV_RVC           — name of the conda env for RVC (default: bulul-rvc)
#   BULUL_VERBOSE           — 1 for verbose output, 0 for quiet (default: 0)
#   MINICONDA_DIR           — path to Miniconda (default: $HOME/miniconda3)
#   STYLETTS2_CHECKPOINTS   — comma-separated list of checkpoint labels to
#                             download (default: "ljspeech,libri,libri-100"; max 5).
#                             Valid labels: ljspeech, libri, libri-100
#                             Example: STYLETTS2_CHECKPOINTS="ljspeech" bash download_models.sh
#
# StyleTTS2 has no setup.py/pyproject.toml so it cannot be pip-installed as a
# package.  Instead we clone the source tree and install its requirements.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/models/styletts2"
STYLETTS2_SRC="$SCRIPT_DIR/models/StyleTTS2"
STYLETTS2_REPO="https://github.com/yl4579/StyleTTS2.git"
LOG_DIR="$SCRIPT_DIR/runtime/logs"
DL_LOG="$LOG_DIR/download_models.log"

# Inherit per-model env names from parent or use defaults
ENV_RVC="${BULUL_ENV_RVC:-bulul-rvc}"
VERBOSE="${BULUL_VERBOSE:-0}"
MINICONDA_DIR="${MINICONDA_DIR:-$HOME/miniconda3}"

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
mkdir -p "$MODELS_DIR" "$HF_HOME" "$TORCH_HOME"

# ── StyleTTS2 source (clone, not pip-install — repo has no setup.py) ──────────
log "Step 1/8 Checking StyleTTS2 source tree…"
if [ -d "$STYLETTS2_SRC/.git" ]; then
    log_v "  StyleTTS2 source already present at $STYLETTS2_SRC — skipping clone"
else
    log "  Cloning StyleTTS2 source (shallow)…"
    run_q git clone --depth 1 "$STYLETTS2_REPO" "$STYLETTS2_SRC" || \
        die "Failed to clone StyleTTS2 from $STYLETTS2_REPO"
    log_v "  StyleTTS2 source cloned to $STYLETTS2_SRC"
fi

# ── Install StyleTTS2 runtime dependencies inside the active Python env ────────
log "Step 2/8 Installing StyleTTS2 runtime dependencies…"
if [ -f "$STYLETTS2_SRC/requirements.txt" ]; then
    run_q python -m pip install --quiet -r "$STYLETTS2_SRC/requirements.txt" || \
        die "Failed to install StyleTTS2 dependencies"
    log_v "  StyleTTS2 dependencies installed"
else
    warn "$STYLETTS2_SRC/requirements.txt not found — skipping dep install"
fi

# Install the styletts2 pip package (provides the `styletts2.tts.StyleTTS2`
# inference API used by scripts/synthesize.py) and einops_exts.
# The yl4579/StyleTTS2 source tree uses a training layout with no installable
# Python package, so we need the pip wrapper explicitly.
log_v "  Installing styletts2 pip package and einops_exts…"
run_q python -m pip install --quiet "styletts2==0.1.6" "einops_exts" || \
    warn "styletts2/einops_exts install had warnings — synthesis may fail. See $DL_LOG"
log_v "  styletts2 pip package installed"

# ── StyleTTS2 voice checkpoint catalog ───────────────────────────────────────
# Each entry describes one TTS voice checkpoint (NOT ASR/PLBERT utility weights;
# those are downloaded automatically by the styletts2 pip package and are not
# selectable voice checkpoints for A/B testing).
#
# Format: "LABEL|CKPT_URL|CONFIG_URL|CKPT_FILENAME|CONFIG_FILENAME"
#
# To add more checkpoints (up to the 5-slot cap) append a new row below.
CKPT_CATALOG=(
    "ljspeech|https://huggingface.co/yl4579/StyleTTS2-LJSpeech/resolve/main/Models/LJSpeech/epoch_2nd_00100.pth|https://huggingface.co/yl4579/StyleTTS2-LJSpeech/resolve/main/Models/LJSpeech/config.yml|epoch_2nd_00100.pth|config.yml"
    "libri|https://huggingface.co/yl4579/StyleTTS2-LibriTTS/resolve/main/Models/LibriTTS/epochs_2nd_00020.pth|https://huggingface.co/yl4579/StyleTTS2-LibriTTS/resolve/main/Models/LibriTTS/config.yml|epoch_2nd_00020_libri.pth|config_libri.yml"
    "libri-100|https://huggingface.co/yl4579/StyleTTS2-LibriTTS/resolve/main/Models/LibriTTS/epochs_2nd_00100.pth|https://huggingface.co/yl4579/StyleTTS2-LibriTTS/resolve/main/Models/LibriTTS/config.yml|epoch_2nd_00100_libri.pth|config_libri.yml"
)

# Which checkpoints to install: comma-separated labels from CKPT_CATALOG.
# Default: install all three available voice checkpoints.
# Override at runtime:  STYLETTS2_CHECKPOINTS="ljspeech" bash download_models.sh
# Or via setup_kaggle:  bash setup_kaggle.sh --checkpoints ljspeech
STYLETTS2_CHECKPOINTS="${STYLETTS2_CHECKPOINTS:-ljspeech,libri,libri-100}"

# Parse requested labels into an array and cap at 5
IFS=',' read -ra _DESIRED_CKPTS <<< "$STYLETTS2_CHECKPOINTS"
DESIRED_CKPTS=()
for _lbl in "${_DESIRED_CKPTS[@]}"; do
    _lbl="${_lbl//[[:space:]]/}"   # trim whitespace
    [ -n "$_lbl" ] && DESIRED_CKPTS+=("$_lbl")
done
if [ "${#DESIRED_CKPTS[@]}" -gt 5 ]; then
    warn "More than 5 checkpoints requested — capping at 5."
    DESIRED_CKPTS=("${DESIRED_CKPTS[@]:0:5}")
fi

log "Step 3/8 Checking StyleTTS2 checkpoint(s): ${DESIRED_CKPTS[*]}"

# Track the first successfully-resolved checkpoint for backward-compat aliases
PRIMARY_CKPT_FILE=""
PRIMARY_CONFIG_FILE=""

for _req_label in "${DESIRED_CKPTS[@]}"; do
    _found=0
    for _entry in "${CKPT_CATALOG[@]}"; do
        IFS='|' read -r _lbl _ckpt_url _cfg_url _ckpt_fname _cfg_fname <<< "$_entry"
        if [ "$_lbl" = "$_req_label" ]; then
            _found=1
            _ckpt_path="$MODELS_DIR/$_ckpt_fname"
            _cfg_path="$MODELS_DIR/$_cfg_fname"

            # Checkpoint file
            if [ -f "$_ckpt_path" ]; then
                log_v "  [$_req_label] Checkpoint already present — skipping"
            else
                log "  [$_req_label] Downloading checkpoint…"
                run_q wget --continue --tries=3 --timeout=120 --quiet \
                    "$_ckpt_url" -O "$_ckpt_path" || \
                    die "Failed to download [$_req_label] checkpoint"
                log_v "  [$_req_label] Checkpoint saved to $_ckpt_path"
            fi

            # Config file
            if [ -f "$_cfg_path" ]; then
                log_v "  [$_req_label] Config already present — skipping"
            else
                log "  [$_req_label] Downloading config…"
                run_q wget --continue --tries=3 --timeout=60 --quiet \
                    "$_cfg_url" -O "$_cfg_path" || \
                    die "Failed to download [$_req_label] config"
                log_v "  [$_req_label] Config saved to $_cfg_path"
            fi

            # Record primary (first) checkpoint for validation and backward compat
            if [ -z "$PRIMARY_CKPT_FILE" ]; then
                PRIMARY_CKPT_FILE="$_ckpt_path"
                PRIMARY_CONFIG_FILE="$_cfg_path"
            fi
            break
        fi
    done

    if [ "$_found" -eq 0 ]; then
        _valid_labels=""
        for _entry in "${CKPT_CATALOG[@]}"; do
            IFS='|' read -r _lbl _ _ _ _ <<< "$_entry"
            _valid_labels="$_valid_labels $_lbl"
        done
        warn "  Unknown checkpoint label '$_req_label' — skipping. Valid labels:$_valid_labels"
    fi
done

# Backward-compat: CKPT_FILE / CONFIG_FILE point to the primary checkpoint
# (preserves any code that still references these variables downstream).
CKPT_FILE="${PRIMARY_CKPT_FILE:-$MODELS_DIR/epoch_2nd_00100.pth}"
CONFIG_FILE="${PRIMARY_CONFIG_FILE:-$MODELS_DIR/config.yml}"

# ── Validate required StyleTTS2 artifacts ─────────────────────────────────────
log "Step 5/8 Validating StyleTTS2 artifacts…"
[ -d "$STYLETTS2_SRC/.git" ] || die "StyleTTS2 source missing at $STYLETTS2_SRC"
[ -f "$CKPT_FILE" ]          || die "Primary checkpoint missing at $CKPT_FILE"
[ -f "$CONFIG_FILE" ]        || die "Primary config missing at $CONFIG_FILE"
ok "StyleTTS2 artifacts ready"
log_v "   StyleTTS2 source   : $STYLETTS2_SRC"
log_v "   Primary checkpoint : $CKPT_FILE"
log_v "   Primary config     : $CONFIG_FILE"
if [ "${#DESIRED_CKPTS[@]}" -gt 1 ]; then
    log_v "   All checkpoints    : ${DESIRED_CKPTS[*]} (in $MODELS_DIR)"
fi

# ── RVC source (clone) ────────────────────────────────────────────────────────
RVC_SRC="$SCRIPT_DIR/models/RVC"
RVC_REPO="https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI.git"
RVC_MODELS_DIR="$SCRIPT_DIR/models/rvc"

log "Step 6/8 Checking RVC source tree…"
if [ -d "$RVC_SRC/.git" ]; then
    log_v "  RVC source already present at $RVC_SRC — skipping clone"
else
    log "  Cloning RVC source (shallow)…"
    run_q git clone --depth 1 "$RVC_REPO" "$RVC_SRC" || \
        die "Failed to clone RVC from $RVC_REPO"
    log_v "  RVC source cloned to $RVC_SRC"
fi

# ── Install RVC runtime dependencies in the dedicated bulul-rvc env ────────────
# Use pip<24.1 to work around the fairseq/omegaconf metadata compatibility
# issue where pip>=24.1 rejects omegaconf<2.1 packages (needed by fairseq==0.12.2).
log "Step 7/8 Installing RVC runtime dependencies in '$ENV_RVC'…"

# Make conda available in this subshell (we may be running inside conda run)
if [ -f "$MINICONDA_DIR/etc/profile.d/conda.sh" ]; then
    export PATH="$MINICONDA_DIR/bin:$PATH"
    # shellcheck source=/dev/null
    source "$MINICONDA_DIR/etc/profile.d/conda.sh" 2>/dev/null || true
fi

RVC_REQS="$RVC_SRC/requirements.txt"
if [ -f "$RVC_REQS" ]; then
    # Step 7a: Pin pip to >=21,<24.1 before installing RVC requirements.
    # Rationale: fairseq==0.12.2 requires omegaconf<2.1; pip>=24.1 rejects those
    # omegaconf versions (0.x/2.0.x) due to a metadata validation change, making
    # the resolver report ResolutionImpossible.  pip 21–23 handles them correctly.
    log_v "  Pinning pip<24.1 in '$ENV_RVC' for fairseq/omegaconf compatibility…"
    run_q conda run -n "$ENV_RVC" pip install --quiet "pip>=21,<24.1" || \
        warn "Could not pin pip in '$ENV_RVC' — install may still work"

    # Step 7b: Install RVC requirements
    log_v "  Installing RVC requirements in '$ENV_RVC'…"
    run_q conda run -n "$ENV_RVC" pip install --quiet -r "$RVC_REQS" || \
        warn "Some RVC pip dependencies failed — voice conversion may not work. See $DL_LOG"
    log_v "  RVC dependencies installed in '$ENV_RVC'"
else
    warn "$RVC_SRC/requirements.txt not found — installing known core RVC deps"
    run_q conda run -n "$ENV_RVC" pip install --quiet \
        praat-parselmouth pyworld resampy ffmpeg-python || \
        warn "Some RVC core dependencies failed — voice conversion may not work"
    log_v "  RVC core dependencies installed in '$ENV_RVC'"
fi

# ── RVC model directory + preflight check ─────────────────────────────────────
log "Step 8/8 Checking RVC model directory…"
mkdir -p "$RVC_MODELS_DIR"

if ls "$RVC_MODELS_DIR"/*.pth 2>/dev/null | grep -q .; then
    PTH_COUNT=$(ls "$RVC_MODELS_DIR"/*.pth 2>/dev/null | wc -l)
    ok "RVC model checkpoint(s) found: ${PTH_COUNT} .pth file(s) in $RVC_MODELS_DIR"
    if [ "$VERBOSE" -eq 1 ]; then
        ls "$RVC_MODELS_DIR"/*.pth | while read -r f; do log_v "  $f"; done
    fi
else
    warn "No RVC .pth checkpoints found in $RVC_MODELS_DIR/"
    warn "  → Place your RVC voice model files (.pth and optional .index) in:"
    warn "      $RVC_MODELS_DIR/"
    warn "  → Download models from https://huggingface.co/models?search=rvc"
    warn "  → The StyleTTS2→RVC pipeline will skip conversion until a model is provided"
fi

ok "All setup artifacts ready"
log_v "   RVC source       : $RVC_SRC"
log_v "   RVC models dir   : $RVC_MODELS_DIR"
log_v "   RVC env          : $ENV_RVC"

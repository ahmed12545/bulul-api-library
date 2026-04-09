#!/usr/bin/env bash
# tests/test_scripts.sh — basic shell-script smoke checks (no real execution)
# Checks syntax and that required variables/commands are referenced in the scripts.
# Run with: bash tests/test_scripts.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()   { echo "  ✅ PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

check_syntax() {
    local script="$1"
    if bash -n "$script" 2>/dev/null; then
        ok "syntax OK — $script"
    else
        fail "syntax error — $script"
    fi
}

check_contains() {
    local script="$1" pattern="$2" description="$3"
    if grep -qE "$pattern" "$script"; then
        ok "$description — $script"
    else
        fail "$description not found — $script"
    fi
}

echo "=== Shell script smoke checks ==="

# ── setup_kaggle.sh ──────────────────────────────────────────────────────────
# Note: setup_kaggle.sh uses 'conda run -n ENV' (not 'conda activate') because
# 'conda activate' does not propagate reliably in non-interactive Kaggle shells.
# We validate 'conda run' usage instead.
S="$REPO_ROOT/setup_kaggle.sh"
check_syntax "$S"
check_contains "$S" "conda tos accept" "accepts Anaconda channel ToS"
check_contains "$S" "conda create" "creates conda env"
check_contains "$S" "conda run" "runs commands via conda run (non-interactive safe)"
check_contains "$S" "conda run.*pip install" "installs python deps via conda run"
check_contains "$S" "download_models.sh" "calls download_models.sh"
check_contains "$S" "HF_HOME" "sets HF_HOME cache var"
check_contains "$S" "TORCH_HOME" "sets TORCH_HOME cache var"
check_contains "$S" "set -euo pipefail" "fail-fast enabled"

# ── download_models.sh ────────────────────────────────────────────────────────
S="$REPO_ROOT/download_models.sh"
check_syntax "$S"
check_contains "$S" "models/" "writes to models/"
check_contains "$S" "StyleTTS2" "references StyleTTS2"
check_contains "$S" "git clone" "clones StyleTTS2 source"
check_contains "$S" "HF_HOME" "sets HF_HOME cache var"
check_contains "$S" "TORCH_HOME" "sets TORCH_HOME cache var"
check_contains "$S" "\-\-continue" "uses wget --continue for resumable downloads"
check_contains "$S" "\-\-tries" "uses wget --tries for retry"
check_contains "$S" "set -euo pipefail" "fail-fast enabled"
check_contains "$S" "RVC" "references RVC setup"
check_contains "$S" "models/rvc" "creates RVC models directory"

# ── tests/test.sh ─────────────────────────────────────────────────────────────
S="$REPO_ROOT/tests/test.sh"
check_syntax "$S"
check_contains "$S" "synthesize.py" "calls StyleTTS2 synthesize script"
check_contains "$S" "rvc_convert.py" "calls RVC convert script"
check_contains "$S" "heartbeat" "implements heartbeat for Kaggle anti-hang"
check_contains "$S" "timeout" "uses timeout guard for long steps"
check_contains "$S" "\-\-text" "accepts --text argument"
check_contains "$S" "\-\-output-dir" "accepts --output-dir argument"
check_contains "$S" "\-\-voice-model" "accepts --voice-model argument"
check_contains "$S" "set -euo pipefail" "fail-fast enabled"

# ── scripts/synthesize.py ────────────────────────────────────────────────────
S="$REPO_ROOT/scripts/synthesize.py"
if [ -f "$S" ]; then
    if python3 -c "import ast; ast.parse(open('$S').read())" 2>/dev/null; then
        ok "syntax OK — $S"
    else
        fail "syntax error — $S"
    fi
    check_contains "$S" "flush=True" "uses flush=True for unbuffered output"
    check_contains "$S" "StyleTTS2" "references StyleTTS2"
    check_contains "$S" "argparse" "uses argparse for argument handling"
else
    fail "missing file — $S"
fi

# ── scripts/rvc_convert.py ────────────────────────────────────────────────────
S="$REPO_ROOT/scripts/rvc_convert.py"
if [ -f "$S" ]; then
    if python3 -c "import ast; ast.parse(open('$S').read())" 2>/dev/null; then
        ok "syntax OK — $S"
    else
        fail "syntax error — $S"
    fi
    check_contains "$S" "flush=True" "uses flush=True for unbuffered output"
    check_contains "$S" "RVC" "references RVC"
    check_contains "$S" "argparse" "uses argparse for argument handling"
else
    fail "missing file — $S"
fi

# ── host_service.sh ───────────────────────────────────────────────────────────
S="$REPO_ROOT/host_service.sh"
check_syntax "$S"
check_contains "$S" "GROQ_API_KEY" "prompts for GROQ_API_KEY"
check_contains "$S" "NGROK_AUTHTOKEN" "prompts for NGROK_AUTHTOKEN"
check_contains "$S" "HF_HOME" "exports HF_HOME cache var"
check_contains "$S" "TORCH_HOME" "exports TORCH_HOME cache var"
check_contains "$S" "PYTHONPATH" "exports PYTHONPATH for StyleTTS2"
check_contains "$S" "uvicorn" "starts uvicorn"
check_contains "$S" "ngrok" "starts ngrok"
check_contains "$S" "set -euo pipefail" "fail-fast enabled"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

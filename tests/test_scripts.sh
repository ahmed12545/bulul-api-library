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

check_absent() {
    local script="$1" pattern="$2" description="$3"
    if ! grep -qE "$pattern" "$script"; then
        ok "$description absent (correct) — $script"
    else
        fail "$description still present (should be removed) — $script"
    fi
}

echo "=== Shell script smoke checks ==="

# ── setup_kaggle.sh ──────────────────────────────────────────────────────────
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
check_contains "$S" "bulul-xtts2" "creates bulul-xtts2 env"
check_contains "$S" "\-\-verbose" "supports --verbose flag"
check_absent   "$S" "bulul-rvc" "bulul-rvc env removed"
check_absent   "$S" "bulul-styletts2" "bulul-styletts2 env removed"
check_absent   "$S" "StyleTTS2" "StyleTTS2 references removed"
check_absent   "$S" "STYLETTS2_CHECKPOINTS" "STYLETTS2_CHECKPOINTS removed"

# ── download_models.sh ────────────────────────────────────────────────────────
S="$REPO_ROOT/download_models.sh"
check_syntax "$S"
check_contains "$S" "voice refs" "creates voice refs directory"
check_contains "$S" "XTTS2" "references XTTS2"
check_contains "$S" "HF_HOME" "sets HF_HOME cache var"
check_contains "$S" "TORCH_HOME" "sets TORCH_HOME cache var"
check_contains "$S" "set -euo pipefail" "fail-fast enabled"
check_absent   "$S" "git clone" "no model source tree cloning"
check_absent   "$S" "StyleTTS2" "StyleTTS2 references removed"
check_absent   "$S" "bulul-rvc" "RVC env references removed"

# ── tests/test.sh ─────────────────────────────────────────────────────────────
S="$REPO_ROOT/tests/test.sh"
check_syntax "$S"
check_contains "$S" "synthesize.py" "calls XTTS2 synthesize script"
check_contains "$S" "heartbeat" "implements heartbeat for Kaggle anti-hang"
check_contains "$S" "timeout" "uses timeout guard for long steps"
check_contains "$S" "\-\-text" "accepts --text argument"
check_contains "$S" "\-\-output-dir" "accepts --output-dir argument"
check_contains "$S" "\-\-ref-wav" "accepts --ref-wav argument"
check_contains "$S" "\-\-verbose" "accepts --verbose flag"
check_contains "$S" "set -euo pipefail" "fail-fast enabled"
check_contains "$S" "bulul-xtts2" "uses bulul-xtts2 env"
check_contains "$S" "voice refs" "references voice refs folder"
check_contains "$S" "Legacy flag" "rejects legacy flags with clear message"
check_absent   "$S" "rvc_convert.py" "rvc_convert.py not called"
check_absent   "$S" "bulul-rvc" "bulul-rvc env not referenced"
check_absent   "$S" "bulul-styletts2" "bulul-styletts2 env not referenced"

# ── tests/podcast_6voices.yaml ────────────────────────────────────────────────
S="$REPO_ROOT/tests/podcast_6voices.yaml"
if [ -f "$S" ]; then
    ok "file exists — $S"
    if grep -q "voices:" "$S"; then
        ok "contains voices list — $S"
    else
        fail "missing voices list — $S"
    fi
    if grep -q "ref_wav:" "$S"; then
        ok "contains ref_wav entries (XTTS2 format) — $S"
    else
        fail "missing ref_wav entries (XTTS2 format) — $S"
    fi
else
    fail "missing file — $S"
fi

# ── scripts/synthesize.py ────────────────────────────────────────────────────
S="$REPO_ROOT/scripts/synthesize.py"
if [ -f "$S" ]; then
    if python3 -c "import ast; ast.parse(open('$S').read())" 2>/dev/null; then
        ok "syntax OK — $S"
    else
        fail "syntax error — $S"
    fi
    check_contains "$S" "flush=True" "uses flush=True for unbuffered output"
    check_contains "$S" "XTTS2" "references XTTS2"
    check_contains "$S" "argparse" "uses argparse for argument handling"
    check_contains "$S" "ref-wav|ref_wav" "accepts reference WAV argument"
    check_contains "$S" "Legacy flag|_LEGACY_FLAGS|legacy" "rejects legacy flags"
else
    fail "missing file — $S"
fi

# ── scripts/rvc_convert.py ────────────────────────────────────────────────────
S="$REPO_ROOT/scripts/rvc_convert.py"
if [ -f "$S" ]; then
    if python3 -c "import ast; ast.parse(open('$S').read())" 2>/dev/null; then
        ok "syntax OK (legacy stub) — $S"
    else
        fail "syntax error — $S"
    fi
    check_contains "$S" "flush=True" "uses flush=True for unbuffered output"
    check_contains "$S" "argparse|XTTS2|removed|legacy" "references migration message"
    check_contains "$S" "sys.exit" "exits with error (legacy stub)"
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
check_contains "$S" "uvicorn" "starts uvicorn"
check_contains "$S" "ngrok" "starts ngrok"
check_contains "$S" "set -euo pipefail" "fail-fast enabled"
check_contains "$S" "bulul-xtts2" "uses bulul-xtts2 env for API"
check_absent   "$S" "bulul-styletts2" "bulul-styletts2 env removed"
check_absent   "$S" "PYTHONPATH.*StyleTTS2" "StyleTTS2 PYTHONPATH removed"

# ── voice refs/ directory ─────────────────────────────────────────────────────
VREF="$REPO_ROOT/voice refs"
if [ -d "$VREF" ]; then
    ok "directory exists — voice refs/"
    if [ -f "$VREF/README.md" ]; then
        ok "README.md present — voice refs/README.md"
    else
        fail "README.md missing — voice refs/README.md"
    fi
else
    fail "directory missing — voice refs/"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

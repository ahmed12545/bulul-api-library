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
S="$REPO_ROOT/setup_kaggle.sh"
check_syntax "$S"
check_contains "$S" "conda tos accept" "accepts Anaconda channel ToS"
check_contains "$S" "conda create" "creates conda env"
check_contains "$S" "conda activate" "activates env"
check_contains "$S" "conda run" "runs download_models.sh via conda run"
check_contains "$S" "pip install" "installs python deps"
check_contains "$S" "download_models.sh" "calls download_models.sh"
check_contains "$S" "set -euo pipefail" "fail-fast enabled"

# ── download_models.sh ────────────────────────────────────────────────────────
S="$REPO_ROOT/download_models.sh"
check_syntax "$S"
check_contains "$S" "models/" "writes to models/"
check_contains "$S" "StyleTTS2" "references StyleTTS2"
check_contains "$S" "git clone" "clones StyleTTS2 source"
check_contains "$S" "set -euo pipefail" "fail-fast enabled"

# ── host_service.sh ───────────────────────────────────────────────────────────
S="$REPO_ROOT/host_service.sh"
check_syntax "$S"
check_contains "$S" "GROQ_API_KEY" "prompts for GROQ_API_KEY"
check_contains "$S" "NGROK_AUTHTOKEN" "prompts for NGROK_AUTHTOKEN"
check_contains "$S" "PYTHONPATH" "exports PYTHONPATH for StyleTTS2"
check_contains "$S" "uvicorn" "starts uvicorn"
check_contains "$S" "ngrok" "starts ngrok"
check_contains "$S" "set -euo pipefail" "fail-fast enabled"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

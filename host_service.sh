#!/usr/bin/env bash
# host_service.sh — start API server and expose via ngrok
# Usage: bash host_service.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The API uses XTTS2; run it inside the bulul-xtts2 env.
CONDA_ENV_NAME="bulul-xtts2"
MINICONDA_DIR="$HOME/miniconda3"
APP_PORT="${APP_PORT:-8000}"

log() { echo "[host_service] $*"; }
die() { echo "[host_service] ERROR: $*" >&2; exit 1; }

# ── 1. Prompt for secrets if not already set ─────────────────────────────────
if [ -z "${GROQ_API_KEY:-}" ]; then
    read -rp "Enter your GROQ API key: " GROQ_API_KEY
    [ -n "$GROQ_API_KEY" ] || die "GROQ_API_KEY cannot be empty"
fi
export GROQ_API_KEY

if [ -z "${NGROK_AUTHTOKEN:-}" ]; then
    read -rp "Enter your ngrok auth token: " NGROK_AUTHTOKEN
    [ -n "$NGROK_AUTHTOKEN" ] || die "NGROK_AUTHTOKEN cannot be empty"
fi
export NGROK_AUTHTOKEN

# ── 2. Activate conda env ─────────────────────────────────────────────────────
export PATH="$MINICONDA_DIR/bin:$PATH"
# shellcheck source=/dev/null
source "$MINICONDA_DIR/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV_NAME" || \
    die "Could not activate conda env '${CONDA_ENV_NAME}'. Run setup_kaggle.sh first."

# ── 3. Export HuggingFace / Torch cache directories ──────────────────────────
export HF_HOME="${HF_HOME:-/kaggle/working/.cache/huggingface}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-/kaggle/working/.cache/huggingface}"
export TORCH_HOME="${TORCH_HOME:-/kaggle/working/.cache/torch}"
mkdir -p "$HF_HOME" "$TORCH_HOME"
log "Cache dirs: HF_HOME=$HF_HOME  TORCH_HOME=$TORCH_HOME"

# ── 4. Set MPLBACKEND for headless operation ──────────────────────────────────
case "${MPLBACKEND:-}" in
    ""|module://*) export MPLBACKEND="Agg" ;;
esac

# ── 5. Configure ngrok ────────────────────────────────────────────────────────
log "Configuring ngrok…"
ngrok config add-authtoken "$NGROK_AUTHTOKEN" 2>/dev/null || true

# ── 6. Start the API server in the background ─────────────────────────────────
log "Starting API server on port ${APP_PORT}…"
cd "$SCRIPT_DIR"
uvicorn app:app \
    --host 0.0.0.0 \
    --port "$APP_PORT" \
    --log-level info &
API_PID=$!
log "API server PID: $API_PID"

# Wait briefly so the server is up before ngrok connects
sleep 3

# ── 7. Open ngrok tunnel ──────────────────────────────────────────────────────
log "Opening ngrok tunnel to port ${APP_PORT}…"
ngrok http "$APP_PORT" --log=stdout &
NGROK_PID=$!

sleep 3

# Print the public URL by querying the local ngrok API
PUBLIC_URL=$(curl -s http://127.0.0.1:4040/api/tunnels \
    | python3 -c "import sys, json; tunnels = json.load(sys.stdin)['tunnels']; print(tunnels[0]['public_url'])" \
    2>/dev/null || echo "(check http://127.0.0.1:4040 for the public URL)")

log "✅ Service is live!"
log "   Public endpoint : $PUBLIC_URL"
log "   Health check    : $PUBLIC_URL/health"
log "   Podcast endpoint: $PUBLIC_URL/generate-podcast"
log ""
log "Press Ctrl+C to stop."
log "NOTE: If this is the first run, XTTS2 may take several minutes to load."

# ── 8. Wait and handle shutdown ───────────────────────────────────────────────
cleanup() {
    log "Shutting down…"
    kill "$API_PID" 2>/dev/null || true
    kill "$NGROK_PID" 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

wait "$API_PID"

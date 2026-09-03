#!/bin/bash
# =============================================================================
# Start Script for MikroTik Backup Bot with SSH + Proxy Support
# =============================================================================

set -euo pipefail

export HOME="${HOME:-/home/aionis}"
export USER="${USER:-aionis}"
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Load Config ---
if [ -f "$SCRIPT_DIR/tg_bot_config.sh" ]; then
    source "$SCRIPT_DIR/tg_bot_config.sh"
else
    echo "ERROR: tg_bot_config.sh not found in $SCRIPT_DIR" >&2
    exit 1
fi

# --- Ensure log directory exists ---
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

echo "[$(date)] Starting MikroTik Backup Bot..."
echo "[$(date)] Script dir: $SCRIPT_DIR"
echo "[$(date)] Proxy: ${TELEGRAM_PROXY:-none}"

# --- Start SSH agent ---
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    eval "$(ssh-agent -s)" > /dev/null
    echo "[$(date)] SSH agent started"
fi

# --- Add SSH keys ---
if [ -f "$HOME/.ssh/mk_key" ]; then
    ssh-add "$HOME/.ssh/mk_key" 2>/dev/null || echo "[$(date)] WARNING: Failed to add mk_key"
else
    echo "[$(date)] WARNING: SSH key $HOME/.ssh/mk_key not found"
fi

if [ -f "$HOME/.ssh/id_rsa" ]; then
    ssh-add "$HOME/.ssh/id_rsa" 2>/dev/null || true
fi

# --- Test GitHub connection ---
echo "[$(date)] Testing GitHub connection..."
ssh -T git@github.com 2>&1 | head -1 || echo "[$(date)] GitHub connection test completed"

# --- Test Telegram API connection (via proxy) ---
echo "[$(date)] Testing Telegram API connection..."
source "$SCRIPT_DIR/tg_api_helpers.sh"
if tg_test_connection; then
    echo "[$(date)] Telegram API connection OK"
else
    echo "[$(date)] WARNING: Cannot reach Telegram API. Check proxy settings."
fi

# --- Start the bot ---
echo "[$(date)] Launching bot..."
exec "$SCRIPT_DIR/mk_tg_bot.sh"


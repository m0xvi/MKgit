#!/bin/bash
# =============================================================================
# Start Script for MikroTik Backup Bot with SSH + Proxy Support
# =============================================================================
# Запускать от пользователя-владельца репозитория (например, aionis).
# Если запустить от root — скрипт сам переключится на владельца каталога
# репозитория: иначе HOME=/root, SSH-ключ ищется в /root/.ssh (его нет),
# а логи/локи/бэкапы создаются root-овыми, после чего обычный пользователь
# не может ни писать в логи, ни снять lock.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Не работаем от root: переключаемся на владельца репозитория ------------
if [ "$(id -u)" = "0" ]; then
    REPO_OWNER="$(stat -c %U "$REPO_DIR" 2>/dev/null || true)"
    if [ -n "$REPO_OWNER" ] && [ "$REPO_OWNER" != "root" ]; then
        OWNER_HOME="$(getent passwd "$REPO_OWNER" | cut -d: -f6)"
        OWNER_HOME="${OWNER_HOME:-/home/$REPO_OWNER}"
        echo "[$(date)] Запуск от root: переключаюсь на владельца репозитория '$REPO_OWNER' (HOME=$OWNER_HOME)"
        if command -v runuser > /dev/null 2>&1; then
            exec runuser -u "$REPO_OWNER" -- env HOME="$OWNER_HOME" USER="$REPO_OWNER" \
                bash "$SCRIPT_DIR/start_bot_with_ssh.sh" "$@"
        else
            exec su -s /bin/bash "$REPO_OWNER" -c \
                "HOME='$OWNER_HOME' bash '$SCRIPT_DIR/start_bot_with_ssh.sh'"
        fi
    fi
    echo "[$(date)] ВНИМАНИЕ: репозиторий принадлежит root — бот будет работать от root." >&2
    echo "[$(date)] Не рекомендуется: лучше 'chown -R aionis:aionis $REPO_DIR' и запуск от aionis." >&2
fi

# HOME/LOGNAME берём у реального пользователя (а не из окружения sudo)
if [ -z "${HOME:-}" ] || [ "${HOME}" = "/root" ]; then
    HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
    [ -n "$HOME" ] && export HOME
fi
export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# --- Load Config ---
if [ -f "$SCRIPT_DIR/tg_bot_config.sh" ]; then
    # shellcheck source=tg_bot_config.sh
    source "$SCRIPT_DIR/tg_bot_config.sh"
else
    echo "ERROR: tg_bot_config.sh not found in $SCRIPT_DIR" >&2
    exit 1
fi

# --- Ensure log directory exists and is writable -------------------------------
LOG_DIR="$(dirname "${LOG_FILE:-$REPO_DIR/logs/mk_backup.log}")"
mkdir -p "$LOG_DIR" 2>/dev/null || true
if ! touch "$LOG_DIR/.write_test" 2>/dev/null; then
    echo "ERROR: нет прав на запись в $LOG_DIR (владелец: $(stat -c '%U:%G' "$LOG_DIR" 2>/dev/null))." >&2
    echo "       Исправьте: sudo chown -R $(id -un):$(id -gn) '$LOG_DIR' '${BACKUP_DIR:-$REPO_DIR/bckp}'" >&2
    echo "       или запустите start_bot_with_ssh.sh от владельца репозитория." >&2
    exit 1
fi
rm -f "$LOG_DIR/.write_test"

echo "[$(date)] Starting MikroTik Backup Bot..."
echo "[$(date)] Script dir: $SCRIPT_DIR"
echo "[$(date)] User/HOME: $(id -un) / $HOME"
echo "[$(date)] Proxy: ${TELEGRAM_PROXY:-none}"

# --- Start SSH agent ---
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    eval "$(ssh-agent -s)" > /dev/null
    echo "[$(date)] SSH agent started"
fi

# --- Add SSH keys ---
KEY_FOUND=0
for k in "${SSH_KEY:-$HOME/.ssh/mk_key}" "$HOME/.ssh/mk_key" "$HOME/.ssh/id_rsa"; do
    if [ -f "$k" ]; then
        ssh-add "$k" 2>/dev/null || echo "[$(date)] WARNING: Failed to add $(basename "$k")"
        KEY_FOUND=1
    fi
done
if [ "$KEY_FOUND" = "0" ]; then
    echo "[$(date)] WARNING: SSH-ключ не найден ($HOME/.ssh/mk_key)."
    echo "[$(date)] WARNING: без ключа бэкапы и обновления не заработают. Создайте:"
    echo "[$(date)]   ssh-keygen -t rsa -b 4096 -f $HOME/.ssh/mk_key -N ''"
    echo "[$(date)]   (и добавьте .pub на каждый MikroTik: /user ssh-keys import)"
fi

# --- Test GitHub connection ---
echo "[$(date)] Testing GitHub connection..."
ssh -T git@github.com 2>&1 | head -1 || echo "[$(date)] GitHub connection test completed"

# --- Test Telegram API connection (via proxy) ---
echo "[$(date)] Testing Telegram API connection..."
# shellcheck source=tg_api_helpers.sh
source "$SCRIPT_DIR/tg_api_helpers.sh"
if tg_test_connection; then
    echo "[$(date)] Telegram API connection OK"
else
    echo "[$(date)] WARNING: Cannot reach Telegram API. Check proxy settings."
    # Не прерываем здесь: пусть пользователь увидит подробный
    # ERROR в логе самого бота (срабатывает в mk_tg_bot.sh).
fi

# --- Start the bot ---
echo "[$(date)] Launching bot..."
# Пробу уже сделали — внутри бота повторный прогон tg_test_connection
# пропустим, чтобы не дублировать строки в логе.
export MK_BOT_SKIP_TEST=1
exec "$SCRIPT_DIR/mk_tg_bot.sh"

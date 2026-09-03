#!/bin/bash
# =============================================================================
# Telegram Bot Configuration for MikroTik Backup Bot
# =============================================================================

# --- Telegram Bot Settings ---
# IMPORTANT: Store token securely! Consider using a vault or restricted file.
export TELEGRAM_BOT_TOKEN="8285477701:AAHbNbmsZ33LIWUYkvBRlDfwtknIwwkX_yw"
export TELEGRAM_CHAT_ID="-5003580476"

# --- Paths ---
export CONFIG_FILE="/home/aionis/MikroGit/devices.conf"
export BACKUP_SCRIPT="/home/aionis/MikroGit/MikroGit.sh"
export LOG_FILE="/home/aionis/MikroGit/logs/mk_backup.log"

# --- Proxy Settings (REQUIRED for Russia) ---
# Supported types: http, socks5, socks5h
# Format: protocol://[user:pass@]host:port
#
# Examples:
#   HTTP proxy:
#     export TELEGRAM_PROXY="http://proxy.example.com:8080"
#   SOCKS5 proxy:
#     export TELEGRAM_PROXY="socks5://proxy.example.com:1080"
#   SOCKS5 with hostname resolution on proxy side:
#     export TELEGRAM_PROXY="socks5h://proxy.example.com:1080"
#   Authenticated proxy:
#     export TELEGRAM_PROXY="http://user:pass@proxy.example.com:8080"
#
# Also respected (by curl natively):
#   export HTTPS_PROXY="socks5h://proxy.example.com:1080"
#   export HTTP_PROXY="http://proxy.example.com:8080"
#   export ALL_PROXY="socks5://proxy.example.com:1080"
#
export TELEGRAM_PROXY="http://cbvpx2yq:njk94ahfh6ui@130.49.141.28:42277"

# --- Retry Settings ---
export TG_MAX_RETRIES=3
export TG_RETRY_DELAY=2
export TG_TIMEOUT=30

# --- SSH Key ---
export SSH_KEY="$HOME/.ssh/mk_key"

# =============================================================================
# RouterOS Updates (bot + tg/mk_updates.sh)
# =============================================================================
# Проверка обновлений выполняется ЧЕРЕЗ САМ РОУТЕР:
#   /system package update check-for-updates
# Требование: у роутера должен быть интернет-доступ к серверам MikroTik
# (upgrade.mikrotik.com), и SSH-пользователь из devices.conf должен иметь
# права на /system package update и /system reboot (обычно full admin).

# Канал обновлений. Варианты: stable | long-term | testing | "" (пусто —
# НЕ менять канал роутера, проверять в том канале, что настроен на самом
# устройстве). Для единообразия на всех устройствах обычно задают stable.
export UPDATE_CHANNEL="stable"

# Делать резервную копию конфигурации (MikroGit.sh --device) перед установкой
export UPDATE_BACKUP_BEFORE_APPLY="1"

# Таймаут скачивания обновления на роутере, сек
export UPDATE_DOWNLOAD_TIMEOUT="900"

# Сколько ждать возвращения устройства в SSH после перезагрузки, сек
export UPDATE_REBOOT_WAIT="600"

# Пауза между попытками опроса устройства после перезагрузки, сек
export UPDATE_REBOOT_POLL="10"

# Автопроверка обновлений по расписанию (выполняется внутри бота)
export UPDATE_AUTO_CHECK="1"

# Интервал автопроверки, часы
export UPDATE_AUTO_INTERVAL_HOURS="24"

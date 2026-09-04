#!/bin/bash
# =============================================================================
# MikroTik Backup Telegram Bot (Proxy-Aware)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Load configs ---
if [ -f "$SCRIPT_DIR/tg_bot_config.sh" ]; then
    source "$SCRIPT_DIR/tg_bot_config.sh"
else
    echo "ERROR: tg_bot_config.sh not found" >&2
    exit 1
fi

# --- Load API helpers (proxy-aware curl wrapper) ---
if [ -f "$SCRIPT_DIR/tg_api_helpers.sh" ]; then
    source "$SCRIPT_DIR/tg_api_helpers.sh"
else
    echo "ERROR: tg_api_helpers.sh not found" >&2
    exit 1
fi

# --- Load state management ---
if [ -f "$SCRIPT_DIR/telegram_states.sh" ]; then
    source "$SCRIPT_DIR/telegram_states.sh"
fi

# --- Load RouterOS update manager (library: функции rup_*) ---
if [ -f "$SCRIPT_DIR/mk_updates.sh" ]; then
    source "$SCRIPT_DIR/mk_updates.sh"
else
    echo "ERROR: mk_updates.sh not found" >&2
fi

# --- Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Ensure log dir ---
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# --- Logging ---
log()   { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
error() { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"; }

# =============================================================================
# SINGLE-INSTANCE GUARD
# =============================================================================
# Две одновременно работающие копии бота делят long-polling getUpdates и
# «съедают»/дублируют сообщения (бот молчит, отвечает с ошибками, сбрасывает
# шаги добавления устройства). Ниже — АТОМАРНАЯ блокировка через flock:
# вторая копия при старте видит занятый lock и сразу завершается.
BOT_LOCK_FILE="$(dirname "$LOG_FILE")/mk_tg_bot.lock"

ensure_single_instance() {
    mkdir -p "$(dirname "$BOT_LOCK_FILE")" 2>/dev/null || true
    if command -v flock > /dev/null 2>&1; then
        # Атомарно: fd 9 держим открытым на время жизни процесса,
        # при выходе процесса ядро само снимает блокировку.
        exec 9> "$BOT_LOCK_FILE"
        if ! flock -n 9; then
            error "Бот уже запущен (lock занят: $BOT_LOCK_FILE). Остановите старый процесс и запустите бота один раз (systemd ИЛИ start_bot_with_ssh.sh)."
            exit 1
        fi
        echo "$$" >&9
    else
        # Fallback без flock: проверка pid-файла
        BOT_PID_FILE="$BOT_LOCK_FILE.pid"
        if [ -f "$BOT_PID_FILE" ]; then
            local opid
            opid=$(cat "$BOT_PID_FILE" 2>/dev/null || true)
            if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null; then
                error "Бот уже запущен (pid=$opid). Запустите только один экземпляр."
                exit 1
            fi
            rm -f "$BOT_PID_FILE"
        fi
        echo "$$" > "$BOT_PID_FILE"
        trap 'rm -f "$BOT_PID_FILE"' EXIT
    fi
    log "Single-instance lock acquired (pid=$$)"
}

# =============================================================================
# BOT FUNCTIONS (using proxy-aware tg_* helpers)
# =============================================================================

# --- SSH public key sender ---
send_ssh_public_key() {
    local key_type="$1"
    local key_file=""

    case "$key_type" in
        mikrotik) key_file="$HOME/.ssh/mk_key.pub" ; key_name="MikroTik Backup Key" ;;
        github)   key_file="$HOME/.ssh/github_key.pub" ; key_name="GitHub Key" ;;
        server)   key_file="$HOME/.ssh/id_rsa.pub" ; key_name="Server SSH Key" ;;
        *)        key_file="$HOME/.ssh/id_rsa.pub" ; key_name="Default SSH Key" ;;
    esac

    if [ ! -f "$key_file" ]; then
        tg_send_message "$TELEGRAM_CHAT_ID" \
            "❌ <b>SSH key not found:</b>\n$key_file\n\nGenerate:\n<code>ssh-keygen -t rsa -f ~/.ssh/$(basename "$key_file" .pub)</code>"
        return 1
    fi

    local key_content=$(cat "$key_file")
    local key_fingerprint=$(ssh-keygen -l -f "$key_file" 2>/dev/null | cut -d' ' -f2)
    local message="🔑 <b>$key_name</b>\n\n<code>$key_content</code>"
    [ -n "$key_fingerprint" ] && message+="\n\nFingerprint: <code>$key_fingerprint</code>"

    if [ ${#key_content} -gt 4000 ]; then
        local temp_file="/tmp/ssh_key_${key_type}.txt"
        echo "$key_content" > "$temp_file"
        tg_send_document "$TELEGRAM_CHAT_ID" "$temp_file" "🔑 <b>$key_name</b>"
        rm -f "$temp_file"
    else
        tg_send_message "$TELEGRAM_CHAT_ID" "$message"
    fi

    log "SSH public key sent: $key_name"
}

# --- SSH keys menu ---
show_ssh_keys_menu() {
    local keyboard='[
        [{"text": "🔑 MikroTik Key", "callback_data": "ssh_key_mikrotik"}],
        [{"text": "🐙 GitHub Key", "callback_data": "ssh_key_github"}],
        [{"text": "🖥️ Server Key", "callback_data": "ssh_key_server"}],
        [{"text": "🔙 Back", "callback_data": "menu"}]
    ]'
    tg_send_keyboard "$TELEGRAM_CHAT_ID" "🔑 <b>SSH Public Keys</b>\nSelect key to download:" "$keyboard"
}

# --- Backup execution ---
perform_backup() {
    local device_name="$1"
    log "Starting manual backup: $device_name"
    tg_send_message "$TELEGRAM_CHAT_ID" "🔄 <b>Starting backup:</b> $device_name"

    if [ "$device_name" = "all" ]; then
        if $BACKUP_SCRIPT --telegram "manual" >> "$LOG_FILE" 2>&1; then
            log "Backup all completed successfully"
        else
            tg_send_message "$TELEGRAM_CHAT_ID" "❌ <b>Backup failed!</b> Check logs."
            error "Backup failed for all devices"
        fi
    else
        if $BACKUP_SCRIPT --device "$device_name" --telegram "manual" >> "$LOG_FILE" 2>&1; then
            tg_send_message "$TELEGRAM_CHAT_ID" "✅ <b>Backup OK!</b>\nDevice: $device_name"
            log "Backup OK: $device_name"
        else
            tg_send_message "$TELEGRAM_CHAT_ID" "❌ <b>Backup failed!</b>\nDevice: $device_name\nCheck logs."
            error "Backup failed: $device_name"
        fi
    fi
}

# --- Backup status ---
get_backup_status() {
    local status_report="📊 <b>Backup Status Report</b>\n\n"
    local total_devices=0 backed_up_devices=0

    while IFS=':' read -r name ip port user description; do
        [[ $name =~ ^# ]] || [[ -z $name ]] && continue
        ((total_devices++))
        local backup_dir="/home/aionis/MikroGit/bckp/$name"
        local latest_backup=$(ls -1t "$backup_dir"/*.rsc 2>/dev/null | head -1)

        if [ -n "$latest_backup" ] && [ -f "$latest_backup" ]; then
            local backup_time=$(stat -c %y "$latest_backup" 2>/dev/null | cut -d'.' -f1)
            local file_size=$(stat -c%s "$latest_backup" 2>/dev/null)
            local time_diff=$(( ($(date +%s) - $(date -d "$backup_time" +%s)) / 3600 ))
            if [ $time_diff -lt 24 ]; then
                status_report+="✅ <b>$name</b>\n   🕐 $backup_time (${time_diff}h ago)\n"
            else
                status_report+="⚠️ <b>$name</b>\n   🕐 $backup_time ($((time_diff/24))d ago)\n"
            fi
            status_report+="   📁 $((file_size/1024)) KB\n\n"
            ((backed_up_devices++))
        else
            status_report+="❌ <b>$name</b>\n   📅 No backups\n\n"
        fi
    done < "$CONFIG_FILE"

    status_report+="📈 <b>Summary:</b> $backed_up_devices/$total_devices devices backed up"
    tg_send_message "$TELEGRAM_CHAT_ID" "$status_report"
}

# --- List devices ---
list_devices() {
    local device_list="📋 <b>Configured Devices:</b>\n\n"
    local count=1
    while IFS=':' read -r name ip port user description; do
        [[ $name =~ ^# ]] || [[ -z $name ]] && continue
        device_list+="$count. <b>$name</b>\n   📍 $ip:$port\n   👤 $user\n   📝 $description\n\n"
        ((count++))
    done < "$CONFIG_FILE"
    device_list+="Total: $((count-1)) devices"
    tg_send_message "$TELEGRAM_CHAT_ID" "$device_list"
}

# --- Interactive device addition ---
start_device_addition() {
    local chat_id="$1"
    set_user_state "$chat_id" "waiting_for_device_name"
    local msg="📝 <b>Adding New Device - Step 1/5</b>\n\n"
    msg+="Enter device name:\n• Only letters, numbers, underscores, hyphens\n"
    msg+="• Example: <code>office_router</code>\n\nSend /cancel to stop"
    tg_send_message "$chat_id" "$msg"
    log "Started device addition for: $chat_id"
}

handle_device_name() {
    local chat_id="$1" device_name="$2"
    if [ -z "$device_name" ]; then
        tg_send_message "$chat_id" "❌ <b>Device name cannot be empty!</b>\nEnter device name:"
        return 1
    fi
    if ! echo "$device_name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        tg_send_message "$chat_id" "❌ <b>Invalid name!</b>\nOnly letters, numbers, _, -\nEnter device name:"
        return 1
    fi
    if grep -q "^$device_name:" "$CONFIG_FILE" 2>/dev/null; then
        tg_send_message "$chat_id" "❌ <b>Device already exists!</b>\nEnter different name:"
        return 1
    fi
    set_user_data "$chat_id" "device_name" "$device_name"
    set_user_state "$chat_id" "waiting_for_device_ip"
    tg_send_message "$chat_id" "✅ <b>Device name:</b> <code>$device_name</code>\n\n<b>Step 2/5</b>\nEnter IP address:\n• Example: <code>192.168.1.1</code>"
}

handle_device_ip() {
    local chat_id="$1" device_ip="$2"
    if ! echo "$device_ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        tg_send_message "$chat_id" "❌ <b>Invalid IP!</b>\nEnter valid IP (e.g., 192.168.1.1):"
        return 1
    fi
    set_user_data "$chat_id" "device_ip" "$device_ip"
    set_user_state "$chat_id" "waiting_for_device_port"
    tg_send_message "$chat_id" "✅ <b>IP:</b> <code>$device_ip</code>\n\n<b>Step 3/5</b>\nEnter SSH port:\n• Default: <code>22</code>"
}

handle_device_port() {
    local chat_id="$1" device_port="$2"
    device_port="${device_port:-22}"
    if ! [[ "$device_port" =~ ^[0-9]+$ ]] || [ "$device_port" -lt 1 ] || [ "$device_port" -gt 65535 ]; then
        tg_send_message "$chat_id" "❌ <b>Invalid port!</b>\nEnter number 1-65535:"
        return 1
    fi
    set_user_data "$chat_id" "device_port" "$device_port"
    set_user_state "$chat_id" "waiting_for_device_user"
    tg_send_message "$chat_id" "✅ <b>Port:</b> <code>$device_port</code>\n\n<b>Step 4/5</b>\nEnter SSH username:\n• Example: <code>admin</code>"
}

handle_device_user() {
    local chat_id="$1" device_user="$2"
    if [ -z "$device_user" ]; then
        tg_send_message "$chat_id" "❌ <b>Username cannot be empty!</b>\nEnter username:"
        return 1
    fi
    set_user_data "$chat_id" "device_user" "$device_user"
    set_user_state "$chat_id" "waiting_for_device_description"
    tg_send_message "$chat_id" "✅ <b>User:</b> <code>$device_user</code>\n\n<b>Step 5/5</b>\nEnter description (or /skip):"
}

handle_device_description() {
    local chat_id="$1" description="$2"
    local device_name=$(get_user_data "$chat_id" "device_name")
    local device_ip=$(get_user_data "$chat_id" "device_ip")
    local device_port=$(get_user_data "$chat_id" "device_port")
    local device_user=$(get_user_data "$chat_id" "device_user")
    [ -z "$description" ] && description="MikroTik Device"

    # Save to config
    echo "$device_name:$device_ip:$device_port:$device_user:$description" >> "$CONFIG_FILE"
    clear_user_state "$chat_id"

    local msg="🎉 <b>Device added!</b>\n\n"
    msg+="┌ <b>Name:</b> <code>$device_name</code>\n"
    msg+="├ <b>IP:</b> <code>$device_ip</code>\n"
    msg+="├ <b>Port:</b> <code>$device_port</code>\n"
    msg+="├ <b>User:</b> <code>$device_user</code>\n"
    msg+="└ <b>Description:</b> $description\n\n"
    msg+="📊 Total devices: <b>$(grep -c '^[^#]' "$CONFIG_FILE")</b>"
    tg_send_message "$chat_id" "$msg"
    log "Device added: $device_name"

    # Test connection
    tg_send_message "$chat_id" "🔍 <b>Testing connection...</b>"
    test_device_connection "$device_name" "$device_ip" "$device_port" "$device_user"
}

cancel_device_addition() {
    local chat_id="$1"
    clear_user_state "$chat_id"
    tg_send_message "$chat_id" "❌ <b>Device addition cancelled.</b>"
    show_menu
}

test_device_connection() {
    local name="$1" ip="$2" port="$3" user="$4"
    local ssh_opts="-o PubkeyAcceptedAlgorithms=+ssh-rsa -o ConnectTimeout=10 -o BatchMode=yes"
    if ssh -p "$port" -i "$SSH_KEY" $ssh_opts "$user@$ip" "/system identity print" > /dev/null 2>&1; then
        local identity=$(ssh -p "$port" -i "$SSH_KEY" $ssh_opts "$user@$ip" "/system identity print" 2>/dev/null | grep "name:" | cut -d":" -f2 | xargs)
        tg_send_message "$TELEGRAM_CHAT_ID" "✅ <b>Connection OK!</b>\nIdentity: <code>$identity</code>"
    else
        tg_send_message "$TELEGRAM_CHAT_ID" "⚠️ <b>Connection failed!</b>\nCheck IP, port, SSH key, network.\nDevice saved but backup may fail."
    fi
}

remove_device() {
    local device_name="$1"
    if ! grep -q "^$device_name:" "$CONFIG_FILE"; then
        tg_send_message "$TELEGRAM_CHAT_ID" "❌ <b>Device not found:</b> $device_name"
        return 1
    fi
    sed -i "/^$device_name:/d" "$CONFIG_FILE"
    tg_send_message "$TELEGRAM_CHAT_ID" "✅ <b>Device removed:</b> $device_name"
    log "Device removed: $device_name"
}

# --- Backup download ---
list_backups_for_download() {
    local device_name="$1"
    local backup_dir="/home/aionis/MikroGit/bckp/$device_name"

    if [ ! -d "$backup_dir" ] || [ -z "$(ls -1 "$backup_dir"/*.rsc 2>/dev/null)" ]; then
        tg_send_message "$TELEGRAM_CHAT_ID" "❌ <b>No backups for:</b> $device_name"
        return 1
    fi

    local backup_list="📂 <b>$device_name backups:</b>\n\n"
    local count=1
    local keyboard='['

    for backup_file in $(ls -1t "$backup_dir"/*.rsc 2>/dev/null | head -10); do
        local filename=$(basename "$backup_file")
        local file_size=$(stat -c%s "$backup_file" 2>/dev/null)
        local backup_time=$(stat -c %y "$backup_file" 2>/dev/null | cut -d'.' -f1)
        backup_list+="$count. <code>$filename</code>\n   📅 $backup_time  📁 $((file_size/1024)) KB\n\n"
        # Use a safe delimiter: we encode device+filename with a double underscore separator
        keyboard+='[{"text": "#'$count' - '$filename'", "callback_data": "dl_'$device_name'__'$filename'"}],'
        ((count++))
    done
    keyboard+='[{"text": "🔙 Back", "callback_data": "download_menu"}]'
    keyboard+=']'

    tg_send_keyboard "$TELEGRAM_CHAT_ID" "$backup_list" "$keyboard"
}

send_backup_file() {
    local device_name="$1" filename="$2"
    local backup_file="/home/aionis/MikroGit/bckp/$device_name/$filename"

    log "Sending backup: $device_name / $filename"

    if [ ! -f "$backup_file" ]; then
        local available=$(ls -1 "/home/aionis/MikroGit/bckp/$device_name/"*.rsc 2>/dev/null | head -5 | xargs -I {} basename {} | tr '\n' ', ')
        tg_send_message "$TELEGRAM_CHAT_ID" "❌ <b>File not found:</b> $filename\nAvailable: $available"
        return 1
    fi

    local file_size=$(stat -c%s "$backup_file")
    local max_size=50000000  # 50 MB Telegram limit

    if [ $file_size -gt $max_size ]; then
        local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        ip="${ip:-YOUR_SERVER_IP}"
        tg_send_message "$TELEGRAM_CHAT_ID" "📁 <b>File too large</b> ($((file_size/1024/1024)) MB)\nDownload via SSH:\n<code>scp aionis@$ip:$backup_file .</code>"
        return 1
    fi

    tg_send_document "$TELEGRAM_CHAT_ID" "$backup_file"
    if [ $? -eq 0 ]; then
        log "Backup sent: $filename"
        return 0
    else
        tg_send_message "$TELEGRAM_CHAT_ID" "❌ <b>Failed to send:</b> $filename"
        return 1
    fi
}

get_latest_backup() {
    local device_name="$1"
    local backup_dir="/home/aionis/MikroGit/bckp/$device_name"
    local latest_backup=$(ls -1t "$backup_dir"/*.rsc 2>/dev/null | head -1)
    if [ -z "$latest_backup" ]; then
        tg_send_message "$TELEGRAM_CHAT_ID" "❌ <b>No backups for:</b> $device_name"
        return 1
    fi
    local filename=$(basename "$latest_backup")
    tg_send_message "$TELEGRAM_CHAT_ID" "📥 <b>Sending latest:</b> $device_name / $filename"
    send_backup_file "$device_name" "$filename"
}

send_latest_backups() {
    local count=0 devices_with_backups=0 total_devices=0

    while IFS=':' read -r name ip port user description; do
        [[ $name =~ ^# ]] || [[ -z $name ]] && continue
        ((total_devices++))
        local backup_dir="/home/aionis/MikroGit/bckp/$name"
        local lb=$(ls -1t "$backup_dir"/*.rsc 2>/dev/null | head -1)
        [ -n "$lb" ] && [ -f "$lb" ] && ((devices_with_backups++))
    done < "$CONFIG_FILE"

    if [ $devices_with_backups -eq 0 ]; then
        tg_send_message "$TELEGRAM_CHAT_ID" "❌ <b>No backups found!</b>"
        return 1
    fi

    tg_send_message "$TELEGRAM_CHAT_ID" "📥 <b>Sending latest backups...</b>\n$devices_with_backups/$total_devices devices have backups"

    while IFS=':' read -r name ip port user description; do
        [[ $name =~ ^# ]] || [[ -z $name ]] && continue
        local backup_dir="/home/aionis/MikroGit/bckp/$name"
        local lb=$(ls -1t "$backup_dir"/*.rsc 2>/dev/null | head -1)
        if [ -n "$lb" ] && [ -f "$lb" ]; then
            if send_backup_file "$name" "$(basename "$lb")"; then
                ((count++))
            fi
            sleep 2  # Rate limit protection
        fi
    done < "$CONFIG_FILE"

    [ $count -gt 0 ] \
        && tg_send_message "$TELEGRAM_CHAT_ID" "✅ <b>Done!</b> Sent $count backup files." \
        || tg_send_message "$TELEGRAM_CHAT_ID" "❌ <b>Failed to send any files!</b>"
}

# =============================================================================
# MENUS
# =============================================================================

show_menu() {
    local keyboard='[
        [{"text": "📊 Status", "callback_data": "status"}, {"text": "📥 Download", "callback_data": "download_menu"}],
        [{"text": "🔄 Backup All", "callback_data": "backup_all"}, {"text": "🔧 Backup Device", "callback_data": "backup_menu"}],
        [{"text": "📋 List Devices", "callback_data": "list_devices"}, {"text": "🔑 SSH Keys", "callback_data": "ssh_keys_menu"}],
        [{"text": "⬆️ Обновления RouterOS", "callback_data": "upd_menu"}],
        [{"text": "➕ Add Device", "callback_data": "add_device"}]
    ]'
    tg_send_keyboard "$TELEGRAM_CHAT_ID" "🤖 <b>MikroTik Backup Bot</b>\nChoose an action:" "$keyboard"
}

show_backup_menu() {
    local keyboard='['
    local count=0
    while IFS=':' read -r name ip port user description; do
        [[ $name =~ ^# ]] || [[ -z $name ]] && continue
        keyboard+='[{"text": "🔧 '$name'", "callback_data": "backup_'$name'"}],'
        ((count++))
    done < "$CONFIG_FILE"
    [ $count -eq 0 ] && { tg_send_message "$TELEGRAM_CHAT_ID" "No devices configured!"; return 1; }
    keyboard+='[{"text": "🔄 Backup All", "callback_data": "backup_all"}],'
    keyboard+='[{"text": "🔙 Back", "callback_data": "menu"}]'
    keyboard+=']'
    tg_send_keyboard "$TELEGRAM_CHAT_ID" "🔧 <b>Select device for backup:</b>" "$keyboard"
}

show_download_menu() {
    local keyboard='['
    local has_backups=0
    while IFS=':' read -r name ip port user description; do
        [[ $name =~ ^# ]] || [[ -z $name ]] && continue
        local backup_dir="/home/aionis/MikroGit/bckp/$name"
        if [ -d "$backup_dir" ] && [ -n "$(ls -1 "$backup_dir"/*.rsc 2>/dev/null)" ]; then
            keyboard+='[{"text": "📂 '$name'", "callback_data": "download_list_'$name'"}],'
            has_backups=1
        fi
    done < "$CONFIG_FILE"
    [ $has_backups -eq 0 ] && { tg_send_message "$TELEGRAM_CHAT_ID" "No backups found!"; return 1; }
    keyboard+='[{"text": "📥 Download All Latest", "callback_data": "download_all_latest"}],'
    keyboard+='[{"text": "🔙 Back", "callback_data": "menu"}]'
    keyboard+=']'
    tg_send_keyboard "$TELEGRAM_CHAT_ID" "📥 <b>Select device:</b>" "$keyboard"
}

# =============================================================================
# ROUTEROS UPDATES (см. mk_updates.sh)
# =============================================================================

# Запуск фонового worker'а обновлений (не блокирует цикл опроса)
rup_spawn() {
    nohup bash "$SCRIPT_DIR/mk_updates.sh" "$@" >> "$LOG_FILE" 2>&1 &
    log "Update worker spawned: mk_updates.sh $*"
}

show_updates_menu() {
    local keyboard='[
        [{"text": "⬆️ Обновить ВСЕ по очереди (AP→SW→GW)", "callback_data": "upd_all"}],
        [{"text": "🔎 Проверить сейчас (все)", "callback_data": "upd_check_all"}],
        [{"text": "📋 Последний статус", "callback_data": "upd_status"}],
        [{"text": "🔩 RouterBOOT firmware", "callback_data": "upd_rb_menu"}],
        [{"text": "🔙 Back", "callback_data": "menu"}]
    ]'
    tg_send_keyboard "$TELEGRAM_CHAT_ID" "⬆️ <b>Обновления RouterOS</b>\n\n• Проверка идёт через сам роутер (<code>/system package update</code>)\n• Перед установкой создаётся резервная копия (MikroGit)\n• Установка — только после вашего подтверждения и требует перезагрузки устройства\n• Обновление — в рамках текущей ветки (6.x или 7.x)\n• RouterBOOT firmware обновляется автоматически сразу после обновления RouterOS\n  (отдельно — кнопкой «RouterBOOT firmware»)\n\nВыберите действие:" "$keyboard"
}

start_update_check() {
    log "Manual update check requested"

    # Считаем устройства, чтобы сразу показать объём работы
    local cnt=0 line
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [ -z "$line" ] && continue
        cnt=$((cnt + 1))
    done < "${CONFIG_FILE:-/home/aionis/MikroGit/devices.conf}"

    tg_send_message "$TELEGRAM_CHAT_ID" "🔎 <b>Запускаю проверку обновлений…</b>
Устройств: ${cnt}. Результат по каждому придёт отдельным сообщением.
Если устройство не отвечает или у него нет доступа к серверам MikroTik, проверка одного роутера может занять до ~2,5 минут (таймаут)."

    rup_spawn check all

    # Убеждаемся, что фоновый воркер реально стартовал (pid-файл, до ~6 сек)
    local alive="" wpid i
    for i in $(seq 1 12); do
        wpid=$(cat "$(rup_state_dir)/worker_last.pid" 2>/dev/null || true)
        if [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then
            alive=1
            break
        fi
        sleep 0.5
    done

    if [ "${alive:-0}" != "1" ]; then
        error "Update worker did not start (check $LOG_FILE)"
        tg_send_message "$TELEGRAM_CHAT_ID" "⚠️ <b>Фоновая проверка не запустилась.</b>
Смотрите лог: <code>$LOG_FILE</code>"
    fi
}

ask_install_update() {
    local dname="$1"
    local tsvinfo detail="" s inst latest
    tsvinfo=$(grep -P "^$dname\t" "$(rup_state_dir)/last_check.tsv" 2>/dev/null | head -1)
    if [ -n "$tsvinfo" ]; then
        IFS=$'\t' read -r _ s _ inst latest _ _ <<< "$tsvinfo"
        detail="\n📦 $inst → <b>${latest:-?}</b>"
    fi
    local keyboard='[
        [{"text": "✅ Подтвердить и обновить", "callback_data": "upd_confirm_'"$dname"'"}],
        [{"text": "❌ Отмена", "callback_data": "upd_cancel_'"$dname"'"}]
    ]'
    tg_send_keyboard "$TELEGRAM_CHAT_ID" "⚠️ <b>Подтвердите установку RouterOS</b> на <b>$dname</b>$detail\n\n• Сначала будет сделана резервная копия конфигурации\n• Роутер <b>перезагрузится</b> (~2–5 минут недоступности)\n• Обновление — в рамках текущей ветки\n\nПродолжить?" "$keyboard"
}

confirm_install_update() {
    local dname="$1"
    # Уже идёт установка на это устройство?
    if [ -d "$(rup_state_dir)/lock_apply_$dname" ]; then
        tg_send_message "$TELEGRAM_CHAT_ID" "⏳ На устройстве <b>$dname</b> уже выполняется установка. Дождитесь завершения."
        return 1
    fi
    log "Confirm update install: $dname"
    tg_send_message "$TELEGRAM_CHAT_ID" "🔄 <b>$dname</b>: запускаю установку RouterOS…\nХод выполнения буду присылать сюда."
    rup_spawn apply "$dname"
}

cancel_install_update() {
    local dname="$1"
    log "Update install cancelled: $dname"
    tg_send_message "$TELEGRAM_CHAT_ID" "❌ Установка на <b>$dname</b> отменена."
}

# --- RouterBOOT firmware: меню выбора устройства и подтверждение ---
show_rb_menu() {
    local keyboard='['
    local count=0 name ip port user description
    while IFS=':' read -r name ip port user description; do
        [[ $name =~ ^# ]] || [[ -z $name ]] && continue
        keyboard+='[{"text":"🔩 '$name'","callback_data":"upd_rb_pick_'$name'"}],'
        ((count++))
    done < "${CONFIG_FILE:-/home/aionis/MikroGit/devices.conf}"
    [ $count -eq 0 ] && { tg_send_message "$TELEGRAM_CHAT_ID" "❌ Нет устройств в devices.conf."; return 1; }
    keyboard+='[{"text":"🔙 Back","callback_data":"upd_menu"}]'
    keyboard+=']'
    tg_send_keyboard "$TELEGRAM_CHAT_ID" "🔩 <b>RouterBOOT firmware</b>\n\nОбновление загрузчика (<code>/system routerboard upgrade</code>) с последующей перезагрузкой.\nВыберите устройство (или вернитесь в меню обновлений):" "$keyboard"
}

ask_rb_upgrade() {
    local dname="$1"
    log "RouterBOOT upgrade requested: $dname"
    local keyboard='[
        [{"text": "✅ Обновить RouterBOOT", "callback_data": "upd_rb_confirm_'\"$dname\"'"}],
        [{"text": "❌ Отмена", "callback_data": "upd_rb_cancel_'\"$dname\"'"}]
    ]'
    tg_send_keyboard "$TELEGRAM_CHAT_ID" "⚠️ <b>Подтвердите обновление RouterBOOT firmware</b> на <b>$dname</b>\n\n• Выполнится <code>/system routerboard upgrade</code>\n• Роутер <b>перезагрузится</b> и будет недоступен несколько минут\n• <b>НЕ выключайте питание</b> во время прошивки!\n\nПродолжить?" "$keyboard"
}

confirm_rb_upgrade() {
    local dname="$1"
    if [ -d "$(rup_state_dir)/lock_apply_$dname" ]; then
        tg_send_message "$TELEGRAM_CHAT_ID" "⏳ На устройстве <b>$dname</b> уже выполняется операция (установка/обновление RouterBOOT). Дождитесь завершения."
        return 1
    fi
    log "Confirm RouterBOOT upgrade: $dname"
    tg_send_message "$TELEGRAM_CHAT_ID" "🔩 <b>$dname</b>: запускаю обновление RouterBOOT firmware…\nХод выполнения буду присылать сюда."
    rup_spawn routerboard "$dname"
}

cancel_rb_upgrade() {
    local dname="$1"
    log "RouterBOOT upgrade cancelled: $dname"
    tg_send_message "$TELEGRAM_CHAT_ID" "❌ Обновление RouterBOOT на <b>$dname</b> отменено."
}

# --- Обновить все по очереди (AP -> SW -> GW -> остальные) ---
ask_update_all() {
    log "Update ALL requested"
    local keyboard='[
        [{"text": "✅ Да, обновить все по очереди", "callback_data": "upd_all_confirm"}],
        [{"text": "❌ Отмена", "callback_data": "upd_all_cancel"}]
    ]'
    tg_send_keyboard "$TELEGRAM_CHAT_ID" "⚠️ <b>Обновить ВСЕ устройства по очереди?</b>\n\n• Порядок: <b>AP → SW → GW</b> → остальные (по имени из devices.conf)\n• Каждое устройство обновляется и <b>проверяется</b> перед переходом к следующему\n• После RouterOS — автоматически проверяется и обновляется RouterBOOT firmware\n• Роутеры будут <b>перезагружаться</b> по одному; весь процесс может занять <b>долгое время</b>\n\nПродолжить?" "$keyboard"
}

confirm_update_all() {
    log "Confirm update ALL"
    if [ -d "$(rup_state_dir)/lock_update_all" ]; then
        tg_send_message "$TELEGRAM_CHAT_ID" "⏳ Обновление всех уже запущено. Дождитесь завершения."
        return 1
    fi
    tg_send_message "$TELEGRAM_CHAT_ID" "🔄 <b>Запускаю поочерёдное обновление всех устройств…</b>\nХод выполнения буду присылать сюда."
    rup_spawn updateall
}

cancel_update_all() {
    log "Update ALL cancelled"
    tg_send_message "$TELEGRAM_CHAT_ID" "❌ Обновление всех отменено."
}

# =============================================================================
# UPDATE PROCESSING
# =============================================================================

process_update() {
    local update="$1"

    local message_text=$(echo "$update" | jq -r '.message.text // ""')
    local callback_data=$(echo "$update" | jq -r '.callback_query.data // ""')
    local chat_id=$(echo "$update" | jq -r '.message.chat.id // .callback_query.message.chat.id')

    # --- Authorization check ---
    if [ "$chat_id" != "$TELEGRAM_CHAT_ID" ]; then
        log "Unauthorized access: $chat_id"
        return
    fi

    # Диагностика каждого апдейта: тип (text/callback/other), чтобы по логу
    # было видно, какие сообщения реально доходят до бота.
    local upd_type="text"
    if [ -n "$callback_data" ]; then upd_type="callback"; fi
    if echo "$update" | jq -e '.message.photo or .message.sticker or .message.document or .message.voice or .message.video' > /dev/null 2>&1; then
        upd_type="non-text-media"
    elif [ -n "$message_text" ]; then :;
    elif [ -z "$callback_data" ]; then upd_type="empty"
    fi
    log "Update - chat=$chat_id type=$upd_type text='$message_text' cb='$callback_data'"

    # --- Interactive mode (adding device) ---
    local user_state=$(get_user_state "$chat_id")
    if [ -n "$user_state" ] && [ -n "$message_text" ]; then
        # Команды (начинаются с "/") ВСЕГДА обрабатываются как команды, а не
        # как очередной шаг ввода. Иначе застрявшее состояние (например, после
        # рестарта бота посреди добавления устройства) "перехватывает" /menu,
        # /start и другие команды — и из него невозможно выйти.
        if [[ "$message_text" == /* ]]; then
            log "Interactive state ($user_state) прервана командой: $message_text"
        else
            log "Interactive mode - state=$user_state msg=$message_text"
            case "$user_state" in
                waiting_for_device_name)        handle_device_name "$chat_id" "$message_text" ;;
                waiting_for_device_ip)          handle_device_ip "$chat_id" "$message_text" ;;
                waiting_for_device_port)        handle_device_port "$chat_id" "$message_text" ;;
                waiting_for_device_user)        handle_device_user "$chat_id" "$message_text" ;;
                waiting_for_device_description) handle_device_description "$chat_id" "$message_text" ;;
                *) clear_user_state "$chat_id"; show_menu ;;
            esac
            return
        fi
    fi

    # Во время активного ввода пришло НЕ-текстовое сообщение (стикер, фото,
    # голосовое и т.п.) — по нему шаг ввода не выполняется. Напомним, что
    # нужен текст, и НЕ сбрасываем состояние (чтобы пользователь мог
    # продолжить ввод с того же шага).
    if [ -n "$user_state" ] && [ -z "$message_text" ] && [ -z "$callback_data" ]; then
        log "Interactive state ($user_state): пришло не-текстовое сообщение — просим текст"
        tg_send_message "$chat_id" "✍️ Отправьте, пожалуйста, <b>текстом</b> (сейчас бот ждёт ввода на шаге: <code>$user_state</code>).\nКоманда /cancel — отмена."
        return
    fi

    # --- Callback queries ---
    if [ -n "$callback_data" ]; then
        # Снимаем "часики" с кнопки у всех callback'ов
        local cb_id cb_msg_id
        cb_id=$(echo "$update" | jq -r '.callback_query.id // ""')
        cb_msg_id=$(echo "$update" | jq -r '.callback_query.message.message_id // ""')
        [ -n "$cb_id" ] && tg_answer_callback "$cb_id"

        case "$callback_data" in
            menu)               clear_user_state "$chat_id"; show_menu ;;
            status)             get_backup_status ;;
            list_devices)       list_devices ;;
            backup_all)         perform_backup "all" ;;
            add_device)         start_device_addition "$chat_id" ;;
            ssh_keys_menu)      show_ssh_keys_menu ;;
            download_menu)      show_download_menu ;;
            download_all_latest) send_latest_backups ;;

            # --- RouterOS updates ---
            upd_menu)           show_updates_menu ;;
            upd_check_all)      start_update_check ;;
            upd_status)         rup_print_cached_status ;;
            upd_install_*)
                local dname=${callback_data#upd_install_}
                if [[ "$dname" =~ ^[A-Za-z0-9_-]+$ ]]; then
                    tg_clear_keyboard "$chat_id" "$cb_msg_id"
                    ask_install_update "$dname"
                fi ;;
            upd_confirm_*)
                local dname=${callback_data#upd_confirm_}
                if [[ "$dname" =~ ^[A-Za-z0-9_-]+$ ]]; then
                    tg_clear_keyboard "$chat_id" "$cb_msg_id"
                    confirm_install_update "$dname"
                fi ;;
            upd_cancel_*)
                local dname=${callback_data#upd_cancel_}
                if [[ "$dname" =~ ^[A-Za-z0-9_-]+$ ]]; then
                    tg_clear_keyboard "$chat_id" "$cb_msg_id"
                    cancel_install_update "$dname"
                fi ;;
            # --- RouterBOOT firmware ---
            upd_rb_menu)
                tg_clear_keyboard "$chat_id" "$cb_msg_id"
                show_rb_menu ;;
            upd_rb_pick_*)
                local rbname=${callback_data#upd_rb_pick_}
                if [[ "$rbname" =~ ^[A-Za-z0-9_-]+$ ]]; then
                    tg_clear_keyboard "$chat_id" "$cb_msg_id"
                    ask_rb_upgrade "$rbname"
                fi ;;
            upd_rb_confirm_*)
                local rbname=${callback_data#upd_rb_confirm_}
                if [[ "$rbname" =~ ^[A-Za-z0-9_-]+$ ]]; then
                    tg_clear_keyboard "$chat_id" "$cb_msg_id"
                    confirm_rb_upgrade "$rbname"
                fi ;;
            upd_rb_cancel_*)
                local rbname=${callback_data#upd_rb_cancel_}
                if [[ "$rbname" =~ ^[A-Za-z0-9_-]+$ ]]; then
                    tg_clear_keyboard "$chat_id" "$cb_msg_id"
                    cancel_rb_upgrade "$rbname"
                fi ;;
            upd_all)
                tg_clear_keyboard "$chat_id" "$cb_msg_id"
                ask_update_all ;;
            upd_all_confirm)
                tg_clear_keyboard "$chat_id" "$cb_msg_id"
                confirm_update_all ;;
            upd_all_cancel)
                tg_clear_keyboard "$chat_id" "$cb_msg_id"
                cancel_update_all ;;

            download_list_*)
                local dname=${callback_data#download_list_}
                list_backups_for_download "$dname" ;;
            dl_*)
                # Format: dl_DEVICE__FILENAME (double underscore separator)
                local tmp=${callback_data#dl_}
                local dname="${tmp%%__*}"
                local fname="${tmp#*__}"
                log "Download: device=$dname file=$fname"
                send_backup_file "$dname" "$fname" ;;
            ssh_key_*)
                send_ssh_public_key "${callback_data#ssh_key_}" ;;
            latest_backup_*)
                get_latest_backup "${callback_data#latest_backup_}" ;;
            backup_menu)
                show_backup_menu ;;
            backup_*)
                local dname=${callback_data#backup_}
                if [[ "$dname" =~ ^[a-zA-Z0-9_-]+$ ]] && [ "$dname" != "menu" ] && [ "$dname" != "all" ]; then
                    perform_backup "$dname"
                else
                    error "Invalid backup callback: $callback_data"
                    tg_send_message "$TELEGRAM_CHAT_ID" "❌ Invalid selection"
                fi ;;
            *)  log "Unknown callback: $callback_data"; show_menu ;;
        esac
        return
    fi

    # --- Text commands ---
    if [ -n "$message_text" ]; then
        case "$message_text" in
            /start|/menu)   clear_user_state "$chat_id"; show_menu ;;
            /updates)       show_updates_menu ;;
            /checkupdates)  show_updates_menu ;;
            /cancel)        cancel_device_addition "$chat_id" ;;
            /status)        get_backup_status ;;
            /backup)        show_backup_menu ;;
            /download)      show_download_menu ;;
            /sshkeys)       show_ssh_keys_menu ;;
            /list)          list_devices ;;
            /add)           start_device_addition "$chat_id" ;;
            /latest)
                tg_send_message "$TELEGRAM_CHAT_ID" "❌ Usage: <code>/latest device_name</code>\nExample: <code>/latest GW_DONA</code>" ;;
            /latest\ *)
                get_latest_backup "${message_text#/latest }" ;;
            /remove)
                tg_send_message "$TELEGRAM_CHAT_ID" "❌ Usage: <code>/remove device_name</code>" ;;
            /remove\ *)
                remove_device "${message_text#/remove }" ;;
            /*)
                tg_send_message "$TELEGRAM_CHAT_ID" "❌ <b>Unknown command</b>\nUse /menu" ;;
            *)
                [ -z "$user_state" ] && show_menu
                ;;
        esac
    fi
}

# =============================================================================
# MAIN BOT LOOP
# =============================================================================

run_bot() {
    log "Starting Telegram Bot..."
    log "Proxy: ${TELEGRAM_PROXY:-none}"

    # Исключаем запуск второй копии бота
    ensure_single_instance

    # Test connection first
    if ! tg_test_connection; then
        error "Cannot reach Telegram API. Check proxy settings. Exiting."
        exit 1
    fi

    tg_send_message "$TELEGRAM_CHAT_ID" "🤖 <b>MikroTik Backup Bot started!</b>"
    tg_send_message "$TELEGRAM_CHAT_ID" "Send /menu to begin"

    local offset=0
    while true; do
        local response=$(tg_get_updates "$offset" 60)

        if [ $? -ne 0 ] || [ -z "$response" ]; then
            error "Failed to get updates from Telegram API (check proxy?)"
            sleep 10
            continue
        fi

        local updates=$(echo "$response" | jq -r '.result[]? | @base64' 2>/dev/null)

        if [ -n "$updates" ]; then
            for update in $updates; do
                [ -z "$update" ] && continue
                local decoded_update=$(echo "$update" | base64 --decode 2>/dev/null)
                [ -z "$decoded_update" ] && continue
                process_update "$decoded_update"
                offset=$(( $(echo "$decoded_update" | jq -r '.update_id' 2>/dev/null) + 1 ))
            done
        fi

        # Clean stale states periodically
        cleanup_stale_states 2>/dev/null || true

        # Автопроверка обновлений по расписанию (не блокирует цикл)
        rup_maybe_auto_check 2>/dev/null || true
    done
}

# --- Dependency check ---
check_dependencies() {
    local missing=()
    for cmd in jq curl; do
        command -v "$cmd" &> /dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing[*]}. Install: sudo apt install ${missing[*]}"
        exit 1
    fi
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
        error "TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set in config"
        exit 1
    fi
}

# --- Entry point ---
main() {
    check_dependencies
    log "MikroTik Telegram Bot starting..."
    run_bot
}

main "$@"


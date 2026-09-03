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

    log "Update - chat=$chat_id text='$message_text' cb='$callback_data'"

    # --- Interactive mode (adding device) ---
    local user_state=$(get_user_state "$chat_id")
    if [ -n "$user_state" ] && [ -n "$message_text" ]; then
        log "Interactive mode - state=$user_state msg=$message_text"

        if [ "$message_text" = "/cancel" ]; then
            cancel_device_addition "$chat_id"
            return
        fi

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

    # --- Callback queries ---
    if [ -n "$callback_data" ]; then
        case "$callback_data" in
            menu)               clear_user_state "$chat_id"; show_menu ;;
            status)             get_backup_status ;;
            list_devices)       list_devices ;;
            backup_all)         perform_backup "all" ;;
            add_device)         start_device_addition "$chat_id" ;;
            ssh_keys_menu)      show_ssh_keys_menu ;;
            download_menu)      show_download_menu ;;
            download_all_latest) send_latest_backups ;;
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

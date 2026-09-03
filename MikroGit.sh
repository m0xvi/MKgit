#!/bin/bash
# =============================================================================
# MikroTik Multi-Device Backup Script (Proxy-Aware)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
CONFIG_FILE="${CONFIG_FILE:-/home/aionis/MikroGit/devices.conf}"
BACKUP_DIR="${BACKUP_DIR:-/home/aionis/MikroGit/bckp}"
REPO_DIR="${REPO_DIR:-/home/aionis/MikroGit}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/mk_key}"
MAX_BACKUPS_PER_DEVICE="${MAX_BACKUPS_PER_DEVICE:-5}"
LOG_FILE="${LOG_FILE:-/home/aionis/mikrotik_backup.log}"
MAX_REPORTS="${MAX_REPORTS:-5}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Parse arguments ---
DEVICE_NAME=""
TELEGRAM_NOTIFICATION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --device)   DEVICE_NAME="$2"; shift 2 ;;
        --telegram) TELEGRAM_NOTIFICATION="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# --- Load API helpers if not already loaded ---
if ! declare -f tg_send_message > /dev/null 2>&1; then
    if [ -f "$SCRIPT_DIR/tg_api_helpers.sh" ]; then
        source "$SCRIPT_DIR/tg_api_helpers.sh"
    fi
fi

# --- Load bot config (for token/chat_id) ---
if [ -f "$SCRIPT_DIR/tg_bot_config.sh" ]; then
    source "$SCRIPT_DIR/tg_bot_config.sh"
fi

# --- Logging ---
log()    { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"; }
error()  { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"; }
warning(){ echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"; }
info()   { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"; }

# --- Telegram notification (uses proxy-aware helper) ---
send_telegram_notification() {
    local message="$1"
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        if declare -f tg_send_message > /dev/null 2>&1; then
            tg_send_message "$TELEGRAM_CHAT_ID" "$message"
        else
            # Fallback: direct curl with proxy
            local proxy_arg=""
            [ -n "${TELEGRAM_PROXY:-}" ] && proxy_arg="--proxy $TELEGRAM_PROXY"
            curl -s $proxy_arg -X POST \
                -H "Content-Type: application/json" \
                -d "{\"chat_id\":\"$TELEGRAM_CHAT_ID\",\"text\":\"$message\",\"parse_mode\":\"HTML\"}" \
                "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" > /dev/null 2>&1
        fi
    fi
}

# --- Setup SSH known hosts ---
setup_ssh_known_hosts() {
    log "Setting up SSH known hosts..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    touch ~/.ssh/known_hosts
    chmod 600 ~/.ssh/known_hosts

    # GitHub
    if ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
        log "Adding GitHub to known_hosts..."
        ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
    fi

    # MikroTik devices
    log "Adding MikroTik devices to known_hosts..."
    while IFS=':' read -r name ip port user description; do
        [[ $name =~ ^# ]] || [[ -z $name ]] && continue
        if ! grep -q "$ip" ~/.ssh/known_hosts 2>/dev/null; then
            log "Adding $ip ($name) to known_hosts..."
            ssh-keyscan -p "$port" "$ip" >> ~/.ssh/known_hosts 2>/dev/null
        fi
    done < "$CONFIG_FILE"
}

# --- Read devices from config ---
read_devices() {
    local devices=()
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Configuration file $CONFIG_FILE not found!"
        return 1
    fi

    while IFS=':' read -r name ip port user description; do
        [[ $name =~ ^# ]] || [[ -z $name ]] && continue
        name=$(echo "$name" | tr -d '\r')
        ip=$(echo "$ip" | tr -d '\r')
        port=$(echo "$port" | tr -d '\r')
        user=$(echo "$user" | tr -d '\r')
        description=$(echo "$description" | tr -d '\r')
        devices+=("$name:$ip:$port:$user:$description")
    done < "$CONFIG_FILE"

    printf '%s\n' "${devices[@]}"
}

# --- Backup a single device ---
backup_device() {
    local device_name=$1 device_ip=$2 device_port=$3 device_user=$4 description=$5
    local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    local backup_file="${device_name}_${timestamp}.rsc"
    local ssh_opts="-o PubkeyAcceptedAlgorithms=+ssh-rsa -o ConnectTimeout=15 -o BatchMode=yes"

    log "Starting backup of $device_name - $description"
    info "Device: $device_ip:$device_port User: $device_user"

    local device_backup_dir="$BACKUP_DIR/$device_name"
    mkdir -p "$device_backup_dir"

    # Test connection
    info "Testing connection to $device_name..."
    if ! ssh -p "$device_port" -i "$SSH_KEY" $ssh_opts \
        "$device_user@$device_ip" "/system identity print" > /dev/null 2>&1; then
        error "Cannot connect to $device_name ($device_ip:$device_port)"
        return 1
    fi

    # Get device info
    local identity=$(ssh -p "$device_port" -i "$SSH_KEY" $ssh_opts \
        "$device_user@$device_ip" "/system identity print" 2>/dev/null | grep "name:" | cut -d":" -f2 | xargs)

    local version=$(ssh -p "$device_port" -i "$SSH_KEY" $ssh_opts \
        "$device_user@$device_ip" "/system resource print" 2>/dev/null | grep "version:" | cut -d":" -f2 | xargs)

    info "Device Identity: $identity, Version: $version"

    # Export configuration on the device
    info "Creating export on $device_name..."
    ssh -p "$device_port" -i "$SSH_KEY" $ssh_opts -o ConnectTimeout=30 \
        "$device_user@$device_ip" "/export file=$backup_file" > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        error "Export failed on $device_name"
        return 1
    fi
    log "Export completed successfully on $device_name"

    # Wait for file creation
    sleep 5

    # Download backup file
    info "Downloading backup from $device_name..."
    scp -P "$device_port" -i "$SSH_KEY" $ssh_opts -o ConnectTimeout=30 \
        "$device_user@$device_ip:/$backup_file.rsc" "$device_backup_dir/" > /dev/null 2>&1

    local download_ok=$?
    local file_size=0

    if [ $download_ok -eq 0 ]; then
        file_size=$(stat -c%s "$device_backup_dir/$backup_file.rsc" 2>/dev/null || echo "0")
    fi

    # Alternative method if download failed or file too small
    if [ $download_ok -ne 0 ] || [ "$file_size" -le 1000 ]; then
        if [ $download_ok -ne 0 ]; then
            warning "Download failed, trying direct export method..."
        else
            warning "Backup file too small (${file_size} bytes), trying direct export..."
        fi

        ssh -p "$device_port" -i "$SSH_KEY" $ssh_opts \
            "$device_user@$device_ip" "/export" > "$device_backup_dir/$backup_file"

        if [ $? -eq 0 ]; then
            file_size=$(stat -c%s "$device_backup_dir/$backup_file" 2>/dev/null || echo "0")
            if [ "$file_size" -gt 1000 ]; then
                log "Backup via direct export: $backup_file ($((file_size/1024)) KB)"
            else
                error "All backup methods failed for $device_name"
                return 1
            fi
        else
            error "All backup methods failed for $device_name"
            return 1
        fi
    else
        log "Backup downloaded: $backup_file.rsc ($((file_size/1024)) KB)"
    fi

    # Clean up remote file
    ssh -p "$device_port" -i "$SSH_KEY" $ssh_opts \
        "$device_user@$device_ip" "/file remove $backup_file.rsc" > /dev/null 2>&1

    # Create device info file
    cat > "$device_backup_dir/device_info.txt" << EOF
Device Name: $device_name
Description: $description
IP Address: $device_ip
SSH Port: $device_port
Username: $device_user
Identity: $identity
Version: $version
Last Backup: $(date)
EOF

    return 0
}

# --- Clean old backups ---
clean_old_backups() {
    local device_name=$1
    local device_backup_dir="$BACKUP_DIR/$device_name"

    if [ -d "$device_backup_dir" ]; then
        cd "$device_backup_dir" || return 1
        local backup_count=$(ls -1 *.rsc 2>/dev/null | wc -l)
        if [ "$backup_count" -gt "$MAX_BACKUPS_PER_DEVICE" ]; then
            local files_to_remove=$((backup_count - MAX_BACKUPS_PER_DEVICE))
            info "Cleaning $files_to_remove old backups from $device_name..."
            ls -1t *.rsc | tail -n "$files_to_remove" | xargs -r rm -f
            ls -1t device_info*.txt 2>/dev/null | tail -n +2 | xargs -r rm -f
        fi
        cd "$REPO_DIR" || true
    fi
}

# --- Clean old reports ---
clean_old_reports() {
    local reports_dir="$BACKUP_DIR"
    local report_count=$(ls -1 "$reports_dir"/backup_report_*.txt 2>/dev/null | wc -l)
    if [ "$report_count" -gt "$MAX_REPORTS" ]; then
        local reports_to_remove=$((report_count - MAX_REPORTS))
        info "Cleaning $reports_to_remove old reports..."
        ls -1t "$reports_dir"/backup_report_*.txt | tail -n "$reports_to_remove" | xargs -r rm -f
    fi
}

# --- Generate report ---
generate_report() {
    local success_count=$1 fail_count=$2 total_devices=$3
    local report_file="$BACKUP_DIR/backup_report_$(date +%Y-%m-%d_%H-%M-%S).txt"

    cat > "$report_file" << EOF
MikroTik Backup Report
======================
Generated: $(date)
Total Devices: $total_devices
Successful: $success_count
Failed: $fail_count

Device Details:
EOF

    for device in "${DEVICES_ARRAY[@]}"; do
        IFS=':' read -r name ip port user description <<< "$device"
        local device_backup_dir="$BACKUP_DIR/$name"
        local latest_backup=$(ls -1t "$device_backup_dir"/*.rsc 2>/dev/null | head -1)
        if [ -n "$latest_backup" ]; then
            local backup_size=$(stat -c%s "$latest_backup" 2>/dev/null || echo "0")
            echo "✓ $name ($description): $(basename "$latest_backup") ($((backup_size/1024)) KB)" >> "$report_file"
        else
            echo "✗ $name ($description): NO BACKUP" >> "$report_file"
        fi
    done

    echo "" >> "$report_file"
    echo "Configuration file: $CONFIG_FILE" >> "$report_file"
    echo "Backup directory: $BACKUP_DIR" >> "$report_file"

    log "Backup report generated: $(basename "$report_file")"
}

# --- Main ---
main() {
    log "===== MikroTik Multi-Device Backup ====="
    log "Configuration file: $CONFIG_FILE"

    # Setup SSH known hosts
    setup_ssh_known_hosts

    # Validate prerequisites
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Configuration file $CONFIG_FILE not found!"
        send_telegram_notification "❌ <b>Backup failed!</b>\nConfig file not found: $CONFIG_FILE"
        exit 1
    fi

    if [[ ! -f "$SSH_KEY" ]]; then
        error "SSH key $SSH_KEY not found!"
        exit 1
    fi
    chmod 600 "$SSH_KEY"

    # Read devices
    mapfile -t DEVICES_ARRAY < <(read_devices)
    if [ ${#DEVICES_ARRAY[@]} -eq 0 ]; then
        error "No devices found in config"
        send_telegram_notification "❌ <b>Backup failed!</b>\nNo devices configured."
        exit 1
    fi

    # Filter by device name if specified
    if [ -n "$DEVICE_NAME" ] && [ "$DEVICE_NAME" != "all" ]; then
        local filtered_devices=()
        for device in "${DEVICES_ARRAY[@]}"; do
            IFS=':' read -r name ip port user description <<< "$device"
            if [ "$name" == "$DEVICE_NAME" ]; then
                filtered_devices+=("$device")
                break
            fi
        done
        if [ ${#filtered_devices[@]} -eq 0 ]; then
            error "Device $DEVICE_NAME not found"
            send_telegram_notification "❌ <b>Backup failed!</b>\nDevice not found: $DEVICE_NAME"
            exit 1
        fi
        DEVICES_ARRAY=("${filtered_devices[@]}")
        log "Filtered to device: $DEVICE_NAME"
    fi

    log "Processing ${#DEVICES_ARRAY[@]} devices"

    # Notification
    if [ -n "$TELEGRAM_NOTIFICATION" ]; then
        if [ -n "$DEVICE_NAME" ] && [ "$DEVICE_NAME" != "all" ]; then
            send_telegram_notification "🔄 <b>Starting manual backup</b>\nDevice: $DEVICE_NAME\nTime: $(date)"
        else
            send_telegram_notification "🔄 <b>Starting backup</b>\nDevices: ${#DEVICES_ARRAY[@]}\nTime: $(date)"
        fi
    fi

    mkdir -p "$BACKUP_DIR"
    cd "$REPO_DIR" || { error "Cannot cd to $REPO_DIR"; exit 1; }

    local success_count=0
    local fail_count=0
    local total_devices=${#DEVICES_ARRAY[@]}

    for device in "${DEVICES_ARRAY[@]}"; do
        IFS=':' read -r name ip port user description <<< "$device"
        if backup_device "$name" "$ip" "$port" "$user" "$description"; then
            ((success_count++))
            send_telegram_notification "✅ <b>Backup OK!</b>\nDevice: $name"
        else
            ((fail_count++))
            send_telegram_notification "❌ <b>Backup failed!</b>\nDevice: $name\nCheck logs."
        fi
        echo "----------------------------------------"
    done

    # Generate report
    generate_report "$success_count" "$fail_count" "$total_devices"

    # Clean old backups/reports
    log "Cleaning old backups (keeping $MAX_BACKUPS_PER_DEVICE per device)..."
    for device in "${DEVICES_ARRAY[@]}"; do
        IFS=':' read -r name ip port user description <<< "$device"
        clean_old_backups "$name"
    done

    log "Cleaning old reports (keeping $MAX_REPORTS)..."
    clean_old_reports

    log "===== Backup process completed ====="
    log "Summary: $success_count OK, $fail_count FAILED out of $total_devices"

    # Final notification
    if [ -n "$TELEGRAM_NOTIFICATION" ]; then
        if [ "$fail_count" -eq 0 ]; then
            send_telegram_notification "✅ <b>All backups OK!</b>\nDevices: $success_count/$total_devices\nTime: $(date)"
        else
            send_telegram_notification "⚠️ <b>Backup completed with errors</b>\nOK: $success_count/$total_devices\nFailed: $fail_count\nTime: $(date)"
        fi
    fi

    [ "$fail_count" -gt 0 ] && exit 1 || exit 0
}

main "$@"

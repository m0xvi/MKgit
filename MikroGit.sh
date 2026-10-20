#!/bin/bash
# =============================================================================
# MikroGit.sh — резервное копирование MikroTik RouterOS
# =============================================================================
# Что делает:
#   • создаёт БИНАРНУЮ резервную копию на роутере:
#         /system backup save name=<файл> dont-encrypt=yes
#     (формат .backup — полное восстановление конфигурации в RouterOS);
#   • скачивает её в bckp/<устройство>/ и УДАЛЯЕТ временный файл с flash
#     роутера (чтобы не забивать память устройств);
#   • бэкап, сделанный непосредственно перед обновлением RouterOS/RouterBOOT,
#     помечается в имени pre_update и хранится с отдельным лимитом ротации;
#   • пишет отчёты в logs/reports/ (а не в корень bckp/), удаляет старые
#     отчёты/логи и «осиротевшие» пустые каталоги устройств.
#
# Использование:
#   MikroGit.sh                              # бэкап всех устройств
#   MikroGit.sh --all                        # то же явно
#   MikroGit.sh --device GW_DONA             # бэкап одного устройства
#   MikroGit.sh --device GW_DONA --pre-update # бэкап ПЕРЕД обновлением
#   MikroGit.sh --cleanup                    # только обслуживание (логи/отчёты)
#   MikroGit.sh --list                       # список устройств из devices.conf
#   MikroGit.sh --telegram manual            # + уведомления в Telegram
#
# Результат:
#   bckp/<устройство>/<устройство>_<дата>_<время>.backup
#   bckp/<устройство>/<устройство>_pre_update_<дата>_<время>.backup
#   logs/reports/backup_report_<дата>_<время>.txt
#
# Старые .rsc (export) НЕ удаляются и остаются доступны в боте для скачивания.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration -----------------------------------------------------------
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/devices.conf}"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/bckp}"
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/mk_key}"

# Ротация: обычные бэкапы и бэкапы «перед обновлением» считаются раздельно,
# чтобы предобновленческий бэкап не вымывался плановыми.
MAX_BACKUPS_PER_DEVICE="${MAX_BACKUPS_PER_DEVICE:-5}"
MAX_PRE_UPDATE_BACKUPS="${MAX_PRE_UPDATE_BACKUPS:-5}"

# Логи и отчёты — в logs/, а не в домашнем каталоге и не в корне bckp/
LOG_DIR="${LOG_DIR:-$REPO_DIR/logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/mk_backup.log}"
REPORTS_DIR="${REPORTS_DIR:-$LOG_DIR/reports}"
MAX_REPORTS="${MAX_REPORTS:-5}"

# Минимальный «правдоподобный» размер .backup (меньше — считаем битым файлом)
MIN_BACKUP_BYTES="${MIN_BACKUP_BYTES:-512}"
# Сколько раз пробовать скачать файл, пока роутер его пишет на flash
BACKUP_WAIT_TRIES="${BACKUP_WAIT_TRIES:-15}"
BACKUP_WAIT_SLEEP="${BACKUP_WAIT_SLEEP:-1}"
# Таймаут команды backup save на роутере, сек
BACKUP_CMD_TIMEOUT="${BACKUP_CMD_TIMEOUT:-120}"
# Сколько ждать освобождения лока (другой бэкап уже идёт), сек
BACKUP_LOCK_WAIT="${BACKUP_LOCK_WAIT:-900}"

# Каталоги создаём лениво (--list не должен ничего писать на диск)
ensure_dirs() { mkdir -p "$LOG_DIR" "$REPORTS_DIR" "$BACKUP_DIR" 2>/dev/null || true; }

# --- Общая библиотека работы с файлами бэкапов -------------------------------
if [ -f "$SCRIPT_DIR/tg/mk_backup_lib.sh" ]; then
    # shellcheck source=tg/mk_backup_lib.sh
    source "$SCRIPT_DIR/tg/mk_backup_lib.sh"
fi
if ! declare -f bkl_list_backups > /dev/null 2>&1; then
    # Минимальный fallback, если библиотеку не скопировали
    bkl_is_pre_update() { case "$(basename "${1:-}")" in *pre_update*) return 0;; esac; return 1; }
    bkl_list_backups() {
        local dir="${1:-}" kind="${2:-all}" f
        [ -d "$dir" ] || return 0
        while IFS= read -r f; do
            if bkl_is_pre_update "$f"; then [ "$kind" = regular ] && continue
            else [ "$kind" = pre ] && continue; fi
            printf '%s\n' "$f"
        done < <(find "$dir" -maxdepth 1 -type f \( -name '*.backup' -o -name '*.rsc' \) \
                    -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
    }
    bkl_latest() { bkl_list_backups "${1:-}" "${2:-all}" | head -n1; }
    bkl_size_h() { stat -c%s "${1:-}" 2>/dev/null | awk '{printf "%.0f KB", $1/1024}'; }
    bkl_mtime() { stat -c %y "${1:-}" 2>/dev/null | cut -d'.' -f1; }
    bkl_label() { if bkl_is_pre_update "${1:-}"; then echo "🛡 перед обновлением"; else echo "📦 плановый"; fi; }
fi

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- Parse arguments ---------------------------------------------------------
DEVICE_NAME=""
TELEGRAM_NOTIFICATION=""
PRE_UPDATE=0
CLEANUP_ONLY=0
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --device)     DEVICE_NAME="${2:-}"; shift 2 ;;
        --all)        DEVICE_NAME="all"; shift ;;
        --telegram)   TELEGRAM_NOTIFICATION="${2:-}"; shift 2 ;;
        --pre-update) PRE_UPDATE=1; shift ;;
        --cleanup)    CLEANUP_ONLY=1; shift ;;
        --list)       LIST_ONLY=1; shift ;;
        -h|--help)
            sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) shift ;;
    esac
done

# --- Load API helpers (proxy-aware) -----------------------------------------
# Раньше искался только $SCRIPT_DIR/tg_api_helpers.sh, а файл лежит в tg/ —
# из-за этого уведомления из MikroGit.sh уходили «мимо» прокси.
if ! declare -f tg_send_message > /dev/null 2>&1; then
    for _h in "$SCRIPT_DIR/tg/tg_api_helpers.sh" "$SCRIPT_DIR/tg_api_helpers.sh"; do
        if [ -f "$_h" ]; then source "$_h"; break; fi
    done
fi

# --- Load bot config (token/chat_id/пути) ------------------------------------
for _c in "$SCRIPT_DIR/tg/tg_bot_config.sh" "$SCRIPT_DIR/tg_bot_config.sh"; do
    if [ -f "$_c" ]; then source "$_c"; break; fi
done

# --- Logging -----------------------------------------------------------------
log()     { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"; }
warning() { echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"; }
info()    { echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"; }

# --- Telegram notification ---------------------------------------------------
send_telegram_notification() {
    local message="$1"
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
    if declare -f tg_send_message > /dev/null 2>&1; then
        tg_send_message "$TELEGRAM_CHAT_ID" "$message"
    else
        local proxy_arg=()
        [ -n "${TELEGRAM_PROXY:-}" ] && proxy_arg=(--proxy "$TELEGRAM_PROXY")
        curl -s "${proxy_arg[@]}" -X POST \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${message}\",\"parse_mode\":\"HTML\"}" \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" > /dev/null 2>&1
    fi
}

# --- Single-instance lock ----------------------------------------------------
# Не даёт плановому (cron/бот) бэкапу пересечься с ручным: второй запуск
# ждёт освобождения (BACKUP_LOCK_WAIT), чтобы не бить один и тот же файл.
BACKUP_LOCK_FILE="$(dirname "$LOG_FILE")/mk_backup.lock"
acquire_lock() {
    command -v flock > /dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$BACKUP_LOCK_FILE")" 2>/dev/null || true
    exec 7> "$BACKUP_LOCK_FILE"
    if ! flock -w "$BACKUP_LOCK_WAIT" 7; then
        error "Другой бэкап не завершился за ${BACKUP_LOCK_WAIT}с (lock: $BACKUP_LOCK_FILE). Выход."
        exit 75
    fi
    echo "$$" >&7
    return 0
}

# --- Setup SSH known hosts ---------------------------------------------------
setup_ssh_known_hosts() {
    mkdir -p ~/.ssh; chmod 700 ~/.ssh
    touch ~/.ssh/known_hosts; chmod 600 ~/.ssh/known_hosts
    if ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
        ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
    fi
    local name ip port user description
    while IFS=':' read -r name ip port user description; do
        [[ $name =~ ^# ]] || [[ -z $name ]] && continue
        grep -q "$ip " ~/.ssh/known_hosts 2>/dev/null && continue
        ssh-keyscan -p "${port:-22}" "$ip" >> ~/.ssh/known_hosts 2>/dev/null
    done < "$CONFIG_FILE"
}

# --- Read devices from config ------------------------------------------------
read_devices() {
    local devices=()
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Configuration file $CONFIG_FILE not found!"
        return 1
    fi
    local name ip port user description
    while IFS=':' read -r name ip port user description; do
        [[ $name =~ ^# ]] || [[ -z $name ]] && continue
        name=$(echo "$name" | tr -d '\r'); ip=$(echo "$ip" | tr -d '\r')
        port=$(echo "$port" | tr -d '\r'); user=$(echo "$user" | tr -d '\r')
        description=$(echo "$description" | tr -d '\r')
        devices+=("$name:$ip:${port:-22}:$user:$description")
    done < "$CONFIG_FILE"
    printf '%s\n' "${devices[@]}"
}

# --- SSH helpers -------------------------------------------------------------
# Глобальные переменные текущего устройства (заполняет backup_device)
DEV_IP=""; DEV_PORT=""; DEV_USER=""

ros_ssh() {
    # $1 — команда RouterOS, $2 — таймаут (сек, необязательно)
    local cmd="$1" tmo="${2:-}"
    local -a opts=(
        -p "$DEV_PORT" -i "$SSH_KEY"
        -o PubkeyAcceptedAlgorithms=+ssh-rsa
        -o HostKeyAlgorithms=+ssh-rsa
        -o ConnectTimeout=15 -o BatchMode=yes
        -o StrictHostKeyChecking=accept-new
        -o ServerAliveInterval=20 -o ServerAliveCountMax=20
        -o LogLevel=ERROR
    )
    if [ -n "$tmo" ] && command -v timeout > /dev/null 2>&1; then
        timeout "$tmo" ssh "${opts[@]}" "$DEV_USER@$DEV_IP" "$cmd" 2>&1
    else
        ssh "${opts[@]}" "$DEV_USER@$DEV_IP" "$cmd" 2>&1
    fi
}

# Скачать файл с роутера: scp → scp -O (legacy) → sftp.
# RouterOS отдаёт файлы только при политике ftp; современный OpenSSH по
# умолчанию использует SFTP-протокол для scp, поэтому нужны варианты.
download_remote_file() {
    # $1 — удалённый путь, $2 — локальный путь
    local remote="$1" local_dst="$2"
    local -a base=(
        -P "$DEV_PORT" -i "$SSH_KEY"
        -o PubkeyAcceptedAlgorithms=+ssh-rsa
        -o HostKeyAlgorithms=+ssh-rsa
        -o ConnectTimeout=15 -o BatchMode=yes
        -o StrictHostKeyChecking=accept-new
        -o LogLevel=ERROR
    )
    rm -f "$local_dst"

    scp "${base[@]}" "$DEV_USER@$DEV_IP:$remote" "$local_dst" > /dev/null 2>&1
    [ -s "$local_dst" ] && return 0

    # legacy-протокол (OpenSSH < 9 ведёт себя так и без -O)
    scp -O "${base[@]}" "$DEV_USER@$DEV_IP:$remote" "$local_dst" > /dev/null 2>&1
    [ -s "$local_dst" ] && return 0

    # sftp (RouterOS поддерживает на 6.43+/7.x)
    if command -v sftp > /dev/null 2>&1; then
        local batch
        batch=$(mktemp)
        printf 'get %s %s\n' "$remote" "$local_dst" > "$batch"
        sftp "${base[@]}" -b "$batch" "$DEV_USER@$DEV_IP" > /dev/null 2>&1
        rm -f "$batch"
        [ -s "$local_dst" ] && return 0
    fi
    rm -f "$local_dst"
    return 1
}

# Почему бэкап не удался (по выводу RouterOS/ssh)
ros_output_is_error() {
    printf '%s' "${1:-}" | grep -qiE 'failure:|bad command|syntax error|unknown command|invalid|not enough permissions|no such item|denied|cannot'
}

# --- Backup a single device --------------------------------------------------
backup_device() {
    local device_name=$1
    DEV_IP=$2; DEV_PORT=$3; DEV_USER=$4
    local description=$5
    local timestamp; timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    local prefix=""
    [ "$PRE_UPDATE" = "1" ] && prefix="pre_update_"
    local base="${device_name}_${prefix}${timestamp}"
    local device_backup_dir="$BACKUP_DIR/$device_name"
    local remote_file="/${base}.backup"
    local local_file="$device_backup_dir/${base}.backup"

    log "Starting backup of $device_name - $description"
    info "Device: $DEV_IP:$DEV_PORT User: $DEV_USER, формат: .backup${prefix:+ (перед обновлением)}"

    mkdir -p "$device_backup_dir"
    chmod 700 "$device_backup_dir" 2>/dev/null || true

    # Проверка связи
    local out
    out=$(ros_ssh "/system identity print" 30)
    if ros_output_is_error "$out" || [ -z "$out" ]; then
        error "Cannot connect to $device_name ($DEV_IP:$DEV_PORT): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
        return 1
    fi
    local identity version
    identity=$(printf '%s\n' "$out" | sed -n 's/^\s*name:\s*//p' | head -1)
    out=$(ros_ssh "/system resource print" 30)
    version=$(printf '%s\n' "$out" | sed -n 's/^\s*version:\s*//p' | head -1)
    info "Identity: ${identity:-?}, Version: ${version:-?}"

    # --- Создаём резервную копию (.backup) на самом роутере ------------------
    info "Creating .backup on $device_name..."
    out=$(ros_ssh "/system backup save name=$base dont-encrypt=yes" "$BACKUP_CMD_TIMEOUT")
    if ros_output_is_error "$out"; then
        # Старые RouterOS (до 6.43) не знают dont-encrypt — повторяем без него
        warning "dont-encrypt не принят роутером ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)) — повтор без него"
        out=$(ros_ssh "/system backup save name=$base" "$BACKUP_CMD_TIMEOUT")
    fi
    if ros_output_is_error "$out"; then
        error "Не удалось создать резервную копию на $device_name: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
        ros_ssh "/file remove [find where name=\"${base}.backup\"]" 30 > /dev/null 2>&1
        return 1
    fi
    log "Резервная копия создана на роутере: ${base}.backup"

    # --- Скачиваем (роутер пишет файл на flash — с повторами) ----------------
    local i size=0 downloaded=0 tmp="$local_file.part"
    rm -f "$tmp"
    for ((i = 1; i <= BACKUP_WAIT_TRIES; i++)); do
        # роутер пишет файл на flash асинхронно — повторяем, пока он не появится
        # и не будет скачан целиком
        if download_remote_file "$remote_file" "$tmp"; then
            size=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
            if [ "$size" -ge "$MIN_BACKUP_BYTES" ]; then
                mv -f "$tmp" "$local_file"
                downloaded=1
                break
            fi
        fi
        rm -f "$tmp"
        [ "$i" -lt "$BACKUP_WAIT_TRIES" ] && sleep "$BACKUP_WAIT_SLEEP"
    done

    # Диагностика: файл на роутере есть, но scp не забрал?
    if [ "$downloaded" != "1" ]; then
        local listing
        listing=$(ros_ssh "/file print where name=\"${base}.backup\"" 30)
        if [ -z "$(printf '%s' "$listing" | grep -F "${base}.backup")" ]; then
            error "$device_name: файл ${base}.backup не появился на роутере (мало места на flash?)"
        else
            error "$device_name: файл ${base}.backup есть на роутере, но scp не смог его скачать."
            warning "Проверьте политику ftp у пользователя $DEV_USER (scp/sftp в RouterOS требует её) и SSH-порт. Пробовали scp, scp -O и sftp."
            warning "Файл оставлен на роутере: ${base}.backup"
            return 1
        fi
        ros_ssh "/file remove [find where name=\"${base}.backup\"]" 30 > /dev/null 2>&1
        return 1
    fi

    chmod 600 "$local_file" 2>/dev/null || true
    log "Backup downloaded: $(basename "$local_file") ($(bkl_size_h "$local_file"), $(bkl_label "$local_file"))"

    # --- Убираем временный файл с роутера (не забиваем flash) ----------------
    out=$(ros_ssh "/file remove [find where name=\"${base}.backup\"]" 30)
    if ros_output_is_error "$out"; then
        warning "Не удалось удалить ${base}.backup с роутера: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
    else
        info "Временный файл на роутере удалён"
    fi

    # --- Информация об устройстве -------------------------------------------
    cat > "$device_backup_dir/device_info.txt" << EOF
Device Name: $device_name
Description: $description
IP Address: $DEV_IP
SSH Port: $DEV_PORT
Username: $DEV_USER
Identity: $identity
Version: $version
Last Backup: $(date)
Last Backup File: $(basename "$local_file")
Format: .backup (RouterOS backup, dont-encrypt)
EOF
    return 0
}

# --- Ротация бэкапов одного устройства --------------------------------------
clean_old_backups() {
    local device_name=$1
    local dir="$BACKUP_DIR/$device_name"
    [ -d "$dir" ] || return 0

    local kind limit label list count excess f
    for kind in regular pre; do
        if [ "$kind" = "pre" ]; then
            limit="$MAX_PRE_UPDATE_BACKUPS"; label="перед обновлением"
        else
            limit="$MAX_BACKUPS_PER_DEVICE"; label="плановых"
        fi
        list=$(bkl_list_backups "$dir" "$kind")
        count=$(printf '%s\n' "$list" | grep -c . || true)
        if [ "$count" -gt "$limit" ]; then
            excess=$((count - limit))
            info "Cleaning $excess old ${label} backups from $device_name (keep $limit)..."
            printf '%s\n' "$list" | tail -n "$excess" | while IFS= read -r f; do
                [ -n "$f" ] && rm -f "$f"
            done
        fi
    done
    # device_info.txt — один на устройство, дубликаты удаляем
    find "$dir" -maxdepth 1 -name 'device_info*.txt' -type f -printf '%T@\t%p\n' 2>/dev/null \
        | sort -rn | cut -f2- | tail -n +2 | while IFS= read -r f; do rm -f "$f"; done
}

# --- Отчёты ------------------------------------------------------------------
clean_old_reports() {
    local count
    mkdir -p "$REPORTS_DIR" 2>/dev/null || true
    count=$(find "$REPORTS_DIR" -maxdepth 1 -name 'backup_report_*.txt' -type f 2>/dev/null | wc -l)
    if [ "$count" -gt "$MAX_REPORTS" ]; then
        info "Cleaning $((count - MAX_REPORTS)) old reports (keep $MAX_REPORTS)..."
        find "$REPORTS_DIR" -maxdepth 1 -name 'backup_report_*.txt' -type f -printf '%T@\t%p\n' 2>/dev/null \
            | sort -rn | cut -f2- | tail -n +$((MAX_REPORTS + 1)) | while IFS= read -r f; do rm -f "$f"; done
    fi
}

generate_report() {
    local success_count=$1 fail_count=$2 total_devices=$3
    # В имя добавляем миллисекунды: два бэкапа в одну секунду (обычный и
    # pre_update) больше не перетирают отчёт друг друга.
    local report_file="$REPORTS_DIR/backup_report_$(date +%Y-%m-%d_%H-%M-%S)_$(date +%3N).txt"
    local mode="плановый"
    [ "$PRE_UPDATE" = "1" ] && mode="перед обновлением"

    mkdir -p "$REPORTS_DIR"
    cat > "$report_file" << EOF
MikroTik Backup Report
======================
Generated: $(date)
Mode: $mode
Total Devices: $total_devices
Successful: $success_count
Failed: $fail_count
Backup format: .backup (/system backup save dont-encrypt=yes)

Device Details:
EOF

    local device name ip port user description dir latest pre
    for device in "${DEVICES_ARRAY[@]}"; do
        IFS=':' read -r name ip port user description <<< "$device"
        dir="$BACKUP_DIR/$name"
        latest=$(bkl_latest "$dir" regular)
        pre=$(bkl_latest "$dir" pre)
        if [ -n "$latest" ]; then
            printf '✓ %s (%s): %s [%s]\n' "$name" "$description" "$(basename "$latest")" "$(bkl_size_h "$latest")" >> "$report_file"
        else
            echo "✗ $name ($description): NO BACKUP" >> "$report_file"
        fi
        [ -n "$pre" ] && printf '  🛡 перед обновлением: %s (%s)\n' "$(basename "$pre")" "$(bkl_size_h "$pre")" >> "$report_file"
    done

    {
        echo ""
        echo "Configuration file: $CONFIG_FILE"
        echo "Backup directory: $BACKUP_DIR"
        echo "Reports directory: $REPORTS_DIR"
        echo "Rotation: $MAX_BACKUPS_PER_DEVICE плановых / $MAX_PRE_UPDATE_BACKUPS перед обновлением"
    } >> "$report_file"

    log "Backup report: $report_file"
}

# --- Обслуживание: логи/отчёты/старые файлы ---------------------------------
run_maintenance() {
    if [ -f "$SCRIPT_DIR/tg/mk_cleanup.sh" ] && ! declare -f mkc_full_cleanup > /dev/null 2>&1; then
        # shellcheck source=tg/mk_cleanup.sh
        source "$SCRIPT_DIR/tg/mk_cleanup.sh"
    fi
    if declare -f mkc_full_cleanup > /dev/null 2>&1; then
        mkc_full_cleanup "$BACKUP_DIR" "$LOG_FILE"
    else
        clean_old_reports
    fi
}

# --- Main --------------------------------------------------------------------
main() {
    if [ "$LIST_ONLY" = "1" ]; then
        read_devices
        exit $?
    fi

    ensure_dirs
    log "===== MikroTik Backup ($([ "$PRE_UPDATE" = 1 ] && echo 'перед обновлением' || echo 'плановый')) ====="
    log "Configuration file: $CONFIG_FILE"
    log "Backup directory:   $BACKUP_DIR"
    log "Reports directory:  $REPORTS_DIR"

    if [ "$CLEANUP_ONLY" = "1" ]; then
        run_maintenance
        log "Обслуживание завершено"
        exit 0
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        error "Configuration file $CONFIG_FILE not found!"
        send_telegram_notification "❌ <b>Backup failed!</b>\nConfig file not found: $CONFIG_FILE"
        exit 1
    fi
    if [ ! -f "$SSH_KEY" ]; then
        error "SSH key $SSH_KEY not found!"
        exit 1
    fi
    chmod 600 "$SSH_KEY" 2>/dev/null || true

    mapfile -t DEVICES_ARRAY < <(read_devices)
    if [ ${#DEVICES_ARRAY[@]} -eq 0 ]; then
        error "No devices found in config"
        send_telegram_notification "❌ <b>Backup failed!</b>\nNo devices configured."
        exit 1
    fi

    if [ -n "$DEVICE_NAME" ] && [ "$DEVICE_NAME" != "all" ]; then
        local filtered=() device name
        for device in "${DEVICES_ARRAY[@]}"; do
            IFS=':' read -r name _ _ _ _ <<< "$device"
            if [ "$name" = "$DEVICE_NAME" ]; then filtered+=("$device"); fi
        done
        if [ ${#filtered[@]} -eq 0 ]; then
            error "Device $DEVICE_NAME not found"
            send_telegram_notification "❌ <b>Backup failed!</b>\nDevice not found: $DEVICE_NAME"
            exit 1
        fi
        DEVICES_ARRAY=("${filtered[@]}")
    fi

    acquire_lock
    setup_ssh_known_hosts

    log "Processing ${#DEVICES_ARRAY[@]} devices"

    if [ -n "$TELEGRAM_NOTIFICATION" ]; then
        local hdr="🔄 <b>Starting backup</b>"
        [ "$PRE_UPDATE" = "1" ] && hdr="🛡 <b>Резервная копия перед обновлением</b>"
        if [ -n "$DEVICE_NAME" ] && [ "$DEVICE_NAME" != "all" ]; then
            send_telegram_notification "$hdr\nDevice: $DEVICE_NAME\nFormat: .backup\nTime: $(date)"
        else
            send_telegram_notification "$hdr\nDevices: ${#DEVICES_ARRAY[@]}\nFormat: .backup\nTime: $(date)"
        fi
    fi

    mkdir -p "$BACKUP_DIR"
    cd "$REPO_DIR" || { error "Cannot cd to $REPO_DIR"; exit 1; }

    local success_count=0 fail_count=0 total_devices=${#DEVICES_ARRAY[@]}
    local device name ip port user description

    for device in "${DEVICES_ARRAY[@]}"; do
        IFS=':' read -r name ip port user description <<< "$device"
        if backup_device "$name" "$ip" "$port" "$user" "$description"; then
            ((success_count++))
            local lst
            lst=$(bkl_latest "$BACKUP_DIR/$name" all)
            if [ -n "$TELEGRAM_NOTIFICATION" ]; then
                send_telegram_notification "✅ <b>Backup OK!</b>\nDevice: <b>$name</b>\nFile: <code>$(basename "${lst:-?}")</code>\nWhere: <code>$BACKUP_DIR/$name/</code>"
            fi
        else
            ((fail_count++))
            [ -n "$TELEGRAM_NOTIFICATION" ] && \
                send_telegram_notification "❌ <b>Backup failed!</b>\nDevice: $name\nCheck logs: <code>$LOG_FILE</code>"
        fi
        echo "----------------------------------------"
    done

    generate_report "$success_count" "$fail_count" "$total_devices"

    log "Cleaning old backups (keeping $MAX_BACKUPS_PER_DEVICE regular / $MAX_PRE_UPDATE_BACKUPS pre-update per device)..."
    for device in "${DEVICES_ARRAY[@]}"; do
        IFS=':' read -r name _ _ _ _ <<< "$device"
        clean_old_backups "$name"
    done

    log "Обслуживание: логи, отчёты, временные файлы..."
    run_maintenance

    log "===== Backup process completed ====="
    log "Summary: $success_count OK, $fail_count FAILED out of $total_devices"

    if [ -n "$TELEGRAM_NOTIFICATION" ]; then
        if [ "$fail_count" -eq 0 ]; then
            send_telegram_notification "✅ <b>All backups OK!</b>\nDevices: $success_count/$total_devices\nFormat: .backup\nTime: $(date)"
        else
            send_telegram_notification "⚠️ <b>Backup completed with errors</b>\nOK: $success_count/$total_devices\nFailed: $fail_count\nTime: $(date)"
        fi
    fi

    [ "$fail_count" -gt 0 ] && exit 1 || exit 0
}

main "$@"

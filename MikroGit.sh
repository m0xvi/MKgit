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
# Итоги последнего запуска — их читает бот, чтобы показать причину сбоя
BACKUP_STATUS_FILE="${BACKUP_STATUS_FILE:-$LOG_DIR/last_backup_status.tsv}"

# Минимальный «правдоподобный» размер .backup (меньше — считаем битым файлом)
MIN_BACKUP_BYTES="${MIN_BACKUP_BYTES:-512}"
# Сколько раз пробовать скачать файл, пока роутер его пишет на flash
BACKUP_WAIT_TRIES="${BACKUP_WAIT_TRIES:-15}"
BACKUP_WAIT_SLEEP="${BACKUP_WAIT_SLEEP:-1}"
# Таймаут команды backup save на роутере, сек
BACKUP_CMD_TIMEOUT="${BACKUP_CMD_TIMEOUT:-120}"
# Сколько ждать освобождения лока (другой бэкап уже идёт), сек
BACKUP_LOCK_WAIT="${BACKUP_LOCK_WAIT:-900}"

# --- Место на flash роутера ---------------------------------------------------
# Минимум свободного места, ниже которого считаем, что бэкап может не влезть
ROUTER_MIN_FREE_BYTES="${ROUTER_MIN_FREE_BYTES:-65536}"
# Файлы бэкапов НА РОУТЕРЕ старше этого числа дней удаляются, когда мало места
ROUTER_CLEANUP_DAYS="${ROUTER_CLEANUP_DAYS:-30}"
# Сколько раз пытаться сохранить бэкап (с уборкой места между попытками)
ROUTER_SAVE_TRIES="${ROUTER_SAVE_TRIES:-3}"
# При агрессивной уборке оставлять на роутере самый свежий наш файл
ROUTER_KEEP_NEWEST="${ROUTER_KEEP_NEWEST:-1}"
# Сколько наших файлов оставлять НА РОУТЕРЕ, если скачать не удалось
# (иначе каждый день на flash остаётся ещё один .backup, а там 1 МБ).
ROUTER_KEEP_REMOTE="${ROUTER_KEEP_REMOTE:-1}"
# Сколько секунд ждать появления файла после /system backup save
ROUTER_FILE_WAIT="${ROUTER_FILE_WAIT:-10}"
# Если .backup создан, но не скачивается из-за политик sensitive/ftp —
# выдать права автоматически через tg/deploy_key.sh (1 = да, 0 = только сказать)
ROUTER_AUTO_FIX_POLICIES="${ROUTER_AUTO_FIX_POLICIES:-1}"
# Сколько секунд отводить на автоматическую выдачу прав (deploy_key.sh)
ROUTER_FIX_TIMEOUT="${ROUTER_FIX_TIMEOUT:-300}"

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

# --- Load bot config (token/chat_id/пути) ------------------------------------
# ВАЖНО: конфиг загружается ДО хелперов — иначе TELEGRAM_PROXY из него
# не попадёт в окружение и ручной запуск получит HTTP 000 (бот при этом шлёт
# нормально, т.к. сам грузит конфиг первым).
for _c in "$SCRIPT_DIR/tg/tg_bot_config.sh" "$SCRIPT_DIR/tg_bot_config.sh"; do
    if [ -f "$_c" ]; then source "$_c"; break; fi
done

# --- Load API helpers (proxy-aware) -----------------------------------------
# Раньше искался только $SCRIPT_DIR/tg_api_helpers.sh, а файл лежит в tg/ —
# из-за этого уведомления из MikroGit.sh уходили «мимо» прокси.
if ! declare -f tg_send_message > /dev/null 2>&1; then
    for _h in "$SCRIPT_DIR/tg/tg_api_helpers.sh" "$SCRIPT_DIR/tg_api_helpers.sh"; do
        if [ -f "$_h" ]; then source "$_h"; break; fi
    done
fi

# Если хелперы уже были загружены вызывающим скриптом (бот), пропишем прокси
# из только что прочитанного конфига повторно.
if declare -f _setup_proxy_env > /dev/null 2>&1; then
    _setup_proxy_env
fi

# --- Logging -----------------------------------------------------------------
# Раньше каждая строка дублировалась в логе: бот запускает скрипт с
# `>> LOG_FILE 2>&1`, и tee писал туда же второй раз. Если stdout уже смотрит
# в тот же файл — печатаем один раз.
_LOG_STDOUT_IS_FILE=0
if [ -n "${LOG_FILE:-}" ] && [ -e /proc/$$/fd/1 ]; then
    if [ "$(readlink -f /proc/$$/fd/1 2>/dev/null)" = "$(readlink -f "$LOG_FILE" 2>/dev/null)" ]; then
        _LOG_STDOUT_IS_FILE=1
    fi
fi
emit_log() {
    if [ "$_LOG_STDOUT_IS_FILE" = "1" ]; then
        printf '%b\n' "$1"
        return
    fi
    if [ ! -d "$(dirname "$LOG_FILE")" ] && ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
        printf '%b\n' "$1"          # каталога логов нет и создать нельзя
        return
    fi
    printf '%b\n' "$1" | tee -a "$LOG_FILE"
}
log()     { emit_log "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error()   { emit_log "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"; }
warning() { emit_log "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"; }
info()    { emit_log "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"; }

# --- Telegram notification ---------------------------------------------------
send_telegram_notification() {
    local message="$1" keyboard="${2:-}"
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
    if [ -n "$keyboard" ] && declare -f tg_send_keyboard > /dev/null 2>&1; then
        tg_send_keyboard "$TELEGRAM_CHAT_ID" "$message" "$keyboard"
    elif declare -f tg_send_message > /dev/null 2>&1; then
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
        bkl_status_record fail "сервер" "предыдущий бэкап не завершился за ${BACKUP_LOCK_WAIT}с — запуск пропущен"
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
DEV_IP=""; DEV_PORT=""; DEV_USER=""; DEV_NAME=""
# Причина последней неудачи — уходит в Telegram вместе с «Backup failed»
BACKUP_ERROR=""
# Локальный файл, скачанный в этом запуске (для отчёта и Telegram)
LAST_BACKUP_FILE=""
# Итоги текущего запуска по устройствам: ok/fail, файл, причина
declare -A RUN_RESULT=() RUN_FILE=() RUN_ERROR=()

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
    # RouterOS отдаёт CRLF: без чистки "\r" попадает в лог и (через printf %b)
    # ломает строки — лог перемешивается.
    if [ -n "$tmo" ] && command -v timeout > /dev/null 2>&1; then
        timeout "$tmo" ssh "${opts[@]}" "$DEV_USER@$DEV_IP" "$cmd" 2>&1 | tr -d '\r'
    else
        ssh "${opts[@]}" "$DEV_USER@$DEV_IP" "$cmd" 2>&1 | tr -d '\r'
    fi
}

# Скачать файл с роутера: scp → scp -O (legacy) → sftp.
# RouterOS отдаёт файлы только при политике ftp; современный OpenSSH по
# умолчанию использует SFTP-протокол для scp, поэтому нужны варианты.
# Последняя ошибка scp/sftp (для сообщения пользователю)
DOWNLOAD_LAST_ERR=""

download_remote_file() {
    # $1 — удалённый путь, $2 — локальный путь
    local remote="$1" local_dst="$2" err=""
    local -a base=(
        -P "$DEV_PORT" -i "$SSH_KEY"
        -o PubkeyAcceptedAlgorithms=+ssh-rsa
        -o HostKeyAlgorithms=+ssh-rsa
        -o ConnectTimeout=15 -o BatchMode=yes
        -o StrictHostKeyChecking=accept-new
        -o LogLevel=ERROR
    )
    rm -f "$local_dst"
    DOWNLOAD_LAST_ERR=""

    err=$(scp "${base[@]}" "$DEV_USER@$DEV_IP:$remote" "$local_dst" 2>&1 > /dev/null)
    [ -s "$local_dst" ] && return 0
    [ -n "$err" ] && DOWNLOAD_LAST_ERR="scp: $(printf '%s' "$err" | tr '\n\r' ' ' | cut -c1-160)"

    # legacy-протокол (OpenSSH < 9 ведёт себя так и без -O)
    err=$(scp -O "${base[@]}" "$DEV_USER@$DEV_IP:$remote" "$local_dst" 2>&1 > /dev/null)
    [ -s "$local_dst" ] && return 0
    [ -n "$err" ] && DOWNLOAD_LAST_ERR="scp -O: $(printf '%s' "$err" | tr '\n\r' ' ' | cut -c1-160)"

    # sftp (RouterOS поддерживает на 6.43+/7.x)
    if command -v sftp > /dev/null 2>&1; then
        local batch
        batch=$(mktemp)
        printf 'get %s %s\n' "$remote" "$local_dst" > "$batch"
        err=$(sftp "${base[@]}" -b "$batch" "$DEV_USER@$DEV_IP" 2>&1 > /dev/null)
        rm -f "$batch"
        [ -s "$local_dst" ] && return 0
        [ -n "$err" ] && DOWNLOAD_LAST_ERR="$DOWNLOAD_LAST_ERR sftp: $(printf '%s' "$err" | tr '\n\r' ' ' | cut -c1-160)"
    fi
    rm -f "$local_dst"
    return 1
}

# Почему бэкап не удался (по выводу RouterOS/ssh)
ros_output_is_error() {
    printf '%s' "${1:-}" | grep -qiE 'failure:|bad command|syntax error|unknown command|invalid|not enough permissions|no such item|denied|cannot|no space|not enough free|disk full'
}

# --- Работа с файлами и местом на роутере -----------------------------------
# Человеко-читаемый размер из байт
human_bytes() {
    local b="${1:-0}"
    case "$b" in ''|*[!0-9]*) echo "?"; return ;; esac
    if [ "$b" -ge 1048576 ]; then echo "$(( b / 1048576 )) MB"
    elif [ "$b" -ge 1024 ]; then echo "$(( b / 1024 )) KB"
    else echo "$b B"; fi
}

# "27.4KiB" / "1.2MiB" / "512" -> байты
ros_size_to_bytes() {
    local v="${1:-}" num unit
    v=$(printf '%s' "$v" | tr -d ' \r\t')
    [ -z "$v" ] && { echo 0; return; }
    num=$(printf '%s' "$v" | sed -E 's/^([0-9]+([.][0-9]+)?).*/\1/')
    unit=$(printf '%s' "$v" | sed -E 's/^[0-9]+([.][0-9]+)?//' | tr '[:upper:]' '[:lower:]')
    awk -v n="${num:-0}" -v u="$unit" 'BEGIN {
        m = 1
        if (u ~ /^k/) m = 1024
        else if (u ~ /^m/) m = 1048576
        else if (u ~ /^g/) m = 1073741824
        printf "%.0f\n", n * m
    }'
}

# Свободно на flash, байт (пусто, если прочитать не удалось)
ros_free_bytes() {
    local out val
    out=$(ros_ssh "/system resource print" 30)
    val=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*free-hdd-space:[[:space:]]*//p' | head -1)
    [ -z "$val" ] && { printf ''; return; }
    ros_size_to_bytes "$val"
}

# Всего на flash, байт
ros_total_bytes() {
    local out val
    out=$(ros_ssh "/system resource print" 30)
    val=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*total-hdd-space:[[:space:]]*//p' | head -1)
    [ -z "$val" ] && { printf ''; return; }
    ros_size_to_bytes "$val"
}

# Список файлов роутера: NAME<TAB>SIZE_BYTES
ros_file_list_tsv() {
    local out
    out=$(ros_ssh ':foreach f in=[/file find] do={:put ([/file get $f name] . "|" . [/file get $f size])}' 60)
    out=$(printf '%s\n' "$out" | tr -d '\r')
    if printf '%s' "$out" | grep -q '|'; then
        printf '%s\n' "$out" | awk -F'|' 'NF>=2 && $1!="" {print $1"\t"$2}'
        return 0
    fi
    # Fallback: обычный /file print
    out=$(ros_ssh "/file print" 60)
    printf '%s\n' "$out" | tr -d '\r' | awk '
        /^[[:space:]]*[0-9]+[[:space:]]/ {
            name = $2
            size = "0"
            for (i = 3; i <= NF; i++) {
                if ($i ~ /^[0-9.]+(B|KiB|MiB|GiB)$/) { size = $i; break }
            }
            print name "\t" size
        }'
}

# Файл с таким именем есть на роутере?
ros_file_exists() {
    local want="$1" list
    list=$(ros_file_list_tsv)
    if [ -n "$list" ]; then
        printf '%s\n' "$list" | awk -F'\t' -v w="$want" '$1 == w {found=1} END {exit !found}'
        return
    fi
    # Список не получили (или на роутере нет файлов) — спрашиваем точечно
    ros_ssh "/file print where name=\"$want\"" 30 | grep -qF "$want"
}

# Грубая проверка: имя встречается в полном /file print
# (на случай, если :foreach и «where name=» на этом RouterOS не сработали)
ros_file_exists_loose() {
    local want="$1"
    [ -n "$want" ] || return 1
    ros_ssh "/file print" 30 | grep -qF "$want"
}

# Что именно случилось с доступом к роутеру — по тексту ошибки ssh
# (+ ping как подсказка). Печатает короткое объяснение для лога/Telegram.
net_diag() {
    local ip="$1" port="$2" err="${3:-}" ping_ok=0
    command -v ping > /dev/null 2>&1 && ping -c1 -W2 "$ip" > /dev/null 2>&1 && ping_ok=1
    case "$err" in
        *"Connection timed out"*|*"Operation timed out"*)
            if [ "$ping_ok" = "1" ]; then
                echo "хост отвечает на ping, но порт $port не открывается — фильтр/firewall или ssh на другом порту"
            else
                echo "роутер $ip не отвечает вообще (ни ping, ни порт $port) — питание, канал/маршрут или адрес сменился"
            fi ;;
        *"Connection refused"*)
            echo "хост доступен, но порт $port закрыт — ssh выключен или порт в devices.conf не тот" ;;
        *"No route to host"*)
            echo "нет маршрута до $ip — другая подсеть/VLAN или адрес сменился" ;;
        *"Connection reset"*|*"Connection closed"*|*"kex_exchange"*)
            echo "на порту $port кто-то есть, но это не SSH RouterOS — проверьте порт в devices.conf" ;;
        *"Permission denied"*|*"publickey"*)
            echo "ключ не принят — посмотрите /user ssh-keys print на роутере" ;;
        *)
            if [ "$ping_ok" = "1" ]; then
                echo "хост $ip отвечает на ping, но SSH-сессия не поднялась"
            else
                echo "нет связи с $ip:$port — питание, канал или адрес"
            fi ;;
    esac
}

# Ждать появления файла (роутер пишет на flash не мгновенно)
ros_wait_file() {
    local want="$1" secs="${2:-$ROUTER_FILE_WAIT}" i
    for ((i = 0; i <= secs; i++)); do
        ros_file_exists "$want" && return 0
        [ "$i" -lt "$secs" ] && sleep 1
    done
    return 1
}

# Удалить файл на роутере
ros_remove_file() {
    local name="$1"
    [ -n "$name" ] || return 1
    local out
    out=$(ros_ssh "/file remove [find name=\"$name\"]" 30)
    if ros_output_is_error "$out"; then
        warning "не удалось удалить $name с роутера: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
        return 1
    fi
    return 0
}

# Наш ли это файл бэкапа (в имени всегда есть дата: ..._YYYY-MM-DD_HH-MM-SS.backup|.rsc)
ros_is_our_backup_name() {
    printf '%s' "${1:-}" | grep -Eq '_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.(backup|rsc)$'
}

# Политики SSH-пользователя, короткой строкой: "<группа>|ftp=1 sensitive=0 read=1"
# (пусто — узнать не удалось; на старых ROS команда может быть недоступна)
ros_user_policy_flags() {
    local user="${1:-$DEV_USER}" out
    [ -n "$user" ] || return 1
    out=$(ros_ssh ":local u [/user find where name=\"$user\"]; :local g [/user get \$u group]; :local p [/user group get [find where name=\$g] policy]; :local f 0; :local s 0; :local r 0; :foreach x in=\$p do={:if (\$x=\"ftp\") do={:set f 1}; :if (\$x=\"sensitive\") do={:set s 1}; :if (\$x=\"read\") do={:set r 1}}; :put (\$g . \"|ftp=\$f sensitive=\$s read=\$r\")" 30)
    out=$(printf '%s\n' "$out" | tr -d '\r' | grep -E '\|ftp=[01] sensitive=[01] read=[01]' | tail -1)
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# Текущий список политик группы пользователя ("ssh,read,write,..."), пусто — не узнать
ros_user_policy_list() {
    local user="${1:-$DEV_USER}" out
    [ -n "$user" ] || return 1
    out=$(ros_ssh ":local u [/user find where name=\"$user\"]; :local g [/user get \$u group]; :put [/user group get [find where name=\$g] policy]" 30)
    # RouterOS 6 печатает список через ";" и с переносами, запреты — с "!"
    out=$(printf '%s' "$out" | tr -d '\r\n\t ' | tr ';' ',' | sed -E 's/^,+//; s/,+$//; s/,,+/,/g')
    case "$out" in ''|*[!a-z,!-]*) return 1 ;; esac
    printf '%s' "$out"
}

# Время создания из имени файла (epoch); 1 — если даты в имени нет
ros_name_epoch() {
    local n base
    n="$(basename "${1:-}")"
    base=$(printf '%s' "$n" | sed -nE 's/.*_([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})\.(backup|rsc)$/\1 \2:\3:\4/p')
    [ -z "$base" ] && return 1
    date -d "$base" +%s 2>/dev/null || return 1
}

# Освободить flash роутера: удалить НАШИ старые бэкапы/экспорты.
#   $1 — возраст в днях (30: только старше; 0: любые, от самых старых)
#   $2 — сколько байт надо освободить (0: удалить все подходящие)
#   $3 — максимум файлов к удалению (0: без ограничения)
# Ставит ROS_CLEANED_BYTES; rc=0, если что-то удалили.
ROS_CLEANED_BYTES=0
ros_cleanup_old_backups() {
    local days="${1:-$ROUTER_CLEANUP_DAYS}" need="${2:-0}" maxdel="${3:-0}"
    local now list name size epoch age_days total=0 n=0
    local -a cand=()
    ROS_CLEANED_BYTES=0
    now=$(date +%s)
    list=$(ros_file_list_tsv) || return 1
    [ -n "$list" ] || return 1

    while IFS=$'\t' read -r name size; do
        [ -n "$name" ] || continue
        ros_is_our_backup_name "$name" || continue
        epoch=$(ros_name_epoch "$name") || epoch=""
        if [ -n "$epoch" ]; then
            age_days=$(( (now - epoch) / 86400 ))
            [ "$days" -gt 0 ] && [ "$age_days" -lt "$days" ] && continue
            cand+=("$epoch|$name|$(ros_size_to_bytes "$size")")
        else
            # без даты в имени удаляем только при агрессивной уборке (days=0)
            [ "$days" -eq 0 ] && cand+=("0|$name|$(ros_size_to_bytes "$size")")
        fi
    done <<< "$list"

    [ ${#cand[@]} -eq 0 ] && return 1

    # самые старые первыми
    local -a sorted=()
    while IFS= read -r line; do sorted+=("$line"); done < <(printf '%s\n' "${cand[@]}" | sort -t'|' -k1,1n)

    # Не трогаем самый свежий наш файл (страховка на случай отката),
    # но если его удаление — единственный способ освободить место, удалим и его.
    # В режиме «старше N дней» (days>0) удаляем всё подходящее: это старьё.
    # Страховка-«последний файл» нужна только при агрессивной уборке (days=0).
    local held=""
    if [ "$days" -eq 0 ] && [ "${ROUTER_KEEP_NEWEST:-1}" = "1" ] && [ ${#sorted[@]} -gt 1 ]; then
        held="${sorted[$((${#sorted[@]} - 1))]}"
        sorted=("${sorted[@]:0:$((${#sorted[@]} - 1))}")
    fi

    local entry
    for entry in "${sorted[@]}"; do
        name="${entry#*|}"; name="${name%|*}"
        size="${entry##*|}"
        [ -n "$name" ] || continue
        if ros_remove_file "$name"; then
            total=$((total + size)); n=$((n + 1))
            info "  удалён с роутера: $name ($(human_bytes "$size"))"
        fi
        [ "$maxdel" -gt 0 ] && [ "$n" -ge "$maxdel" ] && break
        [ "$need" -gt 0 ] && [ "$total" -ge "$need" ] && break
    done

    # всё ещё мало места? тогда жертвуем и самым свежим нашим файлом
    if [ -n "$held" ] && { [ "$need" -eq 0 ] || [ "$total" -lt "$need" ]; }; then
        name="${held#*|}"; name="${name%|*}"; size="${held##*|}"
        if [ -n "$name" ] && ros_remove_file "$name"; then
            total=$((total + size)); n=$((n + 1))
            info "  удалён с роутера: $name ($(human_bytes "$size")) — единственный способ освободить место"
        fi
    fi

    # RouterOS обновляет список файлов не мгновенно — даём ему секунду
    [ "$n" -gt 0 ] && sleep 1
    ROS_CLEANED_BYTES=$total
    if [ "$n" -gt 0 ]; then
        log "Очистка роутера: удалено файлов $n, освобождено $(human_bytes "$total")"
        return 0
    fi
    return 1
}

# Оставить на роутере только N самых свежих наших файлов ЭТОГО устройства.
# Вызывается, когда .backup скачать не удалось: файл остаётся на роутере, но
# копиться им там нельзя (на многих AP всего 1 МБ свободного flash).
# $1 — имя устройства; $2 — сколько оставить (по умолчанию ROUTER_KEEP_REMOTE)
ros_trim_remote_backups() {
    local dev="$1" keep="${2:-${ROUTER_KEEP_REMOTE:-1}}"
    local list name epoch n=0
    local -a arr=()
    [ -n "$dev" ] || return 1
    list=$(ros_file_list_tsv) || return 1
    [ -n "$list" ] || return 1
    while IFS=$'\t' read -r name _size; do
        [ -n "$name" ] || continue
        case "$name" in
            "${dev}"_*.backup|"pre_update_${dev}"_*.backup) ;;
            *) continue ;;
        esac
        ros_is_our_backup_name "$name" || continue
        epoch=$(ros_name_epoch "$name") || epoch=0
        arr+=("$epoch|$name")
    done <<< "$list"
    [ ${#arr[@]} -gt "$keep" ] || return 0
    # свежие первыми, лишние — в удаление
    while IFS= read -r line; do
        n=$((n + 1))
        [ "$n" -le "$keep" ] && continue
        name="${line#*|}"
        if ros_remove_file "$name"; then
            info "  удалён старый файл с роутера: $name"
        fi
    done < <(printf '%s\n' "${arr[@]}" | sort -t'|' -k1,1nr)
    return 0
}

# Убедиться, что на flash достаточно места (при нехватке — чистим старое)
# $1 — сколько байт нужно
ros_ensure_space() {
    local need="${1:-$ROUTER_MIN_FREE_BYTES}" free
    free=$(ros_free_bytes)
    [ -z "$free" ] && return 0     # не смогли прочитать — не мешаем работать
    info "Свободно на flash: $(human_bytes "$free") (нужно ~$(human_bytes "$need"))"
    if [ "$free" -ge "$need" ]; then
        return 0
    fi
    warning "$DEV_NAME: мало места ($(human_bytes "$free") < $(human_bytes "$need")) — удаляю старые бэкапы с роутера (старше $ROUTER_CLEANUP_DAYS дней)"
    ros_cleanup_old_backups "$ROUTER_CLEANUP_DAYS" $((need - free)) 0 || true
    sleep 1
    free=$(ros_free_bytes)
    if [ -n "$free" ] && [ "$free" -lt "$need" ]; then
        warning "$DEV_NAME: после удаления старше $ROUTER_CLEANUP_DAYS дней всё ещё мало ($(human_bytes "$free")) — удаляю самые старые из наших бэкапов"
        ros_cleanup_old_backups 0 $((need - free)) 0 || true
        free=$(ros_free_bytes)
        [ -n "$free" ] && info "Свободно после очистки: $(human_bytes "$free")"
    fi
    return 0
}

# Выдать недостающие политики БЕЗ администратора: ключом самого пользователя.
# Работает, когда группа пользователя уже содержит policy+write — RouterOS
# разрешает такому пользователю править собственную группу. Группа не
# меняется, добавляются только недостающие политики.
# rc: 0 — права в порядке (или только что добавлены); 1 — так нельзя.
router_self_grant_policies() {
    [ "${ROUTER_SELF_GRANT:-1}" = "1" ] || return 1
    [ -f "$SCRIPT_DIR/tg/fix_rights_self.sh" ] || return 1
    local out rc=0 policy
    # reboot не трогаем: для .backup он не нужен, а где-то осознанно запрещён
    policy="${ROUTER_SELF_GRANT_POLICY:-ssh,read,write,test,policy,ftp,sensitive}"
    case ",$policy," in *,sensitive,*) ;; *) policy="$policy,sensitive" ;; esac
    case ",$policy," in *,ftp,*) ;; *) policy="$policy,ftp" ;; esac

    out=$(CONFIG_FILE="$CONFIG_FILE" SSH_KEY="$SSH_KEY" \
          SSH_TIMEOUT="${SSH_TIMEOUT:-10}" TARGET_POLICY="$policy" \
          bash "$SCRIPT_DIR/tg/fix_rights_self.sh" "$DEV_NAME" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$out" | grep -q 'политики добавлены' && \
            info "$DEV_NAME: политики добавлены ключом пользователя (без администратора)"
        return 0
    fi
    log "$DEV_NAME: права ключом пользователя не выдались (rc=$rc): $(printf '%s' "$out" | grep -E '^\[ERR\]' | head -1)"
    SELF_GRANT_WHY="$(printf '%s\n' "$out" | grep -E '^\[ERR\]' | head -1 | sed 's/^\[ERR\] //')"
    return 1
}

# Выдать недостающие политики через существующий деплой (tg/deploy_key.sh).
# Правит ТУ группу, в которой пользователь уже состоит; в mikrogit не переводит.
# rc: 0 — политики в порядке (ничего не делали)
#     2 — права выданы (деплой отработал)
#     1 — выдать не удалось / применить нельзя (нет данных, пароля и т. п.)
router_fix_policies() {
    [ "${ROUTER_AUTO_FIX_POLICIES:-1}" = "1" ] || return 1
    [ -f "$SCRIPT_DIR/tg/deploy_key.sh" ] || return 1

    local flags missing="" cur_group="" fixtarget
    SELF_GRANT_WHY=""
    flags=$(ros_user_policy_flags "$DEV_USER" 2>/dev/null)
    [ -n "$flags" ] || return 1
    cur_group="${flags%%|*}"
    case "$flags" in *"ftp=0"*)       missing="$missing ftp" ;; esac
    case "$flags" in *"sensitive=0"*) missing="$missing sensitive" ;; esac
    case "$flags" in *"read=0"*)      missing="$missing read" ;; esac
    [ -n "$missing" ] || return 0       # всё на месте

    # --- шаг 1: своим ключом, без администратора ---
    if router_self_grant_policies; then
        return 2
    fi

    # --- шаг 2: через деплой (нужен пароль администратора) ---
    if [ -z "${DEPLOY_TL_PASS:-}" ] && [ ! -f "$SCRIPT_DIR/tg/deploy.conf" ]; then
        warning "$DEV_NAME: без администратора права выдать нельзя${SELF_GRANT_WHY:+ ($SELF_GRANT_WHY)}"
        warning "$DEV_NAME: укажите пароль администратора: DEPLOY_TL_USER=admin и DEPLOY_TL_PASS в tg/tg_bot_config.sh (или TL_USER/TL_PASS в tg/deploy.conf)"
        return 1
    fi
    if [ -n "${DEPLOY_TL_USER:-}" ] && [ "${DEPLOY_TL_USER}" = "$DEV_USER" ]; then
        warning "$DEV_NAME: DEPLOY_TL_USER совпадает с пользователем бэкапа ($DEV_USER) — он не может выдать права сам себе; укажите администратора"
        return 1
    fi

    # правим группу пользователя, а не переводим его в другую
    fixtarget="${cur_group:-${DEPLOY_TARGET_GROUP-mikrogit}}"
    if [ -z "$fixtarget" ]; then
        warning "$DEV_NAME: автовыдача прав отключена (DEPLOY_TARGET_GROUP пуст)"
        return 1
    fi
    local fix_policy="${DEPLOY_TARGET_POLICY:-ssh,read,write,test,reboot,policy,ftp,sensitive}"
    case ",$fix_policy," in *,sensitive,*) ;; *) fix_policy="$fix_policy,sensitive" ;; esac
    case ",$fix_policy," in *,ftp,*) ;; *) fix_policy="$fix_policy,ftp" ;; esac

    warning "$DEV_NAME: не хватает политик:$missing — выдаю права автоматически (tg/deploy_key.sh $DEV_NAME)"
    local -a fixenv=(
        DEVICES_CONF="$CONFIG_FILE"
        TARGET_USER=""
        TARGET_GROUP="$fixtarget"
        TARGET_POLICY="$fix_policy"
        KEY_FILE="${DEPLOY_KEY_FILE:-${SSH_KEY}.pub}"
        KEY_PRIV="${DEPLOY_KEY_PRIV:-$SSH_KEY}"
        SSH_PROBE=1
        SSH_VERIFY=1
    )
    # TL_USER/TL_PASS передаём, только если заданы в конфиге бота, — иначе
    # deploy_key.sh возьмёт их из своего tg/deploy.conf
    [ -n "${DEPLOY_TL_USER:-}" ] && fixenv+=(TL_USER="$DEPLOY_TL_USER")
    [ -n "${DEPLOY_TL_PASS:-}" ] && fixenv+=(TL_PASS="$DEPLOY_TL_PASS")

    local drc=0
    if command -v timeout > /dev/null 2>&1; then
        env "${fixenv[@]}" timeout "$ROUTER_FIX_TIMEOUT" \
            bash "$SCRIPT_DIR/tg/deploy_key.sh" "$DEV_NAME" >> "$LOG_FILE" 2>&1 || drc=$?
    else
        env "${fixenv[@]}" \
            bash "$SCRIPT_DIR/tg/deploy_key.sh" "$DEV_NAME" >> "$LOG_FILE" 2>&1 || drc=$?
    fi
    if [ "$drc" -eq 0 ]; then
        info "$DEV_NAME: права обновлены (группа ${fixtarget})"
        return 2
    fi
    warning "$DEV_NAME: автоматически выдать права не удалось (rc=$drc, подробности — $LOG_FILE)"
    warning "$DEV_NAME: чаще всего нужен администратор: DEPLOY_TL_USER=admin и DEPLOY_TL_PASS в tg/tg_bot_config.sh (или TL_USER/TL_PASS в tg/deploy.conf)"
    warning "$DEV_NAME: вручную: bash tg/mk_deploy.sh $DEV_NAME"
    return 1
}

# --- Backup a single device --------------------------------------------------
backup_device() {
    local device_name=$1
    DEV_IP=$2; DEV_PORT=$3; DEV_USER=$4
    DEV_NAME=$device_name
    BACKUP_ERROR=""
    LAST_BACKUP_FILE=""
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
        local why_net
        why_net="$(net_diag "$DEV_IP" "$DEV_PORT" "$out")"
        BACKUP_ERROR="нет SSH-доступа к $DEV_IP:$DEV_PORT: $(printf '%s' "$out" | tail -1 | tr -d '\r' | cut -c1-120) [$why_net]"
        error "Cannot connect to $device_name ($DEV_IP:$DEV_PORT): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
        return 1
    fi
    local identity version
    identity=$(printf '%s\n' "$out" | sed -n 's/^\s*name:\s*//p' | head -1)
    out=$(ros_ssh "/system resource print" 30)
    version=$(printf '%s\n' "$out" | sed -n 's/^\s*version:\s*//p' | head -1)
    info "Identity: ${identity:-?}, Version: ${version:-?}"

    # --- Проверяем место на flash и при нехватке чистим старое ----------------
    local need_bytes=$ROUTER_MIN_FREE_BYTES prev_size=0 prev
    prev=$(bkl_latest "$device_backup_dir" regular 2>/dev/null | head -1)
    [ -n "$prev" ] && [ -f "$prev" ] && prev_size=$(stat -c%s "$prev" 2>/dev/null || echo 0)
    if [ "$prev_size" -gt 0 ]; then
        need_bytes=$(( prev_size * 2 + 32768 ))
    elif [ "$ROUTER_MIN_FREE_BYTES" -lt 262144 ]; then
        need_bytes=262144        # первый бэкап: ~170-200 KB + запас
    fi
    ros_ensure_space "$need_bytes"

    # --- Создаём резервную копию (.backup) с повторами -----------------------
    # На AP с маленьким flash бэкап может не создаться молча (нет места,
    # остались файлы от прошлых запусков). Тогда чистим старое и пробуем снова.
    local attempt out save_err="" saved=0
    for ((attempt = 1; attempt <= ROUTER_SAVE_TRIES; attempt++)); do
        info "Creating .backup on $device_name (попытка $attempt/$ROUTER_SAVE_TRIES)..."
        out=$(ros_ssh "/system backup save name=$base dont-encrypt=yes" "$BACKUP_CMD_TIMEOUT")
        if ros_output_is_error "$out" && printf '%s' "$out" | grep -qiE 'dont-encrypt|bad command|syntax error|unknown'; then
            # Старые RouterOS (до 6.43) не знают dont-encrypt — повторяем без него
            warning "dont-encrypt не принят роутером ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)) — повтор без него"
            out=$(ros_ssh "/system backup save name=$base" "$BACKUP_CMD_TIMEOUT")
        fi
        save_err="$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"

        if ros_wait_file "${base}.backup" "$ROUTER_FILE_WAIT"; then
            saved=1
            break
        fi
        # список файлов мог не прочитаться — проверяем по полному /file print
        if ros_file_exists_loose "${base}.backup"; then
            saved=1
            break
        fi

        # файла нет — разбираемся почему и освобождаем место
        ros_remove_file "${base}.backup" > /dev/null 2>&1   # недописанный огрызок
        local free_now; free_now=$(ros_free_bytes)
        warning "$DEV_NAME: файл ${base}.backup не появился${save_err:+ (ответ роутера: $save_err)}; свободно $(human_bytes "${free_now:-?}")"
        [ "$attempt" -lt "$ROUTER_SAVE_TRIES" ] || break

        local before="${free_now:-0}" after
        if ! ros_cleanup_old_backups "$ROUTER_CLEANUP_DAYS" 0 0; then
            warning "$DEV_NAME: наших бэкапов старше $ROUTER_CLEANUP_DAYS дней нет — удаляю самые старые из наших"
            ros_cleanup_old_backups 0 "$need_bytes" 0 || true
        fi
        after=$(ros_free_bytes); after="${after:-0}"
        if [ "$after" -le "$before" ] && [ "${ROS_CLEANED_BYTES:-0}" -eq 0 ]; then
            # чистить нечего: flash занят чем-то посторонним
            warning "$DEV_NAME: на роутере нечего удалять — старых файлов наших бэкапов нет."
            local tops
            tops=$(ros_file_list_tsv | awk -F'\t' '{printf "%s\t%s\n", $2, $1}' | sort -rn | head -5 | \
                   awk -F'\t' '{ sz=$1+0
                                 if (sz >= 1048576) h=sprintf("%.1f MB", sz/1048576)
                                 else if (sz >= 1024) h=sprintf("%.0f KB", sz/1024)
                                 else h=sz" B"
                                 printf "%s%s (%s)", (NR>1?", ":""), $2, h }')
            [ -n "$tops" ] && warning "$DEV_NAME: самые большие файлы на flash: $tops"
            warning "$DEV_NAME: освободите место вручную (/file print; /file remove [find name=...]) или подключите USB/увеличьте flash."
            break
        fi
        info "Свободно после очистки: $(human_bytes "$after")"
    done

    if [ "$saved" != "1" ] && ros_file_exists_loose "${base}.backup"; then
        saved=1      # файл всё-таки есть, просто список файлов не читался
    fi
    if [ "$saved" != "1" ]; then
        local free_now total
        free_now=$(ros_free_bytes); total=$(ros_total_bytes)
        BACKUP_ERROR="на роутере не создаётся ${base}.backup (свободно $(human_bytes "${free_now:-?}") из $(human_bytes "${total:-?}"))${save_err:+; ответ: $save_err}"
        error "$DEV_NAME: не удалось создать резервную копию: $BACKUP_ERROR"
        error "Что проверить: /system resource print (free-hdd-space), /file print; удалите лишние файлы на flash."
        ros_remove_file "${base}.backup" > /dev/null 2>&1
        return 1
    fi
    LAST_BACKUP_FILE="$local_file"
    log "Резервная копия создана на роутере: ${base}.backup"

    # Права проверяем ДО скачивания: без sensitive/ftp scp всё равно не заберёт
    # .backup, а 15 кругов повторов только мучают роутер. Сразу выдаём права.
    # 0 = права на месте, 2 = выданы сейчас, 1 = выдать не удалось.
    local fixrc=0
    router_fix_policies || fixrc=$?

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
    # Только что выдали политики — RouterOS применяет их к НОВОМУ входу, но на
    # всякий случай даём ему пару секунд и пробуем ещё раз (без долгих циклов).
    if [ "$downloaded" != "1" ] && [ "$fixrc" = "2" ] && ros_file_exists "${base}.backup"; then
        sleep 5
        rm -f "$tmp"
        if download_remote_file "$remote_file" "$tmp"; then
            size=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
            if [ "$size" -ge "$MIN_BACKUP_BYTES" ]; then
                mv -f "$tmp" "$local_file"; downloaded=1
            else
                rm -f "$tmp"
            fi
        fi
    fi
    if [ "$downloaded" = "1" ]; then
        if [ "$fixrc" = "2" ]; then
            info "Скачано после выдачи прав: $(basename "$local_file") ($(bkl_size_h "$local_file"))"
        else
            info "Скачано: $(basename "$local_file") ($(bkl_size_h "$local_file"))"
        fi
    fi

    # Диагностика: файл на роутере есть, но scp не забрал?
    if [ "$downloaded" != "1" ]; then
        if ros_file_exists "${base}.backup"; then
            local rsize flags grp="" missing=""
            rsize=$(ros_file_list_tsv | awk -F'\t' -v w="${base}.backup" '$1==w{print $2; exit}')
            flags=$(ros_user_policy_flags "$DEV_USER" 2>/dev/null)
            if [ -n "$flags" ]; then
                grp="${flags%%|*}"
                case "$flags" in *"ftp=0"*)       missing="$missing ftp" ;; esac
                case "$flags" in *"sensitive=0"*) missing="$missing sensitive" ;; esac
                case "$flags" in *"read=0"*)      missing="$missing read" ;; esac
            fi
            if [ -n "$missing" ]; then
                BACKUP_ERROR="файл ${base}.backup есть на роутере ($(human_bytes "$(ros_size_to_bytes "${rsize:-0}")")), но scp/sftp не может его забрать: у пользователя $DEV_USER нет политик:$missing${grp:+ (группа $grp)}"
                case "${SELF_GRANT_WHY:-}" in
                    *"not enough permissions"*|*"permission"*|*"denied"*)
                        BACKUP_ERROR="$BACKUP_ERROR; в группе нет политик policy/write — сам себе выдать нельзя, нужен администратор" ;;
                esac
                error "$device_name: $BACKUP_ERROR"
                warning "RouterOS не отдаёт .backup по scp/ftp без политик sensitive и ftp (группа ${grp:-?})."
                warning "Исправить автоматически: bash tg/fix_rights_self.sh $device_name  (ключом пользователя)"
                warning "                     или: bash tg/mk_deploy.sh $device_name  (через администратора)"
                local plist fixcmd
                plist=$(ros_user_policy_list "$DEV_USER" 2>/dev/null || true)
                if [ -n "$plist" ] && [ -n "$grp" ]; then
                    case ",$plist," in *,sensitive,*) ;; *) plist="$plist,sensitive" ;; esac
                    case ",$plist," in *,ftp,*) ;; *) plist="$plist,ftp" ;; esac
                    fixcmd="/user group set [find name=$grp] policy=$plist"
                    warning "Крайний вариант (на роутере, от администратора): $fixcmd"
                    info "Пользователь $DEV_USER должен переподключиться (выход/вход по SSH) после смены политик."
                fi
            else
                BACKUP_ERROR="файл ${base}.backup есть на роутере ($(human_bytes "$(ros_size_to_bytes "${rsize:-0}")")), но scp/sftp его не скачал${DOWNLOAD_LAST_ERR:+: $DOWNLOAD_LAST_ERR}"
                error "$device_name: $BACKUP_ERROR"
                warning "Пробовали scp, scp -O и sftp. Проверьте политику ftp у $DEV_USER, службу ftp на роутере и SSH-порт."
            fi
            warning "Файл оставлен на роутере: ${base}.backup"
            # flash на AP маленькая (1 МБ): не даём копиться нескачанным файлам
            ros_trim_remote_backups "$device_name" 2>/dev/null || true
            return 1
        fi
        local free_now
        free_now=$(ros_free_bytes)
        BACKUP_ERROR="файл ${base}.backup не появился на роутере (свободно $(human_bytes "${free_now:-?}"))"
        error "$device_name: $BACKUP_ERROR"
        ros_remove_file "${base}.backup" > /dev/null 2>&1
        return 1
    fi

    chmod 600 "$local_file" 2>/dev/null || true
    log "Backup downloaded: $(basename "$local_file") ($(bkl_size_h "$local_file"), $(bkl_label "$local_file"))"

    # --- Убираем временный файл с роутера (не забиваем flash) ----------------
    if ros_remove_file "${base}.backup"; then
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

    local device name ip port user description dir latest pre res
    for device in "${DEVICES_ARRAY[@]}"; do
        IFS=':' read -r name ip port user description <<< "$device"
        dir="$BACKUP_DIR/$name"
        latest=$(bkl_latest "$dir" regular)
        pre=$(bkl_latest "$dir" pre)
        res="${RUN_RESULT[$name]:-}"
        if [ "$res" = "fail" ]; then
            # в этом запуске копию сделать не удалось — не выдаём старую за свежую
            printf '✗ %s (%s): FAILED%s\n' "$name" "$description" "${RUN_ERROR[$name]:+ — ${RUN_ERROR[$name]}}" >> "$report_file"
        elif [ "$res" = "ok" ] && [ -n "${RUN_FILE[$name]:-}" ]; then
            printf '✓ %s (%s): %s [%s]\n' "$name" "$description" "$(basename "${RUN_FILE[$name]}")" "$(bkl_size_h "${RUN_FILE[$name]}")" >> "$report_file"
        elif [ -n "$latest" ]; then
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
    bkl_status_reset
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
        bkl_status_record fail "сервер" "не найден $CONFIG_FILE"
        send_telegram_notification "❌ <b>Backup failed!</b>\nConfig file not found: $CONFIG_FILE"
        exit 1
    fi
    if [ ! -f "$SSH_KEY" ]; then
        error "SSH key $SSH_KEY not found!"
        bkl_status_record fail "сервер" "не найден SSH-ключ $SSH_KEY (ssh-keygen -t rsa -f $SSH_KEY)"
        exit 1
    fi
    chmod 600 "$SSH_KEY" 2>/dev/null || true

    mapfile -t DEVICES_ARRAY < <(read_devices)
    if [ ${#DEVICES_ARRAY[@]} -eq 0 ]; then
        error "No devices found in config"
        bkl_status_record fail "сервер" "в $CONFIG_FILE нет устройств"
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
            bkl_status_record fail "$DEVICE_NAME" "устройства нет в $CONFIG_FILE"
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
    RUN_RESULT=(); RUN_FILE=(); RUN_ERROR=()   # см. declare -A выше

    for device in "${DEVICES_ARRAY[@]}"; do
        IFS=':' read -r name ip port user description <<< "$device"
        if backup_device "$name" "$ip" "$port" "$user" "$description"; then
            ((success_count++))
            RUN_RESULT[$name]="ok"
            RUN_FILE[$name]="$LAST_BACKUP_FILE"
            bkl_status_record ok "$name" ""
            if [ -n "$TELEGRAM_NOTIFICATION" ]; then
                send_telegram_notification "✅ <b>Backup OK!</b>\nDevice: <b>$name</b>\nFile: <code>$(basename "${LAST_BACKUP_FILE:-?}")</code>\nWhere: <code>$BACKUP_DIR/$name/</code>"
            fi
        else
            ((fail_count++))
            RUN_RESULT[$name]="fail"
            RUN_ERROR[$name]="${BACKUP_ERROR:-(см. лог)}"
            bkl_status_record fail "$name" "${RUN_ERROR[$name]}"
            if [ -n "$TELEGRAM_NOTIFICATION" ]; then
                local why hint
                why=$(printf '%s' "${BACKUP_ERROR:-нет подробностей (см. лог)}" | cut -c1-300 | bkl_html_escape)
                hint=$(bkl_reason_hint "${BACKUP_ERROR:-}")
                local hint_line=""
                [ -n "$hint" ] && hint_line="\n💡 $(printf '%s' "$hint" | bkl_html_escape)"
                local fail_kb
                fail_kb='[[{"text":"📜 Логи","callback_data":"logs_menu"}],[{"text":"🔧 Исправить права","callback_data":"deploy_dev_'$name'"}]]'
                send_telegram_notification "❌ <b>Backup failed!</b>\nDevice: <b>$name</b>\n\n<b>Причина:</b> $why${hint_line}\n\nЛог: <code>$LOG_FILE</code>" "$fail_kb"
            fi
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
            local fail_block
            fail_block=$(bkl_failed_block 5)
            send_telegram_notification "⚠️ <b>Backup completed with errors</b>\nOK: $success_count/$total_devices • Failed: $fail_count\nTime: $(date)${fail_block:+\n\n<b>Почему не вышло:</b>\n$fail_block}" \
                '[[{"text":"📜 Логи","callback_data":"logs_menu"}]]'
        fi
    fi

    [ "$fail_count" -gt 0 ] && exit 1 || exit 0
}

main "$@"

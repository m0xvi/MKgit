#!/bin/bash
# =============================================================================
# mk_schedule.sh — расписание бэкапов и обновлений MikroGit
# -----------------------------------------------------------------------------
# Демон (живёт отдельно от бота, поднимается ботом при старте и после
# перезагрузки сервера через start_bot_with_ssh.sh/cron @reboot):
#   • БЭКАП всеx устройств  — каждый день в HH:MM (по умолчанию 03:00);
#   • ПРОВЕРКА/УСТАНОВКА обновлений RouterOS — раз в неделю
#     (по умолчанию ВС 04:00); режим: только проверка или автоустановка.
#   • После автообновления автоматически делается бэкап «перед обновлением»
#     (pre_update) — это уже внутри mk_updates.sh.
#
# Управление из бота: меню «🗓 Расписание» (включить/выключить, часы, режим).
# Ручной запуск:  bash tg/mk_schedule.sh run | status | start | stop
#
# Состояние: <log dir>/schedule/schedule.conf   (настройки + время прогонов)
#            <log dir>/schedule/daemon.pid
# Лог демона: <log dir>/schedule/daemon.log
# =============================================================================

MSCH_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MSCH_POLL="${MSCH_POLL:-30}"          # период опроса, сек
MSCH_WINDOW="${MSCH_WINDOW:-900}"     # окно срабатывания, сек (15 мин)
MSCH_MIN_GAP="${MSCH_MIN_GAP:-72000}" # минимальный интервал между прогонами, сек (20 ч)

# --- Каталог состояния (рядом с логами бота) --------------------------------
msch_state_dir() {
    echo "${SCHEDULE_STATE_DIR:-$(dirname "${LOG_FILE:-$MSCH_SELF_DIR/../logs/mk_backup.log}")/schedule}"
}
msch_ensure_dirs() { mkdir -p "$(msch_state_dir)" 2>/dev/null || true; }
msch_conf_file()  { echo "$(msch_state_dir)/schedule.conf"; }
msch_pid_file()   { echo "$(msch_state_dir)/daemon.pid"; }
msch_log_file()   { echo "$(msch_state_dir)/daemon.log"; }

msch_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] SCHEDULE: $*" | tee -a "$(msch_log_file)"; }

# --- Значения по умолчанию ---------------------------------------------------
msch_defaults() {
    SCHED_ENABLED="${SCHED_ENABLED:-1}"
    SCHED_BACKUP_ENABLED="${SCHED_BACKUP_ENABLED:-1}"
    SCHED_BACKUP_HOUR="${SCHED_BACKUP_HOUR:-3}"
    SCHED_BACKUP_MINUTE="${SCHED_BACKUP_MINUTE:-0}"
    SCHED_UPDATE_ENABLED="${SCHED_UPDATE_ENABLED:-1}"
    SCHED_UPDATE_WEEKDAY="${SCHED_UPDATE_WEEKDAY:-7}"   # 1=Пн … 7=Вс
    SCHED_UPDATE_HOUR="${SCHED_UPDATE_HOUR:-4}"
    SCHED_UPDATE_MINUTE="${SCHED_UPDATE_MINUTE:-0}"
    SCHED_UPDATE_MODE="${SCHED_UPDATE_MODE:-check}"     # check | apply
    SCHED_LAST_BACKUP="${SCHED_LAST_BACKUP:-0}"
    SCHED_LAST_UPDATE="${SCHED_LAST_UPDATE:-0}"
}

# --- Чтение настроек ---------------------------------------------------------
msch_load() {
    msch_defaults
    local f; f="$(msch_conf_file)"
    [ -f "$f" ] || return 0
    local line k v
    while IFS= read -r line; do
        case "$line" in ""|\#*) continue ;; esac
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            ENABLED)              SCHED_ENABLED="$v" ;;
            BACKUP_ENABLED)       SCHED_BACKUP_ENABLED="$v" ;;
            BACKUP_HOUR)          SCHED_BACKUP_HOUR="$v" ;;
            BACKUP_MINUTE)        SCHED_BACKUP_MINUTE="$v" ;;
            UPDATE_ENABLED)       SCHED_UPDATE_ENABLED="$v" ;;
            UPDATE_WEEKDAY)       SCHED_UPDATE_WEEKDAY="$v" ;;
            UPDATE_HOUR)          SCHED_UPDATE_HOUR="$v" ;;
            UPDATE_MINUTE)        SCHED_UPDATE_MINUTE="$v" ;;
            UPDATE_MODE)          SCHED_UPDATE_MODE="$v" ;;
            LAST_BACKUP_RUN)      SCHED_LAST_BACKUP="$v" ;;
            LAST_UPDATE_RUN)      SCHED_LAST_UPDATE="$v" ;;
        esac
    done < "$f"
}

# --- Запись настроек ---------------------------------------------------------
msch_save() {
    # ВАЖНО: не вызывать здесь msch_load — он перечитал бы файл и затёр
    # только что изменённое значение (было: настройки «откатывались»).
    msch_ensure_dirs
    local f; f="$(msch_conf_file)"
    cat > "$f" <<EOF
# Расписание MikroGit (управляется из бота: меню «🗓 Расписание»)
ENABLED=$SCHED_ENABLED
BACKUP_ENABLED=$SCHED_BACKUP_ENABLED
BACKUP_HOUR=$SCHED_BACKUP_HOUR
BACKUP_MINUTE=$SCHED_BACKUP_MINUTE
UPDATE_ENABLED=$SCHED_UPDATE_ENABLED
UPDATE_WEEKDAY=$SCHED_UPDATE_WEEKDAY
UPDATE_HOUR=$SCHED_UPDATE_HOUR
UPDATE_MINUTE=$SCHED_UPDATE_MINUTE
UPDATE_MODE=$SCHED_UPDATE_MODE
LAST_BACKUP_RUN=$SCHED_LAST_BACKUP
LAST_UPDATE_RUN=$SCHED_LAST_UPDATE
EOF
    chmod 600 "$f" 2>/dev/null || true
}

msch_set() {
    # $1 = ключ (ENABLED, BACKUP_HOUR, …), $2 = значение
    msch_load
    case "$1" in
        ENABLED)         SCHED_ENABLED="$2" ;;
        BACKUP_ENABLED)  SCHED_BACKUP_ENABLED="$2" ;;
        BACKUP_HOUR)     SCHED_BACKUP_HOUR="$2" ;;
        BACKUP_MINUTE)   SCHED_BACKUP_MINUTE="$2" ;;
        UPDATE_ENABLED)  SCHED_UPDATE_ENABLED="$2" ;;
        UPDATE_WEEKDAY)  SCHED_UPDATE_WEEKDAY="$2" ;;
        UPDATE_HOUR)     SCHED_UPDATE_HOUR="$2" ;;
        UPDATE_MINUTE)   SCHED_UPDATE_MINUTE="$2" ;;
        UPDATE_MODE)     SCHED_UPDATE_MODE="$2" ;;
        LAST_BACKUP_RUN) SCHED_LAST_BACKUP="$2" ;;
        LAST_UPDATE_RUN) SCHED_LAST_UPDATE="$2" ;;
        *) return 1 ;;
    esac
    msch_save
}

# --- Человеческое описание плана --------------------------------------------
msch_weekday_name() {
    case "${1:-}" in
        1) echo "Пн" ;; 2) echo "Вт" ;; 3) echo "Ср" ;; 4) echo "Чт" ;;
        5) echo "Пт" ;; 6) echo "Сб" ;; 7) echo "Вс" ;; *) echo "?" ;;
    esac
}

msch_plan_text() {
    msch_load
    local t="" bh bm uh um
    bh=$((10#${SCHED_BACKUP_HOUR:-0})); bm=$((10#${SCHED_BACKUP_MINUTE:-0}))
    uh=$((10#${SCHED_UPDATE_HOUR:-0})); um=$((10#${SCHED_UPDATE_MINUTE:-0}))
    if [ "$SCHED_ENABLED" != "1" ]; then
        t+="⛔ <b>Выключено</b> — по расписанию ничего не запускается.\n\n"
    else
        t+="✅ <b>Включено</b>\n\n"
    fi
    if [ "$SCHED_BACKUP_ENABLED" = "1" ]; then
        t+="📦 <b>Бэкап всех устройств</b>: каждый день в <b>$(printf '%02d:%02d' "$bh" "$bm")</b>\n"
    else
        t+="📦 Бэкап по расписанию: ⛔ выключен\n"
    fi
    if [ "$SCHED_UPDATE_ENABLED" = "1" ]; then
        local mode_txt="только проверка + отчёт"
        [ "$SCHED_UPDATE_MODE" = "apply" ] && mode_txt="проверка и <b>автоустановка</b> (бэкап → reboot)"
        t+="⬆️ <b>Обновления RouterOS</b>: $(msch_weekday_name "$SCHED_UPDATE_WEEKDAY") в <b>$(printf '%02d:%02d' "$uh" "$um")</b> — $mode_txt\n"
    else
        t+="⬆️ Обновления по расписанию: ⛔ выключены\n"
    fi
    local lb lu
    lb=$(date -d "@${SCHED_LAST_BACKUP:-0}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "—")
    lu=$(date -d "@${SCHED_LAST_UPDATE:-0}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "—")
    t+="\n🕐 Последний бэкап: $([ "${SCHED_LAST_BACKUP:-0}" = "0" ] && echo 'ещё не запускался' || echo "$lb")"
    t+="\n🕐 Последняя проверка обновлений: $([ "${SCHED_LAST_UPDATE:-0}" = "0" ] && echo 'ещё не запускалась' || echo "$lu")"
    printf '%b\n' "$t"
}

# --- Живой ли демон ----------------------------------------------------------
msch_daemon_pid() {
    local p
    p=$(cat "$(msch_pid_file)" 2>/dev/null) || return 1
    [ -n "$p" ] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    echo "$p"
}

msch_daemon_running() { msch_daemon_pid > /dev/null 2>&1; }

# --- Тело демона -------------------------------------------------------------
msch_daemon_body() {
    local d; d="$(msch_state_dir)"
    cat <<DEOF
#!/bin/bash
set -uo pipefail
if command -v flock > /dev/null 2>&1; then
    exec 9> "$d/daemon.lock"
    flock -n 9 || exit 0
fi
echo \$\$ > "$d/daemon.pid"
trap 'rm -f "$d/daemon.pid"; exit 0' TERM INT
export MK_SCHEDULE_DAEMON=1

source "$MSCH_SELF_DIR/tg_bot_config.sh" 2>/dev/null || true
source "$MSCH_SELF_DIR/tg_api_helpers.sh" 2>/dev/null || true
source "$MSCH_SELF_DIR/mk_schedule.sh"

msch_log "демон запущен (pid=\$\$)"
while true; do
    msch_tick || true
    sleep $MSCH_POLL & wait \$! 2>/dev/null || true
done
DEOF
}

msch_daemon_start() {
    msch_ensure_dirs
    if msch_daemon_running; then return 0; fi
    rm -f "$(msch_pid_file)" 2>/dev/null || true
    if command -v setsid > /dev/null 2>&1; then
        setsid bash -c "$(msch_daemon_body)" >> "$(msch_log_file)" 2>&1 < /dev/null &
    else
        nohup bash -c "$(msch_daemon_body)" >> "$(msch_log_file)" 2>&1 < /dev/null &
    fi
    sleep 1
    msch_daemon_running
}

msch_daemon_stop() {
    local p
    p=$(msch_daemon_pid) || { rm -f "$(msch_pid_file)"; return 0; }
    kill -TERM "$p" 2>/dev/null || true
    sleep 1
    kill -KILL "$p" 2>/dev/null || true
    rm -f "$(msch_pid_file)"
    msch_log "демон остановлен (pid=$p)"
}

msch_daemon_ensure() {
    msch_load
    [ "$SCHED_ENABLED" = "1" ] || { msch_daemon_stop; return 1; }
    msch_daemon_start
}

# --- Срабатывание ------------------------------------------------------------
# Проверяет, попадает ли текущее время в окно HH:MM..HH:MM+15мин
msch_in_window() {
    local hour="$1" minute="$2"
    local now_s target_s diff hn mn sn
    hour=$((10#${hour:-0})); minute=$((10#${minute:-0}))
    hn=$((10#$(date +%H))); mn=$((10#$(date +%M))); sn=$((10#$(date +%S)))
    now_s=$(( hn * 3600 + mn * 60 + sn ))
    target_s=$(( hour * 3600 + minute * 60 ))
    diff=$(( now_s - target_s ))
    [ "$diff" -ge 0 ] && [ "$diff" -le "$MSCH_WINDOW" ]
}

msch_due() {
    # $1 = last-run epoch, $2 = hour, $3 = minute → 0 если пора
    local last="${1:-0}" hour="$2" minute="$3"
    [ "$last" -gt 0 ] && [ $(( $(date +%s) - last )) -lt "$MSCH_MIN_GAP" ] && return 1
    msch_in_window "$hour" "$minute"
}

# Запуск бэкапа по расписанию
msch_run_backup() {
    local bs="$MSCH_SELF_DIR/../MikroGit.sh"
    [ -f "$bs" ] || bs="${BACKUP_SCRIPT:-}"
    [ -f "$bs" ] || { msch_log "MikroGit.sh не найден — бэкап пропущен"; return 1; }
    msch_log "запуск планового бэкапа: $bs --telegram schedule"
    ( nohup bash "$bs" --telegram schedule >> "$(dirname "$(msch_log_file)")/mk_backup.log" 2>&1 < /dev/null & )
    msch_set LAST_BACKUP_RUN "$(date +%s)"
    msch_log "бэкап запущен в фоне"
}

# Запуск проверки/обновления RouterOS по расписанию
msch_run_updates() {
    local us="$MSCH_SELF_DIR/mk_updates.sh"
    [ -f "$us" ] || { msch_log "mk_updates.sh не найден — проверка пропущена"; return 1; }
    msch_load
    local -a args
    if [ "$SCHED_UPDATE_MODE" = "apply" ]; then
        args=(updateall)
    else
        args=(check all)
    fi
    msch_log "запуск обновлений по расписанию: mk_updates.sh ${args[*]}"
    (
        MK_AUTO_RUN=1 nohup bash "$us" "${args[@]}" \
            >> "$(dirname "$(msch_log_file)")/mk_updates.log" 2>&1 < /dev/null &
    )
    msch_set LAST_UPDATE_RUN "$(date +%s)"
    msch_log "обновления запущены в фоне (${args[*]})"
}

# Один тик демона
msch_tick() {
    msch_load
    [ "$SCHED_ENABLED" = "1" ] || return 0
    local now wd
    now=$(date +%s); wd=$(date +%u)

    if [ "$SCHED_BACKUP_ENABLED" = "1" ] && msch_due "$SCHED_LAST_BACKUP" "$SCHED_BACKUP_HOUR" "$SCHED_BACKUP_MINUTE"; then
        msch_run_backup
    fi
    if [ "$SCHED_UPDATE_ENABLED" = "1" ] && [ "$wd" = "$SCHED_UPDATE_WEEKDAY" ] \
       && msch_due "$SCHED_LAST_UPDATE" "$SCHED_UPDATE_HOUR" "$SCHED_UPDATE_MINUTE"; then
        msch_run_updates
    fi
    return 0
}

# --- CLI ---------------------------------------------------------------------
msch_main() {
    if [ -f "$MSCH_SELF_DIR/tg_bot_config.sh" ]; then
        # shellcheck source=tg_bot_config.sh
        source "$MSCH_SELF_DIR/tg_bot_config.sh"
        if ! declare -f tg_send_message > /dev/null 2>&1 && [ -f "$MSCH_SELF_DIR/tg_api_helpers.sh" ]; then
            source "$MSCH_SELF_DIR/tg_api_helpers.sh"
        fi
    fi
    msch_ensure_dirs
    case "${1:-}" in
        start)   msch_daemon_ensure && echo "демон запущен (pid=$(msch_daemon_pid))" ;;
        stop)    msch_daemon_stop; echo "демон остановлен" ;;
        status)
            msch_load
            if msch_daemon_running; then echo "демон: ✅ работает (pid=$(msch_daemon_pid))"; else echo "демон: ⛔ не запущен"; fi
            echo "🗓 Расписание MikroGit:"
            msch_plan_text | sed 's/<[^>]*>//g'
            ;;
        tick)    msch_tick ;;
        daemon)
            # Foreground-цикл для systemd (Type=simple): демон не отвязывается
            # от терминала, systemd сам его перезапускает при падении.
            msch_ensure_dirs
            if command -v flock > /dev/null 2>&1; then
                exec 9> "$(msch_state_dir)/daemon.lock"
                if ! flock -n 9; then
                    echo "Планировщик уже запущен (lock занят) — выходим." >&2
                    exit 0
                fi
            fi
            echo "$$" > "$(msch_pid_file)"
            trap 'rm -f "$(msch_pid_file)"; exit 0' TERM INT
            msch_log "демон (systemd/foreground) запущен pid=$$"
            while true; do
                msch_tick || true
                # sleep в фоне + wait: TERM от systemd обрабатывается сразу,
                # а не после окончания паузы (иначе stop висит до 30 c,
                # systemd добивает по TimeoutStopSec и остаётся stale pid)
                sleep "$MSCH_POLL" & wait $! 2>/dev/null || true
            done
            ;;
        run)
            # немедленный прогон выбранного блока: run backup | run updates
            case "${2:-}" in
                backup)  msch_run_backup ;;
                updates) msch_run_updates ;;
                *) echo "Использование: mk_schedule.sh run {backup|updates}" >&2; exit 2 ;;
            esac ;;
        *)
            echo "Использование: mk_schedule.sh {start|stop|status|daemon|tick|run backup|run updates}" >&2
            exit 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    msch_main "$@"
fi

#!/bin/bash
# =============================================================================
# mk_cleanup.sh — автоочистка логов, отчётов и мусора MikroGit
# -----------------------------------------------------------------------------
# Что делает (идемпотентно, безопасно запускать сколько угодно раз):
#   1) переносит СТАРЫЕ отчёты из корня bckp/ в logs/reports/
#      (раньше backup_report_*.txt сыпались прямо в bckp/);
#   2) ротирует основной лог и логи воркеров (update_state/deploy_state/
#      harden_state) по размеру, сжимая старые в .gz и храня не больше N;
#   3) убирает старые ~/deploy_key_YYYYMMDD_*.log, оставленные deploy_key.sh
#      в домашнем каталоге, и утаскивает ~/mikrotik_backup.log в logs/;
#   4) удаляет незавершённые *.part и пустые каталоги устройств в bckp/;
#   5) подчищает старые run_*.log / last_run.log воркеров.
#
# Использование:
#   bash tg/mk_cleanup.sh                 # полная очистка с дефолтными путями
#   bash tg/mk_cleanup.sh --dry-run       # только показать, что будет удалено
#   bash tg/mk_cleanup.sh --backup-dir ... --log-file ...
#   source tg/mk_cleanup.sh; mkc_full_cleanup <backup_dir> <log_file>
#
# Переменные окружения:
#   MKC_LOG_MAX_BYTES   — порог ротации лога (по умолчанию 10 MB)
#   MKC_LOG_KEEP        — сколько архивных копий лога хранить (по умолчанию 3)
#   MKC_HOME_LOG_DAYS   — через сколько дней удалять ~/deploy_key_*.log (7)
#   MKC_STATE_LOG_KEEP  — сколько run-логов воркеров хранить (по умолчанию 20)
#   MKC_DRY_RUN=1       — ничего не удалять, только печатать
# =============================================================================

CM_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CM_REPO_DIR="${CM_REPO_DIR:-$(cd "$CM_SELF_DIR/.." && pwd)}"

MKC_LOG_MAX_BYTES="${MKC_LOG_MAX_BYTES:-10485760}"
MKC_LOG_KEEP="${MKC_LOG_KEEP:-3}"
MKC_HOME_LOG_DAYS="${MKC_HOME_LOG_DAYS:-7}"
MKC_STATE_LOG_KEEP="${MKC_STATE_LOG_KEEP:-20}"
MKC_DRY_RUN="${MKC_DRY_RUN:-0}"

mkc_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CLEANUP: $*"
}

mkc_rm() {
    if [ "$MKC_DRY_RUN" = "1" ]; then
        mkc_log "[dry] rm: $*"
    else
        rm -rf "$@"
    fi
}

# --- Ротация одного файла лога по размеру -----------------------------------
# $1 — файл, $2 — максимальный размер (байт), $3 — сколько архивов хранить
mkc_rotate_file() {
    local f="${1:-}" max="${2:-$MKC_LOG_MAX_BYTES}" keep="${3:-$MKC_LOG_KEEP}"
    [ -f "$f" ] || return 0
    local sz
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [ "$sz" -le "$max" ] && return 0

    mkc_log "ротация $(basename "$f") ($((sz / 1024)) KB > $((max / 1024)) KB)"
    if [ "$MKC_DRY_RUN" = "1" ]; then
        mkc_log "[dry] mv $f -> $(basename "$f").$(date +%Y%m%d_%H%M%S).gz"
        return 0
    fi
    local stamp archive
    stamp=$(date +%Y%m%d_%H%M%S)
    archive="${f}.${stamp}.gz"
    if command -v gzip > /dev/null 2>&1; then
        # копируем, затем обрезаем оригинал (лог продолжают писать воркеры)
        cp "$f" "${f}.tmp.$$" 2>/dev/null && gzip -c "${f}.tmp.$$" > "$archive" 2>/dev/null
        rm -f "${f}.tmp.$$"
    else
        cp "$f" "$archive" 2>/dev/null
    fi
    : > "$f" 2>/dev/null || true

    # оставляем только $keep самых свежих архивов
    local archives
    archives=$(find "$(dirname "$f")" -maxdepth 1 -type f -name "$(basename "$f").*.gz" \
                -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
    if [ -n "$archives" ]; then
        printf '%s\n' "$archives" | tail -n +$((keep + 1)) | while IFS= read -r a; do
            mkc_rm "$a"
        done
    fi
}

# --- Ограничить количество файлов по маске ----------------------------------
# $1 — каталог, $2 — glob, $3 — сколько оставить, $4 — исключить (основной файл)
mkc_keep_newest() {
    local dir="${1:-}" pattern="${2:-}" keep="${3:-20}" exclude="${4:-}"
    [ -d "$dir" ] || return 0
    local list count excess
    list=$(find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@\t%p\n' 2>/dev/null \
            | sort -rn | cut -f2-)
    [ -n "$exclude" ] && list=$(printf '%s\n' "$list" | grep -vxF "$exclude")
    [ -z "$list" ] && return 0
    count=$(printf '%s\n' "$list" | grep -c . || true)
    [ "$count" -le "$keep" ] && return 0
    excess=$((count - keep))
    mkc_log "удаляю $excess старых файлов '$pattern' в ${dir/#$HOME/~} (оставляю $keep)"
    printf '%s\n' "$list" | tail -n "$excess" | while IFS= read -r f; do
        mkc_rm "$f"
    done
}

# --- Перенос старых отчётов из корня bckp/ в logs/reports/ -------------------
mkc_migrate_reports() {
    local bdir="${1:-}" rdir="${2:-}"
    [ -n "$bdir" ] && [ -d "$bdir" ] || return 0
    [ -n "$rdir" ] || return 0
    local files
    files=$(find "$bdir" -maxdepth 1 -type f \( -name 'backup_report_*.txt' -o -name 'backup_report_*.txt.*' \) 2>/dev/null)
    [ -z "$files" ] && return 0
    mkc_log "переношу старые отчёты из bckp/ в $(dirname "$rdir")/reports/"
    if [ "$MKC_DRY_RUN" = "1" ]; then
        printf '%s\n' "$files" | sed 's/^/[dry] mv /'
        return 0
    fi
    mkdir -p "$rdir"
    printf '%s\n' "$files" | while IFS= read -r f; do
        mv -f "$f" "$rdir/" 2>/dev/null || rm -f "$f"
    done
}

# --- Пустые/мусорные каталоги устройств -------------------------------------
mkc_clean_device_dirs() {
    local bdir="${1:-}"
    [ -n "$bdir" ] && [ -d "$bdir" ] || return 0
    local d name backups
    for d in "$bdir"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        # каталоги служебных состояний не трогаем
        case "$name" in pre_update|logs|reports) continue ;; esac
        backups=$(find "$d" -maxdepth 1 -type f \( -name '*.backup' -o -name '*.rsc' \) 2>/dev/null | wc -l)
        if [ "$backups" -eq 0 ]; then
            # бэкапов нет: удаляем только если внутри нечего терять
            if [ -z "$(find "$d" -maxdepth 1 -type f ! -name 'device_info*.txt' 2>/dev/null)" ]; then
                mkc_log "удаляю пустой каталог без бэкапов: ${d/#$HOME/~}"
                mkc_rm "$d"
            fi
        else
            # незавершённые загрузки
            find "$d" -maxdepth 1 -type f -name '*.part' -mmin +60 2>/dev/null | while IFS= read -r f; do
                mkc_log "удаляю недокачанный файл: ${f/#$HOME/~}"
                mkc_rm "$f"
            done
        fi
    done
}

# --- Домашние логи deploy_key.sh и старый mikrotik_backup.log ----------------
mkc_clean_home_logs() {
    local home="${HOME:-/root}"
    # deploy_key_YYYYMMDD_*.log — по файлу на каждый прогон, копятся в ~
    local old
    old=$(find "$home" -maxdepth 1 -type f -name 'deploy_key_*.log' -mtime +"$MKC_HOME_LOG_DAYS" 2>/dev/null)
    if [ -n "$old" ]; then
        local n
        n=$(printf '%s\n' "$old" | grep -c . || true)
        mkc_log "удаляю $n старых ~/deploy_key_*.log (старше $MKC_HOME_LOG_DAYS дней)"
        printf '%s\n' "$old" | while IFS= read -r f; do mkc_rm "$f"; done
    fi
    # оставляем максимум 10 самых свежих, даже если они недавние
    mkc_keep_newest "$home" 'deploy_key_*.log' 10

    # старый лог MikroGit.sh, который раньше писался в ~/mikrotik_backup.log
    local legacy="$home/mikrotik_backup.log"
    if [ -f "$legacy" ]; then
        local target="${CM_REPO_DIR}/logs/legacy"
        mkc_log "переношу устаревший ~/mikrotik_backup.log в logs/legacy/"
        if [ "$MKC_DRY_RUN" = "1" ]; then
            mkc_log "[dry] mv $legacy $target/"
        else
            mkdir -p "$target"
            mv -f "$legacy" "$target/mikrotik_backup_$(date +%Y%m%d_%H%M%S).log" 2>/dev/null || rm -f "$legacy"
        fi
    fi
}

# --- Логи воркеров (update_state / deploy_state / harden_state) --------------
mkc_clean_state_logs() {
    local logdir="${1:-}"
    [ -n "$logdir" ] && [ -d "$logdir" ] || return 0
    local sd
    for sd in "$logdir"/update_state "$logdir"/deploy_state "$logdir"/harden_state; do
        [ -d "$sd" ] || continue
        mkc_keep_newest "$sd" 'run_*.log*' "$MKC_STATE_LOG_KEEP"
        mkc_keep_newest "$sd" 'last_run.log.*.gz' 3
        find "$sd" -maxdepth 1 -type f \( -name 'worker_last.pid' -o -name '*.tmp' \) 2>/dev/null | while IFS= read -r f; do
            # pid-файлы мёртвых воркеров не нужны
            local pid; pid=$(cat "$f" 2>/dev/null || true)
            if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
                mkc_rm "$f"
            fi
        done
    done
    # архивы, накопленные старой ротацией лога
    mkc_keep_newest "$logdir" '*.log.*.gz' 6
}

# --- Полная очистка ----------------------------------------------------------
# $1 — каталог бэкапов (bckp), $2 — основной файл лога
mkc_full_cleanup() {
    local bdir="${1:-$CM_REPO_DIR/bckp}"
    local logf="${2:-$CM_REPO_DIR/logs/mk_backup.log}"
    local logdir; logdir=$(dirname "$logf")
    local rdir="${REPORTS_DIR:-$logdir/reports}"

    mkdir -p "$logdir" "$rdir" 2>/dev/null || true

    mkc_migrate_reports "$bdir" "$rdir"
    mkc_rotate_file "$logf"
    mkc_clean_device_dirs "$bdir"
    # репорты: не больше MAX_REPORTS (по умолчанию 5)
    mkc_keep_newest "$rdir" 'backup_report_*.txt' "${MAX_REPORTS:-5}"
    mkc_clean_state_logs "$logdir"
    mkc_clean_home_logs

    # логи планировщика и деплоя
    mkc_rotate_file "$logdir/schedule/daemon.log"
    # deploy_key.sh пишет по файлу на прогон — оставляем 30 самых свежих
    mkc_keep_newest "$logdir/deploy" 'deploy_key_*.log' 30
    # прочие логи в logs/
    local f
    for f in "$logdir"/mk_updates.log "$logdir"/mk_deploy.log "$logdir"/mk_harden.log "$logdir"/tg_api.log; do
        mkc_rotate_file "$f"
    done
    mkc_keep_newest "$logdir" '*.log.*.gz' 8
    return 0
}

# --- CLI ---------------------------------------------------------------------
mkc_main() {
    local bdir="$CM_REPO_DIR/bckp" logf="$CM_REPO_DIR/logs/mk_backup.log"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)       MKC_DRY_RUN=1; shift ;;
            --backup-dir)    bdir="${2:-}"; shift 2 ;;
            --log-file)      logf="${2:-}"; shift 2 ;;
            --max-bytes)     MKC_LOG_MAX_BYTES="${2:-}"; shift 2 ;;
            --keep)          MKC_LOG_KEEP="${2:-}"; shift 2 ;;
            -h|--help)
                echo "Использование: mk_cleanup.sh [--dry-run] [--backup-dir DIR] [--log-file FILE] [--max-bytes N] [--keep N]"
                exit 0 ;;
            *) shift ;;
        esac
    done
    # пути из конфига бота, если он есть (BACKUP_DIR, LOG_FILE, MAX_REPORTS)
    if [ -f "$CM_SELF_DIR/tg_bot_config.sh" ]; then
        # shellcheck source=tg_bot_config.sh
        source "$CM_SELF_DIR/tg_bot_config.sh"
        [ -n "${BACKUP_DIR:-}" ] && [ "$bdir" = "$CM_REPO_DIR/bckp" ] && bdir="$BACKUP_DIR"
        [ -n "${LOG_FILE:-}" ] && [ "$logf" = "$CM_REPO_DIR/logs/mk_backup.log" ] && logf="$LOG_FILE"
    fi
    mkc_log "старт (backup_dir=$bdir, log=$logf$([ "$MKC_DRY_RUN" = 1 ] && echo ', DRY-RUN'))"
    mkc_full_cleanup "$bdir" "$logf"
    mkc_log "готово"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    mkc_main "$@"
fi

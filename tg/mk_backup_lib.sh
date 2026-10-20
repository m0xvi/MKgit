#!/bin/bash
# =============================================================================
# mk_backup_lib.sh — общие функции работы с файлами бэкапов MikroTik
# -----------------------------------------------------------------------------
# Используется и MikroGit.sh (серверный бэкап), и Telegram-ботом, чтобы список,
# сортировка и «вид» бэкапов были ОДИНАКОВЫМИ везде.
#
# Поддерживаемые форматы:
#   *.backup — бинарная резервная копия RouterOS (/system backup save) — основной
#   *.rsc    — текстовый экспорт (/export) — старые бэкапы, остаются доступны
#
# Бэкап «перед обновлением» отличается префиксом pre_update в имени файла:
#   <device>_pre_update_2026-10-20_03-00-00.backup
# =============================================================================

# Бэкап сделан перед обновлением (RouterOS / RouterBOOT)?
bkl_is_pre_update() {
    case "$(basename "${1:-}")" in
        *pre_update*) return 0 ;;
    esac
    return 1
}

# Список бэкапов в каталоге, САМЫЕ СВЕЖИЕ ПЕРВЫМИ.
# $1 — каталог устройства, $2 — all|regular|pre (по умолчанию all)
bkl_list_backups() {
    local dir="${1:-}" kind="${2:-all}" f
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if bkl_is_pre_update "$f"; then
            [ "$kind" = "regular" ] && continue
        else
            [ "$kind" = "pre" ] && continue
        fi
        printf '%s\n' "$f"
    done < <(find "$dir" -maxdepth 1 -type f \( -name '*.backup' -o -name '*.rsc' \) \
                -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)
}

# Самый свежий бэкап (all|regular|pre); пусто, если нет.
bkl_latest() {
    bkl_list_backups "${1:-}" "${2:-all}" | head -n1
}

# Количество бэкапов (all|regular|pre)
bkl_count() {
    bkl_list_backups "${1:-}" "${2:-all}" | grep -c . || true
}

# Есть ли хоть один бэкап перед обновлением
bkl_has_pre() {
    [ -n "$(bkl_latest "${1:-}" pre)" ]
}

# Человеко-читаемый размер файла
bkl_size_h() {
    local f="${1:-}" sz
    [ -f "$f" ] || { echo "?"; return; }
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$sz" -ge 1048576 ]; then
        echo "$(( sz / 1048576 )) MB"
    elif [ "$sz" -ge 1024 ]; then
        echo "$(( sz / 1024 )) KB"
    else
        echo "$sz B"
    fi
}

# Время последнего изменения файла «YYYY-MM-DD HH:MM:SS»
bkl_mtime() {
    local f="${1:-}"
    [ -f "$f" ] || { echo "?"; return; }
    stat -c %y "$f" 2>/dev/null | cut -d'.' -f1
}

# Короткое описание формата
bkl_format_desc() {
    case "${1:-}" in
        *.backup) echo "бинарный .backup (полное восстановление)" ;;
        *.rsc)    echo "текстовый .rsc (/export)" ;;
        *)        echo "?" ;;
    esac
}

# Пометка для Telegram/отчётов
bkl_label() {
    local f="${1:-}"
    if bkl_is_pre_update "$f"; then
        case "$f" in
            *.rsc) echo "🛡 перед обновлением (экспорт .rsc)" ;;
            *)     echo "🛡 перед обновлением" ;;
        esac
    else
        case "$f" in
            *.rsc) echo "📄 экспорт .rsc (старый формат)" ;;
            *)     echo "📦 плановый" ;;
        esac
    fi
}

# Человеческое имя устройства из пути к файлу (для отчётов)
bkl_device_of() {
    basename "$(dirname "${1:-}")"
}

# =============================================================================
# Причины сбоев: подсказки + итоги последнего запуска (для Telegram-бота)
# =============================================================================

# Экранирование для parse_mode=HTML
bkl_html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Убрать HTML-теги (для однострочных выжимок)
bkl_strip_tags() {
    sed -e 's/<[^>]*>//g'
}

# Короткая подсказка «что делать» по тексту причины
bkl_reason_hint() {
    local r="${1:-}"
    [ -n "$r" ] || return 0
    case "$r" in
        *"политика ftp"*|*"scp/sftp"*|*"Not a directory"*|*"scp:"*)
            echo "у пользователя нет политики ftp — без неё scp/sftp не читают файлы: /user group set <группа> policy=...,ftp" ;;
        *"нет SSH-доступа"*|*"Cannot connect"*|*"Connection refused"*|*"Connection timed out"*|*"No route to host"*|*"Permission denied (publickey"*|*"Host key verification failed"*)
            echo "проверьте сеть/порт и ключ: на роутере /user ssh-keys print, у пользователя политики ssh (и read/write)" ;;
        *"не создаётся"*|*"мало места"*|*"no space"*|*"not enough free"*|*"disk full"*|*"не появился"*)
            echo "мало места на flash: /system resource print → free-hdd-space, /file print; лишние файлы удаляются вручную" ;;
        *"login failed"*|*"invalid user"*|*"Authentication failed"*)
            echo "проверьте пользователя/ключ в devices.conf" ;;
    esac
}

# Файл итогов последнего запуска: ok|fail <TAB> устройство <TAB> время <TAB> причина
bkl_status_file() {
    if [ -n "${BACKUP_STATUS_FILE:-}" ]; then
        echo "$BACKUP_STATUS_FILE"
    elif [ -n "${LOG_DIR:-}" ]; then
        echo "$LOG_DIR/last_backup_status.tsv"
    else
        # в боте задан только LOG_FILE (= .../logs/mk_backup.log)
        echo "$(dirname "${LOG_FILE:-/tmp/mk_backup.log}")/last_backup_status.tsv"
    fi
}

bkl_status_reset() {
    : > "$(bkl_status_file)" 2>/dev/null || true
}

bkl_status_record() {
    local st="${1:-}" dev="${2:-}" reason="${3:-}"
    [ -n "$st" ] && [ -n "$dev" ] || return 0
    reason=$(printf '%s' "$reason" | tr '\t\n\r' '   ' | cut -c1-300)
    printf '%s\t%s\t%s\t%s\n' "$st" "$dev" "$(date '+%Y-%m-%d %H:%M:%S')" "$reason" \
        >> "$(bkl_status_file)" 2>/dev/null || true
}

# Неудачи последнего запуска, по одной строке "устройство<TAB>причина" (не более $1)
bkl_failed_list() {
    local max="${1:-5}" f
    f=$(bkl_status_file)
    [ -s "$f" ] || return 0
    awk -F'\t' -v max="$max" '
        $1 == "fail" { n++; dev[n]=$2; why[n]=$4 }
        END {
            start = (n > max) ? n - max + 1 : 1
            if (n > max) printf "…и ещё %d\n", n - max
            for (i = start; i <= n; i++) printf "%s\t%s\n", dev[i], (why[i] == "" ? "см. лог" : why[i])
        }' "$f"
}

# Готовый HTML-блок «Почему не вышло» для сообщения бота (пусто, если неудач нет)
bkl_failed_block() {
    local max="${1:-5}" dev why hint out=""
    while IFS=$'\t' read -r dev why; do
        [ -n "$dev" ] || continue
        if [ "$dev" = "…и ещё" ] || [ "${dev#…и ещё}" != "$dev" ]; then
            out+="<i>$dev ${why}</i>"$'\n'
            continue
        fi
        why=$(printf '%s' "$why" | cut -c1-200)
        hint=$(bkl_reason_hint "$why")
        out+="• <b>$(printf '%s' "$dev" | bkl_html_escape)</b>: $(printf '%s' "$why" | bkl_html_escape)"$'\n'
        [ -n "$hint" ] && out+="  💡 $(printf '%s' "$hint" | bkl_html_escape)"$'\n'
    done < <(bkl_failed_list "$max")
    [ -n "$out" ] && printf '%s' "$out"
}

# Причина последнего сбоя по устройству ("" — не было)
bkl_last_error() {
    local dev="${1:-}" f
    f=$(bkl_status_file)
    [ -s "$f" ] || return 0
    awk -F'\t' -v d="$dev" '$1 == "fail" && $2 == d { why=$4 } END { print why }' "$f"
}

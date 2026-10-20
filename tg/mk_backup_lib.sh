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

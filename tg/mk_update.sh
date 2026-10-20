#!/bin/bash
# =============================================================================
# mk_update.sh — УСТАРЕВШЕЕ ИМЯ. Оставлено как совместимая обёртка.
# -----------------------------------------------------------------------------
# Раньше в репозитории было два почти одинаковых файла: mk_update.sh и
# mk_updates.sh. Они разошлись, и правки (бэкап .backup перед обновлением,
# остановка фоновых операций, RouterBOOT) попадали только в mk_updates.sh.
# Чтобы старые cron-записи/скрипты не работали по устаревшей логике, этот
# файл просто передаёт все аргументы в актуальный mk_updates.sh.
#
# Используйте:  bash tg/mk_updates.sh {check [all|device] | apply <device> |
#                                      routerboard <device> | updateall |
#                                      applylist | status}
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/mk_updates.sh" ]; then
    echo "ERROR: mk_updates.sh не найден в $SCRIPT_DIR" >&2
    exit 1
fi

exec bash "$SCRIPT_DIR/mk_updates.sh" "$@"

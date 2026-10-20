#!/bin/bash
# =============================================================================
# install_systemd.sh — установка systemd-юнитов MikroGit (бот + планировщик)
# -----------------------------------------------------------------------------
# Запускать из ЛЮБОГО каталога и обязательно через sudo:
#
#   sudo bash /home/aionis/MikroGit/tg/install_systemd.sh
#   sudo bash tg/install_systemd.sh --dry-run     # только показать, что будет
#   sudo bash tg/install_systemd.sh --uninstall   # удалить юниты и остановить
#
# Что делает:
#   1) берёт шаблоны tg/mkgit-bot.service.example и tg/mkgit-schedule.service.example;
#   2) подставляет реальные путь к репозиторию и пользователя-владельца
#      (а не жёстко «aionis»);
#   3) останавливает ручные копии бота/планировщика, чтобы не конфликтовал lock;
#   4) ставит юниты в /etc/systemd/system, делает daemon-reload, enable --now;
#   5) печатает статус и подсказки по логам.
# =============================================================================

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"

DRY_RUN=0
UNINSTALL=0
for a in "$@"; do
    case "$a" in
        --dry-run)   DRY_RUN=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Неизвестный аргумент: $a" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
run()  {
    if [ "$DRY_RUN" = "1" ]; then
        say "  [dry] $*"
    else
        "$@"
    fi
}

if [ "$(id -u)" != "0" ] && [ "$DRY_RUN" != "1" ]; then
    say "ERROR: нужны права root. Запустите:  sudo bash $SELF_DIR/$(basename "$0")" >&2
    say "       (или добавьте --dry-run, чтобы просто посмотреть план)" >&2
    exit 1
fi

# --- Кому принадлежит репозиторий: от этого пользователя будет работать бот ---
OWNER="$(stat -c %U "$REPO_DIR" 2>/dev/null)"
OWNER_HOME="$(getent passwd "$OWNER" 2>/dev/null | cut -d: -f6)"
OWNER_HOME="${OWNER_HOME:-/home/$OWNER}"

say "Репозиторий : $REPO_DIR"
say "Пользователь: $OWNER (HOME=$OWNER_HOME)"
[ "$OWNER" = "root" ] && say "⚠️  репозиторий принадлежит root — бот будет работать от root (не рекомендуется)" \
                        "     chown -R <пользователь>:<пользователь> \"$REPO_DIR\""
say ""

SYSTEMD_DIR="/etc/systemd/system"

# --- Удаление -----------------------------------------------------------------
if [ "$UNINSTALL" = "1" ]; then
    say "Удаляю юниты…"
    run systemctl disable --now mkgit-bot.service mkgit-schedule.service 2>/dev/null
    run rm -f "$SYSTEMD_DIR/mkgit-bot.service" "$SYSTEMD_DIR/mkgit-schedule.service"
    run systemctl daemon-reload
    run systemctl reset-failed mkgit-bot.service mkgit-schedule.service 2>/dev/null
    say "Готово. Ручной запуск: cd $REPO_DIR/tg && ./start_bot_with_ssh.sh"
    exit 0
fi

# --- 0. Конфиг бота должен существовать --------------------------------------
if [ ! -f "$SELF_DIR/tg_bot_config.sh" ]; then
    say "ERROR: нет $SELF_DIR/tg_bot_config.sh" >&2
    say "       Создайте его из шаблона и заполните токен/chat_id:" >&2
    say "       cp $SELF_DIR/tg_bot_config.sh.example $SELF_DIR/tg_bot_config.sh" >&2
    exit 1
fi

# --- 1. Шаблоны ---------------------------------------------------------------
BOT_TPL="$SELF_DIR/mkgit-bot.service.example"
SCH_TPL="$SELF_DIR/mkgit-schedule.service.example"
for t in "$BOT_TPL" "$SCH_TPL"; do
    if [ ! -f "$t" ]; then
        say "ERROR: нет шаблона $t" >&2
        say "       Обновите репозиторий:  cd $REPO_DIR && git pull" >&2
        exit 1
    fi
done

gen_unit() {
    # $1 — шаблон; подставляем путь репозитория и пользователя
    local tpl="$1"
    sed -e "s|/home/aionis/MikroGit|$REPO_DIR|g" \
        -e "s|^User=aionis$|User=$OWNER|" \
        -e "s|^Group=aionis$|Group=$OWNER|" \
        -e "s|^Environment=HOME=/home/aionis$|Environment=HOME=$OWNER_HOME|" \
        "$tpl"
}

# --- 2. Останавливаем ручные копии (они держат lock) --------------------------
say "Шаг 1/4: останавливаю ручные копии бота и планировщика…"
MANUAL_BOTS=$(pgrep -u "$OWNER" -f 'mk_tg_bot\.sh' 2>/dev/null || true)
MANUAL_SCH=$(pgrep -u "$OWNER" -f 'mk_schedule\.sh (daemon|start)' 2>/dev/null || true)
if [ -n "$MANUAL_BOTS$MANUAL_SCH" ]; then
    for p in $MANUAL_BOTS $MANUAL_SCH; do
        say "  • останавливаю pid=$p ($(ps -o args= -p "$p" 2>/dev/null | cut -c1-70))"
    done
    run pkill -u "$OWNER" -f 'mk_tg_bot\.sh' 2>/dev/null
    run pkill -u "$OWNER" -f 'mk_schedule\.sh (daemon|start)' 2>/dev/null
    run sleep 2
else
    say "  • ручных копий нет"
fi

# --- 3. Устанавливаем юниты ---------------------------------------------------
say "Шаг 2/4: устанавливаю юниты в $SYSTEMD_DIR…"
if [ "$DRY_RUN" = "1" ]; then
    say "--- mkgit-bot.service ---"
    gen_unit "$BOT_TPL" | grep -vE '^\s*#|^\s*$'
    say "--- mkgit-schedule.service ---"
    gen_unit "$SCH_TPL" | grep -vE '^\s*#|^\s*$'
else
    gen_unit "$BOT_TPL" > "$SYSTEMD_DIR/mkgit-bot.service" || { say "ERROR: не смог записать юнит" >&2; exit 1; }
    gen_unit "$SCH_TPL" > "$SYSTEMD_DIR/mkgit-schedule.service" || { say "ERROR: не смог записать юнит" >&2; exit 1; }
    chmod 644 "$SYSTEMD_DIR/mkgit-bot.service" "$SYSTEMD_DIR/mkgit-schedule.service"
    say "  • $SYSTEMD_DIR/mkgit-bot.service"
    say "  • $SYSTEMD_DIR/mkgit-schedule.service"
fi

say "Шаг 3/4: systemctl daemon-reload…"
run systemctl daemon-reload

say "Шаг 4/4: enable --now mkgit-bot mkgit-schedule…"
run systemctl enable --now mkgit-bot.service mkgit-schedule.service

if [ "$DRY_RUN" = "1" ]; then
    say ""
    say "Это был dry-run: ничего не изменено. Без --dry-run выполнится то же самое по-настоящему."
    exit 0
fi

# --- Итог ---------------------------------------------------------------------
sleep 3
say ""
say "=== Статус ==================================================="
systemctl --no-pager --lines=0 status mkgit-bot.service      | head -6
echo
systemctl --no-pager --lines=0 status mkgit-schedule.service | head -6
say "=============================================================="
say ""
say "Логи:"
say "  journalctl -u mkgit-bot -f"
say "  journalctl -u mkgit-schedule -f"
say "  tail -f $REPO_DIR/logs/mk_backup.log"
say ""
say "Проверка расписания:  bash $REPO_DIR/tg/mk_schedule.sh status"
say "Диагностика:          bash $REPO_DIR/tg/mkgit_doctor.sh"

# подсказка, если сервис не поднялся
if ! systemctl is-active --quiet mkgit-bot.service; then
    say ""
    say "⚠️  mkgit-bot не активен. Частые причины:"
    say "   • lock занят другой копией:  pgrep -af mk_tg_bot.sh"
    say "   • нет прав на logs/:          sudo chown -R $OWNER:$OWNER \"$REPO_DIR\""
    say "   • подробности:                journalctl -u mkgit-bot -n 40 --no-pager"
fi

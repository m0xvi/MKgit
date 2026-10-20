#!/bin/bash
# =============================================================================
# mkgit_doctor.sh — диагностика и починка типовых проблем MikroGit
# -----------------------------------------------------------------------------
# Проверяет (ничего не меняя):
#   • владельца файлов репозитория (root-овые файлы → git «dubious ownership»);
#   • права на запись в logs/, bckp/ и на .git (git fetch → Permission denied);
#   • живой SSH-ключ из конфига и его доступность;
#   • процессы бота/планировщика и занятость локов;
#   • состояние systemd-сервисов (если установлены);
#   • мусор в домашнем каталоге (~/deploy_key_*.log, ~/mikrotik_backup.log);
#   • настройки расписания и последние бэкапы.
#
# Использование:
#   bash tg/mkgit_doctor.sh            # только диагностика (безопасно)
#   sudo bash tg/mkgit_doctor.sh --fix # + исправить владельца файлов
#
# Код возврата: 0 — проблем нет, 1 — есть замечания, 2 — есть ошибки.
# =============================================================================

set -uo pipefail

DK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DK_REPO_DIR="$(cd "$DK_SELF_DIR/.." && pwd)"
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

WARN=0
ERR=0

ok()   { printf '  ✅ %s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*"; WARN=$((WARN + 1)); }
bad()  { printf '  ❌ %s\n' "$*"; ERR=$((ERR + 1)); }
sec()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Кто должен владеть файлами: владелец каталога репозитория
DK_OWNER="$(stat -c %U "$DK_REPO_DIR" 2>/dev/null || echo "?")"
DK_RUN_USER="$(id -un)"

printf 'MikroGit doctor\n'
printf 'Репозиторий : %s\n' "$DK_REPO_DIR"
printf 'Владелец    : %s\n' "$DK_OWNER"
printf 'Запущено от : %s%s\n' "$DK_RUN_USER" "$([ "$DK_RUN_USER" = "root" ] && echo ' (root!)')"
[ "$FIX" = "1" ] && printf 'Режим       : ИСПРАВЛЕНИЕ (--fix)\n'

# --- 1. Владелец файлов -------------------------------------------------------
sec "1. Владелец файлов репозитория"
ROOT_OWNED=$(find "$DK_REPO_DIR" \( -path '*/.git/objects' -o -path '*/.git/index' -o -path '*/.git/FETCH_HEAD' \) -prune -o -user root -print 2>/dev/null | head -20)
if [ -n "$ROOT_OWNED" ]; then
    bad "есть файлы, принадлежащие root (из-за запуска через sudo/root):"
    printf '%s\n' "$ROOT_OWNED" | sed 's/^/       /' | head -10
    [ "$(printf '%s\n' "$ROOT_OWNED" | wc -l)" -gt 10 ] && echo "       … (список обрезан)"
    echo "     Симптомы: git пишет «dubious ownership» или «cannot open .git/FETCH_HEAD: Permission denied»."
    if [ "$FIX" = "1" ] && [ "$DK_RUN_USER" = "root" ] && [ "$DK_OWNER" != "root" ]; then
        chown -R "$DK_OWNER:$DK_OWNER" "$DK_REPO_DIR" && ok "владелец исправлен на $DK_OWNER"
    else
        echo "     Исправление:  sudo chown -R $DK_OWNER:$DK_OWNER $DK_REPO_DIR"
        echo "     (или запустите: sudo bash tg/mkgit_doctor.sh --fix)"
    fi
else
    ok "все файлы принадлежат $DK_OWNER"
fi

# --- 2. Права на запись -------------------------------------------------------
sec "2. Права на запись (логи, бэкапы, .git)"
DK_LOG_FILE=""
if [ -f "$DK_SELF_DIR/tg_bot_config.sh" ]; then
    # shellcheck source=/dev/null
    source "$DK_SELF_DIR/tg_bot_config.sh" 2>/dev/null || true
    DK_LOG_FILE="${LOG_FILE:-}"
fi
DK_LOG_DIR="$(dirname "${DK_LOG_FILE:-$DK_REPO_DIR/logs/mk_backup.log}")"
DK_BCK_DIR="${BACKUP_DIR:-$DK_REPO_DIR/bckp}"

for d in "$DK_LOG_DIR" "$DK_BCK_DIR" "$DK_REPO_DIR/.git"; do
    if [ ! -d "$d" ]; then
        warn "нет каталога $d (создастся автоматически)"
        continue
    fi
    if [ -w "$d" ]; then
        ok "запись в ${d/#$HOME/~} разрешена"
    else
        bad "нет прав на запись в ${d/#$HOME/~} (владелец: $(stat -c '%U:%G' "$d" 2>/dev/null))"
        echo "     Исправление:  sudo chown -R $DK_OWNER:$DK_OWNER $DK_REPO_DIR"
    fi
done

# --- 3. Git-репозиторий -------------------------------------------------------
sec "3. Git"
if command -v git > /dev/null 2>&1; then
    if git -C "$DK_REPO_DIR" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
        ok "ветка: $(git -C "$DK_REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        ok "коммит: $(git -C "$DK_REPO_DIR" log --oneline -1 2>/dev/null)"
    else
        bad "git не может открыть репозиторий (см. разделы 1–2)"
    fi
    BADCFG=$(git config --global --list 2>/dev/null | grep -i 'safe.directory' | head -5)
    if [ -n "$BADCFG" ]; then
        warn "в ~/.gitconfig есть записи safe.directory:"
        printf '%s\n' "$BADCFG" | sed 's/^/       /'
        echo "     Лечится не костылём, а владельцем файлов (раздел 1)."
        echo "     Убрать:  git config --global --unset-all safe.directory"
    else
        ok "safe.directory-костыли не нужны и не прописаны"
    fi
else
    bad "git не установлен"
fi

# --- 4. SSH-ключ --------------------------------------------------------------
sec "4. SSH-ключ для роутеров"
DK_KEY="${SSH_KEY:-$HOME/.ssh/mk_key}"
if [ -n "${SSH_KEY:-}" ]; then
    ok "SSH_KEY из конфига: $SSH_KEY"
fi
if [ -f "$DK_KEY" ]; then
    ok "приватный ключ найден: $DK_KEY"
    if [ -f "$DK_KEY.pub" ]; then
        ok "публичный ключ: $(cut -c1-40 "$DK_KEY.pub")…"
    else
        warn "нет $DK_KEY.pub (без него ключ не добавить на роутер)"
    fi
    PERM=$(stat -c %a "$DK_KEY" 2>/dev/null)
    [ "$PERM" = "600" ] && ok "права 600" || warn "права $PERM — рекомендуется 600 (chmod 600 $DK_KEY)"
    # есть ли ключи вообще
    OTHER_KEYS=$(ls -1 "$HOME"/.ssh/*.pub 2>/dev/null | head -5)
    [ -n "$OTHER_KEYS" ] && echo "     Другие ключи в ~/.ssh: $(printf '%s ' $OTHER_KEYS)"
else
    warn "ключ $DK_KEY не найден"
    echo "     Варианты: создать новый  ssh-keygen -t rsa -b 4096 -f ~/.ssh/mk_key -N ''"
    echo "               или задать существующий в tg/tg_bot_config.sh: export SSH_KEY=~/.ssh/ключ"
    ls -1 "$HOME"/.ssh/id_* 2>/dev/null | sed 's/^/       есть: /'
fi
if [ "$DK_RUN_USER" = "root" ]; then
    bad "запуск от root: HOME=/root, ключ будет искаться в /root/.ssh — работайте от $DK_OWNER"
fi

# --- 5. Процессы и локи -------------------------------------------------------
sec "5. Процессы бота и блокировки"
BOT_PIDS=$(pgrep -f 'mk_tg_bot\.sh' 2>/dev/null || true)
if [ -n "$BOT_PIDS" ]; then
    for p in $BOT_PIDS; do
        printf '  • бот pid=%s: %s\n' "$p" "$(ps -o user=,etime=,args= -p "$p" 2>/dev/null | sed 's/^ *//' | cut -c1-90)"
    done
    [ "$(printf '%s\n' "$BOT_PIDS" | grep -c .)" -gt 1 ] && bad "запущено несколько копий бота — оставьте одну"
else
    warn "бот не запущен"
fi
SCH_PIDS=$(pgrep -f 'mk_schedule\.sh (daemon|start)' 2>/dev/null || true)
[ -n "$SCH_PIDS" ] && ok "планировщик работает (pid=$(echo $SCH_PIDS | tr ' ' ','))" || warn "планировщик не запущен"

DK_LOCK="$(dirname "${DK_LOG_FILE:-$DK_REPO_DIR/logs/mk_backup.log}")/mk_tg_bot.lock"
[ -f "$DK_LOCK" ] && warn "файл лока существует: ${DK_LOCK/#$HOME/~} (владелец: $(stat -c %U "$DK_LOCK"))" \
                   || ok "lock-файла бота нет"

for d in update_state deploy_state harden_state schedule; do
    st="$(dirname "${DK_LOG_FILE:-$DK_REPO_DIR/logs/mk_backup.log}")/$d"
    [ -d "$st" ] || continue
    for lock in "$st"/lock_*; do
        [ -d "$lock" ] || continue
        pid=$(cat "$lock/pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            warn "активный лок $(basename "$lock") (pid=$pid)"
        else
            rm -rf "$lock" && ok "снят мёртвый лок $(basename "$lock")"
        fi
    done
done

# --- 6. systemd ---------------------------------------------------------------
sec "6. systemd"
if command -v systemctl > /dev/null 2>&1; then
    for u in mkgit-bot mkgit-schedule; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^$u.service"; then
            st=$(systemctl is-active "$u" 2>/dev/null)
            [ "$st" = "active" ] && ok "$u.service: active" || warn "$u.service: $st"
        else
            warn "$u.service не установлен (см. README, раздел systemd)"
        fi
    done
else
    warn "systemctl недоступен"
fi

# --- 7. Мусор в домашнем каталоге --------------------------------------------
sec "7. Мусор в $HOME"
DKJ=$(find "$HOME" -maxdepth 1 -name 'deploy_key_*.log' 2>/dev/null | wc -l)
[ "$DKJ" -gt 0 ] && warn "~/deploy_key_*.log: $DKJ шт. (чистятся автоматически, старше MKC_HOME_LOG_DAYS)" \
                 || ok "старых deploy_key-логов нет"
[ -f "$HOME/mikrotik_backup.log" ] && warn "устаревший ~/mikrotik_backup.log (переносится в logs/legacy/)" \
                                  || ok "~/mikrotik_backup.log отсутствует"

# --- 8. Бэкапы и расписание ---------------------------------------------------
sec "8. Бэкапы и расписание"
if [ -d "$DK_BCK_DIR" ]; then
    DEV_DIRS=$(find "$DK_BCK_DIR" -mindepth 1 -maxdepth 1 -type d ! -name pre_update 2>/dev/null | wc -l)
    BK=$(find "$DK_BCK_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.backup' 2>/dev/null | wc -l)
    RSC=$(find "$DK_BCK_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.rsc' 2>/dev/null | wc -l)
    PRE=$(find "$DK_BCK_DIR" -mindepth 2 -maxdepth 2 -type f -name '*pre_update*' 2>/dev/null | wc -l)
    ok "устройств: $DEV_DIRS • .backup: $BK • pre_update: $PRE • старых .rsc: $RSC"
    EMPTY=$(find "$DK_BCK_DIR" -mindepth 2 -maxdepth 2 -name '*.backup' -size -512c 2>/dev/null | wc -l)
    [ "$EMPTY" -gt 0 ] && warn "подозрительно маленьких .backup (<512 байт): $EMPTY"
    ROOTF=$(find "$DK_BCK_DIR" -user root -type f 2>/dev/null | wc -l)
    [ "$ROOTF" -gt 0 ] && bad "в bckp/ есть файлы, принадлежащие root: $ROOTF"
else
    warn "каталог бэкапов отсутствует: $DK_BCK_DIR"
fi
DK_SCHED="$(dirname "${DK_LOG_FILE:-$DK_REPO_DIR/logs/mk_backup.log}")/schedule/schedule.conf"
if [ -f "$DK_SCHED" ]; then
    ok "расписание задано:"
    grep -E '^(ENABLED|BACKUP_HOUR|BACKUP_MINUTE|UPDATE_ENABLED|UPDATE_WEEKDAY|UPDATE_HOUR|UPDATE_MINUTE|UPDATE_MODE)=' "$DK_SCHED" | sed 's/^/       /'
else
    warn "logs/schedule/schedule.conf ещё нет (создастся из настроек по умолчанию)"
fi

# --- Итог ---------------------------------------------------------------------
printf '\n\033[1mИтог\033[0m\n'
printf '  ошибок: %s, замечаний: %s\n' "$ERR" "$WARN"
if [ "$ERR" -gt 0 ]; then
    echo "  → исправьте ошибки выше (чаще всего достаточно: sudo chown -R $DK_OWNER:$DK_OWNER $DK_REPO_DIR)"
    exit 2
elif [ "$WARN" -gt 0 ]; then
    echo "  → критичных проблем нет, посмотрите замечания"
    exit 1
else
    echo "  → всё в порядке"
    exit 0
fi

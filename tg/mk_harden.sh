#!/bin/bash
# =============================================================================
# mk_harden.sh — серверный прогон harden_services.rsc по роутерам из devices.conf
# (механизм как у деплоя: ssh, строго по одному устройству, с отчётом).
# -----------------------------------------------------------------------------
# На каждом роутере:
#   1) заливает harden_services.rsc (scp) и выполняет /import file-name=...;
#   2) собирает НОВЫЙ ssh-порт из маркера  HARDEN_OK_SSH_PORT=NNNN;
#   3) проверяет, что роутер реально отвечает по ssh на новом порту;
#   4) обновляет 3-е поле в devices.conf (имя:ip:PORT:user:описание).
#
# Использование:
#   bash mk_harden.sh                 # справка
#   bash mk_harden.sh all             # все устройства по очереди
#   bash mk_harden.sh <device>        # одно устройство
#   bash mk_harden.sh --dry-run       # только план (без изменений)
#   bash mk_harden.sh --dry-run <device>
#
# Переменные окружения (можно в tg_bot_config.sh или в команде):
#   CONFIG_FILE, SSH_KEY/HARDEN_KEY, HARDEN_RSC, HARDEN_SSH_TIMEOUT,
#   HARDEN_DEVICE_TIMEOUT, HARDEN_SKIP_ADDR_CHECK, LOG_FILE.
#
# ПРЕДУСЛОВИЯ:
#   * выполнен деплой ключа/прав (mk_deploy.sh): пользователь из 4-го поля
#     devices.conf заходит по ssh ключом и имеет права
#     ssh,read,write,test,reboot,policy,ftp — иначе /ip service менять не даст,
#     а scp-загрузку .rsc RouterOS отвергнет (file-доступ даёт только policy ftp);
#   * адрес ЭТОГО сервера входит в allowFrom (по умолчанию 10.20.9.11,
#     192.168.10.89) — иначе после прогона сервер потеряет ssh к роутеру
#     (бэкапы/обновления/деплой встанут!). Обёртка это проверяет и отказывается
#     работать, если сервер не в списке (override: HARDEN_SKIP_ADDR_CHECK=1).
#
# Логика безопасности: текущая ssh-сессия при смене порта НЕ обрывается,
# поэтому обёртка успевает подтвердить новый порт и обновить devices.conf.
# =============================================================================
set -uo pipefail

HARDEN_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Настройки (окружение > дефолты) -----------------------------------------
HARDEN_RSC="${HARDEN_RSC:-$HARDEN_SELF_DIR/harden_services.rsc}"
HARDEN_KEY="${HARDEN_KEY:-${SSH_KEY:-$HOME/.ssh/mk_key}}"
HARDEN_SSH_TIMEOUT="${HARDEN_SSH_TIMEOUT:-20}"       # на одно соединение, сек
HARDEN_DEVICE_TIMEOUT="${HARDEN_DEVICE_TIMEOUT:-150}" # на весь прогон одного устройства
HARDEN_SKIP_ADDR_CHECK="${HARDEN_SKIP_ADDR_CHECK:-0}" # 1 = не проверять адрес сервера
HARDEN_RFILE="harden_services.rsc"                    # имя файла на роутере

harden_cfg_file() { echo "${CONFIG_FILE:-/home/aionis/MikroGit/devices.conf}"; }
harden_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] HARDEN: $*" | tee -a "${LOG_FILE:-/tmp/mk_harden.log}"; }
harden_err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] HARDEN ERROR: $*" | tee -a "${LOG_FILE:-/tmp/mk_harden.log}" >&2; }

# Каталог состояния (лок), как у деплоя/обновлений — рядом с логом
harden_state_dir() { echo "${HARDEN_STATE_DIR:-$(dirname "${LOG_FILE:-/tmp/mk_harden.log}")/harden_state}"; }
harden_ensure_dirs() { mkdir -p "$(harden_state_dir)" 2>/dev/null || true; }

# Флаг остановки фонового хардненинга (кнопка «⏹ Остановить» в боте).
# Воркер проверяет между устройствами и завершается аккуратно.
harden_cancel_file()      { echo "$(harden_state_dir)/stop_harden"; }
harden_cancel_set()       { : > "$(harden_cancel_file)"; }
harden_cancel_clear()     { rm -f "$(harden_cancel_file)"; }
harden_cancel_requested() { [ -f "$(harden_cancel_file)" ]; }

harden_lock_acquire() {
    local wait_max="${1:-5}" lockdir
    lockdir="$(harden_state_dir)/lock_harden"
    harden_ensure_dirs
    local i=0 pid=""
    while [ -d "$lockdir" ]; do
        pid=$(cat "$lockdir/pid" 2>/dev/null)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$lockdir"; continue
        fi
        [ $i -ge "$wait_max" ] && return 1
        sleep 1; i=$((i+1))
    done
    mkdir -p "$lockdir" && echo "$$" > "$lockdir/pid"
    return 0
}
harden_lock_release() { rm -rf "$(harden_state_dir)/lock_harden" 2>/dev/null || true; }

# Отправка в Telegram (только если запущено как worker бота; иначе — в лог)
harden_send() {
    if declare -f tg_send_message > /dev/null 2>&1        && [ -n "${TELEGRAM_CHAT_ID:-}" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
        tg_send_message "$TELEGRAM_CHAT_ID" "$1"
    else
        harden_log "(tg недоступен) $1"
    fi
}

# Как harden_send, но с кнопкой «⏹ Остановить хардненинг» (на свежих сообщениях
# воркера, пока идёт обработка).
harden_send_kb() {
    local kb='[[{"text":"⏹ Остановить хардненинг","callback_data":"hdn_stop"}]]'
    if declare -f tg_send_keyboard > /dev/null 2>&1        && [ -n "${TELEGRAM_CHAT_ID:-}" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
        tg_send_keyboard "$TELEGRAM_CHAT_ID" "$1" "$kb"
    else
        harden_log "(tg недоступен) $1"
    fi
}

# Загрузить конфиг и TG-хелперы, если работаем как worker бота
harden_tg_setup() {
    if [ -f "$HARDEN_SELF_DIR/tg_bot_config.sh" ]; then
        # shellcheck source=tg_bot_config.sh
        source "$HARDEN_SELF_DIR/tg_bot_config.sh"
        if ! declare -f tg_send_message > /dev/null 2>&1 && [ -f "$HARDEN_SELF_DIR/tg_api_helpers.sh" ]; then
            # shellcheck source=tg_api_helpers.sh
            source "$HARDEN_SELF_DIR/tg_api_helpers.sh"
        fi
    fi
}

# SSH-опции (приём как в deploy_key.sh/mk_updates.sh)
harden_ssh_opts() {
    local tmo="${1:-$HARDEN_SSH_TIMEOUT}"
    echo -o PubkeyAcceptedAlgorithms=+ssh-rsa \
         -o HostKeyAlgorithms=+ssh-rsa \
         -o BatchMode=yes \
         -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null \
         -o ConnectTimeout="$tmo" \
         -o LogLevel=ERROR
}

# -----------------------------------------------------------------------------
# Парсим allowFrom и политику из самого .rsc (единый источник правды)
# -----------------------------------------------------------------------------
harden_allow_from() {
    sed -nE 's/^[[:space:]]*:local allowFrom "([^"]*)".*/\1/p' "$HARDEN_RSC" | head -n1
}

# Есть ли адрес этого сервера в allowFrom?
harden_server_allowed() {
    local list="$1" ips entry
    ips=$(hostname -I 2>/dev/null)
    [ -z "$ips" ] && return 1
    local IFS=,
    for entry in $list; do
        entry=$(echo "$entry" | xargs)
        [ -z "$entry" ] && continue
        if echo " $ips " | grep -q " $entry "; then
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# Получить строку устройства name:ip:port:user:desc
# -----------------------------------------------------------------------------
harden_get_line() {
    local name="$1" cfg line
    cfg="$(harden_cfg_file)"
    [ -f "$cfg" ] || return 1
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [ -z "$line" ] && continue
        line=$(echo "$line" | tr -d '\r')
        if [ "$(echo "$line" | cut -d: -f1)" = "$name" ]; then
            echo "$line"; return 0
        fi
    done < "$cfg"
    return 1
}

# Обновить 3-е поле (ssh-порт) у строки устройства в devices.conf.
# Комментарии и пустые строки сохраняются как есть.
harden_update_port() {
    local name="$1" newport="$2" cfg tmp
    cfg="$(harden_cfg_file)"
    tmp="${cfg}.tmp.$$"
    awk -v nm="$name" -v np="$newport" -F: '
        BEGIN { OFS=":"; changed=0 }
        /^[ \t]*#/ || /^[ \t]*$/ { print; next }
        $1 == nm { $3 = np; changed = 1 }
        { print }
        END { exit (changed ? 0 : 1) }
    ' "$cfg" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$cfg"
    return 0
}

# -----------------------------------------------------------------------------
# Обработка ОДНОГО устройства. Возвращает rc: 0 - ок; иначе ошибка.
# -----------------------------------------------------------------------------
harden_one() {
    local name="$1"
    local cfg line ip port user desc
    cfg="$(harden_cfg_file)"
    line=$(harden_get_line "$name") || {
        harden_err "Устройство '$name' не найдено в $cfg"
        return 1
    }
    IFS=':' read -r _ ip port user _ <<< "$line"
    port="${port:-22}"
    [ -n "$user" ] || {
        harden_err "$name: пустой user в devices.conf — пропуск"
        harden_send "❌ <b>$name</b>: пустой user в devices.conf — пропуск"
        return 1
    }
    [ -f "$HARDEN_KEY" ] || {
        harden_err "$name: нет приватного ключа $HARDEN_KEY — пропуск"
        harden_send "❌ <b>$name</b>: нет приватного ключа $HARDEN_KEY — пропуск"
        return 1
    }

    harden_log ">>> [$name] $ip (ssh:$port, user=$user): начинаю..."
    harden_send_kb "🛡 <b>$name</b> ($ip): запускаю хардненинг (ssh:$port)…"

    local ssh_opts
    read -r -a ssh_opts <<< "$(harden_ssh_opts "$HARDEN_SSH_TIMEOUT")"

    # 0) живой ли роутер по ssh до изменений (быстрая диагностика)
    if ! timeout "${HARDEN_SSH_TIMEOUT}" ssh "${ssh_opts[@]}" -p "$port" -i "$HARDEN_KEY" \
            "$user@$ip" "/system identity print" > /dev/null 2>&1; then
        harden_err "[$name] $ip — НЕТ доступа по ssh:$port (ключ/пользователь/права? Выполнен ли деплой?) — пропуск"
        harden_send "❌ <b>$name</b>: нет доступа по ssh:$port (выполнен ли деплой ключа?) — пропуск"
        return 1
    fi

    # 0.5) локальная проверка .rsc перед заливкой: пустой файл или «не тот» файл
    #      дают ровно этот симптом (import без вывода, rc=0, маркера нет)
    if [ ! -s "$HARDEN_RSC" ]; then
        harden_err "[$name] $HARDEN_RSC пуст (0 байт) — проверьте файл на сервере"
        harden_send "❌ <b>$name</b>: $HARDEN_RSC пуст (0 байт) — залейте полный harden_services.rsc"
        return 1
    fi
    if ! grep -q 'HARDEN_OK_SSH_PORT=' "$HARDEN_RSC"; then
        harden_err "[$name] в $HARDEN_RSC нет маркера HARDEN_OK_SSH_PORT= — не тот файл?"
        harden_send "❌ <b>$name</b>: в $HARDEN_RSC нет маркера HARDEN_OK_SSH_PORT= — не тот файл?"
        return 1
    fi

    # 1) заливаем .rsc на роутер (stderr scp сохраняем: без него причина
    #    отказа не видна — чаще всего нет политики ftp у пользователя)
    local scp_opts scp_err
    read -r -a scp_opts <<< "$(harden_ssh_opts "$HARDEN_SSH_TIMEOUT")"
    scp_err="$(timeout 60 scp "${scp_opts[@]}" -P "$port" -i "$HARDEN_KEY" \
            "$HARDEN_RSC" "$user@$ip:$HARDEN_RFILE" 2>&1)"
    if [ $? -ne 0 ]; then
        harden_err "[$name] $ip — не удалось загрузить harden_services.rsc по scp — пропуск"
        harden_err "[$name] scp: $(printf '%s' "$scp_err" | tail -n 3 | sed 's/^/    /')"
        harden_send "❌ <b>$name</b>: не удалось загрузить скрипт по scp — пропуск"
        return 1
    fi
    # прогресс: импорт занимает до HARDEN_DEVICE_TIMEOUT (пауза на отмену +
    # выполнение) — без этого статуса шаг выглядит «зависшим»
    harden_send "📤 <b>$name</b>: скрипт загружен — выполняю на роутере (до ~${HARDEN_DEVICE_TIMEOUT} с)…"

    # 2) импорт и выполнение (внутри .rsc пауза abortSec на отмену)
    local out rc newport
    out=$(timeout "${HARDEN_DEVICE_TIMEOUT}" ssh "${ssh_opts[@]}" -p "$port" -i "$HARDEN_KEY" \
            "$user@$ip" "/import file-name=$HARDEN_RFILE" 2>&1)
    rc=$?

    # 3) уборка файла на роутере (в т.ч. если import упал)
    timeout "${HARDEN_SSH_TIMEOUT}" ssh "${ssh_opts[@]}" -p "$port" -i "$HARDEN_KEY" \
        "$user@$ip" "/file remove [find name=$HARDEN_RFILE]" > /dev/null 2>&1 || true

    # 4) новый порт из маркера
    newport=$(printf '%s\n' "$out" | grep -oE 'HARDEN_OK_SSH_PORT=[0-9]+' | tail -n1 | cut -d= -f2)
    if [ "$rc" -ne 0 ] || [ -z "$newport" ]; then
        harden_err "[$name] $ip — скрипт на роутере не отработал (rc=$rc). Хвост вывода:"
        {
            printf '%s\n' "$out" | tail -n 12 | sed 's/^/    /'
            # диагностика: есть ли файл на роутере и какой у него размер
            echo "    --- диагностика: файл на роутере ---"
            timeout "${HARDEN_SSH_TIMEOUT}" ssh "${ssh_opts[@]}" -p "$port" -i "$HARDEN_KEY" \
                "$user@$ip" "/file print" 2>&1 \
                | grep -i "$HARDEN_RFILE" | sed 's/^/    /' \
                || echo "    (в /file print файла '$HARDEN_RFILE' нет)"
        } | tee -a "${LOG_FILE:-/tmp/mk_harden.log}" >&2 || true
        harden_send "❌ <b>$name</b>: скрипт на роутере не отработал (rc=$rc) — порт НЕ менялся"
        return 1
    fi
    case "$newport" in *[!0-9]*|'')
        harden_err "[$name] маркер порта повреждён: '$newport'"
        harden_send "❌ <b>$name</b>: маркер порта повреждён: '$newport'"
        return 1;;
    esac

    # 5) подтверждаем: роутер отвечает по ssh на НОВОМ порту
    if ! timeout "${HARDEN_SSH_TIMEOUT}" ssh "${ssh_opts[@]}" -p "$newport" -i "$HARDEN_KEY" \
            "$user@$ip" "/system identity print" > /dev/null 2>&1; then
        harden_err "[$name] $ip — новый порт $newport НЕ отвечает по ssh (проверьте allowFrom!) — devices.conf НЕ меняю"
        harden_send "❌ <b>$name</b>: новый порт $newport не отвечает — devices.conf НЕ менял"
        return 1
    fi

    # 6) обновляем devices.conf
    local bak
    bak="${cfg}.bak.harden.$(date +%Y%m%d_%H%M%S)"
    cp "$cfg" "$bak" 2>/dev/null || true
    if harden_update_port "$name" "$newport"; then
        harden_log "✅ [$name] $ip: ssh-порт $port -> $newport, devices.conf обновлён (бэкап: $(basename "$bak"))"
        harden_send "✅ <b>$name</b>: ssh-порт $port → <b>$newport</b>; devices.conf обновлён (доступ по ssh ограничен списком allowFrom)"
        return 0
    else
        harden_err "[$name] не удалось обновить devices.conf (строка не найдена?)"
        harden_send "❌ <b>$name</b>: ssh-порт сменён, но не удалось обновить devices.conf (строка не найдена?)"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Режимы: all / <device> / --dry-run
# -----------------------------------------------------------------------------
harden_dry_run() {
    local scope="${1:-all}"
    local cfg names=() line name ip port user
    cfg="$(harden_cfg_file)"
    [ -f "$cfg" ] || { harden_err "Нет devices.conf: $cfg"; return 1; }
    [ -f "$HARDEN_RSC" ] || { harden_err "Нет harden_services.rsc: $HARDEN_RSC (задайте HARDEN_RSC)"; return 1; }
    local allow
    allow="$(harden_allow_from)"
    harden_log "ПЛАН (dry-run): .rsc=$HARDEN_RSC, allowFrom='$allow', ключ=$HARDEN_KEY"
    if [ "$HARDEN_SKIP_ADDR_CHECK" != "1" ]; then
        if harden_server_allowed "$allow"; then
            harden_log "Адрес этого сервера в allowFrom — ок."
        else
            harden_err "ВНИМАНИЕ: адрес этого сервера НЕ в allowFrom ('$allow'). После применения доступ по ssh к роутеру пропадёт. Проверьте список или установите HARDEN_SKIP_ADDR_CHECK=1."
        fi
    fi

    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [ -z "$line" ] && continue
        line=$(echo "$line" | tr -d '\r')
        name="${line%%:*}"
        [ -z "$name" ] && continue
        if [ "$scope" != "all" ] && [ "$name" != "$scope" ]; then continue; fi
        IFS=':' read -r _ ip port user _ <<< "$line"
        echo "  - $name  $ip  ssh:${port:-22}  user=$user  ->  случайный порт + allowFrom + devices.conf"
    done < "$cfg"
    return 0
}

harden_all() {
    local cfg names=() line name rc ok=0 err=0
    cfg="$(harden_cfg_file)"
    [ -f "$cfg" ] || { harden_err "Нет devices.conf: $cfg"; return 1; }
    harden_cancel_clear

    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [ -z "$line" ] && continue
        line=$(echo "$line" | tr -d '\r')
        name="${line%%:*}"
        [ -n "$name" ] && names+=("$name")
    done < "$cfg"
    local total=${#names[@]}
    [ "$total" = 0 ] && { harden_err "Нет устройств в $cfg"; return 1; }

    harden_log "Хардненинг сервисов: устройств $total. По одному; новый ssh-порт каждого сразу пишется в devices.conf."

    local n=0 stopped=0
    for name in "${names[@]}"; do
        if harden_cancel_requested; then
            harden_cancel_clear
            stopped=1
            harden_log "Остановлено пользователем (обработано $n/$total)"
            break
        fi
        n=$((n+1))
        if harden_one "$name"; then ok=$((ok+1)); else err=$((err+1)); fi
        harden_log "[$n/$total] $name: обработан. Перехожу к следующему…"
    done
    harden_log "ИТОГ ($n/$total): успешно ✅ $ok • ошибки ❌ $err"
    if [ "$stopped" = "1" ]; then
        harden_send "🛑 <b>Хардненинг остановлен пользователем</b> (после $n/$total): успешно ✅ $ok • ошибки ❌ $err"
    else
        harden_send "📊 <b>Хардненинг завершён</b> ($n/$total): успешно ✅ $ok • ошибки ❌ $err"
    fi
    harden_cancel_clear
    return "$err"
}

# -----------------------------------------------------------------------------
# Один прогон под локом (и all, и одиночное устройство): не даёт запустить два
# хардненинга одновременно и проверяет, что сервер не потеряет доступ.
harden_guarded() {
    local scope="$1" rc
    harden_ensure_dirs
    if ! harden_lock_acquire 5; then
        harden_err "Хардненинг уже выполняется в фоне. Дождитесь завершения."
        harden_send "⏳ Хардненинг уже выполняется в фоне. Дождитесь завершения."
        return 1
    fi
    [ -f "$HARDEN_RSC" ] || {
        harden_err "Нет $HARDEN_RSC (задайте HARDEN_RSC)"
        harden_send "❌ <b>Хардненинг</b>: нет $HARDEN_RSC (задайте HARDEN_RSC)"
        harden_lock_release; return 1
    }
    [ -f "$HARDEN_KEY" ] || {
        harden_err "Нет приватного ключа $HARDEN_KEY (задайте HARDEN_KEY)"
        harden_send "❌ <b>Хардненинг</b>: нет приватного ключа $HARDEN_KEY (задайте HARDEN_KEY)"
        harden_lock_release; return 1
    }

    if [ "$HARDEN_SKIP_ADDR_CHECK" != "1" ]; then
        local allow
        allow="$(harden_allow_from)"
        if harden_server_allowed "$allow"; then
            harden_log "Адрес этого сервера есть в allowFrom ('$allow')."
        else
            harden_err "СТОП: адрес этого сервера НЕ в allowFrom ('$allow'). После смены порта сервер потеряет ssh к роутерам. Проверьте allowFrom в harden_services.rsc или задайте HARDEN_SKIP_ADDR_CHECK=1."
            harden_send "🛑 Хардненинг отменён: адрес сервера не в списке <code>allowFrom</code> ($allow) — после прогона сервер потерял бы ssh к роутерам. Исправьте список или подтвердите обход."
            harden_lock_release
            return 3
        fi
    fi

    if [ "$scope" = "all" ]; then
        harden_all
        rc=$?
    else
        local cfg; cfg="$(harden_cfg_file)"
        if ! harden_get_line "$scope" > /dev/null 2>&1; then
            harden_err "Устройство '$scope' не найдено в $cfg."
            harden_send "❌ <b>$scope</b>: устройство не найдено в $cfg."
            harden_cancel_clear
            harden_lock_release
            return 1
        fi
        if harden_cancel_requested; then
            harden_cancel_clear
            harden_send "⏹ Хардненинг остановлен пользователем."
            harden_lock_release
            return 0
        fi
        harden_one "$scope"
        rc=$?
        # страховка: если harden_one вернулся с ошибкой, но по какой-то причине
        # не отправил финальное сообщение — шлём итог здесь
        if [ "$rc" -ne 0 ]; then
            harden_send "❌ <b>$scope</b>: хардненинг завершился с ошибкой (rc=$rc). Детали в run-логе."
        fi
    fi
    harden_cancel_clear
    harden_lock_release
    return "$rc"
}

# -----------------------------------------------------------------------------
# CLI (в т.ч. запуск из бота: bash mk_harden.sh all | <device>)
# -----------------------------------------------------------------------------
harden_main() {
    local action="${1:-}"
    case "$action" in
        -h|--help|"")
            echo "Использование: mk_harden.sh {all | <device> | --dry-run [all|<device>]}"
            echo "Env: CONFIG_FILE, SSH_KEY/HARDEN_KEY, HARDEN_RSC, HARDEN_SSH_TIMEOUT,"
            echo "     HARDEN_DEVICE_TIMEOUT, HARDEN_SKIP_ADDR_CHECK, LOG_FILE"
            echo "Пример:  bash mk_harden.sh all"
            return 0 ;;
    esac
    # worker бота: подхватываем tg-конфиг/хелперы (LOG_FILE, токен, чат)
    harden_tg_setup
    mkdir -p "$(dirname "${LOG_FILE:-/tmp/mk_harden.log}")" 2>/dev/null || true
    harden_ensure_dirs
    echo "$$" > "$(harden_state_dir)/worker_last.pid" 2>/dev/null || true
    harden_log "Worker started: $* (pid=$$)"
    # мгновенное подтверждение в TG, что воркер жив (и где его лог)
    if [[ "$action" != -* ]]; then
        harden_send "🛡 Воркер хардненинга запущен (pid=$$). Run-лог: <code>$(harden_state_dir)/run_${action}.log</code>"
    fi

    if [ "$action" = "--dry-run" ]; then
        harden_dry_run "${2:-all}"
        return $?
    fi
    if [[ "$action" == -* ]]; then
        echo "Неизвестный аргумент: $action (см. --help)" >&2
        return 2
    fi

    local rc
    case "$action" in
        all)
            harden_guarded all ;;
        *)
            harden_guarded "$action" ;;
    esac
    rc=$?
    harden_log "Worker finished: $* (pid=$$, rc=$rc)"
    # копия последнего прогона — как у деплоя: harden_state/last_run.log
    if [[ "$action" != -* ]] && [ -f "$(harden_state_dir)/run_${action}.log" ]; then
        cp "$(harden_state_dir)/run_${action}.log" "$(harden_state_dir)/last_run.log" 2>/dev/null || true
    fi
    return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    harden_main "$@"
    exit $?
fi


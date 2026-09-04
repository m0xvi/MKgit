#!/bin/bash
# =============================================================================
# MikroTik RouterOS Update Manager (Proxy-Aware Telegram Worker / Library)
# =============================================================================
# Назначение:
#   - проверка доступных обновлений RouterOS через сам роутер
#     (/system package update check-for-updates);
#   - автоопределение мажорной ветки (v6 / v7) и обновление В РАМКАХ своей
#     ветки (6.x -> 6.x, 7.x -> 7.x; кросс-апгрейд 6->7 НЕ выполняется);
#   - скачивание обновления командой download и установка через reboot;
#   - перед установкой — резервная копия конфигурации через MikroGit.sh;
#   - автообновление RouterBOOT firmware (/system routerboard upgrade)
#     сразу после успешного обновления RouterOS (UPDATE_ROUTERBOARD_AUTO)
#     либо отдельным запуском: mk_updates.sh routerboard <device>;
#   - отправка прогресса и итогов в Telegram.
#
# Файл может использоваться двумя способами:
#   1) как библиотека:  source tg/mk_updates.sh   (только функции)
#   2) как worker:      bash tg/mk_updates.sh check [all|device]
#                       bash tg/mk_updates.sh apply <device>
#
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
fi

# -----------------------------------------------------------------------------
# Настройки (могут быть заданы в tg_bot_config.sh / окружении)
# -----------------------------------------------------------------------------
# UPDATE_CHANNEL: stable | long-term | testing | "" (пусто — НЕ менять канал
# роутера, проверять в том канале, который настроен на самом роутере).
# Для единообразных проверок обычно задают stable.
UPDATE_CHANNEL="${UPDATE_CHANNEL:-}"

# Делать резервную копию конфигурации перед установкой (через BACKUP_SCRIPT)
UPDATE_BACKUP_BEFORE_APPLY="${UPDATE_BACKUP_BEFORE_APPLY:-1}"

# Общий таймаут на команду download (сек)
UPDATE_DOWNLOAD_TIMEOUT="${UPDATE_DOWNLOAD_TIMEOUT:-900}"

# Сколько ждать возвращения устройства после reboot (сек)
UPDATE_REBOOT_WAIT="${UPDATE_REBOOT_WAIT:-600}"

# Задержка между попытками опроса после reboot (сек)
UPDATE_REBOOT_POLL="${UPDATE_REBOOT_POLL:-10}"

# Автоматически обновлять RouterBOOT firmware (/system routerboard upgrade +
# reboot) сразу после успешного обновления RouterOS: 1 = да (по умолчанию),
# 0 = только сообщить пользователю о доступном обновлении (как раньше).
UPDATE_ROUTERBOARD_AUTO="${UPDATE_ROUTERBOARD_AUTO:-1}"

# Таймаут команды /system routerboard upgrade (прошивка пишется на flash, сек)
UPDATE_RB_TIMEOUT="${UPDATE_RB_TIMEOUT:-120}"

# Порядок обхода при «обновить все по очереди» (rup_worker_update_all):
# устройства группируются по этим префиксам имени (регистр не важен), внутри
# группы — в порядке devices.conf; остальные идут после всех групп.
UPDATE_ALL_PRIORITY="${UPDATE_ALL_PRIORITY:-AP SW GW}"

# Таймаут на одну SSH-команду при "коротких" операциях (resource/print/routerboard),
# сек. Защищает от зависания, если роутер отвечает, но команда "висит".
UPDATE_SSH_TIMEOUT="${UPDATE_SSH_TIMEOUT:-60}"

# Таймаут на check-for-updates: роутер ходит на upgrade.mikrotik.com, при плохом/
# отсутствующем доступе может висеть долго. По истечении устройство помечается
# ERROR и проверка идёт дальше.
UPDATE_CHECK_TIMEOUT="${UPDATE_CHECK_TIMEOUT:-150}"

# Каталог состояния (локи, кеш последней проверки) вычисляется ЛЕНИВО —
# после загрузки конфигурации (LOG_FILE), чтобы бот и его фоновые worker'ы
# использовали один и тот же каталог.
rup_state_dir() {
    echo "${UPDATE_STATE_DIR:-$(dirname "${LOG_FILE:-/tmp/mk_updates.log}")/update_state}"
}

# Автопроверка по расписанию (использует бот в run_bot)
UPDATE_AUTO_CHECK="${UPDATE_AUTO_CHECK:-1}"
UPDATE_AUTO_INTERVAL_HOURS="${UPDATE_AUTO_INTERVAL_HOURS:-24}"

# SSH опции (по образцу остальных скриптов репозитория)
RUP_SSH_OPTS="${RUP_SSH_OPTS:--o PubkeyAcceptedAlgorithms=+ssh-rsa -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=20 -o ServerAliveCountMax=20}"
RUP_SSH_BIN="${RUP_SSH_BIN:-ssh}"

# -----------------------------------------------------------------------------
# Служебное
# -----------------------------------------------------------------------------
RUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rup_log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] UPDATE: $*" | tee -a "${LOG_FILE:-/tmp/mk_updates.log}"; }
rup_err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] UPDATE ERROR: $*" | tee -a "${LOG_FILE:-/tmp/mk_updates.log}" >&2; }

rup_send() {
    # Отправка сообщения в чат (TG-хелперы должны быть загружены; иначе no-op)
    if declare -f tg_send_message > /dev/null 2>&1; then
        tg_send_message "${TELEGRAM_CHAT_ID:-}" "$1"
    else
        rup_log "(tg_send_message недоступен) $1"
    fi
}

rup_send_keyboard() {
    if declare -f tg_send_keyboard > /dev/null 2>&1; then
        tg_send_keyboard "${TELEGRAM_CHAT_ID:-}" "$1" "$2"
    else
        rup_log "(tg_send_keyboard недоступен) $1"
    fi
}

rup_ensure_dirs() {
    mkdir -p "$(rup_state_dir)" 2>/dev/null || true
}

rup_cfg_file() {
    # Читаем CONFIG_FILE: env > дефолт
    echo "${CONFIG_FILE:-/home/aionis/MikroGit/devices.conf}"
}

# -----------------------------------------------------------------------------
# Лок/разлок (простой, на файловых блокировках с защитой от "мёртвых" локов)
# -----------------------------------------------------------------------------
rup_lock_acquire() {
    # $1 - имя лока (без пути), $2 - таймаут в сек
    local lock_name="$1" wait_max="${2:-15}"
    local lockdir="$(rup_state_dir)/lock_$lock_name"
    rup_ensure_dirs
    local i=0 pid=""
    while [ -d "$lockdir" ]; do
        pid=$(cat "$lockdir/pid" 2>/dev/null)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            # Процесс-владелец умер — снимаем осиротевший лок
            rm -rf "$lockdir"
            continue
        fi
        [ $i -ge "$wait_max" ] && return 1
        sleep 1; i=$((i + 1))
    done
    mkdir -p "$lockdir" && echo "$$" > "$lockdir/pid"
    return 0
}

rup_lock_release() {
    rm -rf "$(rup_state_dir)/lock_$1" 2>/dev/null || true
}

rup_busy_message() {
    rup_send "⏳ Над <b>$1</b> уже выполняется операция. Дождитесь завершения."
}

# -----------------------------------------------------------------------------
# SSH: получить строку устройства из devices.conf
# -----------------------------------------------------------------------------
rup_get_line() {
    # $1 - device_name -> печатает "name:ip:port:user:description"
    local name="$1" cfg line
    cfg=$(rup_cfg_file)
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

# -----------------------------------------------------------------------------
# SSH: выполнить команду на роутере
# -----------------------------------------------------------------------------
RUP_SSH_ERR=""
rup_ssh_exec() {
    # $1 - device_name, $2 - команда RouterOS (один аргумент)
    # $3 - таймаут команды в сек (0/пусто = без ограничения)
    # stdout команды -> stdout; stderr -> в RUP_SSH_ERR; rc -> rc функции
    local name="$1" cmd="$2" tmo="${3:-0}"
    local line ip port user _
    RUP_SSH_ERR=""
    line=$(rup_get_line "$name") || { RUP_SSH_ERR="Устройство '$name' не найдено в devices.conf"; return 2; }
    IFS=':' read -r _ ip port user _ <<< "$line"

    local runner out rc
    if [ "$tmo" -gt 0 ] 2>/dev/null && command -v timeout > /dev/null 2>&1; then
        # shellcheck disable=SC2086
        out=$(timeout "$tmo" "$RUP_SSH_BIN" -p "$port" -i "${SSH_KEY:-$HOME/.ssh/mk_key}" \
                $RUP_SSH_OPTS -o LogLevel=ERROR "$user@$ip" "$cmd" 2>&1)
        rc=$?
    else
        # shellcheck disable=SC2086
        out=$($RUP_SSH_BIN -p "$port" -i "${SSH_KEY:-$HOME/.ssh/mk_key}" \
                $RUP_SSH_OPTS -o LogLevel=ERROR "$user@$ip" "$cmd" 2>&1)
        rc=$?
    fi

    # Код 124 = таймаут команды (GNU timeout)
    if [ "$rc" -eq 124 ]; then
        RUP_SSH_ERR="таймаут операции на роутере (${tmo}с)"
        return 124
    fi
    # RouterOS при обрыве (например, reboot) пишет в stderr текст — не считаем
    # его ошибкой, если rc==0/255 от "Connection closed". rc обычно 255 при
    # закрытии соединения удалённой стороной по reboot.
    if [ $rc -ne 0 ] && echo "$out" | grep -qiE "connection closed|closed by remote|remote closed"; then
        rc=0
    fi
    if [ $rc -ne 0 ]; then
        RUP_SSH_ERR="SSH rc=$rc: $(echo "$out" | tail -2 | tr '\n' ' ')"
        return $rc
    fi
    printf '%s\n' "$out"
    return 0
}

rup_ssh_check() {
    # Быстрая проверка доступности + печать версии. rc=0 если SSH отвечает.
    local name="$1"
    rup_ssh_exec "$name" "/system resource print" > /dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Утилиты
# -----------------------------------------------------------------------------
rup_parse_field() {
    # Вызов в двух вариантах:
    #   А) rup_parse_field "<текст вывода>" "имя_поля"
    #   Б) echo "<текст>" | rup_parse_field "имя_поля"
    local text f
    if [ "$#" -ge 2 ]; then
        text="$1"; f="$2"
    else
        f="${1:-}"; text=$(cat)
    fi
    # Ищет строку вида "   latest-version: 7.18.1"
    awk -v f="$f" '
        tolower($0) ~ "^[ \t]*" f "[ \t]*:" {
            sub(/^[^:]*:[ \t]*/, ""); sub(/[ \t\r]*$/, ""); print; exit
        }' <<< "$text"
}

rup_version_major() {
    echo "$1" | cut -d. -f1
}

# Убираем хвосты вида " (stable)", пробелы и мусор из строки версии
rup_ver_clean() {
    echo "$1" | sed -E 's/[[:space:]].*$//; s/[^0-9.].*$//' | xargs
}

# Сравнение версий a b: 0 - равны, 1 - a>b, 2 - a<b
rup_version_cmp() {
    local a="$1" b="$2"
    local ia ib x y
    while [ -n "$a" ] || [ -n "$b" ]; do
        x="${a%%.*}"; y="${b%%.*}"
        x="${x:-0}"; y="${y:-0}"
        ia=$(echo "$x" | sed 's/[^0-9].*$//'); [ -z "$ia" ] && ia=0
        ib=$(echo "$y" | sed 's/[^0-9].*$//'); [ -z "$ib" ] && ib=0
        if [ "$ia" -gt "$ib" ]; then return 1
        elif [ "$ia" -lt "$ib" ]; then return 2
        fi
        a="${a#*.}"; [ "$a" = "$x" ] && a=""
        b="${b#*.}"; [ "$b" = "$y" ] && b=""
    done
    return 0
}

# Обновление доступно? (a - установленная, b - последняя)
rup_is_newer() {
    rup_version_cmp "$2" "$1"
    [ $? -eq 1 ]
}

rup_tsv_escape_detail() {
    # Поле detail не должно содержать переводов строк/табуляций
    echo "$1" | tr '\n' ' ' | tr '\t' ' ' | sed 's/  */ /g'
}

# -----------------------------------------------------------------------------
# ОСНОВНАЯ ПРОВЕРКА ОДНОГО УСТРОЙСТВА
# -----------------------------------------------------------------------------
# Печатает TSV-строку:
#   name<TAB>status<TAB>major<TAB>installed<TAB>latest<TAB>channel<TAB>detail
# где status: UPDATE | CURRENT | BUSY | ERROR
rup_check_device() {
    local name="$1"
    local chan_cfg="$UPDATE_CHANNEL"
    local out err rc cmd
    local cur_ver="" major="" upd_latest="" upd_inst="" upd_status="" upd_chan="" detail=""
    local status="ERROR"

    if ! rup_get_line "$name" > /dev/null 2>&1; then
        echo -e "$name\tERROR\t-\t-\t-\t-\tНе найдено в devices.conf"
        return 1
    fi

    # --- текущая версия (для определения ветки v6/v7) ---
    out=$(rup_ssh_exec "$name" "/system resource print" "${UPDATE_SSH_TIMEOUT:-60}")
    rc=$?
    if [ $rc -ne 0 ]; then
        detail="Нет SSH-доступа (${RUP_SSH_ERR:-rc=$rc})"
        detail=$(rup_tsv_escape_detail "$detail")
        echo -e "$name\tERROR\t-\t-\t-\t-\t$detail"
        return 1
    fi
    cur_ver=$(rup_parse_field "$out" "version")
    cur_ver=$(rup_ver_clean "$cur_ver")
    major=$(rup_version_major "$cur_ver")

    # --- канал (принудительно, если задан UPDATE_CHANNEL) ---
    if [ -n "$chan_cfg" ]; then
        rup_ssh_exec "$name" "/system package update set channel=$chan_cfg" "${UPDATE_SSH_TIMEOUT:-60}" > /dev/null 2>&1
    fi

    # --- запрос обновлений к серверам MikroTik ---
    # check-for-updates может идти долго (роутер ходит на upgrade.mikrotik.com),
    # поэтому ограничиваем по времени, чтобы одно устройство не блокировало все.
    out=$(rup_ssh_exec "$name" $'/system package update check-for-updates\n/system package update print' "${UPDATE_CHECK_TIMEOUT:-150}")
    rc=$?
    if [ $rc -ne 0 ]; then
        if [ "$rc" -eq 124 ]; then
            detail="check-for-updates не ответил за ${UPDATE_CHECK_TIMEOUT:-150}с (нет доступа роутера к upgrade.mikrotik.com?)"
        else
            detail="Ошибка check-for-updates (${RUP_SSH_ERR:-rc=$rc})"
        fi
        detail=$(rup_tsv_escape_detail "$detail")
        echo -e "$name\tERROR\t$major\t$cur_ver\t-\t$chan_cfg\t$detail"
        return 1
    fi

    upd_status=$(rup_parse_field "$out" "status" | tr '[:upper:]' '[:lower:]')
    upd_chan=$(rup_parse_field "$out" "channel")
    upd_latest=$(rup_parse_field "$out" "latest-version")
    # RouterOS 6 не выводит latest-version — в v6 поле называется version
    [ -z "$upd_latest" ] && upd_latest=$(rup_parse_field "$out" "version")
    upd_inst=$(rup_parse_field "$out" "installed-version")
    [ -z "$upd_inst" ] && upd_inst="$cur_ver"
    upd_latest=$(rup_ver_clean "$upd_latest")
    upd_inst=$(rup_ver_clean "$upd_inst")

    detail=""
    # ВАЖНО: "no new version" проверяем раньше "new version" (подстрока!)
    if echo "$upd_status" | grep -qi "no new version"; then
        status="CURRENT"
    elif echo "$upd_status" | grep -qi "new version"; then
        status="UPDATE"
        detail="status=$upd_status"
    elif echo "$upd_status" | grep -qiE "download|upgrade|reboot|install"; then
        # Обновление уже скачано/запланировано (ждёт reboot) — не трогаем
        status="BUSY"
        detail=$(rup_tsv_escape_detail "Обновление уже скачано/запланировано на роутере: $upd_status")
    elif echo "$upd_status" | grep -qiE "could not|fail|error|no route|unreach|refused|timeout|connect"; then
        status="ERROR"
        detail=$(rup_tsv_escape_detail "Роутер не смог связаться с серверами MikroTik: $upd_status")
    else
        # Статус не распознан — попробуем сравнить версии напрямую
        if [ -n "$upd_latest" ] && [ -n "$cur_ver" ] && rup_is_newer "$cur_ver" "$upd_latest"; then
            status="UPDATE"
            detail="status=$upd_status"
        else
            status="CURRENT"
            detail=$(rup_tsv_escape_detail "status: ${upd_status:-неизвестно}")
        fi
    fi

    echo -e "$name\t$status\t$major\t$upd_inst\t$upd_latest\t$upd_chan\t$detail"
    return 0
}

# -----------------------------------------------------------------------------
# ФОРМИРОВАНИЕ ЧЕЛОВЕКО-ЧИТАЕМЫХ СТРОК ИЗ TSV
# -----------------------------------------------------------------------------
rup_report_line_html() {
    # $1 - tsv-строка -> одна строка для сообщения
    local name s maj inst latest chan det
    IFS=$'\t' read -r name s maj inst latest chan det <<< "$1"
    case "$s" in
        UPDATE)
            echo "⬆️ <b>$name</b>: $inst → <b>$latest</b> <i>(канал: ${chan:-?})</i>"
            ;;
        CURRENT)
            echo "✅ <b>$name</b>: актуально ($inst) <i>(канал: ${chan:-?})</i>"
            ;;
        BUSY)
            echo "⏳ <b>$name</b>: ${det:-обновление уже скачано/запланировано}"
            ;;
        ERROR)
            echo "⚠️ <b>$name</b>: ${det:-недоступно}"
            ;;
        *)
            echo "❓ <b>$name</b>: ${det:-неизвестный статус}"
            ;;
    esac
}

rup_report_summary() {
    # $1.. — tsv-строки -> текст сводки (счётчики)
    local up=0 cur=0 err=0 busy=0 line s
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS=$'\t' read -r _ s _ _ _ _ _ <<< "$line"
        case "$s" in UPDATE) up=$((up+1));; CURRENT) cur=$((cur+1));; BUSY) busy=$((busy+1));; *) err=$((err+1));; esac
    done <<< "$(printf '%s\n' "$@")"
    echo "Итого: обновления ⬆️ $up • актуальны ✅ $cur • заняты ⏳ $busy • ошибки ⚠️ $err"
}

# -----------------------------------------------------------------------------
# ВОРКЕР: проверка всех (или одного) устройств
# -----------------------------------------------------------------------------
rup_worker_check() {
    local scope="${1:-all}"
    local name=""
    local names=() line tsv status
    rup_ensure_dirs

    if ! rup_lock_acquire "check" 5; then
        rup_busy_message "проверка обновлений"
        return 1
    fi

    if [ "$scope" = "all" ]; then
        local cfg
        cfg=$(rup_cfg_file)
        [ -f "$cfg" ] || { rup_send "❌ Нет файла devices.conf ($cfg)"; rup_lock_release "check"; return 1; }
        while IFS= read -r line; do
            [[ "$line" =~ ^# ]] && continue
            [ -z "$line" ] && continue
            line=$(echo "$line" | tr -d '\r')
            names+=("$(echo "$line" | cut -d: -f1)")
        done < "$cfg"
    else
        names+=("$scope")
    fi

    if [ ${#names[@]} -eq 0 ]; then
        rup_send "❌ Нет устройств для проверки."
        rup_lock_release "check"
        return 1
    fi

    local total=${#names[@]}
    rup_send "🔎 <b>Проверка обновлений RouterOS…</b> (устройств: $total)
Результат по каждому устройству придёт отдельным сообщением по мере проверки."

    local all_tsv="" n=0
    local upd_buttons="["
    local html=""
    local have_any=0

    for name in "${names[@]}"; do
        n=$((n+1))
        # Сразу показываем прогресс, чтобы не казалось, что бот завис
        rup_send "⏳ [$n/$total] <b>$name</b>: проверяю…"
        tsv=$(rup_check_device "$name")
        IFS=$'\t' read -r _ status _ _ _ _ _ <<< "$tsv"
        all_tsv+="$tsv"$'\n'
        # Результат по устройству — сразу
        rup_send "$(rup_report_line_html "$tsv")"
        rup_log "check $name -> $(echo "$tsv" | tr '\t' '|')"
        if [ "$status" = "UPDATE" ]; then
            have_any=1
            upd_buttons+='[{"text":"⬇️ Установить: '"$name"'","callback_data":"upd_install_'"$name"'"}],'
        fi
        # Небольшая пауза, чтобы не упереться в rate limit Telegram
        sleep 1
    done

    # Кеш последней проверки (для мгновенного /status)
    printf '%s' "$all_tsv" > "$(rup_state_dir)/last_check.tsv" 2>/dev/null

    # Сводка
    rup_send "📊 <b>Итог проверки</b> (${n}/$total)
$(rup_report_summary "$all_tsv")"

    # Кнопки установки (если есть обновления)
    if [ "$have_any" = "1" ]; then
        upd_buttons+='[{"text":"📋 Меню","callback_data":"menu"}]'
        upd_buttons+=']'
        rup_send_keyboard "⬇️ <b>Доступны обновления</b> — нажмите на устройство для подтверждения установки:" "$upd_buttons"
    fi

    rup_lock_release "check"
    return 0
}

# -----------------------------------------------------------------------------
# ПРЕДВАРИТЕЛЬНОЕ РЕЗЕРВНОЕ КОПИРОВАНИЕ (MikroGit.sh)
# -----------------------------------------------------------------------------
rup_backup_before_update() {
    # $1 - device_name
    local name="$1"
    [ "${UPDATE_BACKUP_BEFORE_APPLY:-1}" = "1" ] || return 0
    local bs="${BACKUP_SCRIPT:-}"
    if [ -z "$bs" ] || [ ! -f "$bs" ]; then
        rup_log "BACKUP_SCRIPT не задан/не найден ($bs) — пропускаю предварительный бэкап"
        return 0
    fi
    rup_send "🗄 Делаю резервную копию конфигурации <b>$name</b> перед обновлением…"
    if bash "$bs" --device "$name" >> "${LOG_FILE:-/tmp/mk_updates.log}" 2>&1; then
        rup_send "✅ Конфигурация <b>$name</b> сохранена (MikroGit)."
        return 0
    else
        rup_send "⚠️ Не удалось создать резервную копию <b>$name</b>."
        return 1
    fi
}

# -----------------------------------------------------------------------------
# ВОРКЕР: скачивание + установка + постребутная проверка
# -----------------------------------------------------------------------------
rup_worker_apply() {
    local name="$1"
    rup_ensure_dirs

    if ! rup_lock_acquire "apply_$name" 3; then
        rup_busy_message "$name"
        return 1
    fi
    trap "rup_lock_release apply_$name" EXIT

    local tsv status major installed latest chan det
    local cur_line
    cur_line=$(rup_get_line "$name") || {
        rup_send "❌ Устройство <b>$name</b> не найдено в devices.conf"
        rup_lock_release "apply_$name"; trap - EXIT; return 1
    }

    # 1. Актуальная проверка
    rup_send "🔄 <b>$name</b>: проверяю доступность обновления…"
    tsv=$(rup_check_device "$name")
    IFS=$'\t' read -r _ status major installed latest chan det <<< "$tsv"
    rup_log "apply $name check -> $(echo "$tsv" | tr '\t' '|')"

    case "$status" in
        UPDATE) : ;;
        CURRENT)
            rup_send "✅ <b>$name</b> уже на актуальной версии ($installed)."
            rup_lock_release "apply_$name"; trap - EXIT; return 0 ;;
        BUSY)
            rup_send "⏳ <b>$name</b>: обновление уже скачано/запланировано на роутере. Выполните перезагрузку вручную (или повторите позже)."
            rup_lock_release "apply_$name"; trap - EXIT; return 1 ;;
        *)
            rup_send "❌ <b>$name</b>: ${det:-не удалось проверить обновление}. Установка отменена."
            rup_lock_release "apply_$name"; trap - EXIT; return 1 ;;
    esac

    # Установка только в рамках своей мажорной ветки (6->6, 7->7)
    local latest_major
    latest_major=$(rup_version_major "$latest")
    if [ -n "$latest_major" ] && [ -n "$major" ] && [ "$latest_major" != "$major" ]; then
        rup_send "🚫 <b>$name</b>: доступна версия $latest (ветка $latest_major), установлена $installed (ветка $major). Кросс-апгрейд веток автоматически не выполняется."
        rup_lock_release "apply_$name"; trap - EXIT; return 1
    fi

    # 2. Подтверждено пользователем — резервная копия
    if ! rup_backup_before_update "$name"; then
        rup_send "🛑 <b>$name</b>: установка отменена (резервная копия не создана)."
        rup_lock_release "apply_$name"; trap - EXIT; return 1
    fi

    # 3. Принудительно ставим канал (если задан)
    if [ -n "$UPDATE_CHANNEL" ]; then
        rup_ssh_exec "$name" "/system package update set channel=$UPDATE_CHANNEL" "${UPDATE_SSH_TIMEOUT:-60}" > /dev/null 2>&1 \
            && rup_log "apply $name: channel=$UPDATE_CHANNEL установлен" || true
    fi

    # 4. Скачивание
    rup_send "⬇️ <b>$name</b>: скачиваю RouterOS $latest (канал ${chan:-?}).\nЭто может занять несколько минут…"
    local out rc
    out=$(rup_ssh_exec "$name" "/system package update download" "${UPDATE_DOWNLOAD_TIMEOUT:-900}")
    rc=$?

    if [ $rc -ne 0 ]; then
        if [ $rc -eq 124 ]; then
            rup_send "❌ <b>$name</b>: таймаут скачивания (${UPDATE_DOWNLOAD_TIMEOUT}с). Проверьте канал/интернет роутера."
        else
            rup_send "❌ <b>$name</b>: ошибка скачивания (${RUP_SSH_ERR:-rc=$rc})."
        fi
        rup_lock_release "apply_$name"; trap - EXIT; return 1
    fi

    # Небольшая проверка: статус не должен быть "downloading"
    out=$(rup_ssh_exec "$name" "/system package update print" "${UPDATE_SSH_TIMEOUT:-60}")
    if echo "$out" | grep -qiE "downloading"; then
        rup_send "❌ <b>$name</b>: скачивание не завершилось (статус downloading). Повторите позже."
        rup_lock_release "apply_$name"; trap - EXIT; return 1
    fi
    rup_send "✅ <b>$name</b>: пакеты скачаны. Готовлюсь к перезагрузке…"

    # 5. Перезагрузка для установки
    rup_send "🔄 <b>$name</b>: перезагружаю роутер для установки RouterOS $latest.\nСоединение будет недоступно ~2–5 минут. Не выключайте питание!"
    sleep 5
    rup_ssh_exec "$name" "/system reboot" > /dev/null 2>&1
    rup_log "apply $name: reboot отправлен"

    # 6. Ожидание возвращения устройства и проверка версии
    rup_send "⏳ <b>$name</b>: жду возвращения устройства после перезагрузки…"
    local waited=0 up=""
    while [ $waited -lt "$UPDATE_REBOOT_WAIT" ]; do
        sleep "$UPDATE_REBOOT_POLL"; waited=$((waited + UPDATE_REBOOT_POLL))
        local v
        v=$(rup_ssh_exec "$name" "/system resource print" "${UPDATE_SSH_TIMEOUT:-60}" 2>/dev/null | rup_parse_field "version")
        v=$(rup_ver_clean "$v")
        if [ -n "$v" ]; then up="$v"; break; fi
    done

    if [ -z "$up" ]; then
        rup_send "⚠️ <b>$name</b>: роутер не вернулся в SSH за ${UPDATE_REBOOT_WAIT}с.\nПроверьте устройство вручную!"
        rup_lock_release "apply_$name"; trap - EXIT; return 1
    fi

    if [ "$up" = "$latest" ]; then
        rup_send "🎉 <b>$name</b> обновлён: $installed → <b>$up</b>. Всё прошло успешно!"
    elif rup_is_newer "$installed" "$up"; then
        rup_send "✅ <b>$name</b>: версия теперь <b>$up</b> (была $installed, цель была $latest)."
    else
        rup_send "⚠️ <b>$name</b>: после перезагрузки версия <b>$up</b>, ожидалась $latest. Проверьте устройство вручную."
    fi

    # 7. RouterBOOT firmware: автоматически после успешного обновления RouterOS
    # (или только информирование, если UPDATE_ROUTERBOARD_AUTO=0)
    rup_rb_after_apply "$name"

    rup_lock_release "apply_$name"; trap - EXIT
    return 0
}

# -----------------------------------------------------------------------------
# RouterBOOT firmware: чтение, определение доступного обновления, применение
# -----------------------------------------------------------------------------
# rup_rb_read <name>: получает /system routerboard print и кладёт
#   RUP_RB_CUR / RUP_RB_UPG (current-firmware / upgrade-firmware).
# rc: 0 - данные получены; 1 - нет данных (нет RouterBOOT/полей); 2 - SSH ошибка.
rup_rb_read() {
    local name="$1" out
    RUP_RB_CUR=""
    RUP_RB_UPG=""
    out=$(rup_ssh_exec "$name" "/system routerboard print" "${UPDATE_SSH_TIMEOUT:-60}") || return 2
    RUP_RB_CUR=$(rup_parse_field "$out" "current-firmware")
    RUP_RB_UPG=$(rup_parse_field "$out" "upgrade-firmware")
    if [ -z "$RUP_RB_CUR" ] || [ -z "$RUP_RB_UPG" ]; then
        RUP_RB_CUR=""
        RUP_RB_UPG=""
        return 1
    fi
    return 0
}

# Устройство отвечает по SSH? (быстрая проверка живучести после reboot)
rup_device_online() {
    local name="$1"
    rup_ssh_exec "$name" "/system resource print" 20 > /dev/null 2>&1
}

# Собственно применение прошивки RouterBOOT: upgrade + (reboot) + ожидание +
# контроль результата. Лок предполагается уже взятым вызывающей стороной.
# $1 = name, $2 = целевая версия прошивки (upgrade-firmware)
rup_rb_exec_upgrade() {
    local name="$1" want="$2" out rc
    rup_send "🔩 <b>$name</b>: выгружаю RouterBOOT firmware $want…"
    out=$(rup_ssh_exec "$name" "/system routerboard upgrade" "${UPDATE_RB_TIMEOUT:-120}")
    rc=$?
    # Таймаут (124): прошивка может всё ещё писаться/роутер мог уйти в ребут —
    # не считаем ошибкой, продолжаем с перезагрузкой и контролем.
    if [ "$rc" -eq 124 ]; then
        rup_send "⏳ <b>$name</b>: команда прошивки не ответила за ${UPDATE_RB_TIMEOUT}с — возможно, RouterBOOT уже пишется. Перезагружаю и проверяю…"
    elif [ "$rc" -ne 0 ]; then
        # rup_ssh_exec уже счёл rc=0 при "connection closed"; сюда попадают реальные ошибки
        rup_send "❌ <b>$name</b>: команда <code>/system routerboard upgrade</code> завершилась ошибкой (rc=$rc).\n${RUP_SSH_ERR:-}"
        return 1
    elif echo "$out ${RUP_SSH_ERR:-}" | grep -qiE "failure:|invalid|no routerboard|not supported|unknown command|bad command|denied"; then
        rup_send "❌ <b>$name</b>: RouterOS отказал в прошивке RouterBOOT: $(echo "$out" | tr '\n' ' ' | cut -c1-200)"
        return 1
    fi

    # Прошивка пишется при перезагрузке. Если роутер не ушёл в ребут сам — шлём reboot.
    sleep 3
    rup_send "🔄 <b>$name</b>: перезагружаю роутер для прошивки RouterBOOT…\nНе выключайте питание! Соединение пропадёт на несколько минут."
    if rup_device_online "$name"; then
        rup_ssh_exec "$name" "/system reboot" > /dev/null 2>&1
    fi

    # Ожидание возвращения устройства
    rup_send "⏳ <b>$name</b>: жду возвращения устройства после перезагрузки…"
    local waited=0 on=0
    while [ "$waited" -lt "${UPDATE_REBOOT_WAIT:-600}" ]; do
        sleep "${UPDATE_REBOOT_POLL:-10}"; waited=$((waited + ${UPDATE_REBOOT_POLL:-10}))
        if rup_device_online "$name"; then on=1; break; fi
    done
    if [ "$on" != "1" ]; then
        rup_send "⚠️ <b>$name</b>: роутер не вернулся за ${UPDATE_REBOOT_WAIT}с. Проверьте устройство вручную!"
        return 1
    fi

    # Контроль результата
    if rup_rb_read "$name"; then
        if [ "$RUP_RB_CUR" = "$want" ] || ! rup_is_newer "$RUP_RB_CUR" "$RUP_RB_UPG"; then
            rup_send "🎉 <b>$name</b>: RouterBOOT firmware обновлён → <b>$RUP_RB_CUR</b>."
            return 0
        fi
        rup_send "⚠️ <b>$name</b>: после перезагрузки RouterBOOT всё ещё требует обновления ($RUP_RB_CUR → $RUP_RB_UPG).\nВыполните вручную: <code>/system routerboard upgrade</code> + reboot."
        return 1
    fi
    rup_send "⚠️ <b>$name</b>: не удалось проверить RouterBOOT после перезагрузки (${RUP_SSH_ERR:-нет ответа}).\nПроверьте вручную: <code>/system routerboard print</code>."
    return 1
}

# Шаг 7 при обновлении RouterOS: проверить RouterBOOT и, если нужно, обновить
# автоматически (UPDATE_ROUTERBOARD_AUTO=1) или только сообщить (0).
rup_rb_after_apply() {
    local name="$1" cur upg
    if ! rup_rb_read "$name"; then return 0; fi   # нет RouterBOOT/недоступен — молча
    cur="$RUP_RB_CUR"; upg="$RUP_RB_UPG"
    if [ "$cur" = "-" ] || [ "$upg" = "-" ] || ! rup_is_newer "$cur" "$upg"; then
        return 0
    fi
    if [ "${UPDATE_ROUTERBOARD_AUTO:-1}" = "1" ]; then
        rup_send "🔩 <b>$name</b>: после обновления RouterOS доступно обновление RouterBOOT firmware (<b>$cur → $upg</b>). Обновляю автоматически…"
        rup_rb_exec_upgrade "$name" "$upg"
    else
        rup_send "ℹ️ <b>$name</b>: доступно обновление RouterBOOT firmware ($cur → $upg). Примените при необходимости: <code>/system routerboard upgrade</code> + reboot."
    fi
    return 0
}

# ВОРКЕР: отдельное обновление RouterBOOT firmware на устройстве
# (когда RouterOS уже актуален, а загрузчик — нет)
rup_worker_rb() {
    local name="$1"
    rup_ensure_dirs

    if ! rup_get_line "$name" > /dev/null 2>&1; then
        rup_send "❌ Устройство <b>$name</b> не найдено в devices.conf"
        return 1
    fi

    if ! rup_lock_acquire "apply_$name" 3; then
        rup_busy_message "$name"
        return 1
    fi
    trap "rup_lock_release apply_$name" EXIT

    rup_send "🔩 <b>$name</b>: проверяю RouterBOOT firmware…"
    if ! rup_rb_read "$name"; then
        rup_send "❌ <b>$name</b>: не удалось получить данные RouterBOOT (${RUP_SSH_ERR:-нет ответа/нет полей}).\nПроверьте: <code>/system routerboard print</code>"
        rup_lock_release "apply_$name"; trap - EXIT
        return 1
    fi
    local cur upg
    cur="$RUP_RB_CUR"; upg="$RUP_RB_UPG"
    if [ -z "$cur" ] || [ "$cur" = "-" ] || [ -z "$upg" ] || [ "$upg" = "-" ] || ! rup_is_newer "$cur" "$upg"; then
        rup_send "✅ <b>$name</b>: RouterBOOT firmware актуален (${cur:-?})."
        rup_lock_release "apply_$name"; trap - EXIT
        return 0
    fi
    rup_send "🔩 <b>$name</b>: доступно обновление RouterBOOT firmware (<b>$cur → $upg</b>)."
    rup_rb_exec_upgrade "$name" "$upg"
    local rc=$?
    rup_lock_release "apply_$name"; trap - EXIT
    return $rc
}


# -----------------------------------------------------------------------------
# «ОБНОВИТЬ ВСЕ» ПООЧЕРЁДНО (AP -> SW -> GW -> остальные)
# -----------------------------------------------------------------------------
# Печатает имена устройств devices.conf в порядке групп (префиксы из
# UPDATE_ALL_PRIORITY, регистр не важен), внутри группы — порядок файла;
# устройства без совпавшего префикса — в конце.
rup_ordered_names() {
    local cfg line name prio="${UPDATE_ALL_PRIORITY:-AP SW GW}"
    cfg=$(rup_cfg_file)
    [ -f "$cfg" ] || return 1
    # префиксы групп и отдельные списки имён по группам
    local -a grp_pref=() grp_hit=()
    local g
    for g in $prio; do grp_pref+=("$g"); grp_hit+=(""); done
    # все имена в порядке файла
    local -a names=() rest=()
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [ -z "$line" ] && continue
        line=$(echo "$line" | tr -d '\r')
        name=$(echo "$line" | cut -d: -f1)
        [ -n "$name" ] && names+=("$name")
    done < "$cfg"
    local name up i matched
    for name in "${names[@]}"; do
        up=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
        matched=0
        for i in "${!grp_pref[@]}"; do
            if [[ "$up" == "${grp_pref[$i]}"* ]]; then
                if [ -n "${grp_hit[$i]}" ]; then
                    grp_hit[$i]="${grp_hit[$i]} $name"
                else
                    grp_hit[$i]="$name"
                fi
                matched=1
                break
            fi
        done
        [ "$matched" = 0 ] && rest+=("$name")
    done
    # печать: имена каждой группы (в порядке файла), затем «остальные»
    local i gname
    for i in "${!grp_pref[@]}"; do
        for gname in ${grp_hit[$i]}; do
            echo "$gname"
        done
    done
    printf '%s\n' "${rest[@]}"
}

# ВОРКЕР: поочерёдное обновление всех устройств.
# Для каждого: если есть обновление RouterOS — полный apply (включая авто-
# RouterBOOT); если RouterOS актуален — проверка и обновление RouterBOOT.
# Строго по одному: следующее начинается только после завершения предыдущего.
rup_worker_update_all() {
    rup_ensure_dirs
    if ! rup_lock_acquire update_all 5; then
        rup_busy_message "обновление всех устройств"
        return 1
    fi
    local -a names=()
    local name
    while IFS= read -r name; do
        [ -n "$name" ] && names+=("$name")
    done < <(rup_ordered_names)
    local total=${#names[@]}
    if [ "$total" = 0 ]; then
        rup_send "❌ Нет устройств в devices.conf."
        rup_lock_release "update_all"
        return 1
    fi
    rup_send "🔄 <b>Поочерёдное обновление всех устройств</b> ($total).\nПорядок: ${UPDATE_ALL_PRIORITY:-AP SW GW} → остальные.\nКаждое устройство ждём и проверяем — к следующему переходим только после завершения.\nЭто может занять длительное время (по несколько минут на устройство с обновлением)."
    local n=0 ok=0 err=0 skp=0 tsv status det
    for name in "${names[@]}"; do
        n=$((n+1))
        rup_send "▶️ [$n/$total] <b>$name</b>: начинаю (проверка состояния)…"
        tsv=$(rup_check_device "$name")
        IFS=$'\t' read -r _ status _ _ _ _ det <<< "$tsv"
        case "$status" in
            UPDATE)
                if rup_worker_apply "$name"; then ok=$((ok+1)); else err=$((err+1)); fi ;;
            CURRENT)
                # RouterOS актуален — но RouterBOOT всё равно проверим/обновим
                if rup_worker_rb "$name"; then ok=$((ok+1)); else err=$((err+1)); fi ;;
            BUSY)
                skp=$((skp+1))
                rup_send "⏭️ [$n/$total] <b>$name</b>: уже занят операцией — пропущен." ;;
            *)
                err=$((err+1))
                rup_send "⚠️ [$n/$total] <b>$name</b>: ${det:-не удалось проверить} — пропущен." ;;
        esac
        rup_send "✅ [$n/$total] <b>$name</b>: обработан. Перехожу к следующему…"
    done
    rup_send "📊 <b>Обновление всех завершено</b> ($n/$total): успешно ✅ $ok • пропущено ⏭️ $skp • ошибки ⚠️ $err"
    rup_lock_release "update_all"
    return "$err"
}

# -----------------------------------------------------------------------------
# ПЕЧАТЬ КЕША ПОСЛЕДНЕЙ ПРОВЕРКИ (для мгновенного /updates status)
# -----------------------------------------------------------------------------
rup_print_cached_status() {
    rup_ensure_dirs
    local f="$(rup_state_dir)/last_check.tsv"
    if [ ! -f "$f" ] || [ ! -s "$f" ]; then
        rup_send "📭 Нет сохранённых данных проверки. Нажмите «Проверить сейчас»."
        return 1
    fi
    local line html="" chunk=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        html+="$(rup_report_line_html "$line")"$'\n'
    done < "$f"
    [ -z "$html" ] && { rup_send "📭 Нет данных."; return 0; }
    local header="📋 <b>Последняя проверка обновлений</b>"$'\n'
    header+="$(rup_report_summary "$(cat "$f")")"$'\n\n'
    html="$header$html"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ $(( ${#chunk} + ${#line} + 1 )) -gt 3800 ]; then
            rup_send "$chunk"; chunk=""
        fi
        chunk+="$line"$'\n'
    done <<< "$html"
    [ -n "$chunk" ] && rup_send "$chunk"
    return 0
}

# -----------------------------------------------------------------------------
# АВТОПРОВЕРКА ПО РАСПИСАНИЮ (вызывается ботом в главном цикле)
# -----------------------------------------------------------------------------
rup_maybe_auto_check() {
    [ "${UPDATE_AUTO_CHECK:-1}" = "1" ] || return 0
    rup_ensure_dirs
    local interval_s=$(( (${UPDATE_AUTO_INTERVAL_HOURS:-24}) * 3600 ))
    local f="$(rup_state_dir)/last_auto_check"
    local now mtime
    now=$(date +%s)
    if [ ! -f "$f" ]; then
        touch "$f"   # первый запуск: просто фиксируем время, чтобы не проверять сразу
        return 0
    fi
    mtime=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
    if [ $((now - mtime)) -ge "$interval_s" ]; then
        touch "$f"
        rup_log "Сработало расписание автопроверки обновлений"
        nohup bash "$RUP_SCRIPT_DIR/mk_updates.sh" check all >> "${LOG_FILE:-/tmp/mk_updates.log}" 2>&1 &
    fi
}

# -----------------------------------------------------------------------------
# ТОЧКА ВХОДА (если запущен как отдельный процесс / worker)
# -----------------------------------------------------------------------------
rup_main() {
    # Загрузка конфигурации и TG-хелперов, если ещё не загружены
    if [ ! -f "$RUP_SCRIPT_DIR/tg_bot_config.sh" ]; then
        rup_err "tg_bot_config.sh не найден в $RUP_SCRIPT_DIR"
        exit 1
    fi
    if ! declare -f tg_send_message > /dev/null 2>&1; then
        # shellcheck source=tg_bot_config.sh
        source "$RUP_SCRIPT_DIR/tg_bot_config.sh"
        # shellcheck source=tg_api_helpers.sh
        source "$RUP_SCRIPT_DIR/tg_api_helpers.sh"
    fi
    mkdir -p "$(dirname "${LOG_FILE:-/tmp/mk_updates.log}")" 2>/dev/null || true

    # PID-файл для контроля живости воркера из бота (start_update_check)
    rup_ensure_dirs
    echo "$$" > "$(rup_state_dir)/worker_last.pid" 2>/dev/null || true
    rup_log "Worker started: $* (pid=$$)"

    local action="${1:-}"
    case "$action" in
        check)
            rup_worker_check "${2:-all}" ;;
        apply)
            rup_worker_apply "${2:-}" ;;
        routerboard)
            rup_worker_rb "${2:-}" ;;
        updateall)
            rup_worker_update_all ;;
        status)
            rup_print_cached_status ;;
        *)
            echo "Использование: mk_updates.sh {check [all|device] | apply device | routerboard device | updateall | status}" >&2
            exit 2 ;;
    esac

    rup_log "Worker finished: $* (pid=$$, rc=$?)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    rup_main "$@"
    exit $?
fi


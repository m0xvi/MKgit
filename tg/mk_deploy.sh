#!/bin/bash
# =============================================================================
# MikroTik Key/Rights Deploy Worker (для бота и запуска из консоли)
# =============================================================================
# Назначение:
#   - запуск deploy_key.sh (SSH) по устройствам из devices.conf —
#     установка SSH-ключа MikroGit целевому пользователю + проверка и доводка
#     прав до МИНИМАЛЬНОЙ группы (DEPLOY_TARGET_GROUP, по умолчанию mikrogit,
#     политики ssh,read,write,test,reboot,policy,ftp) — прямо из бота или консоли:
#        bash tg/mk_deploy.sh all
#        bash tg/mk_deploy.sh <device>
#        bash tg/mk_deploy.sh status
#   - работает по одному устройству за раз (следующее после завершения
#     предыдущего), шлёт прогресс и итоги в Telegram (через rup/dep_send);
#
# Файл может использоваться двумя способами:
#   1) как библиотека: source tg/mk_deploy.sh   (только функции dep_*)
#   2) как worker:     bash tg/mk_deploy.sh all|<device>|status
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
fi

# -----------------------------------------------------------------------------
# Настройки (DEPLOY_* могут быть заданы в tg_bot_config.sh / окружении)
# -----------------------------------------------------------------------------
# Где лежит deploy_key.sh (по умолчанию — рядом с mk_deploy.sh в каталоге tg/)
DEPLOY_SCRIPT="${DEPLOY_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy_key.sh}"

# Публичный и приватный ключи (используются deploy_key.sh для SSH-предпроверки)
DEPLOY_KEY_FILE="${DEPLOY_KEY_FILE:-${SSH_KEY:-$HOME/.ssh/mk_key}.pub}"
DEPLOY_KEY_PRIV="${DEPLOY_KEY_PRIV:-${SSH_KEY:-$HOME/.ssh/mk_key}}"

# Администраторский вход на роутер по SSH (для установки ключа и выдачи прав).
# Порт SSH берётся из devices.conf (поле 3) для каждого устройства.
DEPLOY_TL_USER="${DEPLOY_TL_USER:-admin}"
DEPLOY_TL_PASS="${DEPLOY_TL_PASS:-}"

# Целевой пользователь (пусто = пользователь из 4-го поля devices.conf)
DEPLOY_TARGET_USER="${DEPLOY_TARGET_USER:-}"
# Группа, в которую приводится целевой пользователь. Вместо встроенной full —
# отдельная группа с МИНИМАЛЬНЫМ набором политик (DEPLOY_TARGET_POLICY);
# на роутере группа создаётся автоматически, если её нет. Пусто = права не менять.
DEPLOY_TARGET_GROUP="${DEPLOY_TARGET_GROUP:-mikrogit}"
# Политики группы (применяются при СОЗДАНИИ группы). Минимум для задач бота
# (бэкап + проверка/установка обновлений RouterOS через роутер): ssh,read,
# write,test,reboot,policy.
DEPLOY_TARGET_POLICY="${DEPLOY_TARGET_POLICY:-ssh,read,write,test,reboot,policy,ftp}"
# Пароль для создаваемого пользователя (пусто = случайный, будет в логе)
DEPLOY_NEWUSER_PASS="${DEPLOY_NEWUSER_PASS:-}"

# 1 = сначала SSH-предпроверка ключом (уже работает — права проверяем, ключ не
# ставим); 0 = всегда полный прогон. Вход администратора — только по SSH
# (telnet из кода/конфигов удалён полностью).
DEPLOY_SSH_PROBE="${DEPLOY_SSH_PROBE:-1}"
# 1 = после развёртывания повторно подтверждать вход ключом / права по SSH
DEPLOY_SSH_VERIFY="${DEPLOY_SSH_VERIFY:-1}"

# Общий wall-clock лимит на ОДНО устройство (сек) — защита от зависания
DEPLOY_ONE_TIMEOUT="${DEPLOY_ONE_TIMEOUT:-600}"

# Каталог состояния (логи, лок) — рядом с логом, как у обновлений
dep_state_dir() {
    echo "${DEPLOY_STATE_DIR:-$(dirname "${LOG_FILE:-/tmp/mk_deploy.log}")/deploy_state}"
}

# -----------------------------------------------------------------------------
# Флаг остановки фонового деплоя (ставится кнопкой «⏹ Остановить» в боте).
# Воркер проверяет его МЕЖДУ устройствами и завершается аккуратно — не рвёт
# текущую SSH-сессию на середине операции, а просто не начинает следующее.
# -----------------------------------------------------------------------------
dep_cancel_file()      { echo "$(dep_state_dir)/stop_deploy"; }
dep_cancel_set()       { : > "$(dep_cancel_file)"; }
dep_cancel_clear()     { rm -f "$(dep_cancel_file)"; }
dep_cancel_requested() { [ -f "$(dep_cancel_file)" ]; }

# -----------------------------------------------------------------------------
# Служебное: лог и отправка в Telegram (tg_send_message должен быть загружен)
# -----------------------------------------------------------------------------
DEPLOY_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dep_log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEPLOY: $*" | tee -a "${LOG_FILE:-/tmp/mk_deploy.log}"; }
dep_err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEPLOY ERROR: $*" | tee -a "${LOG_FILE:-/tmp/mk_deploy.log}" >&2; }

dep_send() {
    # Отправка в Telegram только если реально есть куда слать (конфиг загружен).
    # Иначе — пишем в лог (режим CLI/тест).
    if declare -f tg_send_message > /dev/null 2>&1        && [ -n "${TELEGRAM_CHAT_ID:-}" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
        tg_send_message "$TELEGRAM_CHAT_ID" "$1"
    else
        dep_log "(tg_send_message недоступен/нет конфига) $1"
    fi
}

# Как dep_send, но с кнопкой «⏹ Остановить деплой» — вешается на сообщения,
# которые воркер шлёт, ПОКА идёт обработка (самое свежее сообщение всегда
# содержит кнопку отмены).
dep_send_kb() {
    local kb='[[{"text":"⏹ Остановить деплой","callback_data":"deploy_stop"}]]'
    if declare -f tg_send_keyboard > /dev/null 2>&1        && [ -n "${TELEGRAM_CHAT_ID:-}" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
        tg_send_keyboard "$TELEGRAM_CHAT_ID" "$1" "$kb"
    else
        dep_log "(tg_send_message недоступен/нет конфига) $1"
    fi
}

dep_ensure_dirs() {
    mkdir -p "$(dep_state_dir)" 2>/dev/null || true
}

dep_cfg_file() {
    echo "${CONFIG_FILE:-/home/aionis/MikroGit/devices.conf}"
}

dep_script_file() {
    echo "$DEPLOY_SCRIPT"
}

# -----------------------------------------------------------------------------
# Лок/разлок (аналогично обновлениям, имя лока: deploy)
# -----------------------------------------------------------------------------
dep_lock_acquire() {
    # $1 - таймаут ожидания в сек
    local wait_max="${1:-15}" lockdir
    lockdir="$(dep_state_dir)/lock_deploy"
    dep_ensure_dirs
    local i=0 pid=""
    while [ -d "$lockdir" ]; do
        pid=$(cat "$lockdir/pid" 2>/dev/null)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$lockdir"
            continue
        fi
        [ $i -ge "$wait_max" ] && return 1
        sleep 1; i=$((i + 1))
    done
    mkdir -p "$lockdir" && echo "$$" > "$lockdir/pid"
    return 0
}

dep_lock_release() {
    rm -rf "$(dep_state_dir)/lock_deploy" 2>/dev/null || true
}

# Идёт ли сейчас операция обновления на устройстве (защита от пересечения
# деплоя с обновлением RouterOS на том же роутере).
dep_update_busy() {
    local name="$1"
    local upd_dir="${UPDATE_STATE_DIR:-$(dirname "${LOG_FILE:-/tmp/mk_deploy.log}")/update_state}"
    [ -d "$upd_dir/lock_apply_$name" ] || [ -d "$upd_dir/lock_update_all" ] || [ -d "$upd_dir/lock_rb_$name" ]
}

# Список устройств из devices.conf (по именам, порядок файла)
dep_devices() {
    local cfg="$1" line
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [ -z "$line" ] && continue
        line=$(printf '%s' "$line" | tr -d '\r')
        local name="${line%%:*}"
        [ -z "$name" ] && continue
        echo "$name"
    done < "$cfg"
}

# -----------------------------------------------------------------------------
# HTML-экранирование строк из лога роутера
# -----------------------------------------------------------------------------
dep_html() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# Полезные строки из лога развёртывания одного устройства (без протокольного
# мусора expect): статус-маркеры deploy_key.sh
dep_grep_good() {
    grep -aE '^\s*(\[OK\]|\[INFO\]|\[WARN\]|\[ERR\]|\[!!\]|====>|вход:|      rc=|Ошибок:|Развёрнуто|Уже настроено|Ключ уже работает|Ключа нет)' \
        | grep -avE '^\s*\[admin@|Password:|Login:' \
        | grep -avE 'MikroTik RouterOS [0-9]' || true
}

# -----------------------------------------------------------------------------
# Выполнить deploy_key.sh для ОДНОГО устройства (подпроцесс с env).
# Возвращает rc deploy_key.sh (0 = успех, иначе ошибка). Лог кладётся в
# $(dep_state_dir)/run_<name>.log и копируется в last_run.log.
# -----------------------------------------------------------------------------
dep_run_one() {
    local name="$1"
    local cfg script log rc
    cfg=$(dep_cfg_file)
    script=$(dep_script_file)
    dep_ensure_dirs
    log="$(dep_state_dir)/run_$name.log"

    if [ ! -f "$cfg" ]; then
        dep_err "нет файла devices.conf: $cfg"
        return 2
    fi
    if [ ! -f "$script" ]; then
        dep_err "deploy_key.sh не найден: $script (скопируйте рядом с ботом или задайте DEPLOY_SCRIPT)"
        return 3
    fi

    (
        export DEVICES_CONF="$cfg"
        # Обязательные/часто используемые передаём всегда (пустой TARGET_GROUP =
        # «права не менять» — это тоже осмысленное значение).
        export TL_USER="$DEPLOY_TL_USER"
        export SSH_PROBE="$DEPLOY_SSH_PROBE"
        export SSH_VERIFY="$DEPLOY_SSH_VERIFY"
        export TARGET_GROUP="$DEPLOY_TARGET_GROUP"
        export TARGET_POLICY="$DEPLOY_TARGET_POLICY"
        # Остальные — только если заданы
        [ -n "${DEPLOY_KEY_FILE:-}" ]     && export KEY_FILE="$DEPLOY_KEY_FILE"
        [ -n "${DEPLOY_KEY_PRIV:-}" ]     && export KEY_PRIV="$DEPLOY_KEY_PRIV"
        [ -n "${DEPLOY_TL_PASS:-}" ]      && export TL_PASS="$DEPLOY_TL_PASS"
        [ -n "${DEPLOY_TARGET_USER:-}" ]  && export TARGET_USER="$DEPLOY_TARGET_USER"
        [ -n "${DEPLOY_NEWUSER_PASS:-}" ] && export NEWUSER_PASS="$DEPLOY_NEWUSER_PASS"
        timeout "${DEPLOY_ONE_TIMEOUT:-600}" bash "$script" "$name"
    ) >"$log" 2>&1
    rc=$?
    cp "$log" "$(dep_state_dir)/last_run.log" 2>/dev/null || true
    printf '%s' "$log" > "$(dep_state_dir)/last_log_path" 2>/dev/null || true
    dep_log "device=$name rc=$rc (лог: $log)"
    return "$rc"
}

# Короткий итог для Telegram по логу одного устройства
dep_result_message() {
    local name="$1" rc="$2" log="$3"
    local state_line
    if grep -aq "Уже настроено (пропущено): *1" "$log"; then
        state_line="⏭️"
    elif [ "$rc" -eq 0 ]; then
        state_line="✅"
    else
        state_line="❌"
    fi

    local body="$state_line <b>$name</b>: развёртывание завершено (rc=$rc)\n"
    local detail
    detail=$(dep_grep_good < "$log" | tail -n 14 | dep_html)
    if [ -n "$detail" ]; then
        body+="<code>$detail</code>"
    fi
    printf '%b' "$body"
}

# -----------------------------------------------------------------------------
# ВОРКЕР: одно устройство (с прогресс-сообщениями)
# -----------------------------------------------------------------------------
dep_worker_device() {
    local name="$1"
    dep_cancel_clear
    if dep_cancel_requested; then
        dep_send "⏹ Деплой остановлен пользователем (устройство <b>$name</b> не обрабатывалось)."
        return 130
    fi
    # Устройство должно существовать в devices.conf
    local cfg; cfg=$(dep_cfg_file)
    if [ ! -f "$cfg" ] || ! grep -q "^$name:" "$cfg"; then
        dep_send "❌ Устройство <b>$name</b> не найдено в $cfg."
        return 1
    fi
    if dep_update_busy "$name"; then
        dep_send "⏳ <b>$name</b>: сейчас идёт операция обновления — пропускаю деплой. Повторите позже."
        return 2
    fi
    dep_send_kb "🔑 <b>$name</b>: запускаю установку ключа / проверку прав…"
    dep_run_one "$name"
    local rc=$?
    dep_send "$(dep_result_message "$name" "$rc" "$(dep_state_dir)/run_$name.log")"
    # если во время обработки устройства пришёл запрос «Остановить» — сообщаем
    # об этом кодом 130 (флаг НЕ снимаем: его обработает цикл dep_worker_all)
    if dep_cancel_requested; then
        dep_send "⏹ <b>$name</b>: обработка завершена, останавливаюсь по запросу."
        return 130
    fi
    return "$rc"
}

# -----------------------------------------------------------------------------
# ВОРКЕР: все устройства по очереди
# -----------------------------------------------------------------------------
dep_worker_all() {
    dep_ensure_dirs
    if ! dep_lock_acquire 5; then
        dep_send "⏳ Деплой уже выполняется в фоне. Дождитесь завершения."
        return 1
    fi
    # свежий запуск: снимаем возможный старый флаг остановки
    dep_cancel_clear
    local cfg names=() name
    cfg=$(dep_cfg_file)
    if [ ! -f "$cfg" ]; then
        dep_send "❌ Нет файла devices.conf ($cfg)."
        dep_cancel_clear
        dep_lock_release
        return 1
    fi
    while IFS= read -r name; do
        [ -n "$name" ] && names+=("$name")
    done < <(dep_devices "$cfg")
    local total=${#names[@]}
    if [ "$total" = 0 ]; then
        dep_send "❌ Нет устройств в devices.conf."
        dep_cancel_clear
        dep_lock_release
        return 1
    fi
    dep_send_kb "🔑 <b>Деплой ключа и прав на все устройства</b> ($total).\nРаботаю строго по одному; по каждому — отдельное сообщение. Это может занять время (по ~0,5–2 мин на устройство).\n\n⏹ На свежих сообщениях есть кнопка «Остановить деплой» — остановка после текущего устройства."

    local n=0 ok=0 err=0 skp=0 rc stopped=0
    for name in "${names[@]}"; do
        # между устройствами проверяем флаг остановки (ставится кнопкой в боте)
        if dep_cancel_requested; then
            dep_cancel_clear
            stopped=1
            dep_send "⏹ <b>Деплой остановлен пользователем</b> (обработано $n из $total)."
            break
        fi
        n=$((n + 1))
        dep_worker_device "$name"
        rc=$?
        # пользователь мог нажать «Остановить», пока шло текущее устройство:
        # завершаем цикл (текущее устройство доведено до конца — это безопасно;
        # само устройство уже сообщило «останаливаюсь по запросу» при rc=130)
        if dep_cancel_requested; then
            dep_cancel_clear
            stopped=1
            break
        fi
        case "$rc" in
            0)
                if grep -aq "Уже настроено (пропущено): *1" "$(dep_state_dir)/run_$name.log"; then
                    skp=$((skp + 1))
                else
                    ok=$((ok + 1))
                fi ;;
            *) err=$((err + 1)) ;;
        esac
        dep_send "✅ [$n/$total] <b>$name</b>: обработан. Перехожу к следующему…"
    done
    if [ "$stopped" = "1" ]; then
        dep_send "📊 <b>Деплой прерван пользователем</b> (остановлен после $n/$total): успешно ✅ $ok • уже настроено ⏭️ $skp • ошибки ❌ $err"
    else
        dep_send "📊 <b>Деплой завершён</b> ($n/$total): успешно ✅ $ok • уже настроено ⏭️ $skp • ошибки ❌ $err"
    fi
    dep_cancel_clear
    dep_lock_release
    return "$err"
}

# -----------------------------------------------------------------------------
# Последний статус (лог последнего запуска) — для кнопки «Последний лог»
# -----------------------------------------------------------------------------
dep_print_last_status() {
    dep_ensure_dirs
    local log
    log=$(cat "$(dep_state_dir)/last_log_path" 2>/dev/null)
    if [ -z "$log" ] || [ ! -f "$log" ]; then
        dep_send "📭 Деплой ещё не запускался из бота. Нажмите «Развернуть на ВСЕХ» или выберите устройство."
        return 1
    fi
    local body raw
    # Секреты (пароли, ключи, токены) вычищаем ДО отправки в Telegram.
    if declare -f log_sanitize > /dev/null 2>&1; then
        raw=$(log_sanitize < "$log")
    else
        raw=$(cat "$log")
    fi
    body=$(printf '%s' "$raw" | dep_grep_good | dep_html | tail -n 25)
    [ -z "$body" ] && body="(пусто)"
    dep_send "📜 <b>Последний лог деплоя</b> (<code>$(basename "$log")</code>)\n<code>$body</code>"
    return 0
}

# -----------------------------------------------------------------------------
# ТОЧКА ВХОДА (если запущен как отдельный процесс / worker)
# -----------------------------------------------------------------------------
dep_main() {
    # Загрузка конфигурации и TG-хелперов, если ещё не загружены (только при
    # реальном конфиге; без него — работаем в режиме лога/CLI).
    if [ -f "$DEPLOY_SELF_DIR/tg_bot_config.sh" ]; then
        # shellcheck source=tg_bot_config.sh
        source "$DEPLOY_SELF_DIR/tg_bot_config.sh"
        if ! declare -f tg_send_message > /dev/null 2>&1; then
            if [ -f "$DEPLOY_SELF_DIR/tg_api_helpers.sh" ]; then
                # shellcheck source=tg_api_helpers.sh
                source "$DEPLOY_SELF_DIR/tg_api_helpers.sh"
            fi
        fi
    fi
    mkdir -p "$(dirname "${LOG_FILE:-/tmp/mk_deploy.log}")" 2>/dev/null || true
    dep_ensure_dirs
    echo "$$" > "$(dep_state_dir)/worker_last.pid" 2>/dev/null || true
    dep_log "Worker started: $* (pid=$$)"

    local action="${1:-}"
    local rc
    if [[ "$action" == -* ]]; then
        echo "Использование: mk_deploy.sh {all | status | <device>}" >&2
        exit 2
    fi
    case "$action" in
        all)        dep_worker_all ;;
        status)     dep_print_last_status ;;
        *)
            # иначе считаем аргумент именем устройства
            if [ -n "$action" ]; then
                dep_worker_device "$action"
            else
                echo "Использование: mk_deploy.sh {all | status | <device>}" >&2
                exit 2
            fi
            ;;
    esac
    rc=$?
    dep_log "Worker finished: $* (pid=$$, rc=$rc)"
    return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    dep_main "$@"
    exit $?
fi


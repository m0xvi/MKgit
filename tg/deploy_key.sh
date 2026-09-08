#!/bin/bash
# =============================================================================
# Развёртывание SSH-ключа MikroGit на MikroTik-роутерах. Вход на роутер — ТОЛЬКО
# по SSH (telnet полностью удалён из всех методов входа). Порт SSH для каждого
# устройства берётся из devices.conf (поле 3).
# -----------------------------------------------------------------------------
# Хосты берутся из devices.conf (IP и порт оттуда верны); вход администратора
# выполняется по SSH отдельным пользователем (TL_USER, пароль TL_PASS),
# а НЕ тем, что указан в devices.conf. Ключ назначается целевому пользователю
# (TARGET_USER): если он уже существует на роутере — только импорт ключа;
# если не существует — создаётся в группе TARGET_GROUP с паролем из
# NEWUSER_PASS (или случайным) и импортируется ключ.
#
# ПРАВА: вместо встроенной группы full (все политики) деплой приводит целевого
# пользователя к отдельной группе TARGET_GROUP (по умолчанию «mikrogit») с
# МИНИМАЛЬНЫМ набором политик TARGET_POLICY (по умолчанию
# ssh,read,write,test,reboot,policy,ftp). ftp даёт file-доступ по scp/sftp —
# без него хардненинг (mk_harden.sh) не сможет залить скрипт на роутер.
# Если группа отсутствует на роутере — она создаётся с этими политиками;
# существующая группа не переопределяется «вслепую»: добавляются только
# недостающие требуемые политики (при невозможности прочитать политики группы
# целевой группе устанавливается требуемый набор). TARGET_GROUP="" = права
# не менять (только проверка/показ).
#
# Параметры: 1) переменные окружения, 2) файл deploy.conf рядом со скриптом
# (приоритет у окружения: строки deploy.conf применяются, только если
# соответствующая переменная окружения пуста).
#
# Зависимости: expect + openssh-client
# (sudo apt-get install -y expect openssh-client)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${DEPLOY_CONF:-$SCRIPT_DIR/deploy.conf}"

# ---------------------------------------------------------------------------
# Загрузка deploy.conf (значения применяются, если env-переменная не задана)
# Формат строк: KEY="value" или KEY=value (без export)
# ---------------------------------------------------------------------------
_load_conf() {
    [ -f "$CONF_FILE" ] || return 0
    local line k v
    while IFS= read -r line; do
        # строка-комментарий (весь конфиг построчный; inline-комментарии не режем,
        # чтобы значения вида a#b сохранялись)
        case "${line}" in
            ""|\#*) continue ;;
        esac
        k="${line%%=*}"
        v="${line#*=}"
        [ -n "$k" ] || continue
        [ -n "${!k:-}" ] && continue             # env уже задан — не перекрываем
        v="${v%\"}"; v="${v#\"}"                 # снять обрамляющие кавычки
        export "$k=$v"
    done < "$CONF_FILE"
}
_load_conf

# ---------------------------------------------------------------------------
# Параметры (с приоритетом: значение уже задано из env/deploy.conf)
# ---------------------------------------------------------------------------
DEVICES_CONF="${DEVICES_CONF:-/home/aionis/MikroGit/devices.conf}"
KEY_FILE="${KEY_FILE:-/home/aionis/.ssh/mk_key.pub}"
KEY_PRIV="${KEY_PRIV:-${KEY_FILE%.pub}}"  # приватный ключ для ПРОВЕРКИ входа
TL_USER="${TL_USER:-admin}"          # администраторский логин (вход по SSH)
TL_PASS="${TL_PASS:-}"               # пароль администратора TL_USER (SSH; обязателен)
TARGET_USER="${TARGET_USER:-}"       # кому назначить ключ (если пусто — берётся user из devices.conf для каждого хоста)
# Группа, в которую должен входить целевой пользователь (вместо «full»).
# По умолчанию — отдельная группа mikrogit с МИНИМАЛЬНЫМ набором политик
# (TARGET_POLICY). Если задать пустым — права НЕ трогаются (только проверка).
TARGET_GROUP="${TARGET_GROUP-mikrogit}"
# Политики группы TARGET_GROUP. Если группы на роутере ещё нет — она создаётся
# с этими политиками; если уже есть — в неё ДОБАВЛЯЮТСЯ недостающие требуемые
# политики (лишние не снимаются).
# Минимальный набор, достаточный для задач бота (бэкапы + проверка/установка
# обновлений RouterOS через сам роутер + RouterBOOT + заливка скрипта
# хардненинга по scp): ssh,read,write,test,reboot,policy,ftp.
TARGET_POLICY="${TARGET_POLICY-ssh,read,write,test,reboot,policy,ftp}"
NEWUSER_PASS="${NEWUSER_PASS:-}"     # пароль для СОЗДАВАЕМОГО пользователя (если TARGET_USER не существует)
SSH_PROBE="${SSH_PROBE:-1}"          # проверять ли вход целевым SSH-ключом (1/0); 0 = всегда полный прогон
SSH_TIMEOUT="${SSH_TIMEOUT:-8}"      # таймаут SSH-проверки на устройство, сек
SSH_VERIFY="${SSH_VERIFY:-1}"        # подтверждать ли ключ повторной SSH-проверкой после развёртывания
# ---------------------------------------------------------------------------
# Разбор аргументов (--dry-run, --check, --force) и фильтр устройства
# ---------------------------------------------------------------------------
DRY_RUN=0
CHECK_ONLY=0
FORCE=0
FILTER=""
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        --check)   CHECK_ONLY=1 ;;
        --force)   FORCE=1 ;;
        --help|-h)
            echo "Использование: $0 [--dry-run|--check|--force] [имя_устройства]"
            echo "Env/конфиг: DEVICES_CONF, KEY_FILE, KEY_PRIV, TL_USER, TL_PASS, TARGET_USER, TARGET_GROUP, TARGET_POLICY, NEWUSER_PASS, SSH_PROBE, SSH_TIMEOUT, SSH_VERIFY"
            exit 0 ;;
        --*) echo "Неизвестный аргумент: $a" >&2; exit 2 ;;
        *)
            if [ -n "$FILTER" ]; then
                echo "Лишний аргумент: $a" >&2
                exit 2
            fi
            FILTER="$a"
            ;;
    esac
done
[ "$FORCE" = "1" ] && SSH_PROBE=0   # --force: игнорировать предпроверку и разворачивать заново

# ---------------------------------------------------------------------------
# Валидация
# ---------------------------------------------------------------------------
[ -f "$DEVICES_CONF" ] || { echo "ERROR: devices.conf не найден: $DEVICES_CONF" >&2; exit 1; }
[ -f "$KEY_FILE" ] || {
    echo "ERROR: публичный ключ не найден: $KEY_FILE" >&2
    echo "Создайте: ssh-keygen -t rsa -b 4096 -f ${KEY_FILE%.pub} -N ''" >&2
    exit 1
}
# Для SSH-предпроверки нужен приватный ключ.
if [ ! -f "$KEY_PRIV" ]; then
    if [ "$CHECK_ONLY" = "1" ]; then
        echo "ERROR: для --check нужен приватный ключ: $KEY_PRIV" >&2
        exit 1
    fi
    if [ "$SSH_PROBE" = "1" ]; then
        echo "WARN: приватный ключ не найден ($KEY_PRIV) — SSH-предпроверка отключена"
        echo "      Скрипт будет разворачивать ключ на всех устройствах через SSH-вход администратора."
        SSH_PROBE=0
    fi
fi
# expect/ssh/TL_PASS проверяем ЛЕНИВО — только когда реально понадобится
# SSH-вход администратора (если все устройства уже настроены — они не нужны).
_CLI_OK=         # 1 = deps проверены и есть
_CLI_ERR=        # 1 = ошибка уже напечатана (не дублировать на каждый роутер)
ensure_client_deps() {
    # Перед реальным заходом администратора по SSH.
    if [ -n "$_CLI_ERR" ]; then return 1; fi
    if [ -z "$_CLI_OK" ]; then
        if ! command -v expect >/dev/null 2>&1; then
            _CLI_ERR=1; echo "ERROR: установите expect (apt-get install -y expect)" >&2; return 1
        fi
        if ! command -v ssh >/dev/null 2>&1; then
            _CLI_ERR=1; echo "ERROR: установите openssh-client (ssh)" >&2; return 1
        fi
        if [ -z "$TL_PASS" ]; then
            _CLI_ERR=1; echo "ERROR: задайте TL_PASS (пароль администратора $TL_USER)" >&2; return 1
        fi
        _CLI_OK=1
    fi
    return 0
}

# expect/tcl печатает кириллицу корректно только в UTF-8-локали (иначе
# не-ASCII символы превращаются в '?'). Если системная локаль не UTF-8 —
# включаем C.UTF-8.
ensure_utf8_locale() {
    if [ "$(locale charmap 2>/dev/null)" != "UTF-8" ]; then
        # берём любую доступную utf-8 локаль (C.utf8 / C.UTF-8 / en_US.UTF-8…)
        local cand
        cand=$(locale -a 2>/dev/null | grep -iE 'utf-?8$' | head -n1)
        [ -n "$cand" ] && export LC_ALL="$cand" LANG="$cand"
    fi
}

# Секреты, которые НЕ должны попадать в логи (добавляются по мере разбора).
_SCR_SECRETS=()
_scr_add_secret() {
    local v="$1"
    [ -n "$v" ] && [ "${#v}" -ge 4 ] && _SCR_SECRETS+=("$v")
}

# Вычистка потока лога от секретов (читает stdin, пишет в stdout).
# $1..N — дополнительные значения для глушения (напр. сгенерированный пароль).
scrub_secrets() {
    local line s v inkey=0
    local -a extra=("$@")
    for v in "$TL_PASS" "$NEWUSER_PASS" "${extra[@]:-}"; do
        _scr_add_secret "$v"
    done
    while IFS= read -r line; do
        # многострочный приватный ключ — глушим целиком
        if [ "$inkey" = "1" ]; then
            if printf '%s' "$line" | grep -qE -- '-----END [A-Z ]*PRIVATE KEY-----'; then
                inkey=0
                echo "[SCRUBBED: private key block]"
            fi
            continue
        fi
        if printf '%s' "$line" | grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----|OPENSSH PRIVATE KEY|-----BEGIN (RSA |EC |DSA |ENCRYPTED )?PRIVATE KEY-----'; then
            inkey=1
            continue
        fi
        # известные значения (пароли/токены из конфига и сгенерированные)
        for s in "${_SCR_SECRETS[@]:-}"; do
            [ -n "$s" ] && line="${line//"$s"/[SCRUBBED]}"
        done
        # типовые паттерны password=.../Password: .../passphrase .../mk-<ts>-<rand>
        line="$(printf '%s' "$line" | sed -E 's/password="[^"]*"/password="[SCRUBBED]"/Ig; s/password=[^ "][^ ]*/password=[SCRUBBED]/Ig; s/mk-[0-9]+-[0-9]+/[SCRUBBED]/g; s/([Pp]assphrase[[:space:]]*[:=][[:space:]]*)[^ ]*/\1[SCRUBBED]/Ig')"
        printf '%s\n' "$line"
    done
}

KEY_TEXT=$(tr -d '\r\n' < "$KEY_FILE")
LOG="deploy_key_$(date +%Y%m%d_%H%M%S).log"

echo "devices.conf : $DEVICES_CONF"
echo "ключ         : $KEY_FILE"
echo "SSH-проверка : $([ "$SSH_PROBE" = "1" ] && echo "вкл (${KEY_PRIV})" || echo "выкл")"
echo "вход админа  : ssh $TL_USER@<ip> — порт каждого устройства из devices.conf, поле 3 (telnet удалён)"; [ -n "$TL_PASS" ] || echo "WARN: TL_PASS не задан — вход администратора невозможен"
[ "$SSH_VERIFY" = "1" ] && [ "$SSH_PROBE" = "1" ] && echo "подтверждение: после развёртывания вход ключом проверяется повторно (SSH)"
echo "целевой user : ${TARGET_USER:-<из devices.conf, поле 4>}"
echo "права (группа): ${TARGET_GROUP:-<не менять, только проверка>}"
[ -n "$TARGET_GROUP" ] && echo "  политики группы : ${TARGET_POLICY:-<как на роутере>} (если группы нет — создаётся с ними)"
[ "$DRY_RUN" = "1" ] && echo "РЕЖИМ: dry-run (без подключения)"
[ "$CHECK_ONLY" = "1" ] && echo "РЕЖИМ: только проверка (--check): у кого ключ уже работает"
[ "$FORCE" = "1" ] && echo "РЕЖИМ: --force (без SSH-предпроверки, разворачивать на всех)"
[ -n "$FILTER" ] && echo "Фильтр устройства: $FILTER"
echo "лог          : $LOG"

# ---------------------------------------------------------------------------
# SSH-предпроверка: входит ли приватный ключ на устройство под целевым user
# (ключ уже есть — ставить не нужно). Но ПРАВА пользователя проверяются даже
# при рабочем ключе (см. ssh_user_group + режим rights_only в deploy_one).
# Возврат: 0 = да, ключ уже работает; 1 = нет (нужен SSH-вход администратора)
# ---------------------------------------------------------------------------
ssh_key_works() {
    local host="$1" sport="$2" target="$3"
    # -n + </dev/null: НЕ давать ssh читать stdin! Внутри цикла
    # while read ... < devices.conf ssh иначе вычитывает весь файл и
    # цикл завершается после первой строки (массовый запуск ломался).
    ssh -n -p "$sport" -i "$KEY_PRIV" \
        -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        -o HostKeyAlgorithms=+ssh-rsa \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout="$SSH_TIMEOUT" -o LogLevel=ERROR \
        "$target@$host" "/system identity print" > /dev/null 2>&1 < /dev/null
}

# ---------------------------------------------------------------------------
# Прочитать группу пользователя на устройстве по SSH (ключом, который уже
# работает). Позволяет проверить ПРАВА и на тех устройствах, которые при
# обычном прогоне были бы пропущены (ключ уже есть).
# Печатает название группы (одной строкой); rc: 0 = прочитано,
# 1 = не удалось (нет доступа / нет такой команды / пусто).
# ---------------------------------------------------------------------------
ssh_user_group() {
    local host="$1" sport="$2" target="$3" q out
    q=":put [/user get [find name=$target] group]"
    out=$(ssh -n -p "$sport" -i "$KEY_PRIV" \
        -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        -o HostKeyAlgorithms=+ssh-rsa \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout="$SSH_TIMEOUT" -o LogLevel=ERROR \
        "$target@$host" "$q" 2>/dev/null < /dev/null)
    out=$(printf '%s' "$out" | tr -d '\r' | grep -m1 '^[A-Za-z][A-Za-z0-9_.-]*$')
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Политики группы, в которой состоит пользователь, прочитанные по SSH одной
# командой (сам пользователь задаёт запрос). RouterOS НЕ выполняет
# многострочные команды через ssh-exec (документированное ограничение),
# поэтому сначала читаем группу, затем политики — каждое ОДНОЙ строкой.
# Печатает политики одной строкой; rc: 0 = прочитано, 1 = не удалось.
# ---------------------------------------------------------------------------
ssh_group_policy_of_user() {
    local host="$1" sport="$2" target="$3" g out pol
    g="$(ssh_user_group "$host" "$sport" "$target")" || return 1
    [ -n "$g" ] || return 1
    out=$(ssh -n -p "$sport" -i "$KEY_PRIV" \
        -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        -o HostKeyAlgorithms=+ssh-rsa \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout="$SSH_TIMEOUT" -o LogLevel=ERROR \
        "$target@$host" ":put [/user group get [find name=$g] policy]" 2>/dev/null < /dev/null)
    pol=$(printf '%s' "$out" | tr -d '\r' | grep -E '^"?[a-zA-Z][a-zA-Z0-9,; _-]*"?$' | tail -n1 | tr -d '"' | tr ';' ',' | tr -d ' ')
    if [ -n "$pol" ]; then
        printf '%s\n' "$pol"
        return 0
    fi
    return 1
}


# Список требуемых политик (для точной проверки прав пользователя)
need_policies() { echo "${TARGET_POLICY:-ssh,read,write,test,reboot,policy,ftp}"; }

# Покрывает ли список политик $1 (через запятую) все требуемые из $2.
pol_has_all() {
    local pol="$1" req="$2" tok t
    [ -z "$pol" ] && return 1
    local IFS=,
    for tok in $req; do
        [ -z "$tok" ] && continue
        local found=0
        for t in $pol; do
            [ "$t" = "$tok" ] && { found=1; break; }
        done
        [ "$found" = 0 ] && return 1
    done
    return 0
}
# ---------------------------------------------------------------------------
# Обработка одного устройства. Вход администратора — ТОЛЬКО по SSH, причём
# команды выполняются через ssh-exec: каждая команда ОДНОЙ строкой и ОТДЕЛЬНОЙ
# сессией БЕЗ pty (ssh -T). Причина: интерактивная консоль RouterOS 6.49 по pty
# заливает сессию ANSI-перерисовкой строки (эхо, [K, [9999B, [6n), из-за чего
# разбор ответов и применение команд ненадёжны; ssh-exec без pty даёт чистый
# вывод, но RouterOS (по документации) не принимает многострочные команды.
# $4=rights_only: 1 = ключ уже работает, делается только проверка/доводка прав.
# rc: 0 = успех; 1 = ошибка (подробности в логе).
# ---------------------------------------------------------------------------
# Выполнить одну команду RouterOS (админ TL_USER) через ssh-exec без pty.
# Пароль уходит только в stdin ssh (в лог/эхо не попадает).
# Результат: stdout роутера -> $ADM_OUT, статус -> $ADM_RC
# (0 = выполнено, 2 = недоступно/соединение, 3 = timeout, 4 = нет TL_PASS,
#  5 = неверный пароль/доступ).
# ---------------------------------------------------------------------------
adm_exec() {
    local host="$1" sport="$2" cmd="$3" out xrc
    ADM_OUT=""; ADM_RC=0
    if [ "${ADM_FAKE:-0}" = "1" ]; then          # локальный стенд (тесты, без сети)
        ADM_OUT="$(fake_router "$cmd")"
        ADM_RC=0
        return 0
    fi
    [ -n "$TL_PASS" ] || { ADM_RC=4; return 1; }
    out="$(ADM_HOST="$host" ADM_SPORT="$sport" ADM_LOGIN="$TL_USER" ADM_PASS="$TL_PASS" \
        ADM_CMD="$cmd" expect <<'EXP' 2>&1
set timeout 35
log_user 0
match_max 300000
spawn ssh -T -p $env(ADM_SPORT) -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR $env(ADM_LOGIN)@$env(ADM_HOST) $env(ADM_CMD)
set gotpw 0
expect {
    -re {[Pp]assword:} { send -- "$env(ADM_PASS)\r"; set gotpw 1 }
    -re {[Pp]ermission denied} { exit 5 }
    eof     { exit 2 }
    timeout { exit 3 }
}
if {!$gotpw} { exit 2 }
expect {
    eof     { puts -nonewline $expect_out(buffer); exit 0 }
    timeout { puts -nonewline $expect_out(buffer); exit 3 }
}
EXP
)"
    xrc=$?
    ADM_OUT="$out"
    case "$out" in
        *"Permission denied"*)                                     ADM_RC=5 ;;
        *"Connection refused"*|*"timed out"*|*"No route to host"*) ADM_RC=2 ;;
        *)                                                         ADM_RC=$xrc ;;
    esac
    return "$ADM_RC"
}

# Последняя строка-значение из вывода :put (мусор баннера не проходит).
put_val() { printf '%s\n' "$1" | tr -d '\r' | grep -E '^[A-Za-z0-9*][A-Za-z0-9*.,;:_+-]*$' | tail -n1; }

# Есть ли в выводе ошибка RouterOS (используется для записывающих команд).
out_err() {
    printf '%s\n' "$1" | grep -Ei 'failure:|syntax error|bad command|no such command|unknown command|invalid|denied|unable|wrong|not found|no such item' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
deploy_one() {
    # $1 host  $2 ssh-порт  $3 target  $4 rights_only  $5 npass (для нового user)
    local host="$1" sport="$2" target="$3" ro="$4" npass="$5"
    local req_pol tgroup
    req_pol="$(printf '%s' "${TARGET_POLICY:-ssh,read,write,test,reboot,policy,ftp}" | tr -d ' \t' | tr ';' ',')"
    tgroup="${TARGET_GROUP:-}"

    # ssh-exec одной строкой (без pty); вывод в ADM_OUT/ADM_RC
    adm() { adm_exec "$host" "$sport" "$1"; }

    # --- чтение версии RouterOS (в лог) ---
    adm "/system resource print"
    if [ "$ADM_RC" = "0" ]; then
        local vr
        vr="$(printf '%s\n' "$ADM_OUT" | tr -d '\r' | grep -oE 'version:[^A-Za-z]*[0-9]+\.[0-9]+' | head -n1)"
        [ -n "$vr" ] && echo "[INFO] $vr"
    fi

    # --- гарантировать наличие группы (создать с TARGET_POLICY при отсутствии) ---
    ensure_group_here() {
        local g="$1"
        adm ":put [/user group find name=$g]"
        if [ "$ADM_RC" != "0" ]; then
            echo "[ERR] нет ответа роутера при проверке группы '$g'"
            return 1
        fi
        if [ -n "$(put_val "$ADM_OUT")" ]; then
            echo "[INFO] группа '$g' уже существует"
            return 0
        fi
        adm "/user group add name=$g policy=$req_pol"
        if [ "$ADM_RC" != "0" ] || out_err "$ADM_OUT"; then
            echo "[ERR] не удалось создать группу '$g': $(printf '%s' "$ADM_OUT" | head -c 300)"
            return 1
        fi
        echo "[INFO] группа '$g' отсутствовала — создана с политиками: $req_pol"
        return 0
    }

    # --- политики группы: сначала :put get, при неудаче print detail ---
    # Результат: POL_TXT (csv) и POL_RC.
    pol_read() {
        local g="$1" p=""
        POL_TXT=""; POL_RC=1
        [ -z "$g" ] && return 1
        adm ":put [/user group get [find name=$g] policy]"
        if [ "$ADM_RC" = "0" ]; then
            p="$(printf '%s\n' "$ADM_OUT" | tr -d '\r' | grep -E '^"?[A-Za-z][A-Za-z0-9,; _-]*"?$' | tail -n1 | tr -d '"')"
        fi
        if [ -z "$p" ]; then
            adm "/user group print detail where name=$g"
            if [ "$ADM_RC" = "0" ]; then
                p="$(printf '%s\n' "$ADM_OUT" | tr -d '\r' | grep -F "name=\"$g\"" | grep -oE 'policy="[^"]*"' | head -n1 | sed -E 's/^policy="(.*)"$/\1/')"
            fi
        fi
        p="$(printf '%s' "$p" | tr -d ' \t' | tr ';' ',' | sed -E 's/,+$//')"
        POL_TXT="$p"
        [ -n "$p" ] && { POL_RC=0; return 0; }
        return 1
    }

    # --- ключ способом file+import (RouterOS 6.43+); 0 = ок ---
    install_key_import() {
        adm "/file print file=mkkey.txt"          # гарантируем наличие файла
        [ "$ADM_RC" = "0" ] || { echo "[WARN] не удалось создать файл mkkey.txt"; return 1; }
        adm "/file set mkkey.txt contents=\"$KEY_TEXT\""
        if [ "$ADM_RC" != "0" ] || out_err "$ADM_OUT"; then
            adm "/file print file=mkkey.txt"
            adm "/file set mkkey.txt contents=\"$KEY_TEXT\""
            if [ "$ADM_RC" != "0" ] || out_err "$ADM_OUT"; then
                echo "[WARN] не удалось записать ключ в файл mkkey.txt"
                return 1
            fi
        fi
        adm "/user ssh-keys import user=$target public-key-file=mkkey.txt"
        local imout="$ADM_OUT" imrc="$ADM_RC"
        adm "/file remove [find name=mkkey.txt]"
        if [ "$imrc" != "0" ] || out_err "$imout"; then
            echo "[WARN] file+import не принят роутером: $(printf '%s' "$imout" | head -c 200)"
            return 1
        fi
        if printf '%s\n' "$imout" | grep -qiE 'already|unchanged'; then
            echo "[OK] ключ уже был установлен ранее ($target) — повторно не добавляем"
        else
            echo "[INFO] ключ импортирован пользователю $target (file+import)"
        fi
        return 0
    }

    # --- недостающие требуемые политики (csv; пусто = все на месте) ---
    missing_policies_csv() {
        local pol="$1" req="$2" miss="" tok t
        if [ -z "$pol" ]; then printf '%s' "$req"; return 0; fi
        local IFS=,
        for tok in $req; do
            [ -z "$tok" ] && continue
            local found=0
            for t in $pol; do
                if [ "$t" = "$tok" ]; then found=1; break; fi
            done
            if [ "$found" = "0" ]; then
                if [ -n "$miss" ]; then miss="$miss,$tok"; else miss="$tok"; fi
            fi
        done
        printf '%s' "$miss"
    }

    # --- гарантировать, что группа $1 покрывает требуемые политики $2 ---
    # Читаем политики группы и добавляем недостающие (дополнение, не замена).
    # Если чтение политик на роутере не работает (старые RouterOS 6 / нет прав
    # на просмотр) — группу принудительно приводим к полному требуемому набору:
    # это проектная группа под backupUser, а иначе хардненинг не сможет заливать
    # скрипты по scp (RouterOS даёт file-доступ только при политике ftp).
    grp_fill_pol() {
        local g="$1" req="$2" cur miss
        [ -z "$g" ] && return 0
        cur=""
        pol_read "$g" && cur="$POL_TXT"
        miss="$(missing_policies_csv "$cur" "$req")"
        if [ -z "$miss" ]; then
            return 0
        fi
        if [ -n "$cur" ]; then
            adm "/user group set [find name=$g] policy=$cur,$miss"
            if [ "$ADM_RC" != "0" ] || out_err "$ADM_OUT"; then
                echo "[WARN] не удалось дополнить группу '$g' политиками: $miss"
                return 1
            fi
            echo "[INFO] группа '$g' дополнена политиками: $miss"
        else
            adm "/user group set [find name=$g] policy=$req"
            if [ "$ADM_RC" != "0" ] || out_err "$ADM_OUT"; then
                echo "[WARN] не удалось установить группе '$g' требуемые политики ($req): $(printf '%s' "$ADM_OUT" | head -c 200)"
                return 1
            fi
            echo "[INFO] группа '$g' — политики не читались; установлен требуемый набор: $req"
        fi
        return 0
    }

    # --- проверка/доводка прав ---
    do_rights_fix() {
        local cur pol_cur
        # текущая группа пользователя
        cur=""
        adm ":put [/user get [find name=$target] group]"
        if [ "$ADM_RC" = "0" ]; then cur="$(put_val "$ADM_OUT")"; fi
        echo "[INFO] текущая группа пользователя '$target': ${cur:-не определена}"

        # политики текущей группы
        pol_cur=""
        if [ -n "$cur" ]; then
            pol_read "$cur" && pol_cur="$POL_TXT"
        fi
        if [ -n "$pol_cur" ]; then
            echo "[INFO] группа '$cur' — политики: $pol_cur"
        else
            echo "[INFO] группа '${cur:-?}' — политики не прочитаны/пусты"
        fi

        # решаем, нужен ли перевод в целевую группу
        local need_fix=0 reason=""
        if [ -n "$tgroup" ] && [ -n "$cur" ]; then
            if [ "$cur" != "$tgroup" ]; then
                # 'full' — всегда уводим (нужны минимальные права, не все);
                # прочие группы — только если политик не хватает или они не читаются
                if [ "$cur" = "full" ] || [ -z "$pol_cur" ] || \
                   [ -n "$(missing_policies_csv "$pol_cur" "$req_pol")" ]; then
                    need_fix=1
                    reason="текущая группа '$cur' не подходит (нужна '$tgroup' с политиками $req_pol)"
                fi
            fi
        elif [ -n "$tgroup" ] && [ "$ro" = "1" ] && [ -z "$cur" ]; then
            need_fix=1
            reason="текущая группа не определяется"
        fi

        if [ "$need_fix" = "1" ]; then
            if ! ensure_group_here "$tgroup"; then return 1; fi
            # целевая группа должна покрывать требуемые политики (в т.ч. ftp для scp-загрузки)
            grp_fill_pol "$tgroup" "$req_pol" || true

            echo "[INFO] перевожу пользователя '$target' в группу '$tgroup' ($reason)"
            adm "/user set [find name=$target] group=$tgroup"
            if [ "$ADM_RC" != "0" ] || out_err "$ADM_OUT"; then
                echo "[ERR] не удалось изменить группу пользователя $target: $(printf '%s' "$ADM_OUT" | head -c 300)"
                return 1
            fi
            # контроль: перечитать группу; при расхождении — одна повторная попытка
            local rb=""
            adm ":put [/user get [find name=$target] group]"
            if [ "$ADM_RC" = "0" ]; then rb="$(put_val "$ADM_OUT")"; fi
            if [ "$rb" != "$tgroup" ]; then
                adm "/user set [find name=$target] group=$tgroup"
                adm ":put [/user get [find name=$target] group]"
                if [ "$ADM_RC" = "0" ]; then rb="$(put_val "$ADM_OUT")"; fi
            fi
            if [ "$rb" = "$tgroup" ]; then
                echo "[INFO] группа пользователя '$target' подтверждена в сессии: $rb"
                cur="$rb"
            else
                echo "[WARN] группа после установки = '${rb:-не читается}' (ожидалось '$tgroup') — итог решит SSH-контроль"
                cur="${rb:-$cur}"
            fi
        else
            if [ -n "$tgroup" ] && [ "$cur" = "$tgroup" ]; then
                # уже в целевой группе — довести её политики до требуемых
                grp_fill_pol "$tgroup" "$req_pol" || true
                local fpol=""
                pol_read "$tgroup" && fpol="$POL_TXT"
                if [ -n "$fpol" ] && [ -z "$(missing_policies_csv "$fpol" "$req_pol")" ]; then
                    echo "[INFO] права в порядке: пользователь уже в группе '$tgroup', требуемые политики на месте"
                fi
            elif [ -n "$pol_cur" ] && [ -z "$(missing_policies_csv "$pol_cur" "$req_pol")" ]; then
                echo "[INFO] права достаточны: группа '$cur' уже даёт все требуемые политики ($req_pol)"
            else
                echo "[INFO] права не меняю (TARGET_GROUP не задан или группа не определяется)"
            fi
        fi

        if [ "$ro" = "1" ]; then
            echo ""
            echo "[OK] права пользователя '$target' проверены и достаточны (группа: ${cur:-?})"
        else
            echo ""
            echo "[OK] ключ установлен → $target на $host"
        fi
        return 0
    }

    if [ "$DRY_RUN" = "1" ]; then
        if [ "$ro" = "1" ]; then
            echo "[dry] $host — вход по ssh, правка прав → $target"
        else
            echo "[dry] $host — вход по ssh, ключ → $target"
        fi
        return 0
    fi

    # --- полная установка (ro=0): пользователь + ключ ---
    if [ "$ro" != "1" ]; then
        local has_user=1
        adm ":put [/user find name=$target]"
        if [ "$ADM_RC" != "0" ] || [ -z "$(put_val "$ADM_OUT")" ]; then
            has_user=0
        fi
        if [ "$has_user" = "0" ]; then
            echo "[INFO] пользователь '$target' на роутере не найден — создаю"
            local ugroup="$tgroup"
            [ -n "$ugroup" ] || ugroup="full"
            if [ -n "$tgroup" ]; then
                ensure_group_here "$tgroup" || return 1
            fi
            adm "/user add name=$target group=$ugroup password=\"$npass\""
            if [ "$ADM_RC" != "0" ] || out_err "$ADM_OUT"; then
                echo "[ERR] не удалось создать пользователя $target: $(printf '%s' "$ADM_OUT" | head -c 300)"
                return 1
            fi
            echo "[INFO] создан пользователь '$target' (группа $ugroup)"
        else
            echo "[INFO] пользователь '$target' уже есть — устанавливаю только ключ/права"
        fi

        # ключ: file+import (6.43+); при неудаче — inline
        if ! install_key_import; then
            echo "[WARN] способ file+import не сработал — пробую inline"
            adm "/user set [find name=$target] ssh-key=\"$KEY_TEXT\""
            if [ "$ADM_RC" != "0" ] || out_err "$ADM_OUT"; then
                echo "[ERR] не удалось назначить SSH-ключ пользователю $target"
                return 1
            fi
            echo "[INFO] ключ назначен inline (старый RouterOS)"
        fi
    fi

    # --- права ---
    do_rights_fix
    return $?
}

# ---------------------------------------------------------------------------
# Основной цикл по devices.conf
# ---------------------------------------------------------------------------
OK=0; SKIP=0; FAIL=0
# desc (5-е поле, комментарий к устройству) намеренно не используется
# shellcheck disable=SC2034
while IFS=':' read -r name ip port user desc; do
    case "$name" in ""|\#*) continue;; esac
    name=$(echo "$name" | tr -d '\r'); ip=$(echo "$ip" | tr -d '\r')
    port=$(echo "$port" | tr -d '\r')
    if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ]; then continue; fi
    # целевой пользователь: глобальный TARGET_USER или user из devices.conf
    local_target="${TARGET_USER:-$user}"
    local_target=$(echo "$local_target" | tr -d '\r')
    if [ -z "$local_target" ]; then
        echo "[$name] $ip — пустое поле user и не задан TARGET_USER, пропуск"
        FAIL=$((FAIL+1))
        continue
    fi
    # SSH-порт устройства берётся из devices.conf (3-е поле). Используется
    # ВЕЗДЕ, где деплой ходит по SSH: предпроверка ключа, чтение прав и вход
    # администратора. Пустое поле (или отсутствие) = стандартный порт 22.
    ssh_port="${port:-22}"

    # --- режим --check: только сообщаем, есть ли уже рабочий ключ ---
    if [ "$CHECK_ONLY" = "1" ]; then
        if ssh_key_works "$ip" "$ssh_port" "$local_target"; then
            g="?"; pol=""
            if [ -n "$TARGET_GROUP" ]; then
                g=$(ssh_user_group "$ip" "$ssh_port" "$local_target" 2>/dev/null) || g="?"
                pol=$(ssh_group_policy_of_user "$ip" "$ssh_port" "$local_target" 2>/dev/null) || pol=""
                if pol_has_all "$pol" "$(need_policies)"; then
                    echo "[check] [$name] $ip — ✅ ключ работает, права достаточны (группа '$g', политики: $pol)"
                else
                    echo "[check] [$name] $ip — ⚠️ ключ работает, но прав НЕ хватает/не подтверждено (группа '${g:-?}', политики: ${pol:-не прочитаны}) — нужен прогон"
                fi
            else
                echo "[check] [$name] $ip — ✅ ключ уже работает (права не проверяем: TARGET_GROUP пуст)"
            fi
            OK=$((OK+1))
        else
            echo "[check] [$name] $ip — ⚠️ ключа НЕТ, нужно разворачивание"
            FAIL=$((FAIL+1))
        fi
        continue
    fi

    # --- предпроверка SSH ---
    rights_only=0
    known=""   # текущая группа из SSH-предпроверки (резерв; в ssh-exec не используется)
    if [ "$SSH_PROBE" = "1" ]; then
        if ssh_key_works "$ip" "$ssh_port" "$local_target"; then
            # Ключ уже работает — ставить нечего. Но ПРАВА проверяем ВСЕГДА:
            # у ограниченного пользователя ключ есть, а обновления делать нельзя.
            if [ -z "$TARGET_GROUP" ]; then
                # TARGET_GROUP пуст — права не меняем, только показываем
                g=$(ssh_user_group "$ip" "$ssh_port" "$local_target" 2>/dev/null) || g="?"
                echo "====> [$name] $ip — ✅ ключ работает ($local_target), TARGET_GROUP пуст — права не меняю (текущая группа: $g)"
                SKIP=$((SKIP+1)); continue
            fi
            g=$(ssh_user_group "$ip" "$ssh_port" "$local_target") || g=""
            known="$g"
            # Точная проверка прав: сравниваем НЕ имя группы, а её реальные политики
            # (у пользователя может быть группа 'forbackup', уже дающая нужные права).
            pol=$(ssh_group_policy_of_user "$ip" "$ssh_port" "$local_target" 2>/dev/null) || pol=""
            if pol_has_all "$pol" "$(need_policies)"; then
                echo "====> [$name] $ip — ✅ ключ работает и права достаточны ($local_target: группа '$g', политики покрывают требуемые) — пропуск"
                SKIP=$((SKIP+1)); continue
            fi
            echo "====> [$name] $ip — ✅ ключ работает, но прав НЕ хватает/не подтверждено (группа '${g:-?}', политики: ${pol:-не прочитаны}) — захожу проверить/исправить"
            rights_only=1
        else
            echo "====> [$name] $ip — ключа нет, нужен вход администратора (ключ → $local_target)"
        fi
    else
        echo "====> [$name] $ip (без SSH-предпроверки)  ключ → $local_target"
    fi

    # --- вход администратора: ТОЛЬКО по SSH (telnet удалён) ---
    # Сюда попадаем только если реально нужен вход на роутер.
    via="ssh"
    admin_port="$ssh_port"
    echo "      вход: ssh $TL_USER@$ip:$admin_port"

    # --- dry-run: показать план и остановиться ---
    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry]     $ip — был бы вход по ssh ($TL_USER@$ip:$admin_port), ключ → $local_target"
        OK=$((OK+1))
        continue
    fi

    if ! ensure_client_deps; then
        echo "[$name] пропуск: нет expect/ssh или TL_PASS"
        FAIL=$((FAIL+1))
        continue
    fi
    ensure_utf8_locale
    npass="${NEWUSER_PASS:-mk-$(date +%s)-$RANDOM}"
    deploy_one "$ip" "$admin_port" "$local_target" "$rights_only" "$npass" 2>&1 | scrub_secrets "$npass" | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
    echo "      rc=$rc"
    if [ "$rc" -eq 0 ]; then
        if [ "$rights_only" = "1" ]; then
            # главный критерий: реальные политики группы пользователя теперь достаточны
            if [ "$SSH_VERIFY" = "1" ] && [ "$SSH_PROBE" = "1" ]; then
                g=$(ssh_user_group "$ip" "$ssh_port" "$local_target" 2>/dev/null) || g=""
                pol=$(ssh_group_policy_of_user "$ip" "$ssh_port" "$local_target" 2>/dev/null) || pol=""
                if [ -n "$g" ] && { pol_has_all "$pol" "$(need_policies)" || [ "$g" = "$TARGET_GROUP" ]; }; then
                    echo "      [OK] подтверждено по SSH: права '$local_target' достаточны (группа '$g', политики: ${pol:-<целевая группа>})"
                    OK=$((OK+1))
                else
                    echo "      [!!] права после исправления не подтвердились по SSH (группа '${g:-?}', политики: ${pol:-не читаются}) — нужна ручная проверка"
                    FAIL=$((FAIL+1))
                fi
            else
                OK=$((OK+1))
            fi
        elif [ "$SSH_VERIFY" = "1" ] && [ "$SSH_PROBE" = "1" ]; then
            # главный критерий успеха установки: ключ РЕАЛЬНО заходит по SSH.
            # (вывод expect-сессии может скрывать ошибки — доверяем только проверке входа)
            if ssh_key_works "$ip" "$ssh_port" "$local_target"; then
                echo "      [OK] подтверждено: ssh $local_target@$ip — ключ работает"
                OK=$((OK+1))
            else
                echo "      [!!] ключ заявлен установленным, но ssh $local_target@$ip НЕ работает — нужна ручная проверка"
                FAIL=$((FAIL+1))
            fi
        else
            OK=$((OK+1))
        fi
    else
        FAIL=$((FAIL+1))
    fi
done < "$DEVICES_CONF"

echo
echo "================ ИТОГ ================"
if [ "$CHECK_ONLY" = "1" ]; then
    echo "Ключ уже работает: $OK"
    echo "Ключа нет (нужно развернуть): $FAIL"
elif [ "$DRY_RUN" = "1" ]; then
    echo "Было бы пропущено (ключ уже есть): $SKIP"
    echo "Было бы развёрнуто (dry-run):      $OK"
    echo "Ошибок:                            $FAIL"
else
    echo "Уже настроено (пропущено): $SKIP"
    echo "Развёрнуто/успешно:        $OK"
    echo "Ошибок:                    $FAIL"
fi
echo "Подробности: $LOG"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1


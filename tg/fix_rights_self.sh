#!/bin/bash
# =============================================================================
# fix_rights_self.sh — добавить недостающие политики группе ПОЛЬЗОВАТЕЛЯ
# БЭКАПА, заходя на роутер ЕГО ЖЕ SSH-ключом (без администратора и пароля).
# -----------------------------------------------------------------------------
# Зачем: RouterOS не отдаёт .backup по scp/ftp без политики sensitive (и ftp).
# На роутерах, где пользователь бэкапа в группе forbackup (без sensitive),
# бэкап создаётся, но не скачивается. Обычный путь (tg/deploy_key.sh) требует
# пароль администратора. Но если группа уже содержит policy + write, RouterOS
# разрешает пользователю править собственную группу — и права можно выдать
# тем же ключом, которым делаются бэкапы.
#
# Что делает (три команды по SSH, каждая отдельной сессией):
#   1) читает группу пользователя;
#   2) читает политики этой группы;
#   3) если чего-то не хватает — /user group set policy=<текущие>,<недостающие>
#      (лишние политики не снимаются, группа пользователя не меняется),
#      затем перечитывает и проверяет результат.
#
# Использование:
#   bash tg/fix_rights_self.sh <устройство>|-all [--check]
#   bash tg/fix_rights_self.sh AP_U2_Conf
#
# Переменные окружения:
#   CONFIG_FILE   — devices.conf (по умолчанию рядом с репозиторием)
#   SSH_KEY       — приватный ключ (по умолчанию ~/.ssh/mk_key)
#   SSH_TIMEOUT   — таймаут подключения, сек (по умолчанию 10)
#   TARGET_POLICY — какие политики обязаны быть (по умолчанию
#                   ssh,read,write,test,policy,ftp,sensitive — без reboot)
#   MK_SSH_BIN    — бинарь ssh (для тестов)
#
# Коды возврата:
#   0 — права в порядке (при необходимости — только что добавлены);
#       в выводе видно, добавлены ли политики: «политики добавлены»
#   3 — выдать нельзя: у группы нет политики policy (нужен администратор)
#   1 — прочая ошибка (в т.ч. нет SSH-соединения — текст в выводе)
# В режиме -all: 0, если хотя бы одному устройству помогли/всё уже было;
# 3, если все упираются в отсутствие policy; иначе 1.
# Режим --check ничего не меняет: 0 = отчёт выдан, 3 = есть устройства,
# которым нужен администратор (у них нет policy/write).
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="${CONFIG_FILE:-${DEVICES_CONF:-$ROOT_DIR/devices.conf}}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/mk_key}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
# Какие политики обязаны быть у группы. reboot намеренно НЕ входит: он не
# нужен для .backup, а у части роутеров он осознанно запрещён (!reboot).
TARGET_POLICY="${TARGET_POLICY:-ssh,read,write,test,policy,ftp,sensitive}"
SSH_BIN="${MK_SSH_BIN:-ssh}"
CHECK_ONLY=0

usage() {
    sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- разбор аргументов -------------------------------------------------------
FILTER=""
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --check)   CHECK_ONLY=1 ;;
        -all|all)  FILTER="" ;;
        -*)        echo "неизвестный параметр: $arg" >&2; exit 1 ;;
        *)         FILTER="$arg" ;;
    esac
done

die() { echo "[ERR] $*" >&2; exit 1; }

[ -f "$CONFIG_FILE" ] || die "нет файла устройств: $CONFIG_FILE"
[ -f "$SSH_KEY" ]     || die "нет SSH-ключа: $SSH_KEY (укажите SSH_KEY=…)"
command -v "$SSH_BIN" > /dev/null 2>&1 || die "нет ssh ($SSH_BIN)"

# Одна команда RouterOS одной строкой, без pty (ssh-exec), с таймаутом.
ros_exec() {
    local host="$1" port="$2" user="$3" cmd="$4"
    "$SSH_BIN" -n -p "$port" -i "$SSH_KEY" \
        -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        -o HostKeyAlgorithms=+ssh-rsa \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout="$SSH_TIMEOUT" -o LogLevel=ERROR \
        "$user@$host" "$cmd" 2>&1 < /dev/null | tr -d '\r'
}

# Нормализация списка политик: без пробелов/переносов, через запятую.
# RouterOS печатает длинный список с переносами и отступами, а запрещённые
# политики — со знаком "!" впереди (например: ssh;ftp;!local;!sensitive).
# Поэтому: убираем любые пробелы/переводы строк, ";" заменяем на ",".
norm_pol() {
    printf '%s' "$1" | tr -d ' \t\r\n' | tr ';' ',' \
        | sed -E 's/^,+//; s/,+$//; s/,,+/,/g'
}

# Вытащить из произвольного вывода RouterOS сам список политик.
# Берём самый длинный фрагмент из допустимых символов, содержащий разделитель.
parse_pol() {
    local flat cand
    flat=$(printf '%s' "$1" | tr -d ' \t\r\n')
    cand=$(printf '%s\n' "$flat" \
        | grep -oE '[A-Za-z!][A-Za-z0-9!;,_-]+' 2>/dev/null \
        | awk 'index($0,";") || index($0,",")' \
        | awk '{print length($0)"\t"$0}' \
        | sort -rn | head -1 | cut -f2-)
    printf '%s' "$(norm_pol "$cand")"
}

# Политики из $2 (требуемые), которых НЕТ в $1 (текущие).
# Запрет "!sensitive" также считается отсутствием.
missing_pol() {
    local have=",$(norm_pol "$1")," want="$2" tok miss=""
    local IFS=,
    for tok in $want; do
        [ -z "$tok" ] && continue
        case "$have" in
            *",$tok,"*) ;;
            *) if [ -n "$miss" ]; then miss="$miss,$tok"; else miss="$tok"; fi ;;
        esac
    done
    printf '%s' "$miss"
}

# Слить текущий список с недостающими политиками.
# Разрешающие политики сохраняются, запреты "!X" для выдаваемых X снимаются,
# недостающие X добавляются в конец. Разделитель для RouterOS — запятая.
merge_pol() {
    local cur="$1" miss="$2" tok want out="" drop
    local -a toks=() kept=() wants=()
    local IFS=','
    for tok in $cur; do [ -n "$tok" ] && toks+=("$tok"); done
    IFS=' ' read -r -a wants <<< "$(printf '%s' "$miss" | tr ',' ' ')"
    for tok in "${toks[@]}"; do
        drop=0
        for want in "${wants[@]}"; do
            [ "$tok" = "!$want" ] && drop=1
        done
        [ "$drop" = "0" ] && kept+=("$tok")
    done
    for want in "${wants[@]}"; do
        [ -n "$want" ] && kept+=("$want")
    done
    for tok in "${kept[@]}"; do
        if [ -n "$out" ]; then out="$out,$tok"; else out="$tok"; fi
    done
    printf '%s' "$out"
}

RESULT_FIXED=0
RESULT_CANNOT=0
RESULT_OK=0
RESULT_DOWN=0
RESULT_NEED=0

process_one() {
    local name="$1" ip="" port="" user="" line group pol miss cmd out rc
    line=$(awk -F: -v n="$name" '$1==n{print; exit}' "$CONFIG_FILE")
    [ -n "$line" ] || { echo "[ERR] $name: нет в $CONFIG_FILE"; return 1; }
    IFS=':' read -r _ ip port user _ <<< "$line"
    [ -n "$user" ] || { echo "[ERR] $name: пустое поле user в devices.conf"; return 1; }
    port="${port:-22}"

    # 1) группа пользователя
    out=$(ros_exec "$ip" "$port" "$user" ":put [/user get [find name=$user] group]")
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$(printf '%s' "$out" | tr -d '\n')" ]; then
        if printf '%s' "$out" | grep -qiE 'connection timed out|connection refused|no route to host|could not resolve|Connection closed'; then
            echo "[ERR] $name ($ip:$port): нет соединения — $(printf '%s' "$out" | tail -1)"
            return 2
        fi
        echo "[ERR] $name: не удалось прочитать группу пользователя $user: $(printf '%s' "$out" | tail -1)"
        return 3
    fi
    group=$(printf '%s\n' "$out" | tr -d '\r' | grep -E '^[A-Za-z0-9*][A-Za-z0-9*._-]*$' | tail -1)
    [ -n "$group" ] || { echo "[ERR] $name: группа пользователя $user не определена"; return 3; }

    # 2) политики группы
    out=$(ros_exec "$ip" "$port" "$user" ":put [/user group get [find name=$group] policy]")
    rc=$?
    pol=$(parse_pol "$out")
    if [ "$rc" -ne 0 ] || [ -z "$pol" ]; then
        echo "[ERR] $name: не удалось прочитать политики группы '$group': $(printf '%s' "$out" | tr -d '\r' | tr -s ' \n' ' ' | cut -c1-300)"
        return 3
    fi
    miss=$(missing_pol "$pol" "$TARGET_POLICY")

    if [ -z "$miss" ]; then
        echo "[OK] $name: права в порядке (группа '$group': $pol)"
        return 0
    fi
    echo "[INFO] $name: группа '$group' — политики: $pol; не хватает: $miss"

    if [ "$CHECK_ONLY" = "1" ]; then
        echo "[WARN] $name: нужны политики: $miss (режим --check, ничего не меняю)"
        return 4
    fi

    # 3) добавляем недостающие (лишние не снимаем, группу не меняем)
    local merged
    merged="$(merge_pol "$pol" "$miss")"
    cmd="/user group set [find name=$group] policy=$merged"
    out=$(ros_exec "$ip" "$port" "$user" "$cmd")
    rc=$?
    if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -qiE 'not enough permissions|permission denied|denied|failure|no such item|invalid|error'; then
        local why
        why=$(printf '%s' "$out" | grep -viE '^$' | tail -1)
        echo "[ERR] $name: добавить политики не удалось: ${why:-rc=$rc}"
        if printf '%s' "$out" | grep -qiE 'not enough permissions|permission denied|denied'; then
            echo "      группе '$group' не хватает прав на управление пользователями (нужны политики policy и write) —"
            echo "      сам себе пользователь их добавить не может; нужен администратор (DEPLOY_TL_PASS) или вручную: $cmd"
            return 3
        fi
        return 1
    fi

    # 4) проверяем результат новым подключением
    out=$(ros_exec "$ip" "$port" "$user" ":put [/user group get [find name=$group] policy]")
    pol=$(parse_pol "$out")
    miss=$(missing_pol "$pol" "$TARGET_POLICY")
    if [ -n "$miss" ]; then
        echo "[ERR] $name: политики не применились, всё ещё нет: $miss"
        return 1
    fi
    echo "[OK] $name: политики добавлены — группа '$group': $pol"
    return 10
}

status=0
found=0
while IFS=: read -r name _; do
    case "$name" in ""|\#*) continue ;; esac
    name=$(printf '%s' "$name" | tr -d '\r')
    if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ]; then continue; fi
    found=$((found + 1))
    process_one "$name"
    case $? in
        0)  RESULT_OK=$((RESULT_OK + 1)) ;;
        10) RESULT_OK=$((RESULT_OK + 1)); RESULT_FIXED=$((RESULT_FIXED + 1)) ;;
        4)  RESULT_NEED=$((RESULT_NEED + 1)) ;;
        3)  RESULT_CANNOT=$((RESULT_CANNOT + 1)); status=3 ;;
        2)  RESULT_DOWN=$((RESULT_DOWN + 1)); [ "$status" -eq 0 ] && status=1 ;;
        *)  status=1 ;;
    esac
done < "$CONFIG_FILE"

[ "$found" -gt 0 ] || { echo "[ERR] устройство '$FILTER' не найдено в $CONFIG_FILE"; exit 1; }

# Итог одной строкой — удобно для парсинга в MikroGit.sh / боте
echo "ИТОГ: в порядке/выдано $RESULT_OK (из них выдано сейчас $RESULT_FIXED), нужно поправить $RESULT_NEED, нельзя без админа $RESULT_CANNOT, нет связи $RESULT_DOWN"
if [ "$RESULT_OK" -gt 0 ]; then exit 0; fi
if [ "$CHECK_ONLY" = "1" ]; then
    # отчёт: 0 = всё понятно (даже если что-то нужно поправить),
    # 3 = есть устройства, где без администратора не обойтись
    [ "$RESULT_CANNOT" -gt 0 ] && exit 3
    [ "$RESULT_DOWN" -gt 0 ] && exit 1
    exit 0
fi
[ "$status" -eq 0 ] && status=3
exit "$status"

#!/bin/bash
# =============================================================================
# Развёртывание SSH-ключа MikroGit на MikroTik-роутерах по TELNET.
# -----------------------------------------------------------------------------
# Хосты берутся из devices.conf (IP и порт оттуда верны), но подключение по
# telnet выполняется ОТДЕЛЬНЫМ административным пользователем (TL_USER),
# а НЕ тем, что указан в devices.conf. Ключ назначается целевому пользователю
# (TARGET_USER): если он уже существует на роутере — только импорт ключа;
# если не существует — создаётся (группа full) с паролем из NEWUSER_PASS
# (или случайным) и импортируется ключ.
#
# Параметры: 1) переменные окружения, 2) файл deploy.conf рядом со скриптом
# (приоритет у окружения: строки deploy.conf применяются, только если
# соответствующая переменная окружения пуста).
#
# Зависимости: expect, telnet (sudo apt-get install -y expect telnet)
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
TL_USER="${TL_USER:-admin}"          # логин для входа по telnet
TL_PORT="${TL_PORT:-23}"             # порт telnet (стандартный)
TL_PASS="${TL_PASS:-}"               # пароль для входа по telnet (обязателен)
TARGET_USER="${TARGET_USER:-}"       # кому назначить ключ (если пусто — берётся user из devices.conf для каждого хоста)
NEWUSER_PASS="${NEWUSER_PASS:-}"     # пароль для СОЗДАВАЕМОГО пользователя (если TARGET_USER не существует)

# ---------------------------------------------------------------------------
# Разбор аргументов (--dry-run, --check) и фильтр устройства
# ---------------------------------------------------------------------------
DRY_RUN=0
CHECK_ONLY=0
FILTER=""
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        --check)   CHECK_ONLY=1 ;;
        --help|-h)
            echo "Использование: $0 [--dry-run|--check] [имя_устройства]"
            echo "Env/конфиг: DEVICES_CONF, KEY_FILE, TL_USER, TL_PORT, TL_PASS, TARGET_USER, NEWUSER_PASS"
            exit 0 ;;
        --*) echo "Неизвестный аргумент: $a" >&2; exit 2 ;;
        *)   [ -z "$FILTER" ] && FILTER="$a" || { echo "Лишний аргумент: $a" >&2; exit 2; } ;;
    esac
done

# ---------------------------------------------------------------------------
# Валидация
# ---------------------------------------------------------------------------
[ -f "$DEVICES_CONF" ] || { echo "ERROR: devices.conf не найден: $DEVICES_CONF" >&2; exit 1; }
[ -f "$KEY_FILE" ] || {
    echo "ERROR: публичный ключ не найден: $KEY_FILE" >&2
    echo "Создайте: ssh-keygen -t rsa -b 4096 -f ${KEY_FILE%.pub} -N ''" >&2
    exit 1
}
if [ "$CHECK_ONLY" = "0" ] && [ "$DRY_RUN" = "0" ]; then
    command -v expect >/dev/null 2>&1 || { echo "ERROR: установите expect (apt-get install -y expect)" >&2; exit 1; }
    command -v telnet >/dev/null 2>&1 || { echo "ERROR: установите telnet (apt-get install -y telnet)" >&2; exit 1; }
    [ -n "$TL_PASS" ] || { echo "ERROR: задайте TL_PASS (пароль telnet)" >&2; exit 1; }
fi

KEY_TEXT=$(tr -d '\r\n' < "$KEY_FILE")
LOG="deploy_key_$(date +%Y%m%d_%H%M%S).log"

echo "devices.conf : $DEVICES_CONF"
echo "ключ         : $KEY_FILE"
echo "telnet вход  : $TL_USER@<ip>:$TL_PORT"
echo "целевой user : ${TARGET_USER:-<из devices.conf, поле 4>}"
[ "$DRY_RUN" = "1" ] && echo "РЕЖИМ: dry-run (без подключения)"
[ "$CHECK_ONLY" = "1" ] && echo "РЕЖИМ: только проверка входа (--check)"
[ -n "$FILTER" ] && echo "Фильтр устройства: $FILTER"
echo "лог          : $LOG"

# ---------------------------------------------------------------------------
# Обработка одного устройства через expect-сессию telnet
# ---------------------------------------------------------------------------
# Возврат: 0=ok, 1=ключ уже был/не критично, 4=ошибка входа, 5=не удалось назначить
deploy_one() {
    local host="$1" tport="$2" target="$3"

    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry] $host:$tport — telnet-вход $TL_USER, ключ → $target"
        return 0
    fi

    if [ "$CHECK_ONLY" = "1" ]; then
        DU_HOST="$host" DU_PORT="$tport" DU_LOGIN="$TL_USER" DU_PASS="$TL_PASS" \
        expect <<'EXP' > /dev/null 2>&1
set timeout 25
set host $env(DU_HOST); set port $env(DU_PORT)
set login $env(DU_LOGIN); set pass $env(DU_PASS)
spawn telnet $host $port
expect {
    -re "Login:" { send -- "$login\r" }
    -re "\\] >" { }
    timeout { exit 2 }
    eof { exit 3 }
}
expect {
    -re "Password:" { send -- "$pass\r" }
    timeout { exit 4 }
    eof { exit 4 }
}
expect {
    -re "\\] >" { exit 0 }
    -re "(Login incorrect|failed)" { exit 5 }
    timeout { exit 6 }
}
EXP
        local rc=$?
        if [ "$rc" -eq 0 ]; then echo "[check] $host: вход OK"; else echo "[check] $host: вход НЕ удался (rc=$rc)"; fi
        return "$rc"
    fi

    DU_HOST="$host" DU_PORT="$tport" DU_LOGIN="$TL_USER" DU_TARGET="$target" \
    DU_PASS="$TL_PASS" DU_KEY="$KEY_TEXT" DU_NPASS="${NEWUSER_PASS:-mk-$(date +%s)-$RANDOM}" \
    expect <<'EXP' 2>&1 | tee -a "$LOG"
set timeout 45
set host   $env(DU_HOST)
set port   $env(DU_PORT)
set login  $env(DU_LOGIN)
set target $env(DU_TARGET)
set pass   $env(DU_PASS)
set key    $env(DU_KEY)
set npass  $env(DU_NPASS)

proc wait_prompt {} {
    while {1} {
        expect {
            -re "--\[Mm\]ore--"   { send -- " "; continue }
            -re "\\] >"           { return 0 }
            -re "Login:"          { return 1 }
            timeout               { return 2 }
            eof                   { return 3 }
        }
    }
}

# --- соединение + логин ---
spawn telnet $host $port
expect {
    -re "Login:" { send -- "$login\r" }
    -re "\\] >"  {}
    timeout      { puts "\n[ERR] нет Login (telnet закрыт?)"; exit 2 }
    eof          { puts "\n[ERR] соединение закрыто (недоступен порт?)"; exit 3 }
}
expect {
    -re "Password:" { send -- "$pass\r" }
    timeout { puts "\n[ERR] нет запроса пароля"; exit 4 }
    eof     { puts "\n[ERR] соединение закрыто"; exit 4 }
}
set r [wait_prompt]
if {$r == 1} { puts "\n[ERR] неверный логин/пароль"; exit 5 }
if {$r != 0} { puts "\n[ERR] нет приглашения роутера"; exit 6 }
puts "[OK] вошли на $host"

# --- версия RouterOS ---
send -- "/system resource print\r"
wait_prompt
set out $expect_out(buffer)
set major 0; set minor 0
if {[regexp -nocase {version:[ \t]*([0-9]+)\.([0-9]+)} $out -> mj mn]} { set major $mj; set minor $mn }
puts "[INFO] RouterOS $major.$minor"

# --- есть ли целевой пользователь? ---
send -- "/user print\r"
wait_prompt
set uout $expect_out(buffer)
set exists [regexp -nocase "name=\"?$target\"?|name=$target" $uout]

if {$exists == 0} {
    puts "[INFO] пользователь '$target' не найден — создаю (group=full)"
    set cmd {}
    append cmd {/user add name=} $target { group=full password="} $npass "\""
    send -- "$cmd\r"
    wait_prompt
    set uout2 $expect_out(buffer)
    if {[regexp -nocase {failure|unable|already exists} $uout2]} {
        puts "\n[ERR] не удалось создать пользователя $target: $uout2"
        send -- "quit\r"
        exit 7
    }
    puts "[INFO] создан пользователь $target (пароль задан, но бот входит по ключу)"
    set exists 1
}

# --- способ 1: file + import (v6.43+/v7) ---
set imported 0
if {$major > 6 || ($major == 6 && $minor >= 43)} {
    send -- "/file print file=mkkey\r"
    wait_prompt
    send -- "/file set mkkey.txt contents=\"$key\"\r"
    wait_prompt
    send -- "/user ssh-keys import user=$target public-key-file=mkkey.txt\r"
    wait_prompt
    set impout $expect_out(buffer)
    puts "-- import: $impout"
    if {[regexp -nocase {failure|unable|invalid|syntax|no such|could not|denied|wrong format|not found|unknown} $impout]} {
        puts "[WARN] file+import не сработал ($impout), пробую inline"
    } else {
        set imported 1
    }
    set rmcmd {}
    append rmcmd {/file remove [find name=mkkey.txt]}
    send -- "$rmcmd\r"
    wait_prompt
}

# --- способ 2: inline (старые v6 / сбой способа 1) ---
if {$imported == 0} {
    set cmd {}
    append cmd {/user set [find name=} $target {] ssh-key="} $key "\""
    send -- "$cmd\r"
    wait_prompt
    set inlout $expect_out(buffer)
    puts "-- inline: $inlout"
    if {[regexp -nocase {failure|unable|invalid|no such|syntax|not found|unknown} $inlout]} {
        puts "\n[ERR] НЕ удалось назначить ключ пользователю $target"
        send -- "quit\r"
        exit 8
    }
    set imported 1
}

send -- "quit\r"
if {$imported} { puts "\n[OK] ключ установлен → $target на $host"; exit 0 }
exit 9
EXP
    return $?
}

# ---------------------------------------------------------------------------
# Основной цикл по devices.conf
# ---------------------------------------------------------------------------
OK=0; FAIL=0
while IFS=':' read -r name ip port user desc; do
    case "$name" in ""|\#*) continue;; esac
    name=$(echo "$name" | tr -d '\r'); ip=$(echo "$ip" | tr -d '\r')
    if [ -n "$FILTER" ] && [ "$name" != "$FILTER" ]; then continue; fi
    # целевой пользователь: глобальный TARGET_USER или user из devices.conf
    local_target="${TARGET_USER:-$user}"
    local_target=$(echo "$local_target" | tr -d '\r')

    echo "====> [$name] $ip (telnet :$TL_PORT)  ключ → $local_target"
    deploy_one "$ip" "$TL_PORT" "$local_target"
    rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then OK=$((OK+1)); else FAIL=$((FAIL+1)); fi
    echo "      rc=$rc"
done < "$DEVICES_CONF"

echo
echo "================ ИТОГ ================"
echo "Успешно/пропущено: $OK   Ошибок: $FAIL"
echo "Подробности: $LOG"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

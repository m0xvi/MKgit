#!/bin/bash
# =============================================================================
# Развёртывание SSH-ключа MikroGit на MikroTik-роутерах: вход администратора по
# TELNET или по SSH (LOGIN_VIA=auto/telnet/ssh). SSH нужен для роутеров, где
# telnet отключён.
# -----------------------------------------------------------------------------
# Хосты берутся из devices.conf (IP и порт оттуда верны), но подключение по
# telnet выполняется ОТДЕЛЬНЫМ административным пользователем (TL_USER),
# а НЕ тем, что указан в devices.conf. Ключ назначается целевому пользователю
# (TARGET_USER): если он уже существует на роутере — только импорт ключа;
# если не существует — создаётся в группе TARGET_GROUP с паролем из
# NEWUSER_PASS (или случайным) и импортируется ключ.
#
# ПРАВА: вместо встроенной группы full (все политики) деплой приводит целевого
# пользователя к отдельной группе TARGET_GROUP (по умолчанию «automation») с
# МИНИМАЛЬНЫМ набором политик TARGET_POLICY (по умолчанию
# ssh,read,write,test,reboot,policy). Если группа отсутствует на роутере — она
# создаётся с этими политиками; существующая группа не переопределяется
# (только если пользователь в неё ещё не переведён). TARGET_GROUP="" = права
# не менять (только проверка/показ).
#
# Параметры: 1) переменные окружения, 2) файл deploy.conf рядом со скриптом
# (приоритет у окружения: строки deploy.conf применяются, только если
# соответствующая переменная окружения пуста).
#
# Зависимости: expect + telnet (для LOGIN_VIA=telnet) и/или ssh
# (sudo apt-get install -y expect telnet openssh-client)
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
TL_USER="${TL_USER:-admin}"          # логин для входа по telnet
TL_PORT="${TL_PORT:-23}"             # порт telnet (стандартный)
TL_PASS="${TL_PASS:-}"               # пароль для входа по telnet (обязателен)
TARGET_USER="${TARGET_USER:-}"       # кому назначить ключ (если пусто — берётся user из devices.conf для каждого хоста)
# Группа, в которую должен входить целевой пользователь (вместо «full»).
# По умолчанию — отдельная группа automation с МИНИМАЛЬНЫМ набором политик
# (TARGET_POLICY). Если задать пустым — права НЕ трогаются (только проверка).
TARGET_GROUP="${TARGET_GROUP-automation}"
# Политики группы TARGET_GROUP — применяются, когда группа создаётся этим
# скриптом (если группы на роутере ещё нет). Существующая группа НЕ меняется.
# Минимальный набор, достаточный для задач бота (бэкапы + проверка/установка
# обновлений RouterOS через сам роутер + RouterBOOT): ssh,read,write,test,reboot,policy.
TARGET_POLICY="${TARGET_POLICY-ssh,read,write,test,reboot,policy}"
NEWUSER_PASS="${NEWUSER_PASS:-}"     # пароль для СОЗДАВАЕМОГО пользователя (если TARGET_USER не существует)
SSH_PROBE="${SSH_PROBE:-1}"          # проверять ли SSH-вход перед telnet (1/0). 0 = всегда заходить по telnet
SSH_TIMEOUT="${SSH_TIMEOUT:-8}"      # таймаут SSH-проверки на устройство, сек
SSH_VERIFY="${SSH_VERIFY:-1}"        # подтверждать ли ключ повторной SSH-проверкой после развёртывания
# Транспорт входа АДМИНИСТРАТОРА (TL_USER) на роутер для развёртывания/правки прав:
#   telnet — всегда telnet (:TL_PORT),  ssh — всегда ssh (:ssh-порт устройства),
#   auto   — telnet, если порт открыт, иначе ssh (для роутеров с отключённым telnet).
LOGIN_VIA="${LOGIN_VIA:-auto}"

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
            echo "Env/конфиг: DEVICES_CONF, KEY_FILE, KEY_PRIV, TL_USER, TL_PORT, TL_PASS, TARGET_USER, TARGET_GROUP, TARGET_POLICY, NEWUSER_PASS, LOGIN_VIA, SSH_PROBE, SSH_TIMEOUT, SSH_VERIFY"
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
        echo "      Скрипт будет разворачивать ключ на всех устройствах через telnet."
        SSH_PROBE=0
    fi
fi
# expect/telnet/TL_PASS проверяем ЛЕНИВО — только когда реально понадобится
# заход по telnet (если все устройства уже настроены — они не нужны).
_TELNET_OK=        # 1 = deps проверены и есть
_TELNET_ERR=       # 1 = ошибка уже напечатана (не дублировать на каждый роутер)
ensure_client_deps() {
    # Перед реальным заходом администратора (telnet/ssh). Кэшируем expect/TL_PASS;
    # сам клиент (telnet/ssh) проверяем под выбранный транспорт (это дёшево).
    if [ -n "$_TELNET_ERR" ]; then return 1; fi
    if [ -z "$_TELNET_OK" ]; then
        if ! command -v expect >/dev/null 2>&1; then
            _TELNET_ERR=1; echo "ERROR: установите expect (apt-get install -y expect)" >&2; return 1
        fi
        if [ -z "$TL_PASS" ]; then
            _TELNET_ERR=1; echo "ERROR: задайте TL_PASS (пароль администратора $TL_USER)" >&2; return 1
        fi
        _TELNET_OK=1
    fi
    if [ "$1" = "ssh" ]; then
        if ! command -v ssh >/dev/null 2>&1; then
            echo "ERROR: установите openssh-client (ssh)" >&2; return 1
        fi
    elif ! command -v telnet >/dev/null 2>&1; then
        echo "ERROR: установите telnet (apt-get install -y telnet)" >&2; return 1
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

# Открыт ли TCP-порт (для выбора транспорта: telnet/ssh)
tcp_open() {
    [ -n "$2" ] || return 1
    timeout "$SSH_TIMEOUT" bash -c "</dev/tcp/$1/$2" 2>/dev/null
}

KEY_TEXT=$(tr -d '\r\n' < "$KEY_FILE")
LOG="deploy_key_$(date +%Y%m%d_%H%M%S).log"

echo "devices.conf : $DEVICES_CONF"
echo "ключ         : $KEY_FILE"
echo "SSH-проверка : $([ "$SSH_PROBE" = "1" ] && echo "вкл (${KEY_PRIV})" || echo "выкл")"
echo "транспорт    : LOGIN_VIA=$LOGIN_VIA (админ $TL_USER входит по telnet:$TL_PORT; ssh — порт каждого устройства из devices.conf, поле 3)"; [ -n "$TL_PASS" ] || echo "WARN: TL_PASS не задан — вход администратора невозможен"
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
# Возврат: 0 = да, ключ уже работает; 1 = нет (нужен заход по telnet)
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
# Обработка одного устройства через expect-сессию: вход администратора по
# telnet или по ssh (в зависимости от $5; $6 — ssh-порт устройства).
# $4=rights_only: 1 = ключ уже работает, делается только проверка/доводка прав.
# Коды возврата (rc) 0=успех (ключ назначен или уже был; права приведены);
# 2=нет Login/запроса, 3=соединение закрыто, 4=нет запроса пароля,
# 5=неверный логин/пароль, 6=нет приглашения/ответа роутера,
# 7=не удалось создать пользователя, 8=не удалось назначить ключ,
# 9=не удалось выдать/подтвердить права (группу).
deploy_one() {
    local host="$1" tport="$2" target="$3" ro="$4" via="$5" sport_ssh="$6"
    # $4: rights_only=1 — ключ уже работает, только проверить/починить права.
    # $5: транспорт входа администратора: telnet|ssh; $6: ssh-порт (для ssh).

    if [ "$DRY_RUN" = "1" ]; then
        if [ "$ro" = "1" ]; then
            echo "[dry] $host — вход по $via, правка прав → $target"
        else
            echo "[dry] $host — вход по $via, ключ → $target"
        fi
        return 0
    fi

    DU_HOST="$host" DU_PORT="$tport" DU_LOGIN="$TL_USER" DU_TARGET="$target" \
    DU_PASS="$TL_PASS" DU_KEY="$KEY_TEXT" DU_NPASS="${NEWUSER_PASS:-mk-$(date +%s)-$RANDOM}" DU_GROUP="$TARGET_GROUP" DU_POLICY="$TARGET_POLICY" DU_RO="$ro" \
    DU_VIA="$via" DU_SPORT="$sport_ssh" \
expect <<'EXP' 2>&1 | tee -a "$LOG"
set timeout 45
set host   $env(DU_HOST)
set port   $env(DU_PORT)
set login  $env(DU_LOGIN)
set target $env(DU_TARGET)
set pass   $env(DU_PASS)
set key    $env(DU_KEY)
set npass  $env(DU_NPASS)
set tgroup $env(DU_GROUP)
set tpol   $env(DU_POLICY)
set via    $env(DU_VIA)
set sport  $env(DU_SPORT)
set ro     $env(DU_RO)
set vmajor 0
set vminor 0

# ВАЖНО: всё распознаётся "в потоке" (expect-паттерны матчатся по мере прихода
# данных, страницы --More-- листаются). Полагаться на expect_out(buffer)
# нельзя: при листании страниц его содержимое ненадёжно.

# --- дождаться приглашения, пролистав --More-- (вывод команды не нужен) ---
# ---------------------------------------------------------------------------
# Драйвер telnet-сессии: каждая команда = send + ожидание приглашения.
# Если приглашение не пришло — "покалываем" Enter (до 6 раз), чтобы снять
# рассинхрон, и только потом считаем ошибкой.
# Полный буфер ответа (эхо + вывод) кладётся в глобальную cmd_out.
# ---------------------------------------------------------------------------
proc run_cmd {cmd} {
    global cmd_out
    set cmd_out ""
    send -- "$cmd\r"
    set ok 0
    set n 0
    while {$n < 6} {
        incr n
        expect {
            -re {--[Mm]ore--} { send -- " "; exp_continue }
            -re "\] >"        { set ok 1; break }
            timeout           { send -- "\r" }
            eof               { break }
        }
    }
    if {!$ok} { return 1 }
    set cmd_out $expect_out(buffer)
    return 0
}

# Вытащить значение, которое роутер напечатал в ответ на команду $cmd
# (между эхом команды и приглашением).
proc cmd_value {cmd} {
    global cmd_out
    set b $cmd_out
    set cut [string last "] >" $b]
    if {$cut >= 0} {
        set b [string range $b 0 [expr {$cut - 1}]]
        set cut2 [string last "\[" $b]
        set nl [string last "\n" $b]
        if {$cut2 >= 0 && $nl < $cut2} { set b [string range $b 0 [expr {$cut2 - 1}]] }
    }
    set e [string last $cmd $b]
    if {$e >= 0} { set b [string range $b [expr {$e + [string length $cmd]}] end] }
    set b [string trim $b " \t\r\n"]
    return [lindex [split $b "\n"] 0]
}

# --- есть ли пользователь в /user print ---
# Вывод бывает: legacy/detail "name=\"x\" ..." либо табличный " 1  backupUser  ..."
proc user_exists {target} {
    global cmd_out has_user
    set has_user 0
    if {[run_cmd "/user print"] != 0} { return 1 }
    set p1 [format {name="?%s"?} $target]
    set p2 [format {(^|\n)[ \t]*[0-9]+[ \t]+%s[ \t]} $target]
    if {[regexp -nocase $p1 $cmd_out] || [regexp -nocase $p2 $cmd_out]} {
        set has_user 1
    }
    return 0
}

# --- существует ли группа ---
# Печатает через :put id группы (пусто = группы нет). Прокидывает has_group.
proc group_exists {gname} {
    global cmd_out has_group
    set has_group 0
    set gfind [format {:put [/user group find name=%s]} $gname]
    if {[run_cmd $gfind] != 0} { return 1 }
    set gv [string trim [cmd_value $gfind]]
    if {[string length $gv] > 0} { set has_group 1 }
    return 0
}

# --- убедиться, что группа есть; если нет — создать с политиками TARGET_POLICY
# Существующую группу НЕ переопределяем (вдруг она используется ещё кем-то):
# проверяем только членство пользователя. gp_created=1 — группу создали сейчас.
proc ensure_group {gname gpol} {
    global cmd_out gp_ok gp_msg gp_created has_group
    set gp_ok 1
    set gp_msg ""
    set gp_created 0
    if {[string length $gname] == 0} { return 0 }
    if {[group_exists $gname] != 0} { return 1 }
    if {!$has_group} {
        set cmd [format {/user group add name=%s policy=%s} $gname $gpol]
        if {[run_cmd $cmd] != 0} { return 1 }
        if {[regexp -nocase {failure:|no such|denied|invalid|unable|bad command|unknown} $cmd_out]} {
            set gp_ok 0
            append gp_msg $cmd_out
            return 0
        }
        set gp_created 1
    }
    return 0
}

# --- создать пользователя (в группе $group) ---
proc user_add {target pass group} {
    global cmd_out add_ok add_msg
    set add_ok 1
    set add_msg ""
    set cmd [format {/user add name=%s group=%s password="%s"} $target $group $pass]
    if {[run_cmd $cmd] != 0} { return 1 }
    if {[regexp -nocase {failure:|no such|invalid|unable|denied|wrong} $cmd_out]} {
        set add_ok 0
        append add_msg $cmd_out
    }
    return 0
}

# --- способ 1: file + import (RouterOS 6.43+ / 7) ---
proc do_import {target key} {
    global cmd_out imp_status imp_msg
    set imp_status ok
    set imp_msg ""
    if {[run_cmd "/file print file=mkkey"] != 0} { return 1 }
    set setc [format {/file set mkkey.txt contents="%s"} $key]
    if {[run_cmd $setc] != 0} { return 1 }
    set impc [format {/user ssh-keys import user=%s public-key-file=mkkey.txt} $target]
    if {[run_cmd $impc] != 0} { return 1 }
    set buf $cmd_out
    if {[regexp -nocase {already exists|unchanged} $buf]} {
        set imp_status already
    } elseif {[regexp -nocase {failure:|no such command|bad command|unknown command|not found|invalid|denied|unable|wrong format} $buf]} {
        set imp_status fail
        append imp_msg $buf
    }
    # убрать рабочий файл, если RouterOS его не съел сам
    run_cmd "/file remove \[find name=mkkey.txt\]"
    return 0
}

# --- способ 2: inline (только старый RouterOS 6 <6.43) ---
proc do_inline {target key} {
    global cmd_out inl_ok inl_msg
    set inl_ok 1
    set inl_msg ""
    set cmd [format {/user set [find name=%s] ssh-key="%s"} $target $key]
    if {[run_cmd $cmd] != 0} { return 1 }
    if {[regexp -nocase {failure:|no such|bad command|unknown command|not found|invalid|denied|unable|wrong} $cmd_out]} {
        set inl_ok 0
        append inl_msg $cmd_out
    }
    return 0
}

# --- запасной запрос версии (если не распознана из баннера) ---
proc get_version {} {
    global cmd_out vmajor vminor
    set vmajor 0
    set vminor 0
    if {[run_cmd "/system resource print"] != 0} { return 1 }
    if {[regexp -nocase {version:[ \t]*([0-9]+)\.([0-9]+)} $cmd_out -> mj mn]} {
        set vmajor $mj
        set vminor $mn
    }
    return 0
}

# --- соединение + логин администратора (telnet или ssh) ---
# Для telnet: host:port, запрос Login, затем Password.
# Для ssh: ssh-клиент сам передаёт логин (login@host), RouterOS спросит Password.
if {$via eq "ssh"} {
    spawn ssh -p $sport -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR $login@$host
} else {
    spawn telnet $host $port
}
# фаза 1: Login (telnet) / Password (ssh) / уже приглашение
expect {
    -re {[Ll]ogin:}   { send -- "$login\r"; exp_continue }
    -re {[Pp]assword:} { send -- "$pass\r" }
    -re "\] >"        { }
    timeout { puts "\n\[ERR\] нет Login/приглашения (служба закрыта?)"; exit 2 }
    eof     { puts "\n\[ERR\] соединение закрыто (недоступен порт?)"; exit 3 }
}
# фаза 2: баннер + приглашение. Если после входа RouterOS снова спрашивает
# Login/Password (напр. sshd с доп. консолью, или неверный пароль) — отвечаем,
# но не более 3 попыток (иначе rc=5). Ловим версию из баннера.
set tries 0
expect {
    -re {RouterOS[ \t]+([0-9]+)\.([0-9]+)} {
        set vmajor $expect_out(1,string)
        set vminor $expect_out(2,string)
        exp_continue
    }
    -re {--[Mm]ore--} { send -- " "; exp_continue }
    -re "\] >"        { }
    -re {[Ll]ogin:}    {
        if {$tries < 3} { incr tries; send -- "$login\r"; exp_continue }
        puts "\n\[ERR\] неверный логин/пароль"; exit 5
    }
    -re {[Pp]assword:} {
        if {$tries < 3} { incr tries; send -- "$pass\r"; exp_continue }
        puts "\n\[ERR\] неверный логин/пароль"; exit 5
    }
    -re {[Pp]ermission denied} { puts "\n\[ERR\] неверный логин/пароль"; exit 5 }
    timeout           { puts "\n\[ERR\] нет приглашения роутера"; exit 6 }
    eof               { puts "\n\[ERR\] нет приглашения роутера"; exit 6 }
}
puts "\[OK\] вошли на $host ($via)"

# --- версия RouterOS: из баннера либо запасной запрос ---
set version_src banner
if {$vmajor == 0} {
    get_version
    set version_src "resource print"
}
puts "\[INFO\] RouterOS $vmajor.$vminor ($version_src)"


# --- целевой пользователь: создать, если нет ---
if {$ro != 1} {
    # полная установка: создать пользователя (если нет) и назначить ключ.
    # При rights_only (ro=1, ключ уже работает) переходим сразу к проверке прав.
if {[user_exists $target] != 0} { puts "\n\[ERR\] нет ответа роутера"; exit 6 }
if {$has_user == 0} {
    # группа для нового пользователя: TARGET_GROUP (если задана) либо full
    # (TARGET_GROUP пуст = «правами не управляю», берём стандартную full).
    set ugroup $tgroup
    if {[string length $ugroup] == 0} { set ugroup "full" }
    # перед созданием пользователя/перевода в группу — убедиться, что группа есть
    if {[string length $tgroup] > 0} {
        if {[ensure_group $tgroup $tpol] != 0} { puts "\n\[ERR\] нет ответа роутера"; exit 7 }
        if {!$gp_ok} {
            puts "\n\[ERR\] не удалось создать группу '$tgroup': $gp_msg"
            send -- "quit\r"
            exit 7
        }
        if {$gp_created} {
            puts "\[INFO\] группа '$tgroup' отсутствовала — создана с политиками: $tpol"
        }
    }
    puts "\[INFO\] пользователь '$target' не найден — создаю (группа $ugroup)"
    if {[user_add $target $npass $ugroup] != 0} { puts "\n\[ERR\] нет ответа роутера"; exit 7 }
    if {$add_ok == 0} {
        puts "\n\[ERR\] не удалось создать пользователя $target: $add_msg"
        send -- "quit\r"
        exit 7
    }
    puts "\[INFO\] создан пользователь $target (пароль задан, но бот входит по ключу)"
}

# --- выбор способа и назначение ключа ---
set method inline
if {$vmajor > 6 || ($vmajor == 6 && $vminor >= 43) || $vmajor == 0} {
    # 6.43+ / 7 (или версия неизвестна) -> file+import; при неудаче fallback на inline
    set method import
    if {[do_import $target $key] != 0} { puts "\n\[ERR\] нет ответа роутера"; exit 8 }
    if {$imp_status eq "already"} {
        puts "\[OK\] ключ уже был установлен ранее ($target) — повторно не добавляем"
    } elseif {$imp_status eq "fail"} {
        puts "\[WARN\] import не прошёл ($imp_msg), пробую inline..."
        set method inline
    }
}
if {$method eq "inline"} {
    if {[do_inline $target $key] != 0} { puts "\n\[ERR\] нет ответа роутера"; exit 8 }
    if {$inl_ok == 0} {
        puts "\n\[ERR\] НЕ удалось назначить ключ пользователю $target: $inl_msg"
        send -- "quit\r"
        exit 8
    }
    puts "\[INFO\] ключ назначен inline (старый RouterOS)"
}

}

# --- ПРОВЕРКА ПРАВ целевого пользователя (группа и политики) ---
# Требуемая группа приходит в $tgroup (bash: TARGET_GROUP, по умолчанию full).
# Если $tgroup пусто — права не меняем, только показываем текущие.
set cur_group ""
set gcmd [format {:put [/user get [find name=%s] group]} $target]
if {[run_cmd $gcmd] != 0} { puts "\n\[ERR\] нет ответа роутера"; exit 6 }
set cur_group [string trim [cmd_value $gcmd]]
set gmsg "не определена"
if {[string length $cur_group] > 0} { set gmsg $cur_group }
puts "\[INFO\] текущая группа пользователя '$target': $gmsg"

set need_set 0
if {[string length $tgroup] > 0} {
    if {[string length $cur_group] == 0 || $cur_group ne $tgroup} {
        set need_set 1
    }
}
if {$need_set} {
    # группа может отсутствовать (в т.ч. при rights_only-режиме) — создаём с TARGET_POLICY
    if {[ensure_group $tgroup $tpol] != 0} { puts "\n\[ERR\] нет ответа роутера"; exit 9 }
    if {!$gp_ok} {
        puts "\n\[ERR\] не удалось создать группу '$tgroup': $gp_msg"
        send -- "quit\r"
        exit 9
    }
    if {$gp_created} {
        puts "\[INFO\] группа '$tgroup' отсутствовала — создана с политиками: $tpol"
    }
    puts "\[INFO\] задаю пользователю '$target' группу: $tgroup (минимальные политики: $tpol)"
    set scmd [format {/user set [find name=%s] group=%s} $target $tgroup]
    if {[run_cmd $scmd] != 0} { puts "\n\[ERR\] нет ответа роутера"; exit 9 }
    if {[regexp -nocase {failure:|no such|denied|invalid|unable|not found|unknown} $cmd_out]} {
        puts "\n\[ERR\] не удалось изменить группу пользователя $target: $cmd_out"
        send -- "quit\r"
        exit 9
    }
    # контроль: перечитать группу
    set gcmd2 [format {:put [/user get [find name=%s] group]} $target]
    if {[run_cmd $gcmd2] != 0} { puts "\n\[ERR\] нет ответа роутера"; exit 9 }
    set new_group [string trim [cmd_value $gcmd2]]
    if {$new_group ne $tgroup} {
        puts "\n\[ERR\] группа пользователя $target после установки: '$new_group' (ожидалось '$tgroup')"
        send -- "quit\r"
        exit 9
    }
    set cur_group $new_group
    puts "\[INFO\] права обновлены: группа '$target' = $cur_group"
}

# --- показать политики группы (что реально умеет пользователь) ---
set pol ""
if {[string length $cur_group] > 0} {
    set pcmd [format {:put [/user group get [find name=%s] policy]} $cur_group]
    if {[run_cmd $pcmd] == 0} {
        set pol [cmd_value $pcmd]
    }
}
if {[string length $pol] > 0} {
    puts "\[INFO\] политики группы '$cur_group': $pol"
    # сверяем с требуемыми политиками TARGET_POLICY (или дефолтным минимумом)
    set req_pol $tpol
    if {[string length $req_pol] == 0} { set req_pol "ssh,read,write,test,reboot,policy" }
    foreach need [split $req_pol ","] {
        set need [string trim $need]
        if {[string length $need] == 0} { continue }
        if {![regexp -nocase "(^|\[ ,\])${need}(\[ ,\]|$)" $pol]} {
            puts "\[WARN\] в группе '$cur_group' не видно политики '$need' — возможны проблемы при обновлении/бэкапе"
        }
    }
} else {
    puts "\[WARN\] не удалось получить политики группы '$cur_group'"
}

send -- "quit\r"
if {$ro == 1} {
    puts "\n\[OK\] права пользователя '$target' приведены к группе '$tgroup' ($host)"
} else {
    puts "\n\[OK\] ключ установлен → $target на $host"
}
exit 0

EXP
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
    # ВЕЗДЕ, где деплой ходит по SSH: предпроверка ключа, чтение прав, выбор
    # транспорта (LOGIN_VIA=auto/ssh) и сам вход администратора. Пустое поле
    # (или отсутствие) = стандартный порт 22.
    ssh_port="${port:-22}"

    # --- режим --check: только сообщаем, есть ли уже рабочий ключ ---
    if [ "$CHECK_ONLY" = "1" ]; then
        if ssh_key_works "$ip" "$ssh_port" "$local_target"; then
            g="?"
            if [ -n "$TARGET_GROUP" ]; then g=$(ssh_user_group "$ip" "$ssh_port" "$local_target" 2>/dev/null) || g="?"; fi
            if [ -n "$TARGET_GROUP" ] && [ "$g" = "$TARGET_GROUP" ]; then
                echo "[check] [$name] $ip — ✅ ключ работает, права OK (группа $g)"
            elif [ -n "$TARGET_GROUP" ]; then
                echo "[check] [$name] $ip — ⚠️ ключ работает, но права НЕ те (группа '$g', нужно $TARGET_GROUP) — нужен прогон"
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
            if [ -n "$g" ] && [ "$g" = "$TARGET_GROUP" ]; then
                echo "====> [$name] $ip — ✅ ключ работает и права в порядке ($local_target: группа '$g'), пропуск"
                SKIP=$((SKIP+1)); continue
            fi
            echo "====> [$name] $ip — ✅ ключ работает, но права НЕ те (группа '${g:-?}') — исправляю права"
            rights_only=1
        else
            echo "====> [$name] $ip — ключа нет, нужен вход администратора (ключ → $local_target)"
        fi
    else
        echo "====> [$name] $ip (без SSH-предпроверки)  ключ → $local_target"
    fi

    # --- выбор транспорта входа администратора (telnet/ssh) ---
    # Сюда попадаем только если реально нужен вход на роутер.
    case "$LOGIN_VIA" in
        telnet) via="telnet" ;;
        ssh)    via="ssh" ;;
        auto)
            if tcp_open "$ip" "$TL_PORT"; then
                via="telnet"
            elif tcp_open "$ip" "$ssh_port"; then
                via="ssh"
            else
                via=""
            fi ;;
        *) echo "ERROR: LOGIN_VIA=$LOGIN_VIA (допустимо: auto|telnet|ssh)" >&2
           exit 1 ;;
    esac
    if [ -z "$via" ]; then
        echo "[$name] $ip — недоступны ни telnet(:$TL_PORT) ни ssh(:$ssh_port) — пропуск"
        FAIL=$((FAIL+1))
        continue
    fi
    if [ "$via" = "ssh" ]; then
        admin_port="$ssh_port"
    else
        admin_port="$TL_PORT"
    fi
    echo "      вход: $via $TL_USER@$ip:$admin_port"

    # --- dry-run: показать план и остановиться ---
    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry]     $ip — был бы вход по $via ($TL_USER@$ip:$admin_port), ключ → $local_target"
        OK=$((OK+1))
        continue
    fi

    if ! ensure_client_deps "$via"; then
        echo "[$name] пропуск: нет expect/$via или TL_PASS"
        FAIL=$((FAIL+1))
        continue
    fi
    ensure_utf8_locale
    deploy_one "$ip" "$admin_port" "$local_target" "$rights_only" "$via" "$ssh_port"
    rc=$?
    echo "      rc=$rc"
    if [ "$rc" -eq 0 ]; then
        if [ "$rights_only" = "1" ]; then
            # главный критерий: группа/права пользователя теперь совпадают с TARGET_GROUP
            if [ "$SSH_VERIFY" = "1" ] && [ "$SSH_PROBE" = "1" ]; then
                if g=$(ssh_user_group "$ip" "$ssh_port" "$local_target") && [ "$g" = "$TARGET_GROUP" ]; then
                    echo "      [OK] подтверждено по SSH: группа '$local_target' = '$TARGET_GROUP'"
                    OK=$((OK+1))
                else
                    echo "      [!!] группа после исправления не подтвердилась ('$g') — нужна ручная проверка"
                    FAIL=$((FAIL+1))
                fi
            else
                OK=$((OK+1))
            fi
        elif [ "$SSH_VERIFY" = "1" ] && [ "$SSH_PROBE" = "1" ]; then
            # главный критерий успеха установки: ключ РЕАЛЬНО заходит по SSH.
            # (telnet-вывод может скрывать ошибки — доверяем только проверке входа)
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


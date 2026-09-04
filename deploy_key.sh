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
KEY_PRIV="${KEY_PRIV:-${KEY_FILE%.pub}}"  # приватный ключ для ПРОВЕРКИ входа
TL_USER="${TL_USER:-admin}"          # логин для входа по telnet
TL_PORT="${TL_PORT:-23}"             # порт telnet (стандартный)
TL_PASS="${TL_PASS:-}"               # пароль для входа по telnet (обязателен)
TARGET_USER="${TARGET_USER:-}"       # кому назначить ключ (если пусто — берётся user из devices.conf для каждого хоста)
NEWUSER_PASS="${NEWUSER_PASS:-}"     # пароль для СОЗДАВАЕМОГО пользователя (если TARGET_USER не существует)
SSH_PROBE="${SSH_PROBE:-1}"          # проверять ли SSH-вход перед telnet (1/0). 0 = всегда заходить по telnet
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
            echo "Env/конфиг: DEVICES_CONF, KEY_FILE, KEY_PRIV, TL_USER, TL_PORT, TL_PASS, TARGET_USER, NEWUSER_PASS, SSH_PROBE, SSH_TIMEOUT, SSH_VERIFY"
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
ensure_telnet_deps() {
    # Вызывается только перед реальным заходом по telnet. Кэшируем результат:
    # если для одного устройства deps подтверждены, для остальных повторно не проверяем.
    [ -n "$_TELNET_OK" ] && return 0
    if [ -n "$_TELNET_ERR" ]; then return 1; fi
    if ! command -v expect >/dev/null 2>&1; then
        _TELNET_ERR=1; echo "ERROR: установите expect (apt-get install -y expect)" >&2; return 1
    fi
    if ! command -v telnet >/dev/null 2>&1; then
        _TELNET_ERR=1; echo "ERROR: установите telnet (apt-get install -y telnet)" >&2; return 1
    fi
    if [ -z "$TL_PASS" ]; then
        _TELNET_ERR=1; echo "ERROR: задайте TL_PASS (пароль telnet)" >&2; return 1
    fi
    _TELNET_OK=1
    return 0
}

KEY_TEXT=$(tr -d '\r\n' < "$KEY_FILE")
LOG="deploy_key_$(date +%Y%m%d_%H%M%S).log"

echo "devices.conf : $DEVICES_CONF"
echo "ключ         : $KEY_FILE"
echo "SSH-проверка : $([ "$SSH_PROBE" = "1" ] && echo "вкл (${KEY_PRIV})" || echo "выкл")"
[ "$SSH_PROBE" = "1" ] && echo "telnet вход  : используется только для устройств БЕЗ рабочего ключа ($TL_USER@<ip>:$TL_PORT)"
[ "$SSH_PROBE" = "0" ] && echo "telnet вход  : $TL_USER@<ip>:$TL_PORT (на все устройства)"
[ "$SSH_VERIFY" = "1" ] && [ "$SSH_PROBE" = "1" ] && echo "подтверждение: после развёртывания вход ключом проверяется повторно (SSH)"
echo "целевой user : ${TARGET_USER:-<из devices.conf, поле 4>}"
[ "$DRY_RUN" = "1" ] && echo "РЕЖИМ: dry-run (без подключения)"
[ "$CHECK_ONLY" = "1" ] && echo "РЕЖИМ: только проверка (--check): у кого ключ уже работает"
[ "$FORCE" = "1" ] && echo "РЕЖИМ: --force (без SSH-предпроверки, разворачивать на всех)"
[ -n "$FILTER" ] && echo "Фильтр устройства: $FILTER"
echo "лог          : $LOG"

# ---------------------------------------------------------------------------
# SSH-предпроверка: входит ли приватный ключ на устройство под целевым user
# (т.е. у пользователя уже есть наш ключ — разворачивать не нужно).
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
# Обработка одного устройства через expect-сессию telnet.
# Коды возврата (rc) 0=успех (ключ назначен или уже был);
# 2=нет Login, 3=соединение закрыто, 4=нет запроса пароля,
# 5=неверный логин/пароль, 6=нет приглашения/ответа роутера,
# 7=не удалось создать пользователя, 8=не удалось назначить ключ.
deploy_one() {
    local host="$1" tport="$2" target="$3"

    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry] $host:$tport — telnet-вход $TL_USER, ключ → $target"
        return 0
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
set vmajor 0
set vminor 0

# ВАЖНО: всё распознаётся "в потоке" (expect-паттерны матчатся по мере прихода
# данных, страницы --More-- листаются). Полагаться на expect_out(buffer)
# нельзя: при листании страниц его содержимое ненадёжно.

# --- дождаться приглашения, пролистав --More-- (вывод команды не нужен) ---
proc drain {} {
    expect {
        -re {--[Mm]ore--}   { send -- " "; exp_continue }
        -re "\] >"          { return 0 }
        timeout             { return 1 }
        eof                 { return 2 }
    }
}

# --- версия RouterOS (запасной запрос, если не распознана из баннера) ---
# Основной источник — баннер логина "MikroTik RouterOS 6.49.20" (см. ниже,
# матчится при ожидании приглашения). Этот proc не даёт зависнуть на --More--:
# ожидание ограничено 6 сек, лишнее не критично.
proc get_version {} {
    global vmajor vminor
    send -- "/system resource print\r"
    set timeout 6
    expect {
        -re {version:[ \t]*([0-9]+)\.([0-9]+)} {
            set vmajor $expect_out(1,string)
            set vminor $expect_out(2,string)
            exp_continue
        }
        -re {--[Mm]ore--} { send -- " "; exp_continue }
        -re "\] >"        { }
        timeout           { }
        eof               { }
    }
    set timeout 45
    return 0
}

# --- есть ли пользователь (матчим строку name=... в /user print) ---
proc user_exists {target} {
    global has_user
    set has_user 0
    set namepat [format {name="?%s"?} $target]
    send -- "/user print\r"
    expect {
        -re $namepat       { set has_user 1; exp_continue }
        -re {--[Mm]ore--}  { send -- " "; exp_continue }
        -re "\] >"         { }
        timeout            { return 1 }
        eof                { return 2 }
    }
    return 0
}

# --- создать пользователя ---
proc user_add {target pass} {
    global add_ok add_msg
    set add_ok 1
    set add_msg ""
    set cmd [format {/user add name=%s group=full password="%s"} $target $pass]
    send -- "$cmd\r"
    expect {
        -re {failure:|no such|invalid|unable|denied|wrong} {
            set add_ok 0
            append add_msg $expect_out(0,string)
            exp_continue
        }
        -re {already exists} { exp_continue }
        -re {--[Mm]ore--} { send -- " "; exp_continue }
        -re "\] >"        { }
        timeout           { return 1 }
        eof               { return 2 }
    }
    return 0
}

# --- способ 1: file + import (RouterOS 6.43+ / 7) ---
# imp_status: ok / already / fail
proc do_import {target key} {
    global imp_status imp_msg
    set imp_status ok
    set imp_msg ""
    send -- "/file print file=mkkey\r"
    expect { -re {--[Mm]ore--} { send -- " "; exp_continue } -re "\] >" { } }
    send -- "[format {/file set mkkey.txt contents="%s"} $key]\r"
    expect { -re {--[Mm]ore--} { send -- " "; exp_continue } -re "\] >" { } }
    send -- "/user ssh-keys import user=$target public-key-file=mkkey.txt\r"
    expect {
        -re {already exists|unchanged} { set imp_status already; exp_continue }
        -re {failure:|no such command|bad command|unknown command|not found|invalid|denied|unable|wrong format} {
            set imp_status fail
            append imp_msg $expect_out(0,string)
            exp_continue
        }
        -re {--[Mm]ore--} { send -- " "; exp_continue }
        -re "\] >"        { }
        timeout           { return 1 }
        eof               { return 2 }
    }
    # убрать файл, если RouterOS его не съел сам (при успехе он удаляется)
    send -- "/file remove \[find name=mkkey.txt\]\r"
    expect { -re {--[Mm]ore--} { send -- " "; exp_continue } -re "\] >" { } }
    return 0
}

# --- способ 2: inline /user set ssh-key (только старый RouterOS 6 <6.43) ---
proc do_inline {target key} {
    global inl_ok inl_msg
    set inl_ok 1
    set inl_msg ""
    set cmd [format {/user set [find name=%s] ssh-key="%s"} $target $key]
    send -- "$cmd\r"
    expect {
        -re {failure:|no such|bad command|unknown command|not found|invalid|denied|unable|wrong} {
            set inl_ok 0
            append inl_msg $expect_out(0,string)
            exp_continue
        }
        -re {--[Mm]ore--} { send -- " "; exp_continue }
        -re "\] >"        { }
        timeout           { return 1 }
        eof               { return 2 }
    }
    return 0
}

# --- соединение + логин ---
spawn telnet $host $port
expect {
    -re "Login:" { send -- "$login\r" }
    -re "\] >"   { }
    timeout      { puts "\n\[ERR\] нет Login (telnet закрыт?)"; exit 2 }
    eof          { puts "\n\[ERR\] соединение закрыто (недоступен порт?)"; exit 3 }
}
expect {
    -re "Password:" { send -- "$pass\r" }
    timeout { puts "\n\[ERR\] нет запроса пароля"; exit 4 }
    eof     { puts "\n\[ERR\] соединение закрыто"; exit 4 }
}
# дождаться приглашения после логина; повторный Login = неверный пароль.
# Здесь же ловим версию из баннера "MikroTik RouterOS 6.49.20 ..." — без
# постраничного вывода.
expect {
    -re {RouterOS[ \t]+([0-9]+)\.([0-9]+)} {
        set vmajor $expect_out(1,string)
        set vminor $expect_out(2,string)
        exp_continue
    }
    -re {--[Mm]ore--} { send -- " "; exp_continue }
    -re "\] >"        { }
    -re "Login:"      { puts "\n\[ERR\] неверный логин/пароль"; exit 5 }
    timeout           { puts "\n\[ERR\] нет приглашения роутера"; exit 6 }
    eof               { puts "\n\[ERR\] нет приглашения роутера"; exit 6 }
}
puts "\[OK\] вошли на $host"

# --- версия RouterOS: из баннера либо запасной запрос ---
set version_src banner
if {$vmajor == 0} {
    get_version
    set version_src "resource print"
}
puts "\[INFO\] RouterOS $vmajor.$vminor ($version_src)"

# --- целевой пользователь: создать, если нет ---
if {[user_exists $target] != 0} { puts "\n\[ERR\] нет ответа роутера"; exit 6 }
if {$has_user == 0} {
    puts "\[INFO\] пользователь '$target' не найден — создаю (group=full)"
    if {[user_add $target $npass] != 0} { puts "\n\[ERR\] нет ответа роутера"; exit 7 }
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

send -- "quit\r"
puts "\n\[OK\] ключ установлен → $target на $host"
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
    # ssh-порт устройства из devices.conf (стандартно 22)
    ssh_port="${port:-22}"

    # --- режим --check: только сообщаем, есть ли уже рабочий ключ ---
    if [ "$CHECK_ONLY" = "1" ]; then
        if ssh_key_works "$ip" "$ssh_port" "$local_target"; then
            echo "[check] [$name] $ip — ✅ ключ уже работает (пропустить можно)"
            OK=$((OK+1))
        else
            echo "[check] [$name] $ip — ⚠️ ключа НЕТ, нужно разворачивание"
            FAIL=$((FAIL+1))
        fi
        continue
    fi

    # --- предпроверка: если ключ уже работает — пропускаем (без telnet) ---
    if [ "$SSH_PROBE" = "1" ]; then
        if ssh_key_works "$ip" "$ssh_port" "$local_target"; then
            echo "====> [$name] $ip — ✅ ключ уже работает ($local_target), пропуск"
            SKIP=$((SKIP+1))
            continue
        fi
        echo "====> [$name] $ip — ключа нет, заход по telnet :$TL_PORT (ключ → $local_target)"
    else
        echo "====> [$name] $ip (telnet :$TL_PORT, без SSH-предпроверки)  ключ → $local_target"
    fi

    # --- dry-run: показать план и остановиться ---
    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry]     $ip:$ssh_port — был бы заход по telnet, ключ → $local_target"
        OK=$((OK+1))
        continue
    fi

    if ! ensure_telnet_deps; then
        echo "[$name] пропуск: нет expect/telnet или TL_PASS"
        FAIL=$((FAIL+1))
        continue
    fi
    deploy_one "$ip" "$TL_PORT" "$local_target"
    rc=$?
    echo "      rc=$rc"
    if [ "$rc" -eq 0 ]; then
        # главный критерий успеха: ключ РЕАЛЬНО заходит по SSH под этим user'ом.
        # (telnet-вывод может скрывать ошибки — доверяем только проверке входа)
        if [ "$SSH_VERIFY" = "1" ] && [ "$SSH_PROBE" = "1" ]; then
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


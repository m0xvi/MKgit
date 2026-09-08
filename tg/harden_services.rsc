# =============================================================================
# harden_services.rsc  (RouterOS 6.43+ / 7.x)
# -----------------------------------------------------------------------------
# Хардненинг сервисов управления на MikroTik:
#   1) выключает ВСЕ сервисы /ip service, кроме ssh и winbox;
#   2) переводит ssh на СЛУЧАЙНЫЙ порт из диапазона minP..maxP (ниже);
#   3) ограничивает доступ к ssh ("Available From") адресами из allowFrom;
#      winbox остаётся включённым, его порт/ограничения НЕ трогаем.
#
# КАК ЗАПУСТИТЬ:
#   на роутере в терминале (или по ssh/telnet):  /import file-name=harden_services.rsc
#   либо просто вставьте весь текст в терминал (новые ROS 7 умеют).
#   Либо серверной обёрткой mk_harden.sh (скрипт на сервере прогоняет по всем
#   роутерам и сам обновляет devices.conf).
#
# ВАЖНО / ОСТОРОЖНО:
#   * Сейчас между план-выводом и применением есть пауза (ABORT_SEC): если вы
#     подключены НЕ с разрешённых адресов или передумали — нажмите Ctrl-C.
#   * Текущая сессия (telnet/ssh) не оборвётся, но СЛЕДУЮЩИЙ вход — только
#     по НОВОМУ ssh-порту и ТОЛЬКО с адресов из allowFrom. Если вы заходите
#     с другого адреса — сначала исправьте allowFrom, иначе закроете себе доступ!
#   * После выполнения запишите новый ssh-порт на сервере в devices.conf
#     (3-е поле строки устройства): бот/деплой/обновления берут ssh-порт
#     именно оттуда, telnet после скрипта будет отключён.
#   * Рекомендация: держите под рукой резервный вход (Winbox по MAC / консоль).
# =============================================================================

# --- НАСТРОЙКИ --------------------------------------------------------------
# кому разрешён ssh (Available From)
:local allowFrom "10.20.9.11,192.168.10.89"
# нижняя граница случайного порта
:local minP 20000
# верхняя граница случайного порта
:local maxP 60000
# пауза перед применением (Ctrl-C = отмена)
:local abortSec 10

# -----------------------------------------------------------------------------
# 0. Версия RouterOS (в v7 у /ip service бывают динамические записи — их нельзя
#    трогать; также в v7 есть :rndnum, в v6 его нет)
# -----------------------------------------------------------------------------
:local vstr [/system resource get version]
:local dot [:find $vstr "."]
:local maj ""
:if ($dot >= 0) do={ :set maj [:pick $vstr 0 $dot] }
:local isV7 false
:if ($maj = "7") do={ :set isV7 true }

:local sshId [/ip service find name="ssh"]
:local winId [/ip service find name="winbox"]
:if ($isV7 = true) do={
    :local sshSt [/ip service find where name="ssh" and !dynamic]
    :if ([:len $sshSt] > 0) do={ :set sshId $sshSt }
    :local winSt [/ip service find where name="winbox" and !dynamic]
    :if ([:len $winSt] > 0) do={ :set winId $winSt }
}

:put ("Версия: " . $vstr)
:if ([:len $sshId] = 0) do={
    :put "ОШИБКА: сервис ssh не найден — прерываю."
    :error "нет сервиса ssh"
}

# -----------------------------------------------------------------------------
# 1. План (что будет отключено) + пауза на отмену
# -----------------------------------------------------------------------------
:local disList ""
:foreach s in=[/ip service find] do={
    :local isDyn false
    :if ($isV7 = true) do={ :set isDyn [/ip service get $s dynamic] }
    :if ($isDyn != true) do={
        :local n [/ip service get $s name]
        :if (($n != "ssh") and ($n != "winbox")) do={ :set disList ($disList . " " . $n) }
    }
}
:put ""
:put ("ПЛАН: будут ОТКЛЮЧЕНЫ сервисы:" . $disList)
:put ("      ssh -> случайный порт из диапазона " . $minP . "-" . $maxP)
:put ("      ssh -> доступ только с: " . $allowFrom)
:put "      winbox -> остаётся включённым (порт/доступ не меняются)"
:put ("Пауза " . $abortSec . " сек — жмите Ctrl-C, чтобы ОТМЕНИТЬ...")
:delay $abortSec

# -----------------------------------------------------------------------------
# 2. Отключаем всё, кроме ssh и winbox
# -----------------------------------------------------------------------------
:put ""
:put "Отключаю лишние сервисы..."
:foreach s in=[/ip service find] do={
    :local isDyn false
    :if ($isV7 = true) do={ :set isDyn [/ip service get $s dynamic] }
    :if ($isDyn != true) do={
        :local n [/ip service get $s name]
        :if (($n != "ssh") and ($n != "winbox")) do={
            /ip service disable $s
            :put ("  выключен: " . $n)
        }
    }
}

# -----------------------------------------------------------------------------
# 3. Случайный свободный ssh-порт.
#    v7: :rndnum; v6: псевдослучайный от текущего времени (в v6 нет :rndnum).
#    Порт не должен совпадать с портом другого сервиса и со старым ssh-портом.
# -----------------------------------------------------------------------------
:local curPort 0
:if ($isV7 = true) do={ :set curPort [/ip service get $sshId port] }
:local newPort 0
:local free false

:if ($isV7 = true) do={
    :while ($free = false) do={
        :set newPort [:rndnum from=$minP to=$maxP]
        :local clash [/ip service find where port=$newPort and name!="ssh"]
        :if (([:len $clash] = 0) and ($newPort != $curPort)) do={ :set free true }
    }
} else={
    # v6: на основе секунд текущего времени (интервал между устройствами при
    # прогоне обёрткой > 10с из-за паузы, поэтому порты устройств различаются)
    :local sec 0
    :do {
        :local t [/system clock get time]
        :local h [:tonum [:pick $t 0 2]]
        :local m [:tonum [:pick $t 3 5]]
        :local s [:tonum [:pick $t 6 8]]
        :set sec ((($h * 3600) + ($m * 60)) + $s)
    } on-error={ :set sec 0 }
    :local span (($maxP - $minP) + 1)
    :local off ($sec * 37)
    :while (($off > $span) and ($span > 0)) do={ :set off ($off - $span) }
    :set newPort ($minP + $off)
    :local clash [/ip service find where port=$newPort and name!="ssh"]
    :if ([:len $clash] > 0) do={ :set newPort ($minP + $span - 1) }
}
:put ""
:put ("Новый ssh-порт: " . $newPort)

# -----------------------------------------------------------------------------
# 4. Применяем: ssh (случайный порт + Available From) и winbox (включён)
# -----------------------------------------------------------------------------
/ip service set $sshId port=$newPort address=$allowFrom disabled=no
:put ("ssh: порт=" . $newPort . ", доступен с: " . $allowFrom)

/ip service enable $winId
:put "winbox: включён (порт и адреса не менялись)"

# -----------------------------------------------------------------------------
# 5. Итог
# -----------------------------------------------------------------------------
:put ""
:put "============================= ИТОГ ============================="
:put ("Новый SSH-порт:     " . $newPort)
:put ("SSH доступен с:     " . $allowFrom)
:put "Winbox: включён (8291)"
:put "Не забудьте на сервере обновить devices.conf: поле 3 = новый ssh-порт!"
:put "==============================================================="
:put ""
/ip service print

# Машиночитаемый маркер для серверной обёртки mk_harden.sh
:put ("HARDEN_OK_SSH_PORT=" . $newPort)


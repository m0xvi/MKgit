# MikroGit — бэкап и обновление устройств MikroTik через Telegram-бота

Набор bash-скриптов для Ubuntu-сервера:

- `MikroGit.sh` — резервное копирование RouterOS по SSH **в формате `.backup`**
  (`/system backup save`, полное восстановление конфигурации);
- `tg/mk_tg_bot.sh` — Telegram-бот (поллинг + inline-клавиатуры);
- `tg/mk_updates.sh` — проверка, скачивание и установка обновлений RouterOS;
- `tg/mk_schedule.sh` — планировщик (ежедневный бэкап + еженедельные обновления);
- `tg/mk_cleanup.sh` — автоочистка логов, отчётов и мусора.

## Что изменилось в этой версии

| Было | Стало |
|---|---|
| Бэкап делался через `/export` → текстовый `.rsc` | Бинарный **`.backup`** (`/system backup save dont-encrypt=yes`) — восстанавливается целиком |
| `scp` качал `файл.rsc.rsc` (двойное расширение) — скачивание падало, `.rsc` оставался мусором на flash роутера | Имя файла собирается корректно, после скачивания временный файл **удаляется с роутера** |
| Бэкап перед обновлением клался в общую кучу без пометок и был не виден в боте | Префикс **`pre_update_`**, отдельный лимит ротации, отдельный раздел в меню «📥 Download» |
| Отчёты (`backup_report_*.txt`) сыпались в корень `bckp/` | Отчёты в **`logs/reports/`**, старые переносятся автоматически |
| `~/deploy_key_*.log` копились в домашней папке на каждый прогон | Логи деплоя в **`logs/deploy/`**, старые в `~` чистятся |
| Логи не ротировались | Ротация по размеру (`.gz`), ограничение количества |
| Расписание только «автопроверка раз в N часов» | Отдельный демон: **бэкап ежедневно 03:00**, **обновления раз в неделю (Вс 04:00)** — настраивается из бота |

## Где лежат бэкапы

```
bckp/
  GW_DONA/
    GW_DONA_2026-10-20_03-00-00.backup              # плановый
    GW_DONA_pre_update_2026-10-20_03-58-12.backup   # 🛡 перед обновлением
    GW_DONA_2026-09-01_10-00-00.rsc                 # старый экспорт (если был) — не удаляется
    device_info.txt
logs/
  mk_backup.log
  reports/backup_report_2026-10-20_03-00-05_123.txt
  deploy/…            update_state/…   deploy_state/…   harden_state/…
  schedule/schedule.conf, daemon.log
```

- Плановые и `pre_update`-бэкапы **ротируются раздельно**:
  `MAX_BACKUPS_PER_DEVICE` (5) и `MAX_PRE_UPDATE_BACKUPS` (5). Бэкап перед
  обновлением не вымывается ежедневными копиями.
- Бэкап перед обновлением создаётся **автоматически** перед установкой RouterOS
  и перед прошивкой RouterBOOT, а также вручную:
  ```bash
  ./MikroGit.sh --device GW_DONA --pre-update
  ```
- Временный `.backup` после скачивания **удаляется с роутера**, чтобы не
  занимать flash.

### Почему бэкап/обновление не удались — прямо в сообщении бота

Любой сбой приходит в Telegram с причиной и подсказкой, а не только «Check
logs»:

```
❌ Backup failed!
Device: AP_U2_Conf

Причина: на роутере не создаётся AP_U2_Conf_2026-10-20_18-05-08.backup
(свободно 12 KB из 16 MB)
💡 мало места на flash: /system resource print → free-hdd-space, /file print

Лог: /home/aionis/MikroGit/logs/mk_backup.log      [📜 Логи]
```

- по каждому устройству — своя причина (нет SSH, мало места, нет политики
  `ftp`, конфиг/ключ, занятой лок);
- в итоговой сводке «Backup completed with errors» перечислены все неудачные
  устройства с причинами;
- к сообщению приложена кнопка **📜 Логи** — сразу открывает меню логов;
- у обновлений итог «Обновление всех завершено» устроен так же: под
  счётчиками идёт блок «Почему не вышло» с последней ошибкой по каждому
  устройству.

Причины хранятся в `logs/last_backup_status.tsv` (последний запуск) и
`logs/update_state/last_errors.tsv` (последнее обновление) — их можно
посмотреть и без Telegram:

```bash
cat ~/MikroGit/logs/last_backup_status.tsv
cat ~/MikroGit/logs/update_state/last_errors.tsv
```

### Мало места на flash роутера

На устройствах с маленьким flash (CAP ac, wAP ac и т. п.) файл `.backup`
(≈170–200 KB) может не создаться: RouterOS отвечает «Configuration backup
saved», но файла нет. Скрипт теперь:

1. до сохранения проверяет `free-hdd-space` и, если места мало
   (нужно ~2 размера бэкапа), чистит flash;
2. удаляет **свои** старые бэкапы/экспорты (`<имя>_ГГГГ-ММ-ДД_ЧЧ-ММ-СС.backup|.rsc`)
   сначала **старше 30 дней**, а если места всё равно нет — самые старые,
   оставляя самый свежий (страховка для отката);
3. повторяет `/system backup save` до 3 раз, ожидая появления файла;
4. если удалять нечего (flash занят посторонними файлами), пишет в лог и в
   Telegram причину и **5 самых больших файлов** на flash, чтобы можно было
   убрать их вручную:

```
WARNING: AP_TEST: на роутере нечего удалять — старых файлов наших бэкапов нет.
WARNING: AP_TEST: самые большие файлы на flash: web-proxy-dump.bin (391 KB), flash_backup.old (195 KB)
WARNING: AP_TEST: освободите место вручную (/file print; /file remove [find name=...])
```

Чужие файлы скрипт **не удаляет** — только те, что создал сам.

Настройки (переменные окружения или строки в начале `MikroGit.sh`):

| Переменная | По умолчанию | Что делает |
|---|---|---|
| `ROUTER_MIN_FREE_BYTES` | `65536` | минимум свободного места для попытки сохранения |
| `ROUTER_CLEANUP_DAYS` | `30` | с какого возраста удалять старые бэкапы на роутере |
| `ROUTER_SAVE_TRIES` | `3` | сколько раз пытаться сохранить с уборкой между попытками |
| `ROUTER_KEEP_NEWEST` | `1` | оставлять самый свежий файл при уборке (0 — удалять всё) |
| `ROUTER_FILE_WAIT` | `10` | сколько секунд ждать появления файла после save |

## Устройства

Файл `devices.conf`, формат строки:

```
имя:ip:порт:ssh_user:описание
```

## Установка на Ubuntu-сервер

```bash
git clone https://github.com/m0xvi/MKgit.git
cd MKgit
cp tg/tg_bot_config.sh.example tg/tg_bot_config.sh
chmod +x MikroGit.sh tg/*.sh
```

Заполните `tg/tg_bot_config.sh` (токен бота, chat_id, пути, прокси).
Затем:

```bash
chmod 600 tg/tg_bot_config.sh          # конфиг содержит токен
mkdir -p ~/.ssh && ssh-keygen -t rsa -b 4096 -f ~/.ssh/mk_key -N ""
# Добавьте ~/.ssh/mk_key.pub в /user ssh-keys на каждом MikroTik
# (или запустите start_bot_with_ssh.sh, который покажет публичный ключ)
```

Запуск бота (в tmux/systemd или руками):

```bash
cd tg
./start_bot_with_ssh.sh        # поднимает ssh-agent и запускает бота
```

При старте бот сам поднимает **демон расписания** (`tg/mk_schedule.sh`).
Проверить/запустить вручную:

```bash
bash tg/mk_schedule.sh status   # состояние + план
bash tg/mk_schedule.sh start    # запустить демон
bash tg/mk_schedule.sh stop     # остановить
bash tg/mk_schedule.sh run backup    # бэкап немедленно (как по расписанию)
bash tg/mk_schedule.sh run updates   # проверка/обновление немедленно
```

### systemd (бот + расписание после перезагрузки)

Устанавливается одной командой (из **любого** каталога, через `sudo`):

```bash
sudo bash ~/MikroGit/tg/install_systemd.sh --dry-run   # посмотреть план
sudo bash ~/MikroGit/tg/install_systemd.sh             # установить и запустить
```

Скрипт сам подставит реальный путь к репозиторию и пользователя-владельца,
остановит ручные копии бота (иначе конфликт по lock), поставит юниты,
сделает `daemon-reload` и `enable --now`.

Удалить юниты: `sudo bash ~/MikroGit/tg/install_systemd.sh --uninstall`.

- `mkgit-bot` — Telegram-бот;
- `mkgit-schedule` — планировщик (ежедневный бэкап + недельные обновления).
  Он живёт **отдельно** от бота, поэтому расписание не сбивается при
  перезапуске бота; если он запущен через systemd, бот при старте его не
  дублирует (защита через `flock`).

### ⚠️ Не запускайте от root

Бот и планировщик должны работать от **владельца каталога репозитория**
(обычно `aionis`). Если запустить от `root`:

- `HOME=/root`, поэтому SSH-ключ ищется в `/root/.ssh/mk_key` — его там нет;
- логи, `bckp/` и lock-файлы создаются root-овыми, и после этого обычный
  пользователь не может ни писать в лог, ни снять lock («Бот уже запущен»).

`start_bot_with_ssh.sh` теперь сам определяет владельца репозитория и
перезапускается от него. Если нужно поправить права вручную:

```bash
sudo chown -R aionis:aionis /home/aionis/MikroGit
```

### Про пути в командах

Команды из README выполняются **из корня репозитория** (`~/MikroGit`).
Если вы уже внутри `tg/`, путь `tg/...` станет `tg/tg/...` и вы получите
`No such file or directory` — поднимайтесь на уровень выше (`cd ..`) или
используйте полные пути:

```bash
cd ~/MikroGit                       # корень проекта
bash tg/mk_schedule.sh status
bash tg/mkgit_doctor.sh
sudo bash tg/install_systemd.sh
```

### Диагностика одной командой

```bash
bash tg/mkgit_doctor.sh            # проверить всё (ничего не меняет)
sudo bash tg/mkgit_doctor.sh --fix # + исправить владельца файлов
```

Проверяет: владельца файлов (root-овые → `dubious ownership` /
`Permission denied` в `.git`), права на `logs/`, `bckp/`, `.git`, SSH-ключ,
процессы бота и зависшие локи, systemd-юниты, мусор в `~`, состояние бэкапов
и расписания. Код возврата: `0` — всё ок, `1` — замечания, `2` — ошибки.

### Если git пишет «dubious ownership» или «Permission denied» в .git

Причина одна: команды git выполнялись от `root` (через `sudo su`), и файлы
`.git` стали root-овыми. Лечится владельцем, а не `safe.directory`:

```bash
sudo chown -R aionis:aionis /home/aionis/MikroGit
```

> `git config --global --add safe.directory …` — это костыль: git начнёт
> доверять каталогу, но запись в `.git/FETCH_HEAD` всё равно останется
> запрещённой (`Permission denied`). Если уже добавляли — уберите:
> `git config --global --unset-all safe.directory`

### Если бот не стартует: «Бот уже запущен (lock занят)»

```bash
pgrep -af mk_tg_bot.sh          # какие копии работают
pkill -f mk_tg_bot.sh           # остановить все (или tmux kill-session -t mkgit)
sudo lsof /home/aionis/MikroGit/logs/mk_tg_bot.lock   # если процессов не видно
```

Затем запустите **один** экземпляр: `systemctl start mkgit-bot` **или**
`./start_bot_with_ssh.sh` (не оба сразу).

### Альтернатива systemd — cron

```
0 3 * * *  /home/USER/MKgit/MikroGit.sh --telegram schedule >> /home/USER/MKgit/logs/mk_backup.log 2>&1
```

> ⚠️ Если используете cron **и** встроенное расписание, выберите что-то одно —
> иначе бэкап будет делаться дважды (второй запуск подождёт лок и просто
> отработает следом).

## Расписание (меню «🗓 Расписание» / команда `/schedule`)

Настройки хранятся в `logs/schedule/schedule.conf` и меняются кнопками в боте:

- **▶️/⛔ Включить/выключить** всё расписание;
- **📦 Бэкап** — ежедневно в заданное время (по умолчанию **03:00**), ±1 ч / ±15 мин;
- **⬆️ Обновления** — раз в неделю, день недели переключается кнопкой
  (по умолчанию **Вс 04:00**), ±1 ч / ±15 мин;
- **режим обновлений**:
  - `check` — только проверка и отчёт в Telegram (установка по кнопке);
  - `apply` — проверка и **автоустановка** по очереди (с бэкапом и reboot);
- **▶️ Бэкап сейчас** / **🔎 Проверить обновления** — разовый запуск.

Часы — по времени сервера (в боте показан часовой пояс и текущее время).

## Автоочистка (меню «🧹 Обслуживание»)

Выполняется **после каждого бэкапа** и по кнопке «Очистить сейчас»:

1. ротация бэкапов: 5 плановых + 5 `pre_update` на устройство;
2. отчёты — не больше 5, лежат в `logs/reports/` (старые из `bckp/`
   переносятся автоматически);
3. ротация логов по размеру (10 MB → `.gz`, 3 архива на файл);
4. удаление `~/deploy_key_*.log` старше 7 дней и перенос устаревшего
   `~/mikrotik_backup.log` в `logs/legacy/`;
5. удаление пустых каталогов устройств и недокачанных `*.part`.
6. чистка `run_*.log` воркеров (update/deploy/harden).

Ручной запуск:

```bash
bash tg/mk_cleanup.sh --dry-run    # посмотреть, что будет удалено
bash tg/mk_cleanup.sh              # выполнить
```

## Обновления RouterOS через бота

1. **Проверка** выполняется самим роутером:
   `/system package update check-for-updates`.
   Бот определяет ветку (RouterOS 6 → 6.x, RouterOS 7 → 7.x) и обновляет
   **в рамках своей ветки** (кросс-апгрейд 6→7 не выполняется).
2. **Установка** — только после подтверждения в Telegram:
   - создаётся бэкап `.backup` с пометкой **`pre_update_`** (путь приходит
     сообщением и виден в 📥 Download → 🛡 Перед обновлением);
   - `/system package update download`;
   - перезагрузка (~2–5 мин недоступности);
   - бот ждёт устройство и присылает итоговую версию.
3. После RouterOS автоматически проверяется и обновляется RouterBOOT firmware
   (тоже с `pre_update`-бэкапом).

### Кнопки и команды

- В главном меню: **«⬆️ Обновления RouterOS»**, **«🗓 Расписание»**,
  **«🧹 Обслуживание»**
- Команды: `/updates`, `/checkupdates`, `/schedule`, `/latest DEVICE`,
  `/latest-pre DEVICE`
- В меню обновлений: «Проверить сейчас (все)», «Последний статус»,
  «⬇️ Установить: <device>» → подтверждение.

### Настройки (tg/tg_bot_config.sh)

| Переменная | По умолчанию | Описание |
|---|---|---|
| `BACKUP_DIR` | `<проект>/bckp` | Каталог бэкапов (общий для бота и `MikroGit.sh`!) |
| `REPORTS_DIR` | `<logs>/reports` | Каталог отчётов |
| `MAX_BACKUPS_PER_DEVICE` | `5` | Плановых бэкапов на устройство |
| `MAX_PRE_UPDATE_BACKUPS` | `5` | Бэкапов «перед обновлением» на устройство |
| `MAX_REPORTS` | `5` | Сколько отчётов хранить |
| `MKC_HOME_LOG_DAYS` | `7` | Через сколько дней удалять `~/deploy_key_*.log` |
| `UPDATE_CHANNEL` | `stable` | Канал: `stable`, `long-term`, `testing` или `""` |
| `UPDATE_BACKUP_BEFORE_APPLY` | `1` | Бэкап перед установкой RouterOS |
| `UPDATE_BACKUP_BEFORE_RB` | `1` | Бэкап перед обновлением RouterBOOT |
| `UPDATE_DOWNLOAD_TIMEOUT` | `900` | Таймаут скачивания, сек |
| `UPDATE_REBOOT_WAIT` | `600` | Ожидание возврата после перезагрузки, сек |
| `UPDATE_REBOOT_POLL` | `10` | Пауза опроса после перезагрузки, сек |
| `UPDATE_SSH_TIMEOUT` | `60` | Таймаут короткой SSH-команды, сек |
| `UPDATE_CHECK_TIMEOUT` | `150` | Таймаут `check-for-updates` |
| `SCHED_ENABLED` | `1` | Планировщик включён |
| `SCHED_BACKUP_HOUR/MINUTE` | `3` / `0` | Время ежедневного бэкапа |
| `SCHED_UPDATE_ENABLED` | `1` | Обновления по расписанию |
| `SCHED_UPDATE_WEEKDAY` | `7` (Вс) | День недели обновлений (1=Пн … 7=Вс) |
| `SCHED_UPDATE_HOUR/MINUTE` | `4` / `0` | Время обновлений |
| `SCHED_UPDATE_MODE` | `check` | `check` (только проверка) или `apply` (автоустановка) |

> Значения `SCHED_*` из `tg_bot_config.sh` — только начальные. После первого
> изменения в меню «Расписание» действует `logs/schedule/schedule.conf`.

## Запуск бэкапа/обновлений вручную (без бота)

```bash
export HOME=/home/USER
source tg/tg_bot_config.sh
source tg/tg_api_helpers.sh

bash MikroGit.sh                       # все устройства, .backup
bash MikroGit.sh --device GW_DONA      # одно
bash MikroGit.sh --device GW_DONA --pre-update
bash MikroGit.sh --list                # список устройств
bash MikroGit.sh --cleanup             # только обслуживание

bash tg/mk_updates.sh check all
bash tg/mk_updates.sh apply GW_DONA    # без подтверждения — осторожно!
bash tg/mk_updates.sh updateall        # все по очереди
bash tg/mk_updates.sh status
```

## Права пользователя MikroTik (важно!)

Проверка обновлений выполняется от SSH-пользователя из `devices.conf`, ему
нужны права на изменение конфигурации и перезагрузку. Минимальный набор
политик группы (`/user group`):

- `ssh` — вход по SSH;
- `read` — чтение конфигурации и `/system resource print`;
- `write` — `/system package update set/check/download`, `/system backup save`;
- `test` — сетевые проверки обновления;
- `reboot` — перезагрузка после установки;
- `ftp` — **нужен для scp/sftp** — без него бэкап не скачается с роутера;
- `sensitive` — **обязателен для `.backup`**: файл содержит пароли, и RouterOS
  не отдаёт его по scp/ftp без этой политики (симптом: файл на роутере есть,
  а `scp`/`sftp` его не забирают, в логе `Permission denied`).

```
/user group add name=mikrogit policy=ssh,read,write,test,reboot,ftp,sensitive \
    comment="MikroGit backup + RouterOS update"
/user set [find name=ИМЯ_ПОЛЬЗОВАТЕЛЯ] group=mikrogit
```

Если группа уже есть, политики **заменяются** списком — добавьте к текущим
`ftp` и `sensitive` (иначе `.backup` не скачается):

```
/user group set [find name=mikrogit] policy=ssh,read,write,test,reboot,ftp,sensitive
```

После смены политик пользователю нужно переподключиться (выйти/войти по SSH).
Скрипт сам подскажет эту команду в логе, если увидит, что у пользователя нет
`sensitive`/`ftp`:

```
ERROR: AP_U2_Conf: файл ...backup есть на роутере (24 KB), но scp/sftp не может
его забрать: у пользователя backupUser нет политик: sensitive (группа backup)
WARNING: Исправить (на роутере, от admin): /user group set [find name=backup] policy=...,sensitive
```

## Частые проблемы

| Симптом | Причина / решение |
|---|---|
| `scp` не скачивает `.backup`, файл остаётся на роутере | Нет политики `ftp` **или `sensitive`** у пользователя (`.backup` содержит пароли — RouterOS не отдаёт его без `sensitive`). Скрипт определяет это сам и пишет готовую команду `/user group set ... policy=...,ftp,sensitive` |
| В Telegram «Backup failed!» без причины | Так писала старая версия. Обновите ветку (`git fetch origin && git switch -C arena/38d8b8f6-mkgit origin/arena/38d8b8f6-mkgit`) и перезапустите бота — теперь причина и подсказка приходят в самом сообщении |
| «файл не появился на роутере» | Мало места на flash. Скрипт сам чистит свои старые бэкапы (старше 30 дней) и повторяет сохранение; если места нет — в логе/Telegram будет причина и список самых больших файлов (см. «Мало места на flash роутера») |
| Бот не видит бэкапы | `BACKUP_DIR` в `tg_bot_config.sh` не совпадает с каталогом, куда пишет `MikroGit.sh` |
| Устройство висит в статусе «нет бэкапов» | Раньше папки создавались пустыми из-за `.rsc.rsc`; теперь пустые каталоги чистятся, а бэкап проверяется по размеру |
| Расписание не срабатывает | `bash tg/mk_schedule.sh status` — демон запущен? Проверьте время сервера/часовой пояс |
| `No such file or directory` при `bash tg/mk_schedule.sh` | Команда запускается из каталога `tg/` — используйте `bash mk_schedule.sh status` или `bash tg/mk_schedule.sh status` из корня проекта |
| git: `dubious ownership` / `cannot open .git/FETCH_HEAD: Permission denied` | Репозиторием владеет root после `sudo su`: `sudo chown -R aionis:aionis ~/MikroGit` (см. `tg/mkgit_doctor.sh`) |
| `Unit mkgit-bot.service not found` | Юнит не установлен: `sudo bash ~/MikroGit/tg/install_systemd.sh` |
| `cp: cannot stat 'tg/mkgit-bot.service.example'` | Команда запущена из `tg/` — вернитесь в корень репозитория (`cd ~/MikroGit`) |
| Копии бота появляются снова после `pkill` | Их перезапускает tmux/screen-сессия или цикл: смотрите `tg/mkgit_doctor.sh` (строка «родитель») и `tmux ls` |
| Бот стартует, но бэкапы падают с «Cannot connect» | Бот запущен от root → ключ ищется в `/root/.ssh`. Запускайте от `aionis` (см. «Не запускайте от root») |
| Бэкапы «перед обновлением» пропали | Проверьте `MAX_PRE_UPDATE_BACKUPS`: они ротируются отдельно от плановых |

## Важные замечания

- `.backup` **шифруется паролем роутера**, если не указан `dont-encrypt=yes`;
  скрипт всегда использует `dont-encrypt=yes`, чтобы файл можно было
  восстановить без пароля. Храните каталог `bckp/` с ограниченными правами.
- `.backup` восстанавливается только на **ту же модель/ветку** RouterOS; для
  просмотра конфигурации глазами удобнее `/export` (старые `.rsc` остаются).
- Перед установкой всегда делается резервная копия — но она не является
  откатом версии RouterOS (откат — только downgrade-пакетом вручную).
- Конфигурация (`tg_bot_config.sh`), `devices.conf`, `bckp/` и `logs/` не
  попадают в git (см. `.gitignore`).

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

В репозитории есть готовые юниты:

```bash
sudo cp tg/mkgit-bot.service.example      /etc/systemd/system/mkgit-bot.service
sudo cp tg/mkgit-schedule.service.example /etc/systemd/system/mkgit-schedule.service
# поправьте в них User=/пути, если у вас другой пользователь/каталог
sudo systemctl daemon-reload
sudo systemctl enable --now mkgit-bot mkgit-schedule
sudo systemctl status mkgit-bot mkgit-schedule
```

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
- `ftp` — **нужен для scp/sftp** — без него бэкап не скачается с роутера.

```
/user group add name=mikrogit policy=ssh,read,write,test,reboot,ftp \
    comment="MikroGit backup + RouterOS update"
/user set [find name=ИМЯ_ПОЛЬЗОВАТЕЛЯ] group=mikrogit
```

## Частые проблемы

| Симптом | Причина / решение |
|---|---|
| `scp` не скачивает `.backup`, файл остаётся на роутере | Нет политики `ftp` у пользователя, либо файл ещё пишется (скрипт повторяет попытки ~15 с) |
| «файл не появился на роутере» | Мало места на flash (`/system resource print` → free-hdd-space) |
| Бот не видит бэкапы | `BACKUP_DIR` в `tg_bot_config.sh` не совпадает с каталогом, куда пишет `MikroGit.sh` |
| Устройство висит в статусе «нет бэкапов» | Раньше папки создавались пустыми из-за `.rsc.rsc`; теперь пустые каталоги чистятся, а бэкап проверяется по размеру |
| Расписание не срабатывает | `bash tg/mk_schedule.sh status` — демон запущен? Проверьте время сервера/часовой пояс |
| `No such file or directory` при `bash tg/mk_schedule.sh` | Команда запускается из каталога `tg/` — используйте `bash mk_schedule.sh status` или `bash tg/mk_schedule.sh status` из корня проекта |
| `Unit mkgit-bot.service not found` | Юнит не установлен: `sudo cp tg/mkgit-bot.service.example /etc/systemd/system/mkgit-bot.service && sudo systemctl daemon-reload` |
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

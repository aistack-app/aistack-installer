# AIStack installer (v1.5)

Установка AI-команды **одной командой** в Terminal. Никаких bundle.zip, никакой распаковки.

```bash
bash <(curl -fsSL https://aistack-app.github.io/aistack-installer/install.sh) ВАШ-КЛЮЧ
```

Пример ключа: `AIS-TEAM-FULL-A7B3XK92`

**Windows** (PowerShell, без WSL; права администратора не нужны) — пока только сборка COACH:
```powershell
iwr -useb https://aistack-app.github.io/aistack-installer/install.ps1 -OutFile "$env:TEMP\aistack-install.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\aistack-install.ps1" ВАШ-КЛЮЧ
```

## Платформы
- ✅ macOS (Intel + Apple Silicon)
- ✅ Ubuntu 22.04+
- ✅ Debian 12+
- 🧪 Windows 10 20H2+ / 11 — нативно через PowerShell (`install.ps1`), только сборка COACH.
  OpenClaw ставится официальным `install.ps1` (Node он ставит сам), gateway — Scheduled Task.
  **На реальной Windows ещё не проверялось**: офлайн-тесты гоняют `install.ps1` под `pwsh`
  на Linux (логика и паритет с bash), но не Windows PowerShell 5.1, winget, Scheduled Task и кодировки консоли.
  Hermes в Windows-версии не ставится.

## Сборки
Ключ `AIS-<ТАРИФ>-<СБОРКА>-<СЛУЧАЙНАЯ ЧАСТЬ>`. Сборка **COACH** — команда начинающего помогающего
эксперта: координатор-технарь, дизайнер, копирайтер (3 Telegram-бота), память команды —
папка-vault на компьютере клиента (открывается в Obsidian). Шаблоны ролей —
`templates/_presets/coach-team/`, скелет vault — `templates/_vault/`.
Генерация картинок, движок «Твоим голосом», видео и Telegram-воронка в этой версии **не подключены**:
шаблоны честно помечают их как ручной этап до отдельной проверки.

## Что делает
0. Сначала спрашивает всё нужное: API-ключ, провайдера и модель (список — `lib/models.tsv`),
   Telegram-токены, для COACH — папку памяти. Без годных ключей ничего не устанавливает.
1. Проверяет систему (ОС, архитектура, интернет, диск)
2. Ставит системные зависимости (Python 3.11+, Node, git, sqlite, ripgrep, ffmpeg)
3. Hermes runtime — через PyPI-пакет `hermes-agent` в свой venv (**без Chromium** → ARM-safe)
4. OpenClaw — `npm install -g openclaw`
5. Шаблоны команды — тянет с публичного репо шаблонов
6. Сохраняет ключ и модель в OpenClaw, создаёт vault (COACH), персонализирует шаблоны
7. Регистрирует агентов
8. Запускает и показывает dashboard `http://localhost:18789`

Время установки: ~3–5 минут (без browser-tools).

## Структура
```
install.sh            точка входа (само-бутстрап: грузит lib/ локально или с github)
lib/helpers.sh        цвета, логи, спиннер, прогресс, traps, watchdog, retry, parse_key
lib/preflight.sh      detect_os / detect_arch / интернет / диск
lib/apt-deps.sh       системные пакеты (apt / brew) + DEBIAN_FRONTEND
lib/hermes-setup.sh   Hermes через pip (venv + hermes-agent)
lib/openclaw-setup.sh OpenClaw + регистрация агентов
lib/workspace-deploy.sh  шаблоны workspace по пресету
lib/wizard.sh         сбор ключа / модели / токенов / vault (офлайн-проверка ключей)
lib/models.tsv        офлайн-список моделей для выбора (общий для bash и PowerShell)
install.ps1           Windows-установщик (PowerShell 5.1+, UTF-8 с BOM), только COACH
templates/_presets/   версии ролей под конкретную сборку (coach-team)
templates/_vault/     скелет памяти команды
tests/                офлайн-тесты: bash tests/run.sh
```

## Тестовый прогон (без установки)
```bash
AISTACK_DRY_RUN=1 bash install.sh AIS-START-COACH-TEST0001
```
В dry-run без ключей подставляются явные заглушки. В реальной установке заглушки,
пустые и заведомо неверные ключи отклоняются (`AIS-TEAM-FULL-DEV1234` больше не
включает заглушки). Офлайн нельзя доказать, что ключ рабочий: это видно только
при первом живом запросе к провайдеру.

## Тесты
```bash
bash tests/run.sh
```
Офлайн, в песочнице (свой HOME/TMPDIR, заглушки sudo/curl/npm/openclaw/браузера),
только выдуманные ключи. Проверки Windows-установщика выполняются, если есть `pwsh`
(иначе — явный SKIP); это не замена прогону на реальной Windows.

## Переменные окружения (для отладки/CI)
| Переменная | Назначение |
|---|---|
| `AISTACK_DRY_RUN=1` | не выполнять системные команды, только печатать |
| `AISTACK_NONINTERACTIVE=1` | без интерактива (брать ключ/токены из env) |
| `AISTACK_API_KEY` | API-ключ в неинтерактивном режиме (обязателен вне dry-run) |
| `AISTACK_TG_TOKENS` | TG-токены через пробел — ровно по одному на агента |
| `AISTACK_PROVIDER` | провайдер, если его не видно по ключу (`openai` по умолчанию) |
| `AISTACK_MODEL` | модель `провайдер/модель` (по умолчанию — рекомендованная из `lib/models.tsv`) |
| `AISTACK_VAULT` | папка памяти команды для COACH (по умолчанию `~/AIStack-Vault`) |
| `AISTACK_TEMPLATES_DIR` | локальный каталог шаблонов вместо скачивания (тесты, разработка) |
| `AISTACK_LOG` | путь к логу (по умолчанию — новый временный файл с правами 600) |
| `AISTACK_BASE_URL` | откуда грузить lib/ (по умолчанию github pages) |
| `AISTACK_TEMPLATES_URL` | tarball с workspace-templates |
| `AISTACK_HERMES_SPEC` | pip-спец Hermes (по умолчанию `hermes-agent`) |

Powered by Hermes + OpenClaw (open source).

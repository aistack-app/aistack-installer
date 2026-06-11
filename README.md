# AIStack installer (v1.5)

Установка AI-команды **одной командой** в Terminal. Никаких bundle.zip, никакой распаковки.

```bash
bash <(curl -fsSL https://aistack-app.github.io/aistack-installer/install.sh) ВАШ-КЛЮЧ
```

Пример ключа: `AIS-TEAM-FULL-A7B3XK92`

## Платформы
- ✅ macOS (Intel + Apple Silicon)
- ✅ Ubuntu 22.04+
- ✅ Debian 12+
- ❌ Windows — не в v1.5 (для Windows напишите [@superwalletsru](https://t.me/superwalletsru) про Personal-тариф)

## Что делает
1. Проверяет систему (ОС, архитектура, интернет, диск)
2. Ставит системные зависимости (Python 3.11+, Node, git, sqlite, ripgrep, ffmpeg)
3. Hermes runtime — через PyPI-пакет `hermes-agent` в свой venv (**без Chromium** → ARM-safe)
4. OpenClaw — `npm install -g openclaw`
5. Шаблоны команды — тянет с публичного репо шаблонов
6. Спрашивает API-ключ нейросети + Telegram-токены ботов
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
lib/wizard.sh         сбор ключа / токенов / имени проекта
```

## Тестовый прогон (без установки)
```bash
AISTACK_DRY_RUN=1 bash install.sh AIS-TEAM-FULL-DEV1234
```

## Переменные окружения (для отладки/CI)
| Переменная | Назначение |
|---|---|
| `AISTACK_DRY_RUN=1` | не выполнять системные команды, только печатать |
| `AISTACK_NONINTERACTIVE=1` | без интерактива (брать ключ/токены из env) |
| `AISTACK_API_KEY` | API-ключ в неинтерактивном режиме |
| `AISTACK_TG_TOKENS` | TG-токены через пробел |
| `AISTACK_BASE_URL` | откуда грузить lib/ (по умолчанию github pages) |
| `AISTACK_TEMPLATES_URL` | tarball с workspace-templates |
| `AISTACK_HERMES_SPEC` | pip-спец Hermes (по умолчанию `hermes-agent`) |

Powered by Hermes + OpenClaw (open source).

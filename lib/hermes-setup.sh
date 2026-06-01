# shellcheck shell=bash
# ============================================================================
# hermes-setup.sh — Hermes runtime через PyPI-пакет hermes-agent (БЕЗ их install.sh).
#
# Почему так: пакет `hermes-agent` есть на PyPI (0.15.x, py>=3.11). `playwright`
# у него ОПЦИОНАЛЬНАЯ extra — значит core-установка НЕ тянет Chromium → ARM-safe
# по умолчанию (это снимает всю боль БРИФ-7/9). Ставим в свой venv, минуя uv/clone.
#
# ⚠️ TO-VERIFY (проверить в Docker-тесте, могут отличаться от реальности пакета):
#   1) команда запуска рантайма (ниже HERMES_SERVE_CMD) — предположение;
#   2) схема config.yaml — создаём минимальную, Hermes может перегенерить свою;
#   3) порт 7777 / health-эндпоинт.
# Эти места помечены TO-VERIFY и сделаны нефатальными (run_soft), чтобы установка
# дошла до конца, а точные детали мы поправим после первого реального прогона.
# ============================================================================

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

hermes_install() {
  CURRENT_STAGE="Stage 3: Hermes runtime (pip)"
  # PYTHON_BIN уже выставлен в Stage 2 (ensure_python_311_or_newer); подстрахуемся для macOS/повторов
  [ -z "${PYTHON_BIN:-}" ] && resolve_python

  substep "Создаю структуру ~/.hermes/"
  run mkdir -p "$HERMES_HOME"/{logs,sessions,config,skills,workspaces}
  run mkdir -p "$HOME/.local/bin"

  substep "Python venv ($PYTHON_BIN): $HERMES_HOME/venv"
  run_step "Создаю venv" "$PYTHON_BIN" -m venv "$HERMES_HOME/venv"

  # pip core-установка: БЕЗ extras → без playwright/Chromium (ARM-safe).
  # Можно переопределить набор extras через AISTACK_HERMES_SPEC (напр. "hermes-agent[anthropic]").
  local spec="${AISTACK_HERMES_SPEC:-hermes-agent}"
  run_step "Обновляю pip" "$HERMES_HOME/venv/bin/python" -m pip install --upgrade pip wheel
  run_step "Ставлю Hermes ($spec) — без browser-tools, ARM-safe" \
    "$HERMES_HOME/venv/bin/pip" install "$spec"

  # Симлинк CLI в ~/.local/bin (user-writable, не требует root)
  if [ -x "$HERMES_HOME/venv/bin/hermes" ] || [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then
    run ln -sf "$HERMES_HOME/venv/bin/hermes" "$HOME/.local/bin/hermes"
    ok "Hermes установлен ($spec)"
  else
    warn "Бинарь hermes не найден в venv/bin — возможно изменилось имя entry-point пакета."
    warn "Проверьте: $HERMES_HOME/venv/bin/ . Установка продолжается."
  fi

  _hermes_write_config
  _hermes_start
}

_hermes_write_config() {
  # .env с ключом — пакет использует python-dotenv (надёжная часть)
  if [ "${AISTACK_DRY_RUN:-0}" != "1" ]; then
    umask 177
    printf 'HERMES_LLM_KEY=%s\nANTHROPIC_API_KEY=%s\nOPENAI_API_KEY=%s\n' \
      "${API_KEY:-}" "${API_KEY:-}" "${API_KEY:-}" > "$HERMES_HOME/.env"
    umask 022
  fi
  # TO-VERIFY: минимальный config.yaml. Схема — предположение из брифа; если Hermes
  # сам генерит свою при первом запуске, этот файл будет перезаписан/проигнорирован.
  if [ ! -f "$HERMES_HOME/config.yaml" ] && [ "${AISTACK_DRY_RUN:-0}" != "1" ]; then
    cat > "$HERMES_HOME/config.yaml" <<YAML
# AIStack · минимальный конфиг Hermes (TO-VERIFY против реальной схемы пакета)
provider: ${HERMES_PROVIDER:-anthropic}
backend:
  type: local
YAML
  fi
  ok "Конфиг Hermes записан (~/.hermes/.env + config.yaml)"
}

_hermes_start() {
  # Правильная команда запуска runtime Hermes — `hermes gateway` (НЕ `serve`, его в пакете
  # НЕТ). Подтверждено по wheel: entry-point `hermes = hermes_cli.main:main`, подкоманды
  #   gateway [run|start|stop|status|install]. Оф. установщик Hermes без systemd делает
  #   `nohup hermes gateway &` — повторяем этот универсальный (в т.ч. Docker) путь.
  # Готовность определяем через `hermes gateway status` + живой процесс — НЕ через curl :7777
  # (HTTP-порта 7777 у пакета нет, это было ошибочное наследие старой bundle-архитектуры).
  local HBIN="$HERMES_HOME/venv/bin/hermes"
  local serve_cmd="${AISTACK_HERMES_SERVE_CMD:-gateway}"
  mkdir -p "$HERMES_HOME/logs" 2>/dev/null || true

  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then ok "Hermes gateway (dry-run, пропуск)"; return 0; fi

  substep "Запускаю Hermes ($serve_cmd) в фоне"
  nohup "$HBIN" $serve_cmd >> "$HERMES_HOME/logs/gateway.log" 2>&1 &
  local gw_pid=$!

  # Retry готовности: 10 попыток по 3 сек
  local i=1 ready=0
  while [ "$i" -le 10 ]; do
    if "$HBIN" gateway status 2>/dev/null | grep -qiE 'is running|gateway running|pid [0-9]|online'; then ready=1; break; fi
    kill -0 "$gw_pid" 2>/dev/null || break   # процесс умер и status не показывает running → не поднялся
    sleep 3; heartbeat; i=$((i + 1))
  done
  # foreground-режим (Docker): если процесс всё ещё жив — считаем поднятым
  if [ "$ready" -eq 0 ] && kill -0 "$gw_pid" 2>/dev/null; then ready=1; fi

  "$HBIN" gateway status >> "$LOG" 2>&1 || true   # снимок статуса в лог для диагностики

  if [ "$ready" -eq 1 ]; then
    ok "Hermes gateway запущен (PID $gw_pid)"
  else
    warn "Hermes gateway не поднялся за 30с (лог: $HERMES_HOME/logs/gateway.log)."
    warn "Не критично: Telegram-агенты работают через OpenClaw; Hermes используется как память."
    warn "Проверить вручную: $HBIN gateway status"
  fi
}

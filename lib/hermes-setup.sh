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
  resolve_python

  substep "Создаю структуру ~/.hermes/"
  run mkdir -p "$HERMES_HOME"/{logs,sessions,config,skills,workspaces}
  run mkdir -p "$HOME/.local/bin"

  substep "Python venv: $HERMES_HOME/venv"
  run_step "Создаю venv" "$PY_BIN" -m venv "$HERMES_HOME/venv"

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
  # TO-VERIFY: точная команда старта рантайма. Нефатально (run_soft) — если имя
  # подкоманды другое, установка дойдёт до конца, а команду поправим после теста.
  local serve_cmd="${AISTACK_HERMES_SERVE_CMD:-serve}"
  run_soft "Запускаю Hermes runtime (hermes $serve_cmd)" \
    bash -c "nohup '$HERMES_HOME/venv/bin/hermes' $serve_cmd >> '$LOG' 2>&1 &"
  sleep 2
  HERMES_OK=0
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then HERMES_OK=1; fi
  curl -sf http://localhost:7777/health >/dev/null 2>&1 && HERMES_OK=1 || true
  if [ "$HERMES_OK" -eq 1 ]; then ok "Hermes отвечает (порт 7777)"; else
    warn "Hermes health-check (7777) не прошёл. Это TO-VERIFY место — уточним команду старта после Docker-теста."
    warn "Память (Hermes) можно поднять позже вручную; базовая команда агентов работает и без неё."
  fi
}

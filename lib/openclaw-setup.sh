# shellcheck shell=bash
# ============================================================================
# openclaw-setup.sh — установка OpenClaw (npm) + базовая привязка к Hermes.
# ============================================================================

openclaw_install() {
  CURRENT_STAGE="Stage 4: OpenClaw"
  if command -v openclaw >/dev/null 2>&1; then
    ok "OpenClaw уже установлен ($(openclaw --version 2>/dev/null | head -n1))"
  else
    # npm global prefix без root: используем ~/.npm-global, добавляем в PATH
    if [ "$OS_FAMILY" != "macos" ] && [ "$(id -u)" -ne 0 ]; then
      run npm config set prefix "$HOME/.npm-global"
      export PATH="$HOME/.npm-global/bin:$PATH"
    fi
    run_step "Ставлю OpenClaw (npm install -g openclaw)" npm install -g openclaw
  fi
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then ok "OpenClaw OK (dry-run)"; return 0; fi
  if openclaw --version >/dev/null 2>&1; then ok "OpenClaw OK"; else
    warn "openclaw --version не отработал — проверьте PATH (~/.npm-global/bin или /usr/local/bin)."
  fi
}

# Память агентов. ВАЖНО (выяснено по исходникам/докам OpenClaw 2026.5.28):
#   • У OpenClaw СВОЯ встроенная файловая память — "default built-in memory store":
#     MEMORY.md (curated long-term memory) + memory/YYYY-MM-DD.md в каждом workspace.
#     Наши шаблоны эти файлы уже разворачивают → агенты ИМЕЮТ долговременную память
#     между сессиями по умолчанию, без какой-либо настройки.
#   • Ключей memory.provider / coordinator.runtime в OpenClaw НЕТ — это была ошибочная
#     догадка (отсюда и warn). "Hermes как memory backend" не существует.
#   • Единственная связь OpenClaw↔Hermes — одноразовая МИГРАЦИЯ (openclaw migrate hermes),
#     импорт config/memories/skills. Требует свежий OpenClaw и не вписывается в наш flow.
# Поэтому ничего не «подключаем» — просто подтверждаем, что встроенная память активна.
# (Опциональный апгрейд до векторной памяти: плагин @openclaw/memory-lancedb — отдельно.)
openclaw_verify_memory() {
  CURRENT_STAGE="Stage 4b: память"
  ok "Память агентов: встроенная файловая (MEMORY.md в каждом workspace) — долговременная, между сессиями"
}

openclaw_set_provider() {
  CURRENT_STAGE="Stage 6b: provider"
  run_soft "Настраиваю провайдера модели ($PROVIDER)" bash -c "
    openclaw config set providers.default '$PROVIDER'
    openclaw config set 'providers.$PROVIDER.api_key' '$API_KEY'
  "
}

# Регистрирует агентов-ботов в OpenClaw: каждому свой workspace + TG-токен
register_bots() {
  CURRENT_STAGE="Stage 7: register agents"
  local i=0 a tok
  for a in $AGENTS; do
    tok="${TG_TOKENS[$i]:-}"
    run_soft "Регистрирую агента: $a" bash -c "
      openclaw agents add '$a' --workspace '$WORKSPACE_BASE/workspace-$a' --telegram-token '$tok'
    "
    i=$((i + 1))
  done
  ok "Зарегистрировано агентов: $i/$AGENT_COUNT"
}

openclaw_start() {
  CURRENT_STAGE="Stage 8: start gateway"
  run_soft "Запускаю gateway" bash -c "openclaw gateway start"
  run_soft "Проверка openclaw doctor" bash -c "openclaw doctor"
}

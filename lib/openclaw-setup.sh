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

openclaw_link_hermes() {
  # Привязываем память/runtime к Hermes (нефатально)
  run_soft "Подключаю Hermes как память" bash -c "openclaw config set memory.provider hermes; openclaw config set coordinator.runtime hermes"
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

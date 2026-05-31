# shellcheck shell=bash
# ============================================================================
# wizard.sh — интерактивный сбор: API-ключ, TG-токены (по числу агентов), имя проекта.
# Неинтерактивный режим (DEV-ключ / AISTACK_NONINTERACTIVE=1 / нет TTY) — берёт из env.
# Выставляет: API_KEY, PROVIDER, BUSINESS_NAME, TG_TOKENS (массив).
# ============================================================================

_infer_provider() {
  case "$1" in
    sk-ant-*) PROVIDER="anthropic";;
    sk-or-*)  PROVIDER="openrouter";;
    AIza*)    PROVIDER="gemini";;
    sk-*)     PROVIDER="${AISTACK_PROVIDER:-openai}";;
    *)        PROVIDER="${AISTACK_PROVIDER:-anthropic}";;
  esac
}

_is_noninteractive() {
  [ "${AISTACK_NONINTERACTIVE:-0}" = "1" ] && return 0
  [ "$RAW_KEY" = "AIS-TEAM-FULL-DEV1234" ] && return 0
  [ ! -t 0 ] && return 0
  return 1
}

run_wizard() {
  CURRENT_STAGE="Stage 6: wizard"
  TG_TOKENS=()

  if _is_noninteractive; then
    say "Неинтерактивный режим (DEV/CI) — беру значения из окружения / заглушки."
    API_KEY="${AISTACK_API_KEY:-sk-ant-DEV-PLACEHOLDER}"
    BUSINESS_NAME="${AISTACK_BUSINESS:-Demo Project}"
    # AISTACK_TG_TOKENS — токены через пробел
    local t i=0
    for t in ${AISTACK_TG_TOKENS:-}; do TG_TOKENS+=("$t"); i=$((i+1)); done
    while [ "$i" -lt "$AGENT_COUNT" ]; do TG_TOKENS+=("000000:DEV-PLACEHOLDER-$i"); i=$((i+1)); done
    _infer_provider "$API_KEY"
    ok "Конфиг принят (provider: $PROVIDER, токенов: ${#TG_TOKENS[@]})"
    return 0
  fi

  echo ""
  echo "${MAG}▶ Настройка${RST}"
  # 1) API-ключ
  echo "  Вставьте API-ключ нейросети (Anthropic sk-ant-… / OpenAI sk-… / ProxyAPI):"
  printf "  ключ: "
  read -rs API_KEY; echo ""
  while [ -z "$API_KEY" ]; do printf "  ${YEL}Ключ пуст. Вставьте ещё раз:${RST} "; read -rs API_KEY; echo ""; done
  _infer_provider "$API_KEY"
  ok "Провайдер: $PROVIDER"

  # 2) Имя проекта
  printf "  Название вашего проекта/бизнеса (Enter — пропустить): "
  read -r BUSINESS_NAME
  [ -z "$BUSINESS_NAME" ] && BUSINESS_NAME="Мой проект"

  # 3) TG-токены — по числу агентов
  echo ""
  echo "  Создайте ${GRN}$AGENT_COUNT${RST} ботов в @BotFather и вставьте их токены —"
  echo "  по одному в строке (формат 123456789:AA...). Агенты: $AGENTS"
  local n=1
  while [ "$n" -le "$AGENT_COUNT" ]; do
    printf "  токен %d/%d: " "$n" "$AGENT_COUNT"
    local tok; read -r tok
    if [ -z "$tok" ]; then warn "пусто — попробуйте снова"; continue; fi
    TG_TOKENS+=("$tok")
    n=$((n+1))
  done
  ok "Принято токенов: ${#TG_TOKENS[@]}"
}

# Записывает API-ключ в конфиги (вызывается после wizard)
save_api_key() {
  openclaw_set_provider
}

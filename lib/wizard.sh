# shellcheck shell=bash
# ============================================================================
# wizard.sh — интерактивный сбор: API-ключ, TG-токены (по числу агентов), имя проекта.
# Неинтерактивный режим (DEV-ключ / AISTACK_NONINTERACTIVE=1 / нет TTY) — берёт из env.
# Выставляет: API_KEY, PROVIDER, BUSINESS_NAME, TG_TOKENS (массив), OWNER_TG_ID.
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
    OWNER_TG_ID="${AISTACK_OWNER_TG_ID:-}"
    CHANNEL_ID="${AISTACK_CHANNEL_ID:-}"
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

  # 2b) Telegram ID владельца — для allowlist: иначе боты встречают хозяина
  # pairing-кодом, а любой посторонний может писать агентам.
  echo ""
  echo "  Ваш Telegram ID — чтобы боты отвечали только вам."
  echo "  ${CYA}Узнать ID: напишите @userinfobot в Telegram (пришлёт число).${RST}"
  OWNER_TG_ID=""
  printf "  Telegram ID (Enter — настроить позже): "
  read -r OWNER_TG_ID
  if [ -n "$OWNER_TG_ID" ] && ! printf '%s' "$OWNER_TG_ID" | grep -qE '^[0-9]{5,12}$'; then
    warn "Не похоже на числовой ID — пропускаю (настроите позже: openclaw config set)"
    OWNER_TG_ID=""
  fi
  [ -n "$OWNER_TG_ID" ] && ok "Доступ будет ограничен ID: $OWNER_TG_ID"

  # 3) TG-токены — по числу агентов, с подсказкой имени для каждого
  echo ""
  echo "  Создайте ${GRN}$AGENT_COUNT${RST} ботов в @BotFather (/newbot) и вставьте токены"
  echo "  по одному (формат 123456789:AA...)."
  local studio_slug
  studio_slug="$(printf '%s' "$BUSINESS_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-12)"
  [ -z "$studio_slug" ] && studio_slug="studio"
  local n=1 a
  for a in $AGENTS; do
    echo "  ${DIM}бот для «$(_agent_title "$a")» — имя в BotFather, например: $(_bot_hint "$a" "$studio_slug")${RST}"
    printf "  токен %d/%d (%s): " "$n" "$AGENT_COUNT" "$a"
    local tok; read -r tok
    while [ -z "$tok" ]; do printf "  ${YEL}пусто — вставьте токен:${RST} "; read -r tok; done
    TG_TOKENS+=("$tok")
    n=$((n+1))
  done
  ok "Принято токенов: ${#TG_TOKENS[@]}"

  # 4) Канал команды — только для сборки «Малый бизнес»
  CHANNEL_ID=""
  if [ "$PRESET_ID" = "smallbiz-team" ]; then
    echo ""
    echo "  Private-канал «Команда ${BUSINESS_NAME}» — лента итогов от Хозяина."
    echo "  ${CYA}1. Создайте private-канал в Telegram${RST}"
    echo "  ${CYA}2. Добавьте бота Хозяина администратором канала${RST}"
    echo "  ${CYA}3. Перешлите любой пост канала боту @JsonDumpBot — он покажет chat.id${RST}"
    printf "  ID канала (вида -100..., Enter — настроить позже): "
    read -r CHANNEL_ID
    if [ -n "$CHANNEL_ID" ] && ! printf '%s' "$CHANNEL_ID" | grep -qE '^-?[0-9]{6,16}$'; then
      warn "Не похоже на ID канала — пропускаю (заполните потом в workspace-khozyain/channel-config.json)"
      CHANNEL_ID=""
    fi
    [ -n "$CHANNEL_ID" ] && ok "Канал команды: $CHANNEL_ID"
  fi
}

# Человеческое имя отдела для подсказок wizard
_agent_title() {
  case "$1" in
    voice) echo "Голос · клиенты";;
    pero) echo "Перо · контент";;
    rost) echo "Рост · маркетинг";;
    chasy) echo "Часы · операционка";;
    khozyain) echo "Хозяин · координатор";;
    *) echo "$1";;
  esac
}

_bot_hint() {
  case "$1" in
    voice|pero|rost|chasy) echo "${1}_${2}_bot";;
    khozyain) echo "boss_${2}_bot";;
    *) echo "${1}_${2}_bot";;
  esac
}

# Записывает API-ключ в конфиги (вызывается после wizard)
save_api_key() {
  openclaw_set_provider
}

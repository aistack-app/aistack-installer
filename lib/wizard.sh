# shellcheck shell=bash
# ============================================================================
# wizard.sh — интерактивный сбор: API-ключ, TG-токены (по числу агентов), имя проекта.
# Неинтерактивный режим (AISTACK_DRY_RUN=1 / AISTACK_NONINTERACTIVE=1 / нет TTY) — берёт
# из env; заглушки допустимы только в dry-run, реальная установка без ключей — отказ.
# Выставляет: API_KEY, PROVIDER, BUSINESS_NAME, TG_TOKENS (массив), OWNER_TG_ID.
# ============================================================================

_infer_provider() {
  case "$1" in
    sk-ant-*) PROVIDER="anthropic";;
    sk-or-*)  PROVIDER="openrouter";;
    AIza*)    PROVIDER="gemini";;
    sk-*)     PROVIDER="${AISTACK_PROVIDER:-openai}";;
    # неизвестный формат ключа (прокси и т.п.): по умолчанию OpenAI — клиенты
    # чаще всего на GPT; в интерактиве провайдер спрашивается явно
    *)        PROVIDER="${AISTACK_PROVIDER:-openai}";;
  esac
}

# ── Модель: офлайн-список lib/models.tsv (общий с install.ps1) ───────────────
# Выбор делается при установке вместо жёстко заданной модели. Доступна ли
# модель ключу клиента, офлайн не проверить — это живая проверка.
MODELS_FILE="${AISTACK_MODELS_FILE:-$(dirname "${BASH_SOURCE[0]:-$0}")/models.tsv}"
models_for()    { awk -F'\t' -v p="$1" '$0 !~ /^#/ && $1 == p { print $2 }' "$MODELS_FILE" 2>/dev/null; }
default_model() { awk -F'\t' -v p="$1" '$0 !~ /^#/ && $1 == p && $3 == "1" { print $2; exit }' "$MODELS_FILE" 2>/dev/null; }
# model_problem <провайдер> <модель> → причина (пусто = формат годится)
model_problem() {
  local p="$1" m="$2"
  if [ -z "$m" ]; then echo "модель не выбрана"
  elif ! printf '%s' "$m" | grep -qE '^[a-z0-9-]+/[A-Za-z0-9._:/-]+$'; then
    echo "id модели пишется как провайдер/модель, например openai/gpt-5.5"
  elif [ "${m%%/*}" != "$p" ]; then echo "модель $m не относится к провайдеру $p"
  fi
}

# ── Vault (память команды) — только для сборки COACH ────────────────────────
# vault_problem <путь> → причина (пусто = годится)
vault_problem() {
  case "$1" in
    "") echo "путь пуст";;
    /*) case "$1" in
          "$HOME"|"$HOME/"|"$HOME/.openclaw"|"$HOME/.openclaw/"*) echo "нужна отдельная папка, не сам домашний каталог и не .openclaw";;
        esac;;
    *) echo "нужен полный путь (например $HOME/AIStack-Vault)";;
  esac
}
_expand_home() { case "$1" in "~") echo "$HOME";; "~/"*) echo "$HOME/${1#\~/}";; *) echo "$1";; esac; }

_is_noninteractive() {
  [ "${AISTACK_NONINTERACTIVE:-0}" = "1" ] && return 0
  [ "${AISTACK_DRY_RUN:-0}" = "1" ] && return 0
  [ ! -t 0 ] && return 0
  return 1
}

# ── Офлайн-проверка ключей (fail-closed) ─────────────────────────────────────
# Отсекает пустое, заглушки и явно неверный формат. НЕ доказывает, что ключ
# рабочий: это возможно только живым запросом к провайдеру (отдельный шаг).
_looks_placeholder() {
  case "$1" in
    *PLACEHOLDER*|*placeholder*|*EXAMPLE*|*example*|*not-real*|*NOT-REAL*|*REPLACE*|*'<'*|*'>'*|*'...'*|*'…'*|000000:*) return 0;;
  esac
  return 1
}
# api_key_problem <ключ> → печатает причину (пусто = ключ принят)
api_key_problem() {
  local k="$1"
  if [ -z "$k" ]; then echo "ключ пуст"
  elif _looks_placeholder "$k"; then echo "это заглушка/пример, а не ваш ключ"
  elif printf '%s' "$k" | grep -q '[[:space:]]'; then echo "в ключе есть пробелы — скопируйте его целиком без переносов"
  elif [ "${#k}" -lt 20 ]; then echo "слишком короткий для API-ключа"
  fi
}
# tg_token_problem <токен> → причина (пусто = формат 123456789:AA… от @BotFather)
tg_token_problem() {
  local t="$1"
  if [ -z "$t" ]; then echo "токен пуст"
  elif _looks_placeholder "$t"; then echo "это заглушка/пример, а не токен бота"
  elif ! printf '%s' "$t" | grep -qE '^[0-9]{6,12}:[A-Za-z0-9_-]{30,}$'; then
    echo "не похоже на токен @BotFather (ожидается 123456789:AA…)"
  fi
}

run_wizard() {
  CURRENT_STAGE="Stage 6: wizard"
  TG_TOKENS=()

  if _is_noninteractive; then
    local dry=0 t i=0 p
    [ "${AISTACK_DRY_RUN:-0}" = "1" ] && dry=1
    BUSINESS_NAME="${AISTACK_BUSINESS:-Demo Project}"
    OWNER_TG_ID="${AISTACK_OWNER_TG_ID:-}"
    CHANNEL_ID="${AISTACK_CHANNEL_ID:-}"
    API_KEY="${AISTACK_API_KEY:-}"
    # AISTACK_TG_TOKENS — токены через пробел
    for t in ${AISTACK_TG_TOKENS:-}; do TG_TOKENS+=("$t"); i=$((i+1)); done

    if [ "$dry" = "1" ] && [ -z "$API_KEY" ] && [ "$i" -eq 0 ]; then
      # Заглушки — ТОЛЬКО в dry-run, где ничего не устанавливается
      say "Dry-run без ключей — подставляю заглушки (в реальной установке это запрещено)."
      API_KEY="sk-DEV-PLACEHOLDER"   # нейтральная: провайдер по умолчанию (OpenAI)
      while [ "$i" -lt "$AGENT_COUNT" ]; do TG_TOKENS+=("000000:DEV-PLACEHOLDER-$i"); i=$((i+1)); done
    else
      say "Неинтерактивный режим — беру ключ и токены из окружения."
      p="$(api_key_problem "$API_KEY")"
      if [ -n "$p" ]; then
        err "AISTACK_API_KEY: $p. Без рабочего ключа установка не продолжается."
        exit 1
      fi
      if [ "$i" -ne "$AGENT_COUNT" ]; then
        err "AISTACK_TG_TOKENS: нужно $AGENT_COUNT токен(ов) через пробел (по одному на агента: $AGENTS), передано $i."
        exit 1
      fi
      i=1
      for t in "${TG_TOKENS[@]}"; do
        p="$(tg_token_problem "$t")"
        if [ -n "$p" ]; then err "AISTACK_TG_TOKENS, токен $i: $p."; exit 1; fi
        i=$((i+1))
      done
    fi
    _infer_provider "$API_KEY"
    MODEL="${AISTACK_MODEL:-$(default_model "$PROVIDER")}"
    if [ -n "$MODEL" ]; then
      p="$(model_problem "$PROVIDER" "$MODEL")"
      if [ -n "$p" ]; then err "AISTACK_MODEL: $p."; exit 1; fi
    fi
    VAULT_PATH=""
    if [ "$PRESET_ID" = "coach-team" ]; then
      VAULT_PATH="$(_expand_home "${AISTACK_VAULT:-$HOME/AIStack-Vault}")"
      p="$(vault_problem "$VAULT_PATH")"
      if [ -n "$p" ]; then err "AISTACK_VAULT: $p."; exit 1; fi
    fi
    ok "Конфиг принят (provider: $PROVIDER, модель: ${MODEL:-выбрать позже}, токенов: ${#TG_TOKENS[@]})"
    return 0
  fi

  echo ""
  echo "${MAG}▶ Настройка${RST}"
  # 1) API-ключ
  echo "  Вставьте API-ключ нейросети (Anthropic sk-ant-… / OpenAI sk-… / ProxyAPI):"
  printf "  ключ: "
  read -rs API_KEY; echo ""
  local p
  p="$(api_key_problem "$API_KEY")"
  while [ -n "$p" ]; do
    printf "  ${YEL}%s. Вставьте ключ ещё раз:${RST} " "$p"; read -rs API_KEY; echo ""
    p="$(api_key_problem "$API_KEY")"
  done
  _infer_provider "$API_KEY"
  case "$API_KEY" in
    sk-ant-*|sk-or-*|sk-*|AIza*) :;;
    *) _ask_provider;;   # формат ключа не говорит, чей он — спрашиваем
  esac
  ok "Провайдер: $PROVIDER"
  _ask_model

  # 2) Имя проекта
  printf "  Название вашего проекта/бизнеса (Enter — пропустить): "
  read -r BUSINESS_NAME
  [ -z "$BUSINESS_NAME" ] && BUSINESS_NAME="Мой проект"

  # 2a) Память команды — только для сборки COACH
  VAULT_PATH=""
  [ "$PRESET_ID" = "coach-team" ] && _ask_vault

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
    p="$(tg_token_problem "$tok")"
    while [ -n "$p" ]; do
      printf "  ${YEL}%s — вставьте токен ещё раз:${RST} " "$p"; read -r tok
      p="$(tg_token_problem "$tok")"
    done
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

# ── Интерактивные вопросы: провайдер, модель, vault ─────────────────────────
_ask_provider() {
  local ans
  echo "  Чей это ключ?  1) OpenAI (GPT)   2) Anthropic (Claude)   3) OpenRouter"
  printf "  номер (Enter — 1): "; read -r ans
  case "$ans" in
    2) PROVIDER="anthropic";; 3) PROVIDER="openrouter";; *) PROVIDER="openai";;
  esac
}

_ask_model() {
  local list m n=0 def ans p
  list="$(models_for "$PROVIDER")"; def="$(default_model "$PROVIDER")"
  if [ -z "$list" ]; then
    MODEL=""
    warn "Для провайдера $PROVIDER нет готового списка моделей — выберете после установки (openclaw models set)."
    return 0
  fi
  echo "  Модель для команды:"
  for m in $list; do
    n=$((n + 1))
    if [ "$m" = "$def" ]; then echo "    $n) $m  ${DIM}(рекомендуется)${RST}"; else echo "    $n) $m"; fi
  done
  echo "    или впишите свой id (провайдер/модель)"
  while :; do
    printf "  номер или id (Enter — %s): " "$def"; read -r ans
    case "$ans" in
      "") MODEL="$def";;
      *[!0-9]*) MODEL="$ans";;
      *) MODEL="$(printf '%s\n' $list | sed -n "${ans}p")";;
    esac
    p="$(model_problem "$PROVIDER" "$MODEL")"
    [ -z "$p" ] && break
    printf "  ${YEL}%s${RST}\n" "$p"
  done
  ok "Модель: $MODEL (доступ к ней проверяется при первом запуске)"
}

_ask_vault() {
  local ans p def="$HOME/AIStack-Vault"
  echo ""
  echo "  Память команды — папка с заметками на этом компьютере (открывается в Obsidian)."
  while :; do
    printf "  Где создать (Enter — %s): " "$def"; read -r ans
    VAULT_PATH="$(_expand_home "${ans:-$def}")"
    p="$(vault_problem "$VAULT_PATH")"
    [ -z "$p" ] && break
    printf "  ${YEL}%s${RST}\n" "$p"
  done
  ok "Память команды: $VAULT_PATH"
}

# Человеческое имя отдела для подсказок wizard
_agent_title() {
  if [ "${PRESET_ID:-}" = "coach-team" ]; then
    case "$1" in
      coordinator) echo "Координатор-технарь"; return;;
      designer) echo "Дизайнер · креативы"; return;;
      copywriter) echo "Копирайтер · тексты"; return;;
    esac
  fi
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

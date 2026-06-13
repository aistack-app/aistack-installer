# shellcheck shell=bash
# ============================================================================
# openclaw-setup.sh — установка OpenClaw (npm, ПИН ВЕРСИИ) + провайдер модели,
# регистрация агентов-ботов, gateway как сервис.
#
# ВАЖНО ПРО ПИН: схема openclaw.json ломается между версиями (проверено на
# живой миграции 2026.4.27 → 2026.6.5: agentRuntime переехал с уровня агента
# на уровень модели). Весь код ниже написан под схему и CLI пина — при смене
# пина перепроверять: agents add / channels add / config set пути.
# ============================================================================

OPENCLAW_PIN="${AISTACK_OPENCLAW_PIN:-2026.6.5}"

openclaw_install() {
  CURRENT_STAGE="Stage 4: OpenClaw"

  # npm global prefix без root: используем ~/.npm-global, добавляем в PATH.
  # НО: если node стоит через nvm — prefix НЕ трогаем (nvm с ним несовместим
  # и перестанет переключать версии; у nvm свой user-writable prefix).
  if [ "$OS_FAMILY" != "macos" ] && [ "$(id -u)" -ne 0 ]; then
    case "$(command -v node 2>/dev/null)" in
      *"/.nvm/"*) say "Node через nvm — npm prefix не трогаем (несовместимы)";;
      *)
        run npm config set prefix "$HOME/.npm-global"
        export PATH="$HOME/.npm-global/bin:$PATH"
        _persist_npm_global_path;;
    esac
  fi

  local cur=""
  cur="$(openclaw --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -n1 || true)"
  if [ "$cur" = "$OPENCLAW_PIN" ]; then
    ok "OpenClaw $OPENCLAW_PIN уже установлен"
  else
    [ -n "$cur" ] && warn "Найден OpenClaw $cur — ставлю протестированную версию $OPENCLAW_PIN"
    run_step "Ставлю OpenClaw $OPENCLAW_PIN (npm install -g)" npm install -g "openclaw@$OPENCLAW_PIN"
  fi
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then ok "OpenClaw OK (dry-run)"; return 0; fi

  # Явная проверка версии — а не просто «команда нашлась» (иначе старый
  # системный openclaw маскирует неудавшуюся установку)
  cur="$(openclaw --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -n1 || true)"
  if [ "$cur" = "$OPENCLAW_PIN" ]; then
    ok "OpenClaw OK ($cur)"
  else
    err "OpenClaw $OPENCLAW_PIN не подтвердился (фактически: ${cur:-не найден})."
    err "Проверьте PATH (~/.npm-global/bin или /usr/local/bin) и запустите заново."
    exit 1
  fi

  # Самообновление движка — ВЫКЛЮЧИТЬ. Реальный инцидент: фоновый автоапдейт
  # подменил файлы под работающим gateway → ERR_MODULE_NOT_FOUND, все боты легли.
  run_soft "Отключаю автообновление движка" openclaw config set update.auto.enabled false --strict-json

  # Защита существующей установки: если конфиг уже есть и в нём есть агенты —
  # бэкап до любых наших правок (agents add по живому id не перезапишет, но
  # каналы/провайдера мы трогаем).
  local cfg="$HOME/.openclaw/openclaw.json"
  if [ -f "$cfg" ] && grep -q '"list"' "$cfg" 2>/dev/null; then
    local bak="$cfg.bak-aistack-$(date +%Y%m%d-%H%M%S)"
    cp "$cfg" "$bak" 2>/dev/null \
      && warn "Найдена существующая установка OpenClaw — бэкап конфига: $bak"
  fi
}

# PATH для новых терминалов: без этого после закрытия окна `openclaw`
# превращается в command not found (npm prefix ~/.npm-global не в PATH по
# умолчанию). Дописываем в rc-файлы только если строки ещё нет.
_persist_npm_global_path() {
  local line='export PATH="$HOME/.npm-global/bin:$PATH"' rc
  for rc in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    grep -qsF '.npm-global/bin' "$rc" || echo "$line" >> "$rc"
  done
}

# Память агентов. ВАЖНО (выяснено по исходникам/докам OpenClaw):
#   • У OpenClaw СВОЯ встроенная файловая память — MEMORY.md + memory/*.md
#     в каждом workspace; наши шаблоны её уже разворачивают.
#   • Ключей memory.provider / coordinator.runtime НЕ существует,
#     «Hermes как memory backend» — нет; связь только openclaw migrate hermes.
openclaw_verify_memory() {
  CURRENT_STAGE="Stage 4b: память"
  ok "Память агентов: встроенная файловая (MEMORY.md в каждом workspace) — долговременная, между сессиями"
}

# Провайдер модели. Пути в схеме (проверены на живом конфиге $OPENCLAW_PIN):
#   agents.defaults.model.primary  — модель по умолчанию для всех агентов
#   env.vars.<KEY>                 — env-переменные для процессов агентов
# Путей providers.default / providers.<p>.api_key в схеме НЕ существует —
# старый вариант молча не работал.
openclaw_set_provider() {
  CURRENT_STAGE="Stage 6b: provider"
  case "$PROVIDER" in
    anthropic)
      run_soft "Модель по умолчанию: anthropic/claude-sonnet-4-6" \
        openclaw config set agents.defaults.model.primary "anthropic/claude-sonnet-4-6"
      run_soft "Сохраняю API-ключ (env.vars)" \
        openclaw config set env.vars.ANTHROPIC_API_KEY "$API_KEY";;
    openrouter)
      run_soft "Сохраняю API-ключ OpenRouter (env.vars)" \
        openclaw config set env.vars.OPENROUTER_API_KEY "$API_KEY"
      # Без этого дефолт остаётся openai/* без ключа → каждый ответ бота
      # падает «Missing API key for provider openai» (поймано на живом VPS).
      # openrouter/auto — роутер OpenRouter, сам выбирает доступную модель.
      run_soft "Модель по умолчанию: openrouter/auto" \
        openclaw config set agents.defaults.model.primary "openrouter/auto";;
    *)
      run_soft "Сохраняю API-ключ (env.vars)" \
        openclaw config set "env.vars.$(printf '%s' "$PROVIDER" | tr '[:lower:]' '[:upper:]')_API_KEY" "$API_KEY"
      warn "Провайдер $PROVIDER: модель выберите после установки (dashboard → Settings)";;
  esac
}

# Регистрация агентов-ботов. Реальный CLI пина (флага --telegram-token НЕ
# существует — старый вариант молча проваливался):
#   1) телеграм-аккаунт с токеном:  channels add --channel telegram --account <a> --bot-token <tok>
#   2) агент + биндинг на аккаунт:  agents add <a> --non-interactive --workspace <ws> --bind telegram:<a>
#   3) доступ владельцу (allowlist) — иначе бот встречает pairing-кодом
register_bots() {
  CURRENT_STAGE="Stage 7: register agents"
  local i=0 a tok registered=0
  for a in $AGENTS; do
    tok="${TG_TOKENS[$i]:-}"
    if [ -n "$tok" ]; then
      # именно --token: --bot-token телеграмом не принимается
      # («Telegram requires token or --token-file») — поймано Docker-тестом
      run_soft "Telegram-аккаунт: $a" \
        openclaw channels add --channel telegram --account "$a" --token "$tok"
    fi
    if ( run openclaw agents add "$a" --non-interactive \
           --workspace "$WORKSPACE_BASE/workspace-$a" --bind "telegram:$a" ); then
      registered=$((registered + 1))
      ok "Агент: $a"
    else
      warn "Агент $a: agents add не отработал (возможно, уже существует) — см. лог $LOG"
    fi
    # Доступ только владельцу (если ID собран в wizard)
    if [ -n "${OWNER_TG_ID:-}" ]; then
      run_soft "Доступ владельцу: $a" bash -c "
        openclaw config set 'channels.telegram.accounts.$a.dmPolicy' allowlist
        openclaw config set 'channels.telegram.accounts.$a.allowFrom' '[\"$OWNER_TG_ID\"]' --strict-json
      "
    fi
    i=$((i + 1))
    # Telegram банит при создании/подключении многих ботов подряд — пауза
    [ "$i" -lt "$AGENT_COUNT" ] && sleep 2
  done

  # Владелец команд (доступ к /diagnostics и owner-командам в ботах)
  if [ -n "${OWNER_TG_ID:-}" ]; then
    run_soft "Владелец команд: $OWNER_TG_ID" \
      openclaw config set commands.ownerAllowFrom "[\"telegram:$OWNER_TG_ID\"]" --strict-json
  fi

  ok "Зарегистрировано агентов: $registered/$AGENT_COUNT"

  setup_smallbiz_runtime

  # Конфиг после всех правок ОБЯЗАН быть валидным — иначе gateway не стартует
  if [ "${AISTACK_DRY_RUN:-0}" != "1" ]; then
    if run openclaw config validate; then
      ok "Конфиг валиден"
    else
      err "Конфиг не прошёл валидацию после регистрации агентов. Лог: $LOG"
      err "Бэкап исходного конфига (если был): ~/.openclaw/openclaw.json.bak-aistack-*"
      exit 1
    fi
  fi
}

# Рантайм сборки «Малый бизнес»: событийная шина + интервалы HEARTBEAT
# по ARCHITECTURE-5-BOTS.md (Хозяин 15m, Часы 30m, Голос 1h; Перо/Рост —
# дефолт, их HEARTBEAT.md сам говорит «только шина»).
setup_smallbiz_runtime() {
  [ "${PRESET_ID:-}" = "smallbiz-team" ] || return 0
  CURRENT_STAGE="Stage 7b: smallbiz runtime"
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then ok "Шина и heartbeat (dry-run)"; return 0; fi

  # Событийная шина — файл должен существовать до первого тика
  mkdir -p "$HOME/.aistack" && touch "$HOME/.aistack/events.log"
  ok "Событийная шина: ~/.aistack/events.log"

  # Интервалы тиков per-agent (схема: agents.list[i].heartbeat.every).
  # Правим конфиг python-ом: config set по индексу списка хрупок.
  if python3 - <<'PYEOF'
import json, os
path = os.path.expanduser("~/.openclaw/openclaw.json")
# pero/rost работают «по запросу», но задачи из шины забираются ТОЛЬКО
# на тике — без тика task_for_department лежал бы в файле вечно
# (поймано на живом VPS). 15м тик = только проверка шины, дёшево.
beats = {"khozyain": "15m", "chasy": "30m", "voice": "1h", "pero": "15m", "rost": "15m"}
with open(path) as f:
    d = json.load(f)
changed = False
for a in d.get("agents", {}).get("list", []):
    every = beats.get(a.get("id"))
    if every and a.get("heartbeat", {}).get("every") != every:
        a["heartbeat"] = {"every": every}
        changed = True
if changed:
    with open(path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
PYEOF
  then
    ok "HEARTBEAT: Хозяин 15м · Часы 30м · Голос 1ч"
  else
    warn "Не удалось выставить интервалы heartbeat — настройте позже (agents.list[].heartbeat.every)"
  fi
}

openclaw_start() {
  CURRENT_STAGE="Stage 8: start gateway"
  # install = сервис (launchd/systemd) → gateway переживает перезагрузку машины
  run_soft "Ставлю gateway как сервис (автозапуск)" openclaw gateway install

  # TLS-страховка: node может не доверять системным CA (антивирусы/VPN с
  # MITM-инспекцией — частый кейс в РФ). Реальный инцидент: все боты легли
  # с UNKNOWN_CERTIFICATE_VERIFICATION_ERROR; лечится этими переменными.
  local svc_env="$HOME/.openclaw/service-env/ai.openclaw.gateway.env"
  if [ "${AISTACK_DRY_RUN:-0}" != "1" ] && [ -f "$svc_env" ] \
     && ! grep -q "NODE_USE_SYSTEM_CA" "$svc_env" 2>/dev/null; then
    {
      echo "export NODE_USE_SYSTEM_CA='1'"
      [ -f /etc/ssl/cert.pem ] && echo "export NODE_EXTRA_CA_CERTS='/etc/ssl/cert.pem'"
    } >> "$svc_env" 2>/dev/null && ok "TLS: доверие системным сертификатам включено"
  fi

  run_soft "Запускаю gateway" openclaw gateway start
  # Подтверждение по факту, с ретраями. Холодный старт gateway (прогрев
  # провайдеров + плагинов) на медленном VPS легко занимает >15с —
  # поэтому окно 30с (10×3с), иначе ложный warn после рабочей установки.
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then ok "Gateway OK (dry-run)"; return 0; fi
  local try=0
  while [ "$try" -lt 10 ]; do
    if openclaw gateway status 2>/dev/null | grep -qiE "running|reachable"; then
      ok "Gateway работает"
      return 0
    fi
    try=$((try + 1)); sleep 3; heartbeat
  done
  # Не дождались за 30с — но gateway уже запущен командой выше; на машинах
  # без systemd (контейнеры) статус и не подтвердится — это норма.
  warn "Gateway не подтвердил статус за 30с. Если вы на обычном сервере — проверьте: openclaw gateway status (в контейнере без systemd это ожидаемо)."
}

# shellcheck shell=bash
# ============================================================================
# AIStack installer · helpers.sh — цвета, логи, спиннер, прогресс, traps,
# watchdog, retry, parse_key. Портировано из private-installer.html / БРИФ-6/7/10.
# ============================================================================

# ── Цвета ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'; RED=$'\033[31m'; MAG=$'\033[35m'; RST=$'\033[0m'
else
  GRN=""; YEL=""; CYA=""; RED=""; MAG=""; RST=""
fi

LOG="${AISTACK_LOG:-/tmp/aistack-install.log}"
: > "$LOG" 2>/dev/null || true

# ── Логирование ─────────────────────────────────────────────────────────────
say()     { echo "${CYA}▸${RST} $*"; }
ok()      { echo "${GRN}✓${RST} $*"; }
warn()    { echo "${YEL}!${RST} $*"; }
err()     { echo "${RED}❌ $*${RST}" >&2; }
stage()   { echo ""; echo "${MAG}▶ $*${RST}"; heartbeat; }
substep() { echo "  ${CYA}↳${RST} $*"; heartbeat; }

# ── DRY-RUN обёртка для тяжёлых/системных команд (тесты в песочнице) ─────────
# AISTACK_DRY_RUN=1 → команды только печатаются в лог, не выполняются.
run() {
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then
    echo "[dry-run] $*" >> "$LOG"
    return 0
  fi
  "$@" >> "$LOG" 2>&1
}

# ── Спиннер пока жив фоновый процесс $1 ─────────────────────────────────────
spinner() {
  local pid="$1" msg="$2" chars='|/-' i=0 rc=0
  if [ -t 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      i=$(( (i + 1) % 3 ))
      printf "\r  ${CYA}%s${RST} %s" "${chars:$i:1}" "$msg"
      sleep 0.2; heartbeat
    done
  else
    echo "  · $msg"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; heartbeat; done
  fi
  wait "$pid" || rc=$?
  if [ "$rc" -eq 0 ]; then printf "\r  ${GRN}✓${RST} %s\n" "$msg"; else printf "\r  ${RED}✗${RST} %s\n" "$msg"; fi
  return "$rc"
}

# Редакция секретов в любом выводе для пользователя: ученики шлют скриншоты
# ошибок в поддержку — TG-токены и API-ключи не должны светиться.
redact() {
  sed -E \
    -e 's/[0-9]{8,12}:[A-Za-z0-9_-]{30,}/[TG_TOKEN]/g' \
    -e 's/sk-[A-Za-z0-9_-]{20,}/sk-[REDACTED]/g' \
    -e 's/(API_KEY[^=]*=)[^ ]+/\1[REDACTED]/g'
}

# run_step "сообщение" cmd...  → тихо (в лог) + спиннер, фатально при ошибке
run_step() {
  local msg="$1"; shift
  ( run "$@" ) &
  if ! spinner "$!" "$msg"; then
    err "Не удалось: $msg"
    echo "     ${RED}лог: $LOG${RST} (последние строки):"
    tail -n 15 "$LOG" 2>/dev/null | redact | sed 's/^/       /'
    exit 1
  fi
}

# run_soft — то же, но ошибка не критична
run_soft() {
  local msg="$1"; shift
  ( run "$@" ) &
  spinner "$!" "$msg" || warn "$msg — не критично (см. лог: $LOG)"
}

# retry cmd... — до 3 попыток при сетевых сбоях (РФ/VPN)
retry() {
  local n=1 max=3 delay=5
  while true; do
    "$@" && return 0
    if [ "$n" -lt "$max" ]; then
      warn "сеть: попытка $n/$max не удалась, повтор через $delay сек..."
      n=$((n + 1)); sleep "$delay"
    else
      return 1
    fi
  done
}

# ── Watchdog (БРИФ-7) — прибивает зомби-процессы по тишине heartbeat ─────────
WATCHDOG_PID=""
WATCHDOG_HEARTBEAT_FILE="${AISTACK_HB:-/tmp/aistack-heartbeat-$$}"
touch "$WATCHDOG_HEARTBEAT_FILE" 2>/dev/null || true
get_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
heartbeat() { touch "$WATCHDOG_HEARTBEAT_FILE" 2>/dev/null || true; }

start_watchdog() {
  local max_silence="${1:-600}"
  local main_pgid; main_pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  stop_watchdog
  touch "$WATCHDOG_HEARTBEAT_FILE" 2>/dev/null || true
  (
    set +e
    while [ -e "$WATCHDOG_HEARTBEAT_FILE" ]; do
      sleep 30
      [ -e "$WATCHDOG_HEARTBEAT_FILE" ] || exit 0
      local last now silence
      last=$(get_mtime "$WATCHDOG_HEARTBEAT_FILE"); now=$(date +%s)
      silence=$(( now - ${last:-now} ))
      if [ "$silence" -gt "$max_silence" ]; then
        echo "" >&2
        echo "${RED}❌ Watchdog: процесс не двигается ${silence}с (лимит ${max_silence}с).${RST}" >&2
        echo "   Залип на: ${CURRENT_STAGE:-?}. Лог: $LOG" >&2
        [ -n "$main_pgid" ] && kill -9 -- -"$main_pgid" 2>/dev/null
        exit 0
      fi
    done
  ) &
  WATCHDOG_PID=$!
  disown "$WATCHDOG_PID" 2>/dev/null || true
}
stop_watchdog() {
  if [ -n "${WATCHDOG_PID:-}" ] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
  fi
  WATCHDOG_PID=""
}

# ── Traps (БРИФ-6 + мини-фикс) ──────────────────────────────────────────────
CURRENT_STAGE="инициализация"
install_traps() {
  trap 'echo ""; err "Установка прервана пользователем (Ctrl+C). Запустите команду заново."; rm -f "$WATCHDOG_HEARTBEAT_FILE" 2>/dev/null; stop_watchdog; exit 130' INT TERM
  trap 'EXIT_CODE=$?; if [ "$EXIT_CODE" = "130" ]; then err "Установка прервана (Ctrl+C). Запустите заново."; else err "Ошибка на стейдже: ${CURRENT_STAGE}. Лог: $LOG"; fi; rm -f "$WATCHDOG_HEARTBEAT_FILE" 2>/dev/null; stop_watchdog; exit "$EXIT_CODE"' ERR
  trap 'rm -f "$WATCHDOG_HEARTBEAT_FILE" 2>/dev/null || true; stop_watchdog' EXIT
}

# ── parse_key (порт parseAccessKey из private-installer.html) ────────────────
# Формат: AIS-<TARIFF>-<PRESET>-<RANDOM>. RANDOM может быть разбит на группы
# через дефис (AIS-TEAM-FULL-A7B3-XK92) — берём всё после 3-го дефиса.
# Выставляет: KEY_VALID, TARIFF, PRESET_ID, AGENTS, AGENT_COUNT, HAS_CRITIC,
#            HAS_LESSONS, IS_PERSONAL, KEY_ERROR.
parse_key() {
  KEY_VALID=false; TARIFF=""; PRESET_ID=""; AGENTS=""; AGENT_COUNT=0
  HAS_CRITIC=false; HAS_LESSONS=false; IS_PERSONAL=false; KEY_ERROR=""
  local key up tariff preset random rest
  key="$(printf '%s' "${1:-}" | tr -d '[:space:]')"
  if [ -z "$key" ]; then KEY_ERROR="Ключ не указан. Запустите команду с ключом из письма."; return 1; fi
  up="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  case "$up" in
    OPENCLAW*|OPCLAW*) KEY_ERROR="Этот ключ устарел. Новые начинаются с AIS-. Поддержка: @superwalletsru."; return 1;;
  esac
  # парсим: AIS - TARIFF - PRESET - <всё остальное = random>
  local p0 p1 p2
  p0="${up%%-*}"; rest="${up#*-}"
  if [ "$p0" != "AIS" ] || [ "$rest" = "$up" ]; then KEY_ERROR="Неправильный формат. Ожидается AIS-TARIFF-PRESET-RANDOM."; return 1; fi
  p1="${rest%%-*}"; rest="${rest#*-}"
  if [ "$rest" = "$p1" ]; then KEY_ERROR="Неправильный формат. Не хватает частей ключа."; return 1; fi
  p2="${rest%%-*}"; rest="${rest#*-}"
  if [ "$rest" = "$p2" ] || [ -z "$rest" ]; then KEY_ERROR="Неправильный формат. Не хватает случайной части ключа."; return 1; fi
  tariff="$p1"; preset="$p2"; random="$(printf '%s' "$rest" | tr -d '-')"

  case " MINI START PROFI TEAM PERSONAL " in
    *" $tariff "*) :;;
    *) KEY_ERROR="Неизвестный тариф: $tariff. Допустимы: MINI, START, PROFI, TEAM, PERSONAL."; return 1;;
  esac

  # SMALLBIZ — отдельная вертикаль «Малый бизнес» (5 ботов-отделов),
  # допустима на любом тарифе (ценовую матрицу решает генератор ключей)
  case " PROFI TEAM PERSONAL " in
    *" $tariff "*)
      case " FULL SMALLBIZ " in
        *" $preset "*) :;;
        *) KEY_ERROR="Тариф $tariff требует сборку FULL или SMALLBIZ (в ключе: $preset). Поддержка: @superwalletsru."; return 1;;
      esac;;
    *)
      case " CONTENT SALES EXPERT BUSINESS SCHOOL TECH SMALLBIZ " in
        *" $preset "*) :;;
        *) KEY_ERROR="Сборка $preset не существует. Для $tariff допустимы: CONTENT, SALES, EXPERT, BUSINESS, SCHOOL, TECH, SMALLBIZ."; return 1;;
      esac;;
  esac

  if ! printf '%s' "$random" | grep -qE '^[A-Z0-9]{6,12}$'; then
    KEY_ERROR="Случайная часть ключа некорректна (ожидается 6–12 символов A–Z / 0–9)."; return 1
  fi

  case "$preset" in
    CONTENT)  PRESET_ID="content-team";  AGENTS="copywriter contentmaker designer";;
    SALES)    PRESET_ID="sales-team";    AGENTS="coordinator negotiator marketer";;
    EXPERT)   PRESET_ID="expert-team";   AGENTS="coordinator copywriter negotiator";;
    BUSINESS) PRESET_ID="business-team"; AGENTS="producer marketer negotiator";;
    SCHOOL)   PRESET_ID="school-team";   AGENTS="coordinator producer copywriter";;
    TECH)     PRESET_ID="tech-team";     AGENTS="coordinator tech";;
    FULL)     PRESET_ID="full-team";     AGENTS="coordinator tech producer marketer designer copywriter contentmaker negotiator";;
    SMALLBIZ) PRESET_ID="smallbiz-team"; AGENTS="voice pero rost chasy khozyain";;
  esac
  AGENT_COUNT=$(printf '%s\n' $AGENTS | grep -c .)

  TARIFF="$(printf '%s' "$tariff" | tr '[:upper:]' '[:lower:]')"
  case " TEAM PERSONAL " in *" $tariff "*) HAS_CRITIC=true;; esac
  case " START TEAM PERSONAL " in *" $tariff "*) HAS_LESSONS=true;; esac
  [ "$tariff" = "PERSONAL" ] && IS_PERSONAL=true
  KEY_VALID=true
  return 0
}

# shellcheck shell=bash
# ============================================================================
# apt-deps.sh — системные зависимости. apt (Debian/Ubuntu, +DEBIAN_FRONTEND из
# БРИФ-10) / brew (macOS). Python ≥ 3.11 (не хардкод 3.11) и Node ≥ 20 (NodeSource).
# Выставляет глобально: PYTHON_BIN — интерпретатор для venv Hermes.
# ============================================================================

install_system_deps() {
  if [ "$OS_FAMILY" = "macos" ]; then
    _deps_macos
  else
    _deps_debian
  fi
}

_deps_debian() {
  # БРИФ-10: APT-defaults для headless — без них apt виснет на tzdata/needrestart в Docker/CI
  export DEBIAN_FRONTEND=noninteractive
  export TZ=UTC
  export NEEDRESTART_MODE=a
  export APT_LISTCHANGES_FRONTEND=none

  local SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
      err "Нужны права root для установки системных пакетов, но sudo не найден."
      err "Запустите от root или установите sudo."
      exit 1
    fi
  fi

  run_step "Обновляю списки пакетов (apt-get update)" $SUDO apt-get update -y
  # Базовые пакеты. software-properties-common даёт add-apt-repository (для deadsnakes).
  # nodejs здесь НЕ ставим — Node ставит NodeSource (apt-овый слишком старый, см. ensure_node).
  run_step "Ставлю базовые пакеты (git, curl, sqlite, ripgrep, ffmpeg, tools)" \
    $SUDO apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg xz-utils sqlite3 ripgrep ffmpeg \
      software-properties-common
  ensure_python_311_or_newer "$SUDO"
  ensure_node "$SUDO"
  ok "Системные зависимости установлены"
}

_deps_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    err "Homebrew не установлен. Установите его: https://brew.sh, затем запустите команду заново."
    err '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
  fi
  # python@3.11 — минимально требуемая ветка; node свежий через brew по умолчанию
  run_step "Ставлю зависимости через brew (python@3.11, node, git, sqlite, ripgrep, ffmpeg)" \
    brew install python@3.11 node git sqlite ripgrep ffmpeg
  ok "Системные зависимости установлены (brew)"
}

# ── Python ≥ 3.11 (FIX: не хардкод 3.11) ────────────────────────────────────
# Если в системе уже есть python ≥ 3.11 (Ubuntu 24.04 = 3.12, Debian 13 = 3.13) —
# используем его. Иначе ставим новейшую доступную ветку (deadsnakes на Ubuntu).
ensure_python_311_or_newer() {
  local SUDO="$1"
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then PYTHON_BIN="python3"; ok "Python ≥3.11 (dry-run, пропуск)"; return 0; fi
  if _has_python_311_or_newer; then resolve_python; return 0; fi
  # 1) базовые репы (Debian 12+: 3.11; новее дистры — новее)
  _try_install_python "$SUDO" && { resolve_python; return 0; }
  # 2) deadsnakes PPA — только Ubuntu (ставит новейшую доступную ветку из PPA)
  if [ "${OS_DISTRO:-}" = "ubuntu" ]; then
    run_step "Добавляю deadsnakes PPA (свежий Python для Ubuntu)" $SUDO add-apt-repository -y ppa:deadsnakes/ppa
    run_step "Обновляю списки после PPA" $SUDO apt-get update -y
    _try_install_python "$SUDO" && { resolve_python; return 0; }
  fi
  err "Не удалось установить Python ≥ 3.11 (Hermes требует ≥ 3.11)."
  err "Ubuntu: deadsnakes PPA. Debian 12+ содержит python3.11+ в базовых репах."
  exit 1
}

# Пробует поставить новейшую доступную ветку: 3.13 → 3.12 → 3.11 (первая успешная)
_try_install_python() {
  local SUDO="$1" ver
  for ver in 3.13 3.12 3.11; do
    if run $SUDO apt-get install -y --no-install-recommends "python$ver" "python$ver-venv"; then
      if _has_python_311_or_newer; then ok "Python $ver установлен"; return 0; fi
    fi
  done
  return 1
}

# true, если в системе есть python ≥ 3.11 (проверка от новых к старым)
_has_python_311_or_newer() {
  local c
  for c in python3.13 python3.12 python3.11 python3; do
    if command -v "$c" >/dev/null 2>&1 \
       && "$c" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3,11) else 1)' 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Находит лучший python ≥ 3.11 → PYTHON_BIN (используется для venv Hermes)
resolve_python() {
  local cand
  for cand in python3.13 python3.12 python3.11 python3; do
    if command -v "$cand" >/dev/null 2>&1 \
       && "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3,11) else 1)' 2>/dev/null; then
      PYTHON_BIN="$(command -v "$cand")"; ok "Python: $PYTHON_BIN ($("$cand" --version 2>&1))"; return 0
    fi
  done
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then PYTHON_BIN="python3"; ok "Python (dry-run): python3"; return 0; fi
  err "Не найден Python ≥ 3.11. Hermes требует Python ≥ 3.11."
  exit 1
}

# ── Node ≥ 20 (FIX: удалить старый apt-Node 12, поставить NodeSource 22) ────────
# В Ubuntu 22.04 apt даёт Node 12 → OpenClaw падает (nullish `??` = Node 14+).
# Если старый nodejs уже стоит, NodeSource НЕ заменяет его без явного remove
# (конфликт distro-nodejs ↔ nodesource) — поэтому сначала сносим, потом ставим.
ensure_node() {
  local SUDO="$1"
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then ok "Node.js ≥20 (dry-run, пропуск)"; return 0; fi
  if _node_ok; then ok "Node.js свежий ($(node --version 2>/dev/null))"; return 0; fi

  # 1) удаляем старый apt-овый nodejs (Node 12), чтобы NodeSource не конфликтовал
  run_soft "Удаляю старый Node (apt)" bash -c "$SUDO apt-get remove -y nodejs npm libnode72 || true"

  # 2) подключаем NodeSource (нужен root; -E сохраняет DEBIAN_FRONTEND)
  if [ -n "$SUDO" ]; then
    run_step "Подключаю NodeSource (Node 22 LTS)" bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
  else
    run_step "Подключаю NodeSource (Node 22 LTS)" bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -"
  fi

  # 3) ставим Node 22 (включает npm)
  run_step "Ставлю Node.js 22 (включает npm)" $SUDO apt-get install -y nodejs
  hash -r 2>/dev/null || true   # сбрасываем кэш путей bash, чтобы node указывал на новый бинарь

  # 4) проверяем версию — если всё ещё < 20, дальше идти нет смысла (Stage 4 упадёт)
  if _node_ok; then
    ok "Node.js установлен ($(node --version 2>/dev/null))"
  else
    err "Node.js всё ещё < 20 после NodeSource (сейчас: $(node --version 2>/dev/null || echo 'нет'))."
    err "OpenClaw требует Node ≥ 20. Проверьте deb.nodesource.com / сеть и запустите заново."
    exit 1
  fi
}

# true, если node ≥ 20
_node_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local major; major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [ "${major:-0}" -ge 20 ] 2>/dev/null
}

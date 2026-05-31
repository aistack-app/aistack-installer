# shellcheck shell=bash
# ============================================================================
# apt-deps.sh — системные зависимости (Python 3.11, Node, git, curl, sqlite…).
# apt на Debian/Ubuntu (с DEBIAN_FRONTEND — БРИФ-10), brew на macOS.
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
  # python3.11 может отсутствовать в базовых репах старых дистров — ставим что есть,
  # затем проверяем версию в hermes-setup.
  run_step "Ставлю системные зависимости (python3, node, git, curl, sqlite…)" \
    $SUDO apt-get install -y --no-install-recommends \
      python3 python3-venv python3-pip \
      nodejs npm git curl ca-certificates xz-utils sqlite3 ripgrep ffmpeg
  ok "Системные зависимости установлены"
}

_deps_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    err "Homebrew не установлен. Установите его: https://brew.sh, затем запустите команду заново."
    err '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
  fi
  run_step "Ставлю зависимости через brew (python@3.11, node, git, sqlite, ripgrep, ffmpeg)" \
    brew install python@3.11 node git sqlite ripgrep ffmpeg
  ok "Системные зависимости установлены (brew)"
}

# Находит подходящий python3.11+ интерпретатор → PY_BIN
resolve_python() {
  local cand
  for cand in python3.11 python3.12 python3; do
    if command -v "$cand" >/dev/null 2>&1; then
      if "$cand" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3,11) else 1)' 2>/dev/null; then
        PY_BIN="$(command -v "$cand")"; ok "Python: $PY_BIN ($("$cand" --version 2>&1))"; return 0
      fi
    fi
  done
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then PY_BIN="python3"; ok "Python (dry-run): python3"; return 0; fi
  err "Не найден Python 3.11+. Hermes требует Python ≥ 3.11."
  exit 1
}

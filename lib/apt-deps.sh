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
  # Базовые пакеты + software-properties-common (даёт add-apt-repository для PPA)
  run_step "Ставлю базовые пакеты (git, curl, sqlite, ripgrep, ffmpeg, node, tools)" \
    $SUDO apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg xz-utils sqlite3 ripgrep ffmpeg \
      software-properties-common nodejs npm
  # Python 3.11+ — Ubuntu 22.04 идёт с 3.10, поэтому ставим явно (deadsnakes PPA)
  ensure_python311 "$SUDO"
  ok "Системные зависимости установлены"
}

# Гарантирует наличие Python 3.11+. Сначала базовые репы (Debian 12 содержит 3.11),
# затем deadsnakes PPA (Ubuntu-only). Вариант A из БРИФ-фикса.
ensure_python311() {
  local SUDO="$1"
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then ok "Python 3.11 (dry-run, пропуск)"; return 0; fi
  # 1) попытка из текущих реп (Debian 12, отдельные Ubuntu с backports)
  run $SUDO apt-get install -y --no-install-recommends python3.11 python3.11-venv || true
  if _has_python311; then ok "Python 3.11 доступен (базовые репы)"; return 0; fi
  # 2) deadsnakes PPA — только Ubuntu (на Debian этого PPA нет)
  if [ "${OS_DISTRO:-}" = "ubuntu" ]; then
    run_step "Добавляю deadsnakes PPA (Python 3.11 для Ubuntu)" $SUDO add-apt-repository -y ppa:deadsnakes/ppa
    run_step "Обновляю списки после PPA" $SUDO apt-get update -y
    run_step "Ставлю Python 3.11 (deadsnakes)" \
      $SUDO apt-get install -y --no-install-recommends python3.11 python3.11-venv python3.11-distutils
  fi
  if _has_python311; then ok "Python 3.11 установлен"; return 0; fi
  err "Не удалось установить Python 3.11 (Hermes требует ≥ 3.11)."
  err "Ubuntu: нужен deadsnakes PPA. Debian 12+ содержит python3.11 в базовых репах."
  exit 1
}

# true, если в системе есть python ≥ 3.11
_has_python311() {
  local c
  for c in python3.11 python3.12 python3.13 python3; do
    if command -v "$c" >/dev/null 2>&1 \
       && "$c" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3,11) else 1)' 2>/dev/null; then
      return 0
    fi
  done
  return 1
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

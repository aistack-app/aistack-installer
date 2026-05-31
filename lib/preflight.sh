# shellcheck shell=bash
# ============================================================================
# preflight.sh — определение ОС/архитектуры, проверка интернета и диска.
# Выставляет: OS_FAMILY (macos|debian|unknown), ARCH (arm64|amd64|other), PKG (brew|apt)
# ============================================================================

detect_os() {
  OS_FAMILY="unknown"; PKG=""; OS_DISTRO=""
  local uname_s; uname_s="$(uname -s 2>/dev/null || echo unknown)"
  case "$uname_s" in
    Darwin)
      OS_FAMILY="macos"; PKG="brew";;
    Linux)
      if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_DISTRO="${ID:-}"   # ubuntu / debian / … (для выбора deadsnakes PPA)
        case "${ID:-}${ID_LIKE:-}" in
          *ubuntu*|*debian*) OS_FAMILY="debian"; PKG="apt";;
          *) OS_FAMILY="unknown";;
        esac
      fi;;
  esac
  if [ "$OS_FAMILY" = "unknown" ]; then
    err "Неподдерживаемая ОС ($uname_s). v1.5 поддерживает macOS, Ubuntu 22.04+, Debian 12+."
    err "Windows в v1.5 не поддерживается — напишите @superwalletsru про Personal-тариф (установка лично)."
    exit 1
  fi
  ok "ОС: $OS_FAMILY (пакетный менеджер: $PKG)"
}

detect_arch() {
  ARCH="other"
  case "$(uname -m 2>/dev/null)" in
    arm64|aarch64) ARCH="arm64";;
    x86_64|amd64)  ARCH="amd64";;
  esac
  ok "Архитектура: $ARCH"
}

check_internet() {
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then ok "Интернет (dry-run, пропуск)"; return 0; fi
  if curl -fsS --max-time 10 https://pypi.org/simple/ >/dev/null 2>&1 \
     || curl -fsS --max-time 10 https://github.com >/dev/null 2>&1; then
    ok "Интернет доступен"
  else
    err "Нет доступа к интернету (pypi.org / github.com недоступны)."
    err "Проверьте сеть/VPN и запустите команду заново."
    exit 1
  fi
}

check_disk_space() {
  # минимум ~2 ГБ свободно в $HOME
  local need_kb=2097152 free_kb
  free_kb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$free_kb" ] && [ "$free_kb" -lt "$need_kb" ] 2>/dev/null; then
    warn "Мало места на диске ($(( free_kb / 1024 )) МБ свободно, нужно ~2 ГБ). Установка может не поместиться."
  else
    ok "Места на диске достаточно"
  fi
}

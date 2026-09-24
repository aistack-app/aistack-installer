# shellcheck shell=bash
# ============================================================================
# tests/lib.sh — общие помощники офлайн-тестов установщика.
# Каждый тест работает в песочнице: свой HOME, свой TMPDIR и «герметичный» PATH,
# где сетевые/системные команды (curl, sudo, npm, apt-get, openclaw, браузер)
# заменены заглушками, которые только записывают факт вызова.
# Все ключи и токены в тестах — выдуманные.
# ============================================================================

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILS=0
TEST_TMP_BASE="${TMPDIR:-/tmp}"   # песочницы создаются здесь; внутри теста TMPDIR = песочница

pass() { echo "  ok   - $*"; }
fail() { echo "  FAIL - $*"; FAILS=$((FAILS + 1)); }

# Команды, которые НЕ попадают в PATH песочницы из системы
STUB_CMDS="sudo curl wget npm node openclaw apt-get apt add-apt-repository brew open xdg-open hermes id"

# new_sandbox → SANDBOX, SB_HOME, SB_TMP, SB_BIN, SB_CALLS
new_sandbox() {
  SANDBOX="$(mktemp -d "${TEST_TMP_BASE%/}/aistack-test.XXXXXX")"
  SB_HOME="$SANDBOX/home"; SB_TMP="$SANDBOX/tmp"
  SB_BIN="$SANDBOX/bin"; SB_CALLS="$SANDBOX/calls.log"
  mkdir -p "$SB_HOME" "$SB_TMP" "$SB_BIN" "$SANDBOX/sys"
  : > "$SB_CALLS"
  # временные файлы, логи и heartbeat всех вызовов — только внутри песочницы
  export TMPDIR="$SB_TMP" AISTACK_HB="$SB_TMP/hb"

  # системные утилиты — симлинками, кроме заглушаемых
  local d f name
  for d in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      name="${f##*/}"
      case " $STUB_CMDS " in *" $name "*) continue;; esac
      [ -e "$SANDBOX/sys/$name" ] || ln -s "$f" "$SANDBOX/sys/$name"
    done
  done

  # заглушки: пишут вызов в calls.log и завершаются ошибкой (ничего не делают)
  for name in curl wget npm node openclaw apt-get apt add-apt-repository brew open xdg-open hermes; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$name" "$SB_CALLS" > "$SB_BIN/$name"
    chmod +x "$SB_BIN/$name"
  done
  # id -u → 1000: имитируем обычного пользователя, даже если тесты идут от root
  printf '#!/bin/sh\n[ "$1" = "-u" ] && { echo 1000; exit 0; }\nexec /usr/bin/id "$@"\n' > "$SB_BIN/id"
  chmod +x "$SB_BIN/id"
}

# add_sudo_stub — sudo есть в системе (но в dry-run его вызывать нельзя)
add_sudo_stub() {
  printf '#!/bin/sh\necho "sudo $*" >> "%s"\nexit 1\n' "$SB_CALLS" > "$SB_BIN/sudo"
  chmod +x "$SB_BIN/sudo"
}

sb_path() { echo "$SB_BIN:$SANDBOX/sys"; }

# Права файла: GNU stat (Linux) или BSD stat (macOS)
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Снимок HOME: список путей + права + контрольные суммы файлов (переносимо)
home_snapshot() {
  ( cd "$SB_HOME" || exit 1
    find . | sort | while IFS= read -r p; do printf '%s %s\n' "$p" "$(file_mode "$p")"; done
    find . -type f -exec cksum {} + | sort )
}

finish() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  if [ "$FAILS" -gt 0 ]; then echo "  → провалено проверок: $FAILS"; exit 1; fi
  exit 0
}

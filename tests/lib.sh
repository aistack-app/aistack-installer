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

# add_e2e_stubs — заглушки для РЕАЛЬНОГО (не dry-run) прогона install.sh:
# все внешние команды «успешны», ничего не ставят и в сеть не ходят; каждый
# вызов пишется в calls.log (argv), файлы, переданные openclaw, — в files.log.
# sed/grep/awk оборачиваются регистратором argv: так видно секрет в аргументах
# ЛЮБОГО процесса (ps показывает argv всем пользователям машины).
add_e2e_stubs() {
  local name real
  cat > "$SB_BIN/_rec" <<'STUB'
#!/bin/sh
n="${0##*/}"
echo "$n $*" >> "$E2E_CALLS"
argval() { k="$1"; shift; prev=""; for a in "$@"; do [ "$prev" = "$k" ] && { echo "$a"; return; }; prev="$a"; done; }
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
case "$n" in
  openclaw)
    # Заглушка «с состоянием»: помнит добавленные аккаунты/агентов/привязки
    # (файлы $E2E_CALLS.state.*) и отвечает на `config get … --json`.
    # Отказы для тестов: E2E_FAIL_AGENTS_ADD=1, E2E_FAIL_CHANNEL=<роль>,
    # E2E_GATEWAY_DOWN=1. Предустановка: заранее записанные state-файлы.
    st="$E2E_CALLS.state"
    case "$1 $2" in
      "--version "*) echo "OpenClaw 2026.6.5";;
      "gateway status")
        if [ -n "${E2E_GATEWAY_DOWN:-}" ]; then echo "Gateway: stopped (probe failed)"; exit 1; fi
        echo "Gateway: running";;
      "config get")
        case "$3" in
          agents.list)
            printf '['; sep=""; [ -f "$st.agents" ] && while read -r a ws; do
              printf '%s{"id": "%s", "model": {"primary": "x"}, "workspace": "%s"}' "$sep" "$a" "$ws"; sep=", "; done < "$st.agents"
            printf ']\n';;
          bindings)
            printf '['; sep=""; [ -f "$st.agents" ] && while read -r a ws; do
              printf '%s{"agentId": "%s", "match": {"channel": "telegram", "accountId": "%s"}}' "$sep" "$a" "$a"; sep=", "; done < "$st.agents"
            printf ']\n';;
          channels.telegram.accounts)
            printf '{'; sep=""; [ -f "$st.accounts" ] && while read -r a f; do
              printf '%s"%s": {"dmPolicy": "pairing", "tokenFile": "%s"}' "$sep" "$a" "$f"; sep=", "; done < "$st.accounts"
            printf '}\n';;
        esac;;
      "config patch")
        f="$(argval --file "$@")"
        if [ -f "$f" ]; then
          echo "PATCH mode=$(fmode "$f") dir=$(fmode "$(dirname "$f")")" >> "$E2E_CALLS.files"
          cat "$f" >> "$E2E_CALLS.patches"; echo >> "$E2E_CALLS.patches"
        else echo "PATCH missing:$f" >> "$E2E_CALLS.files"; fi;;
      "channels add")
        f="$(argval --token-file "$@")"; a="$(argval --account "$@")"
        if [ -n "$f" ] && [ -f "$f" ]; then
          echo "TOKEN $a mode=$(fmode "$f") dir=$(fmode "$(dirname "$f")") sum=$(cksum < "$f" | cut -d' ' -f1)" >> "$E2E_CALLS.files"
        fi
        if [ "$a" = "${E2E_FAIL_CHANNEL:-}" ]; then echo "Error: telegram rejected token"; exit 1; fi
        grep -q "^$a " "$st.accounts" 2>/dev/null || echo "$a $f" >> "$st.accounts";;
      "agents add")
        a="$3"; ws="$(argval --workspace "$@")"
        if grep -q "^$a " "$st.agents" 2>/dev/null; then echo "Error: agent $a already exists"; exit 9; fi
        if [ -n "${E2E_FAIL_AGENTS_ADD:-}" ]; then echo "Error: agents add failed"; exit 9; fi
        echo "$a $ws" >> "$st.agents";;
    esac; exit 0;;
  python3*)
    [ "$1" = "-m" ] && [ "$2" = "venv" ] && { mkdir -p "$3/bin"; for b in python pip hermes; do cp "$0" "$3/bin/$b"; done; }
    exit 0;;
  hermes) [ "$1 $2" = "gateway status" ] && echo "Gateway is running"; exit 0;;
  curl)
    out="$(argval -o "$@")"
    if [ -n "$out" ]; then   # «скачивание» шаблонов = tarball из рабочей копии репо
      d="$(mktemp -d)"; mkdir -p "$d/aistack-app-aistack-installer-e2e"
      cp -R "$E2E_REPO/templates" "$d/aistack-app-aistack-installer-e2e/"
      tar -czf "$out" -C "$d" . && rm -rf "$d"
    fi; exit 0;;
  *) exit 0;;
esac
STUB
  chmod +x "$SB_BIN/_rec"
  for name in openclaw npm node curl wget apt-get apt add-apt-repository brew sudo hermes python3 python3.11 python3.12 python3.13 open xdg-open; do
    rm -f "$SB_BIN/$name" "$SANDBOX/sys/$name"; ln -s "$SB_BIN/_rec" "$SB_BIN/$name"
  done
  for name in sed grep awk; do
    real="$(readlink "$SANDBOX/sys/$name")"
    printf '#!/bin/sh\necho "%s $*" >> "$E2E_CALLS.argv"\nexec "%s" "$@"\n' "$name" "$real" > "$SB_BIN/$name"
    chmod +x "$SB_BIN/$name"
  done
}

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

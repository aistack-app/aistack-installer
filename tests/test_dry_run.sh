#!/usr/bin/env bash
# Dry-run из README (AISTACK_DRY_RUN=1) не должен: менять HOME, вызывать sudo
# и сетевые/пакетные команды, требовать sudo, открывать браузер, писать секреты в лог.
set -u
. "$(dirname "$0")/lib.sh"

echo "# test_dry_run"

KEY="AIS-START-TECH-TEST0001"        # выдуманный ключ: 2 агента → быстрый прогон
FAKE_API="fake-api-key-NOPATTERN-777"
FAKE_TG1="111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001"
FAKE_TG2="222222222:FAKEtokenFAKEtokenFAKEtokenFAKE0002"

prepare_home() {
  printf '# user bashrc\n' > "$SB_HOME/.bashrc"
  printf '# user profile\n' > "$SB_HOME/.profile"
  printf '# user zshrc\n' > "$SB_HOME/.zshrc"
}

# dry_run <лог> [команда-обёртка...] — запуск install.sh в чистом окружении песочницы
dry_run() {
  local log="$1" to=""; shift
  # timeout есть не везде (на macOS его нет) — без него просто без лимита
  [ -e "$SANDBOX/sys/timeout" ] && to="timeout 120"
  env -i HOME="$SB_HOME" PATH="$(sb_path)" TMPDIR="$SB_TMP" TERM=dumb LANG=C.UTF-8 \
    AISTACK_DRY_RUN=1 AISTACK_NONINTERACTIVE=1 AISTACK_LOG="$log" AISTACK_HB="$SB_TMP/hb" \
    AISTACK_API_KEY="$FAKE_API" AISTACK_TG_TOKENS="$FAKE_TG1 $FAKE_TG2" \
    $to "$@"
}

# ran_ok <rc> <лог> — dry-run действительно отработал: иначе остальные проверки
# «проходят» впустую (нечего проверять) и их результат ничего не значит
ran_ok() { [ "$1" -eq 0 ] && grep -q '^\[dry-run\] ' "$2" 2>/dev/null; }
not_ran() {
  fail "$1: dry-run не отработал (rc=$2): $(grep -m1 -E '❌|not found|illegal' "$SANDBOX/out.txt")"
  echo "         остальные проверки $1 пропущены — без прогона они ничего не доказывают"
}

# ── A) sudo нет в системе → dry-run всё равно проходит ─────────────────────────
new_sandbox; prepare_home
dry_run "$SB_TMP/a.log" bash "$REPO_DIR/install.sh" "$KEY" > "$SANDBOX/out.txt" 2>&1
rc=$?
if ran_ok "$rc" "$SB_TMP/a.log"; then pass "A: dry-run без sudo в системе завершился успешно"
else not_ran A "$rc"; fi
rm -rf "$SANDBOX"

# ── B) sudo есть: не вызывается; HOME не меняется; секретов в логе нет ────────
new_sandbox; prepare_home; add_sudo_stub
before="$(home_snapshot)"
dry_run "$SB_TMP/b.log" bash "$REPO_DIR/install.sh" "$KEY" > "$SANDBOX/out.txt" 2>&1
rc=$?
after="$(home_snapshot)"
if ! ran_ok "$rc" "$SB_TMP/b.log"; then not_ran B "$rc"
else
  pass "B: dry-run завершился успешно"
  if [ "$before" = "$after" ]; then pass "B: HOME не изменён"
  else fail "B: HOME изменён:"; diff <(echo "$before") <(echo "$after") | sed 's/^/         /'; fi
  forbidden="$(grep -E '^(sudo|curl|wget|npm|apt-get|apt|add-apt-repository|brew|open|xdg-open) ' "$SB_CALLS")"
  oc="$(grep -E '^openclaw ' "$SB_CALLS")"
  [ -z "$oc" ] && pass "B: OpenClaw не запускался (даже --version)" || fail "B: dry-run запускал OpenClaw: $oc"
  if [ -z "$forbidden" ]; then pass "B: sudo/сеть/пакетные менеджеры не вызывались"
  else fail "B: запрещённые вызовы:"; echo "$forbidden" | sed 's/^/         /'; fi
  leaked=""
  for s in "$FAKE_API" "$FAKE_TG1" "$FAKE_TG2"; do
    grep -qF "$s" "$SB_TMP/b.log" 2>/dev/null && leaked="$leaked $s"
    grep -qF "$s" "$SANDBOX/out.txt" && leaked="$leaked (stdout)$s"
  done
  if [ -z "$leaked" ]; then pass "B: секретов нет ни в логе, ни в выводе"
  else fail "B: утекли секреты:$leaked"; fi
  if [ "$(file_mode "$SB_TMP/b.log")" = "600" ]; then pass "B: лог с правами 600"
  else fail "B: права лога $(file_mode "$SB_TMP/b.log"), ожидалось 600"; fi
fi
rm -rf "$SANDBOX"

# ── C) с терминалом и ответом «y» браузер в dry-run не открывается ────────────
# script(1): util-linux (Linux) и BSD (macOS) принимают разные аргументы
new_sandbox; prepare_home; add_sudo_stub
if script --version 2>/dev/null | grep -q util-linux; then
  pty=(script -qec "bash '$REPO_DIR/install.sh' '$KEY'" /dev/null)
else
  pty=(script -q /dev/null bash "$REPO_DIR/install.sh" "$KEY")
fi
printf 'y\n' | dry_run "$SB_TMP/c.log" "${pty[@]}" > "$SANDBOX/out.txt" 2>&1
rc=$?
if ! ran_ok "$rc" "$SB_TMP/c.log"; then not_ran C "$rc"
else
  pass "C: dry-run в терминале завершился успешно"
  if grep -qE '^(open|xdg-open) ' "$SB_CALLS"; then
    fail "C: dry-run попытался открыть браузер: $(grep -E '^(open|xdg-open) ' "$SB_CALLS")"
  else pass "C: браузер не открывался"; fi
fi


# ── D) dry-run по macOS-пути: Python не запускается, HOME не меняется ────────
# На macOS _deps_macos не выставляет PYTHON_BIN, и шаг Hermes раньше вызывал
# resolve_python — реальный запуск python3 -c. Системный python3 от Apple пишет
# кэш байткода в ~/Library/Caches/com.apple.python (найдено на Mac-приёмке).
# Эмуляция на любой ОС: uname → Darwin; python3* — заглушки, которые, как Apple
# python, пишут кэш в $HOME и отмечают запуск в calls.log.
rm -rf "$SANDBOX"; new_sandbox; prepare_home; add_sudo_stub
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; *) exec "%s" "$@";; esac\n' \
  "$(readlink "$SANDBOX/sys/uname")" > "$SB_BIN/uname"; chmod +x "$SB_BIN/uname"
for n in python3 python3.11 python3.12 python3.13; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nmkdir -p "$HOME/Library/Caches/com.apple.python" && : > "$HOME/Library/Caches/com.apple.python/probe.pyc"\nexit 0\n' \
    "$n" "$SB_CALLS" > "$SB_BIN/$n"; chmod +x "$SB_BIN/$n"
done
before="$(home_snapshot)"
dry_run "$SB_TMP/d.log" bash "$REPO_DIR/install.sh" "$KEY" > "$SANDBOX/out.txt" 2>&1
rc=$?
after="$(home_snapshot)"
if ! ran_ok "$rc" "$SB_TMP/d.log"; then not_ran D "$rc"
else
  grep -q 'ОС: macos' "$SANDBOX/out.txt" && pass "D: dry-run прошёл по macOS-пути (эмуляция uname=Darwin)" || fail "D: не macOS-путь"
  py="$(grep -E '^python3' "$SB_CALLS")"
  [ -z "$py" ] && pass "D: в dry-run Python не запускался" || fail "D: в dry-run запускался Python: $(echo "$py" | head -2 | tr '\n' ';')"
  if [ "$before" = "$after" ]; then pass "D: HOME не изменён (нет кэша Python)"
  else fail "D: HOME изменён:"; diff <(echo "$before") <(echo "$after") | sed 's/^/         /'; fi
fi

finish

#!/usr/bin/env bash
# Dry-run из README (AISTACK_DRY_RUN=1) не должен: менять HOME, вызывать sudo
# и сетевые/пакетные команды, требовать sudo, открывать браузер, писать секреты в лог.
set -u
. "$(dirname "$0")/lib.sh"

echo "# test_dry_run"

KEY="AIS-START-TECH-TEST0001"        # выдуманный ключ: 2 агента → быстрый прогон
FAKE_API="fake-api-key-NOPATTERN-777"
FAKE_TG1="111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001"
FAKE_TG2="fake-tg-token-two"

prepare_home() {
  printf '# user bashrc\n' > "$SB_HOME/.bashrc"
  printf '# user profile\n' > "$SB_HOME/.profile"
  printf '# user zshrc\n' > "$SB_HOME/.zshrc"
}

# dry_run <лог> [команда-обёртка...] — запуск install.sh в чистом окружении песочницы
dry_run() {
  local log="$1"; shift
  env -i HOME="$SB_HOME" PATH="$(sb_path)" TMPDIR="$SB_TMP" TERM=dumb LANG=C.UTF-8 \
    AISTACK_DRY_RUN=1 AISTACK_NONINTERACTIVE=1 AISTACK_LOG="$log" AISTACK_HB="$SB_TMP/hb" \
    AISTACK_API_KEY="$FAKE_API" AISTACK_TG_TOKENS="$FAKE_TG1 $FAKE_TG2" \
    timeout 120 "$@"
}

# ── A) sudo нет в системе → dry-run всё равно проходит ─────────────────────────
new_sandbox; prepare_home
dry_run "$SB_TMP/a.log" bash "$REPO_DIR/install.sh" "$KEY" > "$SANDBOX/out.txt" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then pass "A: dry-run без sudo в системе завершился успешно"
else fail "A: dry-run без sudo упал (rc=$rc): $(grep -m1 '❌' "$SANDBOX/out.txt")"; fi
rm -rf "$SANDBOX"

# ── B) sudo есть: не вызывается; HOME не меняется; секретов в логе нет ────────
new_sandbox; prepare_home; add_sudo_stub
before="$(home_snapshot)"
dry_run "$SB_TMP/b.log" bash "$REPO_DIR/install.sh" "$KEY" > "$SANDBOX/out.txt" 2>&1
rc=$?
after="$(home_snapshot)"
if [ "$rc" -eq 0 ]; then pass "B: dry-run завершился успешно"
else fail "B: dry-run упал (rc=$rc): $(grep -m1 '❌' "$SANDBOX/out.txt")"; fi
if [ "$before" = "$after" ]; then pass "B: HOME не изменён"
else fail "B: HOME изменён:"; diff <(echo "$before") <(echo "$after") | sed 's/^/         /'; fi
forbidden="$(grep -E '^(sudo|curl|wget|npm|apt-get|apt|add-apt-repository|brew|open|xdg-open) ' "$SB_CALLS")"
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
rm -rf "$SANDBOX"

# ── C) с терминалом и ответом «y» браузер в dry-run не открывается ────────────
new_sandbox; prepare_home; add_sudo_stub
printf 'y\n' | dry_run "$SB_TMP/c.log" script -qec "bash '$REPO_DIR/install.sh' '$KEY'" /dev/null \
  > "$SANDBOX/out.txt" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then pass "C: dry-run в терминале завершился успешно"
else fail "C: dry-run в терминале упал (rc=$rc)"; fi
if grep -qE '^(open|xdg-open) ' "$SB_CALLS"; then
  fail "C: dry-run попытался открыть браузер: $(grep -E '^(open|xdg-open) ' "$SB_CALLS")"
else pass "C: браузер не открывался"; fi

finish

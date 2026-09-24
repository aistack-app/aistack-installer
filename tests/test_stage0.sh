#!/usr/bin/env bash
# Этап 0: отказ без реальных ключей (fail-closed), маскировка вывода команд в
# реальном режиме, порог Node. Все ключи/токены — выдуманные.
set -u
. "$(dirname "$0")/lib.sh"

echo "# test_stage0"
new_sandbox
export AISTACK_HB="$SB_TMP/hb" AISTACK_LOG="$SB_TMP/stage0.log"

GOOD_KEY="fake-api-key-NOPATTERN-777"
GOOD_TG1="111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001"
GOOD_TG2="222222222:FAKEtokenFAKEtokenFAKEtokenFAKE0002"

# wiz <ожидаемый rc> <описание> [VAR=val ...] — run_wizard без TTY (2 агента)
wiz() {
  local want="$1" what="$2"; shift 2
  env -u AISTACK_API_KEY -u AISTACK_TG_TOKENS -u AISTACK_DRY_RUN HOME="$SB_HOME" "$@" \
    bash -c '
      . "$0/lib/helpers.sh"; . "$0/lib/wizard.sh"
      RAW_KEY="${RAW_KEY:-AIS-START-TECH-TEST0001}"; AGENTS="coordinator tech"; AGENT_COUNT=2; PRESET_ID=tech-team
      run_wizard >/dev/null 2>&1; rc=$?
      [ "$rc" -eq 0 ] && printf "%s" "$API_KEY" > "$1"
      exit "$rc"' "$REPO_DIR" "$SB_TMP/apikey" </dev/null
  local rc=$?
  if [ "$rc" = "$want" ]; then pass "$what (rc=$rc)"; else fail "$what: rc=$rc, ожидался $want"; fi
}

rm -f "$SB_TMP/apikey"
wiz 1 "без ключей, не dry-run → отказ"
wiz 1 "DEV-ключ без dry-run → отказ (больше не включает заглушки)" RAW_KEY=AIS-TEAM-FULL-DEV1234
wiz 1 "ключ-заглушка → отказ" AISTACK_API_KEY=sk-ant-DEV-PLACEHOLDER AISTACK_TG_TOKENS="$GOOD_TG1 $GOOD_TG2"
wiz 1 "ключ-пример → отказ" AISTACK_API_KEY=example-openai-key-not-real AISTACK_TG_TOKENS="$GOOD_TG1 $GOOD_TG2"
wiz 1 "слишком короткий ключ → отказ" AISTACK_API_KEY=abc123 AISTACK_TG_TOKENS="$GOOD_TG1 $GOOD_TG2"
wiz 1 "токенов меньше, чем агентов → отказ" AISTACK_API_KEY="$GOOD_KEY" AISTACK_TG_TOKENS="$GOOD_TG1"
wiz 1 "токен-заглушка → отказ" AISTACK_API_KEY="$GOOD_KEY" AISTACK_TG_TOKENS="$GOOD_TG1 000000:DEV-PLACEHOLDER-1"
wiz 1 "токен не в формате BotFather → отказ" AISTACK_API_KEY="$GOOD_KEY" AISTACK_TG_TOKENS="$GOOD_TG1 not-a-token"
[ -e "$SB_TMP/apikey" ] && fail "при отказе ключ был принят" || pass "ни в одном отказе ключ не принят"
wiz 0 "формально корректные ключ и токены → принято" AISTACK_API_KEY="$GOOD_KEY" AISTACK_TG_TOKENS="$GOOD_TG1 $GOOD_TG2"
wiz 0 "dry-run без ключей → заглушки допустимы" AISTACK_DRY_RUN=1
if grep -q PLACEHOLDER "$SB_TMP/apikey" 2>/dev/null; then pass "dry-run: подставлена явная заглушка"
else fail "dry-run: заглушка не подставлена"; fi
wiz 1 "dry-run с явно переданным плохим токеном → отказ" AISTACK_DRY_RUN=1 AISTACK_API_KEY="$GOOD_KEY" AISTACK_TG_TOKENS="$GOOD_TG1 bad"

# ── Без ключей реальная установка останавливается ДО любых установок ─────────
add_sudo_stub
: > "$SB_CALLS"
to=""; [ -e "$SANDBOX/sys/timeout" ] && to="timeout 120"
env -i HOME="$SB_HOME" PATH="$(sb_path)" TMPDIR="$SB_TMP" TERM=dumb LANG=C.UTF-8 \
  AISTACK_NONINTERACTIVE=1 AISTACK_LOG="$SB_TMP/real-install.log" AISTACK_HB="$SB_TMP/hb2" \
  $to bash "$REPO_DIR/install.sh" AIS-START-COACH-TEST0001 > "$SB_TMP/real-install.out" 2>&1 </dev/null
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'AISTACK_API_KEY: ключ пуст' "$SB_TMP/real-install.out"; then
  pass "install.sh без ключей → отказ на старте"
else fail "install.sh без ключей: rc=$rc $(grep -m1 '❌' "$SB_TMP/real-install.out")"; fi
if [ -s "$SB_CALLS" ]; then fail "до отказа уже вызывались: $(head -3 "$SB_CALLS" | tr '\n' ';')"
else pass "до отказа не вызвано ни одной команды установки (sudo/apt/curl/npm/openclaw)"; fi
[ -z "$(ls -A "$SB_HOME")" ] && pass "до отказа HOME не тронут" || fail "до отказа в HOME появилось: $(ls -A "$SB_HOME")"

# ── Реальный режим run(): вывод команды маскируется, код возврата сохраняется ──
L="$SB_TMP/real.log"
env -u AISTACK_DRY_RUN AISTACK_LOG="$L" HOME="$SB_HOME" bash -c '
  set -euo pipefail
  . "$0/lib/helpers.sh"
  API_KEY="fake.key*with[regex]+chars(1)|x^y\$z"
  TG_TOKENS=("333333333:FAKEtokenFAKEtokenFAKEtokenFAKE0003")
  run sh -c '"'"'printf "cfg: %s\n" "$1"; printf "tok %s\n" "$2"; echo OPENAI_API_KEY=sk-FAKEFAKEFAKEFAKEFAKEFAKE; exit 3'"'"' _ "$API_KEY" "${TG_TOKENS[0]}" && rc=0 || rc=$?
  echo "rc=$rc"
  run true && echo "true_rc=0"
' "$REPO_DIR" > "$SB_TMP/real.out" 2>&1
if grep -q '^rc=3$' "$SB_TMP/real.out" && grep -q '^true_rc=0$' "$SB_TMP/real.out"; then
  pass "реальный режим: код возврата команды сохранён (3 и 0)"
else fail "реальный режим: коды возврата: $(tr '\n' ' ' < "$SB_TMP/real.out")"; fi
leaked=""
for s in 'fake.key*with[regex]+chars(1)|x^y$z' 333333333:FAKEtokenFAKEtokenFAKEtokenFAKE0003 sk-FAKEFAKEFAKEFAKEFAKEFAKE; do
  grep -qF "$s" "$L" && leaked="$leaked $s"
done
if [ -z "$leaked" ]; then pass "реальный режим: секреты в выводе команды замаскированы"
else fail "реальный режим: в лог попали:$leaked"; fi
if grep -q '^cfg: \[REDACTED\]$' "$L"; then pass "реальный режим: строки лога сохранены, заменён только секрет"
else fail "реальный режим: содержимое лога искажено: $(head -3 "$L" | tr '\n' '|')"; fi

# ── Порог Node: engines openclaw@2026.6.5 = >=22.19.0 ─────────────────────────
for v in 20.18.0:1 22.18.1:1 22.19.0:0 24.1.0:0; do
  ver="${v%%:*}"; want="${v##*:}"
  printf '#!/bin/sh\n[ "$1" = "-e" ] && exec %s -e "Object.defineProperty(process.versions,\\"node\\",{value:\\"%s\\"});$2"\n' \
    "$(command -v node)" "$ver" > "$SB_BIN/node"; chmod +x "$SB_BIN/node"
  PATH="$SB_BIN:$PATH" bash -c '. "$0/lib/helpers.sh"; . "$0/lib/apt-deps.sh"; _node_ok' "$REPO_DIR" 2>/dev/null
  rc=$?; [ "$rc" -ne 0 ] && rc=1
  if [ "$rc" = "$want" ]; then pass "Node $ver → $([ "$want" = 0 ] && echo подходит || echo не подходит)"
  else fail "Node $ver: _node_ok=$rc, ожидалось $want"; fi
done

finish

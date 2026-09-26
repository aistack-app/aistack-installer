#!/usr/bin/env bash
# Итог установки: «AIStack установлен» — ТОЛЬКО если подтверждены все три роли
# (канал Telegram, агент, привязка), конфиг валиден и gateway ответил на
# RPC-пробу. Любой отказ → ненулевой код, «не завершена», без маркера успеха.
# Существующий агент (agents add → «already exists») принимается только после
# чтения конфига (read-back), а не по коду ошибки. Реальный режим на заглушках.
set -u
. "$(dirname "$0")/lib.sh"

echo "# test_final_verdict (install.sh: итог только после подтверждения)"
KEY="sk-proj-FAKEe2eFAKEe2eFAKEe2eFAKE01"
TOKS="111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001 222222222:FAKEtokenFAKEtokenFAKEtokenFAKE0002 333333333:FAKEtokenFAKEtokenFAKEtokenFAKE0003"

# e2e <метка> [VAR=val…] → RC, MARKS (строк «AIStack установлен»), OUT (файл вывода)
e2e() {
  local label="$1"; shift
  rm -rf "${SANDBOX:-/nonexistent}"; new_sandbox; add_e2e_stubs
  [ -n "${PRESEED:-}" ] && for a in $PRESEED; do echo "$a $SB_HOME/.openclaw/workspace-$a" >> "$SB_CALLS.state.agents"; done
  local to=""; [ -e "$SANDBOX/sys/timeout" ] && to="timeout 180"
  OUT="$SANDBOX/out-$label.txt"
  env -i HOME="$SB_HOME" PATH="$(sb_path)" TMPDIR="$SB_TMP" TERM=dumb LANG=C.UTF-8 \
    AISTACK_NONINTERACTIVE=1 AISTACK_API_KEY="$KEY" AISTACK_TG_TOKENS="$TOKS" AISTACK_OWNER_TG_ID=123456789 \
    AISTACK_LOG="$SB_TMP/install.log" E2E_CALLS="$SB_CALLS" E2E_REPO="$REPO_DIR" "$@" \
    $to bash "$REPO_DIR/install.sh" AIS-START-COACH-TEST0001 > "$OUT" 2>&1 </dev/null
  RC=$?
  MARKS="$(grep -c 'AIStack установлен' "$OUT")"
}
expect_fail() {  # expect_fail <описание> <что должно быть названо в выводе>
  if [ "$RC" -ne 0 ] && [ "$MARKS" = 0 ] && grep -q 'НЕ завершена' "$OUT" && grep -q "$2" "$OUT"; then
    pass "$1 → exit $RC, маркера успеха нет, причина названа"
  else
    fail "$1: exit=$RC, «AIStack установлен»×$MARKS, $(grep -m1 -E 'НЕ завершена|AIStack установлен' "$OUT")"
  fi
}

PRESEED="" e2e agents_fail E2E_FAIL_AGENTS_ADD=1
expect_fail "agents add падает (код 9) для всех трёх ролей" 'Агент coordinator'

PRESEED="" e2e channel_fail E2E_FAIL_CHANNEL=designer
expect_fail "channels add отклонён для роли designer" 'Telegram-аккаунт designer'

PRESEED="" e2e gateway_down E2E_GATEWAY_DOWN=1
expect_fail "gateway не отвечает на RPC-пробу" 'Gateway'

PRESEED="" e2e allowlist_down E2E_FAIL_ALLOWLIST=designer
expect_fail "allowlist дизайнера не записался" 'доступ владельца к боту designer'

PRESEED="" e2e owner_commands_down E2E_FAIL_OWNER_COMMANDS=1
expect_fail "владелец команд не записался" 'Владелец команд'

# Повторная установка: агенты уже есть (agents add → «already exists», код 9),
# чтение конфига подтверждает агента, каталог и привязку → успех законен
PRESEED="coordinator designer copywriter" e2e preexisting
if [ "$RC" -eq 0 ] && [ "$MARKS" = 1 ] && grep -q 'уже существует' "$OUT" && ! grep -q 'НЕ завершена' "$OUT"; then
  pass "агенты уже существовали → подтверждены чтением конфига → exit 0, успех"
else fail "повторная установка: exit=$RC, маркер×$MARKS, $(grep -m1 -E 'НЕ завершена|уже существует|❌' "$OUT")"; fi
grep -q '^openclaw config get agents.list --json$' "$SB_CALLS" && grep -q '^openclaw config get bindings --json$' "$SB_CALLS" \
  && grep -q '^openclaw config get channels.telegram.accounts --json$' "$SB_CALLS" \
  && pass "итог опирается на чтение конфига (agents.list, bindings, telegram.accounts)" || fail "чтение конфига не выполнялось"

# Существующий агент с ЧУЖИМ рабочим каталогом — это не «наш» агент
rm -rf "$SANDBOX"; new_sandbox; add_e2e_stubs
echo "coordinator /somewhere/else/workspace-old" >> "$SB_CALLS.state.agents"
to=""; [ -e "$SANDBOX/sys/timeout" ] && to="timeout 180"
env -i HOME="$SB_HOME" PATH="$(sb_path)" TMPDIR="$SB_TMP" TERM=dumb LANG=C.UTF-8 \
  AISTACK_NONINTERACTIVE=1 AISTACK_API_KEY="$KEY" AISTACK_TG_TOKENS="$TOKS" AISTACK_OWNER_TG_ID=123456789 \
  AISTACK_LOG="$SB_TMP/install.log" E2E_CALLS="$SB_CALLS" E2E_REPO="$REPO_DIR" \
  $to bash "$REPO_DIR/install.sh" AIS-START-COACH-TEST0001 > "$SANDBOX/out-foreign.txt" 2>&1 </dev/null
RC=$?; OUT="$SANDBOX/out-foreign.txt"; MARKS="$(grep -c 'AIStack установлен' "$OUT")"
expect_fail "агент coordinator уже есть, но с другим рабочим каталогом" 'Агент coordinator'

PRESEED="" e2e happy
[ "$RC" -eq 0 ] && [ "$MARKS" = 1 ] && pass "штатный первый запуск → exit 0, «AIStack установлен» ровно 1 раз" \
  || fail "штатный запуск: exit=$RC, маркер×$MARKS"
# финал не выдаёт непроверенное за проверенное (граница: конфиг+gateway ≠ «команда отвечает»)
FIN="$SANDBOX/final-block.txt"; sed -n '/AIStack установлен/,$p' "$OUT" > "$FIN"   # только итоговый блок
if grep -q 'НЕ проверено установщиком' "$FIN" && grep -q 'ответ модели' "$FIN" && grep -q 'каждому из 3 ботов' "$FIN" \
   && ! grep -qE '✓ (Модель|Hermes)' "$FIN"; then
  pass "финал разделяет «проверено» и «НЕ проверено»: модель/авторизация и ответы 3 ботов — не проверены"
else fail "финал переоценивает проверку: $(grep -E '✓ (Модель|Hermes)|НЕ проверено' "$FIN" | head -3 | tr '\n' '|')"; fi

# dry-run ничего не устанавливает → и не объявляет установку
rm -rf "$SANDBOX"; new_sandbox; add_sudo_stub
env -i HOME="$SB_HOME" PATH="$(sb_path)" TMPDIR="$SB_TMP" TERM=dumb LANG=C.UTF-8 AISTACK_DRY_RUN=1 \
  AISTACK_LOG="$SB_TMP/dry.log" bash "$REPO_DIR/install.sh" AIS-START-COACH-TEST0001 > "$SANDBOX/out-dry.txt" 2>&1 </dev/null
RC=$?
if [ "$RC" -eq 0 ] && ! grep -q 'AIStack установлен' "$SANDBOX/out-dry.txt" && grep -q 'ничего не установлено' "$SANDBOX/out-dry.txt"; then
  pass "dry-run → exit 0 без «AIStack установлен» (честно: ничего не установлено)"
else fail "dry-run: exit=$RC, $(grep -m1 -E 'AIStack установлен|ничего не установлено' "$SANDBOX/out-dry.txt")"; fi

finish

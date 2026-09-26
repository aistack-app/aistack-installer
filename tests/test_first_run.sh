#!/usr/bin/env bash
# Сквозной ПЕРВЫЙ ЗАПУСК install.sh (реальный режим, не dry-run) для сборки
# COACH с тремя выдуманными ботами. Все внешние команды — заглушки (см.
# add_e2e_stubs): ничего не устанавливается, в сеть ничего не уходит.
# Проверяется: порядок и связки команд OpenClaw, доставка ключа и токенов
# не через аргументы процессов, права файлов с секретами, отсутствие записи
# вне временного HOME/TMPDIR, выбранная модель, отсутствие секретов в логах.
set -u
. "$(dirname "$0")/lib.sh"

echo "# test_first_run (install.sh, COACH, 3 бота, реальный режим на заглушках)"
tmp_before="$(ls -A "$TEST_TMP_BASE" | grep -v '^aistack-test\.' | sort)"
new_sandbox; add_e2e_stubs
printf '# user bashrc\n' > "$SB_HOME/.bashrc"

KEY="sk-proj-FAKEe2eFAKEe2eFAKEe2eFAKE01"
T1="111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001"
T2="222222222:FAKEtokenFAKEtokenFAKEtokenFAKE0002"
T3="333333333:FAKEtokenFAKEtokenFAKEtokenFAKE0003"
to=""; [ -e "$SANDBOX/sys/timeout" ] && to="timeout 180"
# AISTACK_HB не передаём: проверяем путь heartbeat по умолчанию
env -i HOME="$SB_HOME" PATH="$(sb_path)" TMPDIR="$SB_TMP" TERM=dumb LANG=C.UTF-8 \
  AISTACK_NONINTERACTIVE=1 AISTACK_API_KEY="$KEY" AISTACK_TG_TOKENS="$T1 $T2 $T3" \
  AISTACK_OWNER_TG_ID=123456789 AISTACK_BUSINESS="Нина Лебедева · сон" AISTACK_LOG="$SB_TMP/install.log" \
  E2E_CALLS="$SB_CALLS" E2E_REPO="$REPO_DIR" \
  $to bash "$REPO_DIR/install.sh" AIS-START-COACH-TEST0001 > "$SANDBOX/out.txt" 2>&1 </dev/null
rc=$?
tmp_after="$(ls -A "$TEST_TMP_BASE" | grep -v '^aistack-test\.' | sort)"

if [ "$rc" -eq 0 ] && grep -q 'AIStack установлен' "$SANDBOX/out.txt"; then pass "первый запуск завершился (rc=0)"
else fail "первый запуск упал (rc=$rc): $(grep -m2 -E '❌|✗' "$SANDBOX/out.txt" | tr '\n' ' ')"; fi

# ── 3 бота: канал → агент с правильной привязкой и рабочим каталогом ────────
seq_ok=1; i=0
for a in coordinator designer copywriter; do
  i=$((i+1))
  grep -qE "^openclaw channels add --channel telegram --account $a( |$)" "$SB_CALLS" || { seq_ok=0; echo "         нет channels add для $a"; }
  grep -qxF "openclaw agents add $a --non-interactive --workspace $SB_HOME/.openclaw/workspace-$a --bind telegram:$a" "$SB_CALLS" \
    || { seq_ok=0; echo "         нет agents add для $a"; }
done
order="$(grep -oE '^openclaw (channels add --channel telegram --account|agents add) [a-z]+' "$SB_CALLS" | awk '{print $NF}' | tr '\n' ' ')"
[ "$order" = "coordinator coordinator designer designer copywriter copywriter " ] || { seq_ok=0; echo "         порядок: $order"; }
[ "$seq_ok" = 1 ] && pass "3 бота: для каждой роли канал Telegram, затем агент с привязкой telegram:<роль>" || fail "регистрация ботов"
access_ok=1
for a in coordinator designer copywriter; do
  grep -qxF "openclaw config set channels.telegram.accounts.$a.dmPolicy allowlist" "$SB_CALLS" || access_ok=0
  grep -qF "openclaw config set channels.telegram.accounts.$a.allowFrom " "$SB_CALLS" || access_ok=0
  grep -qxF "openclaw config get channels.telegram.accounts.$a --json" "$SB_CALLS" || access_ok=0
done
grep -qF 'openclaw config set commands.ownerAllowFrom ' "$SB_CALLS" || access_ok=0
grep -qxF 'openclaw config get commands.ownerAllowFrom --json' "$SB_CALLS" || access_ok=0
[ "$access_ok" = 1 ] && pass "доступ владельца записан и прочитан обратно для трёх ботов и команд" || fail "нет записи или read-back allowlist"
grep -qx 'openclaw config validate' "$SB_CALLS" && grep -qx 'openclaw gateway install' "$SB_CALLS" && grep -qx 'openclaw gateway start' "$SB_CALLS" \
  && pass "конфиг валидируется, gateway ставится и запускается" || fail "нет validate/gateway install/start"
grep -qx 'openclaw config set agents.defaults.model.primary openai/gpt-5.5' "$SB_CALLS" \
  && pass "модель по умолчанию — выбранная (openai/gpt-5.5)" || fail "модель не выставлена"
if [ ! -e "$SB_HOME/.hermes" ] && ! grep -q 'hermes-agent' "$SB_CALLS"; then
  pass "COACH ставит только нужный ботам OpenClaw, без отдельного Hermes runtime"
else
  fail "COACH тратит установку на Hermes, который не является памятью OpenClaw"
fi

# ── токены: из файлов 600, каждой роли — свой ────────────────────────────────
tok_ok=1; i=0
for a in coordinator designer copywriter; do
  i=$((i+1)); eval "t=\$T$i"
  want="$(printf '%s' "$t" | cksum | cut -d' ' -f1)"
  line="$(grep "^TOKEN $a " "$SB_CALLS.files" 2>/dev/null)"
  case "$line" in *"mode=600 dir=700 sum=$want") :;; *) tok_ok=0; echo "         $a: ${line:-токен не передан файлом}";; esac
done
[ "$tok_ok" = 1 ] && pass "токены переданы файлами (600, каталог 700), каждой роли — её токен" || fail "доставка токенов"

# ── ключ: через файл-патч 600, который потом удалён ──────────────────────────
if grep -q '^PATCH mode=600 dir=700' "$SB_CALLS.files" 2>/dev/null && grep -qF "OPENAI_API_KEY: \"$KEY\"" "$SB_CALLS.patches" 2>/dev/null; then
  pass "API-ключ передан через config patch --file (файл 600 в каталоге 700)"
else fail "API-ключ не через файл-патч: $(grep PATCH "$SB_CALLS.files" 2>/dev/null | head -2 | tr '\n' ' ')"; fi
left="$(grep -rlF "$KEY" "$SB_TMP" 2>/dev/null | grep -v "$SB_TMP/install.log")"
[ -z "$left" ] && pass "временный файл с ключом удалён" || fail "ключ остался во временных файлах: $left"

# ── секреты не видны в аргументах процессов и в логах ────────────────────────
leak=""
for s in "$KEY" "$T1" "$T2" "$T3"; do
  grep -qF "$s" "$SB_CALLS" && leak="$leak [argv openclaw/системных команд]"
  grep -qF "$s" "$SB_CALLS.argv" 2>/dev/null && leak="$leak [argv sed/grep/awk]"
  grep -qF "$s" "$SB_TMP/install.log" && leak="$leak [лог]"
  grep -qF "$s" "$SANDBOX/out.txt" && leak="$leak [вывод]"
done
[ -z "$leak" ] && pass "ключ и токены не попали ни в аргументы процессов, ни в лог, ни в вывод" || fail "утечка:$(echo "$leak" | tr ' ' '\n' | sort -u | tr '\n' ' ')"

# ── запись только в ожидаемые места ──────────────────────────────────────────
[ "$tmp_before" = "$tmp_after" ] && pass "вне временных каталогов песочницы в $TEST_TMP_BASE ничего не создано" \
  || fail "в $TEST_TMP_BASE появились: $(comm -13 <(echo "$tmp_before") <(echo "$tmp_after") | tr '\n' ' ')"
top="$(ls -A "$SB_HOME" | sort | tr '\n' ' ')"
[ "$top" = ".bashrc .openclaw AIStack-Vault " ] && pass "в HOME только нужные COACH-каталоги: $top" || fail "в HOME: $top"
[ ! -e "$SB_HOME/.hermes/.env" ] && pass "COACH не пишет лишнюю копию API-ключа в Hermes" || fail "неожиданный ~/.hermes/.env"
[ -f "$SB_HOME/AIStack-Vault/profile/expert.md" ] && grep -q 'Нина Лебедева · сон' "$SB_HOME/AIStack-Vault/profile/expert.md" \
  && pass "vault создан и персонализирован" || fail "vault не создан"

finish

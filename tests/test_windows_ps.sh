#!/usr/bin/env bash
# Офлайн-проверки Windows-установщика install.ps1 под pwsh.
# ВАЖНО: это PowerShell 7 на Linux/macOS, а НЕ Windows PowerShell 5.1 на Windows.
# Проверяется логика (паритет с bash, dry-run, развёртывание, fail-closed);
# Windows-специфика (iwr, Scheduled Task, winget/Node, кодировки консоли)
# здесь НЕ проверяется — для неё нужен Windows-раннер.
set -u
. "$(dirname "$0")/lib.sh"

echo "# test_windows_ps (pwsh $(pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo 'нет'))"
if ! command -v pwsh >/dev/null 2>&1; then
  echo "  SKIP - pwsh не найден: проверки Windows-установщика НЕ выполнены"
  exit 0
fi
new_sandbox
PS1="$REPO_DIR/install.ps1"
export T_PS1="$PS1"   # путь для pwsh -Command (аргументы после -Command не попадают в $args)
psq() { pwsh -NoLogo -NoProfile -NonInteractive "$@"; }

# ── A) статические проверки ──────────────────────────────────────────────────
[ "$(head -c 3 "$PS1" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] \
  && pass "install.ps1 в UTF-8 с BOM (иначе PowerShell 5.1 искажает кириллицу)" || fail "install.ps1 без BOM"
out="$(psq -Command '
  $t=$null;$e=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($env:T_PS1,[ref]$t,[ref]$e)
  if ($e.Count) { "PARSE: " + ($e | % { "{0}: {1}" -f $_.Extent.StartLineNumber,$_.Message }) -join "; "; exit }
  $bad = $t | ? { "AndAnd","OrOr","QuestionQuestion","QuestionQuestionEquals","QuestionDot","QuestionLBracket","QuestionMark" -contains $_.Kind.ToString() }
  if ($bad) { "PS7: " + (($bad | % { "{0}:{1}" -f $_.Extent.StartLineNumber,$_.Text }) -join ", ") } else { "OK" }' 2>&1)"
[ "$out" = "OK" ] && pass "синтаксис разбирается; нет конструкций только PowerShell 7 (&&, ||, ??, ?., тернарный ?)" \
  || fail "синтаксис: $out"

# ── B) паритет с bash на одних и тех же входах ───────────────────────────────
IN="$SB_TMP/parity.tsv"
{
  for k in AIS-START-COACH-TEST0001 AIS-MINI-COACH-A7B3XK92 AIS-PROFI-COACH-TEST0001 AIS-TEAM-COACH-A7B3-XK92 \
           AIS-PERSONAL-COACH-TEST0001 AIS-TEAM-FULL-A7B3XK92 AIS-START-EXPERT-TEST0001 AIS-PROFI-EXPERT-TEST0001 \
           ais-start-coach-test0001 " AIS-START-COACH-TEST0001 " AIS-START-SMALLBIZ-ABCDEF AIS-MINI-ADMIN-ABCDEF \
           "" OPENCLAW-XXX AIS AIS-START AIS-START-COACH AIS-START-COACH- AIS-GOLD-COACH-TEST0001 \
           AIS-START-NOPE-TEST0001 AIS-START-COACH-SHORT AIS-START-COACH-TOOLONG1234567 AIS-START-COACH-BAD_CHARS \
           XYZ-START-COACH-TEST0001; do printf 'key\t%s\n' "$k"; done
  for k in "" sk-DEV-PLACEHOLDER example-openai-key-not-real "sk-proj-FAKE FAKEFAKEFAKEFAKE" abc123 \
           sk-proj-FAKEFAKEFAKEFAKEFAKE01 "<ваш ключ>" "sk-..." fake-api-key-NOPATTERN-777; do printf 'apikey\t%s\n' "$k"; done
  for t in "" 000000:DEV-PLACEHOLDER-1 not-a-token 111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001 \
           12345:short 111111111:FAKE-token_FAKEtokenFAKEtokenFAKE; do printf 'tg\t%s\n' "$t"; done
  for k in sk-ant-FAKE sk-or-FAKE AIzaFAKE sk-proj-FAKE proxy-FAKE ""; do printf 'prov\t%s\n' "$k"; done
  for p in openai anthropic openrouter gemini; do printf 'defmodel\t%s\nmodels\t%s\n' "$p" "$p"; done
  printf 'modelp\topenai\topenai/gpt-5.5\nmodelp\topenai\tanthropic/claude-sonnet-4-6\nmodelp\topenai\tgpt 5\n'
  printf 'modelp\topenai\t\nmodelp\tanthropic\tanthropic/claude-opus-4-8\nmodelp\topenai\tOpenAI/GPT\n'
  for v in "" relative "$SB_HOME" "$SB_HOME/" "$SB_HOME/.openclaw" "$SB_HOME/.openclaw/v" "$SB_HOME/.openclawx" \
           "$SB_HOME/AIStack-Vault" "/srv/Мой Vault"; do printf 'vaultp\t%s\n' "$v"; done
  for v in "~" "~/Заметки" "/abs/path" "rel"; do printf 'expand\t%s\n' "$v"; done
  printf 'mask\tcfg: fake.key*with[regex]+chars(1)|x^y$z ok\n'
  printf 'mask\ttok 333333333:FAKEtokenFAKEtokenFAKEtokenFAKE0003 и 444444444:FAKEtokenFAKEtokenFAKEtokenFAKE0004\n'
  printf 'mask\tOPENAI_API_KEY=sk-FAKEFAKEFAKEFAKEFAKEFAKE other=1\n'
  printf 'mask\tgemini AIzaFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE00 end\n'
} > "$IN"
export PARITY_API_KEY='fake.key*with[regex]+chars(1)|x^y$z' PARITY_TG="333333333:FAKEtokenFAKEtokenFAKEtokenFAKE0003"
HOME="$SB_HOME" bash "$REPO_DIR/tests/ps/call.sh" < "$IN" > "$SB_TMP/bash.out" 2>&1
HOME="$SB_HOME" USERPROFILE="$SB_HOME" psq -File "$REPO_DIR/tests/ps/call.ps1" < "$IN" > "$SB_TMP/ps.out" 2>&1
n="$(grep -c . "$IN")"
if cmp -s "$SB_TMP/bash.out" "$SB_TMP/ps.out"; then
  pass "паритет bash ↔ PowerShell: $n случаев (ключи доступа, API-ключи, токены, провайдер, модели, vault, маскировка)"
else
  fail "расхождения bash ↔ PowerShell:"
  paste -d'\n' "$IN" /dev/null | head -0
  diff <(nl -ba "$SB_TMP/bash.out") <(nl -ba "$SB_TMP/ps.out") | head -20 | sed 's/^/         /'
fi
unset PARITY_API_KEY PARITY_TG

# ── C) лог: уникальный временный файл; симлинк отклоняется ──────────────────
l1="$(psq -Command '$env:AISTACK_PS_LIBONLY="1"; . $env:T_PS1; Initialize-AisLog; $script:Log')"
l2="$(psq -Command '$env:AISTACK_PS_LIBONLY="1"; . $env:T_PS1; Initialize-AisLog; $script:Log')"
[ -f "$l1" ] && [ "$l1" != "$l2" ] && pass "лог по умолчанию — новый уникальный временный файл" || fail "лог: '$l1' / '$l2'"
rm -f "$l1" "$l2"
echo "важное" > "$SANDBOX/victim.txt"; ln -s "$SANDBOX/victim.txt" "$SB_TMP/planted.log"
AISTACK_LOG="$SB_TMP/planted.log" psq -Command '$env:AISTACK_PS_LIBONLY="1"; . $env:T_PS1; Initialize-AisLog' >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && [ "$(cat "$SANDBOX/victim.txt")" = "важное" ] && pass "AISTACK_LOG-симлинк отклонён, файл-жертва цел" \
  || fail "симлинк: rc=$rc, жертва='$(cat "$SANDBOX/victim.txt")'"

# ── D) fail-closed и ограничения ─────────────────────────────────────────────
runps() {  # runps <ключ> [VAR=val…] → rc; вывод в $SB_TMP/run.out
  local key="$1"; shift
  env -u AISTACK_DRY_RUN -u AISTACK_API_KEY -u AISTACK_TG_TOKENS HOME="$SANDBOX/pwsh-home" USERPROFILE="$SB_HOME" \
    PATH="$SB_BIN:$PATH" AISTACK_TEST_ALLOW_NONWINDOWS=1 AISTACK_NONINTERACTIVE=1 \
    AISTACK_LOG="$SB_TMP/ps-run.log" "$@" pwsh -NoLogo -NoProfile -NonInteractive -File "$PS1" "$key" > "$SB_TMP/run.out" 2>&1 </dev/null
}
printf '#!/bin/sh\necho "openclaw $*" >> "%s"\n[ "$1" = "--version" ] && exit 1\nexit 0\n' "$SB_CALLS" > "$SB_BIN/openclaw"
chmod +x "$SB_BIN/openclaw"
runps AIS-START-COACH-TEST0001 AISTACK_DRY_RUN=1 AISTACK_TEST_ALLOW_NONWINDOWS=0; rc=$?
[ "$rc" -ne 0 ] && grep -q 'для Windows' "$SB_TMP/run.out" && pass "без Windows (и без тест-флага) установщик отказывается" \
  || fail "не-Windows: rc=$rc"
runps AIS-TEAM-FULL-A7B3XK92 AISTACK_DRY_RUN=1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'только сборка COACH' "$SB_TMP/run.out" && pass "другие сборки на Windows честно отклоняются" \
  || fail "сборка FULL на Windows: rc=$rc $(grep -m1 '❌' "$SB_TMP/run.out")"
: > "$SB_CALLS"
runps AIS-START-COACH-TEST0001 AISTACK_TEMPLATES_DIR="$REPO_DIR/templates"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'AISTACK_API_KEY: ключ пуст' "$SB_TMP/run.out" && pass "реальная установка без ключей → отказ" \
  || fail "без ключей: rc=$rc $(grep -m1 '❌' "$SB_TMP/run.out")"
runps AIS-START-COACH-TEST0001 AISTACK_TEMPLATES_DIR="$REPO_DIR/templates" AISTACK_API_KEY=sk-DEV-PLACEHOLDER \
  AISTACK_TG_TOKENS="000000:DEV-PLACEHOLDER-0 000000:DEV-PLACEHOLDER-1 000000:DEV-PLACEHOLDER-2"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'заглушка' "$SB_TMP/run.out" && pass "реальная установка с заглушками → отказ" \
  || fail "заглушки: rc=$rc"
if [ -s "$SB_CALLS" ]; then
  fail "до отказа OpenClaw уже настраивался: $(grep -vE '^openclaw --version' "$SB_CALLS" | head -3)"
else pass "до отказа по ключам OpenClaw не ставился и не настраивался"; fi

# ── E) полный dry-run Windows-установщика (COACH) ───────────────────────────
rm -rf "$SANDBOX"; new_sandbox
printf '#!/bin/sh\necho "openclaw $*" >> "%s"\nexit 1\n' "$SB_CALLS" > "$SB_BIN/openclaw"; chmod +x "$SB_BIN/openclaw"
printf 'profile\n' > "$SB_HOME/Documents.txt"
before="$(home_snapshot)"
FK="fake-api-key-NOPATTERN-777"
FT="111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001 222222222:FAKEtokenFAKEtokenFAKEtokenFAKE0002 333333333:FAKEtokenFAKEtokenFAKEtokenFAKE0003"
runps AIS-START-COACH-TEST0001 AISTACK_DRY_RUN=1 AISTACK_API_KEY="$FK" AISTACK_TG_TOKENS="$FT" AISTACK_OWNER_TG_ID=123456789; rc=$?
after="$(home_snapshot)"
L="$SB_TMP/ps-run.log"
if [ "$rc" -eq 0 ] && grep -q '^\[dry-run\] ' "$L"; then
  pass "dry-run install.ps1 (COACH) прошёл"
  [ "$before" = "$after" ] && pass "dry-run: профиль пользователя не изменён (vault и каталоги не созданы)" || fail "dry-run изменил профиль"
  n="$(grep -c '^\[dry-run\] openclaw agents add ' "$L")"; [ "$n" = 3 ] && pass "dry-run: 3 агента" || fail "dry-run: agents add × $n"
  grep -q 'agents.defaults.model.primary openai/gpt-5.5' "$L" && pass "dry-run: модель openai/gpt-5.5" || fail "dry-run: модель не выставлена"
  grep -q 'install.ps1 -Tag 2026.6.5 -NoOnboard' "$L" && pass "dry-run: OpenClaw — официальный install.ps1 с пином 2026.6.5" || fail "dry-run: нет шага установки OpenClaw"
  leaked=""; for s in $FK $FT; do grep -qF "$s" "$L" "$SB_TMP/run.out" && leaked="$leaked $s"; done
  [ -z "$leaked" ] && pass "dry-run: секретов нет ни в логе, ни в выводе" || fail "dry-run: утекли$leaked"
  bad="$(grep -vE '^openclaw --version' "$SB_CALLS")"
  [ -z "$bad" ] && pass "dry-run: реальные команды не вызывались (кроме openclaw --version)" || fail "dry-run вызвал: $bad"
else fail "dry-run install.ps1 упал (rc=$rc): $(grep -m2 -E '❌|Exception|error' "$SB_TMP/run.out")"; fi

# ── F) развёртывание 3 ролей + vault: результат совпадает с bash-версией ─────
NAME='Нина & Co \ сон/отдых'
HB="$SANDBOX/hb"; HP="$SANDBOX/hp"; mkdir -p "$HB" "$HP"
env HOME="$HB" AISTACK_TEMPLATES_DIR="$REPO_DIR/templates" AISTACK_WORKSPACE_BASE="$HB/.openclaw" N="$NAME" bash -c '
  set -euo pipefail; . "$0/lib/helpers.sh"; . "$0/lib/wizard.sh"; . "$0/lib/workspace-deploy.sh"
  AISTACK_LOG="$HOME/l"; parse_key AIS-START-COACH-TEST0001
  BUSINESS_NAME="$N"; VAULT_PATH="$HOME/Мой Vault"; MODEL=openai/gpt-5.5; CHANNEL_ID=""
  deploy_templates; create_vault; personalize_workspaces' "$REPO_DIR" > "$SB_TMP/fb.out" 2>&1 || fail "bash-развёртывание упало"
env -u AISTACK_DRY_RUN HOME="$SANDBOX/pwsh-home" USERPROFILE="$HP" AISTACK_TEMPLATES_DIR="$REPO_DIR/templates" N="$NAME" \
  pwsh -NoLogo -NoProfile -NonInteractive -Command '
  $env:AISTACK_PS_LIBONLY="1"; . $env:T_PS1; $env:AISTACK_LOG = (Join-Path $env:USERPROFILE "l"); Initialize-AisLog
  $K = ConvertFrom-AisKey "AIS-START-COACH-TEST0001"
  $script:Business = $env:N; $script:VaultPath = (Join-Path $env:USERPROFILE "Мой Vault"); $script:Model = "openai/gpt-5.5"
  Install-AisWorkspaces $K; New-AisVault; Update-AisWorkspaces $K' > "$SB_TMP/fp.out" 2>&1 || fail "PowerShell-развёртывание упало: $(tail -2 "$SB_TMP/fp.out")"
norm() { ( cd "$1" && find .openclaw "Мой Vault" -type f | sort | while IFS= read -r f; do
           printf '== %s\n' "$f"; sed "s#$1#<HOME>#g" "$f"; done ); }
if [ "$(norm "$HB")" = "$(norm "$HP")" ] && [ -n "$(norm "$HP")" ]; then
  pass "PowerShell развернул те же файлы, что bash (3 роли, USER.md, vault; кириллица и & \\ / целы)"
else
  fail "развёртывание PowerShell ≠ bash:"; diff <(norm "$HB") <(norm "$HP") | head -15 | sed 's/^/         /'
fi

finish

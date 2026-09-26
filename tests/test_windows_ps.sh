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
# параметры/переменные, которых нет в Windows PowerShell 5.1 (парсер PS7 их не отличает)
ps6="$(grep -nE -- '-AsHashtable|-AdditionalChildPath|-AsByteStream|utf8NoBOM|-SkipCertificateCheck|-Parallel|\$IsWindows|\$IsLinux|\$IsMacOS|Get-Error|Test-Json|-NoProxy|-ResponseHeadersVariable|-StatusCodeVariable|ConvertFrom-Json[^|]*-Depth|Join-Path [^|]*-ChildPath [^|]*[^)] [^|-]' "$PS1")"
[ -z "$ps6" ] && pass "нет параметров/переменных, появившихся только в PowerShell 6+" || fail "PS6+: $ps6"
iwr="$(grep -n 'Invoke-WebRequest' "$PS1" | grep -v 'UseBasicParsing' | grep -v '^[0-9]*: *#')"
[ -z "$iwr" ] && pass "Invoke-WebRequest везде с -UseBasicParsing (в 5.1 иначе нужен движок IE)" || fail "iwr без -UseBasicParsing: $iwr"

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
  for p in openai anthropic openrouter google gemini; do printf 'defmodel\t%s\nmodels\t%s\n' "$p" "$p"; done
  printf 'modelp\tgoogle\tgoogle/gemini-3.1-pro-preview\nmodelp\tgoogle\tgemini/gemini-3.1-pro\n'
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
  bad="$(cat "$SB_CALLS")"
  [ -z "$bad" ] && pass "dry-run: ни одна внешняя команда не запускалась (включая openclaw --version)" || fail "dry-run вызвал: $bad"
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


# ── G) реальный (не dry-run) прогон install.ps1 на заглушках: 3 бота ─────────
rm -rf "$SANDBOX"; new_sandbox; add_e2e_stubs
tmp_before="$(ls -A "$TEST_TMP_BASE" | grep -v '^aistack-test\.' | sort)"
KEY="sk-proj-FAKEe2eFAKEe2eFAKEe2eFAKE01"
T1="111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001"; T2="222222222:FAKEtokenFAKEtokenFAKEtokenFAKE0002"
T3="333333333:FAKEtokenFAKEtokenFAKEtokenFAKE0003"
env -u AISTACK_DRY_RUN -u AISTACK_HB HOME="$SANDBOX/pwsh-home" USERPROFILE="$SB_HOME" PATH="$SB_BIN:$PATH" TMPDIR="$SB_TMP" \
  AISTACK_TEST_ALLOW_NONWINDOWS=1 AISTACK_NONINTERACTIVE=1 AISTACK_TEMPLATES_DIR="$REPO_DIR/templates" \
  AISTACK_API_KEY="$KEY" AISTACK_TG_TOKENS="$T1 $T2 $T3" AISTACK_OWNER_TG_ID=123456789 AISTACK_BUSINESS="Нина Лебедева" \
  AISTACK_LOG="$SB_TMP/ps-e2e.log" E2E_CALLS="$SB_CALLS" E2E_REPO="$REPO_DIR" \
  pwsh -NoLogo -NoProfile -NonInteractive -File "$PS1" AIS-START-COACH-TEST0001 > "$SB_TMP/ps-e2e.out" 2>&1 </dev/null
rc=$?
tmp_after="$(ls -A "$TEST_TMP_BASE" | grep -v '^aistack-test\.' | sort)"
if [ "$rc" -eq 0 ] && grep -q 'AIStack установлен' "$SB_TMP/ps-e2e.out"; then pass "реальный прогон install.ps1 на заглушках (rc=0)"
else fail "реальный прогон install.ps1 упал (rc=$rc): $(grep -m2 -E '❌|Exception' "$SB_TMP/ps-e2e.out" | tr '\n' ' ')"; fi
ok=1; i=0
for a in coordinator designer copywriter; do
  i=$((i+1)); eval "t=\$T$i"; want="$(printf '%s' "$t" | cksum | cut -d' ' -f1)"
  grep -qxF "openclaw agents add $a --non-interactive --workspace $SB_HOME/.openclaw/workspace-$a --bind telegram:$a" "$SB_CALLS" || { ok=0; echo "         нет agents add $a"; }
  case "$(grep "^TOKEN $a " "$SB_CALLS.files")" in *"mode=600 dir=700 sum=$want") :;; *) ok=0; echo "         токен $a не файлом/не тот";; esac
done
[ "$ok" = 1 ] && pass "3 бота: токены файлами (каждой роли — её), агенты с привязкой telegram:<роль>" || fail "регистрация ботов (PowerShell)"
grep -qF "OPENAI_API_KEY: \"$KEY\"" "$SB_CALLS.patches" && grep -q 'ownerAllowFrom: \["telegram:123456789"\]' "$SB_CALLS.patches" \
  && pass "ключ и список доступа владельца переданы файлами-патчами" || fail "патчи: $(head -c 300 "$SB_CALLS.patches" 2>/dev/null | sed "s/$KEY/<KEY>/")"
leak=""; for s in "$KEY" "$T1" "$T2" "$T3"; do
  grep -qF "$s" "$SB_CALLS" && leak="$leak argv"; grep -qF "$s" "$SB_TMP/ps-e2e.log" && leak="$leak лог"; grep -qF "$s" "$SB_TMP/ps-e2e.out" && leak="$leak вывод"
done
[ -z "$leak" ] && pass "секретов нет в аргументах процессов, логе и выводе" || fail "утечка:$leak"
q="$(grep '^openclaw ' "$SB_CALLS" | grep -F '"')"
[ -z "$q" ] && pass "в аргументах openclaw нет кавычек (legacy-передача аргументов PowerShell 5.1 не исказит)" || fail "кавычки в argv: $q"
[ -z "$(ls -A "$SB_TMP" | grep '^aistack-work-')" ] && pass "рабочий каталог с временными патчами удалён" || fail "остался: $(ls "$SB_TMP")"
[ "$tmp_before" = "$tmp_after" ] && pass "вне песочницы в $TEST_TMP_BASE ничего не создано" || fail "в $TEST_TMP_BASE появилось: $(comm -13 <(echo "$tmp_before") <(echo "$tmp_after") | tr '\n' ' ')"
top="$(ls -A "$SB_HOME" | sort | tr '\n' ' ')"
[ "$top" = ".openclaw AIStack-Vault " ] && pass "в профиле только ожидаемое: $top" || fail "в профиле: $top"


# ── H) итог install.ps1: успех только после подтверждения ────────────────────
# те же сценарии, что test_final_verdict для bash (заглушка openclaw с состоянием)
psv() {  # psv <метка> [VAR=val…] → RC, MARKS, OUT
  local label="$1"; shift
  rm -rf "$SANDBOX"; new_sandbox; add_e2e_stubs
  [ -n "${PRESEED:-}" ] && for a in $PRESEED; do echo "$a $SB_HOME/.openclaw/workspace-$a" >> "$SB_CALLS.state.agents"; done
  [ -n "${FOREIGN:-}" ] && echo "coordinator /somewhere/else/workspace-old" >> "$SB_CALLS.state.agents"
  OUT="$SANDBOX/ps-$label.out"
  env -u AISTACK_HB HOME="$SANDBOX/pwsh-home" USERPROFILE="$SB_HOME" PATH="$SB_BIN:$PATH" TMPDIR="$SB_TMP" \
    AISTACK_TEST_ALLOW_NONWINDOWS=1 AISTACK_NONINTERACTIVE=1 AISTACK_TEMPLATES_DIR="$REPO_DIR/templates" \
    AISTACK_API_KEY="sk-proj-FAKEe2eFAKEe2eFAKEe2eFAKE01" AISTACK_OWNER_TG_ID=123456789 \
    AISTACK_TG_TOKENS="111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001 222222222:FAKEtokenFAKEtokenFAKEtokenFAKE0002 333333333:FAKEtokenFAKEtokenFAKEtokenFAKE0003" \
    AISTACK_LOG="$SB_TMP/ps-v.log" E2E_CALLS="$SB_CALLS" E2E_REPO="$REPO_DIR" "$@" \
    pwsh -NoLogo -NoProfile -NonInteractive -File "$PS1" AIS-START-COACH-TEST0001 > "$OUT" 2>&1 </dev/null
  RC=$?; MARKS="$(grep -c 'AIStack установлен' "$OUT")"
}
psfail() {
  if [ "$RC" -ne 0 ] && [ "$MARKS" = 0 ] && grep -q 'НЕ завершена' "$OUT" && grep -q "$2" "$OUT"; then
    pass "PS: $1 → exit $RC, маркера успеха нет, причина названа"
  else fail "PS: $1: exit=$RC, маркер×$MARKS, $(grep -m1 -E 'НЕ завершена|AIStack установлен|Exception' "$OUT")"; fi
}
PRESEED="" FOREIGN="" psv agents_fail E2E_FAIL_AGENTS_ADD=1;       psfail "agents add падает для всех ролей" 'Агент coordinator'
PRESEED="" FOREIGN="" psv channel_fail E2E_FAIL_CHANNEL=designer;  psfail "channels add отклонён для designer" 'Telegram-аккаунт designer'
PRESEED="" FOREIGN="" psv gateway_down E2E_GATEWAY_DOWN=1;         psfail "gateway не отвечает на RPC-пробу" 'Gateway'
PRESEED="" FOREIGN="" psv allowlist_down E2E_FAIL_ALLOWLIST=designer; psfail "allowlist дизайнера не записался" 'доступ владельца к боту designer'
PRESEED="" FOREIGN="" psv owner_commands_down E2E_FAIL_OWNER_COMMANDS=1; psfail "владелец команд не записался" 'Владелец команд'
PRESEED="" FOREIGN="" psv missing_owner AISTACK_OWNER_TG_ID=; [ "$RC" -ne 0 ] && [ "$MARKS" = 0 ] && grep -q 'AISTACK_OWNER_TG_ID' "$OUT" && pass "PS: без ID владельца отказ до установки" || fail "PS: пустой ID принят"
PRESEED="" FOREIGN="" psv invalid_owner AISTACK_OWNER_TG_ID=not-an-id; [ "$RC" -ne 0 ] && [ "$MARKS" = 0 ] && grep -q 'AISTACK_OWNER_TG_ID' "$OUT" && pass "PS: неверный ID владельца отвергнут" || fail "PS: неверный ID принят"
PRESEED="" FOREIGN=1  psv foreign;                                 psfail "агент coordinator с чужим рабочим каталогом" 'Агент coordinator'
PRESEED="coordinator designer copywriter" FOREIGN="" psv preexisting
[ "$RC" -eq 0 ] && [ "$MARKS" = 1 ] && grep -q '^openclaw config get bindings --json$' "$SB_CALLS" \
  && pass "PS: агенты уже существовали → подтверждены чтением конфига → exit 0, успех" || fail "PS: повторная установка: exit=$RC, маркер×$MARKS"
FIN="$SANDBOX/ps-final-block.txt"; sed -n '/AIStack установлен/,$p' "$OUT" > "$FIN"
if grep -q 'НЕ проверено установщиком' "$FIN" && grep -q 'каждому из 3 ботов' "$FIN" && ! grep -q '✓ Модель' "$FIN" \
   && grep -q 'openclaw.cmd status' "$FIN"; then
  pass "PS: финал разделяет «проверено»/«НЕ проверено»; совет — openclaw.cmd (не .ps1-обёртка)"
else fail "PS: финал: $(grep -E '✓ Модель|НЕ проверено|openclaw(\.cmd)? status' "$FIN" | head -3 | tr '\n' '|')"; fi
PRESEED="" FOREIGN="" psv dry AISTACK_DRY_RUN=1
[ "$RC" -eq 0 ] && [ "$MARKS" = 0 ] && grep -q 'ничего не установлено' "$OUT" \
  && pass "PS: dry-run → exit 0 без «AIStack установлен»" || fail "PS: dry-run: exit=$RC, маркер×$MARKS"


# ── I) самопроверка для нативной Windows (tests/windows/selftest.ps1) ────────
# На Windows её запускают через powershell.exe 5.1; здесь (pwsh на Linux/macOS)
# проверяется только, что сам сценарий исправен и зелёный на текущем коде.
rm -rf "$SANDBOX"; new_sandbox
TMPDIR="$SB_TMP" pwsh -NoLogo -NoProfile -NonInteractive -File "$REPO_DIR/tests/windows/selftest.ps1" > "$SB_TMP/selftest.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'SELFTEST: ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ' "$SB_TMP/selftest.out" && ! grep -q 'FAIL' "$SB_TMP/selftest.out"; then
  pass "selftest.ps1 (сценарий для нативной Windows) исправен: $(grep -c '^  ok' "$SB_TMP/selftest.out") проверок зелёные"
else fail "selftest.ps1: rc=$rc $(grep -m2 -E 'FAIL|Exception' "$SB_TMP/selftest.out" | tr '\n' ' ')"; fi
[ "$(head -c 3 "$REPO_DIR/tests/windows/selftest.ps1" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] \
  && pass "selftest.ps1 в UTF-8 с BOM" || fail "selftest.ps1 без BOM"

finish

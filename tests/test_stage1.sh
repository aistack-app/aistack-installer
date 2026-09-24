#!/usr/bin/env bash
# Этап 1: сборка COACH (координатор-технарь, дизайнер, копирайтер), чистые
# шаблоны, USER.md, клиентский vault, выбор провайдера/модели. Вымышленный
# эксперт «Нина Лебедева, коуч по сну»; всё в изолированных HOME/vault.
set -u
. "$(dirname "$0")/lib.sh"

echo "# test_stage1"
new_sandbox
export AISTACK_HB="$SB_TMP/hb" AISTACK_LOG="$SB_TMP/stage1.log"
PRESET_DIR="$REPO_DIR/templates/_presets/coach-team"
ROLES="coordinator designer copywriter"

# ── 1) Ключи: COACH на любом тарифе, EXPERT не изменился ─────────────────────
pk() {  # pk <ключ> → "rc|PRESET_ID|AGENTS|AGENT_COUNT"
  bash -c '. "$0/lib/helpers.sh" 2>/dev/null; parse_key "$1"; rc=$?
           printf "%s|%s|%s|%s" "$rc" "$PRESET_ID" "$AGENTS" "$AGENT_COUNT"' "$REPO_DIR" "$1"
}
for t in MINI START PROFI TEAM PERSONAL; do
  got="$(pk "AIS-$t-COACH-TEST0001")"
  if [ "$got" = "0|coach-team|coordinator designer copywriter|3" ]; then pass "AIS-$t-COACH → coach-team, 3 роли"
  else fail "AIS-$t-COACH: $got"; fi
done
got="$(pk AIS-START-EXPERT-TEST0001)"
[ "$got" = "0|expert-team|coordinator copywriter negotiator|3" ] && pass "EXPERT не изменился" || fail "EXPERT изменился: $got"
got="$(pk AIS-PROFI-EXPERT-TEST0001)"
[ "${got%%|*}" = "1" ] && pass "PROFI-EXPERT по-прежнему недопустим" || fail "PROFI-EXPERT стал допустим: $got"

# ── 2) Чистота шаблонов сборки и vault (статически) ──────────────────────────
missing=""
for a in $ROLES; do for f in AGENTS.md SOUL.md IDENTITY.md TOOLS.md USER.md.template HEARTBEAT.md MEMORY.md; do
  [ -f "$PRESET_DIR/$a/$f" ] || missing="$missing $a/$f"
done; done
[ -z "$missing" ] && pass "у каждой роли полный набор файлов OpenClaw" || fail "нет файлов:$missing"
scan() { grep -rnE "$1" "$PRESET_DIR" "$REPO_DIR/templates/_vault" 2>/dev/null; }
hits="$(scan 'skills/')";  [ -z "$hits" ] && pass "нет ссылок на навыки (skills/), которых нет в комплекте" || fail "ссылки на навыки: $hits"
hits="$(scan '\[CORRECTION\]|\[CORRECT\]|владелец вынужден|rembg')"
[ -z "$hits" ] && pass "нет чужих уроков/инцидентов владельца" || fail "чужие уроки: $hits"
hits="$(scan 'Маркетолог|Продюсер|Переговорщик|Контентмейкер|agent:tech|к Технарю')"
[ -z "$hits" ] && pass "нет отсылок к ролям вне команды из 3" || fail "роли вне команды: $hits"
hits="$(scan '/Users/|/home/[a-z]|t\.me/|superwallets|[0-9]{8,12}:[A-Za-z0-9_-]{30,}|sk-[A-Za-z0-9_-]{10,}|AIza[0-9A-Za-z_-]{20,}')"
[ -z "$hits" ] && pass "нет личных путей, контактов, ключей и токенов" || fail "личные данные/секреты: $hits"
bad="$(grep -rhoE '\{\{[A-Z_]+\}\}' "$PRESET_DIR" "$REPO_DIR/templates/_vault" | sort -u | grep -vxE '\{\{(STUDIO_NAME|VAULT_PATH|MODEL)\}\}')"
[ -z "$bad" ] && pass "только известные плейсхолдеры (STUDIO_NAME/VAULT_PATH/MODEL)" || fail "неизвестные плейсхолдеры: $bad"

# ── 3) Развёртывание 3 ролей + USER.md + vault (реальное копирование в песочнице)
NAME='Нина & Co \ сон/отдых'
VAULT="$SB_HOME/Мой Vault"
deploy() {
  env HOME="$SB_HOME" AISTACK_TEMPLATES_DIR="$REPO_DIR/templates" AISTACK_WORKSPACE_BASE="$SB_HOME/.openclaw" \
    B_NAME="$NAME" B_VAULT="$VAULT" bash -c '
    set -euo pipefail
    . "$0/lib/helpers.sh"; . "$0/lib/wizard.sh"; . "$0/lib/workspace-deploy.sh"
    parse_key AIS-START-COACH-TEST0001
    BUSINESS_NAME="$B_NAME"; VAULT_PATH="$B_VAULT"; MODEL="openai/gpt-5.5"; CHANNEL_ID=""
    deploy_templates; create_vault; personalize_workspaces' "$REPO_DIR" > "$SB_TMP/deploy.out" 2>&1
}
deploy; rc=$?
[ "$rc" -eq 0 ] && pass "развёртывание сборки прошло" || fail "развёртывание упало (rc=$rc): $(tail -3 "$SB_TMP/deploy.out")"
ws_list="$(cd "$SB_HOME/.openclaw" 2>/dev/null && ls -d workspace-* | sort | tr '\n' ' ')"
[ "$ws_list" = "workspace-coordinator workspace-copywriter workspace-designer " ] \
  && pass "ровно 3 рабочих каталога: $ws_list" || fail "каталоги: '$ws_list'"
if cmp -s "$SB_HOME/.openclaw/workspace-coordinator/SOUL.md" "$REPO_DIR/templates/coordinator/SOUL.md"; then
  fail "координатор получил общий шаблон вместо версии сборки"
elif grep -q 'координатор-технарь' "$SB_HOME/.openclaw/workspace-coordinator/IDENTITY.md"; then
  pass "координатор — версия сборки (координатор-технарь)"
else fail "IDENTITY координатора не из сборки"; fi
nouser=""; for a in $ROLES; do [ -f "$SB_HOME/.openclaw/workspace-$a/USER.md" ] || nouser="$nouser $a"; done
[ -z "$nouser" ] && pass "USER.md создан у всех трёх ролей" || fail "нет USER.md:$nouser"
left="$(grep -rl '{{' "$SB_HOME/.openclaw" --include='*.md' --exclude='*.template' 2>/dev/null)"
[ -z "$left" ] && pass "плейсхолдеров в рабочих файлах не осталось" || fail "остались плейсхолдеры: $left"
grep -qF "$NAME" "$SB_HOME/.openclaw/workspace-designer/IDENTITY.md" \
  && pass "название с & \\ / подставлено дословно" || fail "название искажено: $(grep -m1 Роль "$SB_HOME/.openclaw/workspace-designer/IDENTITY.md")"
grep -qF "$VAULT" "$SB_HOME/.openclaw/workspace-coordinator/AGENTS.md" && grep -qF "openai/gpt-5.5" "$SB_HOME/.openclaw/workspace-coordinator/TOOLS.md" \
  && pass "путь к vault и модель подставлены в инструкции" || fail "vault/модель не подставлены"
vmiss=""; for f in README.md facts/README.md decisions/README.md next-steps/README.md profile/expert.md; do
  [ -f "$VAULT/$f" ] || vmiss="$vmiss $f"; done
[ -z "$vmiss" ] && pass "vault создан (profile, facts, decisions, next-steps)" || fail "в vault нет:$vmiss"
grep -qF "$NAME" "$VAULT/profile/expert.md" && pass "профиль в vault персонализирован" || fail "профиль vault не персонализирован"

# повторная установка не затирает данные клиента
echo "МОЁ: Нина, сессии по 50 минут" >> "$SB_HOME/.openclaw/workspace-coordinator/USER.md"
echo "МОЁ: аудитория — мамы в декрете" >> "$VAULT/profile/expert.md"
echo "МОЁ" > "$VAULT/facts/2026-09-24-факт.md"
echo "МОЁ: текущий пост" >> "$SB_HOME/.openclaw/workspace-copywriter/MEMORY.md"
deploy; rc=$?
kept=0
grep -q 'МОЁ: Нина' "$SB_HOME/.openclaw/workspace-coordinator/USER.md" && kept=$((kept+1))
grep -q 'МОЁ: аудитория' "$VAULT/profile/expert.md" && kept=$((kept+1))
[ -f "$VAULT/facts/2026-09-24-факт.md" ] && kept=$((kept+1))
grep -q 'МОЁ: текущий пост' "$SB_HOME/.openclaw/workspace-copywriter/MEMORY.md" && kept=$((kept+1))
[ "$rc" -eq 0 ] && [ "$kept" -eq 4 ] && pass "повторная установка сохранила USER.md, MEMORY.md и заметки vault" \
  || fail "повторная установка: rc=$rc, сохранено $kept/4"

# ── 4) Провайдер и модель ────────────────────────────────────────────────────
wz() {  # wz <переменные...> → "rc|PROVIDER|MODEL|VAULT_PATH" (при отказе — "rc|||")
  local out rc
  out="$(wz_raw "$@")"; rc=$?
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s|||' "$rc"; fi
}
wz_raw() {
  env -u AISTACK_DRY_RUN -u AISTACK_MODEL -u AISTACK_VAULT -u AISTACK_PROVIDER HOME="$SB_HOME" \
    AISTACK_TG_TOKENS="111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001 222222222:FAKEtokenFAKEtokenFAKEtokenFAKE0002 333333333:FAKEtokenFAKEtokenFAKEtokenFAKE0003" \
    "$@" bash -c '
    . "$0/lib/helpers.sh"; . "$0/lib/wizard.sh"; parse_key AIS-START-COACH-TEST0001
    run_wizard >/dev/null 2>&1; rc=$?
    printf "%s|%s|%s|%s" "$rc" "${PROVIDER:-}" "${MODEL:-}" "${VAULT_PATH:-}"' "$REPO_DIR" </dev/null
}
chk() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: получено '$2', ожидалось '$3'"; fi; }
chk "ключ sk-… → OpenAI, модель по умолчанию" "$(wz AISTACK_API_KEY=sk-proj-FAKEFAKEFAKEFAKEFAKE01)" "0|openai|openai/gpt-5.5|$SB_HOME/AIStack-Vault"
chk "ключ sk-ant-… → Anthropic, её модель по умолчанию" "$(wz AISTACK_API_KEY=sk-ant-FAKEFAKEFAKEFAKEFAKE01)" "0|anthropic|anthropic/claude-sonnet-4-6|$SB_HOME/AIStack-Vault"
chk "ключ неизвестного формата → OpenAI (клиенты чаще на GPT)" "$(wz AISTACK_API_KEY=proxy-FAKEFAKEFAKEFAKEFAKE01)" "0|openai|openai/gpt-5.5|$SB_HOME/AIStack-Vault"
chk "AISTACK_MODEL из списка" "$(wz AISTACK_API_KEY=sk-proj-FAKEFAKEFAKEFAKEFAKE01 AISTACK_MODEL=openai/gpt-5.4-mini)" "0|openai|openai/gpt-5.4-mini|$SB_HOME/AIStack-Vault"
chk "AISTACK_MODEL своего id в формате провайдер/модель" "$(wz AISTACK_API_KEY=sk-proj-FAKEFAKEFAKEFAKEFAKE01 AISTACK_MODEL=openai/my-custom-1)" "0|openai|openai/my-custom-1|$SB_HOME/AIStack-Vault"
r="$(wz AISTACK_API_KEY=sk-proj-FAKEFAKEFAKEFAKEFAKE01 AISTACK_MODEL=anthropic/claude-sonnet-4-6)"
[ "${r%%|*}" = 1 ] && pass "модель другого провайдера → отказ" || fail "модель другого провайдера принята: $r"
r="$(wz AISTACK_API_KEY=sk-proj-FAKEFAKEFAKEFAKEFAKE01 AISTACK_MODEL='gpt 5')"
[ "${r%%|*}" = 1 ] && pass "id модели без провайдера → отказ" || fail "кривой id принят: $r"
chk "AISTACK_VAULT с ~ раскрывается" "$(wz AISTACK_API_KEY=sk-proj-FAKEFAKEFAKEFAKEFAKE01 AISTACK_VAULT='~/Заметки')" "0|openai|openai/gpt-5.5|$SB_HOME/Заметки"
for v in "relative/path" "$SB_HOME" "$SB_HOME/.openclaw/vault"; do
  r="$(wz AISTACK_API_KEY=sk-proj-FAKEFAKEFAKEFAKEFAKE01 AISTACK_VAULT="$v")"
  [ "${r%%|*}" = 1 ] && pass "vault '$v' → отказ" || fail "vault '$v' принят: $r"
done

# интерактивное меню модели (ответы через stdin)
am() { printf "$2" | HOME="$SB_HOME" bash -c '. "$0/lib/helpers.sh"; . "$0/lib/wizard.sh"; PROVIDER="$1"; _ask_model >/dev/null 2>&1; printf "%s" "$MODEL"' "$REPO_DIR" "$1"; }
chk "меню: Enter → рекомендованная" "$(am openai '\n')" "openai/gpt-5.5"
chk "меню: номер 2" "$(am openai '2\n')" "openai/gpt-5.4-mini"
chk "меню: ошибка, затем свой id" "$(am openai 'anthropic/x\nopenai/custom-2\n')" "openai/custom-2"

# конфиг OpenClaw получает выбранную модель; ключ — файлом-патчем под нужным
# именем переменной (заглушка openclaw пишет argv и содержимое --file)
cat > "$SB_BIN/openclaw" <<STUB
#!/bin/sh
echo "openclaw \$*" >> "$SB_CALLS"
prev=""; for a in "\$@"; do [ "\$prev" = "--file" ] && cat "\$a" >> "$SB_CALLS.patches"; prev="\$a"; done
exit 0
STUB
chmod +x "$SB_BIN/openclaw"
setprov() {  # setprov <провайдер> <модель> <ключ>
  : > "$SB_CALLS"; : > "$SB_CALLS.patches"
  env -u AISTACK_DRY_RUN PATH="$SB_BIN:$PATH" HOME="$SB_HOME" bash -c '
    . "$0/lib/helpers.sh"; . "$0/lib/wizard.sh"; . "$0/lib/workspace-deploy.sh"; . "$0/lib/openclaw-setup.sh"
    PROVIDER="$1"; MODEL="$2"; API_KEY="$3"; TG_TOKENS=()
    openclaw_set_provider' "$REPO_DIR" "$@" >/dev/null 2>&1
}
setprov openai openai/gpt-5.4-mini sk-proj-FAKEFAKEFAKEFAKEFAKE01
grep -q '^openclaw config set agents.defaults.model.primary openai/gpt-5.4-mini$' "$SB_CALLS" \
  && pass "в конфиг OpenClaw уходит выбранная модель" || fail "модель в конфиг не ушла: $(cat "$SB_CALLS")"
grep -qF 'OPENAI_API_KEY: "sk-proj-FAKEFAKEFAKEFAKEFAKE01"' "$SB_CALLS.patches" && ! grep -qF 'sk-proj-FAKE' "$SB_CALLS" \
  && pass "ключ OpenAI → env.vars.OPENAI_API_KEY через файл-патч (не аргументом)" || fail "ключ OpenAI: $(cut -c1-80 "$SB_CALLS")"
grep -q 'claude-sonnet' "$SB_CALLS" && fail "осталась жёстко заданная модель" || pass "жёстко заданной модели больше нет"
setprov google google/gemini-3.1-pro-preview AIzaFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE00
grep -qF 'GEMINI_API_KEY: "AIzaFAKE' "$SB_CALLS.patches" && grep -q 'model.primary google/gemini-3.1-pro-preview$' "$SB_CALLS" \
  && pass "ключ Google (AIza…) → GEMINI_API_KEY, модель google/…" || fail "Google: $(cat "$SB_CALLS.patches" | cut -c1-60)"
chk "ключ AIza… → провайдер google и его модель по умолчанию" "$(wz AISTACK_API_KEY=AIzaFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE00)" "0|google|google/gemini-3.1-pro-preview|$SB_HOME/AIStack-Vault"
chk "меню: номер вне списка, затем Enter" "$(am openai '7\n0\n\n')" "openai/gpt-5.5"

# ── 5) Полный dry-run сборки COACH ───────────────────────────────────────────
rm -rf "$SANDBOX"; new_sandbox; add_sudo_stub
printf '# user bashrc\n' > "$SB_HOME/.bashrc"
before="$(home_snapshot)"
to=""; [ -e "$SANDBOX/sys/timeout" ] && to="timeout 120"
env -i HOME="$SB_HOME" PATH="$(sb_path)" TMPDIR="$SB_TMP" TERM=dumb LANG=C.UTF-8 \
  AISTACK_DRY_RUN=1 AISTACK_LOG="$SB_TMP/dry.log" AISTACK_HB="$SB_TMP/hb" \
  $to bash "$REPO_DIR/install.sh" AIS-START-COACH-TEST0001 > "$SANDBOX/out.txt" 2>&1
rc=$?
after="$(home_snapshot)"
if [ "$rc" -eq 0 ] && grep -q '^\[dry-run\] ' "$SB_TMP/dry.log"; then
  pass "dry-run сборки COACH прошёл"
  [ "$before" = "$after" ] && pass "dry-run: HOME не изменён (vault не создан)" || fail "dry-run изменил HOME"
  n="$(grep -c '^\[dry-run\] openclaw agents add ' "$SB_TMP/dry.log")"
  [ "$n" = 3 ] && pass "dry-run: регистрируются ровно 3 агента" || fail "dry-run: agents add × $n"
  grep -q 'agents.defaults.model.primary openai/gpt-5.5' "$SB_TMP/dry.log" && pass "dry-run: модель по умолчанию — openai/gpt-5.5" \
    || fail "dry-run: модель не выставлена"
else fail "dry-run сборки COACH упал (rc=$rc): $(grep -m1 -E '❌' "$SANDBOX/out.txt")"; fi

finish

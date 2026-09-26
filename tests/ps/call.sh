#!/usr/bin/env bash
# Пара к call.ps1: те же операции через lib/*.sh (эталон для паритета).
set -u
R="$(cd "$(dirname "$0")/../.." && pwd)"
. "$R/lib/helpers.sh"; . "$R/lib/wizard.sh"
API_KEY="${PARITY_API_KEY:-}"; TG_TOKENS=(); for t in ${PARITY_TG:-}; do TG_TOKENS+=("$t"); done
while IFS=$'\t' read -r op a1 a2 || [ -n "${op:-}" ]; do
  [ -n "$op" ] || continue
  case "$op" in
    key)
      if parse_key "$a1"; then rc=0; else rc=1; fi
      printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$rc" "$PRESET_ID" "$AGENTS" "$AGENT_COUNT" "$TARIFF" \
        "$HAS_CRITIC" "$HAS_LESSONS" "$IS_PERSONAL" "$KEY_ERROR";;
    apikey)   printf '%s\n' "$(api_key_problem "$a1")";;
    tg)       printf '%s\n' "$(tg_token_problem "$a1")";;
    prov)     _infer_provider "$a1"; echo "$PROVIDER";;
    defmodel) printf '%s\n' "$(default_model "$a1")";;
    models)   printf '%s\n' "$(models_for "$a1" | tr '\n' ' ' | sed 's/ $//')";;
    modelp)   printf '%s\n' "$(model_problem "$a1" "$a2")";;
    vaultp)   printf '%s\n' "$(vault_problem "$a1")";;
    expand)   _expand_home "$a1";;
    mask)     mask_secrets "$a1";;
    *)        echo "unknown op $op";;
  esac
  op=""; a1=""; a2=""
done

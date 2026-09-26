#!/usr/bin/env bash
# A real COACH install must have a numeric owner ID before apt/npm/gateway.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
key='fake-api-key-for-offline-test-9999'
token='123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
run_case() {
  local id="$1"
  env AISTACK_NONINTERACTIVE=1 AISTACK_API_KEY="$key" \
    AISTACK_TG_TOKENS="$token $token $token" AISTACK_OWNER_TG_ID="$id" \
    HOME="$tmp" REPO="$repo" bash -c '
      . "$REPO/lib/wizard.sh"
      . "$REPO/lib/helpers.sh"
      PRESET_ID=coach-team; AGENT_COUNT=3; AGENTS="coordinator designer copywriter"
      run_wizard >/dev/null 2>&1' </dev/null
}
printf '# test_coach_owner\n'
if run_case '' || run_case 'not-a-number'; then
  printf '  FAIL - пустой/неверный ID владельца принят для реальной COACH-установки\n'; exit 1
fi
if run_case '123456789'; then
  printf '  ok   - доступ владельца задан до установки пакетов\n'
else
  printf '  FAIL - корректный Telegram ID отвергнут\n'; exit 1
fi

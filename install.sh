#!/usr/bin/env bash
# ============================================================================
# AIStack · One-liner installer (v1.5)
#
#   bash <(curl -fsSL https://aistack-app.github.io/aistack-installer/install.sh) AIS-...
#
# Платформы: macOS (Intel+ARM), Ubuntu 22.04+, Debian 12+. Windows — не в v1.5.
# Тестовый прогон без установки: AISTACK_DRY_RUN=1 bash install.sh AIS-TEAM-FULL-DEV1234
# ============================================================================
set -euo pipefail

RAW_KEY="${1:-}"
AISTACK_BASE_URL="${AISTACK_BASE_URL:-https://aistack-app.github.io/aistack-installer}"
LIBS="helpers preflight apt-deps hermes-setup openclaw-setup workspace-deploy wizard"

# ── Bootstrap: грузим lib/ локально (если запущен из чекаута) или с github ───
_self="${BASH_SOURCE[0]:-}"
_dir=""
[ -n "$_self" ] && _dir="$(cd "$(dirname "$_self")" 2>/dev/null && pwd || true)"
if [ -n "$_dir" ] && [ -f "$_dir/lib/helpers.sh" ]; then
  for m in $LIBS; do
    # shellcheck disable=SC1090
    . "$_dir/lib/$m.sh"
  done
else
  _tmp="$(mktemp -d)"
  for m in $LIBS; do
    if ! curl -fsSL "$AISTACK_BASE_URL/lib/$m.sh" -o "$_tmp/$m.sh"; then
      echo "❌ Не удалось скачать lib/$m.sh с $AISTACK_BASE_URL. Проверьте интернет." >&2
      exit 1
    fi
    # shellcheck disable=SC1090
    . "$_tmp/$m.sh"
  done
fi

print_logo() {
  echo ""
  echo "${MAG}  █████${RST} ${CYA}AIStack${RST}  ·  AI-команда в одну команду"
  echo "${MAG}  ░░░░░${RST} v1.5  ·  Hermes + OpenClaw (open source)"
  echo ""
}

main() {
  install_traps
  print_logo

  # ── Stage 0: ключ ─────────────────────────────────────────────────────────
  CURRENT_STAGE="Stage 0: ключ"
  if ! parse_key "$RAW_KEY"; then
    err "$KEY_ERROR"
    echo "   Команда запуска: ${CYA}bash <(curl -fsSL $AISTACK_BASE_URL/install.sh) ВАШ-КЛЮЧ${RST}" >&2
    exit 1
  fi
  ok "Ключ принят · тариф: ${TARIFF} · сборка: ${PRESET_ID} · агентов: ${AGENT_COUNT}"
  $HAS_LESSONS && say "Доступ к урокам включён в ваш тариф."

  start_watchdog 600

  # ── Stage 1: preflight ────────────────────────────────────────────────────
  stage "STAGE 1/8 · проверка системы"
  CURRENT_STAGE="Stage 1: preflight"
  detect_os
  detect_arch
  check_internet
  check_disk_space

  # ── Stage 2: системные зависимости ────────────────────────────────────────
  stage "STAGE 2/8 · системные зависимости"
  install_system_deps

  # ── Stage 3: Hermes runtime (pip, ARM-safe, без Chromium) ─────────────────
  stage "STAGE 3/8 · Hermes (память команды)"
  start_watchdog 1020   # установка пакета длинная — поднимаем лимит watchdog
  hermes_install
  start_watchdog 600

  # ── Stage 4: OpenClaw ─────────────────────────────────────────────────────
  stage "STAGE 4/8 · OpenClaw runtime"
  openclaw_install
  openclaw_verify_memory

  # ── Stage 5: workspace-шаблоны ────────────────────────────────────────────
  stage "STAGE 5/8 · шаблоны команды"
  deploy_templates

  # ── Stage 6: wizard (ключ + токены + проект) ──────────────────────────────
  stage "STAGE 6/8 · настройка"
  run_wizard
  save_api_key

  # ── Stage 7: регистрация агентов-ботов ────────────────────────────────────
  stage "STAGE 7/8 · регистрация агентов"
  register_bots

  # ── Stage 8: запуск + финал ───────────────────────────────────────────────
  stage "STAGE 8/8 · запуск"
  openclaw_start
  print_final_marker
  open_dashboard_prompt
}

print_final_marker() {
  CURRENT_STAGE="финал"
  echo ""
  echo "${GRN}════════════════════════════════════════════════════════════${RST}"
  echo "  ${GRN}🚀  AIStack установлен (Stage 8/8)${RST}"
  echo "${GRN}════════════════════════════════════════════════════════════${RST}"
  echo ""
  echo "  ✓ Hermes runtime:    ~/.hermes/  (память + gateway)"
  echo "  ✓ OpenClaw:          ~/.openclaw/  (dashboard :18789)"
  echo "  ✓ Сборка:            ${PRESET_ID} (${TARIFF})"
  echo "  ✓ Агенты:            ${AGENT_COUNT}/${AGENT_COUNT} — ${AGENTS}"
  echo ""
  echo "  📊 Dashboard:        http://localhost:18789"
  echo "  💬 Первый агент:     напишите боту в Telegram «привет»"
  echo "  🩺 Если что-то не так: openclaw status  (диагноз без изменений)"
  echo ""
  echo "${GRN}════════════════════════════════════════════════════════════${RST}"
}

open_dashboard_prompt() {
  local url="http://localhost:18789"
  if [ ! -t 0 ]; then echo "  Откройте в браузере: $url"; return 0; fi
  printf "\n  Открыть dashboard сейчас? [Y/n]: "
  local ans=""; read -r ans || ans="n"
  case "${ans:-Y}" in
    [Yy]*|"")
      if command -v open >/dev/null 2>&1; then (open "$url" >/dev/null 2>&1 &)
      elif command -v xdg-open >/dev/null 2>&1; then (xdg-open "$url" >/dev/null 2>&1 &)
      else echo "  Откройте вручную: $url"; fi;;
  esac
}

main "$@"

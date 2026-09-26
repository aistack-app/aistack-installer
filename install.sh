#!/usr/bin/env bash
# ============================================================================
# AIStack · One-liner installer (v1.5)
#
#   bash <(curl -fsSL https://aistack-app.github.io/aistack-installer/install.sh) AIS-...
#
# Платформы: macOS (Intel+ARM), Ubuntu 22.04+, Debian 12+; Windows COACH — install.ps1.
# Нативный Windows W1 на заглушках пройден; живой OpenClaw и клиентская установка не проверены.
# Тестовый прогон без установки: AISTACK_DRY_RUN=1 bash install.sh AIS-START-COACH-TEST0001
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
  # офлайн-список моделей для выбора при установке (читает wizard.sh рядом с собой)
  if ! curl -fsSL "$AISTACK_BASE_URL/lib/models.tsv" -o "$_tmp/models.tsv"; then
    echo "❌ Не удалось скачать lib/models.tsv с $AISTACK_BASE_URL. Проверьте интернет." >&2
    exit 1
  fi
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

  # ── Настройка ДО установки: ключ, модель, токены, память ───────────────────
  # Раньше wizard шёл на Stage 6: без ключей отказ случался после ~10 минут
  # установки, Hermes (Stage 3) писал в .env ещё пустой ключ, а watchdog мог
  # убить процесс, пока клиент заводит ботов в BotFather (ввод не шлёт heartbeat).
  run_wizard

  start_watchdog 600   # дальше установка идёт без участия человека

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

  # ── Stage 6: настройка команды (ответы wizard собраны в начале) ───────────
  stage "STAGE 6/8 · настройка команды"
  save_api_key
  create_vault
  personalize_workspaces

  # ── Stage 7: регистрация агентов-ботов ────────────────────────────────────
  stage "STAGE 7/8 · регистрация агентов"
  register_bots

  # ── Stage 8: запуск + финал ───────────────────────────────────────────────
  stage "STAGE 8/8 · запуск"
  openclaw_start
  # Установка завершена — гасим watchdog ДО финального вопроса, иначе он
  # убьёт процесс, пока клиент думает над «Открыть dashboard?» (ложный
  # «процесс завис» после успешной установки — поймано на VPS-тесте).
  stop_watchdog
  # Итог — только по фактам: dry-run ничего не ставит; любая проблема
  # (канал, агент, привязка, gateway) → «не завершена» и код 1
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then print_dry_run_marker; return 0; fi
  if [ "$PROBLEM_COUNT" -gt 0 ]; then print_incomplete_marker; exit 1; fi
  print_final_marker
  open_dashboard_prompt
}

print_dry_run_marker() {
  CURRENT_STAGE="финал (dry-run)"
  echo ""
  echo "  Dry-run завершён: ничего не установлено и не запущено. Команды — в логе: $LOG"
}

print_incomplete_marker() {
  CURRENT_STAGE="финал: установка не завершена"
  echo "" >&2
  echo "${RED}════════════════════════════════════════════════════════════${RST}" >&2
  echo "  ${RED}❌  Установка НЕ завершена — команда не готова к работе${RST}" >&2
  echo "${RED}════════════════════════════════════════════════════════════${RST}" >&2
  printf '%s' "$PROBLEM_TEXT" >&2
  echo "  Лог: $LOG" >&2
  echo "  Исправьте причину и запустите установку ещё раз (готовые шаги повторятся безопасно)." >&2
}

print_final_marker() {
  CURRENT_STAGE="финал"
  echo ""
  echo "${GRN}════════════════════════════════════════════════════════════${RST}"
  echo "  ${GRN}🚀  AIStack установлен: настройки подтверждены (Stage 8/8)${RST}"
  echo "${GRN}════════════════════════════════════════════════════════════${RST}"
  echo ""
  echo "  Проверено установщиком:"
  echo "  ✓ Боты Telegram:     ${AGENT_COUNT}/${AGENT_COUNT} в конфиге OpenClaw, каждый привязан к своей роли — ${AGENTS}"
  echo "  ✓ Конфиг OpenClaw:   валиден (сборка ${PRESET_ID}, ${TARIFF})"
  echo "  ✓ Gateway:           ответил на RPC-пробу (dashboard http://localhost:18789)"
  [ -n "${VAULT_PATH:-}" ] && echo "  ✓ Память команды:    ${VAULT_PATH}  (можно открыть в Obsidian)"
  echo ""
  echo "  НЕ проверено установщиком (нужен живой запуск):"
  echo "  ? ответ модели ${MODEL:-(не выбрана: openclaw models set)} с вашим ключом/подпиской"
  echo "  ? ответы ботов — напишите каждому из ${AGENT_COUNT} ботов «привет»; нет ответа → openclaw models status"
  echo "  · Hermes (~/.hermes/) установлен, его работа не проверялась"
  if [ "${PRESET_ID:-}" = "smallbiz-team" ]; then
    echo "  🗺  С чего начать:    спросите Хозяина «с чего начать» — проведёт по первой неделе"
  fi
  echo "  🩺 Диагностика без изменений: openclaw status"
  echo ""
  echo "${GRN}════════════════════════════════════════════════════════════${RST}"
}

open_dashboard_prompt() {
  local url="http://localhost:18789"
  if [ ! -t 0 ] || [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then echo "  Откройте в браузере: $url"; return 0; fi
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

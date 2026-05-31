# shellcheck shell=bash
# ============================================================================
# workspace-deploy.sh — тянет workspace-templates с публичного репо и
# раскладывает по агентам пресета в ~/.openclaw/workspace-<agent>/.
#
# ⚠️ Источник: AISTACK_TEMPLATES_URL (tarball ПУБЛИЧНОГО репо). workspace-templates
# обезличены (БРИФ-8) → их можно держать в публичном репо. Платные skills/knowledge
# остаются в приватном aistack-knowledge. По умолчанию тянем из самого репо установщика
# (templates/ внутри него) — тогда one-liner работает без токена. Если задать приватный
# источник — AISTACK_TEMPLATES_TOKEN (но в публичном install.sh токен светить нельзя).
# ============================================================================

WORKSPACE_BASE="${AISTACK_WORKSPACE_BASE:-$HOME/.openclaw}"
TEMPLATES_URL="${AISTACK_TEMPLATES_URL:-https://github.com/kostyavkoste/aistack-installer/tarball/main}"

deploy_templates() {
  CURRENT_STAGE="Stage 5: workspace templates"
  local tgz="/tmp/aistack-knowledge.tar.gz" exdir="/tmp/aistack-knowledge-extract"

  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then
    for a in $AGENTS; do
      run mkdir -p "$WORKSPACE_BASE/workspace-$a"
      ok "workspace-$a (dry-run)"
    done
    return 0
  fi

  local hdr=()
  [ -n "${AISTACK_TEMPLATES_TOKEN:-}" ] && hdr=(-H "Authorization: Bearer ${AISTACK_TEMPLATES_TOKEN}")

  run_step "Скачиваю шаблоны команды" retry curl -fsSL "${hdr[@]}" "$TEMPLATES_URL" -o "$tgz"
  rm -rf "$exdir"; mkdir -p "$exdir"
  run_step "Распаковываю шаблоны" tar -xzf "$tgz" -C "$exdir"

  # github tarball распаковывается в подпапку <user>-<repo>-<sha>/
  local root tdir
  root="$(find "$exdir" -maxdepth 1 -mindepth 1 -type d | head -n1)"
  # шаблоны могут лежать в templates/ (внутри репо установщика) или workspace-templates/
  if   [ -n "$root" ] && [ -d "$root/templates" ];           then tdir="$root/templates"
  elif [ -n "$root" ] && [ -d "$root/workspace-templates" ]; then tdir="$root/workspace-templates"
  else
    err "В архиве шаблонов нет templates/ или workspace-templates/. Проверьте AISTACK_TEMPLATES_URL."
    exit 1
  fi

  local deployed=0
  for a in $AGENTS; do
    if [ -d "$tdir/$a" ]; then
      run mkdir -p "$WORKSPACE_BASE/workspace-$a"
      run cp -R "$tdir/$a/." "$WORKSPACE_BASE/workspace-$a/"
      ok "workspace-$a"
      deployed=$((deployed + 1))
    else
      warn "Шаблон для агента '$a' не найден в репо — пропускаю."
    fi
  done
  ok "Развёрнуто workspace-папок: $deployed/$AGENT_COUNT"
}

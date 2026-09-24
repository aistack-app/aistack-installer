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
TEMPLATES_URL="${AISTACK_TEMPLATES_URL:-https://github.com/aistack-app/aistack-installer/tarball/main}"
TEMPLATES_SRC=""   # каталог с шаблонами после скачивания (нужен и для vault)

# _copy_missing <src> <dst> — копирует файлы, которых ещё нет в dst.
# Повторная установка не затирает заполненные USER.md/MEMORY.md и заметки vault.
_copy_missing() {
  local src="$1" dst="$2" rel
  ( cd "$src" && find . -type f ) | while IFS= read -r rel; do
    rel="${rel#./}"
    [ -e "$dst/$rel" ] && continue
    mkdir -p "$dst/$(dirname "$rel")" && cp "$src/$rel" "$dst/$rel" || exit 1
  done
}

# Экранирование строки для правой части sed s/…/…/ (\, / и &)
_sed_repl() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

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

  local root tdir
  if [ -n "${AISTACK_TEMPLATES_DIR:-}" ]; then
    # локальный каталог шаблонов (офлайн-тесты / разработка) — без скачивания
    if [ ! -d "$AISTACK_TEMPLATES_DIR" ]; then
      err "AISTACK_TEMPLATES_DIR=$AISTACK_TEMPLATES_DIR — каталог не найден."; exit 1
    fi
    tdir="$AISTACK_TEMPLATES_DIR"
  else
    # ${hdr[@]+…}: пустой массив под set -u роняет bash 3.2 (системный на macOS)
    local hdr=()
    [ -n "${AISTACK_TEMPLATES_TOKEN:-}" ] && hdr=(-H "Authorization: Bearer ${AISTACK_TEMPLATES_TOKEN}")

    run_step "Скачиваю шаблоны команды" retry curl -fsSL ${hdr[@]+"${hdr[@]}"} "$TEMPLATES_URL" -o "$tgz"
    rm -rf "$exdir"; mkdir -p "$exdir"
    run_step "Распаковываю шаблоны" tar -xzf "$tgz" -C "$exdir"

    # github tarball распаковывается в подпапку <user>-<repo>-<sha>/
    root="$(find "$exdir" -maxdepth 1 -mindepth 1 -type d | head -n1)"
    # шаблоны могут лежать в templates/ (внутри репо установщика) или workspace-templates/
    if   [ -n "$root" ] && [ -d "$root/templates" ];           then tdir="$root/templates"
    elif [ -n "$root" ] && [ -d "$root/workspace-templates" ]; then tdir="$root/workspace-templates"
    else
      err "В архиве шаблонов нет templates/ или workspace-templates/. Проверьте AISTACK_TEMPLATES_URL."
      exit 1
    fi
  fi
  TEMPLATES_SRC="$tdir"

  local deployed=0 preset_dir="$tdir/_presets/${PRESET_ID:-}"
  for a in $AGENTS; do
    if [ -d "$preset_dir/$a" ]; then
      # у сборки своя версия роли (напр. coach-team: coordinator = координатор-
      # технарь для команды из 3 ролей) — целиком вместо общего шаблона;
      # уже существующие файлы клиента не затираются
      mkdir -p "$WORKSPACE_BASE/workspace-$a"
      _copy_missing "$preset_dir/$a" "$WORKSPACE_BASE/workspace-$a"
      ok "workspace-$a (сборка $PRESET_ID)"
      deployed=$((deployed + 1))
    elif [ -d "$tdir/$a" ]; then
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

# Память команды (Obsidian vault) — отдельная папка на компьютере клиента.
# Создаётся пустой структурой из templates/_vault; чужие заметки/ключи сюда не
# попадают, существующие файлы клиента не перезаписываются. Только сборка COACH.
create_vault() {
  [ "${PRESET_ID:-}" = "coach-team" ] || return 0
  CURRENT_STAGE="Stage 6d: память команды"
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then
    run mkdir -p "$VAULT_PATH"; ok "Память команды: $VAULT_PATH (dry-run)"; return 0
  fi
  local src="${TEMPLATES_SRC:-}/_vault" f
  if [ ! -d "$src" ]; then err "В шаблонах нет _vault/ — не могу создать память команды."; exit 1; fi
  mkdir -p "$VAULT_PATH"
  _copy_missing "$src" "$VAULT_PATH"
  find "$VAULT_PATH" -type f -name "*.md" 2>/dev/null | while IFS= read -r f; do
    if grep -qs '{{STUDIO_NAME}}' "$f"; then
      sed -i.aistack-bak -e "s/{{STUDIO_NAME}}/$(_sed_repl "$BUSINESS_NAME")/g" "$f" && rm -f "$f.aistack-bak"
    fi
  done
  ok "Память команды: $VAULT_PATH (ваши существующие файлы не тронуты)"
}

# Персонализация воркспейсов — ПОСЛЕ wizard (Stage 6): подставляет название
# бизнеса, ID канала, путь к vault и модель в плейсхолдеры, активирует
# *.template → рабочие файлы. Только сборки smallbiz/admin/coach — остальные
# v1-шаблоны живут по своим правилам.
personalize_workspaces() {
  CURRENT_STAGE="Stage 6c: персонализация"
  case "${PRESET_ID:-}" in smallbiz-team|admin-solo|coach-team) :;; *) return 0;; esac
  if [ "${AISTACK_DRY_RUN:-0}" = "1" ]; then ok "Персонализация (dry-run)"; return 0; fi

  local a ws f r_name r_chan r_vault r_model
  r_name="$(_sed_repl "$BUSINESS_NAME")"
  r_chan="$(_sed_repl "${CHANNEL_ID:-ЗАПОЛНИТЕ-ПОЗЖЕ}")"
  r_vault="$(_sed_repl "${VAULT_PATH:-}")"
  r_model="$(_sed_repl "${MODEL:-не выбрана — openclaw models set}")"
  for a in $AGENTS; do
    ws="$WORKSPACE_BASE/workspace-$a"
    [ -d "$ws" ] || continue
    # *.template → рабочий файл (существующий не перетираем —
    # повторная установка не убивает заполненный BUSINESS.md / USER.md)
    for f in "$ws"/*.template; do
      [ -e "$f" ] || continue
      [ -e "${f%.template}" ] || cp "$f" "${f%.template}"
    done
    # Плейсхолдеры. ADDRESS/CITY оставляем владельцу.
    find "$ws" -maxdepth 2 -type f \( -name "*.md" -o -name "*.json" \) \
      ! -name "*.template" 2>/dev/null | while IFS= read -r f; do
      if grep -qs '{{STUDIO_NAME}}\|{{CHANNEL_ID}}\|{{VAULT_PATH}}\|{{MODEL}}' "$f"; then
        sed -i.aistack-bak \
          -e "s/{{STUDIO_NAME}}/$r_name/g" \
          -e "s/{{CHANNEL_ID}}/$r_chan/g" \
          -e "s/{{VAULT_PATH}}/$r_vault/g" \
          -e "s/{{MODEL}}/$r_model/g" \
          "$f" && rm -f "$f.aistack-bak"
      fi
    done
  done
  ok "Воркспейсы персонализированы: «${BUSINESS_NAME}»${CHANNEL_ID:+, канал $CHANNEL_ID}"
}

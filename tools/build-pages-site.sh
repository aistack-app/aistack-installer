#!/usr/bin/env bash
# ============================================================================
# tools/build-pages-site.sh <каталог> — эталон того, что GitHub Pages обязан
# раздавать. Pages публикует main:/ штатной сборкой (legacy, Jekyll); этот
# скрипт НИЧЕГО не публикует — он собирает эталон для проверки:
#   • файлы загрузчика, побайтно: install.sh, install.ps1, lib/<LIBS>.sh,
#     lib/models.tsv (список библиотек — из строки LIBS= в install.sh) + SHA256SUMS;
#   • PAGES — страницы, уже опубликованные по этим URL (должны отдавать 200):
#     index.html (из README.md) и docs/*.html (из docs/*.md).
# Отказ (код 1): нет/пустой файл, синтаксическая ошибка, install.ps1 без BOM,
# файл загрузчика начинается с front matter (Jekyll отрендерил бы его вместо
# копирования), .nojekyll/_config.yml (меняют сборку: страницы исчезнут).
# ============================================================================
set -euo pipefail

OUT="${1:-}"
SRC="${AISTACK_SITE_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# страницы, которые сейчас открываются на Pages, и их исходники
KEEP_PAGES="index.html:README.md docs/ARCHITECTURE-5-BOTS.html:docs/ARCHITECTURE-5-BOTS.md docs/SITE-COPY-SMALLBIZ.html:docs/SITE-COPY-SMALLBIZ.md"

die() { echo "❌ build-pages-site: $*" >&2; exit 1; }
_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

[ -n "$OUT" ] || die "укажите каталог сборки"
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then die "$OUT не пуст"; fi

libs="$(sed -n 's/^LIBS="\(.*\)"$/\1/p' "$SRC/install.sh" 2>/dev/null || true)"
[ -n "$libs" ] || die "в install.sh не найдена строка LIBS=\"…\""

files="install.sh install.ps1 lib/models.tsv"
for m in $libs; do files="$files lib/$m.sh"; done

for f in $files; do
  [ -f "$SRC/$f" ] || die "нет файла $f — клиентская команда получила бы 404"
  [ -s "$SRC/$f" ] || die "пустой файл $f"
  # front matter → Jekyll отдаст отрендеренный файл вместо исходного
  [ "$(head -n 1 "$SRC/$f" | sed $'s/^\xef\xbb\xbf//' | tr -d '\r')" != "---" ] || die "$f начинается с front matter (---)"
done
for f in $files; do
  case "$f" in *.sh) bash -n "$SRC/$f" || die "синтаксическая ошибка в $f";; esac
done
# Windows PowerShell 5.1 читает файл без BOM как ANSI → кириллица ломается
[ "$(head -c 3 "$SRC/install.ps1" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] \
  || die "install.ps1 без UTF-8 BOM"

for f in .nojekyll _config.yml _config.yaml; do
  [ ! -e "$SRC/$f" ] || die "$f меняет сборку Pages (страницы .html могут исчезнуть) — обновите проверку осознанно"
done
pages=""
for p in $KEEP_PAGES; do
  [ -f "$SRC/${p#*:}" ] || die "нет ${p#*:} — страница ${p%%:*} перестанет открываться"
  pages="$pages ${p%%:*}"
done

mkdir -p "$OUT/lib"
for f in $files; do cp "$SRC/$f" "$OUT/$f"; done
(cd "$OUT" && _sha $files > SHA256SUMS)
for p in $pages; do echo "$p"; done > "$OUT/PAGES"

echo "✓ эталон в $OUT: файлы загрузчика (SHA256SUMS) и страницы (PAGES)"
sed 's/^/  /' "$OUT/SHA256SUMS" "$OUT/PAGES"

#!/usr/bin/env bash
# ============================================================================
# tools/verify-pages-site.sh <base-url> <каталог эталона>
# • каждый файл из SHA256SUMS: HTTP 200 и тот же SHA-256 (404, устаревший кеш,
#   другая ветка, потерянный BOM → ошибка);
# • каждая страница из PAGES: HTTP 200 и HTML (страницы рендерит Pages, поэтому
#   сверяется наличие, а не байты).
# Любое расхождение → код 1. VERIFY_ATTEMPTS / VERIFY_DELAY — повторы, пока
# Pages собирает новую версию и CDN раздаёт старую.
# ============================================================================
set -euo pipefail

BASE="${1:-}"; SITE="${2:-}"
ATTEMPTS="${VERIFY_ATTEMPTS:-1}"; DELAY="${VERIFY_DELAY:-15}"
[ -n "$BASE" ] && [ -f "$SITE/SHA256SUMS" ] || { echo "usage: $0 <base-url> <site-dir>" >&2; exit 2; }
BASE="${BASE%/}"

_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

fetch() {  # fetch <путь> → код HTTP, тело в $tmp/body
  curl -sS -o "$tmp/body" -w '%{http_code}' "$BASE/$1?cb=$$-$RANDOM" 2>"$tmp/err" || true
}

check_all() {
  local bad=0 want f got code
  while read -r want f; do
    f="${f#\*}"; code="$(fetch "$f")"
    if [ "$code" != "200" ]; then
      echo "  ✗ $f → HTTP ${code:-нет ответа} $(head -c 200 "$tmp/err")"; bad=1; continue
    fi
    got="$(_sha "$tmp/body" | cut -d' ' -f1)"
    if [ "$got" = "$want" ]; then echo "  ✓ $f"; else echo "  ✗ $f → SHA-256 $got ≠ $want"; bad=1; fi
  done < "$SITE/SHA256SUMS"
  if [ -f "$SITE/PAGES" ]; then
    while read -r f; do
      [ -n "$f" ] || continue
      code="$(fetch "$f")"
      if [ "$code" != "200" ]; then echo "  ✗ страница $f → HTTP ${code:-нет ответа}"; bad=1
      elif ! grep -qi '<html' "$tmp/body"; then echo "  ✗ страница $f → 200, но не HTML"; bad=1
      else echo "  ✓ страница $f"; fi
    done < "$SITE/PAGES"
  fi
  return "$bad"
}

i=1
while :; do
  echo "Проверка $BASE (попытка $i/$ATTEMPTS)"
  if check_all; then echo "✓ файлы загрузчика совпадают побайтно, страницы открываются"; exit 0; fi
  [ "$i" -ge "$ATTEMPTS" ] && break
  i=$((i + 1)); sleep "$DELAY"
done
echo "❌ опубликованный сайт не совпадает с эталоном" >&2
exit 1

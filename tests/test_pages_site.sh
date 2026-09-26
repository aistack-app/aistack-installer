#!/usr/bin/env bash
# Маршрут публикации (GitHub Pages, legacy, источник main:/):
# • эталон содержит всё, что скачивают клиентские команды, побайтно, и список
#   уже опубликованных страниц (index.html, docs/ARCHITECTURE-5-BOTS.html,
#   docs/SITE-COPY-SMALLBIZ.html) — они не должны пропасть;
# • эталон отказывает: нет файла/исходника страницы, нет BOM, front matter,
#   .nojekyll;
# • проверка опубликованного сайта ловит 404, подмену байта, пропавшую страницу;
# • install.sh, запущенный как у клиента (bash <(curl …)), грузит lib/ и
#   models.tsv с сайта и доходит до финала dry-run.
# Сайт раздаётся локальным http-сервером на 127.0.0.1 — в интернет тест не ходит.
# Рендер страниц Jekyll здесь имитируется (готовый HTML): сам рендер тестом
# не проверяется.
set -u
. "$(dirname "$0")/lib.sh"

echo "# test_pages_site (эталон и раздача сайта установщика)"
REAL_CURL="$(command -v curl || true)"
SRV_PID=""
stop_srv() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""; }
trap stop_srv EXIT
KEEP="index.html docs/ARCHITECTURE-5-BOTS.html docs/SITE-COPY-SMALLBIZ.html"

new_sandbox
SITE="$SANDBOX/site"
if bash "$REPO_DIR/tools/build-pages-site.sh" "$SITE" > "$SANDBOX/build.txt" 2>&1; then
  pass "эталон собран → exit 0"
else fail "эталон: $(tail -1 "$SANDBOX/build.txt")"; fi

libs="$(sed -n 's/^LIBS="\(.*\)"$/\1/p' "$REPO_DIR/install.sh")"
need="install.sh install.ps1 lib/models.tsv"; for m in $libs; do need="$need lib/$m.sh"; done
miss=""; for f in $need; do cmp -s "$REPO_DIR/$f" "$SITE/$f" || miss="$miss $f"; done
[ -z "$miss" ] && pass "в эталоне все $(echo $need | wc -w | tr -d ' ') файлов загрузчика, побайтно как в репо" \
  || fail "нет или отличаются:$miss"
[ "$(head -c 3 "$SITE/install.ps1" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] \
  && pass "install.ps1 в эталоне с UTF-8 BOM (PowerShell 5.1)" || fail "install.ps1 в эталоне без BOM"
miss=""; for p in $KEEP; do grep -qx "$p" "$SITE/PAGES" 2>/dev/null || miss="$miss $p"; done
[ -z "$miss" ] && pass "опубликованные страницы в списке обязательных: $KEEP" || fail "в PAGES нет:$miss"

# отказы эталона — на полной копии репо с одной поломкой
broken() {  # broken <метка> <команда поломки…> → RC, BOUT
  local d="$SANDBOX/src-$1"; shift
  mkdir -p "$d"; cp -R "$REPO_DIR/install.sh" "$REPO_DIR/install.ps1" "$REPO_DIR/lib" "$REPO_DIR/README.md" "$REPO_DIR/docs" "$d/"
  (cd "$d" && eval "$*")
  BOUT="$d.out"
  AISTACK_SITE_SRC="$d" bash "$REPO_DIR/tools/build-pages-site.sh" "$d.site" > "$BOUT" 2>&1
  RC=$?
  [ -e "$d.site/install.sh" ] && RC=99   # эталон не должен создаваться при отказе
}
broken nomodels 'rm lib/models.tsv'
[ "$RC" -ne 0 ] && [ "$RC" -ne 99 ] && grep -q 'lib/models.tsv' "$BOUT" \
  && pass "нет lib/models.tsv → отказ (exit $RC), файл назван" || fail "без models.tsv: exit=$RC $(tail -1 "$BOUT")"
broken nobom 'tail -c +4 "$REPO_DIR/install.ps1" > install.ps1'
[ "$RC" -ne 0 ] && [ "$RC" -ne 99 ] && grep -q 'BOM' "$BOUT" \
  && pass "install.ps1 без BOM → отказ (exit $RC)" || fail "без BOM: exit=$RC"
broken nodoc 'rm docs/SITE-COPY-SMALLBIZ.md'
[ "$RC" -ne 0 ] && [ "$RC" -ne 99 ] && grep -q 'docs/SITE-COPY-SMALLBIZ.html' "$BOUT" \
  && pass "нет docs/SITE-COPY-SMALLBIZ.md → отказ (exit $RC): страница пропала бы" || fail "без docs-исходника: exit=$RC $(tail -1 "$BOUT")"
broken nojekyll ': > .nojekyll'
[ "$RC" -ne 0 ] && [ "$RC" -ne 99 ] && grep -q '.nojekyll' "$BOUT" \
  && pass ".nojekyll → отказ (exit $RC): без Jekyll docs/*.html не собрались бы" || fail ".nojekyll: exit=$RC"
broken frontmatter '{ printf -- "---\n---\n"; cat "$REPO_DIR/lib/helpers.sh"; } > lib/helpers.sh'
[ "$RC" -ne 0 ] && [ "$RC" -ne 99 ] && grep -q 'front matter' "$BOUT" \
  && pass "front matter в lib/helpers.sh → отказ (exit $RC): Jekyll отдал бы не исходный файл" || fail "front matter: exit=$RC"

if ! command -v python3 >/dev/null 2>&1 || [ -z "$REAL_CURL" ]; then
  echo "  SKIP - нет python3 или curl: раздача сайта и запуск через bash <(curl …) не проверены"
  finish
fi

# serve <каталог> → BASE, SRV_LOG (журнал запросов)
serve() {
  stop_srv
  SRV_LOG="$SANDBOX/srv-$RANDOM.log"
  (cd "$1" && exec python3 -u -m http.server 0 --bind 127.0.0.1) > "$SRV_LOG" 2>&1 &
  SRV_PID=$!
  local i=0 port=""
  while [ $i -lt 50 ]; do
    port="$(sed -n 's/.* port \([0-9][0-9]*\).*/\1/p' "$SRV_LOG" | head -1)"
    [ -n "$port" ] && break; sleep 0.1; i=$((i + 1))
  done
  BASE="http://127.0.0.1:$port"
}
verify() {  # verify <метка> → RC, VOUT
  VOUT="$SANDBOX/v-$1.txt"
  env -i PATH="/usr/bin:/bin:$(dirname "$REAL_CURL")" TMPDIR="$SB_TMP" \
    bash "$REPO_DIR/tools/verify-pages-site.sh" "$BASE" "$SITE" > "$VOUT" 2>&1
  RC=$?
}

# «опубликованный» сайт: файлы загрузчика + страницы (имитация рендера Jekyll)
SERVED="$SANDBOX/served"; cp -R "$SITE" "$SERVED"
for p in $KEEP; do mkdir -p "$SERVED/$(dirname "$p")"; printf '<!DOCTYPE html>\n<html><body>%s</body></html>\n' "$p" > "$SERVED/$p"; done
serve "$SERVED"
verify ok
[ "$RC" -eq 0 ] && pass "проверка исправного сайта: файлы 200 + SHA-256, 3 страницы 200 → exit 0" \
  || fail "проверка исправного сайта: exit=$RC $(grep -m1 '✗' "$VOUT")"

printf 'x' >> "$SERVED/lib/helpers.sh"; rm "$SERVED/install.ps1" "$SERVED/docs/SITE-COPY-SMALLBIZ.html"
echo 'plain text' > "$SERVED/docs/ARCHITECTURE-5-BOTS.html"
verify broken
if [ "$RC" -ne 0 ] && grep -q 'install.ps1 → HTTP 404' "$VOUT" && grep -q 'lib/helpers.sh → SHA-256' "$VOUT" \
   && grep -q 'страница docs/SITE-COPY-SMALLBIZ.html → HTTP 404' "$VOUT" && grep -q 'страница docs/ARCHITECTURE-5-BOTS.html → 200, но не HTML' "$VOUT"; then
  pass "проверка ловит 404 файла, подменённый байт, пропавшую и не-HTML страницу → exit $RC"
else fail "проверка сломанного сайта: exit=$RC $(tr '\n' '|' < "$VOUT")"; fi

# Клиентский запуск: bash <(curl -fsSL $BASE/install.sh) КЛЮЧ, dry-run, песочница.
# curl в песочнице пускает только на локальный сайт; остальное — отказ и запись.
add_sudo_stub
client_run() {  # client_run <каталог сайта> <метка>
  serve "$1"
  cat > "$SB_BIN/curl" <<EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in http*://*) case "\$a" in "$BASE"/*) ;; *) echo "curl-denied \$a" >> "$SB_CALLS"; exit 7;; esac;; esac; done
exec "$REAL_CURL" --noproxy '*' "\$@"
EOF
  chmod +x "$SB_BIN/curl"
  OUT="$SANDBOX/client-$2.txt"
  env -i HOME="$SB_HOME" PATH="$(sb_path)" TMPDIR="$SB_TMP" TERM=dumb LANG=C.UTF-8 AISTACK_DRY_RUN=1 \
    AISTACK_BASE_URL="$BASE" AISTACK_LOG="$SB_TMP/client-$2.log" \
    bash -c 'bash <(curl -fsSL "$AISTACK_BASE_URL/install.sh") AIS-START-COACH-TEST0001' > "$OUT" 2>&1 </dev/null
  RC=$?
}

client_run "$SITE" ok
got=""; for f in $need; do [ "$f" = install.ps1 ] && continue; grep -q "\"GET /$f HTTP/1.[01]\" 200" "$SRV_LOG" || got="$got $f"; done
if [ "$RC" -eq 0 ] && grep -q 'ничего не установлено' "$OUT" && [ -z "$got" ] && ! grep -q 'curl-denied' "$SB_CALLS"; then
  pass "bash <(curl …/install.sh) → грузит install.sh, 7 lib/*.sh и models.tsv с сайта (все 200), dry-run exit 0"
else fail "клиентский запуск: exit=$RC, не скачано:${got:- —}, $(grep -m1 -E '❌|curl-denied' "$OUT" "$SB_CALLS")"; fi
grep -q 'AIStack установлен' "$OUT" && fail "dry-run объявил установку" || pass "dry-run не печатает «AIStack установлен»"

SITE404="$SANDBOX/site404"; cp -R "$SITE" "$SITE404"; rm "$SITE404/lib/models.tsv"
client_run "$SITE404" nomodels
if [ "$RC" -ne 0 ] && grep -q 'Не удалось скачать lib/models.tsv' "$OUT" && ! grep -q 'AIStack установлен' "$OUT"; then
  pass "на сайте нет lib/models.tsv (404) → клиентский запуск exit $RC с понятной причиной"
else fail "запуск без models.tsv: exit=$RC $(head -3 "$OUT" | tr '\n' '|')"; fi

stop_srv
finish

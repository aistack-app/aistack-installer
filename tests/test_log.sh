#!/usr/bin/env bash
# Лог установки: права 600, не по фиксированному пути, не следует подложенному
# симлинку, аргументы с секретами в него не пишутся.
set -u
. "$(dirname "$0")/lib.sh"

echo "# test_log"
new_sandbox
export AISTACK_HB="$SB_TMP/hb"

# 1) Лог по умолчанию: создаётся во временной папке (TMPDIR), права 600
LOGPATH="$(cd "$SB_TMP" && env -u AISTACK_LOG TMPDIR="$SB_TMP" HOME="$SB_HOME" \
  bash -c '. "$0/lib/helpers.sh"; echo "$LOG"' "$REPO_DIR" 2>/dev/null)"
case "$LOGPATH" in
  "$SB_TMP"/*) pass "лог по умолчанию во временной папке ($LOGPATH)";;
  *)           fail "лог по умолчанию по фиксированному пути вне TMPDIR: $LOGPATH";;
esac
if [ -f "$LOGPATH" ] && [ ! -L "$LOGPATH" ] && [ "$(file_mode "$LOGPATH")" = "600" ]; then
  pass "лог по умолчанию — обычный файл с правами 600"
else
  fail "лог по умолчанию: права $(file_mode "$LOGPATH"), ожидалось 600"
fi

# 2) AISTACK_LOG = подложенный симлинк на чужой файл → файл-жертва не тронут
VICTIM="$SANDBOX/victim.txt"; echo "важные данные" > "$VICTIM"
ln -s "$VICTIM" "$SB_TMP/planted.log"
AISTACK_LOG="$SB_TMP/planted.log" HOME="$SB_HOME" \
  bash -c '. "$0/lib/helpers.sh"; say "запись в лог" >> "$LOG"' "$REPO_DIR" >/dev/null 2>&1
if [ "$(cat "$VICTIM")" = "важные данные" ]; then
  pass "подложенный симлинк не разыменован, файл-жертва цел"
else
  fail "файл-жертва по симлинку изменён: '$(cat "$VICTIM")'"
fi

# 3) AISTACK_LOG = существующий файл с правами 644 → становится 600
PRE="$SB_TMP/pre.log"; echo old > "$PRE"; chmod 644 "$PRE"
AISTACK_LOG="$PRE" HOME="$SB_HOME" bash -c '. "$0/lib/helpers.sh"' "$REPO_DIR" >/dev/null 2>&1
if [ "$(file_mode "$PRE")" = "600" ]; then pass "AISTACK_LOG: права приведены к 600"
else fail "AISTACK_LOG: права $(file_mode "$PRE"), ожидалось 600"; fi

# 4) run() в dry-run не пишет секреты из аргументов (включая «нешаблонные»)
L4="$SB_TMP/run.log"
AISTACK_LOG="$L4" AISTACK_DRY_RUN=1 HOME="$SB_HOME" bash -c '
  . "$0/lib/helpers.sh"
  API_KEY="fake-api-key-NOPATTERN-777"
  TG_TOKENS=("fake-tg-token-one" "111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001")
  run openclaw config set env.vars.ANTHROPIC_API_KEY "$API_KEY"
  run openclaw channels add --channel telegram --account a --token "${TG_TOKENS[0]}"
  run openclaw channels add --channel telegram --account b --token "${TG_TOKENS[1]}"
  run openclaw config set env.vars.GEMINI_API_KEY AIzaFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE00
' "$REPO_DIR" >/dev/null 2>&1
leaked=""
for s in fake-api-key-NOPATTERN-777 fake-tg-token-one \
         111111111:FAKEtokenFAKEtokenFAKEtokenFAKE0001 AIzaFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE00; do
  grep -qF "$s" "$L4" 2>/dev/null && leaked="$leaked $s"
done
if [ -z "$leaked" ]; then pass "dry-run: секреты в аргументах замаскированы"
else fail "dry-run: в лог попали секреты:$leaked"; fi
if grep -q '^\[dry-run\] openclaw channels add' "$L4" 2>/dev/null; then
  pass "dry-run: сами команды в лог по-прежнему пишутся"
else fail "dry-run: команды пропали из лога"; fi

finish

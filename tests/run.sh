#!/usr/bin/env bash
# Офлайн-тесты установщика: bash tests/run.sh
# Ничего не устанавливают, в сеть не ходят, sudo не вызывают; ключи — выдуманные.
set -u
cd "$(dirname "$0")"
failed=0
for t in test_*.sh; do
  bash "$t" || failed=$((failed + 1))
done
echo ""
if [ "$failed" -eq 0 ]; then echo "ВСЕ ТЕСТЫ ПРОЙДЕНЫ"; else echo "ПРОВАЛЕНО ФАЙЛОВ: $failed"; exit 1; fi

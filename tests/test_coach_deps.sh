#!/usr/bin/env bash
# COACH installs only system packages needed for its OpenClaw runtime.
# apt/Node/Python are stubbed at the command boundary; no network or system write.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
. "$repo/lib/apt-deps.sh"
run_step() { printf '%s\n' "$*" >> "$work/calls"; }
ensure_python_311_or_newer() { printf 'python-check\n' >> "$work/calls"; }
ensure_node() { printf 'node-check\n' >> "$work/calls"; }
brew() { :; }  # macOS-only prereq; test also runs on Linux CI without Homebrew
ok() { :; }
PRESET_ID=coach-team
AISTACK_DRY_RUN=1
_deps_debian
printf '# test_coach_deps\n'
if grep -q 'apt-get install.*ca-certificates.*curl.*git.*gnupg' "$work/calls" \
  && grep -q 'node-check' "$work/calls"; then
  printf '  ok   - базовые пакеты и Node остаются\n'
else
  printf '  FAIL - нет обязательных пакетов или Node\n'; exit 1
fi
if grep -qE 'ffmpeg|ripgrep|sqlite3|software-properties-common|python-check' "$work/calls"; then
  printf '  FAIL - COACH ставит лишние медиа/Python-зависимости\n'; exit 1
fi
printf '  ok   - COACH не ставит отдельный медиа/Python-стек\n'
: > "$work/calls"
_deps_macos
if grep -q 'brew install node git$' "$work/calls"; then
  printf '  ok   - macOS COACH ставит Node/git без Python/медиа-стека\n'
else
  printf '  FAIL - macOS COACH: неожиданные зависимости\n'; exit 1
fi
: > "$work/calls"
PRESET_ID=expert-team
_deps_debian
if grep -q 'python-check' "$work/calls" && grep -q 'ffmpeg' "$work/calls"; then
  printf '  ok   - дополнительная сборка сохранила прежние зависимости\n'
else
  printf '  FAIL - дополнительные сборки потеряли зависимости\n'; exit 1
fi

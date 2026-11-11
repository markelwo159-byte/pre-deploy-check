#!/usr/bin/env bash
# Self-test: builds a broken project and a clean project, runs the gate on both,
# and checks that the broken one is blocked and the clean one passes.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$HERE/pre-deploy-check.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
fail=0

# broken project: committed key, committed .env, risky call
mkdir -p "$W/bad" && cd "$W/bad" && git init -q
printf 'import os\nKEY = "sk-ant-api03-%s"\nos.system("ls")\n' "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456" > app.py
printf 'SECRET=abc\n' > .env
git add -A && git -c user.email=t@t -c user.name=t commit -qm init
out="$("$GATE" "$W/bad")"; code=$?
[ "$code" = 1 ] || { echo "FAIL: broken project should exit 1, got $code"; fail=1; }
echo "$out" | grep -q '^FAIL  secrets' || { echo "FAIL: secret not caught"; fail=1; }
echo "$out" | grep -q '^FAIL  env-files' || { echo "FAIL: committed .env not caught"; fail=1; }
echo "$out" | grep -q '^WARN  risky-code' || { echo "FAIL: os.system not flagged"; fail=1; }

# clean project
mkdir -p "$W/good" && cd "$W/good"
printf 'def add(a, b):\n    return a + b\n' > app.py
out="$("$GATE" "$W/good")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: clean project should exit 0, got $code"; echo "$out"; fail=1; }

[ "$fail" = 0 ] && echo "selftest: all checks passed"
exit "$fail"

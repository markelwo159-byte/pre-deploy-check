#!/usr/bin/env bash
# ship-check: a pre-ship quality and security gate for finished code.
# Pipeline: secrets -> static -> dependencies -> unit/integration -> end-to-end -> performance -> ship.
#
# Usage:
#   ./ship-check.sh <project-dir> [--url https://site.example] [--perf-max 2.0] [--report report.md]
#
# Exit code: 0 when nothing FAILED (WARN and SKIP are allowed), 1 otherwise.

set -u

PROJECT=""
URL=""
PERF_MAX="2.0"
REPORT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="${2:-}"; shift 2 ;;
    --perf-max) PERF_MAX="${2:-2.0}"; shift 2 ;;
    --report) REPORT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) PROJECT="$1"; shift ;;
  esac
done

if [ -z "$PROJECT" ] || [ ! -d "$PROJECT" ]; then
  echo "usage: $0 <project-dir> [--url URL] [--perf-max SECONDS] [--report FILE]" >&2
  exit 2
fi
PROJECT="$(cd "$PROJECT" && pwd)"

RESULTS=()      # "STATUS|stage|detail"
FAILED=0

record() {      # record STATUS stage detail
  RESULTS+=("$1|$2|$3")
  [ "$1" = "FAIL" ] && FAILED=1
  printf '%-5s %-14s %s\n' "$1" "$2" "$3"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Files to scan: tracked files if this is a git repo, otherwise everything outside vendor/build folders.
list_files() {
  if git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$PROJECT" ls-files -co --exclude-standard | sed "s|^|$PROJECT/|"
  else
    find "$PROJECT" -type f \
      -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/.venv/*' \
      -not -path '*/venv/*' -not -path '*/__pycache__/*' -not -path '*/dist/*' -not -path '*/build/*'
  fi
}

FILES="$(list_files)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$FILES" | while IFS= read -r f; do
  [ -f "$f" ] || continue
  # skip binaries and big files
  case "$f" in *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.zip|*.gz|*.mp4|*.mov|*.glb|*.wasm|*.woff|*.woff2|*.ttf|*.db|*.sqlite) continue ;; esac
  sz=$(wc -c < "$f" 2>/dev/null || echo 0)
  [ "$sz" -gt 2000000 ] && continue
  printf '%s\n' "$f"
done > "$TMP/text_files"

echo "ship-check: $PROJECT"
echo "------------------------------------------------------------"

# 1. Secrets ---------------------------------------------------------------
SECRET_RE='(AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-ant-[A-Za-z0-9_-]{20,}|sk-(proj-)?[A-Za-z0-9]{32,}|gh[pousr]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|shpat_[a-f0-9]{32}|(api[_-]?key|secret|token|password)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9/+_=-]{16,}["'"'"'])'
if [ -s "$TMP/text_files" ]; then
  tr '\n' '\0' < "$TMP/text_files" | xargs -0 grep -EnI "$SECRET_RE" 2>/dev/null \
    | grep -viE 'example|placeholder|your[_-]?key|xxxx|<redacted>|ship-check\.sh' > "$TMP/secrets" || true
fi
if [ -s "$TMP/secrets" ]; then
  record FAIL secrets "$(wc -l < "$TMP/secrets" | tr -d ' ') possible secret(s): $(head -3 "$TMP/secrets" | sed "s|$PROJECT/||" | cut -c1-100 | tr '\n' ';')"
else
  record PASS secrets "no keys, tokens or private keys found in $(wc -l < "$TMP/text_files" | tr -d ' ') files"
fi

ENV_TRACKED=""
if git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ENV_TRACKED="$(git -C "$PROJECT" ls-files | grep -E '(^|/)\.env(\..*)?$' | grep -vE '\.example$|\.sample$' || true)"
fi
if [ -n "$ENV_TRACKED" ]; then
  record FAIL env-files ".env file committed to git: $(echo "$ENV_TRACKED" | tr '\n' ' ')"
else
  record PASS env-files "no .env files tracked by git"
fi

# 2. Static checks ----------------------------------------------------------
PY_FILES="$(grep -E '\.py$' "$TMP/text_files" || true)"
if [ -n "$PY_FILES" ] && have python3; then
  bad=0
  while IFS= read -r f; do
    python3 -m py_compile "$f" 2>>"$TMP/pyerr" || bad=$((bad+1))
  done <<< "$PY_FILES"
  if [ "$bad" -gt 0 ]; then record FAIL python-syntax "$bad file(s) fail to compile: $(head -2 "$TMP/pyerr" | tr '\n' ' ' | cut -c1-160)"
  else record PASS python-syntax "$(echo "$PY_FILES" | wc -l | tr -d ' ') Python files compile"; fi
else
  record SKIP python-syntax "no Python files"
fi

JS_FILES="$(grep -E '\.(js|cjs)$' "$TMP/text_files" | grep -v '\.min\.js$' || true)"
if [ -n "$JS_FILES" ] && have node; then
  bad=0
  while IFS= read -r f; do
    node --check "$f" 2>>"$TMP/jserr" || bad=$((bad+1))
  done <<< "$JS_FILES"
  if [ "$bad" -gt 0 ]; then record FAIL js-syntax "$bad file(s) fail to parse: $(head -2 "$TMP/jserr" | tr '\n' ' ' | cut -c1-160)"
  else record PASS js-syntax "$(echo "$JS_FILES" | wc -l | tr -d ' ') JavaScript files parse"; fi
else
  record SKIP js-syntax "no JavaScript files (or node not installed)"
fi

RISKY_RE='(eval\(|new Function\(|innerHTML[[:space:]]*=|subprocess\.[a-z_]+\([^)]*shell[[:space:]]*=[[:space:]]*True|os\.system\(|pickle\.loads?\(|yaml\.load\([^)]*\)$|verify[[:space:]]*=[[:space:]]*False)'
if [ -s "$TMP/text_files" ]; then
  grep -E '\.(py|js|ts|jsx|tsx|mjs|cjs)$' "$TMP/text_files" | tr '\n' '\0' \
    | xargs -0 grep -EnI "$RISKY_RE" 2>/dev/null > "$TMP/risky" || true
fi
if [ -s "$TMP/risky" ]; then
  record WARN risky-code "$(wc -l < "$TMP/risky" | tr -d ' ') risky pattern(s) to review (eval, innerHTML, shell=True, verify=False...): $(head -2 "$TMP/risky" | sed "s|$PROJECT/||" | cut -c1-100 | tr '\n' ';')"
else
  record PASS risky-code "no eval/innerHTML/shell=True/verify=False patterns"
fi

# 3. Dependencies ------------------------------------------------------------
if [ -f "$PROJECT/package-lock.json" ] && have npm; then
  if (cd "$PROJECT" && npm audit --audit-level=high >"$TMP/npmaudit" 2>&1); then
    record PASS npm-audit "no high or critical advisories"
  else
    if grep -qiE 'high|critical' "$TMP/npmaudit"; then record FAIL npm-audit "$(grep -iE 'vulnerabilit' "$TMP/npmaudit" | tail -1)"
    else record WARN npm-audit "audit could not run (offline?)"; fi
  fi
elif [ -f "$PROJECT/package.json" ]; then
  record WARN npm-audit "package.json without package-lock.json: versions are not pinned"
else
  record SKIP npm-audit "no Node dependencies"
fi

if ls "$PROJECT"/requirements*.txt >/dev/null 2>&1 || [ -f "$PROJECT/pyproject.toml" ]; then
  if have pip-audit; then
    if (cd "$PROJECT" && pip-audit -r "$(ls "$PROJECT"/requirements*.txt 2>/dev/null | head -1)" >"$TMP/pipaudit" 2>&1); then
      record PASS pip-audit "no known vulnerable Python packages"
    else
      record FAIL pip-audit "$(tail -1 "$TMP/pipaudit")"
    fi
  else
    record WARN pip-audit "pip-audit not installed (pip install pip-audit) so Python deps were not checked"
  fi
else
  record SKIP pip-audit "no Python requirements file"
fi

# 4. Unit and integration tests ------------------------------------------------
ran_tests=0
if [ -n "$PY_FILES" ] && { [ -d "$PROJECT/tests" ] || ls "$PROJECT"/test_*.py >/dev/null 2>&1 || [ -f "$PROJECT/pytest.ini" ]; }; then
  ran_tests=1
  if have python3 && python3 -c "import pytest" 2>/dev/null; then
    if (cd "$PROJECT" && python3 -m pytest -q --ignore=tests/e2e >"$TMP/pytest" 2>&1); then
      record PASS unit-tests "pytest: $(tail -1 "$TMP/pytest")"
    else
      record FAIL unit-tests "pytest: $(tail -1 "$TMP/pytest")"
    fi
  else
    record WARN unit-tests "tests exist but pytest is not installed"
  fi
fi
if [ -f "$PROJECT/package.json" ] && grep -q '"test"[[:space:]]*:' "$PROJECT/package.json" \
   && ! grep -qE '"test"[[:space:]]*:[[:space:]]*"echo \\"Error: no test specified' "$PROJECT/package.json"; then
  ran_tests=1
  if (cd "$PROJECT" && npm test --silent >"$TMP/npmtest" 2>&1); then
    record PASS unit-tests "npm test passed"
  else
    record FAIL unit-tests "npm test: $(tail -2 "$TMP/npmtest" | tr '\n' ' ' | cut -c1-160)"
  fi
fi
for t in "$PROJECT"/tests/*.sh; do
  [ -x "$t" ] || continue
  ran_tests=1
  if "$t" >"$TMP/shtest" 2>&1; then
    record PASS unit-tests "$(basename "$t"): $(tail -1 "$TMP/shtest")"
  else
    record FAIL unit-tests "$(basename "$t"): $(tail -1 "$TMP/shtest")"
  fi
done
[ "$ran_tests" = 0 ] && record WARN unit-tests "no test suite found: every piece should have tests before it ships"

# 5. End-to-end ---------------------------------------------------------------
if ls "$PROJECT"/playwright.config.* >/dev/null 2>&1; then
  if [ -x "$PROJECT/node_modules/.bin/playwright" ]; then
    if (cd "$PROJECT" && ./node_modules/.bin/playwright test >"$TMP/e2e" 2>&1); then
      record PASS e2e "Playwright: $(grep -E 'passed|failed' "$TMP/e2e" | tail -1)"
    else
      record FAIL e2e "Playwright: $(grep -E 'passed|failed' "$TMP/e2e" | tail -1)"
    fi
  else
    record WARN e2e "playwright.config found but Playwright not installed (npm i -D @playwright/test)"
  fi
elif [ -d "$PROJECT/tests/e2e" ] && have python3 && python3 -c "import pytest" 2>/dev/null; then
  if (cd "$PROJECT" && python3 -m pytest -q tests/e2e >"$TMP/e2e" 2>&1); then
    record PASS e2e "pytest e2e: $(tail -1 "$TMP/e2e")"
  else
    record FAIL e2e "pytest e2e: $(tail -1 "$TMP/e2e")"
  fi
else
  record WARN e2e "no end-to-end tests: have an agent click every real user path (sign in, add, pay, etc.)"
fi

# 6. Performance ----------------------------------------------------------------
if [ -n "$URL" ]; then
  if have curl; then
    times=()
    for i in 1 2 3 4 5; do
      t=$(curl -s -o /dev/null -w '%{time_total}' --max-time 30 "$URL" || echo 30)
      times+=("$t")
    done
    median=$(printf '%s\n' "${times[@]}" | sort -n | sed -n '3p' | awk '{printf "%.2f", $1}')
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$URL" || echo 000)
    if [ "$code" -ge 400 ] 2>/dev/null || [ "$code" = "000" ]; then
      record FAIL perf "$URL returned HTTP $code"
    elif awk "BEGIN{exit !($median > $PERF_MAX)}"; then
      record FAIL perf "median load ${median}s is over the ${PERF_MAX}s limit (HTTP $code)"
    else
      record PASS perf "median load ${median}s over 5 requests (limit ${PERF_MAX}s, HTTP $code)"
    fi
  else
    record SKIP perf "curl not available"
  fi
else
  record SKIP perf "no --url given"
fi

# Report --------------------------------------------------------------------------
echo "------------------------------------------------------------"
if [ "$FAILED" = 1 ]; then VERDICT="DO NOT SHIP: fix every FAIL first"; else VERDICT="OK TO SHIP (review any WARN)"; fi
echo "$VERDICT"

if [ -n "$REPORT" ]; then
  {
    echo "# ship-check report"
    echo
    echo "Project: \`$PROJECT\`  "
    echo "Run: $(date '+%Y-%m-%d %I:%M %p')"
    echo
    echo "| Result | Stage | Detail |"
    echo "| --- | --- | --- |"
    for r in "${RESULTS[@]}"; do
      IFS='|' read -r s st d <<< "$r"
      echo "| $s | $st | $(echo "$d" | sed 's/|/\\|/g') |"
    done
    echo
    echo "**Verdict:** $VERDICT"
  } > "$REPORT"
  echo "report written to $REPORT"
fi

exit "$FAILED"

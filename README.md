# Pre-Deploy Security & Test Check

**A security and quality check I run on every finished project before it goes live.**

AI coding agents write code fast. Fast is not the same as safe or production-ready. So before anything I build is deployed, it has to pass the same kind of checks a professional engineering team runs:

```
security scan → code checks → dependency audit → unit & integration tests → end-to-end tests → speed test → deploy
```

If any check fails, the project is not deployed until it's fixed.

## What it checks

| Check | What it does |
| --- | --- |
| **Leaked secrets** | Scans every file for API keys, passwords, tokens and private keys (AWS, Anthropic, OpenAI, GitHub, Slack, Google, Shopify and generic `api_key = "..."`). Fails if a `.env` secrets file was committed. |
| **Code checks** | Every Python file compiles and every JavaScript file parses. Flags risky code to review: `eval`, `innerHTML =`, `shell=True`, `os.system`, `pickle.load`, `verify=False`. |
| **Dependency audit** | Checks third-party packages for known security vulnerabilities (`npm audit`, `pip-audit`). Warns when versions aren't pinned. |
| **Unit & integration tests** | Runs the project's test suite. Warns if a project has no tests at all. |
| **End-to-end tests** | Runs browser tests (Playwright) that click through real user paths: sign in, add to cart, pay. If a project doesn't have them yet, it says so. |
| **Speed test** | Loads the live page five times and fails if it's slower than the limit (2 seconds by default). |

The result is either **OK TO DEPLOY** or **DO NOT DEPLOY**. Warnings don't block, but each one needs a decision.

## How to run it

```bash
./pre-deploy-check.sh path/to/project
./pre-deploy-check.sh path/to/project --url https://my-site.example --perf-max 1.5 --report report.md
```

It exits with `0` when nothing failed and `1` otherwise, so it can also run automatically on every code push (see [`ci/pre-deploy-check.yml`](ci/pre-deploy-check.yml)).

## The human-style review

A script can only catch so much. [`skill/SKILL.md`](skill/SKILL.md) is a Claude Code skill that runs the script, then walks a written security and reliability review over the code:
- user input is validated
- every change to data is permission-checked
- outside content is escaped before it's shown
- network calls have timeouts and retries
- scheduled jobs can safely run twice
- a crash mid-run can recover
- bulk changes have limits
- money uses exact math
- anything running unattended has monitoring on it

## Example

A project with a leaked key, a committed `.env` file and a failing test:

```
FAIL  secrets        1 possible secret(s): app.py:2:API_KEY = "sk-ant-api03-...";
FAIL  env-files      .env file committed to git: .env
PASS  python-syntax  2 Python files compile
WARN  risky-code     1 risky pattern(s) to review: app.py:5:os.system("ls");
FAIL  unit-tests     pytest: 1 failed in 0.02s
WARN  e2e            no end-to-end tests
------------------------------------------------------------
DO NOT DEPLOY: fix every FAIL first
```

`tests/selftest.sh` builds a broken project and a clean one and confirms the check blocks the first and passes the second.

Built with Claude Code by [Mark Elwood](https://markelwo159-byte.github.io/ai-portfolio/).

# ship-check

A pre-ship quality and security gate for AI-built code.

AI coding agents write code fast. That is not the same as production quality. Before anything I build goes live, it runs through the same pipeline a good engineering team uses:

```
push → unit → integration → end-to-end → performance → ship
```

plus security checks up front. If anything fails, it doesn't ship.

## What it checks

| Stage | What it does |
| --- | --- |
| **Secrets** | Scans every tracked file for API keys, tokens and private keys (AWS, Anthropic, OpenAI, GitHub, Slack, Google, Shopify, generic `api_key = "..."`). Fails if a `.env` file is committed. |
| **Static** | Every Python file compiles, every JavaScript file parses. Flags risky patterns: `eval`, `innerHTML =`, `shell=True`, `os.system`, `pickle.load`, `verify=False`. |
| **Dependencies** | `npm audit` for high and critical advisories, `pip-audit` for Python. Warns when versions aren't pinned. |
| **Unit / integration** | Runs the project's `pytest` or `npm test` suite. Warns when there is no suite at all. |
| **End-to-end** | Runs Playwright (or `tests/e2e` with pytest) so real user paths get clicked in a real browser. |
| **Performance** | Times five requests to a live URL and fails if the median is over budget (2 seconds by default). |

The verdict is **DO NOT SHIP** if any stage fails. Warnings are allowed, but each one needs a decision.

## Usage

```bash
./ship-check.sh path/to/project
./ship-check.sh path/to/project --url https://my-site.example --perf-max 1.5 --report report.md
```

Exit code is `0` when nothing failed and `1` otherwise, so it works as a CI step (see [`ci/ship-check.yml`](ci/ship-check.yml)).

## The review half

The script catches what a machine can catch. [`skill/SKILL.md`](skill/SKILL.md) is a Claude Code skill that runs the script, then walks a written security and robustness protocol over the changed code: input validation, auth on every write, escaped output, timeouts and retries, idempotent scheduled jobs, restart-safe state, guard rails on bulk changes, exact math for money, and a watcher on anything that runs unattended.

## Example

```
FAIL  secrets        1 possible secret(s): app.py:2:API_KEY = "sk-ant-api03-...";
FAIL  env-files      .env file committed to git: .env
PASS  python-syntax  2 Python files compile
WARN  risky-code     1 risky pattern(s) to review: app.py:5:os.system("ls");
FAIL  unit-tests     pytest: 1 failed in 0.02s
WARN  e2e            no end-to-end tests
------------------------------------------------------------
DO NOT SHIP: fix every FAIL first
```

Built with Claude Code by [Mark Elwood](https://markelwo159-byte.github.io/ai-portfolio/).

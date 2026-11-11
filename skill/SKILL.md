---
name: ship-check
description: Run the pre-ship quality and security gate on finished code before it goes live. Use when the user says a project, feature or script is done, asks to "ship-check", "run security checks", "check before deploy", or wants a security and robustness review of finished code.
---

# ship-check

A finished change is not done until it passes this gate. The order matters: push, unit, integration, end-to-end, performance, then ship.

## 1. Run the automated gate

```bash
~/Documents/ship-check/ship-check.sh <project-dir> --report <project-dir>/ship-check-report.md
# add --url https://... for anything with a live page or endpoint (performance check, 2s default limit)
```

Any FAIL blocks the ship. Fix it, then run the gate again. WARN items need a decision you state out loud: fix it, or explain why it is acceptable.

## 2. Claude review protocol (read the code, not just the tests)

Go through every changed file and check each item. Report findings with file and line.

**Security**
- No secrets in code, logs or committed files. Keys come from environment variables or a secrets file that is git-ignored.
- Every outside input is validated: form fields, query strings, uploaded files, webhook bodies, CSV/Excel/PDF rows, LLM output.
- No string-built SQL or shell commands. Use parameters and argument lists.
- Auth and permission checks on every route or action that changes data. Nothing trusts a client-side check alone.
- Rendered user or model content is escaped (no raw innerHTML with outside data).
- Third-party calls use HTTPS with certificate checks on, timeouts, and the least-privilege token.
- Personal data (customer names, emails, addresses, payment info) never lands in logs, URLs or analytics.

**Robustness**
- Every network call has a timeout, a retry with backoff where it is safe, and a clear failure path.
- Jobs that run on a schedule are idempotent: running twice does not double-charge, double-post or double-write.
- State survives a restart: a crash mid-run resumes or rolls back cleanly.
- Errors are logged with enough context to trace them, and alert someone when they matter.
- Bulk changes have guard rails: a cap on how much can change in one run, and a dry-run mode.
- Money, prices and quantities use exact math (integers or decimals, not floats) and are range-checked.
- A watcher exists for anything that runs unattended: is it alive, is its data fresh, are its results sane.

**Tests (the pipeline)**
- Unit: every piece has tests for normal input, edge cases and bad input.
- Integration: the pieces work together against realistic data.
- End-to-end: an agent clicks every real user path (sign in, add to cart, pay, submit) in a real browser.
- Performance: the main page or job finishes inside its budget. Five seconds at checkout is a failure.

## 3. Report

Give a short verdict first: SHIP or DO NOT SHIP. Then the FAIL and WARN items with file:line and the fix. Save the gate's report next to the project.

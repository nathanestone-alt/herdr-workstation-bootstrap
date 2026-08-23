# Issue #8 — Phase K pinned-Node correction dispatch

- Controlling issue: `nathanestone-alt/herdr-workstation-bootstrap#8`
- Correction base: `493e5b6b9ddc3f0211c25f901ca23de016fd3fe8`
- Blocking review: `audit/findings/2026-08-23_issue-8_pinned-node_cross-review-block.md`
- Raw review return: `/tmp/issue-8-pinned-node-final-review-return.md` (`sha256:7f4176ff83b89b46f7d0a285bac0bc3967fa766de523399a031af1b481dfae50`)
- Builder route: OpenAI / `gpt-5.6-luna` / reasoning `max` / service tier `priority`
- Required return: `/tmp/issue-8-verify-node-correction-return.md`

## Objective

Correct the one P1 from the independent review: `scripts/ubuntu/verify.sh` must invoke the managed npm and Codex JavaScript entrypoints through the already trusted pinned Node binary everywhere they execute under the system-only hermetic PATH. Add realistic regression coverage so Bash stand-ins cannot mask the defect.

## Authorized writes

- `scripts/ubuntu/verify.sh`
- `tests/test-verify-path.sh`
- `tests/test-install-payload.sh` only if its fixture or assertion surface is required to exercise the same Phase K behavior
- this return artifact under `/tmp`

Do not modify bootstrap transaction logic, receipt schemas, trust policy, documentation, locks, unrelated tests, or any workbook/STModel repository surface.

## Required boundaries

1. Preserve the system-only PATH. Do not add the Node prefix to PATH.
2. Use the pinned Node binary already admitted by the verify trust checks; do not rediscover an ambient interpreter.
3. Route only JavaScript entrypoints (`npm` and `codex`) through Node. Native/Bun executables such as Claude, Bun, RTK, Python, PowerShell, and Herdr must remain directly executed.
4. Preserve ownership, mode, realpath, hash, descriptor, receipt, argv/output parsing, and failure accounting behavior.
5. Apply the correction to every live execution site in `verify.sh`, including receipt runtime probes and the versions block.
6. Model npm and Codex with realistic `npm-cli.js` / `codex.js` entrypoints using `#!/usr/bin/env node`. Include a positive marker proving pinned-Node execution, parity assertions, and a negative control proving direct ambient-shebang execution fails under the hermetic PATH.
7. Keep the change minimal and do not address the reviewer’s separately disposed P3 items.

## Required checks

- focused verify fixture suite(s), including realistic positive and negative controls
- `bash tests/test-bootstrap-tools.sh`
- `bash tests/test-bootstrap-profile.sh`
- `bash tests/test-python-toolchain.sh`
- `pwsh -NoProfile -File scripts/Validate-Repository.ps1`
- `git diff --check`
- clean worktree and exact committed candidate SHA

## Terminal boundary

Commit the clean candidate, record the exact SHA and all check results in `/tmp/issue-8-verify-node-correction-return.md`, and return only this assigned workflow to the orchestrator. Do not perform independent review, create or control another pane/worktree, dispatch downstream work, run sudo/root gates, install, push, merge, mutate GitHub, close an issue, or restamp a baseline.

# Issue #8 correction dispatch — pinned Node invocation for Codex probes

- Owner/orchestrator: `STM-T-O1` (`w1:p1`)
- Assigned builder: `STM-T-B1` (`w1:p24`)
- Controlling issue: `nathanestone-alt/herdr-workstation-bootstrap#8`
- Repository/worktree: `/home/nathan/code/herdr-workstation-bootstrap-worktrees/issue-8`
- Branch: `codex/issue-8-receipt-authority`
- Starting HEAD: `c91c09abcb03d645cec3227d6ce0174f3ff3402c`
- Blocked candidate: `f3fcbb863a65d13256ca459ff308e2eba16088c4`
- Findings: `audit/findings/2026-08-23_issue-8_node-npm_cross-review-blocked-attempt.md`
- Disposition: `audit/findings/2026-08-23_issue-8_node-npm_cross-review-attempt-disposition.md`
- Route: OpenAI / `gpt-5.6-luna` / max / priority

## Required correction

Keep the npm correction unchanged. Fix both accepted blockers:

1. Execute the locked Codex JS entrypoint through the already validated pinned Node binary everywhere the tools transaction probes or records Codex under the hermetic PATH (currently the post-install version check and both transaction/finalize manifest snapshots).
2. Make the focused tools fixture model Codex as a realistic `#!/usr/bin/env node` entrypoint routed through the fixture Node dispatcher, with markers that prove pinned-Node execution. The fixture must fail against direct ambient-shebang execution.

Confirm the exact locked Codex package shape used by the repository. Do not route ELF executables (`claude`, `bun`, `bunx`) through Node. Do not add a user-writable path to PATH or weaken fences, ownership, hashes, descriptors, or identity checks.

## Allowed writes

- `scripts/ubuntu/bootstrap.sh`
- directly relevant shell test(s) under `tests/`

No other repository or host writes are permitted beyond the required `/tmp` return artifact.

## Required verification

- `bash -n scripts/ubuntu/bootstrap.sh tests/test-bootstrap-tools.sh`
- `bash tests/test-bootstrap-tools.sh`
- `bash tests/test-bootstrap-profile.sh`
- `bash tests/test-python-toolchain.sh`
- `pwsh -NoProfile -File scripts/Validate-Repository.ps1`
- `git diff --check`

Do not run sudo/root gates; the orchestrator owns them after independent review.

## Terminal boundary

Commit the clean correction and return `/tmp/issue-8-codex-node-correction-return.md` with the exact candidate SHA and native exit codes. Do not review, dispatch, control panes, push, merge, install, mutate GitHub, or use sudo. End after completing only the assigned workflow.

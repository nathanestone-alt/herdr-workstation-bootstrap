# Issue #8 — receipt runtime sealing terminal verdict

Date: 2026-08-23

## Candidate

- Repository: `nathanestone-alt/herdr-workstation-bootstrap`
- Branch: `codex/issue-8-receipt-authority`
- Base: `710e2ca`
- Final substantive candidate: `90f40c6ca17823f8ab9e2c23216d0b0bdf1a478f`
- Scope: privileged receipt handoff hardening; sealed directory-backed PowerShell and locked Python runtime bundles; root-fixture fidelity corrections.

## Root gates

- `sudo -n bash tests/test-receipt-authority.sh`: PASS.
  - Log: `/tmp/issue-8-90edc93-root-receipt.log`
  - SHA-256: `81f2bb5baa22836a41f42c07ba315cfa54a97bf43ef93f4b53f4ed6df8cf04cc`
  - The subsequent candidate change touched only `tests/test-bootstrap-tools.sh`.
- `sudo -n bash tests/test-bootstrap-tools.sh`: PASS.
  - Log: `/tmp/issue-8-90f40c6-root-tools.log`
  - SHA-256: `e58f63a5b1e8f6943048ac2abbc99804cf96bf0c0cb8c5415f101bb195b43850`

## Independent cross-review

- Resolved route: Anthropic / `claude-opus-5` / high / normal; fast mode disabled.
- Exact detached candidate: `90f40c6ca17823f8ab9e2c23216d0b0bdf1a478f`.
- Verdict: `PASS FOR CROSS-REVIEW`.
- Blocking findings: none (`0 P1`, `0 P2`).
- Artifact: `audit/findings/2026-08-23_issue-8_receipt-bundle_cross-review-final.md`.
- Source artifact SHA-256: `98e77f605a1682c8c79df7ca6a986ff358dac6ebea9d1499c21a03525b74e4e9`.

All five P3 findings are accepted as non-blocking and preserved in the full report:

1. Root fixtures use uniquely named, prefix-guarded directories under the live trusted staging root because production ancestry requires that chain.
2. Three mutation tests can conflate the preparatory writable-mode change with the named mutation, but still prove fail-closed post-staging rejection.
3. The sealed-bundle symlink policy is stricter than the legacy manifest builder and real-layout coverage is synthetic; the behavior is fail-closed.
4. Receipt authority inherits `umask 022` from the trusted launcher before explicit chmod; adding an intrinsic `umask 077` is a recommended follow-up.
5. Production-scale Python bundle cost is unmeasured; this is performance-only and should be timed after installation.

## Context-independent neutral runner

- Resolved route: OpenAI / `gpt-5.6-luna` / max / priority.
- Exact detached candidate: `90f40c6ca17823f8ab9e2c23216d0b0bdf1a478f`.
- Verdict: `PASS FOR NEUTRAL RUNNER`.
- `git diff --check`: PASS.
- All 26 tracked shell files under `scripts/` and `tests/`: `bash -n` PASS.
- All 14 `tests/test-*.sh` suites: exit 0; expected non-root root-only skips recorded.
- Initial and final HEAD/status: exact and clean.
- Artifact: `audit/findings/2026-08-23_issue-8_receipt-bundle_neutral-runner-final.md`.
- Source artifact SHA-256: `deaf9ddeabd052157d9c7372b9b14fe9b62bbc0d8dcd5e6a067fd75b963c7593`.

## D-GOV-12 terminality

The substantive candidate is `90f40c6ca17823f8ab9e2c23216d0b0bdf1a478f`. Adding these review, runner, and terminal-verdict records is evidence-only and does not create a new substantive review candidate. Any later substantive-surface change reopens cross-review.

## Verdict

PASS FOR MERGE/INSTALL AUTHORIZATION



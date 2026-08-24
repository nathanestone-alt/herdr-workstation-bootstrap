# Issue #8 — source-snapshot correction terminal verdict

Date: 2026-08-24

## Final substantive candidate

- Repository: `nathanestone-alt/herdr-workstation-bootstrap`
- Branch: `codex/issue-8-receipt-authority`
- Evidence baseline: `7642442b8a75dc10dec16136a4705b91da9536b5`
- Production correction: `2a8b77f02e490e43b52cde16e25c5d359c5f02f7`
- Final candidate: `daf84bfac353c01e510e1825709295ac90589561`
- Final delta after the production correction is test-only: `tests/test-bootstrap-fencing.sh`.

## Trigger and correction

The trusted launcher passed live base and tools at the prior candidate, but the standalone receipt-authority install failed closed because hardened source attestation created its snapshot below `/tmp`, then correctly rejected that ancestry. The production correction moves snapshots beneath validated, capability-bound managed staging, carries the prelude manifest and commit into the main phase, and removes the invalid second snapshot of a hardened `.git`-less tree. A later neutral BLOCK found two fencing fixture calls missing explicit fixture-root binding; the final test-only correction supplies that binding.

## Root evidence

- Root receipt suite: PASS at `2a8b77f`.
  - SHA-256: `59cf286fd134a68faa64d57ccb36d2810b5ab1cd0e73d4f7006a4895ca3e9133`
- Root tools suite: PASS at `2a8b77f`.
  - SHA-256: `13592da69d2c507b806dbac44ea2a9521f49b2e0617fba091e8db1f0551d7915`
- These remain applicable to `daf84bf` because its only change is the non-root fencing fixture.

## Independent review chain

1. Opus 5 high, normal tier, fast disabled reviewed the production correction at `2a8b77f`.
   - Verdict: `PASS FOR CROSS-REVIEW`
   - Blocking findings: none.
   - Seven P3 findings were accepted and retained in the full report.
   - Artifact SHA-256: `a40881764e907ffe5fca7f15225c2835c4b801d1de9124b21f0cfb3664c0792e`
2. The first neutral runner BLOCKED at `2a8b77f` on `tests/test-bootstrap-fencing.sh`, correctly stopping after test 1.
   - Artifact SHA-256: `3a0c78db8dcb934aad076736c3c565571af4f06be361471bb36a2164770f349b`
   - Disposition: resolved by `daf84bf`.
3. A fresh Opus 5 high, normal-tier, fast-disabled review inspected exactly `2a8b77f..daf84bf`.
   - Verdict: `PASS FOR CROSS-REVIEW`
   - Blocking findings: none.
   - Five P3 findings were accepted and retained in the full report.
   - Artifact SHA-256: `365fd055f282f047ed8bf8795225b1f7a655c61c223934744c38f1f8935f928e`

## Final neutral runner

- Route: OpenAI / `gpt-5.6-luna` / max / priority.
- Exact detached candidate: `daf84bfac353c01e510e1825709295ac90589561`.
- Verdict: `PASS FOR NEUTRAL RUNNER`.
- `git diff --check`: PASS.
- Tracked shell syntax: 26/26 PASS.
- Sequential non-root suites: 14/14 PASS; expected root-only SKIPs accepted.
- Prior unsafe fencing diagnostic: absent.
- Initial and final candidate identity/status: exact and clean.
- Artifact SHA-256: `8ccef6bf21a2399b2b0d98939647c34ce377a66e30b5d83e78592b5e44b30c0e`.

## Remaining live acceptance

Before issue closure, re-pin the trusted launcher to `daf84bf`, run live base/tools as required for the new pin, then capture the exact standalone receipt-authority install and verify entrypoint. Any failure blocks terminal closure.

## D-GOV-12

The substantive candidate is `daf84bfac353c01e510e1825709295ac90589561`. Adding review, runner, and terminal-verdict records is evidence-only. Any later substantive-surface change reopens cross-review.

## Verdict

PASS FOR RE-PIN AND LIVE ACCEPTANCE

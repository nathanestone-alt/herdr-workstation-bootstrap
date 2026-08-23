# Issue #8 — terminal Node lifecycle validation

- Substantive candidate: `e73d92779ed0d3f1633d1401d4ae189ef350f425`
- Branch: `codex/issue-8-receipt-authority`
- Date: 2026-08-23 UTC
- Verdict: **PASS**

## Independent cross-review

Opus 5 high, normal service tier, fast mode disabled, reviewed the exact detached candidate in `/tmp/herdr-bootstrap-issue-8-review-e73d927` through tracked workflow `[WF:9e3980e5]`.

- Verdict: `PASS FOR CROSS-REVIEW`
- Artifact: `/tmp/issue-8-tools-node-path-cross-review-r3.md`
- SHA-256: `7caac67952a9bc342e5b1a55d88d7bb26cadb77b23b1e9badd725e932143f4fd`
- Blocking findings: none (`0 P1`, `0 P2`)
- Prior P1-1, P1-2, P2-1 and P3-1 through P3-6: resolved or held.
- P3-7 accepted: all traced divergence branches are fail-closed or same-UID-equivalent, and the candidate does not regress the reviewed trust boundary.
- P3-8 accepted: it is a missing fault-injection regression for an early-exit cleanup path; the cleanup ordering was proved empirically and the successful-path no-residue assertion remains tracked.

## Context-independent neutral runner

The headless OpenAI `gpt-5.6-luna` / max / priority runner inspected the exact clean detached candidate in `/tmp/herdr-bootstrap-issue-8-neutral-e73d927`.

- Verdict: `PASS FOR NEUTRAL RUNNER`
- Artifact: `/tmp/issue-8-tools-node-path-neutral.md`
- SHA-256: `81c63ca8153bc53e784642c3005016dad1896ae40d1c13c6f05cdadf5bd63fbb`
- All nine prescribed syntax, tools, fencing, verify-path, trusted-launcher, and repository checks returned zero.
- The candidate SHA and clean status matched before and after execution.

## Final root suites

All suites ran through the authenticated B1 shell with `sudo -n` and returned zero.

| Suite | Log | SHA-256 |
|---|---|---|
| `tests/test-bootstrap-privilege-model.sh` | `/tmp/issue-8-e73-root-privilege.log` | `5419a9ba19f44c79dafa50b615f8a31f95a3c656eb996e78dad25bd593c15731` |
| `tests/test-trusted-launcher.sh` | `/tmp/issue-8-e73-root-trusted.log` | `9aa0379dccfb54b544e1cdf65afc657d25bcfaba8f1553094d73f1b40056abb6` |
| `tests/test-receipt-authority.sh` | `/tmp/issue-8-e73-root-receipt.log` | `6e257b4eafb1646b6ca19af2caf4d0fcb800f296061762637573c2d2ecc7a18b` |
| `tests/test-bootstrap-fencing.sh` | `/tmp/issue-8-e73-root-fencing.log` | `9d8c1bacca09b8ff0cdffcda850766f944b5f5bff7b5d13e4df1df93cc8717ef` |

## D-GOV-12 terminality

The only change recorded here after candidate `e73d927` is this evidence file. No source, test, lock, launcher, receipt, or installation surface changed after terminal cross-review. This evidence-only record does not create a new review candidate.

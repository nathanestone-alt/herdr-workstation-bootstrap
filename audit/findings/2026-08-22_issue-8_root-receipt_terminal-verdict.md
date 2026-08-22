# Issue #8 root receipt authority — terminal verdict

- Controlling issue: `nathanestone-alt/herdr-workstation-bootstrap#8`
- Write lane: audit/evidence only
- Substantive candidate: `294b09e6ed088b3567d96d27d116e2d87d2c2ee1`
- Candidate parent: `86a14069d5cf65ca2ca3571aa595661bfd502a17`
- Evidence receipt commit: `6dbb949460e454d682e44999dd1bca579e35916d`
- Branch: `codex/issue-8-receipt-authority`

## Independent evidence

The bounded Anthropic / `claude-opus-5` / high / normal-tier cross-review passed at the exact substantive candidate. It reported no P1 or P2 findings.

- Full review: `audit/findings/2026-08-22_issue-8_root-receipt_cross-review-r5.md`
  - SHA-256: `99ab11ebc159c42ea54c8fbaeda0e64df43747a93c09f989f5b78566a0424545`
- P3 correction re-review: `audit/findings/2026-08-22_issue-8_root-receipt_p3-rereview.md`
  - SHA-256: `f284025b8746cf6c2d7da26ea23b7cca9f1889ec70db1b6e64a164b886711b13`
  - Workflow: `[WF:2369b600]`
  - Completion return body-read ACK: true
- Independent OpenAI / `gpt-5.6-luna` / max / priority neutral runner: `audit/findings/2026-08-22_issue-8_root-receipt_neutral-runner-final.md`
  - SHA-256: `c84f5cbbb9fa35aa0044343afa9994a30ae0bd441ceacf6bfe7ee019caf8b851`
  - Result: PASS

The root-required gate on parent `86a14069d5cf65ca2ca3571aa595661bfd502a17` completed with anchored `__R5_ROOT_RC__=0` for:

```text
sudo -n bash tests/test-receipt-authority.sh
sudo -n bash tests/test-bootstrap-fencing.sh
sudo -n bash tests/test-trusted-launcher.sh
```

The final substantive correction is test-only (`tests/test-trusted-launcher.sh`). The neutral runner reran all three suites without root and received PASS; root-only sections skipped as designed. No production or installer surface changed after the successful root gate.

## P3 disposition

- P3-1: fixed in `294b09e6`; exact status 24 and exact diagnostic are asserted for invalid and empty selectors.
- P3-4: fixed in `294b09e6`; the two explicitly named load-bearing blobs are pinned to Git mode `100755`.
- P3-2, P3-3, P3-5, P3-6, and P3-7: accepted for the reasons recorded in the independent review; none regressed.
- P3-8: accepted for this candidate. Extending the Git-mode pin to `bootstrap.sh` and `verify.sh` would strengthen fail-closed availability coverage, but both are `100755` now and the residual does not weaken integrity or the reviewed two-blob correction.
- P3-9: accepted. This is a documentation-comment nit; the assertion and failure message remain self-describing.

## D-GOV-12 terminal validation

The receipt delta from `294b09e6` to `6dbb9494` contains exactly these evidence-only Markdown files:

```text
audit/findings/2026-08-22_issue-8_root-receipt_cross-review-r5.md
audit/findings/2026-08-22_issue-8_root-receipt_neutral-runner-final.md
audit/findings/2026-08-22_issue-8_root-receipt_p3-rereview.md
```

- `git diff --check 294b09e6..6dbb9494`: PASS
- `git diff --exit-code 294b09e6..6dbb9494 -- scripts tests config`: PASS
- Candidate `scripts`, `tests`, `config` tree objects:
  - `57fca32d9e324d259491f996472d0cdf4860e0a7`
  - `04c605611a886a0bca1f625074992ef8c6d5f7a4`
  - `cdeebf5e703d15b0fc3175322d6de13c000c6a21`
- Receipt `scripts`, `tests`, `config` tree objects are identical, in the same order.
- Branch and worktree were clean at validation start.

This terminal verdict is itself an evidence-only Markdown receipt. Under D-GOV-12 it does not create a new substantive candidate and is not independently re-reviewed.

## Verdict

**PASS FOR MERGE, PUSH, PINNED INSTALLATION, AND ISSUE CLOSURE.**

Installation must remain pinned to substantive candidate `294b09e6ed088b3567d96d27d116e2d87d2c2ee1`, not to a later evidence-only receipt commit. Merge, push, install, and issue closure proceed only under the user's explicit authorization already recorded in the controlling thread.

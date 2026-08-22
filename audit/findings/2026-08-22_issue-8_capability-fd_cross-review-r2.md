# Issue 8 capability-fd correction cross-review r2

## Verdict

`PASS FOR CROSS-REVIEW`

- Candidate: `b00684d5a555dba432a9e9d08f8f3ef692f1da7d`
- Parent: `793fdf8855484acb25818435352c14764a9fe33a`
- Repository: `nathanestone-alt/herdr-workstation-bootstrap`
- Review worktree: `/tmp/herdr-bootstrap-issue-8-review-b00684d`
- Review route: Anthropic / `claude-opus-5` / high / normal non-fast
- Review artifact: `/tmp/herdr-bootstrap-issue-8-cross-review-b00684d.md`

## Scope and checks

The reviewer independently inspected the exact three-file `+152/-42` correction, the complete capability helper, and the verify/bootstrap/receipt/trusted-launcher binding surfaces. The following checks passed:

- `bash tests/test-verify-path.sh`
- `bash tests/test-trusted-launcher.sh`
- `bash tests/test-bootstrap-fencing.sh`
- `bash tests/test-receipt-authority.sh`
- `pwsh -NoProfile -File scripts/Validate-Repository.ps1`
- `bash -n` on all changed shell files
- `git diff --check`

A negative control grafted the blocked parent's helper into the candidate test tree. Bootstrap fencing then failed with the expected policy-grammar/status-24 regression, proving the former false PASS is caught.

## Findings

- P1: none.
- P2: none.

The reviewer verified that repeat binding safely reuses readonly validated captures while all identity, ownership, path, fd, parent, and entry checks rerun; exact-byte/NUL/offset edge cases fail closed; no production policy-content reopen remains; and the full validator executes verify-path.

## P3 dispositions

1. Environment-seeded cache values can synthetically skip the first parse. Production uses `env -i`, and descriptor/path/ownership/parent checks remain mandatory. Accepted for commissioning as defense-in-depth; follow up by binding cache reuse to readonly provenance or clearing cache globals before first bind.
2. The lifetime hash reconstruction from readonly values is tautological. Descriptor size/mtime identity provides the actual mutation evidence. Accepted as dead defensive code; remove or annotate in follow-up.
3. The static reopen guard remains a denylist with synthetic bypasses. Exact production code has no reopen and behavioural coverage passes. Accepted as test-defense residual; prefer structural allowlisting in follow-up.
4. The root-only `setpriv` fixture was correct by inspection but not executed at uid 1000. Accepted provisionally and required during root commissioning before issue closure.

Residual same-size/same-mtime in-place mutation by root is accepted under the root-owned 0600 policy trust model. Windows-only, root-gated, and Python-unavailable skips remain recorded in the review artifact.

PASS FOR CROSS-REVIEW

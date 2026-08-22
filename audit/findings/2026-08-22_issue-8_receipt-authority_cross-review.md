# Issue #8 — independent cross-review of receipt authority and RTK publication

- Candidate: `e2d7cdd52cb4ba22ec1a659d5b270b82c3a8b6c3`
- Parent: `c9a049bae4b50501c1c88b5f7a2d0b84110e4294`
- Cumulative baseline: `32b06865c97096df4593ebd81e969135728b08dd`
- Worktree: `/tmp/herdr-bootstrap-issue-8-review-e2d7cdd` (clean, detached, read-only)
- Route: Anthropic / `claude-opus-5` / high / normal non-fast
- Source artifact: `/tmp/herdr-bootstrap-issue-8-cross-review-e2d7cdd.md`

## Verdict

**PASS FOR CROSS-REVIEW.** No P1 or P2 findings.

The reviewer verified that all six requested P3 corrections were genuine:

- non-tautological `env -i` validation;
- identity- and canonical-path-bound installer staging cleanup;
- bounded receipt race wait;
- exact sentinel extraction;
- fail-closed RTK archive contract, retaining the upstream-evidence limitation as P3;
- realistic RTK target-replacement race coverage.

Previously blocking capability, `receipt_awk_bin`, RTK provenance, tools/RTK/receipt integration,
apt descriptor, root-drop, publication, archive-rejection, profile, and no-source-build predicates
were re-audited and remained intact.

## Accepted P3 dispositions

- **P3-A — RTK digest evidence wording.** The lockfile can state more plainly that the pinned RTK
  digest lacks an independently retained upstream measurement. Accepted because checksum, archive
  shape, executable mode, and exact version all fail closed. The residue is first-run availability,
  not unintended installation.
- **P3-B — sentinel tail assertion.** The guard does not assert that the dispatch block remains the
  file tail. Accepted because the current discarded remainder is proved empty and extraction is
  exact and fail-closed; retain as future test hardening.
- **P3-C — staging-file interruption window.** A kill between staging-path assignment and inode
  capture can leave one root-owned staging file. Accepted because cleanup refuses unsafe deletion,
  the parent is root-only mode `0755`, and the window does not create a privilege escalation.
- **P3-D — publish-failure diagnostic specificity.** The fixture does not assert the exact
  diagnostic. Accepted because it proves nonzero exit and no residue, while the replacement case is
  covered separately.
- **P3-E — receipt-race comment wording.** A comment says fail closed although the executable proof
  is successful descriptor immunity. Accepted as comment-only debt; assertions are correct.
- **P3-F — host-wide same-prefix test glob.** Accepted as same-user test hygiene only; no production
  behavior or security predicate depends on it.
- **P3-G — descriptor-number reuse clarity.** The receipt command relies on fd-number reuse after
  close/reopen. Accepted because a mismatch fails closed and the adversarial race fixture passes;
  refactoring would be clarity-only.

## Limits

Root-gated branches were skipped at uid 1000. The reviewer had no network authority to confirm the
pinned RTK release digest/archive; the implementation remains fail-closed and P3-A records that
evidence limitation.

Terminal verdict: **PASS FOR CROSS-REVIEW**

# Independent cross-review — issue #923 (R2)

Candidate: `cf5364fa81633aa8bcf458056c0eb52652811f8d`
Base: `86f4bce75f44281702f08e16d956651929aee16a`
Candidate first parent: `21aa284f2a8eb4fcded9a7cae74f20f16f2d7818`
Scope: `git diff 86f4bce75f44281702f08e16d956651929aee16a cf5364fa81633aa8bcf458056c0eb52652811f8d`

## Prior P2 disposition

The prior report at `refs/reviews/923/21aa284f-adapter-cross-review-r1` identified
the unqualified Herdr completion gate at `SKILL.md:85-87`. R2 changes that contract
to require the selected adapter to return the complete result body, with Herdr
completion and return-body acknowledgement required only when Herdr is selected or
explicitly requested (`SKILL.md:85-89`). The new regression assertion checks both
adapter-neutral and Herdr-qualified phrases (`scripts/test_st_herdr_dispatch.ps1:62-68`).

## Checks

- `pwsh -NoProfile -File scripts/test_st_herdr_dispatch.ps1` — PASS.
- `git diff --check 86f4bce75f44281702f08e16d956651929aee16a cf5364fa81633aa8bcf458056c0eb52652811f8d` — PASS.
- The complete base-to-candidate diff remains limited to `SKILL.md`,
  `references/herdr-workflow.md`, and `scripts/test_st_herdr_dispatch.ps1`.
- Candidate checkout was clean before and after the checks; no candidate or installed
  files were modified.

## Findings

P1: none.

P2: none. The prior P2 is resolved, and the adapter-neutral completion rule does not
force Herdr ACK/return mechanics onto native adapters.

P3: none.

## Verdict

PASS FOR CROSS-REVIEW

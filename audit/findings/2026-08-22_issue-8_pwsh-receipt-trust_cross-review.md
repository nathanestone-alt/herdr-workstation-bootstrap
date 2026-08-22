# Issue #8 — PowerShell and receipt trust cross-review

- Candidate: `3b65a2a8b3d99d09d0d570cb25d5b842ce9285d0`
- Immediate parent: `bfec382971dbe98351d28d184843410dc1c82879`
- Arc base: `b694eae65cbbecabd10ad3fb42101968868df572`
- Workflow: `[WF:310c16d8]`
- Route: Anthropic / `claude-opus-5` / high / normal non-fast
- Final artifact: `/tmp/herdr-bootstrap-cross-review-3b65a2a.md`
- Final artifact SHA-256: `31f93ba258c75897774e5238f595b2a232bc4c2f1eb093f98c69235460263b69`
- Prior blocking artifact: `/tmp/herdr-bootstrap-cross-review-bfec382.md`
- Prior artifact SHA-256: `1c8619c849d0baf85e2dc805b610dd14d281c587b3f2e82ea784f41c54c2677f`

## Verdict

**PASS FOR CROSS-REVIEW.** No P1 or P2 findings remain.

The reviewer inspected the exact detached candidate read-only, verified the whole
`b694eae..3b65a2a` arc, ran both focused suites as uid 1000, and used extracted byte-identical
trust seams only to exercise root-owned states unavailable in that context. The candidate tree
remained clean and unchanged.

## Blocking finding dispositions

- **P2-1 — fixed.** The packaged PowerShell `/opt` target now requires uid 0 and a root-owned,
  non-group/other-writable parent chain through `/`, while retaining regular-file, no-symlink,
  canonical identity, mode, and lifetime checks. Simulated root cases accepted the official target
  and rejected non-root ownership, writable immediate/mid-chain parents, and unsafe `/` state.
- **P2-2 — fixed.** The root-only production payload-stage regression genuinely omits
  `--fixture-root`, mutates one tracked stage entry to mode `0664`, asserts the exact production
  trust diagnostic, and restores the original mode before later fixture-mode cases.

## Prior P3 dispositions

- **P3-1 — fixed.** Canonical-absent fallback acceptance and hostile fallback symlink rejection
  are now covered.
- **P3-2 — accepted follow-up.** PowerShell is still resolved before package installation and is
  not descriptor-bound across replacement. This is pre-existing availability/lifetime debt and
  is not widened by the candidate.
- **P3-3 — accepted follow-up.** `--fixture-root` remains caller-supplied and unvalidated in the
  prelude. The capability layer independently requires root payload authority, and the only parser
  desynchronization path exits at the unknown-argument guard before the affected probe.
- **P3-4 — fixed.** The prelude now reads `receipt_prelude_fixture_root`, closing the latent
  main-body-scope `set -u` hazard.

## New non-blocking P3 dispositions

- **P3-5 — accepted operational requirement.** The two PowerShell ownership regressions and the
  production payload-stage regression skip loudly outside root. Commissioning must run them as
  root; the non-root review does not claim them as PASS.
- **P3-6 — accepted follow-up.** The new uid/parent-chain enforcement is scoped to the canonical
  `/opt` PowerShell target; generalizing it to every trusted system seam is separate hardening.
- **P3-7 — accepted follow-up.** Owner and mode are sampled by separate `stat` calls. Exploitation

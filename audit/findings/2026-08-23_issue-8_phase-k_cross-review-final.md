# Issue #8 Phase K pinned-Node — independent cross-review final

- Workflow: `[WF:19ffcb3c]`; return relay `[HR:5bb80ee2]`
- Reviewer: `w1:p10` (`STM-T-C1`), session `7e5b1e1f-23c3-4d65-b71e-61413d15c064`
- Route: Anthropic / `claude-opus-5` / high reasoning / normal service tier; fast mode disabled
- Candidate: `164da46011b12e476d236ebe276f22a53fe58374`
- Evidence base: `371090d3eae4c224caddb1ded81963b9674bc13d`
- Detached worktree: `/tmp/herdr-bootstrap-issue-8-review-164da46`
- Raw return: `/tmp/issue-8-phase-k-final-review-return.md`
- Raw return SHA-256: `afb623545baf69bc9a67250ec6c2c72cc140fe35a0845b165280536b215998b5`
- Verdict: **PASS FOR CROSS-REVIEW**

## Integrity and validation

The reviewer proved the detached worktree remained clean at the exact candidate before and after review. All required commands passed: syntax checks, verify-path, bootstrap-tools, bootstrap-profile, Python toolchain, full repository validator, and `git diff --check`.

Two independent `git archive` negative controls also passed their purpose: fully reverting `verify_run_command` made the verify-path suite fail on both npm and Codex receipt probes; partially reverting only Codex routing made the suite fail on Codex. The linked worktree was never mutated.

## Findings

No P1 or P2 findings.

The six P3 items were explicitly disposed:

1. The versions block retains informational `|| true`; authoritative receipt probes remain fail-accounted and covered, so no change.
2. Missing Node and a tool exit of 1 share a caller status, but both fail closed and Node has separate target/receipt diagnostics; acceptable.
3. `npx` and `corepack` remain latent aliases, absent from the resolver allowlist and all live probes; no change.
4. npm/Codex arms in generic exact-version checking are not currently called, but routing the generic helper makes future use correct by default; retain.
5. Locked Codex `0.148.0` wrapper shape is inherited from directly observed adjacent packaging; any incompatible ELF shape fails loudly during bootstrap and receipt verification, so acceptable.
6. The fixture's explicit chmod list is hand-maintained but exactly covers regular fixture files and fails noisily on omission; retain.

## Verdict basis

Every live npm/Codex JavaScript execution under Phase K's system-only PATH now passes through the already trusted pinned Node. Native and Bun tools remain direct. Node resolution stays within the existing containment boundary; argv, output, exit status, failure accounting, receipt parity, PATH, descriptor, capability, privilege, and launcher boundaries are preserved. Realistic fixtures and independent revert controls prove the regression is load-bearing.

This PASS authorizes only the orchestrator's neutral-runner and deterministic gate legs. It does not authorize merge, push, installation, issue closure, or baseline restamp by a worker/reviewer.

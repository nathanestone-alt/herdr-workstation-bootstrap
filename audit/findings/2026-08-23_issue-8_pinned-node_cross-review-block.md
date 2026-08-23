# Issue #8 pinned-Node correction — independent cross-review block

- Workflow: `[WF:1d4dddff]`
- Return relay: `[HR:1c396828]`
- Reviewer: `w1:p10` (`STM-T-C1`), session `f7add8ad-f302-4f32-8437-d340a3873c21`
- Route: Anthropic / `claude-opus-5` / high reasoning / normal service tier; fast mode absent
- Candidate: `e13532e69e8100c6fb27899cdf4e3c5cdba10920`
- Detached review worktree: `/tmp/herdr-bootstrap-issue-8-review-e13532e`
- Raw return artifact: `/tmp/issue-8-pinned-node-final-review-return.md`
- Raw artifact SHA-256: `7f4176ff83b89b46f7d0a285bac0bc3967fa766de523399a031af1b481dfae50`
- Verdict: **BLOCK FOR CORRECTION**

## Integrity and checks

The reviewer proved the detached worktree remained clean at exact candidate SHA before and after review. The correction diff itself passed `git diff --check`. Independent non-root checks all returned zero:

- `bash tests/test-bootstrap-tools.sh`
- `bash tests/test-bootstrap-profile.sh`
- `bash tests/test-python-toolchain.sh`
- `pwsh -NoProfile -File scripts/Validate-Repository.ps1` (root-only suites skipped as expected)

## Blocking finding

**P1 — Phase K verification still launches JavaScript entrypoints through ambient shebangs.**

`scripts/ubuntu/verify.sh` deliberately keeps `PATH=/usr/sbin:/usr/bin:/sbin:/bin`, resolves the managed `npm` and `codex` aliases, then executes those aliases directly in both receipt probes and the versions block. Their real entrypoints are `npm-cli.js` and `codex.js`, each using `#!/usr/bin/env node`. On a correctly bootstrapped host without `/usr/bin/node`, both direct probes reproduce exit 127. The receipt probes therefore mark runtime verification failed; the versions block silently suppresses the same failure.

The current verify fixtures mask the defect by modeling `npm` and `codex` as Bash scripts. Correction must route only these JavaScript entrypoints through the pinned Node binary and add realistic npm/Codex fixture coverage plus an ambient-shebang negative control, without weakening the system-only PATH, descriptor, ownership, hash, receipt, or privilege boundaries.

## Non-blocking dispositions

- `npx` and `corepack` are latent managed aliases with no live hermetic-PATH execution site; no change in this correction.
- The unused `bootstrap_exec_node` helper and residual user `.npmrc` influence are pre-existing and out of scope; retain as a separate follow-up concern.
- The existing bootstrap-tools negative control is adequate because its primary regression runs under the actual system-only PATH and the fixture exits distinctly if ambient Node is used.
- Heredoc escaping differences are cosmetic and empirically covered by manifest parity.
- Finalize-only manifest snapshots correctly rely on assertions already executed during tools-prepare.

Any substantive correction creates a new candidate and requires a fresh independent cross-review. No merge, push, installation, issue closure, or baseline restamp is authorized by this finding.

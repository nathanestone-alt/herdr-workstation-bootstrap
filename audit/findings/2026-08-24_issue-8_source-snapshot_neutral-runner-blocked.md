# Issue #8 Source-Snapshot Neutral Runner

## Route

- Role: deterministic neutral runner; write lane: read-only, with the single required receipt write under /tmp.
- Resolved worker: provider OpenAI; model gpt-5.6-luna; reasoning effort max; service tier priority.
- Capability profile: tooling-core.
- Controlling issue: nathanestone-alt/herdr-workstation-bootstrap#8.
- Exact detached worktree: /tmp/herdr-bootstrap-issue-8-neutral-2a8b77f.
- Exact candidate: 2a8b77f02e490e43b52cde16e25c5d359c5f02f7.
- Substantive correction base: 7642442b8a75dc10dec16136a4705b91da9536b5.
- Prior substantive baseline: 90f40c6ca17823f8ab9e2c23216d0b0bdf1a478f.
- Independent review: PASS FOR CROSS-REVIEW, /tmp/issue-8-source-snapshot-cross-review.md.

## Deterministic matrix

Identity and initial-state commands:

    pwd
    id -u
    id -un
    git rev-parse --show-toplevel
    git remote get-url origin
    git rev-parse --verify HEAD
    git symbolic-ref --quiet --short HEAD
    git status --porcelain=v1 --branch --untracked-files=all

Observed identity and initial state:

    pwd=/tmp/herdr-bootstrap-issue-8-neutral-2a8b77f
    uid=1000
    user=nathan
    repo=/tmp/herdr-bootstrap-issue-8-neutral-2a8b77f
    remote_origin=https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git
    HEAD=2a8b77f02e490e43b52cde16e25c5d359c5f02f7
    git symbolic-ref exit=1 (detached)
    git status: ## HEAD (no branch)
    initial status exit=0; no dirty or untracked paths

Diff command:

    git diff --check 7642442..2a8b77f

Result: exit 0; output empty.

Syntax command: for every tracked path selected by git ls-files whose path is under scripts/ or tests/ and ends in .sh, run bash -n "$path". Result: 26/26 passed, 0 failed.

| # | tracked shell | exit | result |
|---:|---|---:|---|
| 1 | scripts/ubuntu/bootstrap.sh | 0 | PASS |
| 2 | scripts/ubuntu/configure-excel-share.sh | 0 | PASS |
| 3 | scripts/ubuntu/configure-vps-client.sh | 0 | PASS |
| 4 | scripts/ubuntu/install-payload.sh | 0 | PASS |
| 5 | scripts/ubuntu/install-trusted-launcher.sh | 0 | PASS |
| 6 | scripts/ubuntu/launcher-capability.sh | 0 | PASS |
| 7 | scripts/ubuntu/receipt-authority.sh | 0 | PASS |
| 8 | scripts/ubuntu/rtk-release.sh | 0 | PASS |
| 9 | scripts/ubuntu/source-attestation.sh | 0 | PASS |
| 10 | scripts/ubuntu/trusted-launcher.sh | 0 | PASS |
| 11 | scripts/ubuntu/verify-vps-access.sh | 0 | PASS |
| 12 | scripts/ubuntu/verify.sh | 0 | PASS |
| 13 | tests/test-bootstrap-fencing.sh | 0 | PASS syntax |
| 14 | tests/test-bootstrap-privilege-model.sh | 0 | PASS syntax |
| 15 | tests/test-bootstrap-profile.sh | 0 | PASS syntax |
| 16 | tests/test-bootstrap-tools.sh | 0 | PASS syntax |
| 17 | tests/test-configure-excel-share-inputs.sh | 0 | PASS syntax |
| 18 | tests/test-configure-vps-client.sh | 0 | PASS syntax |
| 19 | tests/test-install-payload.sh | 0 | PASS syntax |
| 20 | tests/test-python-toolchain.sh | 0 | PASS syntax |
| 21 | tests/test-receipt-authority.sh | 0 | PASS syntax |
| 22 | tests/test-rtk-release.sh | 0 | PASS syntax |
| 23 | tests/test-tailscale-downgrade.sh | 0 | PASS syntax |
| 24 | tests/test-trusted-launcher.sh | 0 | PASS syntax |
| 25 | tests/test-verify-path.sh | 0 | PASS syntax |
| 26 | tests/test-verify-vps-access.sh | 0 | PASS syntax |

Test command: enumerate tests/test-*.sh in shell glob order and run bash "$test" sequentially as UID 1000; record the exit code; stop immediately on the first nonzero exit. Expected test count: 14. Executed: 1. Stopped: yes, at the first test with exit 1.

| # | test | exit | outcome |
|---:|---|---:|---|
| 1 | tests/test-bootstrap-fencing.sh | 1 | FAIL; first nonzero; stop |
| 2 | tests/test-bootstrap-privilege-model.sh | — | NOT RUN; stopped by required rule |
| 3 | tests/test-bootstrap-profile.sh | — | NOT RUN; stopped by required rule |
| 4 | tests/test-bootstrap-tools.sh | — | NOT RUN; stopped by required rule |
| 5 | tests/test-configure-excel-share-inputs.sh | — | NOT RUN; stopped by required rule |
| 6 | tests/test-configure-vps-client.sh | — | NOT RUN; stopped by required rule |
| 7 | tests/test-install-payload.sh | — | NOT RUN; stopped by required rule |
| 8 | tests/test-python-toolchain.sh | — | NOT RUN; stopped by required rule |
| 9 | tests/test-receipt-authority.sh | — | NOT RUN; stopped by required rule |
| 10 | tests/test-rtk-release.sh | — | NOT RUN; stopped by required rule |
| 11 | tests/test-tailscale-downgrade.sh | — | NOT RUN; stopped by required rule |
| 12 | tests/test-trusted-launcher.sh | — | NOT RUN; stopped by required rule |
| 13 | tests/test-verify-path.sh | — | NOT RUN; stopped by required rule |
| 14 | tests/test-verify-vps-access.sh | — | NOT RUN; stopped by required rule |

No root-only SKIP was reached or accepted because the first non-root test failed. The captured test output had no filtered PASS/SKIP/FAIL/ERROR/OK summary line.

## Final exactness and hashes

Final-state commands:

    git rev-parse --verify HEAD
    git status --porcelain=v1 --branch --untracked-files=all
    git symbolic-ref --quiet --short HEAD

Observed final state:

    HEAD=2a8b77f02e490e43b52cde16e25c5d359c5f02f7 (exact candidate)
    git symbolic-ref exit=1 (still detached)
    git status: ## HEAD (no branch)
    final status exit=0; clean

Hash command:

    for f in /tmp/issue-8-2a8b77f-root-receipt.log /tmp/issue-8-2a8b77f-root-tools.log /tmp/issue-8-source-snapshot-cross-review.md; do sha256sum "$f"; done

Required SHA-256 results:

    59cf286fd134a68faa64d57ccb36d2810b5ab1cd0e73d4f7006a4895ca3e9133  /tmp/issue-8-2a8b77f-root-receipt.log
    13592da69d2c507b806dbac44ea2a9521f49b2e0617fba091e8db1f0551d7915  /tmp/issue-8-2a8b77f-root-tools.log
    a40881764e907ffe5fca7f15225c2835c4b801d1de9124b21f0cfb3664c0792e  /tmp/issue-8-source-snapshot-cross-review.md

## Limitations and terminal assessment

- The required stop-on-first-nonzero rule left 13 test scripts unexecuted; they are listed above as NOT RUN rather than inferred passes.
- This run was non-root only and did not exercise root-only paths or mutate installed state.
- No repository files, Git refs, candidate content, GitHub state, permissions, or live installed state were changed.
- Candidate exactness and cleanliness passed, but the required test matrix did not pass because tests/test-bootstrap-fencing.sh returned exit 1.

BLOCK FOR CORRECTION

# Issue #8 — Final Deterministic Neutral Runner

## Route and scope

- Controlling issue: `nathanestone-alt/herdr-workstation-bootstrap#8`.
- Role: fresh final deterministic neutral runner.
- Write lane: read-only; the only write was this required receipt under `/tmp`.
- Exact detached worktree: `/tmp/herdr-bootstrap-issue-8-neutral-daf84bf`.
- Exact candidate: `daf84bfac353c01e510e1825709295ac90589561`.
- Correction base: `7642442b8a75dc10dec16136a4705b91da9536b`.
- Resolved worker: OpenAI / `gpt-5.6-luna` / max / priority.
- Capability profile: `tooling-core`.
- Candidate restrictions honored: no candidate edits, chmod, commit, dispatch,
  push, merge, install, sudo, GitHub mutation, or live-state mutation.

## Prior neutral BLOCK disposition

Prior receipt: `/tmp/issue-8-source-snapshot-neutral-runner.md`.

That run evaluated candidate `2a8b77f02e490e43b52cde16e25c5d359c5f02f7`,
stopped as required at test 1/14, and recorded:

```text
tests/test-bootstrap-fencing.sh: exit 1
receipt authority trust prelude: production source snapshot staging parent is not root-owned and
non-writable: /tmp/tmp.zqKCddwOfx/fixture/var/lib/herdr-workstation/bootstrap/staging
```

The failure was caused by both receipt-authority `--help` calls in the fencing
fixture omitting `--fixture-root`, which selected the production ancestry branch
for a non-root `/tmp` fixture. Candidate `daf84bf` changes only
`tests/test-bootstrap-fencing.sh`: both calls now pass
`--fixture-root "$fixture_root"`. The final independent review at
`/tmp/issue-8-fencing-final-cross-review.md` is `PASS FOR CROSS-REVIEW` and
confirms this is fixture-only correction with no production-code change.

Disposition: the prior BLOCK condition is resolved and revalidated below.

## Deterministic matrix

### 1. Exact detached HEAD, repository, uid, and clean proof

Observed in the candidate worktree before and after the test matrix:

```text
pwd=/tmp/herdr-bootstrap-issue-8-neutral-daf84bf
uid=1000
user=nathan
repo=/tmp/herdr-bootstrap-issue-8-neutral-daf84bf
worktree=true
bare=false
origin=https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git
HEAD=daf84bfac353c01e510e1825709295ac90589561
git symbolic-ref exit=1 (detached; no branch name)
git status: ## HEAD (no branch)
status exit=0; no dirty or untracked paths
```

### 2. Diff check

Command:

```text
git diff --check 7642442b8a75dc10dec16136a4705b91da9536b..daf84bfac353c01e510e1825709295ac90589561
```

Result: exit `0`, empty output.

The final correction delta from `2a8b77f` is one test-only path:
`tests/test-bootstrap-fencing.sh`. Its `git diff --check` also exited `0`.

### 3. Bash syntax matrix

Every tracked `scripts/**/*.sh` and `tests/**/*.sh` path was selected from Git
and checked with `bash -n`. Result: `26/26` passed, `0` failed.

| # | tracked shell | exit | result |
|---:|---|---:|---|
| 1 | `scripts/ubuntu/bootstrap.sh` | 0 | PASS |
| 2 | `scripts/ubuntu/configure-excel-share.sh` | 0 | PASS |
| 3 | `scripts/ubuntu/configure-vps-client.sh` | 0 | PASS |
| 4 | `scripts/ubuntu/install-payload.sh` | 0 | PASS |
| 5 | `scripts/ubuntu/install-trusted-launcher.sh` | 0 | PASS |
| 6 | `scripts/ubuntu/launcher-capability.sh` | 0 | PASS |
| 7 | `scripts/ubuntu/receipt-authority.sh` | 0 | PASS |
| 8 | `scripts/ubuntu/rtk-release.sh` | 0 | PASS |
| 9 | `scripts/ubuntu/source-attestation.sh` | 0 | PASS |
| 10 | `scripts/ubuntu/trusted-launcher.sh` | 0 | PASS |
| 11 | `scripts/ubuntu/verify-vps-access.sh` | 0 | PASS |
| 12 | `scripts/ubuntu/verify.sh` | 0 | PASS |
| 13 | `tests/test-bootstrap-fencing.sh` | 0 | PASS syntax |
| 14 | `tests/test-bootstrap-privilege-model.sh` | 0 | PASS syntax |
| 15 | `tests/test-bootstrap-profile.sh` | 0 | PASS syntax |
| 16 | `tests/test-bootstrap-tools.sh` | 0 | PASS syntax |
| 17 | `tests/test-configure-excel-share-inputs.sh` | 0 | PASS syntax |
| 18 | `tests/test-configure-vps-client.sh` | 0 | PASS syntax |
| 19 | `tests/test-install-payload.sh` | 0 | PASS syntax |
| 20 | `tests/test-python-toolchain.sh` | 0 | PASS syntax |
| 21 | `tests/test-receipt-authority.sh` | 0 | PASS syntax |
| 22 | `tests/test-rtk-release.sh` | 0 | PASS syntax |
| 23 | `tests/test-tailscale-downgrade.sh` | 0 | PASS syntax |
| 24 | `tests/test-trusted-launcher.sh` | 0 | PASS syntax |
| 25 | `tests/test-verify-path.sh` | 0 | PASS syntax |
| 26 | `tests/test-verify-vps-access.sh` | 0 | PASS syntax |

### 4. Sequential non-root test matrix

The authoritative run used the shell glob `tests/test-*.sh`, lexical order,
`bash "$test"`, uid `1000` (`nathan`), and stopped on the first nonzero. All
14 tests completed with exit `0`.

| # | test | exit | result |
|---:|---|---:|---|
| 1 | `tests/test-bootstrap-fencing.sh` | 0 | PASS |
| 2 | `tests/test-bootstrap-privilege-model.sh` | 0 | PASS; expected root-only SKIPs accepted |
| 3 | `tests/test-bootstrap-profile.sh` | 0 | PASS |
| 4 | `tests/test-bootstrap-tools.sh` | 0 | PASS; expected root-only SKIP accepted |
| 5 | `tests/test-configure-excel-share-inputs.sh` | 0 | PASS |
| 6 | `tests/test-configure-vps-client.sh` | 0 | PASS |
| 7 | `tests/test-install-payload.sh` | 0 | PASS |
| 8 | `tests/test-python-toolchain.sh` | 0 | PASS |
| 9 | `tests/test-receipt-authority.sh` | 0 | PASS; expected root-only SKIPs accepted |
| 10 | `tests/test-rtk-release.sh` | 0 | PASS |
| 11 | `tests/test-tailscale-downgrade.sh` | 0 | PASS |
| 12 | `tests/test-trusted-launcher.sh` | 0 | PASS; expected root-only SKIP accepted |
| 13 | `tests/test-verify-path.sh` | 0 | PASS |
| 14 | `tests/test-verify-vps-access.sh` | 0 | PASS |

No later test was skipped by failure; the suite reached `SUITE completed=14/14`.

### 5. Fencing correction confirmation

Focused authoritative rerun of `tests/test-bootstrap-fencing.sh` as uid 1000:

```text
fencing_exit=0
prior_unsafe_fixture_diagnostic_seen=no
bootstrap launcher fencing, dirty-checkout, forged-marker, and pre-line-10 tests passed.
```

The stable prefix of the prior diagnostic,
`receipt authority trust prelude: production source snapshot staging parent is
not root-owned and`, was absent from the captured output. The two expected
root-only PowerShell SKIPs were accepted.

### 6. Final exact HEAD and clean status

After the authoritative matrix and focused confirmation, the final candidate
identity remained:

```text
HEAD=daf84bfac353c01e510e1825709295ac90589561
git status --porcelain=v1 --branch --untracked-files=all:
## HEAD (no branch)
status exit=0
```

### 7. SHA-256 evidence

The required pre-existing evidence hashes are:

```text
59cf286fd134a68faa64d57ccb36d2810b5ab1cd0e73d4f7006a4895ca3e9133  /tmp/issue-8-2a8b77f-root-receipt.log
13592da69d2c507b806dbac44ea2a9521f49b2e0617fba091e8db1f0551d7915  /tmp/issue-8-2a8b77f-root-tools.log
a40881764e907ffe5fca7f15225c2835c4b801d1de9124b21f0cfb3664c0792e  /tmp/issue-8-source-snapshot-cross-review.md
365fd055f282f047ed8bf8795225b1f7a655c61c223934744c38f1f8935f928e  /tmp/issue-8-fencing-final-cross-review.md
```

This runner artifact's SHA-256 is computed after the final write and reported
separately, rather than embedded here (embedding it would change the hash).

## Limitations and execution notes

- Root-only branches were not exercised because the required run was non-root;
  their documented SKIPs returned exit `0` and were accepted.
- An initial in-sandbox attempt could not validate the fencing test because the
  sandbox remapped `/usr/bin` ownership to uid `65534` (`nobody`), causing the
  test's trusted-host check to report `Host uname is unavailable.` and exit 22.
  That attempt was not used as the matrix result. The authoritative rerun was
  outside that filesystem remapping while remaining uid 1000 and completed
  14/14.
- A prior isolated test-run transport also hit its host 300-second response
  ceiling before returning a matrix; it was not used as evidence.
- The carried-forward root logs remain applicable because the final candidate
  delta after `2a8b77f` is test-only, and the final independent review records
  that fact. No root recalculation or installed-state exercise was authorized
  or performed.
- No candidate content, Git refs, GitHub state, permissions, or live installed
  state were changed.

PASS FOR NEUTRAL RUNNER

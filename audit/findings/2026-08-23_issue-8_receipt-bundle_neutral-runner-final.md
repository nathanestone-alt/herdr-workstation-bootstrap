# Issue #8 Final Neutral Runner

## Scope and route

- Controlling issue: `nathanestone-alt/herdr-workstation-bootstrap#8`
- Exact detached worktree: `/tmp/herdr-bootstrap-issue-8-neutral-90f40c6`
- Candidate: `90f40c6ca17823f8ab9e2c23216d0b0bdf1a478f`
- Base: `710e2ca`
- Independent cross-review: `PASS FOR CROSS-REVIEW` (`/tmp/issue-8-final-cross-review.md`)
- `resolved_worker.provider`: `OpenAI`
- `resolved_worker.model`: `gpt-5.6-luna`
- `resolved_worker.reasoning_effort`: `max`
- `resolved_worker.service_tier`: `priority`
- `capability_profile`: `tooling-core`
- Runner boundary: read-only candidate validation; no edit, chmod, commit, dispatch, push, merge, install, sudo, GitHub mutation, or live installed-state mutation.

## Identity and clean-state proof

Commands were run from the exact worktree as the current non-root user.

| Command | Result |
|---|---|
| `pwd` | `/tmp/herdr-bootstrap-issue-8-neutral-90f40c6` |
| `id -u` | `1000` |
| `id -un` | `nathan` |
| `git rev-parse --show-toplevel` | `/tmp/herdr-bootstrap-issue-8-neutral-90f40c6` |
| `git config --get remote.origin.url` | `https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git` |
| `git rev-parse HEAD` (initial) | `90f40c6ca17823f8ab9e2c23216d0b0bdf1a478f` |
| `git status --porcelain=v1 --untracked-files=all` (initial) | empty; clean |

## Diff check

Command:

```text
git diff --check 710e2ca..90f40c6
```

Exit code: `0`.

## Tracked shell syntax matrix

The tracked-file enumerator was `git ls-files -z`; 26 tracked `.sh` files under `scripts/` and `tests/` were found. Every command below returned exit code `0`:

```text
bash -n scripts/ubuntu/bootstrap.sh
bash -n scripts/ubuntu/configure-excel-share.sh
bash -n scripts/ubuntu/configure-vps-client.sh
bash -n scripts/ubuntu/install-payload.sh
bash -n scripts/ubuntu/install-trusted-launcher.sh
bash -n scripts/ubuntu/launcher-capability.sh
bash -n scripts/ubuntu/receipt-authority.sh
bash -n scripts/ubuntu/rtk-release.sh
bash -n scripts/ubuntu/source-attestation.sh
bash -n scripts/ubuntu/trusted-launcher.sh
bash -n scripts/ubuntu/verify-vps-access.sh
bash -n scripts/ubuntu/verify.sh
bash -n tests/test-bootstrap-fencing.sh
bash -n tests/test-bootstrap-privilege-model.sh
bash -n tests/test-bootstrap-profile.sh
bash -n tests/test-bootstrap-tools.sh
bash -n tests/test-configure-excel-share-inputs.sh
bash -n tests/test-configure-vps-client.sh
bash -n tests/test-install-payload.sh
bash -n tests/test-python-toolchain.sh
bash -n tests/test-receipt-authority.sh
bash -n tests/test-rtk-release.sh
bash -n tests/test-tailscale-downgrade.sh
bash -n tests/test-trusted-launcher.sh
bash -n tests/test-verify-path.sh
bash -n tests/test-verify-vps-access.sh
```

## Sequential test matrix

Each command was executed as `bash tests/test-*.sh`, in the sorted order below, with no privilege elevation. Every completed before its runner safety ceiling and returned exit code `0`; the sequence completed without a nonzero result.

| # | Exact command | Exit | Result |
|---:|---|---:|---|
| 1 | `bash tests/test-bootstrap-fencing.sh` | 0 | PASS; explicit root-only PowerShell trust-regression SKIPs |
| 2 | `bash tests/test-bootstrap-privilege-model.sh` | 0 | PASS; explicit root-required SKIP |
| 3 | `bash tests/test-bootstrap-profile.sh` | 0 | PASS |
| 4 | `bash tests/test-bootstrap-tools.sh` | 0 | PASS; explicit root trusted-launcher tools-handoff SKIP |
| 5 | `bash tests/test-configure-excel-share-inputs.sh` | 0 | PASS |
| 6 | `bash tests/test-configure-vps-client.sh` | 0 | PASS |
| 7 | `bash tests/test-install-payload.sh` | 0 | PASS; output also contained `Terminated` from a fixture subprocess |
| 8 | `bash tests/test-python-toolchain.sh` | 0 | PASS |
| 9 | `bash tests/test-receipt-authority.sh` | 0 | PASS; explicit root-required receipt SKIP |
| 10 | `bash tests/test-rtk-release.sh` | 0 | PASS |
| 11 | `bash tests/test-tailscale-downgrade.sh` | 0 | PASS |
| 12 | `bash tests/test-trusted-launcher.sh` | 0 | PASS; explicit root-gated privilege-drop SKIP |
| 13 | `bash tests/test-verify-path.sh` | 0 | PASS |
| 14 | `bash tests/test-verify-vps-access.sh` | 0 | PASS |

The explicit skips are expected limitations of running as UID 1000; no skip was converted into a failure or hidden.

## Requested SHA-256 evidence

| File | Readable | Bytes | SHA-256 |
|---|---:|---:|---|
| `/tmp/issue-8-90edc93-root-receipt.log` | yes | 4566 | `81f2bb5baa22836a41f42c07ba315cfa54a97bf43ef93f4b53f4ed6df8cf04cc` |
| `/tmp/issue-8-90f40c6-root-tools.log` | yes | 208 | `e58f63a5b1e8f6943048ac2abbc99804cf96bf0c0cb8c5415f101bb195b43850` |
| `/tmp/issue-8-final-cross-review.md` | yes | 20823 | `98e77f605a1682c8c79df7ca6a986ff358dac6ebea9d1499c21a03525b74e4e9` |

## Final proof and limitations

Final commands:

```text
git rev-parse HEAD
git status --porcelain=v1 --untracked-files=all
```

Results:

- Final HEAD: `90f40c6ca17823f8ab9e2c23216d0b0bdf1a478f` (exact candidate; unchanged).
- Final status: empty; clean.
- The runner was non-root (`uid=1000`), so root-only branches explicitly reported SKIP and were not exercised.
- A preliminary single-call buffered matrix exceeded the context runner's 300-second RPC limit and yielded no usable report. It was not used as evidence for PASS; the authoritative checks above were then executed and recorded in bounded sequential batches.
- The requested artifact is outside the candidate worktree under `/tmp`; the candidate itself remained unmodified.

Terminal verdict: PASS
PASS FOR NEUTRAL RUNNER

# Issue #8 privilege transaction — root gate

- Controlling issue: `nathanestone-alt/herdr-workstation-bootstrap#8`
- Substantive candidate: `ca863b98902dca85f16513f9a934d4d1046b001c`
- Worktree: `/home/nathan/code/herdr-workstation-bootstrap-worktrees/issue-8`
- Executed: `2026-08-23T13:26:00Z`
- Execution context: cleared standing tooling builder pane `w1:p24` (`STM-T-B1`), plain host Bash, authenticated root via `sudo -n`

## Results

Each suite was invoked independently and emitted a unique numeric completion marker.

| Suite | Log | Completion marker | Result |
|---|---|---|---|
| `sudo -n bash tests/test-bootstrap-privilege-model.sh` | `/tmp/issue-8-root-privilege.log` | `__ROOT_PRIVILEGE_RC__=0` | PASS |
| `sudo -n bash tests/test-trusted-launcher.sh` | `/tmp/issue-8-root-launcher.log` | `__ROOT_LAUNCHER_RC__=0` | PASS |
| `sudo -n bash tests/test-receipt-authority.sh` | `/tmp/issue-8-root-receipt.log` | `__ROOT_RECEIPT_RC__=0` | PASS |
| `sudo -n bash tests/test-bootstrap-fencing.sh` | `/tmp/issue-8-root-fencing.log` | `__ROOT_FENCING_RC__=0` | PASS |

The host-level fencing run used real host ownership semantics and passed. This supersedes the earlier neutral sandbox false negative caused by UID remapping of root-owned system executables; the corrected independent host-neutral result is recorded separately.

## Verdict

All required root suites passed at the exact substantive candidate. No installation or repository mutation occurred as part of this gate.

`PASS FOR ROOT GATE`

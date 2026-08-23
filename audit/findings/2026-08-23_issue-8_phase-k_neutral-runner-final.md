# Issue #8 Phase K pinned-Node — neutral runner final

- Candidate: `164da46011b12e476d236ebe276f22a53fe58374`
- Final runner route: OpenAI / `gpt-5.6-luna` / max reasoning / priority service tier
- Final runner session: `01a02f74-432d-7d70-ab9e-17aae38c0c04`
- Exact detached worktree: `/tmp/herdr-bootstrap-issue-8-neutral-164da46`
- Final return: `/tmp/issue-8-phase-k-neutral-return.md`
- Final return SHA-256: `bd18ec0e57a8055587c46f2a8e284d137101938a8fb1262f40568915cd9dba7e`
- Harness logs: `/tmp/issue-8-phase-k-neutral-final.KWbQZe`
- Verdict: **PASS FOR NEUTRAL RUNNER**

## Adapter disposition

Two fresh attempts were preserved but are not candidate verdicts:

1. Global read-only sandbox: `/tmp/issue-8-phase-k-neutral-readonly-attempt.md`, SHA-256 `f7dec8a610e7e38ea29835050bd056d96e63d982f0084ee7a29679b0a7518943`. It could not create required `mktemp` fixtures because `/tmp` was read-only.
2. Workspace-write sandbox: `/tmp/issue-8-phase-k-neutral-sandbox-attempt.md`, SHA-256 `9d36b5243e4d61aa550b1d9808bc395b43357ecacf26366631ffb1ff7bc1ed22`. Six Bash checks and all source assertions passed, but the sandbox hid host executable/process boundaries (`Host uname is unavailable`), so the fencing fixture correctly failed closed.

The final fresh runner used the same explicit policy route outside the Codex filesystem sandbox and was restricted to one fixed deterministic harness. This was required because the fencing validator intentionally observes the real host boundary. No sudo, install, GitHub, Herdr-pane, or source mutation occurred.

## Final deterministic results

All seven required checks returned zero:

- `bash -n scripts/ubuntu/verify.sh`
- `bash -n tests/test-verify-path.sh`
- `bash tests/test-verify-path.sh`
- `bash tests/test-bootstrap-tools.sh`
- `bash tests/test-bootstrap-profile.sh`
- `bash tests/test-python-toolchain.sh`
- `pwsh -NoProfile -File scripts/Validate-Repository.ps1`

All 18 deterministic source assertions passed, covering npm/Codex-only routing through managed Node, direct native execution, both receipt probes, versions routing, realistic npm/Codex JS paths and shebangs, distinct markers, receipt parity, and ambient-shebang negative controls.

The worktree was clean at exact candidate SHA before and after the run; `git diff --check` passed and `FAILURES=0`.

This is the independent deterministic runner result required after the final cross-review. It does not itself authorize merge, push, installation, issue closure, or baseline restamp.

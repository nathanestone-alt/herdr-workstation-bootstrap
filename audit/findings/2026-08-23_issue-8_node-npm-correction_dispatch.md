# Issue #8 correction dispatch — pinned Node invocation for npm

- Owner/orchestrator: `STM-T-O1` (`w1:p1`)
- Assigned builder: `STM-T-B1` (`w1:p24`)
- Controlling issue: `nathanestone-alt/herdr-workstation-bootstrap#8`
- Repository: `nathanestone-alt/herdr-workstation-bootstrap`
- Worktree: `/home/nathan/code/herdr-workstation-bootstrap-worktrees/issue-8`
- Branch: `codex/issue-8-receipt-authority`
- Starting HEAD: `d8a6601806aeb7526660d6a6110c7a460fc61288`
- Prior substantive candidate: `ca863b98902dca85f16513f9a934d4d1046b001c`
- Route: OpenAI / `gpt-5.6-luna` / max / priority

## Proven defect

The live pinned tools transaction publishes RTK 0.45.0, then exits 127 while invoking npm. Host `strace -f -e execve` captured:

```text
execve("/proc/self/fd/17/bin/npm", ["/proc/self/fd/17/bin/npm", "install", ...]) = 0
execve("/usr/sbin/node", ["node", "/proc/self/fd/17/bin/npm", ...]) = -1 ENOENT
execve("/usr/bin/node", ["node", "/proc/self/fd/17/bin/npm", ...]) = -1 ENOENT
execve("/sbin/node", ["node", "/proc/self/fd/17/bin/npm", ...]) = -1 ENOENT
execve("/bin/node", ["node", "/proc/self/fd/17/bin/npm", ...]) = -1 ENOENT
```

The npm script uses `#!/usr/bin/env node`, but the transaction intentionally retains a system-only trusted PATH. The pinned Node binary exists at the already fenced `$node_anchor/bin/node`.

Evidence:

- `/tmp/issue-8-tools-execve.log`
- `/tmp/issue-8-install-tools-trace.log`
- failure marker `__INSTALL_TOOLS_TRACE_RC__=127`

## Required correction

Make the smallest production correction so npm is executed explicitly by the already validated pinned Node binary, without adding a user-writable directory to PATH and without weakening any fence, ownership, hash, or identity check. Add focused regression coverage proving npm execution does not depend on ambient `node` resolution.

## Allowed writes

- `scripts/ubuntu/bootstrap.sh`
- directly relevant shell test(s) under `tests/`
- this dispatch may be cited but not rewritten

No workbook or STModel repository writes are permitted.

## Required verification

- Relevant focused shell test(s)
- `bash tests/test-bootstrap-profile.sh`
- `bash tests/test-python-toolchain.sh`
- `pwsh -NoProfile -File scripts/Validate-Repository.ps1`
- `git diff --check`

Do not run sudo/root gates; the orchestrator owns the post-correction root gate and installation retry.

## Terminal boundary

Commit the clean correction, record the exact new candidate SHA, and return `/tmp/issue-8-node-npm-correction-return.md` with commands and native exit codes. Do not review, dispatch another worker, control or rename panes, push, merge, install, mutate GitHub, or alter host configuration. End after the committed builder return; the owning orchestrator performs cross-review and all downstream actions.

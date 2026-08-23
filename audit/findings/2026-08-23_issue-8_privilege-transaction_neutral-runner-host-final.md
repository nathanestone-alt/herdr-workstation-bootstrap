# PASS — deterministic neutral host validation

- Workflow: `[WF:9fbb7537]`
- Issue: `nathanestone-alt/herdr-workstation-bootstrap#8`
- Candidate: `ca863b98902dca85f16513f9a934d4d1046b001c`
- Base: `2e3a2cc63c2e81a2e695951687e385decd02b7a5`
- Worktree: `/tmp/herdr-bootstrap-issue-8-neutral-ca863b9`
- Execution profile: OpenAI `gpt-5.6-luna`, reasoning `max`, service tier `priority`
- Scope: `git diff base..candidate` only; candidate write access remained read-only.

## Host proof

Final ownership/permission proof exited `0` for every required binary. Each was a regular file, uid `0`, mode `755`, with no group/other write bits:

- `/usr/bin/realpath`
- `/usr/bin/stat`
- `/usr/bin/uname`
- `/usr/bin/grep`
- `/usr/bin/ps`

## Validation exits

- `bash -n scripts/ubuntu/bootstrap.sh`: `0`
- `bash -n scripts/ubuntu/trusted-launcher.sh`: `0`
- `bash -n tests/test-bootstrap-privilege-model.sh`: `0`
- `bash -n tests/test-bootstrap-profile.sh`: `0`
- `bash -n tests/test-python-toolchain.sh`: `0`
- `bash -n tests/test-tailscale-downgrade.sh`: `0`
- `bash -n tests/test-trusted-launcher.sh`: `0`
- `git diff --check 2e3a2cc63c2e81a2e695951687e385decd02b7a5..ca863b98902dca85f16513f9a934d4d1046b001c`: `0`
- `bash tests/test-bootstrap-profile.sh`: `0`
- `bash tests/test-bootstrap-fencing.sh`: `0` (documented uid-1000 root-only cases skipped)
- `bash tests/test-bootstrap-privilege-model.sh`: `0` (documented root-only case skipped)
- `bash tests/test-trusted-launcher.sh`: `0` (documented root-gated case skipped)
- `bash tests/test-receipt-authority.sh`: `0` (documented uid-1000 root-only cases skipped)
- `pwsh -NoProfile -File scripts/Validate-Repository.ps1`: `0` (documented Python-unavailable and platform/root-only skips)

## Final repository proof

- `git rev-parse HEAD`: `0`, exact candidate confirmed.
- `git symbolic-ref --short -q HEAD`: `1`, expected detached HEAD.
- `git status --porcelain=v1 --branch`: `0`, exactly `## HEAD (no branch)`.
- Combined final reconfirmation: `0`.

No edits, commits, pushes, merges, installs, GitHub mutations, pane control, or downstream dispatch were performed.

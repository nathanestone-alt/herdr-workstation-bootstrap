# Issue #8 — deterministic neutral runner round 2

- Workflow: `[WF:ea2a497a]`
- Completion relay: `[HR:7a5e8da7]`
- Candidate: `e2d7cdd52cb4ba22ec1a659d5b270b82c3a8b6c3`
- Parent: `c9a049bae4b50501c1c88b5f7a2d0b84110e4294`
- Worktree: `/tmp/herdr-bootstrap-issue-8-neutral-e2d7cdd` (clean, detached, unchanged)
- Route: OpenAI / `gpt-5.6-luna` / max / priority
- Source artifact: `/tmp/herdr-bootstrap-issue-8-neutral-runner-r2-e2d7cdd.md`
- Source artifact SHA-256: `b45022ccb99c4c4dbc01020274931b4dff838d2f226ff14e30d2ec7647f6c41d`

## Result

**PASS FOR NEUTRAL RUNNER.** All required checks exited 0. The candidate was not modified.

## Checks

- Exact cwd, detached candidate, parent, and clean-state proofs passed before and after validation.
- `bash -n` passed for every changed shell file in `c9a049b..e2d7cdd`.
- `git diff --check c9a049bae4b50501c1c88b5f7a2d0b84110e4294..e2d7cdd52cb4ba22ec1a659d5b270b82c3a8b6c3` exited 0.
- `bash tests/test-bootstrap-tools.sh` exited 0.
- `bash tests/test-trusted-launcher.sh` exited 0.
- `bash tests/test-receipt-authority.sh` exited 0.
- `bash tests/test-rtk-release.sh` exited 0.
- `pwsh -NoProfile -File scripts/Validate-Repository.ps1` ran exactly once through the native host
  shell with a 600-second bound and exited 0. Its captured log ended with
  `Repository validation passed.`

## Expected skips and warning

- Python syntax validation was skipped because Python was unavailable.
- Root-gated payload-authenticity and positive transaction tests were skipped at uid 1000.
- Root-gated launcher privilege-drop tests were skipped because root was unavailable.
- Windows ACL, path-policy, handle, process-identity, and Excel COM fixtures were skipped on Linux.

No unexpected warning or skip was observed. No edit, commit, push, merge, issue mutation, install,
sudo, network access, downstream dispatch, pane change, or route substitution occurred in the
neutral-runner context.

Terminal verdict: **PASS FOR NEUTRAL RUNNER**

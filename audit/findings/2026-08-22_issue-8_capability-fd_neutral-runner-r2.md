# Issue 8 capability-fd neutral runner r2

## Verdict

`PASS FOR NEUTRAL RUNNER`

- Candidate: `b00684d5a555dba432a9e9d08f8f3ef692f1da7d`
- Parent: `793fdf8855484acb25818435352c14764a9fe33a`
- Repository: `nathanestone-alt/herdr-workstation-bootstrap`
- Detached worktree: `/tmp/herdr-bootstrap-issue-8-neutral-b00684d`
- Route: OpenAI / `gpt-5.6-luna` / max / priority
- Passing artifact: `/tmp/herdr-bootstrap-issue-8-neutral-b00684d-r2.md`
- Initial adapter-block artifact: `/tmp/herdr-bootstrap-issue-8-neutral-b00684d-attempt1-block.md`

## Adapter disposition

The initial managed `workspace-write` Codex sandbox hid the trusted host `uname` path, causing bootstrap fencing to return environment status 22. That attempt was classified as a neutral-adapter block, not a candidate verdict. A single evidence-based retry preserved the same route and exact candidate while using host-capable `danger-full-access`. The retry runtime explicitly reported OpenAI `gpt-5.6-luna`, max effort, the exact worktree, and the priority-tier launch configuration.

## Required checks

All eight required checks exited 0:

1. `bash -n scripts/ubuntu/launcher-capability.sh tests/test-trusted-launcher.sh tests/test-bootstrap-fencing.sh`
2. `git diff --check HEAD^`
3. `bash tests/test-verify-path.sh`
4. `bash tests/test-trusted-launcher.sh`
5. `bash tests/test-bootstrap-fencing.sh`
6. `bash tests/test-receipt-authority.sh`
7. `bash tests/test-rtk-release.sh`
8. `pwsh -NoProfile -File scripts/Validate-Repository.ps1`

The full validator ended with `Repository validation passed.` The trusted-launcher suite explicitly reported exact-byte, NUL/byte-count, alias-reopen, substitution, and absence coverage passing.

## Negative control and cleanliness

The blocked parent helper blob `1e69c84ad3dfa8663b85a3bba677ff6779c3bfd8` was copied only into scratch. Bootstrap fencing exited 1 with the expected policy-grammar/status-24 messages. Before and after the runner, the candidate worktree was detached, exact, and clean.

Expected skips were root-gated tests at uid 1000, Windows-only checks, and Python syntax validation where Python was unavailable.

PASS FOR NEUTRAL RUNNER

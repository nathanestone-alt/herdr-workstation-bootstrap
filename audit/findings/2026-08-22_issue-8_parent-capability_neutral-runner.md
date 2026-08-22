# Issue 8 cross-UID parent-capability neutral runner

## Verdict

`PASS FOR NEUTRAL RUNNER`

- Candidate: `50970caa066c366aa245d2d4eddb91034afdc6d0`
- Parent: `9de6ef0a495c754969ce51b17a137acade894d69`
- Repository: `nathanestone-alt/herdr-workstation-bootstrap`
- Detached runner worktree: `/tmp/herdr-bootstrap-issue-8-neutral-50970ca`
- Route: OpenAI / `gpt-5.6-luna` / max / priority
- Final artifact: `/tmp/herdr-bootstrap-issue-8-neutral-50970ca-r4.md`
- Final artifact SHA-256: `460ee85b2814e2fb57a2e2deba8f64b439d0bebbe27ea78b3005f72f79c969b2`

## Deterministic checks

The first attempt ran the required checks individually after its aggregate
wrapper timed out. All focused checks passed:

1. Bash syntax for the capability, launcher, bootstrap, and touched tests.
2. Exact-parent `git diff --check`.
3. `tests/test-verify-path.sh`.
4. `tests/test-trusted-launcher.sh`, including the exact positive, missing,
   substituted, and role-distinction fd 12 coverage line.
5. `tests/test-bootstrap-fencing.sh`.
6. `tests/test-receipt-authority.sh`.
7. `tests/test-rtk-release.sh`.

The final non-PTY retry ran `pwsh -NoProfile -File
scripts/Validate-Repository.ps1` as a standalone process with no timeout. It
exited 0 and ended with `Repository validation passed.` The post-run detached
SHA, parent, and clean-tree proofs matched the pre-run proofs exactly.

## Adapter-attempt disposition

- Attempt 1 aggregate wrapper timed out at 300 seconds; its later 180-second
  validator bound also expired. Artifact SHA-256:
  `b5f658a1cb6008053478ac94c0ae4366da5a427cfae6a40cd8979a3e20a690ca`.
- Attempt r2 allowed 900 seconds but used a PTY. The receipt fixture launches
  `/usr/bin/python3 -c pass` with nonempty `PYTHONINSPECT=0`; under a PTY Python
  waits interactively. Artifact SHA-256:
  `d45fadc71a20b3c5cabb3d8f8d94ea4be99732032a93613849d447c8018f63f3`.
- Attempt r3 reproduced the same PTY adapter defect and was terminated after
  exact child-process proof. It did not produce a verdict artifact.
- Attempt r4 used a non-PTY adapter. The same deterministic validator crossed
  receipt-authority normally and passed. Attempts 1-r3 are adapter evidence,
  not candidate failures.

## Skips and residual gate

Python syntax validation was unavailable in the validator environment. Root
payload and launcher privilege-drop positives were skipped at uid 1000.
Windows ACL, path, handle, process-identity, and Excel COM fixtures were skipped
on Linux. These are not claimed as coverage. Root commissioning remains the
required final live gate.

PASS FOR NEUTRAL RUNNER

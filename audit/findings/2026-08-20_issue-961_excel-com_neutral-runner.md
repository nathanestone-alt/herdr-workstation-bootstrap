# Issue #961 deterministic neutral runner

- Candidate: `70cdb679b620debf5cbeed2ea554718645b86841`
- Base: `d9b6d38ae65921bc0f4def63322ac51f580adf8f`
- Worktree: `/tmp/herdr-bootstrap-961-review-70cdb67`
- Route: OpenAI / `gpt-5.6-luna` / max / priority (`openai-gpt-5.6-luna-max`)
- The isolated sandbox remaps `/etc/ssh` ownership; all five prescribed checks were run with the documented control override `HERDR_SYSTEM_SSH_CONFIG=/home/nathan/.ssh/config`.

## Initial preflight

- `git rev-parse HEAD`: exit 0; exact candidate SHA matched.
- `git symbolic-ref -q HEAD`: exit 1 with empty output; detached HEAD proved.
- `git status --porcelain`: exit 0; empty.
- `git diff --numstat d9b6d38ae65921bc0f4def63322ac51f580adf8f..70cdb679b620debf5cbeed2ea554718645b86841`: exit 0; exact three-file scope, 15 insertions and 3 deletions:

  ```text
  2  2 scripts/Validate-Repository.ps1
  1  1 scripts/windows/HerdrExcelJobRunner.ps1
  12 0 tests/Test-HerdrExcelJobRunner.ps1
  ```

- `git diff --check d9b6d38ae65921bc0f4def63322ac51f580adf8f..70cdb679b620debf5cbeed2ea554718645b86841`: exit 0.

## Prescribed deterministic checks

1. `HERDR_SYSTEM_SSH_CONFIG=/home/nathan/.ssh/config pwsh -NoProfile -File tests/Test-HerdrExcelJobRunner.ps1`: exit 0; Herdr Excel job runner regression test passed.
2. `HERDR_SYSTEM_SSH_CONFIG=/home/nathan/.ssh/config pwsh -NoProfile -File tests/Test-HostOwnedAclPolicy.ps1`: exit 0; platform skip: Windows ACL policy checks require Windows security principals.
3. `HERDR_SYSTEM_SSH_CONFIG=/home/nathan/.ssh/config pwsh -NoProfile -File tests/Test-HerdrReviewStaging.ps1`: exit 0; Herdr review staging regression test passed.
4. `HERDR_SYSTEM_SSH_CONFIG=/home/nathan/.ssh/config pwsh -NoProfile -File tests/Test-HerdrWindowsSecurityIntegration.ps1`: exit 0; platform-independent runspace round-trip and race-fixture checks passed. Platform skip: Windows handle, ACL, process-identity, and Excel COM integration fixtures require Windows.
5. `HERDR_SYSTEM_SSH_CONFIG=/home/nathan/.ssh/config pwsh -NoProfile -File scripts/Validate-Repository.ps1`: exit 0; repository validation passed and configure-vps-client convergence passed under the controlled override.

Validator skips/warnings recorded:

- Python syntax validation skipped because Python was unavailable.
- Windows ACL policy checks skipped because Windows security principals are unavailable.
- Windows path-policy checks skipped because Windows path semantics are unavailable.
- Windows handle, ACL, process-identity, and Excel COM integration fixtures skipped because Windows is unavailable.

No Windows ACL convergence, Excel COM, OneDrive, or runtime validation is claimed; those remain later commissioning work.

## Final identity and clean-state proof

- `git rev-parse HEAD`: exit 0; `70cdb679b620debf5cbeed2ea554718645b86841`.
- `git symbolic-ref -q HEAD`: exit 1 with empty output; detached HEAD remained proven.
- `git status --porcelain`: exit 0; empty after all checks.
- Final `git diff --numstat d9b6d38ae65921bc0f4def63322ac51f580adf8f..70cdb679b620debf5cbeed2ea554718645b86841`: exit 0; same exact three-file 15-insertion/3-deletion scope.
- Final `git diff --check d9b6d38ae65921bc0f4def63322ac51f580adf8f..70cdb679b620debf5cbeed2ea554718645b86841`: exit 0.

PASS FOR NEUTRAL RUNNER

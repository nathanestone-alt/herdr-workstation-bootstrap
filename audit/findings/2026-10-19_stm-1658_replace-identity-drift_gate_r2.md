VERDICT: BLOCK
MERGE-BLOCKED

# STModel #1658 identity-drift replacement gate, round 2

Base: `8512b44cd14a457da1db6bb047b29464749b1a63`
Head: `29e480c23c67f359b9986719fa12c7b2e5e1b517`
Range: `8512b44..29e480c`, one commit, four files. HEAD matched the candidate and the worktree was clean on entry. Entry verification returned `NOT_APPLICABLE` for this headless node.

## Mechanical evidence

| Suite | Host | Counts and outcome |
| --- | --- | --- |
| `tests/Test-WindowsReceiptAuthority.ps1` | herdr-ubuntu, `/usr/bin/pwsh` 7.6.5 | PASS, 64 source assertions, exit 0. Native transaction fixtures explicitly NOTRUN on Linux. |
| Same candidate suite, copied to fresh scratch | herdr-win, pwsh 7.6.7 | NOTRUN / INFRASTRUCTURE-BLOCKED. No established source or native assertion count. Neither restricted-child attempt produced a suite result. |
| PowerShell parser, three changed `.ps1` files | herdr-ubuntu, pwsh 7.6.5 | PASS, 3 files, 0 parse errors. |
| `git diff --check 8512b44..29e480c` | herdr-ubuntu | PASS, exit 0, no output. |

The parse covered `scripts/windows/WindowsReceiptAuthority.ps1`, `scripts/windows/Install-WindowsReceiptAuthority.ps1`, and `tests/Test-WindowsReceiptAuthority.ps1` using `Management.Automation.Language.Parser.ParseFile`.

SSH used `ssh -o BatchMode=yes -o StrictHostKeyChecking=yes herdr-win` with bounded connection and execution timeouts. The SSH account reported administrator membership. The helper therefore attempted to launch the suite with a restricted token that disabled the Administrators SID and maximum privileges. It never invoked the suite directly in the elevated parent.

Both attempts extracted 42 files from candidate Git blobs under a fresh `%TEMP%\stm1658-gate2-<timestamp>` directory and verified their SHA-256 values before launch. The first helper's `CreateProcessWithTokenW` attempt failed with `Access is denied` before a fixture process launched. The second used `CreateProcessAsUserW`, waited for its child to finish, and then found no `fixtures.log`. Consequently there is no evidence that the suite reached its non-elevated assertion or ran a native transaction. Both parent cleanup blocks reported `scratch_removed=True`. No third attempt was made, following `STModel-Private/audit/CLAUDE.md:92`, which removes a gate leg after two harness failures. Both foreground jobs finished before this report was written.

## Bounded question

Answer: no bypass was found through the production callers. The switch does not skip any code beyond the two named blocks. This conclusion is from the candidate diff and a caller census, not a completed Windows runtime check.

- `scripts/windows/Install-WindowsReceiptAuthority.ps1:38` rejects `-Replace` outside Install mode. Ordinary Check calls `Assert-HerdrWindowsAuthority` without either bypass switch at lines 53-60. The installer exposes no `SkipInstalledIdentityDrift` parameter. Its only bypass call is inside `if ($Replace)` at lines 69-72.
- `scripts/windows/WindowsReceiptAuthority.ps1:654` and `:696` are the other two production calls that pass the switch. Both validate the existing pair inside `Publish-HerdrAuthorityReplacement`, after its administrator and fixed-pair-path guards at lines 649-653. The installer calls that publisher only under `if ($Replace)` at lines 103-108. First install takes the separate publisher at lines 109-112.
- The two switch conditions at `scripts/windows/WindowsReceiptAuthority.ps1:535` and `:546` enclose exactly the recorded executable safe-path/hash loop and live uv re-resolution/comparison. The loop's safe-path checks are part of the skipped block. Fixed authority and receipt paths, tree owner/ACL checks, runtime namespace access, authority identity fields, receipt hash binding, receipt/authority identity binding, expiry validation, role-manifest binding, and the uv reparse-required field remain outside those conditions at lines 488-534 and 543-545.
- The helper is a dot-sourced function, so its switch is directly callable, as the fixture does at `tests/Test-WindowsReceiptAuthority.ps1:303`. This does not add a public installer Check option or publication path. The three production switch call sites are all replacement pre-checks.

The replacement still measures new identities from installed binaries. `scripts/windows/Install-WindowsReceiptAuthority.ps1:90` obtains a fresh role manifest; lines 91-94 obtain and constrain fresh Python and uv identities. The measurement functions resolve commands and hash installed files at `scripts/windows/WindowsReceiptAuthority.ps1:228`, `:254`, and `:275`. The new receipt and authority are then constructed at installer lines 95-102. The old recorded identities are not reused to construct the replacement.

Before publication, `scripts/windows/WindowsReceiptAuthority.ps1:671` writes the new staged files; lines 673-692 protect the stage and validate staged bytes, the authority/receipt binding, expiry, and runtime namespace access. The bypass calls at lines 654 and 696 read the existing fixed pair, not the stage. Line 698 publishes the staged pair through the unchanged atomic transaction.

The requested after-publication qualification is narrower than a production post-check. `tests/Test-WindowsReceiptAuthority.ps1:336` publishes the fixture pair and line 342 runs ordinary Check with no bypass; lines 339-344 verify backup bytes and the published receipt hash. That Windows fixture leg was not established in this run. Production itself has no automatic Check after the move: the publisher returns at `scripts/windows/WindowsReceiptAuthority.ps1:706`, and the installer reports success at lines 107-117. This is also true at base `8512b44`; it is not introduced by the candidate. Therefore this gate cannot claim a production post-publication identity revalidation or a passing native post-publication test.

## Findings by severity

No P1/P2 candidate defect was established in the changed surface. No P3 documentation or test-structure finding is raised.

Acceptance blocker: the required non-elevated herdr-win suite has no result after two failed launch-harness attempts. Linux source checks do not execute the native transaction or the changed identity-drift assertion at test lines 302-303. This is missing evidence, not an observed candidate regression.

## Disposition

INCOMPLETE. Merge remains blocked until a fresh gate leg supplies a passing non-elevated herdr-win fixture result for this exact candidate. The diff review, Linux source fixtures, parse checks, and whitespace check passed. No installer or Check ran against a real authority path; no sudo, elevation request, git mutation, remote Git operation, or product-file edit occurred. Only this untracked report, `.node-return.md`, and scratch files were written.

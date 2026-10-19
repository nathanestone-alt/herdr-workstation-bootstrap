VERDICT: PASS
MERGE-OK

# STModel #1658 identity-drift replacement gate, round 3

Base: `8512b44cd14a457da1db6bb047b29464749b1a63`
Head: `29e480c23c67f359b9986719fa12c7b2e5e1b517`
Range: `8512b44..29e480c`, one commit, four files. Review scope is this diff. Worktree HEAD on entry was `0c9bc333e9f295ed37bb054dae885f9ecc686808`, which adds the round-2 report. All four candidate files match the `29e480c` Git blobs byte for byte. Entry verification returned `NOT_APPLICABLE` for the headless node.

## Mechanical evidence

| Suite | Host | Counts and outcome |
| --- | --- | --- |
| `tests/Test-WindowsReceiptAuthority.ps1` | herdr-ubuntu, `/usr/bin/pwsh` 7.6.5 | PASS, 64 source assertions, exit 0. Native fixtures explicitly NOTRUN on Linux. |
| Same suite from candidate Git blobs | herdr-win, pwsh 7.6.7, `ELEVATED=False` | PASS, 87 total assertions, including the 64 source assertions and 23 additional Windows assertions. Child exit 0; SSH exit 0. |
| PowerShell parser | herdr-ubuntu, pwsh 7.6.5 | PASS, 3 changed `.ps1` files, 0 parse errors. |
| `git diff --check 8512b44..29e480c` | herdr-ubuntu | PASS, exit 0, no output. |

The parser used `Management.Automation.Language.Parser.ParseFile` on `scripts/windows/WindowsReceiptAuthority.ps1`, `scripts/windows/Install-WindowsReceiptAuthority.ps1`, and `tests/Test-WindowsReceiptAuthority.ps1`.

The r1 harness SHA-256 matched the brief's `a312e3305241733cb895267354803c97c8d3c6e8667351c6ee468ff2b4a0766d`. Diffing it against `run-remote-29e480c.py` showed only two commit-literal substitutions (`bdc8e1b` to `29e480c`) and the scratch-prefix change (`stm1658-gate-` to `stm1658-gate3-`). The supplied harness ran unchanged, once. It packed candidate blobs with `git ls-tree`/`git show`, connected only to `herdr-win` using BatchMode and StrictHostKeyChecking, and launched a normal-user SAFER token through `CreateProcessAsUserW`. The child reported `HOST=HERDR-WIN PWSH=7.6.7 ELEVATED=False`. The harness reported `FIXTURE_EXIT=0` and `SCRATCH_REMOVED=True` after removing its fresh `%TEMP%` tree.

Both changed statements at `tests/Test-WindowsReceiptAuthority.ps1:302` and `:303` executed in the native fixture. Ordinary Check rejected executable drift; the existing-pair validation accepted it with the replacement switch. The native suite also exercised malformed-pair refusal, simulated owner/ACL and runtime-access refusals, rollback on held-reader and failed-move cases, backup preservation, publication, and ordinary Check on the new generation.

Logs retained under the node's scratch directory:

- Linux: `/home/nathan/.cache/stm-scratch/STModel-Private-a9176bfdd476d72d/tl1-1658-bootstrap-gate-r3-644250932e6cc6da/gate-logs/windows-authority-linux.log` (SHA-256 `83de6306919e5cf75682816d4b4331dde3520bb0b224fbddd6173aae80a3cf7b`).
- Windows: `/home/nathan/.cache/stm-scratch/STModel-Private-a9176bfdd476d72d/tl1-1658-bootstrap-gate-r3-644250932e6cc6da/gate-logs/windows-herdr-win-limited.log` (SHA-256 `e26e10d83166cba2baed46b68fc2946bf6fdbd0dd7d5f2c408db74b3d02b4479`). The transcript includes expected errors from negative assertions; the final count and child exit establish the suite outcome.

## Bounded question

No bypass was found through production callers, and the switch skips exactly the two named blocks. It does not allow ordinary Check, first install, or replacement to bypass the remaining pair-authenticity checks.

- `scripts/windows/Install-WindowsReceiptAuthority.ps1:38` rejects `-Replace` outside Install mode. Its parameter list has no `SkipInstalledIdentityDrift` option. Ordinary Check at `:54` supplies neither skip switch. Only `if ($Replace)` at `:69` supplies the new switch at `:71`. First install takes the separate publisher at `:110`.
- The other two production uses are `scripts/windows/WindowsReceiptAuthority.ps1:655` and `:697`, both inside `Publish-HerdrAuthorityReplacement`. Its administrator and fixed-pair-path guards remain at `:649` and `:650`. Both calls read the existing fixed pair, not the staged new generation. A census of the candidate's Windows scripts found no other callers or uses.
- `scripts/windows/WindowsReceiptAuthority.ps1:535` guards only the recorded executable safe-path/hash loop, including its executable-path safety check. `:546` guards only live uv re-resolution and its recorded-target comparison. Fixed authority/receipt paths, tree ownership/ACLs, runtime namespace access, authority schema/identity fields, the receipt hash, receipt/authority identity binding, expiry validation, and the role-manifest hash remain outside those blocks at `:488` through `:534`. The uv reparse-required field remains enforced at `:543`.
- The dot-sourced helper can be called directly with the switch, as the fixture does at `tests/Test-WindowsReceiptAuthority.ps1:303`. That helper invocation does not expose the switch through installer Check or create a publication path.

The installer still measures the replacement from installed binaries at `scripts/windows/Install-WindowsReceiptAuthority.ps1:90` through `:94`, then builds a new receipt and authority at `:95` through `:102`. Role hashes come from resolved commands at `scripts/windows/WindowsReceiptAuthority.ps1:236` through `:238`; Python and launcher hashes at `:264` through `:271`; uv target resolution and commissioned-hash comparison at `:293` through `:304`. It does not reuse the existing pair's recorded identities to mint the new generation.

Before publication, `scripts/windows/WindowsReceiptAuthority.ps1:671` through `:692` writes and protects the staged pair, checks its bytes and authority-to-receipt binding, validates expiry, and checks runtime namespace access. The unchanged transaction publishes it at `:698`. After publication, the native fixture runs ordinary Check without either switch at `tests/Test-WindowsReceiptAuthority.ps1:342`, and verifies the published receipt hash at `:343`; this run passed.

The after-publication evidence is a fixture check. Production does not automatically run Check after the transaction; its publisher returns at `scripts/windows/WindowsReceiptAuthority.ps1:706`. That behavior is unchanged from `8512b44` and is outside this diff. This report does not claim production post-publication remeasurement.

## Findings by severity

No P1/P2 candidate defect found. No P3 documentation or test-structure finding raised.

## Disposition and limitations

PASS / MERGE-OK for `8512b44..29e480c`. All requested acceptance items are answered, including the previously missing non-elevated Windows native fixture result. This is a merge-safety recommendation, not merge authorization or evidence of a live authority mint.

The native fixture substitutes privileged owner/ACL operations, runtime-access checks, uv probing, and ancestor-handle setup (`tests/Test-WindowsReceiptAuthority.ps1:199` through `:223`); it exercises the live digest reader and NTFS transaction in scratch. No installer or Check ran against `C:\ProgramData`, no `C:\dev` path was touched, and no sudo, elevation, remote Git operation, commit, or product-file edit occurred. The local and SSH processes finished before this report was written. Only this untracked report, `.node-return.md`, and node scratch were written. The orchestrator owns committing the verdict and recording the ledger return.

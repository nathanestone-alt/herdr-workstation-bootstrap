VERDICT: BLOCK

# Issue #1074 Windows authority producer build r1

## CLAIMS

- A source-only Windows #961 authority producer is implemented at
  `scripts/windows/Install-WindowsReceiptAuthority.ps1`, with reusable contract logic in
  `scripts/windows/WindowsReceiptAuthority.ps1`.
- The producer is Windows/x64/admin-only and publishes only the fixed
  `C:\ProgramData\STModel\Issue961\receipt-authority.json` and bound
  `bootstrap-receipt.json` locations.
- Install mode requires independently supplied hashes for the reviewed source commit,
  payload manifest, role allowlist, and producer script. It rejects a dirty tracked tree
  and verifies every payload-manifest entry with .NET SHA-256.
- The producer resolves the actual `HERDR-WIN\rdp-natha` SID, records and hashes the real
  `py.exe -3.13` CPython 3.13.15 executable and launcher, and records both the uv 0.12.5
  WinGet command reparse path and its non-reparse resolved target/hash.
- Role identities are built only from the reviewed #961 allowlist. Git and PowerShell are
  mandatory; supported additional reviewed roles may be explicitly requested.
- Publication uses same-directory temporary files opened with no sharing, ACL convergence
  before commit, atomic move/replace, reparse/path checks, held read handles, exact receipt
  hashing, and post-publication identity validation.
- The Issue961 directory tree permits only SYSTEM and built-in Administrators full control;
  the exact runtime SID receives read/execute and no effective write bits. ACL inheritance,
  unexpected principals, wrong ownership, and reparse descendants are rejected.
- No Windows host was mutated, no authority was published, and no deployment/install was run.

## CARDINALITY

- 7 intended source/test/doc files changed or added before this finding: 3 producer/security
  scripts, 1 repository validator, 2 PowerShell tests, and 1 commissioning document.
- Focused source fixtures: 1/1 PASS.
- PowerShell fixture sweep: 5 PASS, 4 expected non-Windows SKIP, 0 FAIL.
- Syntax sweep: all `scripts/windows/*.ps1` and `tests/*.ps1` parsed, 0 errors.
- Native Windows commissioning: 0 runs (explicitly NOT RUN).
- Source commits created: 0; the sandbox blocks writes to the linked worktree Git metadata.

## CHANGES

- `scripts/windows/WindowsReceiptAuthority.ps1`: canonical JSON/hash helpers, source payload
  validation, authentic role/Python/uv identity probes, receipt/envelope construction,
  atomic publication, and installed-authority validation.
- `scripts/windows/Install-WindowsReceiptAuthority.ps1`: fixed-scope administrator entrypoint
  with independently supplied bindings, Install and Check modes, locked runtime account,
  and fixed authority/receipt paths.
- `scripts/windows/HerdrHostOwnedAclPolicy.ps1`: host-owned read-only ACL convergence and a
  separate non-mutating assertion for exact owner/principal/right cardinality.
- `tests/Test-WindowsReceiptAuthority.ps1`: portable canonicalization, SHA, payload tamper,
  authority-envelope, fixed identity, uv-target, and anti-regression fixtures.
- `tests/Test-HostOwnedAclPolicy.ps1`: native Windows read-only ACL regression coverage.
- `scripts/Validate-Repository.ps1`: required-file, content-tripwire, and focused-test wiring.
- `docs/windows-receipt-authority.md`: precise privileged commissioning prerequisites,
  commands, evidence, and producer/consumer contract.

File SHA-256 values before this finding was created:

| File | SHA-256 |
|---|---|
| `scripts/windows/HerdrHostOwnedAclPolicy.ps1` | `172682694957ad4c597e3edf29e3d7aa041c635f2019b61382b93c97b71159fd` |
| `scripts/windows/WindowsReceiptAuthority.ps1` | `15a81995b40c37b6b57614d29619f2c91ba779f9941e68d5589d5f13b354b2ca` |
| `scripts/windows/Install-WindowsReceiptAuthority.ps1` | `51110968def4f7e2a7b6c527c5e9ffdc1c5ab75670e6e53180a1f7d4d3b3ee0a` |
| `scripts/Validate-Repository.ps1` | `398b6065e4e68f7e94a6ae828fec470b834938e0b72fcb98daee5f50ad331671` |
| `tests/Test-HostOwnedAclPolicy.ps1` | `20860ffeecbfe37364021ec08dc06384a2ef90318e8d35af5e08db1891a50b89` |
| `tests/Test-WindowsReceiptAuthority.ps1` | `72492e79ef7cb5996d1c0e8b16f220e85d211db985b338a64d4f30efc803ebd7` |
| `docs/windows-receipt-authority.md` | `f120a1f467c06adaf1f7b577edad0657095b1af8ddce9011f422f34aa4f085b4` |

## CHECKS

- Entry preflight: repository, branch, and clean tracked entry matched the brief at
  `cbc43993769cb32a2aa2aef79f8a6ab7dece9c08` before writing.
- `pwsh -NoLogo -NoProfile -File tests/Test-WindowsReceiptAuthority.ps1`: PASS.
- PowerShell fixture sweep with 60-second per-test caps: 5 PASS, 4 non-Windows SKIP, 0 FAIL.
- Parser sweep over Windows scripts and PowerShell tests: PASS, 0 syntax errors.
- `git diff --check`: PASS.
- `PSScriptAnalyzer`: SKIP, module unavailable.
- `scripts/Validate-Repository.ps1`: INCOMPLETE at the explicit 120-second cap after several
  printed passing regressions; exit 124. This is not claimed as a pass or product failure.
- Native Windows install/check, ACL/effective-access proof, and consumer replay: NOT RUN by
  design and remain required commissioning/acceptance work.

## OPEN

1. BLOCK: the assigned workspace permits source writes but not writes to the common Git
   directory used by this linked worktree. `git add` failed with:
   `Unable to create '/home/nathan/code/herdr-workstation-bootstrap/.git/worktrees/issue-1074-windows-authority-20260905/index.lock': Read-only file system`.
   Therefore the required coherent source commit cannot be created in this node.
2. A writable host context must stage and independently review these exact files, run the
   full repository validator to completion, and commit the candidate on
   `issue-1074/windows-authority-20260905`. No push is authorized here.
3. The owning orchestrator must independently review the committed candidate, then commission
   on HERDR-WIN with the exact commit/script/manifest/allowlist hashes documented in
   `docs/windows-receipt-authority.md`.
4. Native acceptance must prove the fixed paths, exact `rdp-natha` SID, allow-only ACLs and
   negative write access, reparse rejection, uv link-to-target binding, CPython/launcher hashes,
   receipt hash, held-handle behavior, Check mode, and the separate consumer replay.

## Producer/consumer handoff

The consumer should require the fixed authority path and continue rejecting every reparse
component while holding authority, receipt, and launcher handles across proof/use. It should
bind caller assertions only to authority-owned `receipt_path`, `receipt_sha256`, `receipt_id`,
`source_commit_sha`, `verification_status`, `payload_manifest_sha256`,
`bridge_allowlist_sha256`, Windows/x86_64, `python313` plus launcher, and
`role_manifest_sha256`. The producer additionally supplies `uv` command/reparse-target proof
and `runtime_identity` account/SID; the Windows consumer/native gate should validate those
fields rather than replace them with caller-side values. No Ubuntu receipt or platform value
is copied or invented.

# #1074 authority native correction r5

## Outcome

The source correction is complete for the two native failures observed after r4. The
read-only ACL helper now invokes `icacls /setowner` separately from the replacement-DACL
operation and checks each exit code. The Windows native fixture now uses an
existence-checked GUID directory under fixed local ProgramData, protects that private root,
and separately protects the success and failed-publication namespace parents before the
production publisher exercises its unchanged ancestor access checks.

No authority assertion was weakened. The reader remains RX-only; SYSTEM and built-in
Administrators retain FullControl; built-in Administrators remains the required owner;
inheritance, unexpected-SID, token identity, token group-attribute, and real AccessCheck
proofs remain enforced.

## Exact source identity

- Entry source commit: `b63624ef74b1a1100ad4cb3dd6e88c7d5ee37fe4`.
- Entry HEAD: `824838a709227150db79226c1c534e61b0ce11a2`; its only change from the entry source is
  `audit/findings/2026-09-05_issue-1074_windows_authority_review_r4.md`.
- Candidate four-file patch SHA-256 from entry HEAD: `4c2b86591b64137ef395d668074d0e1c351bb7f756bc8d61c7dd9a98857ec1c3`.
- `scripts/windows/HerdrHostOwnedAclPolicy.ps1` SHA-256:
  `7c5fc9b8e4d42e93b09a73d4423dd61e72ed56d44db1ac9710b5b644a3926992`.
- `tests/Test-WindowsAuthorityNative.ps1` SHA-256:
  `368bd16950ce712220f371d6414f1350f8d1b960810b58f376313b3e47432642`.
- `tests/Test-WindowsReceiptAuthority.ps1` SHA-256:
  `3e3e72aabe8158038b1f1bdb2518995a7aa6741a62e810c1b823504f0f15b8e1`.
- `docs/windows-receipt-authority.md` SHA-256:
  `d02d3bfe1e2d3a858781f60601e5d1e669ba0851b62b4411d32f43c8517062ae`.

## Changes

- `scripts/windows/HerdrHostOwnedAclPolicy.ps1`: one checked owner command and one checked
  inheritance-removal/replacement-DACL command per tree item. Existing final owner, DACL,
  allow-only, and rights assertions remain unchanged.
- `tests/Test-WindowsReceiptAuthority.ps1`: ordinary Linux-runnable AST regression requires
  exactly one owner command and one replacement-DACL command in
  `Protect-HostOwnedReadOnlyTree`, and rejects either command if it contains the other's
  incompatible switch.
- `tests/Test-WindowsAuthorityNative.ps1`: replaces the runtime account TEMP root with a
  private GUID root beneath `CommonApplicationData`; refuses a pre-existing root; protects
  and asserts the fixture root plus the success and failed-generation parents; retains the
  canonical uv copied-byte/version proof, runtime/runner masks `0x10`/`0x0f`, and real
  AccessCheck cases.
- `docs/windows-receipt-authority.md`: records the corrected private ProgramData fixture
  topology.

## Focused checks

- PowerShell parser over the three edited `.ps1` files: PASS.
- `pwsh -NoLogo -NoProfile -File tests/Test-WindowsReceiptAuthority.ps1`: PASS,
  `Windows receipt-authority source fixture tests passed.`
- `pwsh -NoLogo -NoProfile -File tests/Test-WindowsAuthorityNative.ps1`: exit 0,
  `nativeNOTRUN: Windows authority native token/link/publication checks require Windows.`
- `pwsh -NoLogo -NoProfile -File tests/Test-HostOwnedAclPolicy.ps1`: exit 0, expected Linux
  `SKIP: Windows ACL policy checks require Windows security principals.`
- `git diff --check`: PASS.
- C# compilation: NOT RUN because no C# or embedded C# changed.
- Whole repository validator and live launcher verify: NOT RUN, per the brief's focused-check
  boundary and because this sandbox has no authorized deployment/native-host access.

## Native and operational limitations

nativeNOTRUN: this worker did not execute SSH, a Windows scheduled task, native token/ACL/
link/publication mutation, or the fixed `C:\ProgramData\STModel\Issue961` authority. The parent
must independently review a clean committed source SHA and then run the existing native
acceptance leg with a freshly observed commissioned process tuple. No merge, push, PR,
release, deployment, account change, global ACL change, workbook/COM action, or downstream
dispatch occurred.

The single authorized Git commit attempt was blocked before staging by the linked-worktree
index boundary:

```text
fatal: Unable to create '/home/nathan/code/herdr-workstation-bootstrap/.git/worktrees/issue-1074-windows-authority-20260905/index.lock': Read-only file system
```

No second Git index or commit attempt was made. A writable parent must mechanically stage the
four source/test/doc files and this report, verify their exact hashes, and create the clean
candidate commit for independent review and native execution.

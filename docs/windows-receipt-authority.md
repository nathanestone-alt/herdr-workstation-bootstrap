# Windows #961 receipt authority

`scripts/windows/Install-WindowsReceiptAuthority.ps1` is the Windows producer for the fixed
`C:\ProgramData\STModel\Issue961\receipt-authority.json` installation authority. It creates
and binds `bootstrap-receipt.json`; it does not copy or translate an Ubuntu receipt.

The producer must run in an elevated PowerShell 7 session from an independently reviewed,
clean bootstrap checkout. It refuses a source commit or payload-manifest digest other than
the independently commissioned values. It probes the real `py.exe -3.13` result, hashes both
the launcher and resolved CPython executable, requires the approved runtime profile's canonical
`Microsoft\WinGet\Links\uv.exe` reparse leaf, constrains its target to the `astral-sh.uv`
WinGet package topology, and binds the real target to an independently commissioned SHA-256.
The commissioned installed target is `uv 0.12.6`; this exact version is required without
reinstalling, downgrading, or accepting an arbitrary PATH executable.
It also hashes each required host role from the reviewed #961
role allowlist. The authority records the actual SID resolved for the already-approved
`HERDR-WIN\rdp-natha` runtime account.

## Commissioning (not run by the source builder)

Prerequisites on `HERDR-WIN`:

- elevated PowerShell 7 in the interactive administrator context;
- the reviewed bootstrap commit checked out on a fixed local NTFS volume with no reparse
  component, a clean tracked tree, and Git available;
- `HERDR-WIN\rdp-natha` already present and resolvable to its real SID;
- an existing non-elevated runtime process for that account whose PID, UTC creation time, and
  session ID are captured immediately before commissioning (caller assertions are checked
  against the still-open process and token handles);
- Windows x64 CPython 3.13 registered with `py.exe`, plus `uv`, Git, and PowerShell 7;
- the independently reviewed 40-hex bootstrap commit and 64-hex SHA-256 of
  `config\payload-manifest.sha256`, `config\receipt-authority-role-allowlist.txt`, and
  `scripts\windows\Install-WindowsReceiptAuthority.ps1`, and the resolved WinGet `uv.exe`
  target recorded in the commissioning evidence.

From the reviewed checkout, an administrator runs:

```powershell
$commit = '<reviewed-40-hex-bootstrap-commit>'
$manifestSha256 = '<reviewed-64-hex-config-payload-manifest-sha256>'
$allowlistSha256 = '<reviewed-64-hex-role-allowlist-sha256>'
$producerSha256 = '<reviewed-64-hex-producer-script-sha256>'
$uvTargetSha256 = '<reviewed-64-hex-installed-winget-uv-target-sha256>'
$runtimeProcess = Get-Process -Id <existing-non-elevated-runtime-process-pid>
$runtimeCreationUtc = $runtimeProcess.StartTime.ToUniversalTime().ToString('o')
$runtimeSessionId = $runtimeProcess.SessionId
pwsh -NoLogo -NoProfile -File scripts\windows\Install-WindowsReceiptAuthority.ps1 `
  -Mode Install -ExpectedSourceCommit $commit -ExpectedPayloadManifestSha256 $manifestSha256 `
  -ExpectedRoleAllowlistSha256 $allowlistSha256 -ExpectedProducerScriptSha256 $producerSha256 `
  -ExpectedUvTargetSha256 $uvTargetSha256 -RuntimeProcessId $runtimeProcess.Id `
  -ExpectedRuntimeProcessCreationTimeUtc $runtimeCreationUtc -ExpectedRuntimeSessionId $runtimeSessionId
pwsh -NoLogo -NoProfile -File scripts\windows\Install-WindowsReceiptAuthority.ps1 -Mode Check `
  -RuntimeProcessId $runtimeProcess.Id -ExpectedRuntimeProcessCreationTimeUtc $runtimeCreationUtc `
  -ExpectedRuntimeSessionId $runtimeSessionId
```

Publication is first-install-only: if the fixed directory or either fixed file already exists,
the producer refuses before changing anything. It creates and validates both files in a private
sibling directory, then publishes the complete pair with one atomic directory rename. A failed
pre-publication check removes the sibling and cannot expose a receipt-only or authority-only
generation. The fixed directory is protected against inherited ACLs; only
SYSTEM and built-in Administrators receive full control, while the resolved `rdp-natha` SID
receives read/execute. The producer opens the specified live process token, verifies its exact
PID/creation/session/SID tuple, and asks Windows `AccessCheck` for the token's effective rights.
An enabled Administrators group therefore fails closed, while a UAC-filtered deny-only group is
handled according to the actual token. Retained no-delete-share handles stabilize each namespace
ancestor during proof; ancestors are checked only for delete-child/delete/ACL-owner rights, while
the dedicated Issue961 tree is checked for all write/delete/ACL-owner rights. Any UNC/device namespace,
non-fixed volume, reparse component, unexpected ACL principal, dirty source, manifest drift,
missing tool, or identity mismatch aborts publication/checking.

Native Windows acceptance must retain the install/check output, resulting authority and
receipt SHA-256 values, `icacls` output for the Issue961 directory and both files, the resolved
runtime account SID, `py.exe`/CPython paths and hashes, and the uv command-link and resolved
target paths/hashes, and the runtime process PID/creation/session/SID/elevation/group-attribute
proof. The source fixture test is not a substitute for that native acceptance.

`tests\Test-WindowsAuthorityNative.ps1` is the bounded native-positive commissioning fixture.
Pass it the freshly re-observed limited `rdp-natha` process ID, round-trip UTC creation time,
session ID, and SID. Without those live-process inputs it prints `nativeNOTRUN` and cannot be
reported as a full #1074 native PASS. The fixture uses the production token, ACL, uv resolver,
and publisher helpers beneath an existence-checked, GUID-named private boundary in fixed local
ProgramData; it copies the independently hashed installed uv bytes and never changes the live
WinGet link, package, or production authority.

## Producer/consumer contract

The consumer must keep the fixed authority path, reject reparse components, hold read handles
across proof/use, and compare caller assertions to the authority. The envelope binds schema and
authority IDs, receipt path/hash/ID, source commit, verification status, payload and role-
allowlist hashes, Windows/x86_64, CPython 3.13 plus `py.exe`, canonical role-manifest hash,
resolved uv target identity, and the exact runtime account/SID. Unknown extra fields may be
ignored, but these bindings must not be weakened or sourced from caller-controlled sidecars.
The consumer must independently apply the same handle-bound `AccessCheck` rule to its own live
runtime token before trusting the authority; the producer's commissioning-time process proof is
evidence about that captured process, not a transferable boolean or a waiver for later processes.

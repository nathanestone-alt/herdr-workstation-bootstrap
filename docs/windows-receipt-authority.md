# Windows #961 receipt authority

`scripts/windows/Install-WindowsReceiptAuthority.ps1` is the Windows producer for the fixed
`C:\ProgramData\STModel\Issue961\receipt-authority.json` installation authority. It creates
and binds `bootstrap-receipt.json`; it does not copy or translate an Ubuntu receipt.

The producer must run in an elevated PowerShell 7 session from an independently reviewed,
clean bootstrap checkout. It refuses a source commit or payload-manifest digest other than
the independently commissioned values. It probes the real `py.exe -3.13` result, hashes both
the launcher and resolved CPython executable, resolves the installed `uv` command's reparse
target and hashes that real target, and hashes each required host role from the reviewed #961
role allowlist. The authority records the actual SID resolved for the already-approved
`HERDR-WIN\rdp-natha` runtime account.

## Commissioning (not run by the source builder)

Prerequisites on `HERDR-WIN`:

- elevated PowerShell 7 in the interactive administrator context;
- the reviewed bootstrap commit checked out on a fixed local NTFS volume with no reparse
  component, a clean tracked tree, and Git available;
- `HERDR-WIN\rdp-natha` already present and resolvable to its real SID;
- Windows x64 CPython 3.13 registered with `py.exe`, plus `uv`, Git, and PowerShell 7;
- the independently reviewed 40-hex bootstrap commit and 64-hex SHA-256 of
  `config\payload-manifest.sha256`, `config\receipt-authority-role-allowlist.txt`, and
  `scripts\windows\Install-WindowsReceiptAuthority.ps1` recorded in the commissioning evidence.

From the reviewed checkout, an administrator runs:

```powershell
$commit = '<reviewed-40-hex-bootstrap-commit>'
$manifestSha256 = '<reviewed-64-hex-config-payload-manifest-sha256>'
$allowlistSha256 = '<reviewed-64-hex-role-allowlist-sha256>'
$producerSha256 = '<reviewed-64-hex-producer-script-sha256>'
pwsh -NoLogo -NoProfile -File scripts\windows\Install-WindowsReceiptAuthority.ps1 `
  -Mode Install -ExpectedSourceCommit $commit -ExpectedPayloadManifestSha256 $manifestSha256 `
  -ExpectedRoleAllowlistSha256 $allowlistSha256 -ExpectedProducerScriptSha256 $producerSha256
pwsh -NoLogo -NoProfile -File scripts\windows\Install-WindowsReceiptAuthority.ps1 -Mode Check
```

Publication is fail-closed. The fixed directory is protected against inherited ACLs; only
SYSTEM and built-in Administrators receive full control, while the resolved `rdp-natha` SID
receives read/execute. Temporary files are created without sharing, ACL-converged before an
atomic same-directory move/replace, and the producer then holds and revalidates the authority
and receipt while checking their exact hash and identity bindings. Any UNC/device namespace,
non-fixed volume, reparse component, unexpected ACL principal, dirty source, manifest drift,
missing tool, or identity mismatch aborts publication/checking.

Native Windows acceptance must retain the install/check output, resulting authority and
receipt SHA-256 values, `icacls` output for the Issue961 directory and both files, the resolved
runtime account SID, `py.exe`/CPython paths and hashes, and the uv command-link and resolved
target paths/hashes. The source fixture test is not a substitute for that native acceptance.

## Producer/consumer contract

The consumer must keep the fixed authority path, reject reparse components, hold read handles
across proof/use, and compare caller assertions to the authority. The envelope binds schema and
authority IDs, receipt path/hash/ID, source commit, verification status, payload and role-
allowlist hashes, Windows/x86_64, CPython 3.13 plus `py.exe`, canonical role-manifest hash,
resolved uv target identity, and the exact runtime account/SID. Unknown extra fields may be
ignored, but these bindings must not be weakened or sourced from caller-controlled sidecars.

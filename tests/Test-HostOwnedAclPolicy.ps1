$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrHostOwnedAclPolicy.ps1')

if (-not $IsWindows) {
    Write-Host 'SKIP: Windows ACL policy checks require Windows security principals.'
    exit 0
}

$operatorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$root = Join-Path ([IO.Path]::GetTempPath()) "herdr-acl-policy-$([Guid]::NewGuid().ToString('N'))"
$child = Join-Path $root 'pre-existing-child'
$readOnlyRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-readonly-acl-policy-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $child -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $child 'existing.txt'), 'fixture')

    $childAcl = Get-Acl -LiteralPath $child
    $childAcl.SetAccessRuleProtection($true, $false)
    foreach ($existingRule in @($childAcl.Access)) {
        $childAcl.RemoveAccessRuleSpecific($existingRule)
    }
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $childAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $operatorSid, [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance, $propagation, $allow))
    $childAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-11'),
        [Security.AccessControl.FileSystemRights]::Modify,
        $inheritance, $propagation, $allow))
    Set-Acl -LiteralPath $child -AclObject $childAcl

    Protect-HostOwnedTree -TargetPath $root -OperatorSid $operatorSid
    @(Get-ChildItem -LiteralPath $root -Force -Recurse) | Out-Null
    $fileAcl = Get-Acl -LiteralPath (Join-Path $child 'existing.txt')
    $fileRules = @($fileAcl.Access)
    if ($fileRules.Count -lt 3) {
        throw 'A host-owned leaf file was left without the required allow-only DACL.'
    }
    foreach ($fileRule in $fileRules) {
        $fileSid = $fileRule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($fileSid -notin @('S-1-5-18', 'S-1-5-32-544', $operatorSid.Value) -or
            $fileRule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
            throw "Unexpected leaf-file ACL entry '$($fileRule.IdentityReference):$($fileRule.FileSystemRights)'."
        }
    }
    $operatorProbe = Join-Path $root 'operator-write.tmp'
    [IO.File]::WriteAllText($operatorProbe, 'allowed')
    Remove-Item -LiteralPath $operatorProbe -Force

    New-Item -ItemType Directory -Path $readOnlyRoot -Force | Out-Null
    $readOnlyFile = Join-Path $readOnlyRoot 'authority.json'
    [IO.File]::WriteAllText($readOnlyFile, '{}')
    Protect-HostOwnedReadOnlyTree -TargetPath $readOnlyRoot -ReaderSid $operatorSid
    Assert-HostOwnedReadOnlyTree -TargetPath $readOnlyRoot -ReaderSid $operatorSid
    $readerRules = @(Get-Acl -LiteralPath $readOnlyFile | Select-Object -ExpandProperty Access | Where-Object {
        $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $operatorSid.Value
    })
    if ($readerRules.Count -eq 0) { throw 'Read-only host policy omitted the designated reader SID.' }
    $writeMask = [Security.AccessControl.FileSystemRights]0x000D0156
    foreach ($readerRule in $readerRules) {
        if (($readerRule.FileSystemRights -band $writeMask) -ne 0) {
            throw "Read-only host policy granted write rights to the designated reader: $($readerRule.FileSystemRights)."
        }
    }
    Write-Host 'Host-owned ACL policy regression test passed.'
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    if (Test-Path -LiteralPath $readOnlyRoot) {
        Remove-Item -LiteralPath $readOnlyRoot -Recurse -Force
    }
}

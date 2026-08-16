#Requires -Version 7.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidatePattern('^HerdrBridge$')]
    [string]$LocalUser = 'HerdrBridge',
    [string]$ShareName = 'HerdrExchange',
    [string]$Path = 'C:\HerdrExchange',
    [string]$ToolsPath = 'C:\HerdrTools',
    [SecureString]$Password,
    [switch]$RotatePassword
)

$ErrorActionPreference = 'Stop'
$requiredUser = 'HerdrBridge'
function Assert-DedicatedBridgeMembership([object]$User) {
    $ordinaryUsersSid = 'S-1-5-32-545'
    try {
        $adsiUser = [ADSI]"WinNT://$env:COMPUTERNAME/$($User.Name),user"
        $memberGroups = @($adsiUser.psbase.Invoke('Groups'))
    }
    catch {
        throw "Could not enumerate actual group memberships for bridge account '$($User.Name)' via ADSI: $($_.Exception.Message)"
    }
    $isOrdinaryUser = $false
    foreach ($group in $memberGroups) {
        $groupName = $group.GetType().InvokeMember('Name', 'GetProperty', $null, $group, $null)
        $sidBytes = $group.GetType().InvokeMember('objectSID', 'GetProperty', $null, $group, $null)
        $groupSid = [Security.Principal.SecurityIdentifier]::new([byte[]]$sidBytes, 0).Value
        if ($groupSid -eq $ordinaryUsersSid) {
            $isOrdinaryUser = $true
        }
        else {
            throw "Bridge account '$($User.Name)' belongs to prohibited local group '$groupName'. It may belong only to the built-in Users group."
        }
    }
    if (-not $isOrdinaryUser) {
        throw "Bridge account '$($User.Name)' is not a member of the built-in Users group."
    }
}

function Test-FirewallPortIncludes445([object]$LocalPort) {
    foreach ($portExpression in @($LocalPort)) {
        $text = [string]$portExpression
        if ($text -eq '445') { return $true }
        if ($text -match '^(\d+)-(\d+)$' -and [int]$Matches[1] -le 445 -and [int]$Matches[2] -ge 445) {
            return $true
        }
    }
    return $false
}

function Get-ConflictingSmbFirewallRules([string]$ManagedRuleName) {
    $activeProfiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        switch ([string]$_.NetworkCategory) {
            'DomainAuthenticated' { 'Domain' }
            'Private' { 'Private' }
            'Public' { 'Public' }
        }
    } | Select-Object -Unique)
    foreach ($firewallRule in @(Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow)) {
        if ($firewallRule.DisplayName -eq $ManagedRuleName) { continue }
        $ruleProfiles = @(([string]$firewallRule.Profile) -split ',\s*')
        if ($activeProfiles.Count -gt 0 -and 'Any' -notin $ruleProfiles -and
            @($ruleProfiles | Where-Object { $_ -in $activeProfiles }).Count -eq 0) {
            continue
        }
        foreach ($portFilter in @($firewallRule | Get-NetFirewallPortFilter)) {
            if (($portFilter.Protocol -in @('TCP', 6)) -and
                (Test-FirewallPortIncludes445 -LocalPort $portFilter.LocalPort)) {
                $firewallRule
                break
            }
        }
    }
}
if ($LocalUser -cne $requiredUser) {
    throw "The SMB bridge must use the dedicated '$requiredUser' account."
}

$sharePath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
$toolsPathResolved = [IO.Path]::GetFullPath($ToolsPath).TrimEnd('\')
if ($toolsPathResolved.Equals($sharePath, [StringComparison]::OrdinalIgnoreCase) -or
    $toolsPathResolved.StartsWith("$sharePath\", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The host-owned tools directory must be outside the SMB share.'
}
if (Test-Path -LiteralPath (Join-Path $sharePath 'scripts')) {
    throw "Legacy shared scripts directory detected. Move reviewed executables to '$toolsPathResolved', remove the old directory, and retry."
}

$ruleName = 'Herdr Exchange SMB over Tailscale'
$conflictingRules = @(Get-ConflictingSmbFirewallRules -ManagedRuleName $ruleName)
if ($conflictingRules.Count -gt 0) {
    $names = @($conflictingRules | Select-Object -ExpandProperty DisplayName -Unique) -join "', '"
    throw "Preflight found other active-profile inbound allow rules that explicitly include TCP 445: '$names'. No account, ACL, share, or firewall state was changed."
}

$account = Get-LocalUser -Name $LocalUser -ErrorAction SilentlyContinue
if (-not $account) {
    if (-not $Password) {
        $Password = Read-Host "Create a strong local password for $LocalUser" -AsSecureString
    }
    New-LocalUser -Name $LocalUser -Password $Password -PasswordNeverExpires `
        -UserMayNotChangePassword -AccountNeverExpires `
        -Description 'Dedicated non-admin SMB exchange account for the Herdr Ubuntu VM' | Out-Null
    $account = Get-LocalUser -Name $LocalUser
}
else {
    if ($account.SID.Value -match '-500$') {
        throw 'The built-in Administrator account cannot be used for the SMB bridge.'
    }
    if (-not $account.Enabled) {
        throw "Existing bridge account '$LocalUser' is disabled; review it manually before retrying."
    }
    if ($Password -and -not $RotatePassword) {
        throw 'Supplying -Password for an existing account requires the explicit -RotatePassword switch.'
    }
    if ($RotatePassword) {
        if (-not $Password) {
            $Password = Read-Host "Rotate the password for $LocalUser" -AsSecureString
        }
        Set-LocalUser -Name $LocalUser -Password $Password
        Write-Warning 'The Windows password changed. Immediately rerun configure-excel-share.sh in Ubuntu and verify a write before ending this maintenance window.'
    }
    Set-LocalUser -Name $LocalUser -PasswordNeverExpires $true -UserMayChangePassword $false -AccountNeverExpires
}

$account = Get-LocalUser -Name $LocalUser
if (-not $account.Enabled -or $null -ne $account.PasswordExpires) {
    throw 'The bridge account does not satisfy the enabled, non-expiring credential policy.'
}
$usersSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
$directGroupSids = @(([ADSI]"WinNT://$env:COMPUTERNAME/$($account.Name),user").psbase.Invoke('Groups') | ForEach-Object {
    $sidBytes = $_.GetType().InvokeMember('objectSID', 'GetProperty', $null, $_, $null)
    [Security.Principal.SecurityIdentifier]::new([byte[]]$sidBytes, 0).Value
})
if ($usersSid.Value -notin $directGroupSids) {
    Add-LocalGroupMember -SID $usersSid -Member $account.SID -ErrorAction Stop
}
Assert-DedicatedBridgeMembership -User $account

foreach ($directory in @($sharePath, "$sharePath\in", "$sharePath\out", "$sharePath\logs", $toolsPathResolved)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$identity = "$env:COMPUTERNAME\$LocalUser"
$operatorIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$operatorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$rootAcl = Get-Acl -LiteralPath $sharePath
$rootAcl.SetAccessRuleProtection($true, $false)
foreach ($existingRule in @($rootAcl.Access)) {
    $rootAcl.RemoveAccessRuleSpecific($existingRule)
}
$inheritFlags = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$noInherit = [Security.AccessControl.InheritanceFlags]::None
$propagation = [Security.AccessControl.PropagationFlags]::None
$allow = [Security.AccessControl.AccessControlType]::Allow
foreach ($principal in @(
    [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
    [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),
    $operatorSid
)) {
    $rootAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $principal, [Security.AccessControl.FileSystemRights]::FullControl, $inheritFlags, $propagation, $allow))
}
$rootAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    $account.SID, [Security.AccessControl.FileSystemRights]::ReadAndExecute, $noInherit, $propagation, $allow))
Set-Acl -LiteralPath $sharePath -AclObject $rootAcl
foreach ($writableDirectory in @("$sharePath\in", "$sharePath\out", "$sharePath\logs")) {
    & icacls.exe $writableDirectory /grant:r "$($identity):(OI)(CI)M" /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to grant NTFS Modify permission on '$writableDirectory'." }
}
& icacls.exe $toolsPathResolved /remove:g $identity /T /C | Out-Null
& icacls.exe $toolsPathResolved /inheritance:r `
    /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "$($operatorIdentity):(OI)(CI)F" /T /C | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to protect host-owned tools directory '$toolsPathResolved'." }

$share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
if ($share -and -not ([IO.Path]::GetFullPath($share.Path).TrimEnd('\')).Equals($sharePath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Existing share '$ShareName' points to '$($share.Path)', not '$sharePath'. Remove or rename it manually, then retry."
}
if (-not $share) {
    New-SmbShare -Name $ShareName -Path $sharePath -ChangeAccess $identity `
        -FolderEnumerationMode AccessBased -CachingMode None -EncryptData $true | Out-Null
}
else {
    Set-SmbShare -Name $ShareName -FolderEnumerationMode AccessBased -CachingMode None -EncryptData $true -Force | Out-Null
}

foreach ($access in @(Get-SmbShareAccess -Name $ShareName)) {
    $isDesired = $access.AccountName -ieq $identity -and
        $access.AccessControlType -eq 'Allow' -and
        $access.AccessRight -eq 'Change'
    if (-not $isDesired) {
        Revoke-SmbShareAccess -Name $ShareName -AccountName $access.AccountName -Force -ErrorAction Stop | Out-Null
    }
}
Grant-SmbShareAccess -Name $ShareName -AccountName $identity -AccessRight Change -Force | Out-Null

Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort 445 -RemoteAddress @('100.64.0.0/10', 'fd7a:115c:a1e0::/48') -Profile Any | Out-Null

Write-Host "Converged \\$env:COMPUTERNAME\$ShareName for $identity."
Write-Host "Writable bridge directories: '$sharePath\in', '$sharePath\out', and '$sharePath\logs'."
Write-Host "Host-owned executable directory (not shared): '$toolsPathResolved'."
Write-Warning 'The long, strong bridge password intentionally does not expire. Store it in the password manager and rotate it only with a coordinated Ubuntu credential update.'

#Requires -Version 7.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidatePattern('^HerdrBridge$')]
    [string]$LocalUser = 'HerdrBridge',
    [string]$ShareName = 'HerdrExchange',
    [string]$Path = 'C:\HerdrExchange',
    [string]$ToolsPath = 'C:\HerdrTools',
    [string]$ReviewJobsPath = 'C:\HerdrReviewJobs',
    [string[]]$AcceptedFirewallRule = @(),
    [switch]$AllowExistingSharePath,
    [SecureString]$Password,
    [switch]$RotatePassword
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HerdrFirewallPolicy.ps1')
. (Join-Path $PSScriptRoot 'HerdrHostOwnedAclPolicy.ps1')
. (Join-Path $PSScriptRoot 'HerdrExchangePathPolicy.ps1')
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

function Test-FirewallRuleExposesSmb([object]$FirewallRule) {
    $programs = @($FirewallRule | Get-NetFirewallApplicationFilter | ForEach-Object { [string]$_.Program })
    $services = @($FirewallRule | Get-NetFirewallServiceFilter | ForEach-Object { [string]$_.Service })
    foreach ($portFilter in @($FirewallRule | Get-NetFirewallPortFilter)) {
        if (Test-HerdrFirewallFilterExposesSmb -Protocol $portFilter.Protocol -LocalPort @($portFilter.LocalPort) -Program $programs -Service $services -Owner @([string]$FirewallRule.Owner)) {
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
        if (Test-FirewallRuleExposesSmb -FirewallRule $firewallRule) {
            $program = @($firewallRule | Get-NetFirewallApplicationFilter | Select-Object -ExpandProperty Program) -join ','
            $service = @($firewallRule | Get-NetFirewallServiceFilter | Select-Object -ExpandProperty Service) -join ','
            $addressFilters = @($firewallRule | Get-NetFirewallAddressFilter)
            $localAddresses = @($addressFilters | Select-Object -ExpandProperty LocalAddress)
            $remoteAddresses = @($addressFilters | Select-Object -ExpandProperty RemoteAddress)
            if ((Test-HerdrFirewallAddressScopeIsTailnetOnly -Address $localAddresses) -or
                (Test-HerdrFirewallAddressScopeIsTailnetOnly -Address $remoteAddresses)) {
                Write-Host "Tailnet-confined inbound rule is compatible: '$($firewallRule.DisplayName)' (name=$($firewallRule.Name))."
                continue
            }
            [pscustomobject]@{
                Name = [string]$firewallRule.Name
                DisplayName = $firewallRule.DisplayName
                Program = $program
                Service = $service
                Profile = [string]$firewallRule.Profile
                LocalAddress = $localAddresses -join ','
                RemoteAddress = $remoteAddresses -join ','
            }
        }
    }
}
if ($LocalUser -cne $requiredUser) {
    throw "The SMB bridge must use the dedicated '$requiredUser' account."
}

$requestedSharePath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
$share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
if ($share -and -not ([IO.Path]::GetFullPath($share.Path).TrimEnd('\')).Equals($requestedSharePath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Existing share '$ShareName' points to '$($share.Path)', not '$requestedSharePath'. Remove or rename it manually, then retry."
}
$sharePath = Resolve-HerdrExchangePath -Path $requestedSharePath `
    -AllowExistingUnmanagedPath:$AllowExistingSharePath -ExistingManagedShare:($null -ne $share)
$toolsPathResolved = [IO.Path]::GetFullPath($ToolsPath).TrimEnd('\')
$reviewJobsPathResolved = [IO.Path]::GetFullPath($ReviewJobsPath).TrimEnd('\')
if ($toolsPathResolved.Equals($reviewJobsPathResolved, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The host-owned tools and Excel review directories must be distinct.'
}
foreach ($hostOwnedPath in @($toolsPathResolved, $reviewJobsPathResolved)) {
    if ($hostOwnedPath.Equals([IO.Path]::GetPathRoot($hostOwnedPath).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to apply a protected host-owned ACL to drive root '$hostOwnedPath'."
    }
    if ($hostOwnedPath.Equals($sharePath, [StringComparison]::OrdinalIgnoreCase) -or
        $hostOwnedPath.StartsWith("$sharePath\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Host-owned directory '$hostOwnedPath' must be outside the SMB share."
    }
}
if (Test-Path -LiteralPath (Join-Path $sharePath 'scripts')) {
    throw "Legacy shared scripts directory detected. Move reviewed executables to '$toolsPathResolved', remove the old directory, and retry."
}

$ruleName = 'Herdr Exchange SMB over Tailscale'
$potentialConflicts = @(Get-ConflictingSmbFirewallRules -ManagedRuleName $ruleName)
$acceptedNames = @($AcceptedFirewallRule | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
foreach ($acceptedName in $acceptedNames) {
    if (@($potentialConflicts | Where-Object { $_.Name -ieq $acceptedName }).Count -eq 0) {
        throw "Accepted firewall rule '$acceptedName' is not an active conflicting SMB exposure. No state was changed."
    }
    Write-Warning "Explicitly accepted firewall exposure '$acceptedName'. Record this reviewed exception in the commissioning log."
}
$conflictingRules = @($potentialConflicts | Where-Object { $_.Name -notin $acceptedNames })
if ($conflictingRules.Count -gt 0) {
    $details = @($conflictingRules | ForEach-Object {
        $escapedName = $_.Name.Replace("'", "''")
        "'$($_.DisplayName)' (name=$($_.Name); program=$($_.Program); service=$($_.Service); profile=$($_.Profile); local=$($_.LocalAddress); remote=$($_.RemoteAddress)); remediate: Disable-NetFirewallRule -Name '$escapedName'"
    }) -join '; '
    throw "Preflight found other active-profile inbound allow rules that expose TCP 445: $details. Disable each rule after review, or document the exception and rerun with -AcceptedFirewallRule '<exact-name>'. No account, ACL, share, or firewall state was changed."
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
Protect-HostOwnedTree -TargetPath $reviewJobsPathResolved -OperatorSid $operatorSid
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
Protect-HostOwnedTree -TargetPath $toolsPathResolved -OperatorSid $operatorSid

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
[IO.File]::WriteAllText((Join-Path $sharePath '.herdr-exchange-root'), 'herdr-exchange-root-v1')

Write-Host "Converged \\$env:COMPUTERNAME\$ShareName for $identity."
Write-Host "Writable bridge directories: '$sharePath\in', '$sharePath\out', and '$sharePath\logs'."
Write-Host "Host-owned executable directory (not shared): '$toolsPathResolved'."
Write-Host "Host-owned Excel review directory (not shared): '$reviewJobsPathResolved'."
Write-Warning 'The long, strong bridge password intentionally does not expire. Store it in the password manager and rotate it only with a coordinated Ubuntu credential update.'

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
    foreach ($group in @(Get-LocalGroup)) {
        $memberSids = @(Get-LocalGroupMember -Group $group -ErrorAction Stop | ForEach-Object { $_.SID.Value })
        if ($memberSids -contains $User.SID.Value -and $group.SID.Value -ne $ordinaryUsersSid) {
            throw "Bridge account '$($User.Name)' belongs to prohibited local group '$($group.Name)'. It may belong only to the built-in Users group."
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
Assert-DedicatedBridgeMembership -User $account

foreach ($directory in @($sharePath, "$sharePath\in", "$sharePath\out", "$sharePath\logs", $toolsPathResolved)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$identity = "$env:COMPUTERNAME\$LocalUser"
& icacls.exe $sharePath /remove:g $identity /T /C | Out-Null
& icacls.exe $sharePath /grant:r "$($identity):(RX)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to grant NTFS read/traverse permission on the share root.' }
foreach ($writableDirectory in @("$sharePath\in", "$sharePath\out", "$sharePath\logs")) {
    & icacls.exe $writableDirectory /grant:r "$($identity):(OI)(CI)M" /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to grant NTFS Modify permission on '$writableDirectory'." }
}
& icacls.exe $toolsPathResolved /remove:g $identity /T /C | Out-Null
$operatorIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
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

$ruleName = 'Herdr Exchange SMB over Tailscale'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort 445 -RemoteAddress @('100.64.0.0/10', 'fd7a:115c:a1e0::/48') -Profile Any | Out-Null

Write-Host "Converged \\$env:COMPUTERNAME\$ShareName for $identity."
Write-Host "Writable bridge directories: '$sharePath\in', '$sharePath\out', and '$sharePath\logs'."
Write-Host "Host-owned executable directory (not shared): '$toolsPathResolved'."
Write-Warning 'The long, strong bridge password intentionally does not expire. Store it in the password manager and rotate it only with a coordinated Ubuntu credential update.'

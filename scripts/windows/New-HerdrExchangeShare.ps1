#Requires -Version 7.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$LocalUser = 'HerdrBridge',
    [string]$ShareName = 'HerdrExchange',
    [string]$Path = 'C:\HerdrExchange',
    [SecureString]$Password
)

$ErrorActionPreference = 'Stop'
if (-not $Password) {
    $Password = Read-Host "Create a strong local password for $LocalUser" -AsSecureString
}

$account = Get-LocalUser -Name $LocalUser -ErrorAction SilentlyContinue
if (-not $account) {
    New-LocalUser -Name $LocalUser -Password $Password -PasswordNeverExpires:$false -UserMayNotChangePassword:$false -AccountNeverExpires -Description 'Non-admin SMB exchange account for the Herdr Ubuntu VM' | Out-Null
} else {
    Set-LocalUser -Name $LocalUser -Password $Password
}

foreach ($directory in @($Path, "$Path\in", "$Path\out", "$Path\logs", "$Path\scripts")) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$identity = "$env:COMPUTERNAME\$LocalUser"
& icacls.exe $Path /grant "$($identity):(OI)(CI)M" /T /C | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to grant NTFS Modify permission to the bridge account.' }

$share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
if (-not $share) {
    New-SmbShare -Name $ShareName -Path $Path -ChangeAccess $identity -FolderEnumerationMode AccessBased | Out-Null
} else {
    Grant-SmbShareAccess -Name $ShareName -AccountName $identity -AccessRight Change -Force | Out-Null
}

$ruleName = 'Herdr Exchange SMB over Tailscale'
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -RemoteAddress @('100.64.0.0/10', 'fd7a:115c:a1e0::/48') -Profile Any | Out-Null
}

Write-Host "Created \\$env:COMPUTERNAME\$ShareName for $identity."
Write-Host 'Reserve this non-admin account for the Ubuntu VM mount. Do not add it to Administrators or Remote Desktop Users.'
Write-Warning 'Store the password in the workstation password manager; it is intentionally not written to the repository.'

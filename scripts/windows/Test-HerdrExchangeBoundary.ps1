#Requires -Version 7.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$LocalUser = 'HerdrBridge',
    [string]$SharePath = 'C:\HerdrExchange',
    [string]$ToolsPath = 'C:\HerdrTools',
    [SecureString]$Password
)

$ErrorActionPreference = 'Stop'
if (-not $Password) {
    $Password = Read-Host "Password for $env:COMPUTERNAME\$LocalUser" -AsSecureString
}
$credential = [PSCredential]::new("$env:COMPUTERNAME\$LocalUser", $Password)
$probeName = ".herdr-boundary-$([Guid]::NewGuid().ToString('N')).tmp"
$toolsProbe = Join-Path $ToolsPath $probeName
$rootProbe = Join-Path $SharePath $probeName
$rootDirectoryProbe = Join-Path $SharePath ".herdr-boundary-$([Guid]::NewGuid().ToString('N')).dir"
$legacyDirectoryProbe = Join-Path $SharePath 'scripts'
$exchangeProbe = Join-Path (Join-Path $SharePath 'in') $probeName
if (Test-Path -LiteralPath $legacyDirectoryProbe) {
    throw "Cannot run the guarded-directory probe because '$legacyDirectoryProbe' already exists; inspect it manually."
}

$child = @"
`$ErrorActionPreference = 'Stop'
try {
    [IO.File]::WriteAllText('$($rootProbe.Replace("'", "''"))', 'forbidden')
    Remove-Item -LiteralPath '$($rootProbe.Replace("'", "''"))' -Force -ErrorAction SilentlyContinue
    exit 43
}
catch [UnauthorizedAccessException] {
}
try {
    [IO.Directory]::CreateDirectory('$($rootDirectoryProbe.Replace("'", "''"))') | Out-Null
    Remove-Item -LiteralPath '$($rootDirectoryProbe.Replace("'", "''"))' -Recurse -Force -ErrorAction SilentlyContinue
    exit 44
}
catch [UnauthorizedAccessException] {
}
try {
    [IO.Directory]::CreateDirectory('$($legacyDirectoryProbe.Replace("'", "''"))') | Out-Null
    Remove-Item -LiteralPath '$($legacyDirectoryProbe.Replace("'", "''"))' -Recurse -Force -ErrorAction SilentlyContinue
    exit 45
}
catch [UnauthorizedAccessException] {
}
try {
    [IO.File]::WriteAllText('$($toolsProbe.Replace("'", "''"))', 'forbidden')
    Remove-Item -LiteralPath '$($toolsProbe.Replace("'", "''"))' -Force -ErrorAction SilentlyContinue
    exit 41
}
catch [UnauthorizedAccessException] {
}
try {
    [IO.File]::WriteAllText('$($exchangeProbe.Replace("'", "''"))', 'allowed')
    Remove-Item -LiteralPath '$($exchangeProbe.Replace("'", "''"))' -Force
    exit 0
}
catch {
    exit 42
}
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
try {
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Credential $credential -LoadUserProfile -WorkingDirectory "$env:SystemRoot\Temp" `
        -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded -Wait -PassThru
}
catch {
    throw "Boundary probe could not be launched as $env:COMPUTERNAME\$LocalUser from a traversable working directory: $($_.Exception.Message)"
}

Remove-Item -LiteralPath $toolsProbe -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $rootProbe -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $rootDirectoryProbe -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $legacyDirectoryProbe -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $exchangeProbe -Force -ErrorAction SilentlyContinue
switch ($process.ExitCode) {
    0 { Write-Host 'Boundary test passed: HerdrBridge can write exchange inputs, cannot write the exchange root, and cannot write host-owned tools.' }
    41 { throw "Boundary failure: $LocalUser could write '$ToolsPath'." }
    42 { throw "Boundary failure: $LocalUser could not write '$SharePath\in'." }
    43 { throw "Boundary failure: $LocalUser could write directly to '$SharePath'." }
    44 { throw "Boundary failure: $LocalUser could create a directory directly under '$SharePath'." }
    45 { throw "Boundary failure: $LocalUser could create the guarded legacy directory '$SharePath\scripts'." }
    default { throw "Boundary probe exited unexpectedly with code $($process.ExitCode)." }
}

$managedRuleName = 'Herdr Exchange SMB over Tailscale'
$managedRules = @(Get-NetFirewallRule -DisplayName $managedRuleName -Enabled True -Direction Inbound -Action Allow -ErrorAction SilentlyContinue)
if ($managedRules.Count -ne 1) {
    throw "Boundary failure: expected exactly one enabled inbound '$managedRuleName' allow rule."
}
$managedPortFilters = @($managedRules[0] | Get-NetFirewallPortFilter)
if ($managedPortFilters.Count -ne 1 -or $managedPortFilters[0].Protocol -notin @('TCP', 6) -or
    -not (@($managedPortFilters[0].LocalPort) -contains '445')) {
    throw "Boundary failure: '$managedRuleName' is not restricted to TCP 445."
}
$managedRemoteAddresses = @($managedRules[0] | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress)
$expectedRemoteAddresses = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48')
if (@(Compare-Object -ReferenceObject $expectedRemoteAddresses -DifferenceObject $managedRemoteAddresses).Count -ne 0) {
    throw "Boundary failure: '$managedRuleName' is not restricted to the expected Tailscale address ranges."
}
$activeProfiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
    switch ([string]$_.NetworkCategory) {
        'DomainAuthenticated' { 'Domain' }
        'Private' { 'Private' }
        'Public' { 'Public' }
    }
} | Select-Object -Unique)
$conflictingRules = foreach ($firewallRule in @(Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow)) {
    if ($firewallRule.DisplayName -eq $managedRuleName) { continue }
    $ruleProfiles = @(([string]$firewallRule.Profile) -split ',\s*')
    if ($activeProfiles.Count -gt 0 -and 'Any' -notin $ruleProfiles -and
        @($ruleProfiles | Where-Object { $_ -in $activeProfiles }).Count -eq 0) {
        continue
    }
    foreach ($portFilter in @($firewallRule | Get-NetFirewallPortFilter)) {
        $includes445 = $false
        foreach ($portExpression in @($portFilter.LocalPort)) {
            $text = [string]$portExpression
            if ($text -eq '445' -or
                ($text -match '^(\d+)-(\d+)$' -and [int]$Matches[1] -le 445 -and [int]$Matches[2] -ge 445)) {
                $includes445 = $true
                break
            }
        }
        if (($portFilter.Protocol -in @('TCP', 6)) -and $includes445) {
            $firewallRule
            break
        }
    }
}
if (@($conflictingRules).Count -gt 0) {
    $names = @($conflictingRules | Select-Object -ExpandProperty DisplayName -Unique) -join "', '"
    throw "Boundary failure: other enabled inbound allow rules expose TCP 445: '$names'."
}
Write-Host 'Boundary test passed: no other enabled inbound allow rule exposes TCP 445.'

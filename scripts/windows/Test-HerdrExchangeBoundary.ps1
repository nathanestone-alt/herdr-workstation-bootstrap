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
$exchangeProbe = Join-Path (Join-Path $SharePath 'in') $probeName

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
Remove-Item -LiteralPath $exchangeProbe -Force -ErrorAction SilentlyContinue
switch ($process.ExitCode) {
    0 { Write-Host 'Boundary test passed: HerdrBridge can write exchange inputs, cannot write the exchange root, and cannot write host-owned tools.' }
    41 { throw "Boundary failure: $LocalUser could write '$ToolsPath'." }
    42 { throw "Boundary failure: $LocalUser could not write '$SharePath\in'." }
    43 { throw "Boundary failure: $LocalUser could write directly to '$SharePath'." }
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
$conflictingRules = foreach ($firewallRule in @(Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow)) {
    if ($firewallRule.DisplayName -eq $managedRuleName) { continue }
    foreach ($portFilter in @($firewallRule | Get-NetFirewallPortFilter)) {
        $includes445 = $false
        foreach ($portExpression in @($portFilter.LocalPort)) {
            $text = [string]$portExpression
            if ($text -eq 'Any' -or $text -eq '445' -or
                ($text -match '^(\d+)-(\d+)$' -and [int]$Matches[1] -le 445 -and [int]$Matches[2] -ge 445)) {
                $includes445 = $true
                break
            }
        }
        if (($portFilter.Protocol -in @('TCP', 6, 'Any', 256)) -and $includes445) {
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

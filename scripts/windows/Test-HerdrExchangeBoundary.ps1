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
$exchangeProbe = Join-Path (Join-Path $SharePath 'in') $probeName

$child = @"
`$ErrorActionPreference = 'Stop'
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
$process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Credential $credential -LoadUserProfile -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded `
    -Wait -PassThru

Remove-Item -LiteralPath $toolsProbe -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $exchangeProbe -Force -ErrorAction SilentlyContinue
switch ($process.ExitCode) {
    0 { Write-Host 'Boundary test passed: HerdrBridge can write exchange inputs and cannot write host-owned tools.' }
    41 { throw "Boundary failure: $LocalUser could write '$ToolsPath'." }
    42 { throw "Boundary failure: $LocalUser could not write '$SharePath\in'." }
    default { throw "Boundary probe exited unexpectedly with code $($process.ExitCode)." }
}

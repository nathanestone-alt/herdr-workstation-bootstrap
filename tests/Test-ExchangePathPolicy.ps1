$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrExchangePathPolicy.ps1')

function Assert-Rejected([string]$Path, [string]$Expected, [switch]$AllowExisting) {
    try {
        Resolve-HerdrExchangePath -Path $Path -AllowExistingUnmanagedPath:$AllowExisting | Out-Null
        throw "Expected '$Path' to be rejected."
    }
    catch {
        if (-not $_.Exception.Message.Contains($Expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unexpected rejection for '$Path': $($_.Exception.Message)"
        }
    }
}

$driveRoot = [IO.Path]::GetPathRoot($env:SystemRoot)
Assert-Rejected -Path $driveRoot -Expected 'drive root'
Assert-Rejected -Path $env:SystemRoot -Expected 'protected system path'
Assert-Rejected -Path (Join-Path $env:SystemRoot 'Temp') -Expected 'protected system path'
Assert-Rejected -Path $env:ProgramData -Expected 'protected system path'
Assert-Rejected -Path (Join-Path $env:SystemDrive 'Users') -Expected 'protected system path'
Assert-Rejected -Path $env:SystemRoot -Expected 'protected system path' -AllowExisting

$fixture = Join-Path $PSScriptRoot "herdr-exchange-policy-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    Assert-Rejected -Path $fixture -Expected 'not marked as Herdr-managed'
    $resolved = Resolve-HerdrExchangePath -Path $fixture -AllowExistingUnmanagedPath
    if (-not $resolved.Equals($fixture, [StringComparison]::OrdinalIgnoreCase)) { throw 'Explicit authorization returned the wrong path.' }
    [IO.File]::WriteAllText((Join-Path $fixture '.herdr-exchange-root'), 'herdr-exchange-root-v1')
    Assert-Rejected -Path $fixture -Expected 'not marked as Herdr-managed'
    $resolved = Resolve-HerdrExchangePath -Path $fixture -ExistingManagedShare
    if (-not $resolved.Equals($fixture, [StringComparison]::OrdinalIgnoreCase)) { throw 'Managed-marker convergence returned the wrong path.' }
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

$freshPath = Join-Path $PSScriptRoot "herdr-exchange-new-$([Guid]::NewGuid().ToString('N'))"
$resolvedFresh = Resolve-HerdrExchangePath -Path $freshPath
if (-not $resolvedFresh.Equals($freshPath, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $freshPath)) {
    throw 'Fresh-path validation mutated the path or returned the wrong value.'
}
Write-Host 'Exchange share path policy regression test passed.'

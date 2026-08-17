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
Assert-Rejected -Path '\\?\C:\Windows' -Expected 'device namespace' -AllowExisting
Assert-Rejected -Path '\\host\share\sub' -Expected 'UNC path'

$fixture = Join-Path $PSScriptRoot "herdr-exchange-policy-$([Guid]::NewGuid().ToString('N'))"
$fixtureProtectedPath = @(Join-Path $PSScriptRoot 'synthetic-protected-root')
$bootstrapText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\bootstrap.ps1')
$windowsBaseBody = ($bootstrapText -split 'function Enable-HyperV', 2)[0]
$expectedWindowsBaseDirectoryLoop = "foreach (`$directory in @('C:\dev', 'C:\HerdrTools')) {"
if (-not $windowsBaseBody.Contains($expectedWindowsBaseDirectoryLoop, [StringComparison]::Ordinal)) {
    throw 'WindowsBase directory allowlist changed; review it before allowing any additional host path.'
}
if ($windowsBaseBody -match '[''"]C:\\HerdrExchange(?:\\|[''"])') {
    throw 'WindowsBase must not pre-create C:\HerdrExchange; the share script owns its creation and marker.'
}

$nonFixedPath = 'Z:\HerdrExchange'
foreach ($driveTypeUnderTest in [Enum]::GetValues([IO.DriveType]) | Where-Object { $_ -ne [IO.DriveType]::Fixed }) {
    $resolver = { param($Root) $driveTypeUnderTest }.GetNewClosure()
    try {
        Resolve-HerdrExchangePath -Path $nonFixedPath -ProtectedRoots $fixtureProtectedPath `
            -DriveTypeResolver $resolver | Out-Null
        throw "Expected synthetic drive type '$driveTypeUnderTest' to be rejected."
    }
    catch {
        if (-not $_.Exception.Message.Contains('local fixed drive', [StringComparison]::OrdinalIgnoreCase)) { throw }
    }
}
$fixedResolver = { param($Root) [IO.DriveType]::Fixed }
$resolvedFixed = Resolve-HerdrExchangePath -Path $nonFixedPath -ProtectedRoots $fixtureProtectedPath -DriveTypeResolver $fixedResolver
if (-not $resolvedFixed.Equals($nonFixedPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Synthetic fixed-drive validation returned the wrong path.'
}

$assignedRoots = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name })
$unassignedRoot = @(68..90 | ForEach-Object { "$([char]$_):\" } | Where-Object { $_ -notin $assignedRoots })[0]
if ([string]::IsNullOrWhiteSpace($unassignedRoot)) { throw 'Could not find an unassigned drive letter for the default-resolver test.' }
$unassignedPath = $unassignedRoot + 'HerdrExchange'
try {
    Resolve-HerdrExchangePath -Path $unassignedPath -ProtectedRoots $fixtureProtectedPath | Out-Null
    throw 'Expected the production drive-type resolver to reject an unassigned drive.'
}
catch {
    if (-not $_.Exception.Message.Contains('local fixed drive', [StringComparison]::OrdinalIgnoreCase)) { throw }
}

try {
    Resolve-HerdrExchangePath -Path $env:SystemRoot -AllowExistingUnmanagedPath -ProtectedRoots $null | Out-Null
    throw 'Expected an explicitly null protected-root set to be rejected.'
}
catch {
    if (-not $_.Exception.Message.Contains('ProtectedRoots', [StringComparison]::OrdinalIgnoreCase)) { throw }
}
try {
    Resolve-HerdrExchangePath -Path $nonFixedPath -ProtectedRoots $fixtureProtectedPath -DriveTypeResolver $null | Out-Null
    throw 'Expected an explicitly null drive-type resolver to be rejected.'
}
catch {
    if (-not $_.Exception.Message.Contains('DriveTypeResolver', [StringComparison]::OrdinalIgnoreCase)) { throw }
}

try {
    Resolve-HerdrExchangePath -Path $PSScriptRoot -AllowExistingUnmanagedPath -ProtectedRoots $fixtureProtectedPath `
        -DriveTypeResolver $fixedResolver | Out-Null
    throw 'Expected a candidate ancestor of a protected root to be rejected.'
}
catch {
    if (-not $_.Exception.Message.Contains('protected system path', [StringComparison]::OrdinalIgnoreCase)) { throw }
}

try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    try {
        Resolve-HerdrExchangePath -Path $fixture -ProtectedRoots $fixtureProtectedPath | Out-Null
        throw 'Expected the existing unmarked fixture to be rejected.'
    }
    catch {
        if (-not $_.Exception.Message.Contains('not marked as Herdr-managed', [StringComparison]::OrdinalIgnoreCase)) { throw }
    }
    $resolved = Resolve-HerdrExchangePath -Path $fixture -AllowExistingUnmanagedPath -ProtectedRoots $fixtureProtectedPath
    if (-not $resolved.Equals($fixture, [StringComparison]::OrdinalIgnoreCase)) { throw 'Explicit authorization returned the wrong path.' }
    $markerPath = Join-Path $fixture '.herdr-exchange-root'
    foreach ($invalidMarker in @('', 'herdr-exchange-root-v0', "herdr-exchange-root-v1`n")) {
        [IO.File]::WriteAllText($markerPath, $invalidMarker)
        try {
            Resolve-HerdrExchangePath -Path $fixture -ExistingManagedShare -ProtectedRoots $fixtureProtectedPath | Out-Null
            throw "Expected invalid marker content '$invalidMarker' to be rejected."
        }
        catch {
            if (-not $_.Exception.Message.Contains('not marked as Herdr-managed', [StringComparison]::OrdinalIgnoreCase)) { throw }
        }
    }
    [IO.File]::WriteAllText($markerPath, 'herdr-exchange-root-v1')
    try {
        Resolve-HerdrExchangePath -Path $fixture -ProtectedRoots $fixtureProtectedPath | Out-Null
        throw 'Expected a marker without a matching share to be rejected.'
    }
    catch {
        if (-not $_.Exception.Message.Contains('not marked as Herdr-managed', [StringComparison]::OrdinalIgnoreCase)) { throw }
    }
    $resolved = Resolve-HerdrExchangePath -Path $fixture -ExistingManagedShare -ProtectedRoots $fixtureProtectedPath
    if (-not $resolved.Equals($fixture, [StringComparison]::OrdinalIgnoreCase)) { throw 'Managed-marker convergence returned the wrong path.' }
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

$junctionTarget = Join-Path $PSScriptRoot "herdr-exchange-target-$([Guid]::NewGuid().ToString('N'))"
$junctionPath = Join-Path $PSScriptRoot "herdr-exchange-junction-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $junctionTarget | Out-Null
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    try {
        Resolve-HerdrExchangePath -Path $junctionPath -AllowExistingUnmanagedPath -ProtectedRoots $fixtureProtectedPath | Out-Null
        throw 'Expected a reparse-point fixture to be rejected.'
    }
    catch {
        if (-not $_.Exception.Message.Contains('reparse point', [StringComparison]::OrdinalIgnoreCase)) { throw }
    }
}
finally {
    if (Test-Path -LiteralPath $junctionPath) { Remove-Item -LiteralPath $junctionPath -Force }
    if (Test-Path -LiteralPath $junctionTarget) { Remove-Item -LiteralPath $junctionTarget -Recurse -Force }
}

$freshPath = Join-Path $PSScriptRoot "herdr-exchange-new-$([Guid]::NewGuid().ToString('N'))"
$resolvedFresh = Resolve-HerdrExchangePath -Path $freshPath -ProtectedRoots $fixtureProtectedPath
if (-not $resolvedFresh.Equals($freshPath, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $freshPath)) {
    throw 'Fresh-path validation mutated the path or returned the wrong value.'
}
Write-Host 'Exchange share path policy regression test passed.'

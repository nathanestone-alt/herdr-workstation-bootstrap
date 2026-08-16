$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$bootstrapPath = Join-Path $repoRoot 'bootstrap.ps1'
$bootstrapCommand = Get-Command $bootstrapPath
$calleeCommand = Get-Command (Join-Path $repoRoot 'scripts\windows\New-HerdrUbuntuVM.ps1')
$stageAttribute = @($bootstrapCommand.Parameters.Stage.Attributes | Where-Object {
    $_ -is [Management.Automation.ValidateSetAttribute]
}) | Select-Object -First 1
if (-not $stageAttribute -or 'VmComplete' -notin $stageAttribute.ValidValues) {
    throw 'bootstrap.ps1 does not expose the documented VmComplete stage.'
}

$expectedCalleeParameters = [ordered]@{
    ProcessorCount = [int]
    MinimumMemoryBytes = [UInt64]
    StartupMemoryBytes = [UInt64]
    MaximumMemoryBytes = [UInt64]
    HostProcessorReserve = [int]
    HostMemoryReserveBytes = [UInt64]
    InstallationComplete = [Management.Automation.SwitchParameter]
    IsoPath = [string]
}
foreach ($entry in $expectedCalleeParameters.GetEnumerator()) {
    if (-not $calleeCommand.Parameters.ContainsKey($entry.Key)) {
        throw "New-HerdrUbuntuVM.ps1 does not accept dispatcher key '$($entry.Key)'."
    }
    if ($calleeCommand.Parameters[$entry.Key].ParameterType -ne $entry.Value) {
        throw "New-HerdrUbuntuVM.ps1 parameter '$($entry.Key)' has type '$($calleeCommand.Parameters[$entry.Key].ParameterType)', expected '$($entry.Value)'."
    }
}

$content = Get-Content -Raw -LiteralPath $bootstrapPath
foreach ($mapping in @(
    'ProcessorCount = $VmProcessorCount',
    'MinimumMemoryBytes = $VmMinimumMemoryBytes',
    'StartupMemoryBytes = $VmStartupMemoryBytes',
    'MaximumMemoryBytes = $VmMaximumMemoryBytes',
    'HostProcessorReserve = $VmHostProcessorReserve',
    'HostMemoryReserveBytes = $VmHostMemoryReserveBytes',
    '$vmParameters.InstallationComplete = $true'
)) {
    if (-not $content.Contains($mapping, [StringComparison]::Ordinal)) {
        throw "VmComplete dispatcher mapping is missing: $mapping"
    }
}

foreach ($relativeDoc in @(
    'AGENT-HANDOFF.md',
    'MANUAL-START.md',
    'HERDR_WORKSTATION_DEPENDENCY_SETUP_PLAN.md'
)) {
    $doc = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $relativeDoc)
    if (-not $doc.Contains('bootstrap.ps1 -Stage VmComplete', [StringComparison]::Ordinal)) {
        throw "$relativeDoc does not use the supported VmComplete entry point."
    }
    if ($doc.Contains('New-HerdrUbuntuVM.ps1 -InstallationComplete', [StringComparison]::Ordinal)) {
        throw "$relativeDoc still documents the lower-level completion entry point."
    }
}

Write-Host 'Bootstrap VM completion dispatcher regression test passed.'

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$manifest = @(
    "test_herdr_skill_compatibility.ps1",
    "test_herdr_workflow_profile_reporting.ps1",
    "test_herdr_coordination.ps1",
    "test_herdr_workflow.ps1",
    "test_herdr_workflow_stress.ps1",
    "test_herdr_naming_lifecycle.ps1",
    "test_herdr_pane_registry.ps1",
    "test_herdr_pane_registry_cli.ps1",
    "test_codex_session_refresh.ps1",
    "test_claude_session_refresh.ps1",
    "test_herdr_workflow_empty_ledger.ps1",
    "test_ubuntu_portability.ps1"
)

$passed = 0
foreach ($name in $manifest) {
    $path = Join-Path $PSScriptRoot $name
    Write-Output "RUN: pwsh -NoProfile -File scripts/$name"
    & pwsh -NoProfile -File $path
    if ($LASTEXITCODE -ne 0) {
        throw "Manifest entry failed: $name (exit $LASTEXITCODE)"
    }
    $passed++
}

Write-Output "PASS: Ubuntu portability manifest ($passed entries)"

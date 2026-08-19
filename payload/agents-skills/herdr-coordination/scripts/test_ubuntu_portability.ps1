[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptsRoot = $PSScriptRoot
$issues = [Collections.Generic.List[string]]::new()

function Add-Issue {
    param([Parameter(Mandatory)][string]$Message)
    $issues.Add($Message)
}

function Get-Lines {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.File]::ReadAllLines($Path)
}

$productionFiles = @(
    "herdr_coordination.ps1",
    "herdr_pane_registry.ps1",
    "herdr_workflow.ps1",
    "sync_installed_skill.ps1"
)

$transportFixtureFiles = @(
    "test_herdr_coordination.ps1",
    "test_herdr_naming_lifecycle.ps1",
    "test_herdr_pane_registry_cli.ps1",
    "test_herdr_workflow.ps1",
    "test_herdr_workflow_roundtrip.ps1",
    "test_herdr_workflow_stress.ps1",
    "test_herdr_workflow_profile_reporting.ps1",
    "test_codex_session_refresh.ps1",
    "test_claude_session_refresh.ps1"
)

$windowsGatedFixtureFiles = @(
    "test_codex_session_refresh.ps1",
    "test_claude_session_refresh.ps1",
    "test_herdr_naming_lifecycle.ps1",
    "test_herdr_pane_registry_cli.ps1",
    "test_herdr_workflow.ps1",
    "test_herdr_workflow_roundtrip.ps1",
    "test_herdr_workflow_stress.ps1",
    "test_herdr_workflow_profile_reporting.ps1",
    "test_herdr_coordination.ps1"
)

foreach ($name in $productionFiles) {
    $path = Join-Path $scriptsRoot $name
    $lines = Get-Lines -Path $path
    $text = $lines -join "`n"

    $driveRootedWindowsPathPattern = '(?i)(?:^|["'']\s*)[A-Z]:\\[^"''\r\n]+'
    if ([regex]::IsMatch($text, $driveRootedWindowsPathPattern)) {
        Add-Issue "$name contains a drive-rooted Windows path in production code."
    }
    if ($text -match '(?i)\\\\') {
        Add-Issue "$name contains a doubled Windows path separator in production code."
    }
    if ($text -match '\$env:PATH\s*=\s*[^\r\n;]*;[^\r\n]*') {
        Add-Issue "$name assigns PATH with a hard-coded semicolon separator."
    }
    if ($text -match '(?i)@echo off|%~dp0|findstr|\.cmd') {
        Add-Issue "$name contains a Windows command-wrapper primitive."
    }
    if ($name -ne "sync_installed_skill.ps1" -and $text -match '\$env:USERPROFILE') {
        Add-Issue "$name requires USERPROFILE instead of using the platform home resolver."
    }
    if ($name -eq "sync_installed_skill.ps1" -and
        $text -notmatch '\$env:HOME' -and
        $text -notmatch '\[Environment\]::GetFolderPath\("UserProfile"\)') {
        Add-Issue "$name has no HOME or platform user-profile fallback."
    }
    if ($text -match 'Start-Process[^\r\n]*-WindowStyle' -and $text -notmatch 'if \(\$IsWindows\)') {
        Add-Issue "$name uses WindowStyle without a Windows-only guard."
    }
}

foreach ($name in $transportFixtureFiles) {
    $path = Join-Path $scriptsRoot $name
    $text = [IO.File]::ReadAllText($path)
    if ($text -match '\$env:PATH\s*=\s*[^\r\n;]*;[^\r\n]*') {
        Add-Issue "$name assigns PATH with a hard-coded semicolon separator."
    }
    if ($text -notmatch '\[IO\.Path\]::PathSeparator|\$pathSeparator|Set-HermeticTransportPath') {
        Add-Issue "$name does not use a platform PATH separator for its transport fixture."
    }
}

$excludedStaticScanFiles = @(
    "test_ubuntu_portability.ps1",
    "run_ubuntu_portability_manifest.ps1"
)
$allScriptFiles = @(Get-ChildItem -LiteralPath $scriptsRoot -Filter "*.ps1" -File |
    Where-Object { $excludedStaticScanFiles -notcontains $_.Name })
foreach ($file in $allScriptFiles) {
    $name = $file.Name
    $text = [IO.File]::ReadAllText($file.FullName)
    if ($text -match '(?i)@echo off|%~dp0|findstr|\.cmd') {
        if ($windowsGatedFixtureFiles -notcontains $name) {
            Add-Issue "$name contains Windows-only fixture syntax without an allowlisted Windows gate."
        }
        elseif ($text -notmatch '\$isWindowsPlatform\s*=|if \(\$isWindowsPlatform\)|if \(\$IsWindows\)') {
            Add-Issue "$name contains Windows-only fixture syntax without an explicit platform gate."
        }
    }
}

$requiredPortableContracts = @{
    "herdr_coordination.ps1" = @("function Test-CurrentProcessDescendsFrom", "/proc")
    "herdr_workflow.ps1" = @("function Get-WorkflowViews")
    "test_herdr_workflow_profile_reporting.ps1" = @("report-profile", "PathSeparator")
    "sync_installed_skill.ps1" = @("Resolve-UserHomePath", "Join-Path", "Test-SamePath")
    "test_herdr_coordination.ps1" = @("Assert-MissingTransportFailsClosed", "Set-HermeticTransportPath")
    "test_herdr_workflow.ps1" = @("isWindowsPlatform", "PathSeparator")
    "test_herdr_workflow_stress.ps1" = @("isWindowsPlatform", "PathSeparator")
    "test_herdr_naming_lifecycle.ps1" = @("isWindowsPlatform", "PathSeparator")
    "test_herdr_pane_registry_cli.ps1" = @("isWindowsPlatform", "PathSeparator")
}
foreach ($entry in $requiredPortableContracts.GetEnumerator()) {
    $path = Join-Path $scriptsRoot $entry.Key
    $text = [IO.File]::ReadAllText($path)
    foreach ($marker in $entry.Value) {
        if ($text -notmatch [regex]::Escape($marker)) {
            Add-Issue "$($entry.Key) is missing required portability contract '$marker'."
        }
    }
}

if ($issues.Count -gt 0) {
    $issues | ForEach-Object { "FAIL: $_" }
    exit 1
}

Write-Output "PASS: Ubuntu portability scan ($($allScriptFiles.Count) PowerShell scripts checked)"

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$skillPath = Join-Path $root "SKILL.md"
$referencePath = Join-Path $root "references\herdr-workflow.md"
$syncPath = Join-Path $PSScriptRoot "sync_installed_skill.ps1"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

foreach ($path in @($skillPath, $referencePath, $syncPath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Missing required file: $path"
}

$skill = Get-Content -Raw -LiteralPath $skillPath
$reference = Get-Content -Raw -LiteralPath $referencePath
$sync = Get-Content -Raw -LiteralPath $syncPath
try { [scriptblock]::Create($sync) | Out-Null } catch { throw "Sync script does not parse: $($_.Exception.Message)" }

Assert-True ([regex]::IsMatch($skill, '(?s)\A---\r?\n.*?\r?\n---\r?\n')) "SKILL.md lacks frontmatter"
Assert-True ($skill -match '(?m)^name:\s*st-herdr-dispatch\s*$') "Frontmatter name is wrong"
$description = [regex]::Match($skill, '(?m)^description:\s*(.+)$').Groups[1].Value
Assert-True ($description.IndexOf('Automatically support provider-neutral dispatch', [StringComparison]::OrdinalIgnoreCase) -ge 0) "Description does not trigger automatically for dispatched workflow nodes"
Assert-True ($description.IndexOf('worker, handoff, independent review, gate, or durable completion return', [StringComparison]::OrdinalIgnoreCase) -ge 0) "Description omits normal dispatch trigger classes"
Assert-True ($description.IndexOf('Activate Herdr pane/session/ACK/watchdog mechanics only when', [StringComparison]::OrdinalIgnoreCase) -ge 0) "Description does not isolate Herdr-only mechanics"
Assert-True ($skill.IndexOf('Explicit invocation: `$st-herdr-dispatch`', [StringComparison]::Ordinal) -ge 0) "Explicit invocation syntax is missing"

$requiredSkillTerms = @(
    "orchestrated workflow reaches a node",
    "Apply this skill automatically",
    "validates the resolved worker and adapter boundary",
    "resolved_worker",
    "provider: <explicit provider>",
    "model: <explicit model>",
    "reasoning_effort: <explicit effort>",
    "service_tier: <explicit tier>",
    "Reject a packet that omits any field",
    "Never inherit the resident orchestrator",
    "The orchestrator may be any model",
    "native isolated noninteractive execution",
    "compatible native subagent execution",
    "ephemeral background Herdr execution",
    "visible Herdr pane",
    'Absence of `HERDR_ENV` is irrelevant',
    "references/herdr-workflow.md",
    "PASS/BLOCK/ERROR",
    "Repository governance controls",
    "at most one transport retry",
    "ERROR/INCOMPLETE",
    "Do not forward full orchestrator or builder transcripts"
)
foreach ($term in $requiredSkillTerms) {
    Assert-True ($skill.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) "Missing skill contract term: $term"
}

$skillFlat = [regex]::Replace($skill, '\s+', ' ')
foreach ($term in @(
    "selected adapter returns the complete result body",
    "When Herdr is the selected or explicitly requested adapter"
)) {
    Assert-True ($skillFlat.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) "Missing adapter-neutral completion term: $term"
}

$forbiddenConcreteRouting = @('Fable', 'Luna', 'Sol Medium', 'Opus', 'Sonnet', 'gpt-5')
foreach ($term in $forbiddenConcreteRouting) {
    Assert-True ($skill.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -lt 0) "Adapter hard-codes a routing choice: $term"
}

Assert-True ($skill.IndexOf('merge, push, issue close', [StringComparison]::OrdinalIgnoreCase) -lt 0) "Adapter duplicates repository authorization policy"
Assert-True ($skill.IndexOf('pwsh -NoProfile -File "$workflow"', [StringComparison]::OrdinalIgnoreCase) -lt 0) "Operational helper commands were not progressively disclosed"

$requiredReferenceTerms = @(
    "## Contents",
    'if ($env:HERDR_ENV -ne "1")',
    'pwsh -NoProfile -File "$coord" -Action discover',
    "DISPATCH BRIEF",
    "Resolved worker: <provider, model, reasoning effort, service tier; all required>",
    "Plain send versus tracked workflow",
    'pwsh -NoProfile -File "$workflow" -Action preflight',
    'pwsh -NoProfile -File "$workflow" -Action request',
    'pwsh -NoProfile -File "$workflow" -Action ack',
    'pwsh -NoProfile -File "$workflow" -Action complete',
    'pwsh -NoProfile -File "$workflow" -Action ack-return',
    'pwsh -NoProfile -File "$watchdog"',
    "GATE BRIEF",
    "Pane naming",
    "Stop conditions"
)
foreach ($term in $requiredReferenceTerms) {
    Assert-True ($reference.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -ge 0) "Missing Herdr workflow reference term: $term"
}

Assert-True ($sync.IndexOf(".agents\skills\st-herdr-dispatch", [StringComparison]::OrdinalIgnoreCase) -ge 0) "Sync script omits first managed root"
Assert-True ($sync.IndexOf(".claude\skills\st-herdr-dispatch", [StringComparison]::OrdinalIgnoreCase) -ge 0) "Sync script omits second managed root"
Assert-True ($sync.IndexOf('"check", "install"', [StringComparison]::OrdinalIgnoreCase) -ge 0) "Sync script omits check/install actions"
Assert-True ($sync.IndexOf("source_commit", [StringComparison]::OrdinalIgnoreCase) -ge 0) "Sync output omits source commit"
Assert-True ($sync.IndexOf("installed_commit", [StringComparison]::OrdinalIgnoreCase) -ge 0) "Sync output omits installed commit"
Assert-True ($sync.IndexOf("current", [StringComparison]::OrdinalIgnoreCase) -ge 0) "Sync output omits current proof"

function Invoke-GitText {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git fixture command failed: $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine).Trim()
}

# Regression: check must fail closed when one isolated install is stale.
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture = Join-Path $tempRoot ("st-herdr-dispatch-sync-" + [Guid]::NewGuid().ToString('N'))
try {
    $sourceRemote = Invoke-GitText -Repository $root -Arguments @('remote', 'get-url', 'origin')
    $history = @(Invoke-GitText -Repository $root -Arguments @('rev-list', '--max-count=2', 'HEAD')) -split '\r?\n' | Where-Object { $_ }
    Assert-True ($history.Count -ge 2) 'Regression fixture requires at least two source commits'
    $stale = Join-Path $fixture 'stale'
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    & git clone --no-local $root $stale 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not clone stale regression target' }
    $null = Invoke-GitText -Repository $stale -Arguments @('remote', 'set-url', 'origin', $sourceRemote)
    $null = Invoke-GitText -Repository $stale -Arguments @('switch', '--detach', $history[1].Trim())
    $probe = & pwsh -NoProfile -File $syncPath -Action check -InstallRoots $stale 2>&1
    $probeExit = $LASTEXITCODE
    Assert-True ($probeExit -ne 0) 'Stale isolated target did not make check fail closed'
    Assert-True (($probe -join [Environment]::NewLine) -match 'not at source commit|Installed skill did not advance') 'Check failure did not identify the stale target'
}
finally {
    if (Test-Path -LiteralPath $fixture) {
        Assert-True ($fixture.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) 'Unsafe regression fixture removal path'
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}

Write-Output "PASS: st-herdr-dispatch is a routing-preserving optional Herdr adapter"

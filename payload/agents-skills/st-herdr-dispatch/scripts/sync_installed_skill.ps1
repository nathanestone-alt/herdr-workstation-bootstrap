[CmdletBinding()]
param(
    [ValidateSet("check", "install")]
    [string]$Action = "check",

    [string[]]$InstallRoots = @(
        (Join-Path $env:USERPROFILE ".agents\skills\st-herdr-dispatch"),
        (Join-Path $env:USERPROFILE ".claude\skills\st-herdr-dispatch")
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-GitText {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git -C $Repository $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Assert-CleanRepository {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Role
    )

    $status = Invoke-GitText -Repository $Repository -Arguments @("status", "--porcelain")
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw "$Role repository has uncommitted changes and will not be synchronized: $Repository"
    }
}

$sourceRoot = Get-FullPath (Split-Path -Parent $PSScriptRoot)
$sourceGitRoot = Get-FullPath (Invoke-GitText -Repository $sourceRoot -Arguments @("rev-parse", "--show-toplevel"))
if ($sourceGitRoot -ine $sourceRoot) {
    throw "The synchronization script must run from the root of the tracked skill repository."
}
Assert-CleanRepository -Repository $sourceRoot -Role "Source"
$sourceHead = Invoke-GitText -Repository $sourceRoot -Arguments @("rev-parse", "HEAD")
$sourceRemote = Invoke-GitText -Repository $sourceRoot -Arguments @("remote", "get-url", "origin")
if ([string]::IsNullOrWhiteSpace($sourceRemote)) {
    throw "Source repository origin is empty."
}

$results = @()
foreach ($installPath in $InstallRoots) {
    $targetRoot = Get-FullPath $installPath
    if ($targetRoot -ieq $sourceRoot) {
        throw "Source and installed skill paths must be different: $targetRoot"
    }

    if (-not (Test-Path -LiteralPath $targetRoot)) {
        if ($Action -eq "check") {
            throw "Installed skill is missing: $targetRoot"
        }
        $targetParent = Split-Path -Parent $targetRoot
        if (-not (Test-Path -LiteralPath $targetParent)) {
            New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        }
        $cloneOutput = & git clone $sourceRemote $targetRoot 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed for ${targetRoot}: $($cloneOutput -join [Environment]::NewLine)"
        }
    }

    $targetGitRoot = Get-FullPath (Invoke-GitText -Repository $targetRoot -Arguments @("rev-parse", "--show-toplevel"))
    if ($targetGitRoot -ine $targetRoot) {
        throw "Installed skill is not the root of its own Git checkout: $targetRoot"
    }
    Assert-CleanRepository -Repository $targetRoot -Role "Installed"

    $targetRemote = Invoke-GitText -Repository $targetRoot -Arguments @("remote", "get-url", "origin")
    if (-not [String]::Equals($targetRemote, $sourceRemote, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Installed origin mismatch: $targetRoot uses $targetRemote, source uses $sourceRemote"
    }

    $null = Invoke-GitText -Repository $targetRoot -Arguments @("fetch", "origin")
    $objectCheck = & git -C $targetRoot cat-file -e ($sourceHead + "^{commit}") 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Source commit $sourceHead is not present in the canonical origin for $targetRoot."
    }

    $targetHead = Invoke-GitText -Repository $targetRoot -Arguments @("rev-parse", "HEAD")
    if ($Action -eq "install" -and $targetHead -ne $sourceHead) {
        $null = Invoke-GitText -Repository $targetRoot -Arguments @("merge", "--ff-only", $sourceHead)
        $targetHead = Invoke-GitText -Repository $targetRoot -Arguments @("rev-parse", "HEAD")
    }

    $current = $targetHead -eq $sourceHead
    if (-not $current) {
        throw "Installed skill did not advance to source commit ${sourceHead}: $targetRoot"
    }

    $results += [pscustomobject]@{
        install_root = $targetRoot
        installed_commit = $targetHead
        current = $current
    }
}

[pscustomobject]@{
    action = $Action
    source_root = $sourceRoot
    source_commit = $sourceHead
    canonical_origin = $sourceRemote
    installs = $results
} | ConvertTo-Json -Depth 5
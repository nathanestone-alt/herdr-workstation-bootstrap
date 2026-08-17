[CmdletBinding()]
param(
    [ValidateSet("check", "install")]
    [string]$Action = "check",

    [string]$InstallPath = (Join-Path $env:USERPROFILE ".agents\skills\herdr-coordination")
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

$sourceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$targetRoot = [IO.Path]::GetFullPath($InstallPath)
if ($sourceRoot.TrimEnd('\') -ieq $targetRoot.TrimEnd('\')) {
    throw "Source and installed skill paths must be different."
}

$sourceGitRoot = [IO.Path]::GetFullPath(
    (Invoke-GitText -Repository $sourceRoot -Arguments @("rev-parse", "--show-toplevel"))
)
if ($sourceGitRoot.TrimEnd('\') -ine $sourceRoot.TrimEnd('\')) {
    throw "The synchronization script must run from the root of the tracked skill repository."
}
Assert-CleanRepository -Repository $sourceRoot -Role "Source"
$sourceHead = Invoke-GitText -Repository $sourceRoot -Arguments @("rev-parse", "HEAD")
$sourceRemote = Invoke-GitText -Repository $sourceRoot -Arguments @("remote", "get-url", "origin")

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
        throw "git clone failed: $($cloneOutput -join [Environment]::NewLine)"
    }
}

$targetGitRoot = [IO.Path]::GetFullPath(
    (Invoke-GitText -Repository $targetRoot -Arguments @("rev-parse", "--show-toplevel"))
)
if ($targetGitRoot.TrimEnd('\') -ine $targetRoot.TrimEnd('\')) {
    throw "Installed skill is not the root of its own Git checkout: $targetRoot"
}
Assert-CleanRepository -Repository $targetRoot -Role "Installed"

$null = Invoke-GitText -Repository $targetRoot -Arguments @("fetch", "origin")
$objectCheck = & git -C $targetRoot cat-file -e "$sourceHead`^{commit}" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Source commit $sourceHead is not present in the canonical origin. Push the source repository first."
}

$targetHead = Invoke-GitText -Repository $targetRoot -Arguments @("rev-parse", "HEAD")
if ($Action -eq "install" -and $targetHead -ne $sourceHead) {
    $null = Invoke-GitText -Repository $targetRoot -Arguments @("merge", "--ff-only", $sourceHead)
    $targetHead = Invoke-GitText -Repository $targetRoot -Arguments @("rev-parse", "HEAD")
}

$isCurrent = $targetHead -eq $sourceHead
if ($Action -eq "install" -and -not $isCurrent) {
    throw "Installed skill did not advance to source commit $sourceHead."
}

[pscustomobject]@{
    action = $Action
    source_root = $sourceRoot
    source_commit = $sourceHead
    canonical_origin = $sourceRemote
    install_root = $targetRoot
    installed_commit = $targetHead
    current = $isCurrent
} | ConvertTo-Json -Depth 5

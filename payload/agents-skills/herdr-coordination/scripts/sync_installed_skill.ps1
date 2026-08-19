[CmdletBinding()]
param(
    [ValidateSet("check", "install")]
    [string]$Action = "check",

    [string]$InstallPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$isWindowsPlatform = [IO.Path]::DirectorySeparatorChar -eq [char]92

function Resolve-UserHomePath {
    $candidates = @(
        $env:HOME,
        $env:USERPROFILE,
        [Environment]::GetFolderPath("UserProfile")
    )

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        try {
            $fullCandidate = [IO.Path]::GetFullPath([string]$candidate)
        }
        catch {
            continue
        }

        if (Test-Path -LiteralPath $fullCandidate -PathType Container) {
            return $fullCandidate
        }
    }

    throw "Unable to resolve a usable user home directory. Set HOME or USERPROFILE, or pass -InstallPath explicitly."
}

function Resolve-ComparablePath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $trimCharacters = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if (-not [string]::IsNullOrEmpty($root) -and $fullPath.Length -gt $root.Length) {
        return $fullPath.TrimEnd($trimCharacters)
    }
    return $fullPath
}

function Test-SamePath {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $leftComparable = Resolve-ComparablePath -Path $Left
    $rightComparable = Resolve-ComparablePath -Path $Right
    if ($isWindowsPlatform) {
        return $leftComparable -ieq $rightComparable
    }
    return $leftComparable -ceq $rightComparable
}

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
if ([string]::IsNullOrWhiteSpace($InstallPath)) {
    $homePath = Resolve-UserHomePath
    $installRoot = Join-Path -Path $homePath -ChildPath ".agents"
    $installRoot = Join-Path -Path $installRoot -ChildPath "skills"
    $installRoot = Join-Path -Path $installRoot -ChildPath "herdr-coordination"
    $InstallPath = $installRoot
}
$targetRoot = [IO.Path]::GetFullPath($InstallPath)
if (Test-SamePath -Left $sourceRoot -Right $targetRoot) {
    throw "Source and installed skill paths must be different."
}

$sourceGitRoot = [IO.Path]::GetFullPath(
    (Invoke-GitText -Repository $sourceRoot -Arguments @("rev-parse", "--show-toplevel"))
)
if (-not (Test-SamePath -Left $sourceGitRoot -Right $sourceRoot)) {
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
if (-not (Test-SamePath -Left $targetGitRoot -Right $targetRoot)) {
    throw "Installed skill is not the root of its own Git checkout: $targetRoot"
}
Assert-CleanRepository -Repository $targetRoot -Role "Installed"

if ($Action -eq "install") {
    $null = Invoke-GitText -Repository $targetRoot -Arguments @("fetch", "origin")
}
$objectCheck = & git -C $targetRoot cat-file -e "$sourceHead`^{commit}" 2>&1
if ($LASTEXITCODE -ne 0) {
    if ($Action -eq "check") {
        throw "Source commit $sourceHead is not present in the installed checkout. Check is read-only and did not fetch the managed install; run -Action install after pushing the source repository."
    }
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

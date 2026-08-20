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

function Get-UniqueSiblingPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Suffix
    )

    $parent = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
    $candidate = Join-Path $parent "$leaf.$Suffix-$stamp"
    $counter = 0
    while (Test-Path -LiteralPath $candidate) {
        $counter++
        $candidate = Join-Path $parent "$leaf.$Suffix-$stamp-$counter"
    }
    return $candidate
}

function Test-GitCheckout {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }
    $null = & git -C $Path rev-parse --show-toplevel 2>$null
    return $LASTEXITCODE -eq 0
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

$legacyInstall = $false
$legacyBackupPath = $null
$stagingPath = $null
$sourceCommitBootstrappedLocally = $false
if ((Test-Path -LiteralPath $targetRoot -PathType Container) -and
    -not (Test-GitCheckout -Path $targetRoot)) {
    if ($Action -eq "check") {
        throw "Installed skill is not a Git checkout: $targetRoot. Run -Action install once to migrate it to a recoverable Git checkout."
    }
    $legacyInstall = $true
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
        throw "git clone failed: $($cloneOutput -join [Environment]::NewLine)"
    }
}
elseif ($legacyInstall) {
    # A previous installer left a plain copied skill directory. Build the new
    # checkout beside it from the exact committed source tree, then swap the
    # paths only after cloning succeeds. The old directory is retained as a
    # timestamped sibling so migration is recoverable.
    $stagingPath = Get-UniqueSiblingPath -Path $targetRoot -Suffix "bootstrap"
    $cloneOutput = & git clone --no-local $sourceRoot $stagingPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git clone of the committed local source failed: $($cloneOutput -join [Environment]::NewLine)"
    }
    try {
        $null = Invoke-GitText -Repository $stagingPath -Arguments @("remote", "set-url", "origin", $sourceRemote)
        $legacyBackupPath = Get-UniqueSiblingPath -Path $targetRoot -Suffix "legacy-backup"
        Move-Item -LiteralPath $targetRoot -Destination $legacyBackupPath
        try {
            Move-Item -LiteralPath $stagingPath -Destination $targetRoot
            $stagingPath = $null
        }
        catch {
            if (Test-Path -LiteralPath $targetRoot) {
                $failedCheckoutPath = Get-UniqueSiblingPath -Path $targetRoot -Suffix "failed-bootstrap"
                Move-Item -LiteralPath $targetRoot -Destination $failedCheckoutPath
            }
            Move-Item -LiteralPath $legacyBackupPath -Destination $targetRoot
            throw
        }
    }
    catch {
        if ($stagingPath -and (Test-Path -LiteralPath $stagingPath)) {
            $failedStagingPath = Get-UniqueSiblingPath -Path $targetRoot -Suffix "failed-bootstrap"
            Move-Item -LiteralPath $stagingPath -Destination $failedStagingPath
        }
        throw
    }
}

$targetGitRoot = [IO.Path]::GetFullPath(
    (Invoke-GitText -Repository $targetRoot -Arguments @("rev-parse", "--show-toplevel"))
)
if (-not (Test-SamePath -Left $targetGitRoot -Right $targetRoot)) {
    throw "Installed skill is not the root of its own Git checkout: $targetRoot"
}
Assert-CleanRepository -Repository $targetRoot -Role "Installed"

if ($Action -eq "install" -and -not $legacyInstall) {
    try {
        $null = Invoke-GitText -Repository $targetRoot -Arguments @("fetch", "origin")
    }
    catch {
        # A local source commit can still be installed safely after the source
        # checkout has been cleanly committed. Preserve the configured origin
        # and fall back below to fetching that exact local HEAD; publishing is
        # still required for other machines to consume the same commit.
    }
}
$objectCheck = & git -C $targetRoot cat-file -e "$sourceHead`^{commit}" 2>&1
if ($LASTEXITCODE -ne 0) {
    if ($Action -eq "check") {
        throw "Source commit $sourceHead is not present in the installed checkout. Check is read-only and did not fetch the managed install; run -Action install after pushing the source repository."
    }
    try {
        $null = Invoke-GitText -Repository $targetRoot -Arguments @("fetch", "--no-tags", $sourceRoot, "HEAD")
        $sourceCommitBootstrappedLocally = $true
    }
    catch {
        throw "Source commit $sourceHead is not present in the installed checkout or canonical origin, and fetching the clean local source failed: $($_.Exception.Message)"
    }
    $objectCheck = & git -C $targetRoot cat-file -e "$sourceHead`^{commit}" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "The local source fetch did not make source commit $sourceHead available in the installed checkout."
    }
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
    migrated_legacy_install = $legacyInstall
    legacy_backup_path = $legacyBackupPath
    source_commit_bootstrapped_locally = $sourceCommitBootstrappedLocally
} | ConvertTo-Json -Depth 5

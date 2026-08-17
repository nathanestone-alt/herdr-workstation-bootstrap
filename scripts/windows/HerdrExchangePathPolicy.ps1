Set-StrictMode -Version Latest

function Test-HerdrPathSameOrDescendant {
    param([Parameter(Mandatory)][string]$Candidate, [Parameter(Mandatory)][string]$Ancestor)
    $candidateNormalized = [IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $ancestorNormalized = [IO.Path]::GetFullPath($Ancestor).TrimEnd('\')
    return $candidateNormalized.Equals($ancestorNormalized, [StringComparison]::OrdinalIgnoreCase) -or
        $candidateNormalized.StartsWith("$ancestorNormalized\", [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-HerdrExchangePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowExistingUnmanagedPath,
        [switch]$ExistingManagedShare,
        [AllowNull()][string[]]$ProtectedRoots,
        [scriptblock]$DriveTypeResolver = {
            param([string]$Root)
            ([IO.DriveInfo]::new($Root)).DriveType
        }
    )

    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('\\.\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('\??\', [StringComparison]::Ordinal)) {
        throw "The SMB share path must not use a Windows device namespace: '$Path'."
    }
    if ($Path.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw "The SMB share path must not be a UNC path: '$Path'."
    }
    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "The SMB share path must be absolute: '$Path'."
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $driveRoot = [IO.Path]::GetPathRoot($fullPath)
    $resolved = $fullPath.TrimEnd('\')
    $pathRoot = $driveRoot.TrimEnd('\')
    $driveType = & $DriveTypeResolver $driveRoot
    if ($driveRoot -notmatch '^[A-Za-z]:\\$' -or
        $driveType -ne [IO.DriveType]::Fixed) {
        throw "The SMB share path must be on a local fixed drive: '$resolved'."
    }
    if ($resolved.Equals($pathRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use drive root '$resolved' as the SMB share."
    }

    $protectedPaths = if ($PSBoundParameters.ContainsKey('ProtectedRoots')) {
        @($ProtectedRoots)
    }
    else {
        @(
            $env:SystemRoot, $env:ProgramData, $env:ProgramFiles,
            ${env:ProgramFiles(x86)}, (Join-Path $env:SystemDrive 'Users')
        )
    }
    $protectedPaths = @($protectedPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($protectedPath in $protectedPaths) {
        if ((Test-HerdrPathSameOrDescendant -Candidate $resolved -Ancestor $protectedPath) -or
            (Test-HerdrPathSameOrDescendant -Candidate $protectedPath -Ancestor $resolved)) {
            throw "Refusing SMB share path '$resolved' because it overlaps protected system path '$protectedPath'."
        }
    }

    if (Test-Path -LiteralPath $resolved) {
        $item = Get-Item -LiteralPath $resolved -Force
        if (-not $item.PSIsContainer) { throw "SMB share path '$resolved' exists but is not a directory." }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing existing SMB share path '$resolved' because it is a reparse point."
        }
        $markerPath = Join-Path $resolved '.herdr-exchange-root'
        $isManaged = (Test-Path -LiteralPath $markerPath -PathType Leaf) -and
            ((Get-Content -Raw -LiteralPath $markerPath) -eq 'herdr-exchange-root-v1')
        if (-not ($isManaged -and $ExistingManagedShare) -and -not $AllowExistingUnmanagedPath) {
            throw "Existing SMB share path '$resolved' is not marked as Herdr-managed. Refusing to replace its DACL without -AllowExistingSharePath."
        }
    }
    return $resolved
}

Set-StrictMode -Version Latest

function Get-HerdrWorkbookExtensionAllowlist {
    return @('.xlsx', '.xlsm', '.xlsb')
}

function Get-HerdrCanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path is empty.'
    }
    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('\\.\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('\??\', [StringComparison]::Ordinal)) {
        throw "Device namespace paths are not allowed: '$Path'."
    }
    if ($Path.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw "UNC paths are not allowed: '$Path'."
    }
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
    }
    catch {
        throw "Path is not valid: '$Path'."
    }
    while ($fullPath.Length -gt 1 -and ($fullPath.EndsWith('\') -or $fullPath.EndsWith('/'))) {
        $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }
    return $fullPath
}

function Test-HerdrPathSameOrDescendant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Ancestor
    )

    $candidatePath = Get-HerdrCanonicalPath -Path $Candidate
    $ancestorPath = Get-HerdrCanonicalPath -Path $Ancestor
    if ($candidatePath.Equals($ancestorPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $separator = if ($ancestorPath.EndsWith('\') -or $ancestorPath.EndsWith('/')) { '' } elseif ($IsWindows) { '\' } else { '/' }
    return $candidatePath.StartsWith("$ancestorPath$separator", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-HerdrConfiguredLocalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $canonicalPath = Get-HerdrCanonicalPath -Path $Path
    if ($IsWindows) {
        $driveRoot = [IO.Path]::GetPathRoot($canonicalPath)
        if ($driveRoot -notmatch '^[A-Za-z]:\\$') {
            throw "Configured path must be on a local drive: '$canonicalPath'."
        }
        try {
            $driveType = ([IO.DriveInfo]::new($driveRoot)).DriveType
        }
        catch {
            throw "Could not inspect the configured drive for '$canonicalPath'."
        }
        if ($driveType -ne [IO.DriveType]::Fixed) {
            throw "Configured path must be on a fixed local drive: '$canonicalPath'."
        }
    }
    return $canonicalPath
}

function Assert-HerdrExistingPathIsNotReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissing
    )

    $canonicalPath = Get-HerdrCanonicalPath -Path $Path
    if (-not (Test-Path -LiteralPath $canonicalPath)) {
        if ($AllowMissing) { return $canonicalPath }
        throw "Configured path does not exist: '$canonicalPath'."
    }
    $item = Get-Item -LiteralPath $canonicalPath -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Configured path is a reparse point: '$canonicalPath'."
    }
    return $canonicalPath
}

function Assert-HerdrPathDoesNotOverlap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right,
        [Parameter(Mandatory)][string]$Description
    )

    if ((Test-HerdrPathSameOrDescendant -Candidate $Left -Ancestor $Right) -or
        (Test-HerdrPathSameOrDescendant -Candidate $Right -Ancestor $Left)) {
        throw "Configured $Description paths overlap."
    }
}

function Assert-HerdrJobId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JobId)

    if ($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $JobId -in @('.', '..') -or
        $JobId.EndsWith('.') -or $JobId.EndsWith(' ')) {
        throw 'Job ID is invalid; use 1-64 ASCII letters, digits, dot, underscore, or hyphen, without a trailing dot or space.'
    }
    return $JobId
}

function Assert-HerdrMetadataValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [int]$MaximumLength = 512
    )

    if ($Value.Length -gt $MaximumLength -or $Value.IndexOf([char]0) -ge 0 -or
        $Value.IndexOf("`r") -ge 0 -or $Value.IndexOf("`n") -ge 0) {
        throw "$Name contains unsupported control data."
    }
    return $Value
}

function Get-HerdrDefaultOneDriveInboxRoot {
    [CmdletBinding()]
    param()

    $oneDriveRoot = if (-not [string]::IsNullOrWhiteSpace($env:OneDriveCommercial)) {
        $env:OneDriveCommercial
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:OneDrive)) {
        $env:OneDrive
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Join-Path $env:USERPROFILE 'OneDrive'
    }
    else {
        throw 'No configured OneDrive root is available; pass -OneDriveInboxRoot explicitly.'
    }
    return (Join-Path (Join-Path $oneDriveRoot 'Herdr Review Exchange') 'Inbox')
}

function Get-HerdrDefaultOneDriveSiblingRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InboxRoot,
        [Parameter(Mandatory)][ValidateSet('Outbox', 'Archive')][string]$Name
    )

    return (Join-Path (Split-Path -Parent (Get-HerdrCanonicalPath -Path $InboxRoot)) $Name)
}

function Get-HerdrBlockedAttributeNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Attributes)

    $blockedAttributes = [ordered]@{
        Offline = [int64]0x1000
        ReparsePoint = [int64][IO.FileAttributes]::ReparsePoint
        RecallOnOpen = [int64]0x40000
        RecallOnDataAccess = [int64]0x400000
    }
    return @(
        foreach ($entry in $blockedAttributes.GetEnumerator()) {
            if (([int64]$Attributes -band $entry.Value) -ne 0) { $entry.Key }
        }
    )
}

function Assert-HerdrWorkbookFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -and $item.Length -ge 0) {
        $extension = [IO.Path]::GetExtension($item.Name).ToLowerInvariant()
        if ($extension -notin (Get-HerdrWorkbookExtensionAllowlist)) {
            throw "Workbook extension '$extension' is not allowed."
        }
        $blocked = @(Get-HerdrBlockedAttributeNames -Attributes $item.Attributes)
        if ($blocked.Count -gt 0) {
            throw "Workbook is not fully hydrated; blocked attributes: $($blocked -join ', ')."
        }
        return $item
    }
    throw 'Workbook source must be a regular file.'
}

function ConvertTo-HerdrSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)

    return [Convert]::ToHexString($Bytes).ToLowerInvariant()
}

function Get-HerdrFileSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $canonicalPath = Get-HerdrCanonicalPath -Path $Path
    $before = Assert-HerdrWorkbookFile -Path $canonicalPath
    $beforeLength = [int64]$before.Length
    $beforeWriteTime = $before.LastWriteTimeUtc
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        try {
            $stream = [IO.FileStream]::new(
                $canonicalPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::None,
                1048576,
                [IO.FileOptions]::SequentialScan)
            $digest = $hashAlgorithm.ComputeHash($stream)
        }
        catch {
            throw "Workbook could not be read exclusively: '$canonicalPath'."
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $hashAlgorithm.Dispose()
    }
    try {
        $after = Assert-HerdrWorkbookFile -Path $canonicalPath
    }
    catch {
        throw "Workbook changed or disappeared during the exclusive read: '$canonicalPath'."
    }
    if ([int64]$after.Length -ne $beforeLength -or $after.LastWriteTimeUtc -ne $beforeWriteTime) {
        throw "Workbook changed during the exclusive read: '$canonicalPath'."
    }
    [pscustomobject][ordered]@{
        Path = $canonicalPath
        CapturedUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        SizeBytes = $beforeLength
        LastWriteTimeUtc = $beforeWriteTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Sha256 = ConvertTo-HerdrSha256 -Bytes $digest
    }
}

function Assert-HerdrSnapshotsEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][object]$Actual,
        [Parameter(Mandatory)][string]$Description
    )

    if ([int64]$Expected.SizeBytes -ne [int64]$Actual.SizeBytes -or
        [string]$Expected.LastWriteTimeUtc -cne [string]$Actual.LastWriteTimeUtc -or
        [string]$Expected.Sha256 -cne [string]$Actual.Sha256) {
        throw "$Description is unstable or has a hash mismatch."
    }
}

function Assert-HerdrSnapshotContentEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][object]$Actual,
        [Parameter(Mandatory)][string]$Description
    )

    if ([int64]$Expected.SizeBytes -ne [int64]$Actual.SizeBytes -or
        [string]$Expected.Sha256 -cne [string]$Actual.Sha256) {
        throw "$Description has a size or hash mismatch."
    }
}

function Copy-HerdrFileExclusive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $source = Get-HerdrCanonicalPath -Path $SourcePath
    $destination = Get-HerdrCanonicalPath -Path $DestinationPath
    if (Test-Path -LiteralPath $destination) {
        throw "Destination already exists: '$destination'."
    }
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Destination directory does not exist: '$parent'."
    }
    $temporary = Join-Path $parent ('.herdr-copy-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $sourceStream = $null
    $destinationStream = $null
    try {
        $sourceStream = [IO.FileStream]::new($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None, 1048576, [IO.FileOptions]::SequentialScan)
        $destinationStream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 1048576, [IO.FileOptions]::SequentialScan)
        $sourceStream.CopyTo($destinationStream, 1048576)
        $destinationStream.Flush($true)
    }
    catch {
        throw "Exclusive workbook copy failed."
    }
    finally {
        if ($null -ne $destinationStream) { $destinationStream.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
    }
    try {
        [IO.File]::Move($temporary, $destination)
    }
    catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        throw "Exclusive workbook copy could not be committed."
    }
    return $destination
}

function Write-HerdrAtomicText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $destination = Get-HerdrCanonicalPath -Path $Path
    if (Test-Path -LiteralPath $destination) { throw "Output already exists: '$destination'." }
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Output directory does not exist: '$parent'." }
    $temporary = Join-Path $parent ('.herdr-text-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $destination)
    }
    catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        throw "Atomic text output could not be committed."
    }
    return $destination
}

function Invoke-HerdrReviewStaging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$OneDriveInboxRoot,
        [Parameter(Mandatory)][string]$ExchangeRoot,
        [string]$OneDriveOutboxRoot,
        [string]$OneDriveArchiveRoot,
        [string]$Repository = 'NOT-PROVIDED',
        [string]$Branch = 'NOT-PROVIDED',
        [string]$Commit = 'NOT-PROVIDED',
        [ValidateRange(0, 60000)][int]$StabilityIntervalMilliseconds = 1000,
        [scriptblock]$BetweenSourceReads
    )

    Assert-HerdrJobId -JobId $JobId | Out-Null
    Assert-HerdrMetadataValue -Value $Repository -Name 'Repository' | Out-Null
    Assert-HerdrMetadataValue -Value $Branch -Name 'Branch' | Out-Null
    Assert-HerdrMetadataValue -Value $Commit -Name 'Commit' | Out-Null
    $inboxRoot = Assert-HerdrConfiguredLocalPath -Path $OneDriveInboxRoot
    $exchangeRootCanonical = Assert-HerdrConfiguredLocalPath -Path $ExchangeRoot
    Assert-HerdrExistingPathIsNotReparsePoint -Path $inboxRoot | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $exchangeRootCanonical -AllowMissing | Out-Null
    if ([string]::IsNullOrWhiteSpace($OneDriveOutboxRoot)) {
        $OneDriveOutboxRoot = Get-HerdrDefaultOneDriveSiblingRoot -InboxRoot $inboxRoot -Name Outbox
    }
    if ([string]::IsNullOrWhiteSpace($OneDriveArchiveRoot)) {
        $OneDriveArchiveRoot = Get-HerdrDefaultOneDriveSiblingRoot -InboxRoot $inboxRoot -Name Archive
    }
    $outboxRoot = Assert-HerdrConfiguredLocalPath -Path $OneDriveOutboxRoot
    $archiveRoot = Assert-HerdrConfiguredLocalPath -Path $OneDriveArchiveRoot
    Assert-HerdrExistingPathIsNotReparsePoint -Path $outboxRoot | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $archiveRoot | Out-Null
    Assert-HerdrPathDoesNotOverlap -Left $inboxRoot -Right $exchangeRootCanonical -Description 'OneDrive and exchange'
    Assert-HerdrPathDoesNotOverlap -Left $inboxRoot -Right $outboxRoot -Description 'OneDrive Inbox and Outbox'
    Assert-HerdrPathDoesNotOverlap -Left $inboxRoot -Right $archiveRoot -Description 'OneDrive Inbox and Archive'
    Assert-HerdrPathDoesNotOverlap -Left $outboxRoot -Right $archiveRoot -Description 'OneDrive Outbox and Archive'
    Assert-HerdrPathDoesNotOverlap -Left $exchangeRootCanonical -Right $outboxRoot -Description 'exchange and OneDrive Outbox'
    Assert-HerdrPathDoesNotOverlap -Left $exchangeRootCanonical -Right $archiveRoot -Description 'exchange and OneDrive Archive'
    $sourceCanonical = Get-HerdrCanonicalPath -Path $SourcePath
    if (-not (Test-HerdrPathSameOrDescendant -Candidate $sourceCanonical -Ancestor $inboxRoot) -or
        $sourceCanonical.Equals($inboxRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Source workbook is outside the configured OneDrive Inbox.'
    }
    $sourceItem = Assert-HerdrWorkbookFile -Path $sourceCanonical
    $stageRoot = Get-HerdrCanonicalPath -Path (Join-Path $exchangeRootCanonical 'in')
    Assert-HerdrExistingPathIsNotReparsePoint -Path $stageRoot -AllowMissing | Out-Null
    if (Test-Path -LiteralPath $stageRoot -PathType Leaf) { throw 'Exchange input root is not a directory.' }
    [IO.Directory]::CreateDirectory($stageRoot) | Out-Null
    $jobDirectory = Get-HerdrCanonicalPath -Path (Join-Path $stageRoot $JobId)
    if (Test-Path -LiteralPath $jobDirectory) { throw "Staging collision for job '$JobId'." }
    [IO.Directory]::CreateDirectory($jobDirectory) | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $jobDirectory | Out-Null
    $completed = $false
    try {
        $firstSnapshot = Get-HerdrFileSnapshot -Path $sourceCanonical
        if ($null -ne $BetweenSourceReads) { & $BetweenSourceReads }
        if ($StabilityIntervalMilliseconds -gt 0) { Start-Sleep -Milliseconds $StabilityIntervalMilliseconds }
        $secondSnapshot = Get-HerdrFileSnapshot -Path $sourceCanonical
        Assert-HerdrSnapshotsEqual -Expected $firstSnapshot -Actual $secondSnapshot -Description 'OneDrive source'
        $extension = [IO.Path]::GetExtension($sourceItem.Name).ToLowerInvariant()
        $stagedPath = Get-HerdrCanonicalPath -Path (Join-Path $jobDirectory ('input' + $extension))
        Copy-HerdrFileExclusive -SourcePath $sourceCanonical -DestinationPath $stagedPath | Out-Null
        $stagedSnapshot = Get-HerdrFileSnapshot -Path $stagedPath
        Assert-HerdrSnapshotContentEqual -Expected $firstSnapshot -Actual $stagedSnapshot -Description 'Bridge staging copy'
        if (-not (Test-Path -LiteralPath $sourceCanonical -PathType Leaf)) {
            throw 'OneDrive source was not preserved after staging.'
        }
        $manifestPath = Get-HerdrCanonicalPath -Path (Join-Path $jobDirectory 'staging-provenance.json')
        $manifest = [ordered]@{
            schema = 'herdr-review-staging-v1'
            job_id = $JobId
            created_utc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            stability_interval_milliseconds = $StabilityIntervalMilliseconds
            allowed_extensions = @(Get-HerdrWorkbookExtensionAllowlist)
            source_root = $inboxRoot
            one_drive_outbox_root = $outboxRoot
            one_drive_archive_root = $archiveRoot
            exchange_root = $exchangeRootCanonical
            staged_input_path = $stagedPath
            source = [ordered]@{
                path = $firstSnapshot.Path
                file_name = $sourceItem.Name
                extension = $extension
                captured_utc = $firstSnapshot.CapturedUtc
                size_bytes = $firstSnapshot.SizeBytes
                last_write_time_utc = $firstSnapshot.LastWriteTimeUtc
                sha256 = $firstSnapshot.Sha256
            }
            bridge_stage = [ordered]@{
                path = $stagedSnapshot.Path
                file_name = [IO.Path]::GetFileName($stagedPath)
                extension = $extension
                captured_utc = $stagedSnapshot.CapturedUtc
                size_bytes = $stagedSnapshot.SizeBytes
                last_write_time_utc = $stagedSnapshot.LastWriteTimeUtc
                sha256 = $stagedSnapshot.Sha256
            }
            provenance = [ordered]@{
                repository = $Repository
                branch = $Branch
                commit = $Commit
            }
            source_preserved = $true
        }
        $json = $manifest | ConvertTo-Json -Depth 8 -Compress
        Write-HerdrAtomicText -Path $manifestPath -Content $json | Out-Null
        $completed = $true
        return [pscustomobject][ordered]@{
            Schema = $manifest.schema
            JobId = $JobId
            SourcePath = $firstSnapshot.Path
            SourceSha256 = $firstSnapshot.Sha256
            StagedPath = $stagedSnapshot.Path
            StagedSha256 = $stagedSnapshot.Sha256
            ManifestPath = $manifestPath
            SourcePreserved = $true
        }
    }
    finally {
        if (-not $completed -and (Test-Path -LiteralPath $jobDirectory)) {
            Remove-Item -LiteralPath $jobDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

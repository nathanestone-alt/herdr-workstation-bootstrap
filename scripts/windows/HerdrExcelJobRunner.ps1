Set-StrictMode -Version Latest

$script:HerdrReviewStagingScriptPath = Join-Path $PSScriptRoot 'HerdrReviewStaging.ps1'
. $script:HerdrReviewStagingScriptPath

function Assert-HerdrJsonProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Description
    )

    foreach ($property in @($Object.PSObject.Properties)) {
        if ($property.Name -notin $Allowed) {
            throw "$Description contains an unknown field '$($property.Name)'."
        }
    }
}

function Get-HerdrRequiredJsonString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or $property.Value -isnot [string]) {
        throw "$Description requires string field '$Name'."
    }
    return (Assert-HerdrMetadataValue -Value ([string]$property.Value) -Name $Name)
}

function Get-HerdrOptionalJsonString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = 'NOT-PROVIDED'
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    if ($property.Value -isnot [string]) { throw "Optional field '$Name' must be a string." }
    return (Assert-HerdrMetadataValue -Value ([string]$property.Value) -Name $Name)
}

function Read-HerdrJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$TrustedRoot
    )

    $opened = $null
    $fileStream = $null
    $reader = $null
    $boundaryBefore = $null
    try {
        if ([string]::IsNullOrWhiteSpace($TrustedRoot)) {
            $proof = Get-HerdrPhysicalPathProof -Path $Path
        }
        else {
            $boundaryBefore = Assert-HerdrPhysicalPathUnderRoot -CandidatePath $Path -RootPath $TrustedRoot -Description 'JSON input boundary'
            $proof = $boundaryBefore.Candidate
        }
        if (-not $proof.Exists -or $proof.Leaf.IsDirectory) { throw 'not a regular file' }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse point' }
        if ($IsWindows) {
            $opened = Open-HerdrNativeReadFile -Path $Path
            Compare-HerdrPhysicalIdentity -Expected $proof.Leaf -Actual $opened.Identity -Description 'JSON input before read' -IncludeLinkCount | Out-Null
            $fileStream = [IO.FileStream]::new($opened.SafeHandle, [IO.FileAccess]::Read, 4096, $false)
            $reader = [IO.StreamReader]::new($fileStream, [Text.UTF8Encoding]::new($false, $true), $true, 4096, $true)
            $raw = $reader.ReadToEnd()
        }
        else {
            $raw = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
        }
        $value = $raw | ConvertFrom-Json -Depth 20 -ErrorAction Stop
        $afterProof = if ($IsWindows) {
            Get-HerdrPhysicalPathProof -Path $Path -ExistingLeafHandle $opened
        }
        else {
            Get-HerdrPhysicalPathProof -Path $Path
        }
        Compare-HerdrPhysicalIdentity -Expected $proof.Leaf -Actual $afterProof.Leaf -Description 'JSON input after read' -IncludeLinkCount | Out-Null
        if ($null -ne $boundaryBefore) {
            Assert-HerdrPhysicalPathUnderRoot -CandidatePath $Path -RootPath $TrustedRoot `
                -ExpectedCandidate $proof -ExpectedRoot $boundaryBefore.Root -Description 'JSON input boundary after read' `
                -ExistingCandidateHandle $opened | Out-Null
        }
    }
    catch {
        throw "JSON input is invalid or unreadable: '$Path'."
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $fileStream) { $fileStream.Dispose() }
        if ($null -ne $opened -and $null -ne $opened.SafeHandle -and -not $opened.SafeHandle.IsClosed) { $opened.SafeHandle.Dispose() }
    }
    if ($null -eq $value -or $value -is [Array] -or $value -isnot [pscustomobject]) {
        throw "JSON input must be an object: '$Path'."
    }
    return $value
}

function Assert-HerdrSidValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Sid, [Parameter(Mandatory)][string]$Name)

    if ($Sid -notmatch '^S-\d-\d+(?:-\d+)+$') { throw "$Name must be a Windows SID." }
    return $Sid
}

function Get-HerdrIdentityConfiguration {
    [CmdletBinding()]
    param(
        [string]$ExpectedInteractiveUserSid,
        [int]$ExpectedInteractiveSessionId = -1,
        [string]$ExpectedBridgeAccountSid,
        [switch]$TestMode
    )

    if ($TestMode) {
        return [pscustomobject][ordered]@{
            InteractiveUserSid = if ([string]::IsNullOrWhiteSpace($ExpectedInteractiveUserSid)) { $null } else { Assert-HerdrSidValue -Sid $ExpectedInteractiveUserSid -Name 'Expected interactive user SID' }
            InteractiveSessionId = $ExpectedInteractiveSessionId
            BridgeAccountSid = if ([string]::IsNullOrWhiteSpace($ExpectedBridgeAccountSid)) { $null } else { Assert-HerdrSidValue -Sid $ExpectedBridgeAccountSid -Name 'Expected bridge account SID' }
            Source = 'explicit-test-mode'
        }
    }
    if (-not $IsWindows) { throw 'Production identity configuration is Windows-only.' }

    $userSid = if (-not [string]::IsNullOrWhiteSpace($ExpectedInteractiveUserSid)) {
        $ExpectedInteractiveUserSid
    }
    else { [string]$env:HERDR_DESIGNATED_INTERACTIVE_USER_SID }
    $sessionText = if ($ExpectedInteractiveSessionId -ge 0) {
        [string]$ExpectedInteractiveSessionId
    }
    else { [string]$env:HERDR_DESIGNATED_INTERACTIVE_SESSION_ID }
    $bridgeSid = if (-not [string]::IsNullOrWhiteSpace($ExpectedBridgeAccountSid)) {
        $ExpectedBridgeAccountSid
    }
    else { [string]$env:HERDR_BRIDGE_ACCOUNT_SID }
    if ([string]::IsNullOrWhiteSpace($userSid) -or [string]::IsNullOrWhiteSpace($sessionText) -or
        [string]::IsNullOrWhiteSpace($bridgeSid)) {
        throw 'Production requires HERDR_DESIGNATED_INTERACTIVE_USER_SID, HERDR_DESIGNATED_INTERACTIVE_SESSION_ID, and HERDR_BRIDGE_ACCOUNT_SID deployment configuration.'
    }
    $parsedSession = 0
    if (-not [int]::TryParse($sessionText, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsedSession) -or $parsedSession -le 0) {
        throw 'Expected designated interactive session ID must be a positive integer.'
    }
    [pscustomobject][ordered]@{
        InteractiveUserSid = Assert-HerdrSidValue -Sid $userSid -Name 'Expected interactive user SID'
        InteractiveSessionId = $parsedSession
        BridgeAccountSid = Assert-HerdrSidValue -Sid $bridgeSid -Name 'Expected bridge account SID'
        Source = 'deployment-configuration'
    }
}

function Get-HerdrProcessIdentityProof {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)

    if (-not $IsWindows) { throw 'Process identity proof is Windows-only.' }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $sid = [Herdr.Security.NativeMethods]::ReadProcessUserSid($ProcessId)
        if ([string]::IsNullOrWhiteSpace($sid)) { throw 'empty process token SID' }
        [pscustomobject][ordered]@{
            ProcessId = $ProcessId
            UserSid = Assert-HerdrSidValue -Sid $sid -Name 'Observed process user SID'
            SessionId = [int]$process.SessionId
            Name = [string]$process.ProcessName
        }
    }
    catch {
        throw "Could not prove process identity for PID $ProcessId."
    }
}

function Assert-HerdrOneDriveReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OneDriveExchangeRoot,
        [Parameter(Mandatory)][string]$OneDriveAccount,
        [Parameter(Mandatory)][object]$IdentityConfiguration,
        [switch]$TestMode,
        [scriptblock]$ReadyProbe
    )

    if ($null -ne $ReadyProbe -and -not $TestMode) {
        throw 'OneDrive readiness probes are permitted only in explicit test mode.'
    }
    if ($TestMode) {
        if ($null -eq $ReadyProbe) {
            return [pscustomobject][ordered]@{ Status = 'test-mode-bypassed' }
        }
        $observed = & $ReadyProbe
        if ($null -eq $observed -or ($observed -is [bool] -and -not $observed)) {
            throw 'OneDrive readiness probe reported that the configured account is not ready.'
        }
        return $observed
    }
    if (-not $IsWindows) { throw 'OneDrive readiness proof is Windows-only.' }

    $matchingProcess = $false
    foreach ($process in @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue)) {
        try {
            $proof = Get-HerdrProcessIdentityProof -ProcessId $process.Id
            if ($proof.UserSid -ceq [string]$IdentityConfiguration.InteractiveUserSid -and
                $proof.SessionId -eq [int]$IdentityConfiguration.InteractiveSessionId) {
                $matchingProcess = $true
                break
            }
        }
        catch {
            continue
        }
    }
    if (-not $matchingProcess) {
        throw 'OneDrive is not running under the designated interactive Windows user and session.'
    }

    $accountsRoot = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
    $matchingAccount = $false
    foreach ($accountKey in @(Get-ChildItem -LiteralPath $accountsRoot -ErrorAction SilentlyContinue)) {
        try {
            $accountProperties = Get-ItemProperty -LiteralPath $accountKey.PSPath -ErrorAction Stop
            $accountNames = @(
                $accountProperties.PSObject.Properties['UserEmail'],
                $accountProperties.PSObject.Properties['UserName'],
                $accountProperties.PSObject.Properties['AccountName']
            ) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.Value) } |
                ForEach-Object { [string]$_.Value }
            $userFolderProperty = $accountProperties.PSObject.Properties['UserFolder']
            if ($null -ne $userFolderProperty -and $accountNames -contains $OneDriveAccount -and
                (Test-HerdrPathSameOrDescendant -Candidate $OneDriveExchangeRoot -Ancestor ([string]$userFolderProperty.Value))) {
                $matchingAccount = $true
                break
            }
        }
        catch {
            continue
        }
    }
    if (-not $matchingAccount) {
        throw 'The configured OneDrive exchange root is not associated with a signed-in configured OneDrive account.'
    }
    [pscustomobject][ordered]@{
        Status = 'ready'
        Process = 'OneDrive'
        Account = $OneDriveAccount
        ExchangeRoot = $OneDriveExchangeRoot
    }
}

function Assert-HerdrInteractiveIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Configuration,
        [switch]$TestMode,
        [scriptblock]$IdentityProbe
    )

    if ($null -ne $IdentityProbe -and -not $TestMode) {
        throw 'Interactive identity probes are permitted only in explicit test mode.'
    }
    if ($TestMode) {
        $observed = if ($null -ne $IdentityProbe) { & $IdentityProbe } else { Test-HerdrInteractiveSession }
        if ($observed -is [bool] -and -not $observed) { throw 'Designated interactive Windows session is unavailable.' }
        if ($null -ne $observed -and $observed -isnot [bool]) {
            foreach ($name in @('CurrentUserSid', 'ExplorerUserSid')) {
                $property = $observed.PSObject.Properties[$name]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value) -and
                    $null -ne $Configuration.InteractiveUserSid -and
                    [string]$property.Value -cne [string]$Configuration.InteractiveUserSid) {
                    throw "Interactive identity proof mismatch for $name."
                }
            }
            foreach ($name in @('CurrentSessionId', 'ExplorerSessionId')) {
                $property = $observed.PSObject.Properties[$name]
                if ($null -ne $property -and [int]$property.Value -gt 0 -and
                    [int]$Configuration.InteractiveSessionId -gt 0 -and
                    [int]$property.Value -ne [int]$Configuration.InteractiveSessionId) {
                    throw "Interactive session proof mismatch for $name."
                }
            }
        }
        return $observed
    }

    $current = Get-HerdrProcessIdentityProof -ProcessId $PID
    if ($current.UserSid -cne $Configuration.InteractiveUserSid -or
        $current.SessionId -ne $Configuration.InteractiveSessionId -or
        $current.SessionId -eq 0) {
        throw 'Current process is not running as the designated interactive user and session.'
    }
    $explorers = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $Configuration.InteractiveSessionId })
    if ($explorers.Count -eq 0) { throw 'No Explorer process exists in the designated interactive session.' }
    $matchingExplorer = $false
    foreach ($explorer in $explorers) {
        $proof = Get-HerdrProcessIdentityProof -ProcessId $explorer.Id
        if ($proof.UserSid -cne $Configuration.InteractiveUserSid -or $proof.SessionId -ne $Configuration.InteractiveSessionId) {
            throw 'Explorer owner or session does not match the designated interactive identity.'
        }
        $matchingExplorer = $true
    }
    if (-not $matchingExplorer) { throw 'Designated Explorer identity could not be proven.' }
    return [pscustomobject][ordered]@{
        CurrentUserSid = $current.UserSid
        CurrentSessionId = $current.SessionId
        ExplorerUserSid = $Configuration.InteractiveUserSid
        ExplorerSessionId = $Configuration.InteractiveSessionId
    }
}

function Assert-HerdrSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hash, [Parameter(Mandatory)][string]$Name)

    if ($Hash -notmatch '^[0-9a-fA-F]{64}$') { throw "$Name is not a SHA-256 value." }
    return $Hash.ToLowerInvariant()
}

function Get-HerdrManifestRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$ExchangeRoot,
        [Parameter(Mandatory)][string]$OneDriveInboxRoot,
        [Parameter(Mandatory)][string]$OneDriveOutboxRoot,
        [Parameter(Mandatory)][string]$OneDriveArchiveRoot
    )

    $manifestCanonical = Get-HerdrCanonicalPath -Path $ManifestPath
    $exchangeCanonical = Get-HerdrCanonicalPath -Path $ExchangeRoot
    $inboxCanonical = Get-HerdrCanonicalPath -Path $OneDriveInboxRoot
    $outboxCanonical = Get-HerdrCanonicalPath -Path $OneDriveOutboxRoot
    $archiveCanonical = Get-HerdrCanonicalPath -Path $OneDriveArchiveRoot
    Assert-HerdrExistingPathIsNotReparsePoint -Path $inboxCanonical | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $outboxCanonical | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $archiveCanonical | Out-Null
    Assert-HerdrPathDoesNotOverlap -Left $inboxCanonical -Right $outboxCanonical -Description 'OneDrive Inbox and Outbox'
    Assert-HerdrPathDoesNotOverlap -Left $inboxCanonical -Right $archiveCanonical -Description 'OneDrive Inbox and Archive'
    Assert-HerdrPathDoesNotOverlap -Left $outboxCanonical -Right $archiveCanonical -Description 'OneDrive Outbox and Archive'
    $allowedManifestRoot = Get-HerdrCanonicalPath -Path (Join-Path (Join-Path $exchangeCanonical 'in') $JobId)
    Assert-HerdrPhysicalPathUnderRoot -CandidatePath $manifestCanonical -RootPath $allowedManifestRoot -Description 'Staging manifest boundary' | Out-Null
    if ([IO.Path]::GetExtension($manifestCanonical).ToLowerInvariant() -ne '.json') {
        throw 'Staging manifest is outside the job-specific exchange input directory.'
    }
    $document = Read-HerdrJsonFile -Path $manifestCanonical -TrustedRoot $allowedManifestRoot
    Assert-HerdrJsonProperties -Object $document -Allowed @(
        'schema', 'job_id', 'created_utc', 'stability_interval_milliseconds', 'allowed_extensions',
        'source_root', 'one_drive_outbox_root', 'one_drive_archive_root', 'exchange_root', 'staged_input_path', 'source', 'bridge_stage', 'provenance', 'source_preserved'
    ) -Description 'Staging manifest'
    if ((Get-HerdrRequiredJsonString -Object $document -Name 'schema' -Description 'Staging manifest') -cne 'herdr-review-staging-v1') {
        throw 'Staging manifest schema is unsupported.'
    }
    if ((Get-HerdrRequiredJsonString -Object $document -Name 'job_id' -Description 'Staging manifest') -cne $JobId) {
        throw 'Staging manifest job ID does not match the requested job.'
    }
    if ($document.source_preserved -ne $true) { throw 'Staging manifest does not prove that the Inbox original was preserved.' }
    $manifestExchange = Get-HerdrCanonicalPath -Path (Get-HerdrRequiredJsonString -Object $document -Name 'exchange_root' -Description 'Staging manifest')
    if (-not $manifestExchange.Equals($exchangeCanonical, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staging manifest exchange root does not match the configured exchange root.'
    }
    $manifestInbox = Get-HerdrCanonicalPath -Path (Get-HerdrRequiredJsonString -Object $document -Name 'source_root' -Description 'Staging manifest')
    if (-not $manifestInbox.Equals($inboxCanonical, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staging manifest Inbox root does not match the configured Inbox root.'
    }
    $manifestOutbox = Get-HerdrCanonicalPath -Path (Get-HerdrRequiredJsonString -Object $document -Name 'one_drive_outbox_root' -Description 'Staging manifest')
    $manifestArchive = Get-HerdrCanonicalPath -Path (Get-HerdrRequiredJsonString -Object $document -Name 'one_drive_archive_root' -Description 'Staging manifest')
    if (-not $manifestOutbox.Equals($outboxCanonical, [StringComparison]::OrdinalIgnoreCase) -or
        -not $manifestArchive.Equals($archiveCanonical, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staging manifest OneDrive roots do not match the configured review exchange.'
    }
    $source = $document.source
    $stage = $document.bridge_stage
    if ($null -eq $source -or $null -eq $stage -or $source -is [Array] -or $stage -is [Array]) {
        throw 'Staging manifest source records are missing.'
    }
    Assert-HerdrJsonProperties -Object $source -Allowed @('path', 'file_name', 'extension', 'captured_utc', 'size_bytes', 'last_write_time_utc', 'sha256', 'volume_serial_number', 'file_index', 'number_of_links', 'file_identity') -Description 'Source record'
    Assert-HerdrJsonProperties -Object $stage -Allowed @('path', 'file_name', 'extension', 'captured_utc', 'size_bytes', 'last_write_time_utc', 'sha256', 'volume_serial_number', 'file_index', 'number_of_links', 'file_identity') -Description 'Bridge-stage record'
    $sourcePath = Get-HerdrCanonicalPath -Path (Get-HerdrRequiredJsonString -Object $source -Name 'path' -Description 'Source record')
    Assert-HerdrPhysicalPathUnderRoot -CandidatePath $sourcePath -RootPath $inboxCanonical -Description 'Staging source boundary' | Out-Null
    if ($sourcePath.Equals($inboxCanonical, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staging manifest source is outside the configured OneDrive Inbox.'
    }
    $stagedPath = Get-HerdrCanonicalPath -Path (Get-HerdrRequiredJsonString -Object $stage -Name 'path' -Description 'Bridge-stage record')
    $manifestStagedPath = Get-HerdrCanonicalPath -Path (Get-HerdrRequiredJsonString -Object $document -Name 'staged_input_path' -Description 'Staging manifest')
    Assert-HerdrPhysicalPathUnderRoot -CandidatePath $stagedPath -RootPath $allowedManifestRoot -Description 'Bridge-stage boundary' | Out-Null
    if (-not $stagedPath.Equals($manifestStagedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staging manifest bridge path is outside the job-specific exchange input directory.'
    }
    $allowedExtensions = @($document.allowed_extensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $expectedExtensions = @(Get-HerdrWorkbookExtensionAllowlist)
    if (@(Compare-Object -ReferenceObject $expectedExtensions -DifferenceObject $allowedExtensions).Count -ne 0) {
        throw 'Staging manifest workbook extension allowlist is not the locked allowlist.'
    }
    $sourceExtension = [IO.Path]::GetExtension($sourcePath).ToLowerInvariant()
    $stageExtension = [IO.Path]::GetExtension($stagedPath).ToLowerInvariant()
    if ($sourceExtension -notin $expectedExtensions -or $stageExtension -notin $expectedExtensions -or $sourceExtension -cne $stageExtension) {
        throw 'Staging manifest workbook extension is unsupported or inconsistent.'
    }
    $sourceHash = Assert-HerdrSha256 -Hash (Get-HerdrRequiredJsonString -Object $source -Name 'sha256' -Description 'Source record') -Name 'Source hash'
    $stageHash = Assert-HerdrSha256 -Hash (Get-HerdrRequiredJsonString -Object $stage -Name 'sha256' -Description 'Bridge-stage record') -Name 'Bridge-stage hash'
    if ($sourceHash -cne $stageHash) { throw 'Staging manifest source and bridge hashes do not match.' }
    $sourceIdentityText = if ($null -ne $source.PSObject.Properties['file_identity'] -and $null -ne $source.file_identity) { [string]$source.file_identity } else { $null }
    $stageIdentityText = if ($null -ne $stage.PSObject.Properties['file_identity'] -and $null -ne $stage.file_identity) { [string]$stage.file_identity } else { $null }
    if ($null -ne $source.PSObject.Properties['number_of_links'] -and [int64]$source.number_of_links -gt 1) {
        throw 'Staging manifest source has multiple hard links.'
    }
    if ([int64]$source.size_bytes -lt 0 -or [int64]$stage.size_bytes -lt 0 -or [int64]$source.size_bytes -ne [int64]$stage.size_bytes) {
        throw 'Staging manifest source and bridge sizes do not match.'
    }
    if ($null -eq $document.provenance -or $document.provenance -is [Array]) { throw 'Staging manifest provenance is missing.' }
    Assert-HerdrJsonProperties -Object $document.provenance -Allowed @('repository', 'branch', 'commit') -Description 'Provenance'
    $provenance = [ordered]@{
        repository = Get-HerdrRequiredJsonString -Object $document.provenance -Name 'repository' -Description 'Provenance'
        branch = Get-HerdrRequiredJsonString -Object $document.provenance -Name 'branch' -Description 'Provenance'
        commit = Get-HerdrRequiredJsonString -Object $document.provenance -Name 'commit' -Description 'Provenance'
    }
    [pscustomobject][ordered]@{
        Path = $manifestCanonical
        Schema = 'herdr-review-staging-v1'
        JobId = $JobId
        SourcePath = $sourcePath
        SourceHash = $sourceHash
        SourceSizeBytes = [int64]$source.size_bytes
        StagedPath = $stagedPath
        StagedHash = $stageHash
        StagedSizeBytes = [int64]$stage.size_bytes
        SourceRoot = $inboxCanonical
        ExchangeRoot = $exchangeCanonical
        Extension = $stageExtension
        SourceIdentity = [pscustomobject][ordered]@{
            Exists = $true
            VolumeSerialNumber = if ($null -ne $source.PSObject.Properties['volume_serial_number']) { $source.volume_serial_number } else { $null }
            FileIndex = if ($null -ne $source.PSObject.Properties['file_index']) { $source.file_index } else { $null }
            NumberOfLinks = if ($null -ne $source.PSObject.Properties['number_of_links']) { [int64]$source.number_of_links } else { [int64]1 }
            FileIdentity = $sourceIdentityText
        }
        StagedIdentity = [pscustomobject][ordered]@{
            Exists = $true
            VolumeSerialNumber = if ($null -ne $stage.PSObject.Properties['volume_serial_number']) { $stage.volume_serial_number } else { $null }
            FileIndex = if ($null -ne $stage.PSObject.Properties['file_index']) { $stage.file_index } else { $null }
            NumberOfLinks = if ($null -ne $stage.PSObject.Properties['number_of_links']) { [int64]$stage.number_of_links } else { [int64]1 }
            FileIdentity = $stageIdentityText
        }
        Provenance = $provenance
    }
}

function Read-HerdrExcelJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JobPath,
        [Parameter(Mandatory)][string]$ExchangeRoot
    )

    $exchangeCanonical = Get-HerdrCanonicalPath -Path $ExchangeRoot
    $jobInputRoot = Get-HerdrCanonicalPath -Path (Join-Path $exchangeCanonical 'in')
    $jobCanonical = Get-HerdrCanonicalPath -Path $JobPath
    Assert-HerdrPhysicalPathUnderRoot -CandidatePath $jobCanonical -RootPath $jobInputRoot -Description 'Excel job boundary' | Out-Null
    if ([IO.Path]::GetExtension($jobCanonical).ToLowerInvariant() -ne '.json') {
        throw 'Excel job definition must be a JSON file under the exchange input root.'
    }
    $document = Read-HerdrJsonFile -Path $jobCanonical -TrustedRoot $jobInputRoot
    Assert-HerdrJsonProperties -Object $document -Allowed @(
        'schema', 'job_id', 'operation', 'staging_manifest', 'source_repository', 'source_branch', 'source_commit', 'trust_approval'
    ) -Description 'Excel job'
    if ((Get-HerdrRequiredJsonString -Object $document -Name 'schema' -Description 'Excel job') -cne 'herdr-excel-job-v1') {
        throw 'Excel job schema is unsupported.'
    }
    $jobId = Get-HerdrRequiredJsonString -Object $document -Name 'job_id' -Description 'Excel job'
    Assert-HerdrJobId -JobId $jobId | Out-Null
    if ((Get-HerdrRequiredJsonString -Object $document -Name 'operation' -Description 'Excel job') -cne 'recalculate') {
        throw 'Excel operation is not in the finite allowlist.'
    }
    $manifestPath = Get-HerdrCanonicalPath -Path (Get-HerdrRequiredJsonString -Object $document -Name 'staging_manifest' -Description 'Excel job')
    $approval = [ordered]@{ status = 'none' }
    if ($null -ne $document.PSObject.Properties['trust_approval']) {
        $approvalDocument = $document.trust_approval
        if ($null -eq $approvalDocument -or $approvalDocument -is [Array]) { throw 'Trust approval must be a named approval object.' }
        Assert-HerdrJsonProperties -Object $approvalDocument -Allowed @('approval_name', 'approver', 'approved_utc', 'scope', 'reason') -Description 'Trust approval'
        $approval = [ordered]@{
            status = 'explicit'
            approval_name = Get-HerdrRequiredJsonString -Object $approvalDocument -Name 'approval_name' -Description 'Trust approval'
            approver = Get-HerdrRequiredJsonString -Object $approvalDocument -Name 'approver' -Description 'Trust approval'
            approved_utc = Get-HerdrRequiredJsonString -Object $approvalDocument -Name 'approved_utc' -Description 'Trust approval'
            scope = Get-HerdrRequiredJsonString -Object $approvalDocument -Name 'scope' -Description 'Trust approval'
            reason = Get-HerdrRequiredJsonString -Object $approvalDocument -Name 'reason' -Description 'Trust approval'
        }
    }
    [pscustomobject][ordered]@{
        Path = $jobCanonical
        Schema = 'herdr-excel-job-v1'
        JobId = $jobId
        Operation = 'recalculate'
        ManifestPath = $manifestPath
        SourceRepository = Get-HerdrOptionalJsonString -Object $document -Name 'source_repository'
        SourceBranch = Get-HerdrOptionalJsonString -Object $document -Name 'source_branch'
        SourceCommit = Get-HerdrOptionalJsonString -Object $document -Name 'source_commit'
        TrustApproval = $approval
    }
}

function Test-HerdrInteractiveSession {
    [CmdletBinding()]
    param()

    if (-not $IsWindows -or -not [Environment]::UserInteractive) { return $false }
    try {
        $sessionId = [int](Get-Process -Id $PID -ErrorAction Stop).SessionId
        if ($sessionId -eq 0) { return $false }
        return @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId }).Count -gt 0
    }
    catch {
        return $false
    }
}

function Resolve-HerdrIdentitySid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$IdentityReference)

    if ($IdentityReference -is [Security.Principal.SecurityIdentifier]) { return $IdentityReference.Value }
    $identityText = [string]$IdentityReference
    if ($identityText -match '^S-\d-\d+(?:-\d+)+$') { return $identityText }
    try {
        return ([Security.Principal.NTAccount]::new($identityText)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        throw 'A host-owned ACL identity could not be resolved.'
    }
}

function Get-HerdrBridgeAccountSid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExpectedBridgeAccountSid)

    if (-not $IsWindows) { throw 'Bridge ACL inspection requires Windows.' }
    try {
        $user = Get-LocalUser -Name 'HerdrBridge' -ErrorAction Stop
        $actualSid = Assert-HerdrSidValue -Sid $user.SID.Value -Name 'HerdrBridge account SID'
        if ($actualSid -cne $ExpectedBridgeAccountSid) {
            throw 'The fixed HerdrBridge account SID does not match deployment configuration.'
        }
        return $actualSid
    }
    catch {
        throw "Could not resolve the fixed HerdrBridge account SID: $($_.Exception.Message)"
    }
}

function Test-HerdrWriteRights {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.AccessControl.FileSystemRights]$Rights)

    $writeMask = [int64]([Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership -bor
        [Security.AccessControl.FileSystemRights]::FullControl)
    return (([int64]$Rights -band $writeMask) -ne 0)
}

function Assert-HerdrBridgeCannotWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [string]$ExpectedBridgeAccountSid,
        [scriptblock]$AclReader,
        [scriptblock]$GroupSidReader,
        [scriptblock]$BridgeIdentityProbe,
        [switch]$TestMode
    )

    if (($null -ne $AclReader -or $null -ne $GroupSidReader -or $null -ne $BridgeIdentityProbe) -and -not $TestMode) {
        throw 'Bridge identity and ACL probes are permitted only in explicit test mode.'
    }
    if (-not $TestMode) {
        if ([string]::IsNullOrWhiteSpace($ExpectedBridgeAccountSid)) { throw 'Expected HerdrBridge account SID is required.' }
        $bridgeSid = Get-HerdrBridgeAccountSid -ExpectedBridgeAccountSid $ExpectedBridgeAccountSid
        foreach ($path in $Paths) {
            $canonicalPath = Get-HerdrCanonicalPath -Path $path
            if (-not (Test-Path -LiteralPath $canonicalPath -PathType Any)) {
                throw "Host-owned path is missing: '$canonicalPath'."
            }
            try {
                $acl = Get-Acl -LiteralPath $canonicalPath -ErrorAction Stop
                if (-not $acl.AreAccessRulesProtected) { throw "Host-owned path inherits access rules: '$canonicalPath'." }
                $securityDescriptor = $acl.GetSecurityDescriptorBinaryForm()
                $hasEffectiveWrite = [Herdr.Security.NativeMethods]::HasEffectiveWriteAccess($bridgeSid, $securityDescriptor)
            }
            catch {
                throw "Host-owned effective access could not be evaluated: '$canonicalPath': $($_.Exception.Message)"
            }
            if ($hasEffectiveWrite) {
                throw "Bridge account has effective write access to host-owned path '$canonicalPath'."
            }
        }
        return $true
    }
    $observedBridgeSid = $null
    if ($null -ne $BridgeIdentityProbe) {
        $identity = & $BridgeIdentityProbe
        $observedBridgeSid = if ($identity -is [string]) { [string]$identity } else { [string]$identity.UserSid }
        Assert-HerdrSidValue -Sid $observedBridgeSid -Name 'Observed bridge account SID' | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($ExpectedBridgeAccountSid) -and $observedBridgeSid -cne $ExpectedBridgeAccountSid) {
            throw 'Bridge account identity substitution was detected.'
        }
    }
    $groupSids = if ($null -ne $GroupSidReader) {
        @(& $GroupSidReader 'HerdrBridge')
    }
    else {
        if ([string]::IsNullOrWhiteSpace($ExpectedBridgeAccountSid)) { throw 'Expected HerdrBridge account SID is required.' }
        @($ExpectedBridgeAccountSid)
    }
    $groupSids = @(@($groupSids) | Select-Object -Unique)
    if ($groupSids.Count -eq 0) { throw 'Bridge account group membership is empty; refusing to continue.' }
    foreach ($path in $Paths) {
        $canonicalPath = Get-HerdrCanonicalPath -Path $path
        if (-not (Test-Path -LiteralPath $canonicalPath -PathType Any)) {
            throw "Host-owned path is missing: '$canonicalPath'."
        }
        try {
            $acl = if ($null -ne $AclReader) { & $AclReader $canonicalPath } else { Get-Acl -LiteralPath $canonicalPath -ErrorAction Stop }
        }
        catch {
            throw "Host-owned ACL could not be read: '$canonicalPath'."
        }
        if (-not $acl.AreAccessRulesProtected) { throw "Host-owned path inherits access rules: '$canonicalPath'." }
        foreach ($rule in @($acl.Access)) {
            $sid = [string](Resolve-HerdrIdentitySid -IdentityReference $rule.IdentityReference)
            $isBridgeSid = @($groupSids | ForEach-Object { [string]$_ }) -contains $sid
            $isAllow = [string]$rule.AccessControlType -ceq 'Allow'
            $hasWrite = [bool](Test-HerdrWriteRights -Rights $rule.FileSystemRights)
            if ($isBridgeSid -and $isAllow -and $hasWrite) {
                throw "Bridge account has write access to host-owned path '$canonicalPath'."
            }
        }
    }
    return $true
}

function Disable-HerdrExcelConnections {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Workbook)

    foreach ($connection in @($Workbook.Connections)) {
        try {
            $connection.OLEDBConnection.EnableRefresh = $false
            $connection.OLEDBConnection.RefreshOnFileOpen = $false
        }
        catch {
            try {
                $connection.ODBCConnection.EnableRefresh = $false
                $connection.ODBCConnection.RefreshOnFileOpen = $false
            }
            catch {
                throw 'Workbook data connections could not be disabled.'
            }
        }
    }
}

function Assert-HerdrExcelProcessIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Excel,
        [Parameter(Mandatory)][object]$Configuration,
        [switch]$TestMode,
        [scriptblock]$ExcelProcessProbe
    )

    if ($null -ne $ExcelProcessProbe -and -not $TestMode) {
        throw 'Excel process probes are permitted only in explicit test mode.'
    }
    if ($TestMode -and $null -ne $ExcelProcessProbe) {
        $observed = & $ExcelProcessProbe $Excel
        if ($observed -is [bool] -and -not $observed) { throw 'Excel process identity proof failed.' }
        return $observed
    }
    if (-not $IsWindows) { throw 'Excel process identity proof is Windows-only.' }
    $hwnd = [IntPtr]0
    try { $hwnd = [IntPtr]$Excel.Hwnd } catch { $hwnd = [IntPtr]0 }
    $processId = if ($hwnd -ne [IntPtr]::Zero) { [Herdr.Security.NativeMethods]::ReadWindowProcessId($hwnd) } else { 0 }
    if ($processId -le 0) {
        $candidates = @(Get-Process -Name EXCEL -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $Configuration.InteractiveSessionId })
        if ($candidates.Count -ne 1) { throw 'Excel process identity is ambiguous or unavailable.' }
        $processId = [int]$candidates[0].Id
    }
    $proof = Get-HerdrProcessIdentityProof -ProcessId $processId
    if ($proof.UserSid -cne $Configuration.InteractiveUserSid -or
        $proof.SessionId -ne $Configuration.InteractiveSessionId -or
        $proof.SessionId -eq 0) {
        throw 'Excel is not running as the designated interactive user and session.'
    }
    return $proof
}

function Invoke-HerdrExcelRecalculate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$ResultPath,
        [Parameter(Mandatory)][object]$IdentityConfiguration,
        [switch]$TestMode,
        [scriptblock]$ExcelProcessProbe
    )

    if (-not $IsWindows) { throw 'Excel COM execution is Windows-only.' }
    $excel = $null
    $workbook = $null
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $excel.EnableEvents = $false
        $excel.AutomationSecurity = 3
        $excel.AskToUpdateLinks = $false
        Assert-HerdrExcelProcessIdentity -Excel $excel -Configuration $IdentityConfiguration `
            -TestMode:$TestMode -ExcelProcessProbe $ExcelProcessProbe | Out-Null
        $workbook = $excel.Workbooks.Open($InputPath, 0, $false)
        Disable-HerdrExcelConnections -Workbook $workbook
        $workbook.UpdateLinks = 0
        $workbook.Calculate()
        Assert-HerdrExcelProcessIdentity -Excel $excel -Configuration $IdentityConfiguration `
            -TestMode:$TestMode -ExcelProcessProbe $ExcelProcessProbe | Out-Null
        $workbook.SaveCopyAs($ResultPath)
        $workbook.Close($false)
        $workbook = $null
        $excel.Quit()
        $excel = $null
    }
    catch {
        throw 'Excel COM operation failed closed.'
    }
    finally {
        if ($null -ne $workbook) { try { $workbook.Close($false) } catch {} }
        if ($null -ne $excel) { try { $excel.Quit() } catch {} }
    }
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) { throw 'Excel did not produce a result workbook.' }
}

function Invoke-HerdrExcelJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JobPath,
        [string]$RuntimeConfigurationPath,
        [string]$ExchangeRoot,
        [string]$ReviewJobsRoot,
        [string]$ToolsRoot,
        [string]$OneDriveInboxRoot,
        [string]$OneDriveOutboxRoot,
        [string]$OneDriveArchiveRoot,
        [string]$ExpectedInteractiveUserSid,
        [int]$ExpectedInteractiveSessionId = -1,
        [string]$ExpectedBridgeAccountSid,
        [switch]$TestMode,
        [scriptblock]$InteractiveSessionProbe,
        [scriptblock]$IdentityProbe,
        [scriptblock]$HostOwnedAccessProbe,
        [scriptblock]$ExcelInvoker,
        [scriptblock]$ExcelProcessProbe,
        [scriptblock]$AfterExcelHook,
        [scriptblock]$OneDriveReadyProbe
    )

    # A caller may invoke this script with the call operator, which gives a
    # dot-sourced dependency its own transient script scope. Import the
    # staging helper into this function scope so every helper used by the
    # bounded job remains available.
    . $script:HerdrReviewStagingScriptPath
    $copyHerdrFileExclusive = Get-Command Copy-HerdrFileExclusive -CommandType Function -ErrorAction Stop

    if (-not $TestMode -and ($null -ne $InteractiveSessionProbe -or $null -ne $IdentityProbe -or
        $null -ne $HostOwnedAccessProbe -or $null -ne $ExcelInvoker -or $null -ne $ExcelProcessProbe -or
        $null -ne $AfterExcelHook -or $null -ne $OneDriveReadyProbe)) {
        throw 'Test probes are permitted only in explicit test mode.'
    }
    if ($null -ne $InteractiveSessionProbe -and $null -ne $IdentityProbe) {
        throw 'Specify one interactive identity probe.'
    }
    $runtimeConfiguration = $null
    if (-not $TestMode -or -not [string]::IsNullOrWhiteSpace($RuntimeConfigurationPath) -or
        -not [string]::IsNullOrWhiteSpace($env:HERDR_WINDOWS_REVIEW_CONFIG)) {
        $runtimeConfiguration = Get-HerdrRuntimeConfiguration -Path $RuntimeConfigurationPath -TestMode:$TestMode
        $providedPaths = @(
            [pscustomobject]@{ Name = 'exchange_root'; Provided = $ExchangeRoot; Configured = $runtimeConfiguration.ExchangeRoot },
            [pscustomobject]@{ Name = 'review_jobs_root'; Provided = $ReviewJobsRoot; Configured = $runtimeConfiguration.ReviewJobsRoot },
            [pscustomobject]@{ Name = 'tools_root'; Provided = $ToolsRoot; Configured = $runtimeConfiguration.ToolsRoot },
            [pscustomobject]@{ Name = 'one_drive_inbox_root'; Provided = $OneDriveInboxRoot; Configured = $runtimeConfiguration.OneDriveInboxRoot },
            [pscustomobject]@{ Name = 'one_drive_outbox_root'; Provided = $OneDriveOutboxRoot; Configured = $runtimeConfiguration.OneDriveOutboxRoot },
            [pscustomobject]@{ Name = 'one_drive_archive_root'; Provided = $OneDriveArchiveRoot; Configured = $runtimeConfiguration.OneDriveArchiveRoot }
        )
        foreach ($pathRecord in $providedPaths) {
            if (-not [string]::IsNullOrWhiteSpace($pathRecord.Provided) -and
                -not (Get-HerdrCanonicalPath -Path $pathRecord.Provided).Equals($pathRecord.Configured, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Explicit $($pathRecord.Name) disagrees with host-owned runtime configuration."
            }
        }
        $ExchangeRoot = $runtimeConfiguration.ExchangeRoot
        $ReviewJobsRoot = $runtimeConfiguration.ReviewJobsRoot
        $ToolsRoot = $runtimeConfiguration.ToolsRoot
        $OneDriveInboxRoot = $runtimeConfiguration.OneDriveInboxRoot
        $OneDriveOutboxRoot = $runtimeConfiguration.OneDriveOutboxRoot
        $OneDriveArchiveRoot = $runtimeConfiguration.OneDriveArchiveRoot
        if ([string]::IsNullOrWhiteSpace($ExpectedInteractiveUserSid)) { $ExpectedInteractiveUserSid = $runtimeConfiguration.DesignatedInteractiveUserSid }
        if ($ExpectedInteractiveSessionId -lt 0) { $ExpectedInteractiveSessionId = $runtimeConfiguration.DesignatedInteractiveSessionId }
        if ([string]::IsNullOrWhiteSpace($ExpectedBridgeAccountSid)) { $ExpectedBridgeAccountSid = $runtimeConfiguration.BridgeAccountSid }
    }
    if ([string]::IsNullOrWhiteSpace($ExchangeRoot) -or [string]::IsNullOrWhiteSpace($ReviewJobsRoot) -or
        [string]::IsNullOrWhiteSpace($ToolsRoot) -or [string]::IsNullOrWhiteSpace($OneDriveInboxRoot)) {
        throw 'Explicit roots are incomplete; use a complete host-owned runtime configuration.'
    }
    $identityConfiguration = Get-HerdrIdentityConfiguration `
        -ExpectedInteractiveUserSid $ExpectedInteractiveUserSid `
        -ExpectedInteractiveSessionId $ExpectedInteractiveSessionId `
        -ExpectedBridgeAccountSid $ExpectedBridgeAccountSid `
        -TestMode:$TestMode
    if ($null -ne $runtimeConfiguration -and -not $TestMode) {
        Assert-HerdrBridgeCannotWrite -Paths @($runtimeConfiguration.ConfigurationPath) `
            -ExpectedBridgeAccountSid $identityConfiguration.BridgeAccountSid | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($OneDriveOutboxRoot)) { $OneDriveOutboxRoot = Get-HerdrDefaultOneDriveSiblingRoot -InboxRoot $OneDriveInboxRoot -Name Outbox }
    if ([string]::IsNullOrWhiteSpace($OneDriveArchiveRoot)) { $OneDriveArchiveRoot = Get-HerdrDefaultOneDriveSiblingRoot -InboxRoot $OneDriveInboxRoot -Name Archive }
    if ($null -ne $runtimeConfiguration) {
        Assert-HerdrOneDriveReady -OneDriveExchangeRoot $runtimeConfiguration.OneDriveExchangeRoot `
            -OneDriveAccount $runtimeConfiguration.OneDriveAccount -IdentityConfiguration $identityConfiguration `
            -TestMode:$TestMode -ReadyProbe $OneDriveReadyProbe | Out-Null
    }
    $exchangeCanonical = Ensure-HerdrManagedDirectory -Path (Assert-HerdrConfiguredLocalPath -Path $ExchangeRoot) -Description 'Exchange root'
    $reviewCanonical = Assert-HerdrConfiguredLocalPath -Path $ReviewJobsRoot
    $toolsCanonical = Assert-HerdrConfiguredLocalPath -Path $ToolsRoot
    $outboxCanonical = Ensure-HerdrManagedDirectory -Path (Join-Path $exchangeCanonical 'out') `
        -TrustedRoot $exchangeCanonical -Description 'Exchange output root'
    $oneDriveOutboxCanonical = Assert-HerdrConfiguredLocalPath -Path $OneDriveOutboxRoot
    $oneDriveArchiveCanonical = Assert-HerdrConfiguredLocalPath -Path $OneDriveArchiveRoot
    Assert-HerdrExistingPathIsNotReparsePoint -Path $exchangeCanonical | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $reviewCanonical | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $toolsCanonical | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $outboxCanonical -AllowMissing | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $oneDriveOutboxCanonical | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $oneDriveArchiveCanonical | Out-Null
    $exchangeInputCanonical = Ensure-HerdrManagedDirectory -Path (Join-Path $exchangeCanonical 'in') `
        -TrustedRoot $exchangeCanonical -Description 'Exchange input root'
    Assert-HerdrPathDoesNotOverlap -Left $exchangeCanonical -Right $reviewCanonical -Description 'exchange and review-job'
    Assert-HerdrPathDoesNotOverlap -Left $exchangeCanonical -Right $toolsCanonical -Description 'exchange and tools'
    Assert-HerdrPathDoesNotOverlap -Left $reviewCanonical -Right $toolsCanonical -Description 'review-job and tools'
    $oneDriveInboxCanonical = Assert-HerdrConfiguredLocalPath -Path $OneDriveInboxRoot
    Assert-HerdrExistingPathIsNotReparsePoint -Path $oneDriveInboxCanonical | Out-Null
    Assert-HerdrPathDoesNotOverlap -Left $exchangeCanonical -Right $oneDriveInboxCanonical -Description 'exchange and OneDrive'
    Assert-HerdrPathDoesNotOverlap -Left $exchangeCanonical -Right $oneDriveOutboxCanonical -Description 'exchange and OneDrive Outbox'
    Assert-HerdrPathDoesNotOverlap -Left $exchangeCanonical -Right $oneDriveArchiveCanonical -Description 'exchange and OneDrive Archive'
    $job = Read-HerdrExcelJob -JobPath $JobPath -ExchangeRoot $exchangeCanonical
    $manifest = Get-HerdrManifestRecord -ManifestPath $job.ManifestPath -JobId $job.JobId `
        -ExchangeRoot $exchangeCanonical -OneDriveInboxRoot $OneDriveInboxRoot `
        -OneDriveOutboxRoot $oneDriveOutboxCanonical -OneDriveArchiveRoot $oneDriveArchiveCanonical
    if ($job.SourceRepository -ne 'NOT-PROVIDED' -and $job.SourceRepository -cne $manifest.Provenance.repository) { throw 'Excel job repository provenance does not match the staging manifest.' }
    if ($job.SourceBranch -ne 'NOT-PROVIDED' -and $job.SourceBranch -cne $manifest.Provenance.branch) { throw 'Excel job branch provenance does not match the staging manifest.' }
    if ($job.SourceCommit -ne 'NOT-PROVIDED' -and $job.SourceCommit -cne $manifest.Provenance.commit) { throw 'Excel job commit provenance does not match the staging manifest.' }
    $jobLogsRoot = Ensure-HerdrManagedDirectory -Path (Join-Path $exchangeCanonical 'logs') `
        -TrustedRoot $exchangeCanonical -Description 'Exchange log root'
    $logPath = Get-HerdrCanonicalPath -Path (Join-Path $jobLogsRoot ($job.JobId + '.json'))
    if (Test-Path -LiteralPath $logPath) { throw "Job log collision for '$($job.JobId)'." }
    $reviewJobPath = Get-HerdrCanonicalPath -Path (Join-Path $reviewCanonical $job.JobId)
    $outboxJobPath = Get-HerdrCanonicalPath -Path (Join-Path $outboxCanonical $job.JobId)
    $oneDriveOutboxJobPath = Get-HerdrCanonicalPath -Path (Join-Path $oneDriveOutboxCanonical $job.JobId)
    if (Test-Path -LiteralPath $reviewJobPath -PathType Any -ErrorAction SilentlyContinue) { throw "Review-job collision for '$($job.JobId)'." }
    if (Test-Path -LiteralPath $outboxJobPath -PathType Any -ErrorAction SilentlyContinue) { throw "Outbox collision for '$($job.JobId)'." }
    if (Test-Path -LiteralPath $oneDriveOutboxJobPath -PathType Any -ErrorAction SilentlyContinue) { throw "OneDrive Outbox collision for '$($job.JobId)'." }
    $interactiveProbe = if ($null -ne $IdentityProbe) { $IdentityProbe } else { $InteractiveSessionProbe }
    Assert-HerdrInteractiveIdentity -Configuration $identityConfiguration -TestMode:$TestMode -IdentityProbe $interactiveProbe | Out-Null
    if ($null -ne $HostOwnedAccessProbe) {
        & $HostOwnedAccessProbe @($toolsCanonical, $reviewCanonical)
    }
    else {
        Assert-HerdrBridgeCannotWrite -Paths @($toolsCanonical, $reviewCanonical) `
            -ExpectedBridgeAccountSid $identityConfiguration.BridgeAccountSid -TestMode:$TestMode | Out-Null
    }
    $sourceBefore = Get-HerdrFileSnapshot -Path $manifest.SourcePath -TrustedRoot $oneDriveInboxCanonical -ExpectedIdentity $manifest.SourceIdentity
    if ($sourceBefore.Sha256 -cne $manifest.SourceHash -or $sourceBefore.SizeBytes -ne $manifest.SourceSizeBytes) { throw 'Canonical source workbook hash changed before execution.' }
    $stageBefore = Get-HerdrFileSnapshot -Path $manifest.StagedPath `
        -TrustedRoot (Join-Path (Join-Path $exchangeCanonical 'in') $job.JobId) -ExpectedIdentity $manifest.StagedIdentity
    if ($stageBefore.Sha256 -cne $manifest.StagedHash -or $stageBefore.SizeBytes -ne $manifest.StagedSizeBytes) { throw 'Bridge-stage workbook hash changed before execution.' }
    $reviewJobPath = Ensure-HerdrManagedDirectory -Path $reviewJobPath `
        -TrustedRoot $reviewCanonical -Description 'Excel review-job directory'
    if ($null -ne $HostOwnedAccessProbe) {
        & $HostOwnedAccessProbe @($toolsCanonical, $reviewCanonical, $reviewJobPath)
    }
    else {
        Assert-HerdrBridgeCannotWrite -Paths @($toolsCanonical, $reviewCanonical, $reviewJobPath) `
            -ExpectedBridgeAccountSid $identityConfiguration.BridgeAccountSid -TestMode:$TestMode | Out-Null
    }
    $extension = $manifest.Extension
    $lastMilePath = Get-HerdrCanonicalPath -Path (Join-Path $reviewJobPath ('input' + $extension))
    $resultWorkingPath = Get-HerdrCanonicalPath -Path (Join-Path $reviewJobPath ('result' + $extension))
    $completed = $false
    try {
        & $copyHerdrFileExclusive -SourcePath $manifest.StagedPath -DestinationPath $lastMilePath `
            -TrustedRoot (Join-Path (Join-Path $exchangeCanonical 'in') $job.JobId) `
            -ExpectedSourceIdentity $stageBefore -TrustedDestinationRoot $reviewJobPath | Out-Null
        $lastMileBefore = Get-HerdrFileSnapshot -Path $lastMilePath -TrustedRoot $reviewJobPath
        Assert-HerdrSnapshotContentEqual -Expected $stageBefore -Actual $lastMileBefore -Description 'Protected last-mile copy'
        if ($null -ne $ExcelInvoker) {
            & $ExcelInvoker $lastMilePath $resultWorkingPath
        }
        else {
            Invoke-HerdrExcelRecalculate -InputPath $lastMilePath -ResultPath $resultWorkingPath `
                -IdentityConfiguration $identityConfiguration -TestMode:$TestMode -ExcelProcessProbe $ExcelProcessProbe
        }
        if ($null -ne $AfterExcelHook) { & $AfterExcelHook }
        $lastMileAfter = Get-HerdrFileSnapshot -Path $lastMilePath -TrustedRoot $reviewJobPath -ExpectedIdentity $lastMileBefore
        Assert-HerdrSnapshotsEqual -Expected $lastMileBefore -Actual $lastMileAfter -Description 'Protected last-mile workbook'
        $sourceAfter = Get-HerdrFileSnapshot -Path $manifest.SourcePath -TrustedRoot $oneDriveInboxCanonical -ExpectedIdentity $sourceBefore
        if ($sourceAfter.Sha256 -cne $sourceBefore.Sha256 -or $sourceAfter.SizeBytes -ne $sourceBefore.SizeBytes) { throw 'Canonical source workbook changed during execution.' }
        $resultWorking = Get-HerdrFileSnapshot -Path $resultWorkingPath -TrustedRoot $reviewJobPath
        $outboxJobPath = Ensure-HerdrManagedDirectory -Path $outboxJobPath `
            -TrustedRoot $outboxCanonical -Description 'Exchange output job directory'
        $resultPath = Get-HerdrCanonicalPath -Path (Join-Path $outboxJobPath ('result' + $extension))
        & $copyHerdrFileExclusive -SourcePath $resultWorkingPath -DestinationPath $resultPath `
            -TrustedRoot $reviewJobPath -ExpectedSourceIdentity $resultWorking -TrustedDestinationRoot $outboxJobPath | Out-Null
        $result = Get-HerdrFileSnapshot -Path $resultPath -TrustedRoot $outboxJobPath
        Assert-HerdrSnapshotContentEqual -Expected $resultWorking -Actual $result -Description 'Outbox result copy'
        $oneDriveOutboxJobPath = Ensure-HerdrManagedDirectory -Path $oneDriveOutboxJobPath `
            -TrustedRoot $oneDriveOutboxCanonical -Description 'OneDrive output job directory'
        $oneDriveResultPath = Get-HerdrCanonicalPath -Path (Join-Path $oneDriveOutboxJobPath ('result' + $extension))
        & $copyHerdrFileExclusive -SourcePath $resultPath -DestinationPath $oneDriveResultPath `
            -TrustedRoot $outboxJobPath -ExpectedSourceIdentity $result -TrustedDestinationRoot $oneDriveOutboxJobPath | Out-Null
        $oneDriveResult = Get-HerdrFileSnapshot -Path $oneDriveResultPath -TrustedRoot $oneDriveOutboxJobPath
        Assert-HerdrSnapshotContentEqual -Expected $result -Actual $oneDriveResult -Description 'OneDrive Outbox result copy'
        $completedUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        $provenance = [ordered]@{
            schema = 'herdr-excel-job-result-v1'
            job_id = $job.JobId
            status = 'succeeded'
            operation = $job.Operation
            completed_utc = $completedUtc
            source = [ordered]@{
                path = $manifest.SourcePath
                observed_utc_before = $sourceBefore.CapturedUtc
                observed_utc_after = $sourceAfter.CapturedUtc
                sha256_before = $sourceBefore.Sha256
                sha256_after = $sourceAfter.Sha256
                last_write_time_utc_before = $sourceBefore.LastWriteTimeUtc
                last_write_time_utc_after = $sourceAfter.LastWriteTimeUtc
                size_bytes = $sourceAfter.SizeBytes
            }
            bridge_stage = [ordered]@{
                path = $manifest.StagedPath
                observed_utc = $stageBefore.CapturedUtc
                sha256 = $stageBefore.Sha256
                last_write_time_utc = $stageBefore.LastWriteTimeUtc
                size_bytes = $stageBefore.SizeBytes
            }
            last_mile = [ordered]@{
                path = $lastMilePath
                observed_utc = $lastMileAfter.CapturedUtc
                sha256 = $lastMileAfter.Sha256
                last_write_time_utc = $lastMileAfter.LastWriteTimeUtc
                size_bytes = $lastMileAfter.SizeBytes
            }
            result = [ordered]@{
                path = $resultPath
                observed_utc = $result.CapturedUtc
                sha256 = $result.Sha256
                last_write_time_utc = $result.LastWriteTimeUtc
                size_bytes = $result.SizeBytes
                one_drive_outbox_path = $oneDriveResultPath
                one_drive_outbox_sha256 = $oneDriveResult.Sha256
            }
            provenance = $manifest.Provenance
            trust_approval = $job.TrustApproval
            security = [ordered]@{
                interactive_session_required = $true
                designated_interactive_user_sid = $identityConfiguration.InteractiveUserSid
                designated_interactive_session_id = $identityConfiguration.InteractiveSessionId
                bridge_account_sid = $identityConfiguration.BridgeAccountSid
                macros = 'disabled'
                external_links = 'not-updated'
                data_connections = 'disabled'
                trusted_locations = 'none-added'
                canonical_workbook_mutated = $false
            }
        }
        $manifestOutputPath = Get-HerdrCanonicalPath -Path (Join-Path $outboxJobPath 'provenance.json')
        $json = $provenance | ConvertTo-Json -Depth 12 -Compress
        Write-HerdrAtomicText -Path $manifestOutputPath -Content $json -TrustedRoot $outboxJobPath | Out-Null
        $oneDriveManifestPath = Get-HerdrCanonicalPath -Path (Join-Path $oneDriveOutboxJobPath 'provenance.json')
        & $copyHerdrFileExclusive -SourcePath $manifestOutputPath -DestinationPath $oneDriveManifestPath `
            -TrustedRoot $outboxJobPath -TrustedDestinationRoot $oneDriveOutboxJobPath | Out-Null
        $logRecord = [ordered]@{
            schema = 'herdr-excel-job-log-v1'
            job_id = $job.JobId
            status = 'succeeded'
            operation = $job.Operation
            completed_utc = $completedUtc
            manifest_path = $manifestOutputPath
            result_path = $resultPath
            result_sha256 = $result.Sha256
            one_drive_result_path = $oneDriveResultPath
        }
        Write-HerdrAtomicText -Path $logPath -Content ($logRecord | ConvertTo-Json -Depth 8 -Compress) `
            -TrustedRoot $jobLogsRoot | Out-Null
        $completed = $true
        return [pscustomobject][ordered]@{
            Schema = $provenance.schema
            JobId = $job.JobId
            Status = $provenance.status
            ResultPath = $resultPath
            ResultSha256 = $result.Sha256
            ManifestPath = $manifestOutputPath
            LogPath = $logPath
            OneDriveResultPath = $oneDriveResultPath
            OneDriveManifestPath = $oneDriveManifestPath
        }
    }
    finally {
        if (-not $completed) {
            foreach ($cleanup in @(
                [pscustomobject]@{ Path = $outboxJobPath; Root = $outboxCanonical; Files = @('result.xlsx', 'result.xlsm', 'result.xlsb', 'provenance.json') },
                [pscustomobject]@{ Path = $oneDriveOutboxJobPath; Root = $oneDriveOutboxCanonical; Files = @('result.xlsx', 'result.xlsm', 'result.xlsb', 'provenance.json') },
                [pscustomobject]@{ Path = $reviewJobPath; Root = $reviewCanonical; Files = @('input.xlsx', 'input.xlsm', 'input.xlsb', 'result.xlsx', 'result.xlsm', 'result.xlsb') }
            )) {
                try {
                    Remove-HerdrManagedTree -Path $cleanup.Path -TrustedRoot $cleanup.Root -KnownFileNames $cleanup.Files
                }
                catch {
                    Write-Verbose "Safe runner cleanup did not remove '$($cleanup.Path)': $($_.Exception.Message)"
                }
            }
            try {
                if ($IsWindows) {
                    Remove-HerdrNativeRelativeEntry -Path $logPath -TrustedRoot $jobLogsRoot
                }
                elseif (Test-Path -LiteralPath $logPath) {
                    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
                Write-Verbose "Safe runner log cleanup did not remove '$logPath': $($_.Exception.Message)"
            }
        }
    }
}

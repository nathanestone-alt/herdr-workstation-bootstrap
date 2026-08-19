Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'HerdrReviewStaging.ps1')

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
    param([Parameter(Mandatory)][string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse point' }
        $raw = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
        $value = $raw | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    }
    catch {
        throw "JSON input is invalid or unreadable: '$Path'."
    }
    if ($null -eq $value -or $value -is [Array] -or $value -isnot [pscustomobject]) {
        throw "JSON input must be an object: '$Path'."
    }
    return $value
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
    if (-not (Test-HerdrPathSameOrDescendant -Candidate $manifestCanonical -Ancestor $allowedManifestRoot) -or
        [IO.Path]::GetExtension($manifestCanonical).ToLowerInvariant() -ne '.json') {
        throw 'Staging manifest is outside the job-specific exchange input directory.'
    }
    $document = Read-HerdrJsonFile -Path $manifestCanonical
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
    Assert-HerdrJsonProperties -Object $source -Allowed @('path', 'file_name', 'extension', 'captured_utc', 'size_bytes', 'last_write_time_utc', 'sha256') -Description 'Source record'
    Assert-HerdrJsonProperties -Object $stage -Allowed @('path', 'file_name', 'extension', 'captured_utc', 'size_bytes', 'last_write_time_utc', 'sha256') -Description 'Bridge-stage record'
    $sourcePath = Get-HerdrCanonicalPath -Path (Get-HerdrRequiredJsonString -Object $source -Name 'path' -Description 'Source record')
    if (-not (Test-HerdrPathSameOrDescendant -Candidate $sourcePath -Ancestor $inboxCanonical) -or
        $sourcePath.Equals($inboxCanonical, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staging manifest source is outside the configured OneDrive Inbox.'
    }
    $stagedPath = Get-HerdrCanonicalPath -Path (Get-HerdrRequiredJsonString -Object $stage -Name 'path' -Description 'Bridge-stage record')
    $manifestStagedPath = Get-HerdrCanonicalPath -Path (Get-HerdrRequiredJsonString -Object $document -Name 'staged_input_path' -Description 'Staging manifest')
    if (-not $stagedPath.Equals($manifestStagedPath, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-HerdrPathSameOrDescendant -Candidate $stagedPath -Ancestor $allowedManifestRoot)) {
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
    if (-not (Test-HerdrPathSameOrDescendant -Candidate $jobCanonical -Ancestor $jobInputRoot) -or
        [IO.Path]::GetExtension($jobCanonical).ToLowerInvariant() -ne '.json') {
        throw 'Excel job definition must be a JSON file under the exchange input root.'
    }
    $document = Read-HerdrJsonFile -Path $jobCanonical
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

function Get-HerdrBridgeGroupSids {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BridgeAccount)

    if (-not $IsWindows) { throw 'Bridge ACL inspection requires Windows.' }
    try {
        $user = Get-LocalUser -Name $BridgeAccount -ErrorAction Stop
        $sids = [Collections.Generic.List[string]]::new()
        $sids.Add($user.SID.Value)
        $adsiUser = [ADSI]"WinNT://$env:COMPUTERNAME/$BridgeAccount,user"
        foreach ($group in @($adsiUser.psbase.Invoke('Groups'))) {
            $sidBytes = $group.GetType().InvokeMember('objectSID', 'GetProperty', $null, $group, $null)
            $sids.Add(([Security.Principal.SecurityIdentifier]::new([byte[]]$sidBytes, 0)).Value)
        }
        return @($sids | Select-Object -Unique)
    }
    catch {
        throw 'Could not resolve the bridge account group membership.'
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
        [string]$BridgeAccount = 'HerdrBridge',
        [scriptblock]$AclReader,
        [scriptblock]$GroupSidReader
    )

    $groupSids = @(
        if ($null -ne $GroupSidReader) { & $GroupSidReader $BridgeAccount }
        else { Get-HerdrBridgeGroupSids -BridgeAccount $BridgeAccount }
    )
    $groupSids = @($groupSids + @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545') | Select-Object -Unique)
    if ($groupSids.Count -eq 0) { throw 'Bridge account group membership is empty; refusing to continue.' }
    foreach ($path in $Paths) {
        $canonicalPath = Get-HerdrCanonicalPath -Path $path
        if (-not (Test-Path -LiteralPath $canonicalPath -PathType Container)) {
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
            $sid = Resolve-HerdrIdentitySid -IdentityReference $rule.IdentityReference
            if ($sid -in $groupSids -and $rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                (Test-HerdrWriteRights -Rights $rule.FileSystemRights)) {
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

function Invoke-HerdrExcelRecalculate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$ResultPath
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
        $workbook = $excel.Workbooks.Open($InputPath, 0, $false)
        Disable-HerdrExcelConnections -Workbook $workbook
        $workbook.UpdateLinks = 0
        $workbook.Calculate()
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
        [string]$ExchangeRoot = 'C:\HerdrExchange',
        [string]$ReviewJobsRoot = 'C:\HerdrReviewJobs',
        [string]$ToolsRoot = 'C:\HerdrTools',
        [string]$OneDriveInboxRoot,
        [string]$OneDriveOutboxRoot,
        [string]$OneDriveArchiveRoot,
        [string]$BridgeAccount = 'HerdrBridge',
        [scriptblock]$InteractiveSessionProbe,
        [scriptblock]$HostOwnedAccessProbe,
        [scriptblock]$ExcelInvoker,
        [scriptblock]$AfterExcelHook
    )

    if ([string]::IsNullOrWhiteSpace($OneDriveInboxRoot)) { $OneDriveInboxRoot = Get-HerdrDefaultOneDriveInboxRoot }
    if ([string]::IsNullOrWhiteSpace($OneDriveOutboxRoot)) { $OneDriveOutboxRoot = Get-HerdrDefaultOneDriveSiblingRoot -InboxRoot $OneDriveInboxRoot -Name Outbox }
    if ([string]::IsNullOrWhiteSpace($OneDriveArchiveRoot)) { $OneDriveArchiveRoot = Get-HerdrDefaultOneDriveSiblingRoot -InboxRoot $OneDriveInboxRoot -Name Archive }
    $exchangeCanonical = Assert-HerdrConfiguredLocalPath -Path $ExchangeRoot
    $reviewCanonical = Assert-HerdrConfiguredLocalPath -Path $ReviewJobsRoot
    $toolsCanonical = Assert-HerdrConfiguredLocalPath -Path $ToolsRoot
    $outboxCanonical = Get-HerdrCanonicalPath -Path (Join-Path $exchangeCanonical 'out')
    $oneDriveOutboxCanonical = Assert-HerdrConfiguredLocalPath -Path $OneDriveOutboxRoot
    $oneDriveArchiveCanonical = Assert-HerdrConfiguredLocalPath -Path $OneDriveArchiveRoot
    Assert-HerdrExistingPathIsNotReparsePoint -Path $exchangeCanonical | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $reviewCanonical | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $toolsCanonical | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $outboxCanonical -AllowMissing | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $oneDriveOutboxCanonical | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $oneDriveArchiveCanonical | Out-Null
    Assert-HerdrPathDoesNotOverlap -Left $exchangeCanonical -Right $reviewCanonical -Description 'exchange and review-job'
    Assert-HerdrPathDoesNotOverlap -Left $exchangeCanonical -Right $toolsCanonical -Description 'exchange and tools'
    Assert-HerdrPathDoesNotOverlap -Left $reviewCanonical -Right $toolsCanonical -Description 'review-job and tools'
    Assert-HerdrPathDoesNotOverlap -Left $exchangeCanonical -Right (Assert-HerdrConfiguredLocalPath -Path $OneDriveInboxRoot) -Description 'exchange and OneDrive'
    Assert-HerdrPathDoesNotOverlap -Left $exchangeCanonical -Right $oneDriveOutboxCanonical -Description 'exchange and OneDrive Outbox'
    Assert-HerdrPathDoesNotOverlap -Left $exchangeCanonical -Right $oneDriveArchiveCanonical -Description 'exchange and OneDrive Archive'
    $job = Read-HerdrExcelJob -JobPath $JobPath -ExchangeRoot $exchangeCanonical
    $manifest = Get-HerdrManifestRecord -ManifestPath $job.ManifestPath -JobId $job.JobId `
        -ExchangeRoot $exchangeCanonical -OneDriveInboxRoot $OneDriveInboxRoot `
        -OneDriveOutboxRoot $oneDriveOutboxCanonical -OneDriveArchiveRoot $oneDriveArchiveCanonical
    if ($job.SourceRepository -ne 'NOT-PROVIDED' -and $job.SourceRepository -cne $manifest.Provenance.repository) { throw 'Excel job repository provenance does not match the staging manifest.' }
    if ($job.SourceBranch -ne 'NOT-PROVIDED' -and $job.SourceBranch -cne $manifest.Provenance.branch) { throw 'Excel job branch provenance does not match the staging manifest.' }
    if ($job.SourceCommit -ne 'NOT-PROVIDED' -and $job.SourceCommit -cne $manifest.Provenance.commit) { throw 'Excel job commit provenance does not match the staging manifest.' }
    $jobLogsRoot = Get-HerdrCanonicalPath -Path (Join-Path $exchangeCanonical 'logs')
    if (Test-Path -LiteralPath $jobLogsRoot -PathType Leaf) { throw 'Exchange log root is not a directory.' }
    [IO.Directory]::CreateDirectory($jobLogsRoot) | Out-Null
    $logPath = Get-HerdrCanonicalPath -Path (Join-Path $jobLogsRoot ($job.JobId + '.json'))
    if (Test-Path -LiteralPath $logPath) { throw "Job log collision for '$($job.JobId)'." }
    $reviewJobPath = Get-HerdrCanonicalPath -Path (Join-Path $reviewCanonical $job.JobId)
    $outboxJobPath = Get-HerdrCanonicalPath -Path (Join-Path $outboxCanonical $job.JobId)
    $oneDriveOutboxJobPath = Get-HerdrCanonicalPath -Path (Join-Path $oneDriveOutboxCanonical $job.JobId)
    if (Test-Path -LiteralPath $reviewJobPath -PathType Any -ErrorAction SilentlyContinue) { throw "Review-job collision for '$($job.JobId)'." }
    if (Test-Path -LiteralPath $outboxJobPath -PathType Any -ErrorAction SilentlyContinue) { throw "Outbox collision for '$($job.JobId)'." }
    if (Test-Path -LiteralPath $oneDriveOutboxJobPath -PathType Any -ErrorAction SilentlyContinue) { throw "OneDrive Outbox collision for '$($job.JobId)'." }
    $interactive = if ($null -ne $InteractiveSessionProbe) { [bool](& $InteractiveSessionProbe) } else { Test-HerdrInteractiveSession }
    if (-not $interactive) { throw 'Designated interactive Windows session is unavailable.' }
    if ($null -ne $HostOwnedAccessProbe) {
        & $HostOwnedAccessProbe @($toolsCanonical, $reviewCanonical)
    }
    else {
        Assert-HerdrBridgeCannotWrite -Paths @($toolsCanonical, $reviewCanonical) -BridgeAccount $BridgeAccount | Out-Null
    }
    $sourceBefore = Get-HerdrFileSnapshot -Path $manifest.SourcePath
    if ($sourceBefore.Sha256 -cne $manifest.SourceHash -or $sourceBefore.SizeBytes -ne $manifest.SourceSizeBytes) { throw 'Canonical source workbook hash changed before execution.' }
    $stageBefore = Get-HerdrFileSnapshot -Path $manifest.StagedPath
    if ($stageBefore.Sha256 -cne $manifest.StagedHash -or $stageBefore.SizeBytes -ne $manifest.StagedSizeBytes) { throw 'Bridge-stage workbook hash changed before execution.' }
    [IO.Directory]::CreateDirectory($reviewJobPath) | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $reviewJobPath | Out-Null
    if ($null -ne $HostOwnedAccessProbe) {
        & $HostOwnedAccessProbe @($toolsCanonical, $reviewCanonical, $reviewJobPath)
    }
    else {
        Assert-HerdrBridgeCannotWrite -Paths @($toolsCanonical, $reviewCanonical, $reviewJobPath) -BridgeAccount $BridgeAccount | Out-Null
    }
    $extension = $manifest.Extension
    $lastMilePath = Get-HerdrCanonicalPath -Path (Join-Path $reviewJobPath ('input' + $extension))
    $resultWorkingPath = Get-HerdrCanonicalPath -Path (Join-Path $reviewJobPath ('result' + $extension))
    $completed = $false
    try {
        Copy-HerdrFileExclusive -SourcePath $manifest.StagedPath -DestinationPath $lastMilePath | Out-Null
        $lastMileBefore = Get-HerdrFileSnapshot -Path $lastMilePath
        Assert-HerdrSnapshotContentEqual -Expected $stageBefore -Actual $lastMileBefore -Description 'Protected last-mile copy'
        if ($null -ne $ExcelInvoker) {
            & $ExcelInvoker $lastMilePath $resultWorkingPath
        }
        else {
            Invoke-HerdrExcelRecalculate -InputPath $lastMilePath -ResultPath $resultWorkingPath
        }
        if ($null -ne $AfterExcelHook) { & $AfterExcelHook }
        $lastMileAfter = Get-HerdrFileSnapshot -Path $lastMilePath
        Assert-HerdrSnapshotsEqual -Expected $lastMileBefore -Actual $lastMileAfter -Description 'Protected last-mile workbook'
        $sourceAfter = Get-HerdrFileSnapshot -Path $manifest.SourcePath
        if ($sourceAfter.Sha256 -cne $sourceBefore.Sha256 -or $sourceAfter.SizeBytes -ne $sourceBefore.SizeBytes) { throw 'Canonical source workbook changed during execution.' }
        $resultWorking = Get-HerdrFileSnapshot -Path $resultWorkingPath
        [IO.Directory]::CreateDirectory($outboxCanonical) | Out-Null
        [IO.Directory]::CreateDirectory($outboxJobPath) | Out-Null
        Assert-HerdrExistingPathIsNotReparsePoint -Path $outboxJobPath | Out-Null
        $resultPath = Get-HerdrCanonicalPath -Path (Join-Path $outboxJobPath ('result' + $extension))
        Copy-HerdrFileExclusive -SourcePath $resultWorkingPath -DestinationPath $resultPath | Out-Null
        $result = Get-HerdrFileSnapshot -Path $resultPath
        Assert-HerdrSnapshotContentEqual -Expected $resultWorking -Actual $result -Description 'Outbox result copy'
        [IO.Directory]::CreateDirectory($oneDriveOutboxJobPath) | Out-Null
        Assert-HerdrExistingPathIsNotReparsePoint -Path $oneDriveOutboxJobPath | Out-Null
        $oneDriveResultPath = Get-HerdrCanonicalPath -Path (Join-Path $oneDriveOutboxJobPath ('result' + $extension))
        Copy-HerdrFileExclusive -SourcePath $resultPath -DestinationPath $oneDriveResultPath | Out-Null
        $oneDriveResult = Get-HerdrFileSnapshot -Path $oneDriveResultPath
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
                macros = 'disabled'
                external_links = 'not-updated'
                data_connections = 'disabled'
                trusted_locations = 'none-added'
                canonical_workbook_mutated = $false
            }
        }
        $manifestOutputPath = Get-HerdrCanonicalPath -Path (Join-Path $outboxJobPath 'provenance.json')
        $json = $provenance | ConvertTo-Json -Depth 12 -Compress
        Write-HerdrAtomicText -Path $manifestOutputPath -Content $json | Out-Null
        $oneDriveManifestPath = Get-HerdrCanonicalPath -Path (Join-Path $oneDriveOutboxJobPath 'provenance.json')
        Copy-HerdrFileExclusive -SourcePath $manifestOutputPath -DestinationPath $oneDriveManifestPath | Out-Null
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
        Write-HerdrAtomicText -Path $logPath -Content ($logRecord | ConvertTo-Json -Depth 8 -Compress) | Out-Null
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
            if (Test-Path -LiteralPath $outboxJobPath) { Remove-Item -LiteralPath $outboxJobPath -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $oneDriveOutboxJobPath) { Remove-Item -LiteralPath $oneDriveOutboxJobPath -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $reviewJobPath) { Remove-Item -LiteralPath $reviewJobPath -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

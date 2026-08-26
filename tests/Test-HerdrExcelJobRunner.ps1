#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrExcelJobRunner.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Expected, [string]$Name) {
    $thrown = $false
    try { & $Action }
    catch {
        $thrown = $true
        if (-not $_.Exception.Message.Contains($Expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Name failed with an unexpected error: $($_.Exception.Message)"
        }
    }
    if (-not $thrown) { throw "$Name was accepted unexpectedly." }
}

function Write-TestJson([string]$Path, [object]$Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
}

$root = Join-Path ([IO.Path]::GetTempPath()) "herdr-runner-test-$([Guid]::NewGuid().ToString('N'))"
$oneDriveExchange = Join-Path $root 'onedrive\Herdr Review Exchange'
$inbox = Join-Path $oneDriveExchange 'Inbox'
$oneDriveOutbox = Join-Path $oneDriveExchange 'Outbox'
$oneDriveArchive = Join-Path $oneDriveExchange 'Archive'
$exchange = Join-Path $root 'exchange'
$reviewJobs = Join-Path $root 'review-jobs'
$tools = Join-Path $root 'tools'
$runtimeConfig = Join-Path $root 'runtime-config.json'
$secret = 'TEST-SECRET-MUST-NOT-LEAK'
$counter = 0
$accessCalls = [Collections.Generic.List[string]]::new()
$protectedReviewJobPaths = [Collections.Generic.List[string]]::new()
$expectedReviewJobPath = [IO.Path]::GetFullPath((Join-Path $reviewJobs 'job-001'))
$accessProbe = {
    param([object[]]$Paths)
    foreach ($path in $Paths) { [void]$accessCalls.Add([string]$path) }
    $true
}.GetNewClosure()
$protectionProbe = {
    param([string]$Path, [string]$OperatorSid)
    [void]$protectedReviewJobPaths.Add([IO.Path]::GetFullPath($Path))
    $true
}.GetNewClosure()
$successAccessProbe = {
    param([object[]]$Paths)
    foreach ($path in $Paths) {
        $canonicalPath = [IO.Path]::GetFullPath([string]$path)
        $hasProtection = @($protectedReviewJobPaths | Where-Object {
            $_.Equals($expectedReviewJobPath, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if ($canonicalPath.Equals($expectedReviewJobPath, [StringComparison]::OrdinalIgnoreCase) -and -not $hasProtection) {
            throw 'Review-job bridge ACL assertion ran before host-owned protection.'
        }
        [void]$accessCalls.Add([string]$path)
    }
    $true
}.GetNewClosure()
$interactiveProbe = { $true }
$oneDriveReadyProbe = { $true }
$copyHerdrFileExclusive = Get-Command Copy-HerdrFileExclusive -CommandType Function -ErrorAction Stop
$excelProbe = {
    param([string]$InputPath, [string]$ResultPath)
    & $copyHerdrFileExclusive -SourcePath $InputPath -DestinationPath $ResultPath | Out-Null
}.GetNewClosure()

function New-TestJob {
    $script:counter++
    $jobId = 'job-{0:d3}' -f $script:counter
    $source = Join-Path $inbox ("workbook-{0}.xlsx" -f $script:counter)
    [IO.File]::WriteAllBytes($source, [Text.Encoding]::UTF8.GetBytes("fixture $secret $jobId`n"))
    $staged = Invoke-HerdrReviewStaging -SourcePath $source -JobId $jobId -OneDriveExchangeRoot $oneDriveExchange `
        -OneDriveInboxRoot $inbox `
        -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
        -ExchangeRoot $exchange -Repository 'STModel-Private' -Branch 'main' -Commit 'abc123' -StabilityIntervalMilliseconds 0
    $jobPath = Join-Path (Split-Path -Parent $staged.ManifestPath) 'job.json'
    Write-TestJson -Path $jobPath -Value ([ordered]@{
        schema = 'herdr-excel-job-v1'
        job_id = $jobId
        operation = 'recalculate'
        staging_manifest = $staged.ManifestPath
        source_repository = 'STModel-Private'
        source_branch = 'main'
        source_commit = 'abc123'
    })
    return [pscustomobject]@{ Job = $jobPath; JobId = $jobId; Source = $source; Staged = $staged }
}

try {
    New-Item -ItemType Directory -Path $inbox, $oneDriveOutbox, $oneDriveArchive, $exchange, $reviewJobs, $tools -Force | Out-Null
    $platformRoot = [IO.Path]::GetPathRoot($root)
    $platformRootProof = Get-HerdrPhysicalPathProof -Path $platformRoot -AllowedCloudFilesRoot $oneDriveExchange
    Assert-True ($platformRootProof.Exists -and $platformRootProof.Leaf.IsDirectory) `
        "A configured Cloud Files boundary incorrectly rejected the platform root '$platformRoot'."
    if ($IsWindows) {
        # DestinationAllowedCloudFilesRoot is independent of TrustedDestinationRoot.
        # This exercises Copy-HerdrFileExclusive's C:\ operation root on Windows.
        $independentCopySource = Join-Path $exchange 'independent-boundary-source.xlsx'
        $independentCopyDestination = Join-Path $oneDriveOutbox 'independent-boundary-destination.xlsx'
        [IO.File]::WriteAllBytes($independentCopySource, [Text.Encoding]::UTF8.GetBytes('independent boundary fixture'))
        Copy-HerdrFileExclusive -SourcePath $independentCopySource -DestinationPath $independentCopyDestination `
            -DestinationAllowedCloudFilesRoot $oneDriveExchange | Out-Null
        Assert-True (Test-Path -LiteralPath $independentCopyDestination -PathType Leaf) `
            'A destination Cloud Files boundary was incorrectly coupled to TrustedDestinationRoot.'
    }
    Write-TestJson -Path $runtimeConfig -Value ([ordered]@{
        schema = 'herdr-windows-review-runtime-v1'
        approved = $true
        one_drive_exchange_root = $oneDriveExchange
        one_drive_account = 'configured@example.invalid'
        exchange_root = $exchange
        review_jobs_root = $reviewJobs
        tools_root = $tools
        designated_interactive_user_sid = 'S-1-5-21-961-1001'
        designated_interactive_session_id = 7
        bridge_account_sid = 'S-1-5-21-961-1002'
    })
    $runtime = Get-HerdrRuntimeConfiguration -Path $runtimeConfig
    Assert-True ($runtime.ReviewJobsRoot -ceq $reviewJobs) 'Runtime configuration did not resolve the local review-job root.'
    Assert-True ($runtime.OneDriveArchiveRoot -ceq $oneDriveArchive) 'Runtime configuration did not derive the OneDrive Archive root.'
    Assert-True ($null -ne (Get-Command Copy-HerdrFileExclusive -ErrorAction SilentlyContinue)) 'Runner dependency did not expose Copy-HerdrFileExclusive.'
    $unapprovedConfig = Join-Path $root 'unapproved-runtime-config.json'
    $unapprovedDocument = [IO.File]::ReadAllText($runtimeConfig) | ConvertFrom-Json
    $unapprovedDocument.approved = $false
    Write-TestJson -Path $unapprovedConfig -Value $unapprovedDocument
    Assert-Throws { Get-HerdrRuntimeConfiguration -Path $unapprovedConfig } 'not explicitly approved' 'unapproved runtime configuration'
    Assert-HerdrOneDriveReady -OneDriveExchangeRoot $oneDriveExchange -OneDriveAccount 'configured@example.invalid' `
        -IdentityConfiguration ([pscustomobject]@{ InteractiveUserSid = 'S-1-5-21-961-1001'; InteractiveSessionId = 7 }) `
        -TestMode -ReadyProbe { $true } | Out-Null
    Assert-Throws {
        Assert-HerdrOneDriveReady -OneDriveExchangeRoot $oneDriveExchange -OneDriveAccount 'configured@example.invalid' `
            -IdentityConfiguration ([pscustomobject]@{ InteractiveUserSid = 'S-1-5-21-961-1001'; InteractiveSessionId = 7 }) `
            -TestMode -ReadyProbe { $false } | Out-Null
    } 'not ready' 'OneDrive readiness gate'
    Assert-Throws {
        Assert-HerdrOneDriveReady -OneDriveExchangeRoot $oneDriveExchange -OneDriveAccount 'configured@example.invalid' `
            -IdentityConfiguration ([pscustomobject]@{ InteractiveUserSid = 'S-1-5-21-961-1001'; InteractiveSessionId = 7 }) `
            -TestMode | Out-Null
    } 'readiness probe' 'OneDrive readiness requires probe'
    $jsonReaderProbePath = Join-Path $root 'json-reader-probe.json'
    [IO.File]::WriteAllText($jsonReaderProbePath, '{"schema":"probe"}', [Text.UTF8Encoding]::new($false))
    $jsonReaderOwner = [IO.FileStream]::new($jsonReaderProbePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $jsonReaderBorrowedHandle = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new(
        $jsonReaderOwner.SafeFileHandle.DangerousGetHandle(), $false)
    $jsonReaderStream = $null
    $jsonReader = $null
    try {
        $jsonReaderStream = [IO.FileStream]::new($jsonReaderBorrowedHandle, [IO.FileAccess]::Read, 4096, $false)
        $jsonReader = [IO.StreamReader]::new($jsonReaderStream, [Text.UTF8Encoding]::new($false, $true), $true, 4096, $true)
        Assert-True (($jsonReader.ReadToEnd()) -ceq '{"schema":"probe"}') 'The supported handle-backed JSON reader did not read the fixture.'
    }
    finally {
        if ($null -ne $jsonReader) { $jsonReader.Dispose() }
        if ($null -ne $jsonReaderStream) { $jsonReaderStream.Dispose() }
        if ($null -ne $jsonReaderBorrowedHandle -and -not $jsonReaderBorrowedHandle.IsClosed) { $jsonReaderBorrowedHandle.Dispose() }
        if ($null -ne $jsonReaderOwner) { $jsonReaderOwner.Dispose() }
    }
    if ($IsWindows) {
        $jsonReaderExclusivePath = Join-Path $root 'json-reader-exclusive.json'
        [IO.File]::WriteAllText($jsonReaderExclusivePath, '{"schema":"exclusive-share-zero"}', [Text.UTF8Encoding]::new($false))
        $jsonReaderExclusiveValue = Read-HerdrJsonFile -Path $jsonReaderExclusivePath
        Assert-True ($jsonReaderExclusiveValue.schema -ceq 'exclusive-share-zero') `
            'The production Windows JSON reader did not complete with its share-zero handle held during proof.'
    }
    $success = New-TestJob
    $successResult = Invoke-HerdrExcelJob -JobPath $success.Job -RuntimeConfigurationPath $runtimeConfig `
        -TestMode `
        -InteractiveSessionProbe $interactiveProbe `
        -HostOwnedAccessProbe $successAccessProbe -HostOwnedTreeProtector $protectionProbe `
        -OneDriveReadyProbe $oneDriveReadyProbe -ExcelInvoker $excelProbe
    Assert-True ($successResult.Status -ceq 'succeeded') 'The hermetic runner did not succeed.'
    Assert-True (Test-Path -LiteralPath $successResult.ResultPath -PathType Leaf) 'The runner result is missing.'
    Assert-True (Test-Path -LiteralPath $successResult.ManifestPath -PathType Leaf) 'The runner provenance manifest is missing.'
    Assert-True (Test-Path -LiteralPath $successResult.LogPath -PathType Leaf) 'The runner job log is missing.'
    Assert-True (Test-Path -LiteralPath $successResult.OneDriveResultPath -PathType Leaf) 'The OneDrive Outbox result is missing.'
    Assert-True (Test-Path -LiteralPath $successResult.OneDriveManifestPath -PathType Leaf) 'The OneDrive Outbox manifest is missing.'
    $resultManifest = [IO.File]::ReadAllText($successResult.ManifestPath)
    $resultDocument = $resultManifest | ConvertFrom-Json
    $jobLog = [IO.File]::ReadAllText($successResult.LogPath)
    $oneDriveManifest = [IO.File]::ReadAllText($successResult.OneDriveManifestPath)
    Assert-True ($resultManifest.Contains('herdr-excel-job-result-v1', [StringComparison]::Ordinal)) 'Result manifest schema is missing.'
    Assert-True ($resultManifest.Contains('macros', [StringComparison]::Ordinal) -and $resultManifest.Contains('disabled', [StringComparison]::Ordinal)) 'Macro default deny is not recorded.'
    Assert-True ($resultManifest.Contains('immutable_for_bridge_account', [StringComparison]::Ordinal)) 'Last-mile bridge immutability is not recorded.'
    Assert-True ($resultDocument.last_mile.protected -eq $true) 'Last-mile protection did not record the observed true result.'
    Assert-True ($resultDocument.last_mile.immutable_for_bridge_account -eq $true) 'Last-mile bridge immutability did not record the observed true result.'
    Assert-True ($resultDocument.trust_approval_verified -eq $false) 'Trust approval verification was not explicitly recorded as false.'
    Assert-True (-not $resultManifest.Contains($secret, [StringComparison]::Ordinal)) 'Result manifest leaked workbook content.'
    Assert-True (-not $jobLog.Contains($secret, [StringComparison]::Ordinal)) 'Job log leaked workbook content.'
    Assert-True ($oneDriveManifest -ceq $resultManifest) 'The OneDrive Outbox manifest differs from the bridge manifest.'
    Assert-True ((Get-HerdrFileSnapshot -Path $success.Source).Sha256 -ceq $successResult.ResultSha256) 'The canonical source was not preserved.'
    Assert-True (@($protectedReviewJobPaths | Where-Object {
        $_.Equals($expectedReviewJobPath, [StringComparison]::OrdinalIgnoreCase)
    }).Count -eq 1) 'Review-job host-owned protection was not invoked.'
    Assert-True ($accessCalls.Count -ge 2) 'Host-owned ACL policy was not checked before execution.'
    $cliOutput = $successResult | ConvertTo-Json -Compress
    Assert-True (-not $cliOutput.Contains($secret, [StringComparison]::Ordinal)) 'Runner output leaked workbook content.'

    Assert-Throws {
        Assert-HerdrInteractiveIdentity -Configuration ([pscustomobject]@{
            InteractiveUserSid = 'S-1-5-21-961-1001'
            InteractiveSessionId = 7
        }) -TestMode -IdentityProbe { $null } | Out-Null
    } 'interactive Windows session' 'null interactive-session proof'
    Assert-Throws {
        Assert-HerdrExcelProcessIdentity -Excel ([pscustomobject]@{}) -Configuration ([pscustomobject]@{
            InteractiveUserSid = 'S-1-5-21-961-1001'
            InteractiveSessionId = 7
        }) -TestMode -ExcelProcessProbe { $null } | Out-Null
    } 'process identity proof' 'null Excel-process proof'

    $stageMismatch = New-TestJob
    [IO.File]::WriteAllBytes($stageMismatch.Staged.StagedPath, [Text.Encoding]::UTF8.GetBytes('changed bridge stage'))
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $stageMismatch.Job -RuntimeConfigurationPath $runtimeConfig `
            -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs `
            -ToolsRoot $tools -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
            -TestMode -InteractiveSessionProbe $interactiveProbe -HostOwnedAccessProbe $accessProbe `
            -HostOwnedTreeProtector $protectionProbe -OneDriveReadyProbe $oneDriveReadyProbe -ExcelInvoker $excelProbe
    } 'Bridge-stage workbook hash changed' 'bridge-stage hash gate'

    $configurationDisagreement = New-TestJob
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $configurationDisagreement.Job -RuntimeConfigurationPath $runtimeConfig `
            -ExchangeRoot $tools -TestMode
    } 'Explicit exchange_root disagrees with host-owned runtime configuration.' 'explicit/configured exchange-root disagreement gate'

    $lastMileMutation = New-TestJob
    $lastMilePath = Join-Path (Join-Path $reviewJobs $lastMileMutation.JobId) 'input.xlsx'
    $mutateLastMile = {
        [IO.File]::WriteAllBytes($lastMilePath, [Text.Encoding]::UTF8.GetBytes('changed protected copy'))
    }.GetNewClosure()
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $lastMileMutation.Job -RuntimeConfigurationPath $runtimeConfig `
            -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs `
            -ToolsRoot $tools -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
            -TestMode -InteractiveSessionProbe $interactiveProbe -HostOwnedAccessProbe $accessProbe `
            -HostOwnedTreeProtector $protectionProbe -OneDriveReadyProbe $oneDriveReadyProbe `
            -ExcelInvoker $excelProbe -AfterExcelHook $mutateLastMile
    } 'Protected last-mile workbook' 'protected last-mile hash gate'

    $reviewCollision = New-TestJob
    New-Item -ItemType Directory -Path (Join-Path $reviewJobs $reviewCollision.JobId) -Force | Out-Null
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $reviewCollision.Job -RuntimeConfigurationPath $runtimeConfig `
            -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs `
            -ToolsRoot $tools -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
            -TestMode -InteractiveSessionProbe $interactiveProbe -HostOwnedAccessProbe $accessProbe `
            -HostOwnedTreeProtector $protectionProbe -OneDriveReadyProbe $oneDriveReadyProbe -ExcelInvoker $excelProbe
    } 'Review-job collision' 'review-job collision'

    $misboundJob = New-TestJob
    $misboundPath = Join-Path (Join-Path $exchange 'in') 'misbound-job.json'
    [IO.File]::Copy($misboundJob.Job, $misboundPath)
    Assert-Throws {
        Read-HerdrExcelJob -JobPath $misboundPath -ExchangeRoot $exchange | Out-Null
    } 'job-ID directory' 'job definition binding'

    $unknownOperation = New-TestJob
    $unknownDocument = [IO.File]::ReadAllText($unknownOperation.Job) | ConvertFrom-Json
    $unknownDocument.operation = 'invoke-command'
    Write-TestJson -Path $unknownOperation.Job -Value $unknownDocument
    Assert-Throws {
        Read-HerdrExcelJob -JobPath $unknownOperation.Job -ExchangeRoot $exchange
    } 'finite allowlist' 'unknown operation'

    $unknownField = New-TestJob
    $unknownDocument = [IO.File]::ReadAllText($unknownField.Job) | ConvertFrom-Json
    $unknownDocument | Add-Member -NotePropertyName command -NotePropertyValue 'Get-ChildItem'
    Write-TestJson -Path $unknownField.Job -Value $unknownDocument
    Assert-Throws {
        Read-HerdrExcelJob -JobPath $unknownField.Job -ExchangeRoot $exchange
    } 'unknown field' 'arbitrary command field'

    $powershellField = New-TestJob
    $powershellDocument = [IO.File]::ReadAllText($powershellField.Job) | ConvertFrom-Json
    $powershellDocument | Add-Member -NotePropertyName powershell -NotePropertyValue 'Get-Process'
    Write-TestJson -Path $powershellField.Job -Value $powershellDocument
    Assert-Throws {
        Read-HerdrExcelJob -JobPath $powershellField.Job -ExchangeRoot $exchange
    } 'unknown field' 'arbitrary PowerShell field'

    $approvedJob = New-TestJob
    $approvedDocument = [IO.File]::ReadAllText($approvedJob.Job) | ConvertFrom-Json
    $approvedDocument | Add-Member -NotePropertyName trust_approval -NotePropertyValue ([pscustomobject]@{
        approval_name = 'fixture-approval-961'
        approver = 'fixture-reviewer'
        approved_utc = '2026-08-26T00:00:00Z'
        scope = 'fixture-only'
        reason = 'hermetic regression fixture'
    })
    Write-TestJson -Path $approvedJob.Job -Value $approvedDocument
    $approvedResult = Invoke-HerdrExcelJob -JobPath $approvedJob.Job -RuntimeConfigurationPath $runtimeConfig `
        -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs `
        -ToolsRoot $tools -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
        -TestMode -InteractiveSessionProbe $interactiveProbe -HostOwnedAccessProbe $accessProbe `
        -HostOwnedTreeProtector $protectionProbe -OneDriveReadyProbe $oneDriveReadyProbe -ExcelInvoker $excelProbe
    $approvedManifest = [IO.File]::ReadAllText($approvedResult.ManifestPath)
    Assert-True ($approvedManifest.Contains('fixture-approval-961', [StringComparison]::Ordinal)) `
        'Named trust approval was not retained in result provenance.'
    $approvedDocument = $approvedManifest | ConvertFrom-Json
    Assert-True ($approvedDocument.trust_approval_verified -eq $false) `
        'Declarative trust approval was incorrectly marked as verified.'

    $noInteractive = New-TestJob
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $noInteractive.Job -RuntimeConfigurationPath $runtimeConfig `
            -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs `
            -ToolsRoot $tools -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
            -TestMode `
            -InteractiveSessionProbe { $false } `
            -HostOwnedAccessProbe $accessProbe -OneDriveReadyProbe $oneDriveReadyProbe -ExcelInvoker $excelProbe
    } 'interactive Windows session' 'interactive-session gate'

    $bridgeWrite = New-TestJob
    $bridgeProbe = { param([object[]]$Paths) throw 'bridge write probe failed' }
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $bridgeWrite.Job -RuntimeConfigurationPath $runtimeConfig `
            -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs `
            -ToolsRoot $tools -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
            -TestMode `
            -InteractiveSessionProbe $interactiveProbe `
            -HostOwnedAccessProbe $bridgeProbe -OneDriveReadyProbe $oneDriveReadyProbe -ExcelInvoker $excelProbe
    } 'bridge write probe failed' 'bridge ACL gate'

    $sourceMutation = New-TestJob
    $mutateSource = { [IO.File]::WriteAllBytes($sourceMutation.Source, [Text.Encoding]::UTF8.GetBytes('changed source')) }.GetNewClosure()
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $sourceMutation.Job -RuntimeConfigurationPath $runtimeConfig `
            -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs `
            -ToolsRoot $tools -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
            -TestMode `
            -InteractiveSessionProbe $interactiveProbe `
            -HostOwnedAccessProbe $accessProbe -HostOwnedTreeProtector $protectionProbe `
            -OneDriveReadyProbe $oneDriveReadyProbe -ExcelInvoker $excelProbe -AfterExcelHook $mutateSource
    } 'changed during execution' 'canonical source after-hash gate'

    $aclRoot = Join-Path $root 'acl-fixture'
    New-Item -ItemType Directory -Path $aclRoot -Force | Out-Null
    $writeRule = [pscustomobject]@{
        IdentityReference = 'S-1-5-32-545'
        AccessControlType = [Security.AccessControl.AccessControlType]::Allow
        FileSystemRights = [Security.AccessControl.FileSystemRights]::Modify
    }
    $readRule = [pscustomobject]@{
        IdentityReference = 'S-1-5-18'
        AccessControlType = [Security.AccessControl.AccessControlType]::Allow
        FileSystemRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute
    }
    $acl = [pscustomobject]@{ AreAccessRulesProtected = $true; Access = @($writeRule, $readRule) }
    $aclReader = { param([string]$Path) $acl }.GetNewClosure()
    $groups = { param([string]$Account) @('S-1-5-32-545') }
    Assert-Throws {
        Assert-HerdrBridgeCannotWrite -Paths @($aclRoot) -AclReader $aclReader -GroupSidReader $groups -TestMode
    } 'write access' 'ACL write deny'
    $safeAcl = [pscustomobject]@{ AreAccessRulesProtected = $true; Access = @($readRule) }
    $safeReader = { param([string]$Path) $safeAcl }.GetNewClosure()
    Assert-HerdrBridgeCannotWrite -Paths @($aclRoot) -AclReader $safeReader -GroupSidReader $groups -TestMode | Out-Null
    Assert-HerdrBridgeCannotWrite -Paths @($runtimeConfig) -AclReader $safeReader -GroupSidReader $groups -TestMode | Out-Null

    $runnerText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\scripts\windows\HerdrExcelJobRunner.ps1')
    Assert-True ($runnerText.Contains('FileStream]::new($opened.SafeHandle', [StringComparison]::Ordinal)) 'The production JSON reader is not handle-backed through FileStream.'
    Assert-True (-not $runnerText.Contains('StreamReader]::new($opened.SafeHandle', [StringComparison]::Ordinal)) 'The production JSON reader uses the unsupported SafeFileHandle StreamReader overload.'
    foreach ($required in @('AutomationSecurity = 3', 'AskToUpdateLinks = $false', 'EnableRefresh = $false', 'RefreshOnFileOpen = $false', 'Workbooks.Open($InputPath, 0, $false)', 'SaveCopyAs', 'canonical_workbook_mutated')) {
        Assert-True ($runnerText.Contains($required, [StringComparison]::Ordinal)) "Excel canary marker is missing: $required"
    }
    Assert-True (-not $runnerText.Contains('$workbook.Calculate()', [StringComparison]::Ordinal)) `
        'Workbook-level Calculate is invalid and must not return.'
    $connectionIndex = $runnerText.IndexOf('Disable-HerdrExcelConnections -Workbook $workbook', [StringComparison]::Ordinal)
    $calculateIndex = $runnerText.IndexOf('$excel.Calculate()', [StringComparison]::Ordinal)
    $postCalculateIdentityIndex = if ($calculateIndex -ge 0) {
        $runnerText.IndexOf('Assert-HerdrExcelProcessIdentity -Excel $excel', $calculateIndex, [StringComparison]::Ordinal)
    }
    else { -1 }
    $saveCopyIndex = $runnerText.IndexOf('$workbook.SaveCopyAs($ResultPath)', [StringComparison]::Ordinal)
    Assert-True ($connectionIndex -ge 0 -and $calculateIndex -gt $connectionIndex -and
        $postCalculateIdentityIndex -gt $calculateIndex -and $saveCopyIndex -gt $postCalculateIdentityIndex) `
        'Application-level Excel calculation call or ordering is missing.'
    foreach ($forbidden in @('RefreshAll', 'Invoke-Expression', 'Start-Process', 'TrustedLocation', 'RunAutoMacros', '$workbook.UpdateLinks = 0')) {
        Assert-True (-not $runnerText.Contains($forbidden, [StringComparison]::Ordinal)) "Excel canary regression marker is present: $forbidden"
    }
    Assert-True ($runnerText.Contains('HostOwnedTreeProtector', [StringComparison]::Ordinal)) 'The runner lacks the focused host-owned protection test seam.'
    Assert-True ($runnerText.Contains('Protect-HostOwnedTree -TargetPath $reviewJobPath', [StringComparison]::Ordinal)) 'The runner does not apply the host-owned ACL policy to new review-job directories.'
    $outputTexts = @(Get-ChildItem -LiteralPath $exchange -File -Recurse -Filter '*.json' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) })
    foreach ($text in $outputTexts) {
        Assert-True (-not $text.Contains($secret, [StringComparison]::Ordinal)) 'Runner output or log leaked workbook content.'
    }
    Write-Host 'Herdr Excel job runner regression test passed.'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

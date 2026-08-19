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
$inbox = Join-Path $root 'onedrive\Herdr Review Exchange\Inbox'
$oneDriveOutbox = Join-Path $root 'onedrive\Herdr Review Exchange\Outbox'
$oneDriveArchive = Join-Path $root 'onedrive\Herdr Review Exchange\Archive'
$exchange = Join-Path $root 'exchange'
$reviewJobs = Join-Path $root 'review-jobs'
$tools = Join-Path $root 'tools'
$secret = 'TEST-SECRET-MUST-NOT-LEAK'
$counter = 0
$accessCalls = [Collections.Generic.List[string]]::new()
$accessProbe = {
    param([object[]]$Paths)
    foreach ($path in $Paths) { [void]$accessCalls.Add([string]$path) }
}.GetNewClosure()
$interactiveProbe = { $true }
$excelProbe = {
    param([string]$InputPath, [string]$ResultPath)
    Copy-HerdrFileExclusive -SourcePath $InputPath -DestinationPath $ResultPath | Out-Null
}.GetNewClosure()

function New-TestJob {
    $script:counter++
    $jobId = 'job-{0:d3}' -f $script:counter
    $source = Join-Path $inbox ("workbook-{0}.xlsx" -f $script:counter)
    [IO.File]::WriteAllBytes($source, [Text.Encoding]::UTF8.GetBytes("fixture $secret $jobId`n"))
    $staged = Invoke-HerdrReviewStaging -SourcePath $source -JobId $jobId -OneDriveInboxRoot $inbox `
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
    return [pscustomobject]@{ Job = $jobPath; Source = $source; Staged = $staged }
}

try {
    New-Item -ItemType Directory -Path $inbox, $oneDriveOutbox, $oneDriveArchive, $exchange, $reviewJobs, $tools -Force | Out-Null
    $success = New-TestJob
    $successResult = Invoke-HerdrExcelJob -JobPath $success.Job -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs `
        -ToolsRoot $tools -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
        -InteractiveSessionProbe $interactiveProbe `
        -HostOwnedAccessProbe $accessProbe -ExcelInvoker $excelProbe
    Assert-True ($successResult.Status -ceq 'succeeded') 'The hermetic runner did not succeed.'
    Assert-True (Test-Path -LiteralPath $successResult.ResultPath -PathType Leaf) 'The runner result is missing.'
    Assert-True (Test-Path -LiteralPath $successResult.ManifestPath -PathType Leaf) 'The runner provenance manifest is missing.'
    Assert-True (Test-Path -LiteralPath $successResult.LogPath -PathType Leaf) 'The runner job log is missing.'
    Assert-True (Test-Path -LiteralPath $successResult.OneDriveResultPath -PathType Leaf) 'The OneDrive Outbox result is missing.'
    Assert-True (Test-Path -LiteralPath $successResult.OneDriveManifestPath -PathType Leaf) 'The OneDrive Outbox manifest is missing.'
    $resultManifest = [IO.File]::ReadAllText($successResult.ManifestPath)
    $jobLog = [IO.File]::ReadAllText($successResult.LogPath)
    $oneDriveManifest = [IO.File]::ReadAllText($successResult.OneDriveManifestPath)
    Assert-True ($resultManifest.Contains('herdr-excel-job-result-v1', [StringComparison]::Ordinal)) 'Result manifest schema is missing.'
    Assert-True ($resultManifest.Contains('macros', [StringComparison]::Ordinal) -and $resultManifest.Contains('disabled', [StringComparison]::Ordinal)) 'Macro default deny is not recorded.'
    Assert-True (-not $resultManifest.Contains($secret, [StringComparison]::Ordinal)) 'Result manifest leaked workbook content.'
    Assert-True (-not $jobLog.Contains($secret, [StringComparison]::Ordinal)) 'Job log leaked workbook content.'
    Assert-True ($oneDriveManifest -ceq $resultManifest) 'The OneDrive Outbox manifest differs from the bridge manifest.'
    Assert-True ((Get-HerdrFileSnapshot -Path $success.Source).Sha256 -ceq $successResult.ResultSha256) 'The canonical source was not preserved.'
    Assert-True ($accessCalls.Count -ge 2) 'Host-owned ACL policy was not checked before execution.'
    $cliOutput = $successResult | ConvertTo-Json -Compress
    Assert-True (-not $cliOutput.Contains($secret, [StringComparison]::Ordinal)) 'Runner output leaked workbook content.'

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

    $noInteractive = New-TestJob
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $noInteractive.Job -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs `
            -ToolsRoot $tools -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
            -InteractiveSessionProbe { $false } `
            -HostOwnedAccessProbe $accessProbe -ExcelInvoker $excelProbe
    } 'interactive Windows session' 'interactive-session gate'

    $bridgeWrite = New-TestJob
    $bridgeProbe = { param([object[]]$Paths) throw 'bridge write probe failed' }
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $bridgeWrite.Job -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs `
            -ToolsRoot $tools -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
            -InteractiveSessionProbe $interactiveProbe `
            -HostOwnedAccessProbe $bridgeProbe -ExcelInvoker $excelProbe
    } 'bridge write probe failed' 'bridge ACL gate'

    $sourceMutation = New-TestJob
    $mutateSource = { [IO.File]::WriteAllBytes($sourceMutation.Source, [Text.Encoding]::UTF8.GetBytes('changed source')) }.GetNewClosure()
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $sourceMutation.Job -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs `
            -ToolsRoot $tools -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
            -InteractiveSessionProbe $interactiveProbe `
            -HostOwnedAccessProbe $accessProbe -ExcelInvoker $excelProbe -AfterExcelHook $mutateSource
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
        Assert-HerdrBridgeCannotWrite -Paths @($aclRoot) -AclReader $aclReader -GroupSidReader $groups
    } 'write access' 'ACL write deny'
    $safeAcl = [pscustomobject]@{ AreAccessRulesProtected = $true; Access = @($readRule) }
    $safeReader = { param([string]$Path) $safeAcl }.GetNewClosure()
    Assert-HerdrBridgeCannotWrite -Paths @($aclRoot) -AclReader $safeReader -GroupSidReader $groups | Out-Null

    $runnerText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\scripts\windows\HerdrExcelJobRunner.ps1')
    foreach ($required in @('AutomationSecurity = 3', 'AskToUpdateLinks = $false', 'EnableRefresh = $false', 'RefreshOnFileOpen = $false', 'SaveCopyAs', 'canonical_workbook_mutated')) {
        Assert-True ($runnerText.Contains($required, [StringComparison]::Ordinal)) "Excel canary marker is missing: $required"
    }
    foreach ($forbidden in @('RefreshAll', 'Invoke-Expression', 'Start-Process', 'TrustedLocation', 'RunAutoMacros')) {
        Assert-True (-not $runnerText.Contains($forbidden, [StringComparison]::Ordinal)) "Excel canary regression marker is present: $forbidden"
    }
    $outputTexts = @(Get-ChildItem -LiteralPath $exchange -File -Recurse -Filter '*.json' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) })
    foreach ($text in $outputTexts) {
        Assert-True (-not $text.Contains($secret, [StringComparison]::Ordinal)) 'Runner output or log leaked workbook content.'
    }
    Write-Host 'Herdr Excel job runner regression test passed.'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

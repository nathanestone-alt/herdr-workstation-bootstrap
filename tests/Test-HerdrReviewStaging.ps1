#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrReviewStaging.ps1')

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

$root = Join-Path ([IO.Path]::GetTempPath()) "herdr-staging-test-$([Guid]::NewGuid().ToString('N'))"
$oneDriveExchange = Join-Path $root 'onedrive\Herdr Review Exchange'
$inbox = Join-Path $oneDriveExchange 'Inbox'
$oneDriveOutbox = Join-Path $oneDriveExchange 'Outbox'
$oneDriveArchive = Join-Path $oneDriveExchange 'Archive'
$exchange = Join-Path $root 'exchange'
$reviewJobs = Join-Path $root 'review-jobs'
$tools = Join-Path $root 'tools'
$runtimeConfig = Join-Path $root 'runtime-config.json'
$source = Join-Path $inbox 'review.xlsx'
$secret = 'TEST-SECRET-MUST-NOT-LEAK'
$sourceBytes = [Text.Encoding]::UTF8.GetBytes("Workbook fixture $secret`n")
try {
    New-Item -ItemType Directory -Path $inbox, $oneDriveOutbox, $oneDriveArchive -Force | Out-Null
    New-Item -ItemType Directory -Path $exchange, $reviewJobs, $tools -Force | Out-Null
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
    $runtime = Get-HerdrRuntimeConfiguration -Path $runtimeConfig -TestMode
    Assert-True ($runtime.ExchangeRoot -ceq $exchange) 'Runtime configuration did not resolve the local exchange root.'
    Assert-True ($runtime.OneDriveInboxRoot -ceq $inbox) 'Runtime configuration did not derive the OneDrive Inbox root.'
    [IO.File]::WriteAllBytes($source, $sourceBytes)

    $result = Invoke-HerdrReviewStaging -SourcePath $source -JobId 'job-001' `
        -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -Repository 'STModel-Private' `
        -Branch 'codex/issue-961-bootstrap-reconcile' -Commit 'aa1f42580e4a3d98df8756f73d727d901cad90ea' `
        -StabilityIntervalMilliseconds 0
    Assert-True ($result.SourcePreserved) 'The Inbox source was not reported as preserved.'
    Assert-True (Test-Path -LiteralPath $result.StagedPath -PathType Leaf) 'The bridge staging copy is missing.'
    Assert-True (Test-Path -LiteralPath $result.ManifestPath -PathType Leaf) 'The staging provenance manifest is missing.'
    $sourceHash = (Get-HerdrFileSnapshot -Path $source).Sha256
    Assert-True ($sourceHash -ceq $result.SourceSha256) 'The source hash changed during staging.'
    $manifestText = [IO.File]::ReadAllText($result.ManifestPath)
    Assert-True (-not $manifestText.Contains($secret, [StringComparison]::Ordinal)) 'The staging manifest leaked workbook content.'
    Assert-True ((@(Get-HerdrWorkbookExtensionAllowlist) -join ',') -ceq '.xlsx,.xlsm,.xlsb') 'The workbook extension allowlist changed.'

    Assert-Throws {
        Invoke-HerdrReviewStaging -SourcePath $source -JobId 'job-001' -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -StabilityIntervalMilliseconds 0
    } 'collision' 'job collision'
    Assert-Throws {
        Invoke-HerdrReviewStaging -SourcePath $source -JobId '../escape' -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -StabilityIntervalMilliseconds 0
    } 'job ID is invalid' 'job ID traversal'
    $outside = Join-Path $root 'outside.xlsx'
    [IO.File]::WriteAllBytes($outside, $sourceBytes)
    Assert-Throws {
        Invoke-HerdrReviewStaging -SourcePath $outside -JobId 'job-outside' -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -StabilityIntervalMilliseconds 0
    } 'outside the configured OneDrive Inbox' 'source root escape'
    $unsupported = Join-Path $inbox 'unsupported.txt'
    [IO.File]::WriteAllText($unsupported, 'not a workbook')
    Assert-Throws {
        Invoke-HerdrReviewStaging -SourcePath $unsupported -JobId 'job-extension' -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -StabilityIntervalMilliseconds 0
    } 'not allowed' 'extension deny'

    $unstableSource = Join-Path $inbox 'unstable.xlsx'
    [IO.File]::WriteAllBytes($unstableSource, [Text.Encoding]::UTF8.GetBytes('stable-before'))
    Assert-Throws {
        Invoke-HerdrReviewStaging -SourcePath $unstableSource -JobId 'job-unstable' -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -StabilityIntervalMilliseconds 0 `
            -BetweenSourceReads { param([string]$Path) [IO.File]::WriteAllBytes($Path, [Text.Encoding]::UTF8.GetBytes('changed-after')) }
    } 'unstable' 'stability gate'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $exchange 'in\job-unstable'))) 'Unstable staging left a partial job directory.'

    $offlineBits = [int64]0x1000
    Assert-True ((Get-HerdrBlockedAttributeNames -Attributes $offlineBits) -contains 'Offline') 'Offline hydration flag is not blocked.'
    $recallBits = [int64]0x400000
    Assert-True ((Get-HerdrBlockedAttributeNames -Attributes $recallBits) -contains 'RecallOnDataAccess') 'Recall flag is not blocked.'

    $cliSource = Join-Path $inbox 'cli.xlsx'
    [IO.File]::WriteAllBytes($cliSource, $sourceBytes)
    $cliOutput = & (Join-Path $PSScriptRoot '..\scripts\windows\Stage-HerdrReviewWorkbook.ps1') `
        -SourcePath $cliSource -JobId 'job-cli' -RuntimeConfigurationPath $runtimeConfig -TestMode `
        -StabilityIntervalMilliseconds 0 2>&1 | Out-String
    Assert-True (-not $cliOutput.Contains($secret, [StringComparison]::Ordinal)) 'Staging stdout/stderr leaked workbook content.'
    $stagedFiles = @(Get-ChildItem -LiteralPath $exchange -File -Recurse -Filter '*.json' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) })
    foreach ($text in $stagedFiles) {
        Assert-True (-not $text.Contains($secret, [StringComparison]::Ordinal)) 'Staging metadata/log output leaked workbook content.'
    }
    Write-Host 'Herdr review staging regression test passed.'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

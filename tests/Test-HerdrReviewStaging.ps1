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

function Assert-HerdrExtensionMutationFailsFixture([string]$StagingSourcePath) {
    $mutationRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-staging-mutation-$([Guid]::NewGuid().ToString('N'))"
    $mutatedSourcePath = Join-Path $mutationRoot 'HerdrReviewStaging.mutated.ps1'
    $fixturePath = Join-Path $mutationRoot 'fixture.ps1'
    try {
        New-Item -ItemType Directory -Path $mutationRoot -Force | Out-Null
        $sourceText = [IO.File]::ReadAllText($StagingSourcePath)
        $guard = @'
        if ($extension -notin (Get-HerdrWorkbookExtensionAllowlist)) {
            throw "Workbook extension '$extension' is not allowed."
        }
'@
        $revertedGuard = @'
        if ($extension -notin (Get-HerdrWorkbookExtensionAllowlist)) {
            return $item
        }
'@
        if (-not $sourceText.Contains($guard, [StringComparison]::Ordinal)) {
            throw 'The extension guard mutation fixture no longer matches production source.'
        }
        [IO.File]::WriteAllText($mutatedSourcePath, $sourceText.Replace($guard, $revertedGuard), [Text.UTF8Encoding]::new($false))
        $fixture = @'
#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$MutatedScript)
$ErrorActionPreference = 'Stop'
. $MutatedScript
$root = Join-Path ([IO.Path]::GetTempPath()) "herdr-staging-mutation-fixture-$([Guid]::NewGuid().ToString('N'))"
$exchangeRoot = Join-Path $root 'onedrive\Herdr Review Exchange'
$inbox = Join-Path $exchangeRoot 'Inbox'
$outbox = Join-Path $exchangeRoot 'Outbox'
$archive = Join-Path $exchangeRoot 'Archive'
$localExchange = Join-Path $root 'exchange'
$source = Join-Path $inbox 'unsupported.txt'
try {
    New-Item -ItemType Directory -Path $inbox, $outbox, $archive, $localExchange -Force | Out-Null
    [IO.File]::WriteAllText($source, 'fixture')
    try {
        Invoke-HerdrReviewStaging -SourcePath $source -JobId 'mutation-fixture' -OneDriveExchangeRoot $exchangeRoot `
            -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $outbox -OneDriveArchiveRoot $archive `
            -ExchangeRoot $localExchange -StabilityIntervalMilliseconds 0 | Out-Null
        exit 1
    }
    catch {
        if (-not $_.Exception.Message.Contains('not allowed', [StringComparison]::OrdinalIgnoreCase)) { exit 2 }
        exit 0
    }
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
'@
        [IO.File]::WriteAllText($fixturePath, $fixture, [Text.UTF8Encoding]::new($false))
        & pwsh -NoLogo -NoProfile -File $fixturePath -MutatedScript $mutatedSourcePath
        if ($LASTEXITCODE -ne 1) {
            throw "The fixture did not fail after reverting the extension guard (exit $LASTEXITCODE)."
        }
    }
    finally {
        if (Test-Path -LiteralPath $mutationRoot) { Remove-Item -LiteralPath $mutationRoot -Recurse -Force }
    }
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
    $runtime = Get-HerdrRuntimeConfiguration -Path $runtimeConfig
    Assert-True ($runtime.ExchangeRoot -ceq $exchange) 'Runtime configuration did not resolve the local exchange root.'
    Assert-True ($runtime.OneDriveInboxRoot -ceq $inbox) 'Runtime configuration did not derive the OneDrive Inbox root.'
    Assert-True (Assert-HerdrAllowedReparsePoint -ReparseTag ([Convert]::ToUInt32('9000E01A', 16)) -IsDirectory:$false `
            -ComponentPath (Join-Path $inbox 'review.xlsx') -CandidatePath (Join-Path $inbox 'review.xlsx') `
            -AllowedCloudFilesRoot $oneDriveExchange) `
        'Cloud Files file acceptance beneath the configured exchange boundary failed.'
    Assert-Throws {
        Assert-HerdrAllowedReparsePoint -ReparseTag ([Convert]::ToUInt32('9000E01A', 16)) -IsDirectory:$false `
            -ComponentPath (Join-Path $inbox 'review.xlsx') -CandidatePath (Join-Path $inbox 'review.xlsx') | Out-Null
    } 'configured OneDrive exchange boundary' 'Cloud Files file no-boundary rejection'
    Assert-Throws {
        Assert-HerdrAllowedReparsePoint -ReparseTag ([Convert]::ToUInt32('9000E01A', 16)) -IsDirectory:$false `
            -ComponentPath (Join-Path $root 'outside.xlsx') -CandidatePath (Join-Path $root 'outside.xlsx') `
            -AllowedCloudFilesRoot $oneDriveExchange | Out-Null
    } 'outside the configured OneDrive exchange boundary' 'Cloud Files file boundary rejection'
    Assert-Throws {
        Assert-HerdrAllowedReparsePoint -ReparseTag ([Convert]::ToUInt32('9000001B', 16)) -IsDirectory:$false `
            -ComponentPath (Join-Path $inbox 'unknown.xlsx') -CandidatePath (Join-Path $inbox 'unknown.xlsx') `
            -AllowedCloudFilesRoot $oneDriveExchange | Out-Null
    } 'Refusing unrecognized reparse point on a non-directory' 'unrecognized file reparse rejection'
    [IO.File]::WriteAllBytes($source, $sourceBytes)

    $result = Invoke-HerdrReviewStaging -SourcePath $source -JobId 'job-001' `
        -OneDriveExchangeRoot $oneDriveExchange -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -Repository 'STModel-Private' `
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
        Invoke-HerdrReviewStaging -SourcePath $source -JobId 'job-001' -OneDriveExchangeRoot $oneDriveExchange `
            -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -StabilityIntervalMilliseconds 0
    } 'collision' 'job collision'
    Assert-Throws {
        Invoke-HerdrReviewStaging -SourcePath $source -JobId '../escape' -OneDriveExchangeRoot $oneDriveExchange `
            -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -StabilityIntervalMilliseconds 0
    } 'job ID is invalid' 'job ID traversal'
    Assert-Throws {
        Invoke-HerdrReviewStaging -SourcePath $source -JobId 'CON.xlsx' -OneDriveExchangeRoot $oneDriveExchange `
            -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -StabilityIntervalMilliseconds 0
    } 'reserved Windows device name' 'reserved device job ID'
    $outside = Join-Path $root 'outside.xlsx'
    [IO.File]::WriteAllBytes($outside, $sourceBytes)
    Assert-Throws {
        Invoke-HerdrReviewStaging -SourcePath $outside -JobId 'job-outside' -OneDriveExchangeRoot $oneDriveExchange `
            -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -StabilityIntervalMilliseconds 0
    } 'outside the configured OneDrive Inbox' 'source root escape'
    $unsupported = Join-Path $inbox 'unsupported.txt'
    [IO.File]::WriteAllText($unsupported, 'not a workbook')
    Assert-Throws {
        Invoke-HerdrReviewStaging -SourcePath $unsupported -JobId 'job-extension' -OneDriveExchangeRoot $oneDriveExchange `
            -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -StabilityIntervalMilliseconds 0
    } 'not allowed' 'extension deny'

    $unstableSource = Join-Path $inbox 'unstable.xlsx'
    [IO.File]::WriteAllBytes($unstableSource, [Text.Encoding]::UTF8.GetBytes('stable-before'))
    Assert-Throws {
        Invoke-HerdrReviewStaging -SourcePath $unstableSource -JobId 'job-unstable-no-test-mode' -OneDriveExchangeRoot $oneDriveExchange `
            -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -StabilityIntervalMilliseconds 0 `
            -BetweenSourceReads { param([string]$Path) }
    } 'Test probes are permitted only in explicit test mode' 'staging seam test-mode gate'
    Assert-Throws {
        Invoke-HerdrReviewStaging -SourcePath $unstableSource -JobId 'job-unstable' -OneDriveExchangeRoot $oneDriveExchange `
            -OneDriveInboxRoot $inbox -ExchangeRoot $exchange -StabilityIntervalMilliseconds 0 `
            -TestMode -BetweenSourceReads { param([string]$Path) [IO.File]::WriteAllBytes($Path, [Text.Encoding]::UTF8.GetBytes('changed-after')) }
    } 'unstable' 'stability gate'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $exchange 'in\job-unstable'))) 'Unstable staging left a partial job directory.'

    $fullyHydratedCloudFilesAttributes = [int64]0x420 # Archive | ReparsePoint
    $fullyHydratedCloudFilesTag = [uint32]([Convert]::ToUInt32('9000E01A', 16))
    $fullyHydratedCloudFilesBlocked = @(Get-HerdrBlockedAttributeNames -Attributes $fullyHydratedCloudFilesAttributes `
        -ReparseTag $fullyHydratedCloudFilesTag -ComponentPath $source -CandidatePath $source `
        -AllowedCloudFilesRoot $oneDriveExchange)
    Assert-True (-not ($fullyHydratedCloudFilesBlocked -contains 'ReparsePoint')) `
        'Fully hydrated Cloud Files attributes must not block ReparsePoint.'
    $cloudFilesNoBoundaryBlocked = @(Get-HerdrBlockedAttributeNames -Attributes $fullyHydratedCloudFilesAttributes `
        -ReparseTag $fullyHydratedCloudFilesTag -ComponentPath $source -CandidatePath $source)
    Assert-True ($cloudFilesNoBoundaryBlocked -contains 'ReparsePoint') `
        'Cloud Files ReparsePoint must remain blocked without an allowed boundary.'
    $cloudFilesOutsideBoundaryBlocked = @(Get-HerdrBlockedAttributeNames -Attributes $fullyHydratedCloudFilesAttributes `
        -ReparseTag $fullyHydratedCloudFilesTag -ComponentPath $source -CandidatePath $source `
        -AllowedCloudFilesRoot (Join-Path $root 'other-boundary'))
    Assert-True ($cloudFilesOutsideBoundaryBlocked -contains 'ReparsePoint') `
        'Cloud Files ReparsePoint must remain blocked outside the allowed boundary.'
    $unrecognizedCloudFilesBlocked = @(Get-HerdrBlockedAttributeNames -Attributes $fullyHydratedCloudFilesAttributes `
        -ReparseTag ([uint32]([Convert]::ToUInt32('9000001B', 16))) -ComponentPath $source -CandidatePath $source `
        -AllowedCloudFilesRoot $oneDriveExchange)
    Assert-True ($unrecognizedCloudFilesBlocked -contains 'ReparsePoint') `
        'Unrecognized reparse tags must remain blocked by the hydration filter.'
    foreach ($hydrationCase in @(
        [pscustomobject]@{ Name = 'Offline'; Bits = [int64]0x1000 },
        [pscustomobject]@{ Name = 'RecallOnOpen'; Bits = [int64]0x40000 },
        [pscustomobject]@{ Name = 'RecallOnDataAccess'; Bits = [int64]0x400000 }
    )) {
        $hydrationBlocked = @(Get-HerdrBlockedAttributeNames -Attributes ($fullyHydratedCloudFilesAttributes -bor $hydrationCase.Bits) `
            -ReparseTag $fullyHydratedCloudFilesTag -ComponentPath $source -CandidatePath $source `
            -AllowedCloudFilesRoot $oneDriveExchange)
        Assert-True ($hydrationBlocked -contains $hydrationCase.Name) `
            "$($hydrationCase.Name) must remain blocked for a Cloud Files leaf."
        Assert-True (-not ($hydrationBlocked -contains 'ReparsePoint')) `
            "$($hydrationCase.Name) must not restore the generic ReparsePoint hydration denial."
    }
    $offlineBits = [int64]0x1000
    Assert-True ((Get-HerdrBlockedAttributeNames -Attributes $offlineBits) -contains 'Offline') 'Offline hydration flag is not blocked.'
    $recallBits = [int64]0x400000
    Assert-True ((Get-HerdrBlockedAttributeNames -Attributes $recallBits) -contains 'RecallOnDataAccess') 'Recall flag is not blocked.'

    $stagePath = Join-Path $PSScriptRoot '..\scripts\windows\Stage-HerdrReviewWorkbook.ps1'
    $stageText = [IO.File]::ReadAllText($stagePath)
    $stagingSourceText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\scripts\windows\HerdrReviewStaging.ps1'))
    $runnerSourceText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\scripts\windows\HerdrExcelJobRunner.ps1'))
    Assert-True ($stagingSourceText.Contains('Get-HerdrPhysicalPathProof -Path $trustedRootCanonical -AllowedCloudFilesRoot $AllowedCloudFilesRoot', [StringComparison]::Ordinal)) `
        'Managed-directory trusted-root proof does not propagate the Cloud Files boundary.'
    Assert-True ($stagingSourceText.Contains('Open-HerdrNativeReadFile -Path $canonicalPath -AllowedCloudFilesRoot $AllowedCloudFilesRoot', [StringComparison]::Ordinal)) `
        'Snapshot native reads do not propagate the Cloud Files boundary.'
    Assert-True ($stagingSourceText.Contains('Open-HerdrNativeReadFile -Path $source -AllowedCloudFilesRoot $SourceAllowedCloudFilesRoot', [StringComparison]::Ordinal)) `
        'Copy native reads do not propagate the source Cloud Files boundary.'
    Assert-True ($runnerSourceText.Contains('Open-HerdrNativeReadFile -Path $Path -AllowedCloudFilesRoot $AllowedCloudFilesRoot', [StringComparison]::Ordinal)) `
        'Runner JSON native reads do not preserve explicit Cloud Files boundary plumbing.'
    Assert-True (-not $stageText.Contains('TestMode', [StringComparison]::Ordinal)) 'Production staging wrapper exposes a test-mode seam.'
    $identityIndex = $stageText.IndexOf('Assert-HerdrInteractiveIdentity', [StringComparison]::Ordinal)
    $bridgeIndex = $stageText.IndexOf('Assert-HerdrBridgeCannotWrite', [StringComparison]::Ordinal)
    $oneDriveIndex = $stageText.IndexOf('Assert-HerdrOneDriveReady', [StringComparison]::Ordinal)
    $stagingIndex = $stageText.IndexOf('Invoke-HerdrReviewStaging', [StringComparison]::Ordinal)
    Assert-True ($identityIndex -ge 0 -and $identityIndex -lt $bridgeIndex -and $bridgeIndex -lt $oneDriveIndex -and $oneDriveIndex -lt $stagingIndex) `
        'Production staging gates are not ordered before real staging.'
    $cliSource = Join-Path $inbox 'cli.xlsx'
    [IO.File]::WriteAllBytes($cliSource, $sourceBytes)
    Assert-Throws {
        & $stagePath -SourcePath $cliSource -JobId 'job-cli' -RuntimeConfigurationPath $runtimeConfig -TestMode `
            -StabilityIntervalMilliseconds 0
    } 'parameter' 'production staging test-mode bypass'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $exchange 'in\job-cli'))) `
        'Production staging reached the staging function after a rejected test-mode bypass.'
    Assert-HerdrExtensionMutationFailsFixture -StagingSourcePath (Join-Path $PSScriptRoot '..\scripts\windows\HerdrReviewStaging.ps1')
    Write-Host 'Herdr review staging regression test passed.'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RuntimeConfigurationPath,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$JobId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Repository,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Branch,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{7,64}$')][string]$Commit,
    [ValidateRange(0, 60000)][int]$StabilityIntervalMilliseconds = 1000
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\windows\HerdrExcelJobRunner.ps1')

function Assert-HerdrRoundtripEqual([string]$Name, [object]$Expected, [object]$Actual) {
    if ([string]$Expected -cne [string]$Actual) {
        throw "$Name mismatch."
    }
}

function Read-HerdrRoundtripJson([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description is missing: '$Path'."
    }
    return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

try {
    foreach ($value in @(
        [pscustomobject]@{ Name = 'Repository'; Value = $Repository },
        [pscustomobject]@{ Name = 'Branch'; Value = $Branch },
        [pscustomobject]@{ Name = 'Commit'; Value = $Commit }
    )) {
        if ($value.Value.Contains([char]10) -or $value.Value.Contains([char]13)) {
            throw "$($value.Name) contains a newline."
        }
    }

    $runtime = Get-HerdrRuntimeConfiguration -Path $RuntimeConfigurationPath
    $sourceCanonical = Get-HerdrCanonicalPath -Path $SourcePath
    if (-not (Test-HerdrPathSameOrDescendant -Candidate $sourceCanonical -Ancestor $runtime.OneDriveInboxRoot) -or
        $sourceCanonical.Equals($runtime.OneDriveInboxRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Roundtrip source must be inside the configured OneDrive Inbox: '$SourcePath'."
    }
    $sourceBefore = Assert-HerdrWorkbookFile -Path $sourceCanonical -AllowedCloudFilesRoot $runtime.OneDriveExchangeRoot
    $sourceHashBefore = (Get-FileHash -LiteralPath $sourceCanonical -Algorithm SHA256).Hash.ToLowerInvariant()

    $stageScript = Join-Path $PSScriptRoot '..\..\windows\Stage-HerdrReviewWorkbook.ps1'
    $runnerScript = Join-Path $PSScriptRoot '..\..\windows\Invoke-HerdrExcelJob.ps1'
    $stageOutput = (& $stageScript -SourcePath $sourceCanonical -JobId $JobId -RuntimeConfigurationPath $RuntimeConfigurationPath -Repository $Repository -Branch $Branch -Commit $Commit -StabilityIntervalMilliseconds $StabilityIntervalMilliseconds | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($stageOutput)) {
        throw 'The staging wrapper returned no result.'
    }
    $stage = $stageOutput | ConvertFrom-Json
    Assert-HerdrRoundtripEqual 'staging schema' 'herdr-review-staging-v1' $stage.Schema
    Assert-HerdrRoundtripEqual 'staging job id' $JobId $stage.JobId
    Assert-HerdrRoundtripEqual 'staging source preservation' $true $stage.SourcePreserved

    $stagingManifest = Read-HerdrRoundtripJson -Path $stage.ManifestPath -Description 'Staging provenance manifest'
    Assert-HerdrRoundtripEqual 'staging manifest schema' 'herdr-review-staging-v1' $stagingManifest.schema
    Assert-HerdrRoundtripEqual 'staging source hash and bridge-stage hash' $stagingManifest.source.sha256 $stagingManifest.bridge_stage.sha256
    Assert-HerdrRoundtripEqual 'staging repository provenance' $Repository $stagingManifest.provenance.repository
    Assert-HerdrRoundtripEqual 'staging branch provenance' $Branch $stagingManifest.provenance.branch
    Assert-HerdrRoundtripEqual 'staging commit provenance' $Commit $stagingManifest.provenance.commit
    Assert-HerdrRoundtripEqual 'staging source preserved flag' $true $stagingManifest.source_preserved
    Assert-HerdrRoundtripEqual 'source hash before staging' $sourceHashBefore $stagingManifest.source.sha256

    $jobPath = Join-Path (Split-Path -Parent $stage.ManifestPath) 'job.json'
    if (Test-Path -LiteralPath $jobPath -PathType Any) {
        throw "Refusing to overwrite an existing commissioning job: '$jobPath'."
    }
    $job = [ordered]@{
        schema = 'herdr-excel-job-v1'
        job_id = $JobId
        operation = 'recalculate'
        staging_manifest = $stage.ManifestPath
        source_repository = $Repository
        source_branch = $Branch
        source_commit = $Commit
    }
    [IO.File]::WriteAllText($jobPath, ($job | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))

    $runnerOutput = (& $runnerScript -JobPath $jobPath -RuntimeConfigurationPath $RuntimeConfigurationPath | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($runnerOutput)) {
        throw 'The Excel job wrapper returned no result.'
    }
    $runner = $runnerOutput | ConvertFrom-Json
    Assert-HerdrRoundtripEqual 'runner status' 'succeeded' $runner.Status
    Assert-HerdrRoundtripEqual 'runner job id' $JobId $runner.JobId

    $resultManifestText = Get-Content -Raw -LiteralPath $runner.ManifestPath
    $oneDriveManifestText = Get-Content -Raw -LiteralPath $runner.OneDriveManifestPath
    Assert-HerdrRoundtripEqual 'local and OneDrive provenance manifest bytes' $resultManifestText $oneDriveManifestText
    $resultManifest = $resultManifestText | ConvertFrom-Json
    Assert-HerdrRoundtripEqual 'result manifest schema' 'herdr-excel-job-result-v1' $resultManifest.schema
    Assert-HerdrRoundtripEqual 'result source hash' $stagingManifest.source.sha256 $resultManifest.source.sha256
    Assert-HerdrRoundtripEqual 'result staged hash' $stagingManifest.bridge_stage.sha256 $resultManifest.staged.sha256
    Assert-HerdrRoundtripEqual 'result repository provenance' $Repository $resultManifest.provenance.repository
    Assert-HerdrRoundtripEqual 'result branch provenance' $Branch $resultManifest.provenance.branch
    Assert-HerdrRoundtripEqual 'result commit provenance' $Commit $resultManifest.provenance.commit
    Assert-HerdrRoundtripEqual 'macro policy' 'disabled' $resultManifest.security.macros
    Assert-HerdrRoundtripEqual 'external-link policy' 'not-updated' $resultManifest.security.external_links
    Assert-HerdrRoundtripEqual 'data-connection policy' 'disabled' $resultManifest.security.data_connections
    Assert-HerdrRoundtripEqual 'trusted-location policy' 'none-added' $resultManifest.security.trusted_locations
    Assert-HerdrRoundtripEqual 'canonical workbook mutation policy' $false $resultManifest.security.canonical_workbook_mutated

    $outboxResultHash = (Get-FileHash -LiteralPath $runner.OneDriveResultPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-HerdrRoundtripEqual 'OneDrive Outbox result hash' $resultManifest.result.one_drive_outbox_sha256 $outboxResultHash
    Assert-HerdrRoundtripEqual 'runner result hash' $runner.ResultSha256 $resultManifest.result.sha256
    $sourceHashAfter = (Get-FileHash -LiteralPath $sourceCanonical -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-HerdrRoundtripEqual 'preserved Inbox source hash' $sourceHashBefore $sourceHashAfter

    [pscustomobject][ordered]@{
        schema = 'herdr-review-commissioning-roundtrip-v1'
        status = 'PASS'
        job_id = $JobId
        source_path = $sourceCanonical
        source_preserved = $true
        staging_manifest = $stage.ManifestPath
        job_path = $jobPath
        protected_result_path = $runner.ResultPath
        outbox_result_path = $runner.OneDriveResultPath
        local_provenance_manifest = $runner.ManifestPath
        onedrive_provenance_manifest = $runner.OneDriveManifestPath
        source_sha256 = $sourceHashBefore
        outbox_result_sha256 = $outboxResultHash
        provenance = [ordered]@{
            repository = $Repository
            branch = $Branch
            commit = $Commit
        }
        checks = @(
            'Inbox source preserved with unchanged SHA-256',
            'bridge staging hash equals Inbox hash',
            'protected Excel review-job copy completed',
            'local and OneDrive Outbox provenance manifests are byte-identical',
            'OneDrive Outbox result hash equals manifest hash',
            'Excel default-deny security fields are present'
        )
    } | ConvertTo-Json -Depth 10 -Compress
}
catch {
    Write-Error "HERDR_REVIEW_ROUNDTRIP_FAILED: $($_.Exception.Message)"
    exit 1
}

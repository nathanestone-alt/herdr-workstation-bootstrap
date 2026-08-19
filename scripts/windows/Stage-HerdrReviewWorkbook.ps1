#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$JobId,
    [string]$OneDriveInboxRoot,
    [string]$OneDriveOutboxRoot,
    [string]$OneDriveArchiveRoot,
    [string]$ExchangeRoot = 'C:\HerdrExchange',
    [string]$Repository = 'NOT-PROVIDED',
    [string]$Branch = 'NOT-PROVIDED',
    [string]$Commit = 'NOT-PROVIDED',
    [ValidateRange(0, 60000)][int]$StabilityIntervalMilliseconds = 1000
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HerdrReviewStaging.ps1')
if ([string]::IsNullOrWhiteSpace($OneDriveInboxRoot)) {
    $OneDriveInboxRoot = Get-HerdrDefaultOneDriveInboxRoot
}

try {
    $result = Invoke-HerdrReviewStaging -SourcePath $SourcePath -JobId $JobId `
        -OneDriveInboxRoot $OneDriveInboxRoot -OneDriveOutboxRoot $OneDriveOutboxRoot `
        -OneDriveArchiveRoot $OneDriveArchiveRoot -ExchangeRoot $ExchangeRoot `
        -Repository $Repository -Branch $Branch -Commit $Commit `
        -StabilityIntervalMilliseconds $StabilityIntervalMilliseconds
    $result | ConvertTo-Json -Depth 5 -Compress
}
catch {
    Write-Error 'HERDR_STAGING_FAILED: the workbook was not staged.'
    exit 1
}

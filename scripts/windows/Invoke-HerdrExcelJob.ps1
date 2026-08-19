#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JobPath,
    [string]$ExchangeRoot = 'C:\HerdrExchange',
    [string]$ReviewJobsRoot = 'C:\HerdrReviewJobs',
    [string]$ToolsRoot = 'C:\HerdrTools',
    [string]$OneDriveInboxRoot,
    [string]$OneDriveOutboxRoot,
    [string]$OneDriveArchiveRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HerdrExcelJobRunner.ps1')
if ([string]::IsNullOrWhiteSpace($OneDriveInboxRoot)) {
    $OneDriveInboxRoot = Get-HerdrDefaultOneDriveInboxRoot
}

try {
    $result = Invoke-HerdrExcelJob -JobPath $JobPath -ExchangeRoot $ExchangeRoot `
        -ReviewJobsRoot $ReviewJobsRoot -ToolsRoot $ToolsRoot `
        -OneDriveInboxRoot $OneDriveInboxRoot -OneDriveOutboxRoot $OneDriveOutboxRoot `
        -OneDriveArchiveRoot $OneDriveArchiveRoot
    $result | ConvertTo-Json -Depth 5 -Compress
}
catch {
    Write-Error 'HERDR_EXCEL_JOB_FAILED: the job was rejected or did not complete.'
    exit 1
}

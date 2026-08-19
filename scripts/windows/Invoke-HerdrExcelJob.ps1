#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$JobPath,
    [string]$RuntimeConfigurationPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HerdrExcelJobRunner.ps1')

try {
    $result = Invoke-HerdrExcelJob -JobPath $JobPath -RuntimeConfigurationPath $RuntimeConfigurationPath
    $result | ConvertTo-Json -Depth 5 -Compress
}
catch {
    Write-Error 'HERDR_EXCEL_JOB_FAILED: the job was rejected or did not complete.'
    exit 1
}

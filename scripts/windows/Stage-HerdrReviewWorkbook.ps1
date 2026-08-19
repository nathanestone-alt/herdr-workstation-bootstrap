#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$JobId,
    [string]$RuntimeConfigurationPath,
    [string]$Repository = 'NOT-PROVIDED',
    [string]$Branch = 'NOT-PROVIDED',
    [string]$Commit = 'NOT-PROVIDED',
    [ValidateRange(0, 60000)][int]$StabilityIntervalMilliseconds = 1000,
    [switch]$TestMode
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HerdrExcelJobRunner.ps1')

try {
    $runtimeConfiguration = Get-HerdrRuntimeConfiguration -Path $RuntimeConfigurationPath -TestMode:$TestMode
    if (-not $TestMode) {
        $identityConfiguration = Get-HerdrIdentityConfiguration `
            -ExpectedInteractiveUserSid $runtimeConfiguration.DesignatedInteractiveUserSid `
            -ExpectedInteractiveSessionId $runtimeConfiguration.DesignatedInteractiveSessionId `
            -ExpectedBridgeAccountSid $runtimeConfiguration.BridgeAccountSid
        Assert-HerdrInteractiveIdentity -Configuration $identityConfiguration | Out-Null
        Assert-HerdrBridgeCannotWrite -Paths @($runtimeConfiguration.ConfigurationPath) `
            -ExpectedBridgeAccountSid $identityConfiguration.BridgeAccountSid | Out-Null
        Assert-HerdrOneDriveReady -OneDriveExchangeRoot $runtimeConfiguration.OneDriveExchangeRoot `
            -OneDriveAccount $runtimeConfiguration.OneDriveAccount -IdentityConfiguration $identityConfiguration | Out-Null
    }
    $result = Invoke-HerdrReviewStaging -SourcePath $SourcePath -JobId $JobId `
        -OneDriveInboxRoot $runtimeConfiguration.OneDriveInboxRoot -OneDriveOutboxRoot $runtimeConfiguration.OneDriveOutboxRoot `
        -OneDriveArchiveRoot $runtimeConfiguration.OneDriveArchiveRoot -ExchangeRoot $runtimeConfiguration.ExchangeRoot `
        -Repository $Repository -Branch $Branch -Commit $Commit `
        -StabilityIntervalMilliseconds $StabilityIntervalMilliseconds
    $result | ConvertTo-Json -Depth 5 -Compress
}
catch {
    Write-Error 'HERDR_STAGING_FAILED: the workbook was not staged.'
    exit 1
}

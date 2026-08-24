#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RuntimeConfigurationPath,
    [string]$WorkbookPath,
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\windows\HerdrExcelJobRunner.ps1')

function Get-HerdrHydrationBlockedAttributes([object]$Attributes) {
    $value = [int64]$Attributes
    $blocked = [System.Collections.Generic.List[string]]::new()
    if (($value -band [int64]0x1000) -ne 0) {
        [void]$blocked.Add('Offline')
    }
    if (($value -band [int64]0x40000) -ne 0) {
        [void]$blocked.Add('RecallOnOpen')
    }
    if (($value -band [int64]0x400000) -ne 0) {
        [void]$blocked.Add('RecallOnDataAccess')
    }
    return @($blocked)
}

function Get-HerdrHydratedDirectoryRecord([string]$Name, [string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        throw "$Name is not a directory: '$Path'."
    }
    $blocked = @(Get-HerdrHydrationBlockedAttributes -Attributes $item.Attributes)
    if ($blocked.Count -gt 0) {
        throw "$Name is not hydrated for offline use; blocked attributes: $($blocked -join ', ')."
    }
    $attributes = [int64]$item.Attributes
    return [pscustomobject][ordered]@{
        name = $Name
        path = [IO.Path]::GetFullPath($Path)
        attributes = [string]$item.Attributes
        reparse_point = (($attributes -band [int64][IO.FileAttributes]::ReparsePoint) -ne 0)
        always_keep_on_device = $true
    }
}

try {
    $runtime = Get-HerdrRuntimeConfiguration -Path $RuntimeConfigurationPath
    $identity = Get-HerdrIdentityConfiguration -ExpectedInteractiveUserSid $runtime.DesignatedInteractiveUserSid -ExpectedInteractiveSessionId $runtime.DesignatedInteractiveSessionId -ExpectedBridgeAccountSid $runtime.BridgeAccountSid
    Assert-HerdrInteractiveIdentity -Configuration $identity | Out-Null
    Assert-HerdrOneDriveReady -OneDriveExchangeRoot $runtime.OneDriveExchangeRoot -OneDriveAccount $runtime.OneDriveAccount -IdentityConfiguration $identity | Out-Null

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($directory in @(
        [pscustomobject]@{ Name = 'OneDrive exchange'; Path = $runtime.OneDriveExchangeRoot },
        [pscustomobject]@{ Name = 'OneDrive Inbox'; Path = $runtime.OneDriveInboxRoot },
        [pscustomobject]@{ Name = 'OneDrive Outbox'; Path = $runtime.OneDriveOutboxRoot },
        [pscustomobject]@{ Name = 'OneDrive Archive'; Path = $runtime.OneDriveArchiveRoot }
    )) {
        [void]$records.Add((Get-HerdrHydratedDirectoryRecord -Name $directory.Name -Path $directory.Path))
    }

    $workbookRecord = $null
    if (-not [string]::IsNullOrWhiteSpace($WorkbookPath)) {
        $workbookCanonical = Get-HerdrCanonicalPath -Path $WorkbookPath
        if (-not (Test-HerdrPathSameOrDescendant -Candidate $workbookCanonical -Ancestor $runtime.OneDriveInboxRoot) -or
            $workbookCanonical.Equals($runtime.OneDriveInboxRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Workbook hydration probe must be inside the configured OneDrive Inbox: '$WorkbookPath'."
        }
        $workbook = Assert-HerdrWorkbookFile -Path $workbookCanonical -AllowedCloudFilesRoot $runtime.OneDriveExchangeRoot
        $workbookRecord = [pscustomobject][ordered]@{
            name = 'commissioning workbook'
            path = $workbookCanonical
            extension = [IO.Path]::GetExtension($workbook.Name).ToLowerInvariant()
            size_bytes = $workbook.Length
            attributes = [string]$workbook.Attributes
            always_keep_on_device = $true
            sha256 = (Get-FileHash -LiteralPath $workbookCanonical -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }

    $result = [pscustomobject][ordered]@{
        schema = 'herdr-onedrive-hydration-v1'
        status = 'PASS'
        account = $runtime.OneDriveAccount
        directories = @($records)
        workbook = $workbookRecord
        manual_confirmation = 'Explorer Always keep on this device was verified by blocked-attribute absence.'
    }
    $json = $result | ConvertTo-Json -Depth 8 -Compress
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        $evidenceParent = Split-Path -Parent ([IO.Path]::GetFullPath($EvidencePath))
        if (-not (Test-Path -LiteralPath $evidenceParent -PathType Container)) {
            throw "Hydration evidence parent does not exist: '$evidenceParent'."
        }
        if (Test-Path -LiteralPath $EvidencePath -PathType Any) {
            throw "Refusing to overwrite hydration evidence: '$EvidencePath'."
        }
        [IO.File]::WriteAllText($EvidencePath, $json, [Text.UTF8Encoding]::new($false))
    }
    $json
}
catch {
    Write-Error "HERDR_ONEDRIVE_HYDRATION_FAILED: $($_.Exception.Message)"
    exit 1
}

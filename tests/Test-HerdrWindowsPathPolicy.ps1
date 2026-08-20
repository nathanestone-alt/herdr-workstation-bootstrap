#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$CloudFilesExchangeRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrReviewStaging.ps1')

if (-not $IsWindows) {
    Write-Host 'SKIP: Windows native path-policy checks require Windows.'
    exit 0
}

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

function ConvertTo-TestReparseTag([string]$Hex) {
    return [Convert]::ToUInt32($Hex, 16)
}

Assert-True ((ConvertTo-HerdrFinalPath -Path '\\?\C:\') -ceq 'C:\') `
    'A valid local extended-length root was not normalized to its drive-root path.'
Assert-True ((ConvertTo-HerdrFinalPath -Path '\\?\C:\Windows') -ceq 'C:\Windows') `
    'A valid local extended-length path was not normalized to its local path.'
Assert-Throws { ConvertTo-HerdrFinalPath -Path '\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1' } 'non-local extended-length' `
    'extended device path admission'
Assert-Throws { Get-HerdrCanonicalPath -Path '\\?\C:\Windows' } 'Device namespace' 'extended device path'
Assert-Throws { Get-HerdrCanonicalPath -Path '\\.\C:\Windows' } 'Device namespace' 'Win32 device path'
Assert-Throws { Get-HerdrCanonicalPath -Path '\??\C:\Windows' } 'Device namespace' 'NT device path'
Assert-Throws { Get-HerdrCanonicalPath -Path '\\server\share\folder' } 'UNC' 'UNC path'

$syntheticBoundary = 'C:\Users\natha\OneDrive\Herdr Review Exchange'
$syntheticComponent = 'C:\Users\natha\OneDrive'
$syntheticCandidate = Join-Path $syntheticBoundary 'Inbox'
Assert-True (Test-HerdrCloudFilesReparseTag -ReparseTag (ConvertTo-TestReparseTag '9000E01A')) `
    'The commissioned Cloud Files tag variant was not recognized.'
Assert-True (Assert-HerdrAllowedReparsePoint -ReparseTag (ConvertTo-TestReparseTag '9000E01A') -IsDirectory:$true `
        -ComponentPath $syntheticComponent -CandidatePath $syntheticCandidate -AllowedCloudFilesRoot $syntheticBoundary) `
    'The accepted Cloud Files directory case was not allowed beneath its configured boundary.'
Assert-True (Assert-HerdrAllowedReparsePoint -ReparseTag (ConvertTo-TestReparseTag '9000E01A') -IsDirectory:$false `
        -ComponentPath (Join-Path $syntheticCandidate 'workbook.xlsx') `
        -CandidatePath (Join-Path $syntheticCandidate 'workbook.xlsx') -AllowedCloudFilesRoot $syntheticBoundary) `
    'Cloud Files file acceptance beneath its configured boundary failed.'
foreach ($tagCase in @(
    [pscustomobject]@{ Name = 'symbolic link'; Tag = ConvertTo-TestReparseTag 'A000000C'; DirectoryExpected = 'Refusing symbolic-link reparse point with tag'; FileExpected = 'Refusing symbolic-link reparse point on a non-directory' },
    [pscustomobject]@{ Name = 'junction'; Tag = ConvertTo-TestReparseTag 'A0000003'; DirectoryExpected = 'Refusing junction or mount-point reparse point with tag'; FileExpected = 'Refusing junction or mount-point reparse point on a non-directory' },
    [pscustomobject]@{ Name = 'mount point'; Tag = ConvertTo-TestReparseTag 'A0000003'; DirectoryExpected = 'Refusing junction or mount-point reparse point with tag'; FileExpected = 'Refusing junction or mount-point reparse point on a non-directory' },
    [pscustomobject]@{ Name = 'unrecognized reparse tag'; Tag = ConvertTo-TestReparseTag '9000001B'; DirectoryExpected = 'Refusing unrecognized reparse point with tag'; FileExpected = 'Refusing unrecognized reparse point on a non-directory' }
)) {
    Assert-Throws {
        Assert-HerdrAllowedReparsePoint -ReparseTag $tagCase.Tag -IsDirectory:$true `
            -ComponentPath $syntheticComponent -CandidatePath $syntheticCandidate `
            -AllowedCloudFilesRoot $syntheticBoundary | Out-Null
    } $tagCase.DirectoryExpected "$($tagCase.Name) rejection"
    Assert-Throws {
        Assert-HerdrAllowedReparsePoint -ReparseTag $tagCase.Tag -IsDirectory:$false `
            -ComponentPath (Join-Path $syntheticCandidate 'workbook.xlsx') `
            -CandidatePath (Join-Path $syntheticCandidate 'workbook.xlsx') `
            -AllowedCloudFilesRoot $syntheticBoundary | Out-Null
    } $tagCase.FileExpected "$($tagCase.Name) file rejection"
}
Assert-Throws {
    Assert-HerdrAllowedReparsePoint -ReparseTag (ConvertTo-TestReparseTag '9000E01A') -IsDirectory:$false `
        -ComponentPath 'C:\Users\natha\OneDrive\Other\workbook.xlsx' -CandidatePath 'C:\Users\natha\OneDrive\Other\workbook.xlsx' `
        -AllowedCloudFilesRoot $syntheticBoundary | Out-Null
} 'Cloud Files reparse point outside' 'Cloud Files file boundary rejection'
Assert-Throws {
    Assert-HerdrAllowedReparsePoint -ReparseTag (ConvertTo-TestReparseTag '9000E01A') -IsDirectory:$true `
        -ComponentPath $syntheticComponent -CandidatePath 'C:\Users\natha\OneDrive\Other' `
        -AllowedCloudFilesRoot $syntheticBoundary | Out-Null
} 'outside the configured' 'Cloud Files boundary escape'
Assert-Throws {
    Assert-HerdrAllowedReparsePoint -ReparseTag (ConvertTo-TestReparseTag '9000E01A') -IsDirectory:$false `
        -ComponentPath (Join-Path $syntheticCandidate 'workbook.xlsx') `
        -CandidatePath (Join-Path $syntheticCandidate 'workbook.xlsx') | Out-Null
} 'configured OneDrive exchange boundary' 'Cloud Files file no-boundary rejection'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-path-policy-$([Guid]::NewGuid().ToString('N'))"
$junctionTarget = Join-Path $fixtureRoot 'target'
$junctionPath = Join-Path $fixtureRoot 'junction'
try {
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    Assert-Throws { Get-HerdrPhysicalPathProof -Path $junctionPath | Out-Null } 'junction or mount-point' 'native junction fixture'
}
finally {
    if (Test-Path -LiteralPath $junctionPath) { Remove-Item -LiteralPath $junctionPath -Force }
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}

if (-not [string]::IsNullOrWhiteSpace($CloudFilesExchangeRoot)) {
    $exchangeRoot = Get-HerdrCanonicalPath -Path $CloudFilesExchangeRoot
    foreach ($directory in @(
        $exchangeRoot,
        (Join-Path $exchangeRoot 'Inbox'),
        (Join-Path $exchangeRoot 'Outbox'),
        (Join-Path $exchangeRoot 'Archive')
    )) {
        $proof = Get-HerdrPhysicalPathProof -Path $directory -AllowedCloudFilesRoot $exchangeRoot
        Assert-True ($proof.Exists -and $proof.Leaf.IsDirectory) "Cloud Files directory proof failed: '$directory'."
        Assert-True ([uint32]$proof.Leaf.ReparseTag -ne 0) "Cloud Files reparse tag was not captured: '$directory'."
        Assert-True (Test-HerdrCloudFilesReparseTag -ReparseTag ([uint32]$proof.Leaf.ReparseTag)) `
            "Unexpected reparse tag on commissioned Cloud Files directory: '$directory'."
        Assert-True ($proof.FinalPath -match '^[A-Za-z]:\\') "Final handle path was not local: '$directory'."
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$proof.Leaf.FileIdentity)) `
            "File identity was not captured: '$directory'."
        Assert-HerdrPhysicalPathUnderRoot -CandidatePath $directory -RootPath $exchangeRoot `
            -AllowEqual:($directory.Equals($exchangeRoot, [StringComparison]::OrdinalIgnoreCase)) `
            -AllowedCloudFilesRoot $exchangeRoot -Description "Cloud Files containment '$directory'" | Out-Null
    }
}

Write-Host 'Herdr Windows path-policy correction regression test passed.'

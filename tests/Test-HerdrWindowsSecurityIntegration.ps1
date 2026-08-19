#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    Write-Host 'SKIP: Windows handle, ACL, process-identity, and Excel COM integration fixtures require Windows.'
    exit 0
}

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
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
}

function New-IntegrationFixture {
    param(
        [Parameter(Mandatory)][string]$Inbox,
        [Parameter(Mandatory)][string]$OneDriveOutbox,
        [Parameter(Mandatory)][string]$OneDriveArchive,
        [Parameter(Mandatory)][string]$Exchange,
        [Parameter(Mandatory)][string]$ReviewJobs,
        [Parameter(Mandatory)][string]$Tools,
        [Parameter(Mandatory)][int]$Number
    )

    $source = Join-Path $Inbox "fixture-$Number.xlsx"
    [IO.File]::WriteAllBytes($source, [Text.Encoding]::UTF8.GetBytes("fixture-$Number"))
    $staged = Invoke-HerdrReviewStaging -SourcePath $source -JobId "windows-$Number" `
        -OneDriveInboxRoot $Inbox -OneDriveOutboxRoot $OneDriveOutbox -OneDriveArchiveRoot $OneDriveArchive `
        -ExchangeRoot $Exchange -Repository 'STModel-Private' -Branch 'security-test' -Commit 'fixture' `
        -StabilityIntervalMilliseconds 0
    $jobPath = Join-Path (Split-Path -Parent $staged.ManifestPath) 'job.json'
    Write-TestJson -Path $jobPath -Value ([ordered]@{
        schema = 'herdr-excel-job-v1'
        job_id = "windows-$Number"
        operation = 'recalculate'
        staging_manifest = $staged.ManifestPath
        source_repository = 'STModel-Private'
        source_branch = 'security-test'
        source_commit = 'fixture'
    })
    [pscustomobject]@{ Source = $source; Staged = $staged; Job = $jobPath }
}

function Invoke-HerdrDisposableExcelCanary {
    if ($env:HERDR_RUN_EXCEL_CANARY -ne '1') {
        Write-Host 'SKIP: set HERDR_RUN_EXCEL_CANARY=1 on HERDR-WIN to run the disposable real-Excel canary.'
        return
    }
    $configuration = Get-HerdrIdentityConfiguration
    $canaryRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-excel-canary-$([Guid]::NewGuid().ToString('N'))"
    $source = Join-Path $canaryRoot 'canary.xlsm'
    $external = Join-Path $canaryRoot 'external.txt'
    $result = Join-Path $canaryRoot 'result.xlsm'
    New-Item -ItemType Directory -Path $canaryRoot -Force | Out-Null
    [IO.File]::WriteAllText($external, 'EXTERNAL_CANARY_DATA', [Text.UTF8Encoding]::new($false))
    $excel = $null
    $book = $null
    $verifyExcel = $null
    $verifyBook = $null
    $beforeExcelCount = @(Get-Process -Name EXCEL -ErrorAction SilentlyContinue).Count
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $book = $excel.Workbooks.Add()
        $sheet = $book.Worksheets.Item(1)
        $sheet.Range('A1').Value2 = 'HERDR_CANARY'
        $sheet.Range('A2').Formula = "='[external.xlsx]Sheet1'!`$A`$1"
        $query = $sheet.QueryTables.Add("TEXT;$external", $sheet.Range('A3'))
        $query.RefreshOnFileOpen = $false
        $query.BackgroundQuery = $false
        $module = $book.VBProject.VBComponents.Add(1)
        $macro = "Sub Auto_Open()`nThisWorkbook.Worksheets(1).Range(`"B1`").Value2 = `"MACRO_RAN`"`nEnd Sub"
        $module.CodeModule.AddFromString($macro)
        $book.SaveAs($source, 52)
        $book.Close($false)
        $book = $null
        $excel.Quit()
        $excel = $null

        $beforeHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        Invoke-HerdrExcelRecalculate -InputPath $source -ResultPath $result -IdentityConfiguration $configuration
        $afterHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        Assert-True ($beforeHash -ceq $afterHash) 'Disposable canary changed the canonical source workbook.'
        Assert-True (Test-Path -LiteralPath $result -PathType Leaf) 'Disposable Excel canary did not produce a result.'

        $verifyExcel = New-Object -ComObject Excel.Application
        $verifyExcel.Visible = $false
        $verifyExcel.DisplayAlerts = $false
        $verifyBook = $verifyExcel.Workbooks.Open($result, 0, $true)
        try {
            Assert-True ([string]$verifyBook.Worksheets.Item(1).Range('B1').Value2 -ne 'MACRO_RAN') 'Macro canary executed.'
            Assert-True ([string]$verifyBook.Worksheets.Item(1).Range('A3').Value2 -ne 'EXTERNAL_CANARY_DATA') 'Data-connection canary refreshed.'
        }
        finally {
            if ($null -ne $verifyBook) { try { $verifyBook.Close($false) } catch {} }
            if ($null -ne $verifyExcel) { try { $verifyExcel.Quit() } catch {} }
            $verifyBook = $null
            $verifyExcel = $null
        }
        Assert-True (@(Get-Process -Name EXCEL -ErrorAction SilentlyContinue).Count -le $beforeExcelCount) 'Excel canary leaked an Excel process.'
        Write-Host 'Disposable real-Excel security canary passed.'
    }
    finally {
        if ($null -ne $book) { try { $book.Close($false) } catch {} }
        if ($null -ne $excel) { try { $excel.Quit() } catch {} }
        if ($null -ne $verifyBook) { try { $verifyBook.Close($false) } catch {} }
        if ($null -ne $verifyExcel) { try { $verifyExcel.Quit() } catch {} }
        if (Test-Path -LiteralPath $canaryRoot) { Remove-Item -LiteralPath $canaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) "herdr-windows-security-$([Guid]::NewGuid().ToString('N'))"
$inbox = Join-Path $root 'onedrive\Herdr Review Exchange\Inbox'
$oneDriveOutbox = Join-Path $root 'onedrive\Herdr Review Exchange\Outbox'
$oneDriveArchive = Join-Path $root 'onedrive\Herdr Review Exchange\Archive'
$exchange = Join-Path $root 'exchange'
$reviewJobs = Join-Path $root 'review-jobs'
$tools = Join-Path $root 'tools'
try {
    New-Item -ItemType Directory -Path $inbox, $oneDriveOutbox, $oneDriveArchive, $exchange, $reviewJobs, $tools -Force | Out-Null

    $outside = Join-Path $root 'outside'
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $outside 'escaped.xlsx'), [Text.Encoding]::UTF8.GetBytes('outside'))
    $nested = Join-Path $inbox 'nested'
    New-Item -ItemType Junction -Path $nested -Target $outside | Out-Null
    Assert-Throws { Get-HerdrPhysicalPathProof -Path (Join-Path $nested 'escaped.xlsx') } 'reparse point' 'nested reparse boundary'
    Assert-Throws { Ensure-HerdrManagedDirectory -Path (Join-Path $nested 'new') -TrustedRoot $inbox } 'reparse point' 'directory identity swap'

    $hardSource = Join-Path $inbox 'hard-source.xlsx'
    [IO.File]::WriteAllBytes($hardSource, [Text.Encoding]::UTF8.GetBytes('hard-link'))
    $hardLink = Join-Path $inbox 'hard-link.xlsx'
    New-Item -ItemType HardLink -Path $hardLink -Target $hardSource | Out-Null
    Assert-Throws { Get-HerdrFileSnapshot -Path $hardLink } 'multiple hard links' 'hard-link source boundary'

    $safeDestinationRoot = Join-Path $root 'safe-destination'
    New-Item -ItemType Directory -Path $safeDestinationRoot -Force | Out-Null
    $unsafeCopyDestination = Join-Path $outside 'unsafe-copy.xlsx'
    Assert-Throws {
        Copy-HerdrFileExclusive -SourcePath $hardSource -DestinationPath $unsafeCopyDestination `
            -TrustedDestinationRoot $safeDestinationRoot
    } 'outside the trusted physical root' 'destination directory boundary'
    Assert-Throws {
        Write-HerdrAtomicText -Path (Join-Path $outside 'unsafe-output.json') -Content '{}' -TrustedRoot $safeDestinationRoot
    } 'outside the trusted physical root' 'atomic output boundary'

    $identityConfiguration = [pscustomobject]@{
        InteractiveUserSid = 'S-1-5-21-961-user'
        InteractiveSessionId = 7
        BridgeAccountSid = 'S-1-5-21-961-bridge'
    }
    Assert-Throws {
        Assert-HerdrInteractiveIdentity -Configuration $identityConfiguration -TestMode -IdentityProbe {
            [pscustomobject]@{ CurrentUserSid = 'S-1-5-21-961-user'; CurrentSessionId = 8; ExplorerUserSid = 'S-1-5-21-961-user'; ExplorerSessionId = 8 }
        }
    } 'session proof mismatch' 'wrong interactive session'

    $aclRoot = Join-Path $root 'acl'
    New-Item -ItemType Directory -Path $aclRoot -Force | Out-Null
    $nestedWrite = [pscustomobject]@{
        IdentityReference = 'S-1-5-21-961-nested-group'
        AccessControlType = [Security.AccessControl.AccessControlType]::Allow
        FileSystemRights = [Security.AccessControl.FileSystemRights]::Modify
    }
    $acl = [pscustomobject]@{ AreAccessRulesProtected = $true; Access = @($nestedWrite) }
    $aclReader = { param([string]$Path) $acl }.GetNewClosure()
    $nestedGroupReader = { param([string]$Account) @('S-1-5-21-961-nested-group') }
    $identityGroupReader = { param([string]$Account) @('S-1-5-21-961-bridge') }
    $substituteIdentityProbe = { 'S-1-5-21-961-substitute' }
    Assert-Throws {
        Assert-HerdrBridgeCannotWrite -Paths @($aclRoot) -ExpectedBridgeAccountSid $identityConfiguration.BridgeAccountSid `
            -AclReader $aclReader `
            -GroupSidReader $nestedGroupReader -TestMode
    } 'write access' 'nested-group write grant'
    Assert-Throws {
        Assert-HerdrBridgeCannotWrite -Paths @($aclRoot) -ExpectedBridgeAccountSid $identityConfiguration.BridgeAccountSid `
            -AclReader $aclReader `
            -GroupSidReader $identityGroupReader `
            -BridgeIdentityProbe $substituteIdentityProbe -TestMode
    } 'identity substitution' 'bridge identity substitution'

    $fixture = New-IntegrationFixture -Inbox $inbox -OneDriveOutbox $oneDriveOutbox -OneDriveArchive $oneDriveArchive `
        -Exchange $exchange -ReviewJobs $reviewJobs -Tools $tools -Number 1
    $sourceTamper = New-IntegrationFixture -Inbox $inbox -OneDriveOutbox $oneDriveOutbox -OneDriveArchive $oneDriveArchive `
        -Exchange $exchange -ReviewJobs $reviewJobs -Tools $tools -Number 2
    [IO.File]::WriteAllText($sourceTamper.Source, 'source-tampered')
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $sourceTamper.Job -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs -ToolsRoot $tools `
            -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
            -TestMode -InteractiveSessionProbe { $true } -HostOwnedAccessProbe { param([object[]]$Paths) } `
            -ExcelInvoker { param([string]$InputPath, [string]$ResultPath) Copy-HerdrFileExclusive -SourcePath $InputPath -DestinationPath $ResultPath -TrustedDestinationRoot (Split-Path -Parent $ResultPath) | Out-Null }
    } 'hash changed' 'source tamper'

    $stageTamper = New-IntegrationFixture -Inbox $inbox -OneDriveOutbox $oneDriveOutbox -OneDriveArchive $oneDriveArchive `
        -Exchange $exchange -ReviewJobs $reviewJobs -Tools $tools -Number 3
    [IO.File]::WriteAllText($stageTamper.Staged.StagedPath, 'stage-tampered')
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $stageTamper.Job -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs -ToolsRoot $tools `
            -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
            -TestMode -InteractiveSessionProbe { $true } -HostOwnedAccessProbe { param([object[]]$Paths) } `
            -ExcelInvoker { param([string]$InputPath, [string]$ResultPath) Copy-HerdrFileExclusive -SourcePath $InputPath -DestinationPath $ResultPath -TrustedDestinationRoot (Split-Path -Parent $ResultPath) | Out-Null }
    } 'hash changed' 'stage tamper'

    $lastMileTamper = New-IntegrationFixture -Inbox $inbox -OneDriveOutbox $oneDriveOutbox -OneDriveArchive $oneDriveArchive `
        -Exchange $exchange -ReviewJobs $reviewJobs -Tools $tools -Number 4
    $tamperLastMile = { [IO.File]::WriteAllText((Join-Path $reviewJobs 'windows-4\input.xlsx'), 'last-mile-tampered') }.GetNewClosure()
    Assert-Throws {
        Invoke-HerdrExcelJob -JobPath $lastMileTamper.Job -ExchangeRoot $exchange -ReviewJobsRoot $reviewJobs -ToolsRoot $tools `
            -OneDriveInboxRoot $inbox -OneDriveOutboxRoot $oneDriveOutbox -OneDriveArchiveRoot $oneDriveArchive `
            -TestMode -InteractiveSessionProbe { $true } -HostOwnedAccessProbe { param([object[]]$Paths) } `
            -ExcelInvoker { param([string]$InputPath, [string]$ResultPath) Copy-HerdrFileExclusive -SourcePath $InputPath -DestinationPath $ResultPath -TrustedDestinationRoot (Split-Path -Parent $ResultPath) | Out-Null } `
            -AfterExcelHook $tamperLastMile
    } 'unstable' 'last-mile tamper'

    Invoke-HerdrDisposableExcelCanary
    Write-Host 'Herdr Windows security integration fixtures passed.'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

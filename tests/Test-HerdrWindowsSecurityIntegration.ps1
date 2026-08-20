#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$fixtureText = [IO.File]::ReadAllText($PSCommandPath)
$rawThreadPattern = '[Threading.' + 'ThreadStart]'
if ($fixtureText.Contains($rawThreadPattern, [StringComparison]::Ordinal)) {
    throw 'Mechanical race-fixture regression: raw ThreadStart execution is forbidden.'
}
if (-not $fixtureText.Contains('RunspaceFactory', [StringComparison]::Ordinal) -or
    -not $fixtureText.Contains('[PowerShell]::Create()', [StringComparison]::Ordinal)) {
    throw 'Mechanical race-fixture regression: the mutator must own an explicit PowerShell runspace.'
}
if (-not $fixtureText.Contains('[System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()', [StringComparison]::Ordinal)) {
    throw 'Mechanical race-fixture regression: the PowerShell 7 RunspaceFactory type must be fully qualified.'
}

function Invoke-HerdrRunspaceRoundTrip {
    $evidence = [Collections.Concurrent.ConcurrentDictionary[string, bool]]::new()
    $runspace = $null
    $powerShell = $null
    try {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.Open()
        [void]$evidence.TryAdd('runspace-opened', $true)
        $powerShell = [PowerShell]::Create()
        $powerShell.Runspace = $runspace
        [void]$powerShell.AddScript('param($value) "round-trip:$value"')
        [void]$powerShell.AddArgument('fixture')
        $async = $powerShell.BeginInvoke()
        [void]$evidence.TryAdd('begin-invoke-started', $true)
        if (-not $async.AsyncWaitHandle.WaitOne(5000)) {
            throw 'The platform-independent runspace round trip did not complete within the bounded timeout.'
        }
        $result = @($powerShell.EndInvoke($async))
        [void]$evidence.TryAdd('end-invoke-completed', $true)
        if ($result.Count -ne 1 -or [string]$result[0] -cne 'round-trip:fixture') {
            throw "The platform-independent runspace round trip returned an unexpected result: '$($result -join ', ')'."
        }
        [void]$evidence.TryAdd('result-collected', $true)
        if ($powerShell.Streams.Error.Count -gt 0) {
            throw (($powerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join ' | ')
        }
    }
    finally {
        if ($null -ne $powerShell) {
            $powerShell.Dispose()
            [void]$evidence.TryAdd('powershell-disposed', $true)
        }
        if ($null -ne $runspace) {
            $runspace.Dispose()
            [void]$evidence.TryAdd('runspace-disposed', $true)
        }
    }
    foreach ($requiredKey in @('runspace-opened', 'begin-invoke-started', 'end-invoke-completed', 'result-collected', 'powershell-disposed', 'runspace-disposed')) {
        if (-not $evidence.ContainsKey($requiredKey)) {
            throw "The platform-independent runspace round trip did not prove '$requiredKey'."
        }
    }
}

Invoke-HerdrRunspaceRoundTrip
Write-Host 'PASS: platform-independent runspace round-trip regression passed.'
Write-Host 'PASS: race-fixture execution mechanism is runspace-backed.'

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

function Start-HerdrRaceMutator {
    param(
        [Parameter(Mandatory)][string]$RaceParent,
        [Parameter(Mandatory)][string]$RaceMoved,
        [Parameter(Mandatory)][string]$RaceOutside,
        [Parameter(Mandatory)][object]$RaceEvidence,
        [Parameter(Mandatory)][object]$RaceStop,
        [Parameter(Mandatory)][object]$RaceErrors,
        [object]$RaceReady,
        [object]$RaceRelease
    )

    $script = @'
param($raceParent, $raceMoved, $raceOutside, $raceEvidence, $raceStop, $raceErrors, $raceReady, $raceRelease)
[void]$raceEvidence.TryAdd('race-runspace-started', $true)
for ($raceCycle = 0; $raceCycle -lt 256 -and -not $raceStop.IsSet; $raceCycle++) {
    [void]$raceEvidence.TryAdd('race-cycle', $true)
    try {
        if ([IO.Directory]::Exists($raceParent) -and -not [IO.Directory]::Exists($raceMoved)) {
            [IO.Directory]::Move($raceParent, $raceMoved)
            [void]$raceEvidence.TryAdd('parent-moved', $true)
        }
        if (-not [IO.Directory]::Exists($raceParent)) {
            New-Item -ItemType Junction -Path $raceParent -Target $raceOutside -Force | Out-Null
            [void]$raceEvidence.TryAdd('junction-created', $true)
            if ($null -ne $raceReady) {
                [void]$raceEvidence.TryAdd('race-junction-ready', $true)
                [void]$raceReady.Set()
                while ($null -ne $raceRelease -and -not $raceRelease.IsSet -and -not $raceStop.IsSet) {
                    Start-Sleep -Milliseconds 1
                }
            }
        }
        Start-Sleep -Milliseconds 1
        if ([IO.Directory]::Exists($raceParent) -and
            (([IO.File]::GetAttributes($raceParent) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            Remove-Item -LiteralPath $raceParent -Force -ErrorAction SilentlyContinue
            [void]$raceEvidence.TryAdd('junction-removed', $true)
        }
        if ([IO.Directory]::Exists($raceMoved) -and -not [IO.Directory]::Exists($raceParent)) {
            [IO.Directory]::Move($raceMoved, $raceParent)
            [void]$raceEvidence.TryAdd('parent-restored', $true)
        }
    }
    catch {
        [void]$raceErrors.Enqueue($_.Exception.ToString())
        [void]$raceEvidence.TryAdd('race-mutator-error', $true)
    }
}
'@
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $powerShell = [PowerShell]::Create()
    $powerShell.Runspace = $runspace
    [void]$powerShell.AddScript($script)
    [void]$powerShell.AddArgument($RaceParent)
    [void]$powerShell.AddArgument($RaceMoved)
    [void]$powerShell.AddArgument($RaceOutside)
    [void]$powerShell.AddArgument($RaceEvidence)
    [void]$powerShell.AddArgument($RaceStop)
    [void]$powerShell.AddArgument($RaceErrors)
    [void]$powerShell.AddArgument($RaceReady)
    [void]$powerShell.AddArgument($RaceRelease)
    $async = $powerShell.BeginInvoke()
    [pscustomobject]@{
        PowerShell = $powerShell
        Runspace = $runspace
        Async = $async
        Stop = $RaceStop
    }
}

function Stop-HerdrRaceMutator {
    param([Parameter(Mandatory)][object]$Worker)

    $Worker.Stop.Set()
    if (-not $Worker.Async.AsyncWaitHandle.WaitOne(10000)) {
        $Worker.PowerShell.Stop()
        if (-not $Worker.Async.AsyncWaitHandle.WaitOne(1000)) {
            throw 'The runspace-backed race mutator did not stop within the bounded timeout.'
        }
    }
    try {
        [void]$Worker.PowerShell.EndInvoke($Worker.Async)
        if ($Worker.PowerShell.Streams.Error.Count -gt 0) {
            throw (($Worker.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join ' | ')
        }
    }
    catch {
        throw "The runspace-backed race mutator failed: $($_.Exception.Message)"
    }
    finally {
        $Worker.PowerShell.Dispose()
        $Worker.Runspace.Dispose()
    }
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

    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $currentGroups = @([Security.Principal.WindowsIdentity]::GetCurrent().Groups | ForEach-Object { $_.Value })
    $effectiveWriteSddl = "D:P(A;;0x120116;;;$currentSid)"
    $effectiveReadSddl = "D:P(A;;0x120089;;;$currentSid)"
    $effectiveWriteDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new($effectiveWriteSddl)
    $effectiveReadDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new($effectiveReadSddl)
    $effectiveWriteBytes = [byte[]]::new($effectiveWriteDescriptor.BinaryLength)
    $effectiveReadBytes = [byte[]]::new($effectiveReadDescriptor.BinaryLength)
    $effectiveWriteDescriptor.GetBinaryForm($effectiveWriteBytes, 0)
    $effectiveReadDescriptor.GetBinaryForm($effectiveReadBytes, 0)
    Assert-True ([Herdr.Security.NativeMethods]::HasEffectiveWriteAccess($currentSid, $effectiveWriteBytes)) `
        'Authz effective-access regression did not detect direct token write access.'
    Assert-True (-not [Herdr.Security.NativeMethods]::HasEffectiveWriteAccess($currentSid, $effectiveReadBytes)) `
        'Authz effective-access regression treated read access as write access.'
    if ($currentGroups.Count -gt 0) {
        $groupSddl = "D:P(A;;0x120116;;;$($currentGroups[0]))"
        $groupDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new($groupSddl)
        $groupBytes = [byte[]]::new($groupDescriptor.BinaryLength)
        $groupDescriptor.GetBinaryForm($groupBytes, 0)
        Assert-True ([Herdr.Security.NativeMethods]::HasEffectiveWriteAccess($currentSid, $groupBytes)) `
            'Authz effective-access regression did not honor a token group write grant.'
    }

    $raceTrusted = Join-Path $root 'handle-race-trusted'
    $raceParent = Join-Path $raceTrusted 'parent'
    $raceMoved = Join-Path $raceTrusted 'parent-moved'
    $raceOutside = Join-Path $root 'handle-race-outside'
    New-Item -ItemType Directory -Path $raceParent, $raceOutside -Force | Out-Null
    $raceSource = Join-Path $raceTrusted 'race-source.xlsx'
    [IO.File]::WriteAllText($raceSource, 'race-source')
    $raceEvidence = [Collections.Concurrent.ConcurrentDictionary[string, bool]]::new()
    $raceErrors = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    $raceStop = [Threading.ManualResetEventSlim]::new($false)
    $raceWorker = Start-HerdrRaceMutator -RaceParent $raceParent -RaceMoved $raceMoved -RaceOutside $raceOutside `
        -RaceEvidence $raceEvidence -RaceStop $raceStop -RaceErrors $raceErrors
    $raceStartDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not $raceEvidence.ContainsKey('race-runspace-started') -and [DateTime]::UtcNow -lt $raceStartDeadline) {
        Start-Sleep -Milliseconds 10
    }
    Assert-True ($raceEvidence.ContainsKey('race-runspace-started')) 'The runspace-backed race mutator did not start.'
    $raceOperationAttempts = 0
    $raceOperationSuccesses = 0
    $raceOperationFailures = [Collections.Generic.List[string]]::new()
    $raceWorkerFailure = $null
    try {
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            $raceOperationAttempts++
            try {
                Ensure-HerdrManagedDirectory -Path (Join-Path $raceParent ("created-{0:d2}" -f $attempt)) `
                    -TrustedRoot $raceTrusted -Description 'concurrent create race' | Out-Null
                $raceOperationSuccesses++
            }
            catch {
                if ($raceOperationFailures.Count -lt 8) {
                    [void]$raceOperationFailures.Add("Ensure[$attempt]: $($_.Exception.Message)")
                }
            }
            $raceOperationAttempts++
            try {
                Copy-HerdrFileExclusive -SourcePath $raceSource `
                    -DestinationPath (Join-Path $raceParent ("copy-{0:d2}.xlsx" -f $attempt)) `
                    -TrustedRoot $raceTrusted -TrustedDestinationRoot $raceTrusted | Out-Null
                $raceOperationSuccesses++
            }
            catch {
                if ($raceOperationFailures.Count -lt 8) {
                    [void]$raceOperationFailures.Add("Copy[$attempt]: $($_.Exception.Message)")
                }
            }
        }
    }
    finally {
        try { Stop-HerdrRaceMutator -Worker $raceWorker }
        catch { $raceWorkerFailure = $_.Exception }
    }
    if ([IO.Directory]::Exists($raceParent) -and
        (([IO.File]::GetAttributes($raceParent) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Remove-Item -LiteralPath $raceParent -Force -ErrorAction SilentlyContinue
    }
    if ([IO.Directory]::Exists($raceMoved) -and -not [IO.Directory]::Exists($raceParent)) {
        [IO.Directory]::Move($raceMoved, $raceParent)
    }
    if ($null -ne $raceWorkerFailure) {
        throw "The ancestor/junction race worker failed: $($raceWorkerFailure.Message)"
    }
    $raceContentionDiagnostics = @($raceErrors.ToArray())
    $raceEvidenceKeys = @($raceEvidence.Keys)
    $raceMutationEvidence = @($raceEvidenceKeys | Where-Object {
        $_ -in @('parent-moved', 'junction-created', 'junction-removed', 'parent-restored')
    })
    Assert-True ($raceOperationAttempts -eq 80) `
        "Ancestor/junction race did not execute the bounded operation set (attempts=$raceOperationAttempts)."
    Assert-True ($raceMutationEvidence.Count -gt 0) `
        ("Ancestor/junction race did not observe a bounded ancestor mutation; attempts={0}; successes={1}; " +
         "race_evidence={2}; contention={3}." -f $raceOperationAttempts, $raceOperationSuccesses, ($raceEvidenceKeys -join ', '),
         ($raceContentionDiagnostics -join ' | '))
    $raceControlSuccess = $false
    try {
        Ensure-HerdrManagedDirectory -Path (Join-Path $raceParent 'control-after-race') `
            -TrustedRoot $raceTrusted -Description 'post-race control operation' | Out-Null
        $raceControlSuccess = $true
    }
    catch {
        [void]$raceOperationFailures.Add("Control: $($_.Exception.Message)")
    }
    Assert-True $raceControlSuccess `
        ("Ancestor/junction race control operation failed after parent restoration; attempts={0}; successes={1}; failures={2}; " +
         "race_evidence={3}; contention={4}." -f $raceOperationAttempts, $raceOperationSuccesses, ($raceOperationFailures -join ' | '),
         ($raceEvidenceKeys -join ', '), ($raceContentionDiagnostics -join ' | '))
    Assert-True (@(Get-ChildItem -LiteralPath $raceOutside -Force -File -ErrorAction SilentlyContinue).Count -eq 0) `
        'Handle-relative create/copy race wrote outside the trusted root.'

    $cleanupCollision = Join-Path $raceParent 'cleanup-collision.json'
    [IO.File]::WriteAllText($cleanupCollision, '{}')
    $cleanupEvidence = [Collections.Concurrent.ConcurrentDictionary[string, bool]]::new()
    $cleanupErrors = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    $cleanupReady = [Threading.ManualResetEventSlim]::new($false)
    $cleanupRelease = [Threading.ManualResetEventSlim]::new($false)
    $raceStop.Reset()
    $cleanupRaceWorker = Start-HerdrRaceMutator -RaceParent $raceParent -RaceMoved $raceMoved -RaceOutside $raceOutside `
        -RaceEvidence $cleanupEvidence -RaceStop $raceStop -RaceErrors $cleanupErrors `
        -RaceReady $cleanupReady -RaceRelease $cleanupRelease
    $cleanupError = $null
    $cleanupWorkerFailure = $null
    try {
        if (-not $cleanupReady.Wait(5000)) {
            throw ("The cleanup collision race did not establish its bounded start barrier; evidence={0}; contention={1}." -f
                (($cleanupEvidence.Keys | Sort-Object) -join ', '), ($cleanupErrors.ToArray() -join ' | '))
        }
        Assert-True ($cleanupEvidence.ContainsKey('race-runspace-started')) `
            'The cleanup collision race worker did not start.'
        Assert-True ($cleanupEvidence.ContainsKey('race-junction-ready')) `
            'The cleanup collision race did not report a ready junction.'
        Assert-True ([IO.Directory]::Exists($raceParent) -and
            (([IO.File]::GetAttributes($raceParent) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) `
            'The cleanup collision race did not establish the junction before the collision attempt.'
        [void]$cleanupEvidence.TryAdd('cleanup-junction-ready', $true)
        try {
            Write-HerdrAtomicText -Path $cleanupCollision -Content '{"safe":true}' -TrustedRoot $raceTrusted | Out-Null
        }
        catch { $cleanupError = $_.Exception }
    }
    catch { $cleanupError = $_.Exception }
    finally {
        [void]$cleanupRelease.Set()
        try { Stop-HerdrRaceMutator -Worker $cleanupRaceWorker }
        catch { $cleanupWorkerFailure = $_.Exception }
    }
    if ([IO.Directory]::Exists($raceParent) -and
        (([IO.File]::GetAttributes($raceParent) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Remove-Item -LiteralPath $raceParent -Force -ErrorAction SilentlyContinue
    }
    if ([IO.Directory]::Exists($raceMoved) -and -not [IO.Directory]::Exists($raceParent)) {
        [IO.Directory]::Move($raceMoved, $raceParent)
    }
    $cleanupReady.Dispose()
    $cleanupRelease.Dispose()
    if ($null -ne $cleanupWorkerFailure) {
        throw "The cleanup collision race worker failed: $($cleanupWorkerFailure.Message)"
    }
    $cleanupContentionDiagnostics = @($cleanupErrors.ToArray())
    $cleanupEvidenceKeys = @($cleanupEvidence.Keys)
    $cleanupMutationEvidence = @($cleanupEvidenceKeys | Where-Object {
        $_ -in @('parent-moved', 'junction-created', 'junction-removed', 'parent-restored')
    })
    Assert-True ($cleanupEvidence.ContainsKey('cleanup-junction-ready')) `
        ("Cleanup collision race did not retain its junction-ready evidence; evidence={0}; contention={1}." -f
            ($cleanupEvidenceKeys -join ', '), ($cleanupContentionDiagnostics -join ' | '))
    Assert-True ($cleanupMutationEvidence.Count -gt 0) `
        ("Cleanup collision race did not observe a bounded ancestor mutation; evidence={0}; contention={1}." -f
            ($cleanupEvidenceKeys -join ', '), ($cleanupContentionDiagnostics -join ' | '))
    Assert-True ($null -ne $cleanupError) 'Handle-relative cleanup race accepted an output collision.'
    $cleanupControlFailures = [Collections.Generic.List[string]]::new()
    $cleanupControlSuccess = $false
    try {
        Ensure-HerdrManagedDirectory -Path (Join-Path $raceParent 'cleanup-control-after-race') `
            -TrustedRoot $raceTrusted -Description 'post-cleanup-race control operation' | Out-Null
        $cleanupControlSuccess = $true
    }
    catch {
        [void]$cleanupControlFailures.Add($_.Exception.Message)
    }
    Assert-True $cleanupControlSuccess `
        ("Cleanup collision race control operation failed after parent restoration; failures={0}; evidence={1}; contention={2}." -f
            ($cleanupControlFailures -join ' | '), ($cleanupEvidenceKeys -join ', '),
            ($cleanupContentionDiagnostics -join ' | '))
    Assert-True (@(Get-ChildItem -LiteralPath $raceOutside -Recurse -Force -File -ErrorAction SilentlyContinue).Count -eq 0) `
        'Handle-relative cleanup race wrote outside the trusted root.'
    Assert-True (@(Get-ChildItem -LiteralPath $raceTrusted -Recurse -Force -File -Filter '.herdr-text-*.tmp' -ErrorAction SilentlyContinue).Count -eq 0) `
        'Handle-relative atomic-text cleanup left a temporary file.'

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

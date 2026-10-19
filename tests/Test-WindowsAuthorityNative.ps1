#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(0, [int]::MaxValue)][int]$RuntimeProcessId = 0,
    [string]$ExpectedRuntimeProcessCreationTimeUtc = '',
    [ValidateRange(0, [int]::MaxValue)][int]$ExpectedRuntimeSessionId = 0,
    [ValidatePattern('^S-1-5-21-[0-9-]+$')]
    [string]$ExpectedRuntimeUserSid = 'S-1-5-21-4197016633-3342904429-2049924131-1006',
    [string]$KnownUvExecutablePath = 'C:\Users\rdp-natha\AppData\Local\Microsoft\WinGet\Packages\astral-sh.uv_Microsoft.Winget.Source_8wekyb3d8bbwe\uv.exe',
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedUvTargetSha256 = '965816e654d8fac650b282345c89c1daff16a0cfe45e9d2d2a8f5af3fed466a4',
    [string]$ExpectedUvVersionOutput = 'uv 0.12.6 (7938ca5d5 2026-08-25 x86_64-pc-windows-msvc)'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrReviewStaging.ps1')
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrWindowsRuntimeTokenAccess.ps1')
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrHostOwnedAclPolicy.ps1')
. (Join-Path $PSScriptRoot '..\scripts\windows\WindowsReceiptAuthority.ps1')

if (-not $IsWindows) {
    Write-Host 'nativeNOTRUN: Windows authority native token/link/publication checks require Windows.'
    return
}

$missingInputs = @()
if ($RuntimeProcessId -eq 0) { $missingInputs += 'RuntimeProcessId' }
if ([string]::IsNullOrWhiteSpace($ExpectedRuntimeProcessCreationTimeUtc)) { $missingInputs += 'ExpectedRuntimeProcessCreationTimeUtc' }
if ($ExpectedRuntimeSessionId -eq 0) { $missingInputs += 'ExpectedRuntimeSessionId' }
if ($missingInputs.Count -ne 0) {
    Write-Host ("nativeNOTRUN: #1074 native acceptance requires commissioned live-process inputs: {0}." -f ($missingInputs -join ', '))
    return
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Expected, [string]$Name) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw "$Name failed unexpectedly: $($_.Exception.Message)" }
        return
    }
    throw "$Name was accepted unexpectedly."
}

function Assert-ThrowsAny([scriptblock]$Action, [string]$Name) {
    try { & $Action }
    catch { return }
    throw "$Name was accepted unexpectedly."
}

$runtimeSid = [Security.Principal.SecurityIdentifier]::new($ExpectedRuntimeUserSid)
$runtimeToken = Open-HerdrRuntimeTokenProof -ProcessId $RuntimeProcessId `
    -ExpectedCreationTimeUtc $ExpectedRuntimeProcessCreationTimeUtc `
    -ExpectedSessionId $ExpectedRuntimeSessionId -ExpectedUserSid $runtimeSid
$runnerProcess = Get-Process -Id $PID
$runnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$runnerCreation = $runnerProcess.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
$runnerToken = Open-HerdrRuntimeTokenProof -ProcessId $PID -ExpectedCreationTimeUtc $runnerCreation `
    -ExpectedSessionId $runnerProcess.SessionId -ExpectedUserSid $runnerSid
$programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
if ([string]::IsNullOrWhiteSpace($programData)) { throw 'Windows ProgramData path is unavailable.' }
$root = Join-Path $programData "HerdrWindowsAuthorityNative-$([Guid]::NewGuid().ToString('N'))"
if (Test-Path -LiteralPath $root) { throw "Private native fixture root already exists: '$root'." }

try {
    Assert-True ($runtimeToken.UserSid -ceq $ExpectedRuntimeUserSid) 'Runtime token SID differs from the commissioned SID.'
    $expectedRuntimeGroupAttributes = [uint32]0x00000010
    $expectedRunnerGroupAttributes = [uint32]0x0000000f
    Assert-True $runtimeToken.AdministratorsGroupPresent 'Runtime token lacks the expected Administrators group entry.'
    Assert-True $runtimeToken.AdministratorsGroupDenyOnly 'Runtime token Administrators group is not deny-only.'
    Assert-True (-not $runtimeToken.AdministratorsGroupEnabled) 'Runtime token Administrators group is unexpectedly enabled.'
    Assert-True ($runtimeToken.AdministratorsGroupAttributes -eq $expectedRuntimeGroupAttributes) `
        ("Runtime Administrators attributes were 0x{0:x8}, expected deny-only 0x{1:x8}." -f
            $runtimeToken.AdministratorsGroupAttributes, $expectedRuntimeGroupAttributes)
    Assert-True $runnerToken.AdministratorsGroupPresent 'Commissioning runner lacks the Administrators group entry.'
    Assert-True $runnerToken.AdministratorsGroupEnabled 'Commissioning runner Administrators group is not enabled.'
    Assert-True (-not $runnerToken.AdministratorsGroupDenyOnly) 'Commissioning runner Administrators group is unexpectedly deny-only.'
    Assert-True ($runnerToken.AdministratorsGroupAttributes -eq $expectedRunnerGroupAttributes) `
        ("Runner Administrators attributes were 0x{0:x8}, expected enabled 0x{1:x8}." -f
            $runnerToken.AdministratorsGroupAttributes, $expectedRunnerGroupAttributes)

    New-Item -ItemType Directory -Path $root | Out-Null
    Protect-HostOwnedReadOnlyTree -TargetPath $root -ReaderSid $runtimeSid
    Assert-HostOwnedReadOnlyTree -TargetPath $root -ReaderSid $runtimeSid
    $tokenCase = Join-Path $root 'token-case'
    New-Item -ItemType Directory -Path $tokenCase | Out-Null
    Protect-HostOwnedReadOnlyTree -TargetPath $tokenCase -ReaderSid $runtimeSid
    $expectedReaderMask = [uint32]0x001200A9
    $expectedAdministratorMask = [uint32]0x001F01FF
    $runtimeGranted = Get-HerdrRuntimeTokenGrantedAccess -RuntimeToken $runtimeToken -Path $tokenCase
    $runnerGranted = Get-HerdrRuntimeTokenGrantedAccess -RuntimeToken $runnerToken -Path $tokenCase
    Assert-True ($runtimeGranted -eq $expectedReaderMask) `
        ("Limited runtime AccessCheck mask was 0x{0:x8}, expected 0x{1:x8}." -f $runtimeGranted, $expectedReaderMask)
    Assert-True ($runnerGranted -eq $expectedAdministratorMask) `
        ("Enabled-Administrator AccessCheck mask was 0x{0:x8}, expected 0x{1:x8}." -f $runnerGranted, $expectedAdministratorMask)
    $assertedRuntimeMask = Assert-HerdrRuntimeTokenCannotMutate -RuntimeToken $runtimeToken -Path $tokenCase
    Assert-True ($assertedRuntimeMask -eq $runtimeGranted) 'Limited-token admission did not preserve the observed AccessCheck mask.'
    Assert-Throws {
        Assert-HerdrRuntimeTokenCannotMutate -RuntimeToken $runnerToken -Path $tokenCase
    } 'effective mutation authority' 'enabled-Administrator effective-writer rejection'

    $knownUv = Assert-HerdrAuthoritySafePath -Path $KnownUvExecutablePath
    Assert-True ((Get-HerdrAuthoritySha256 -Path $knownUv) -ceq $ExpectedUvTargetSha256) `
        'Known uv executable differs from the independently commissioned SHA-256.'
    $profile = Join-Path $root 'profile'
    $links = Join-Path $profile 'AppData\Local\Microsoft\WinGet\Links'
    $packages = Join-Path $profile 'AppData\Local\Microsoft\WinGet\Packages'
    New-Item -ItemType Directory -Path $links -Force | Out-Null
    New-Item -ItemType Directory -Path $packages -Force | Out-Null
    $link = Join-Path $links 'uv.exe'
    Assert-Throws {
        Get-HerdrUvIdentity -RuntimeProfilePath $profile -ExpectedTargetSha256 $ExpectedUvTargetSha256
    } 'command link is missing' 'missing WinGet uv link rejection'
    [IO.File]::WriteAllText($link, 'direct-path-fixture')
    Assert-Throws {
        Get-HerdrUvIdentity -RuntimeProfilePath $profile -ExpectedTargetSha256 $ExpectedUvTargetSha256
    } 'not a reparse link' 'direct PATH uv executable rejection'
    Remove-Item -LiteralPath $link -Force

    $foreign = Join-Path $root 'foreign-uv.exe'
    Copy-Item -LiteralPath $knownUv -Destination $foreign
    New-Item -ItemType SymbolicLink -Path $link -Target $foreign | Out-Null
    Assert-Throws {
        Get-HerdrUvIdentity -RuntimeProfilePath $profile -ExpectedTargetSha256 $ExpectedUvTargetSha256
    } 'outside the approved package root' 'foreign WinGet uv target rejection'
    Remove-Item -LiteralPath $link -Force

    $package = Join-Path $packages 'astral-sh.uv_Microsoft.Winget.Source_8wekyb3d8bbwe'
    New-Item -ItemType Directory -Path $package | Out-Null
    $approvedTarget = Join-Path $package 'uv.exe'
    Copy-Item -LiteralPath $knownUv -Destination $approvedTarget
    New-Item -ItemType SymbolicLink -Path $link -Target $approvedTarget | Out-Null
    Assert-Throws {
        Get-HerdrUvIdentity -RuntimeProfilePath $profile -ExpectedTargetSha256 ('0' * 64)
    } 'independently commissioned SHA-256' 'wrong WinGet uv target hash rejection'
    $uv = Get-HerdrUvIdentity -RuntimeProfilePath $profile -ExpectedTargetSha256 $ExpectedUvTargetSha256
    Assert-True ($uv.command_path -ceq $link -and $uv.command_path_is_reparse -eq $true) `
        'Positive uv identity did not preserve the canonical WinGet reparse leaf.'
    Assert-True ($uv.executable -ceq $approvedTarget -and $uv.sha256 -ceq $ExpectedUvTargetSha256) `
        'Positive uv identity did not preserve the approved topology and copied byte identity.'
    Assert-True ($uv.version -ceq $ExpectedUvVersionOutput) `
        "Positive uv identity returned an unexpected version: '$($uv.version)'."

    $successParent = Join-Path $root 'success'
    New-Item -ItemType Directory -Path $successParent | Out-Null
    Protect-HostOwnedReadOnlyTree -TargetPath $successParent -ReaderSid $runtimeSid
    Assert-HostOwnedReadOnlyTree -TargetPath $successParent -ReaderSid $runtimeSid
    $successRoot = Join-Path $successParent 'Issue961'
    $successAuthority = Join-Path $successRoot 'receipt-authority.json'
    $successReceipt = Join-Path $successRoot 'bootstrap-receipt.json'
    $receiptContent = ConvertTo-HerdrCanonicalJson -Value ([ordered]@{ receipt_id = '#961-private-native-positive' })
    $receiptHash = Get-HerdrStringSha256 -Value ($receiptContent + "`n")
    $authorityContent = ConvertTo-HerdrCanonicalJson -Value ([ordered]@{
        authority_id = $script:WindowsReceiptAuthorityId
        receipt_id = '#961-private-native-positive'
        receipt_path = $successReceipt
        receipt_sha256 = $receiptHash
    })
    $authorityHash = Get-HerdrStringSha256 -Value ($authorityContent + "`n")
    $savedWindowsReceiptPath = $script:WindowsReceiptPath
    try {
        $script:WindowsReceiptPath = $successReceipt
        Publish-HerdrAuthorityFirstInstall -AuthorityPath $successAuthority -AuthorityContent $authorityContent `
            -ReceiptPath $successReceipt -ReceiptContent $receiptContent -RuntimeSid $runtimeSid -RuntimeToken $runtimeToken
    }
    finally { $script:WindowsReceiptPath = $savedWindowsReceiptPath }
    Assert-True ([IO.File]::Exists($successAuthority) -and [IO.File]::Exists($successReceipt)) `
        'Successful first install did not publish both authority files.'
    Assert-True ((Get-HerdrAuthoritySha256 -Path $successReceipt) -ceq $receiptHash) `
        'Published receipt hash differs from the coherent staged receipt.'
    Assert-True ((Get-HerdrAuthoritySha256 -Path $successAuthority) -ceq $authorityHash) `
        'Published authority hash differs from the coherent staged authority.'
    Assert-True (([IO.File]::ReadAllText($successAuthority, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -AsHashtable).receipt_sha256 -ceq $receiptHash) `
        'Published authority does not bind the published receipt hash.'
    Assert-HostOwnedReadOnlyTree -TargetPath $successRoot -ReaderSid $runtimeSid
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $successRoot) -Filter '.issue-961-authority-*.tmp').Count -eq 0) `
        'Successful first install retained staging residue.'

    $rawPublishedHandle = [Herdr.Security.NativeMethods]::OpenDirectoryForRelative($successRoot)
    $heldPublishedHandle = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new($rawPublishedHandle, $true)
    $movedSuccessRoot = Join-Path (Split-Path -Parent $successRoot) 'Issue961-moved'
    try {
        Assert-ThrowsAny { [IO.Directory]::Move($successRoot, $movedSuccessRoot) } `
            'held published directory rename sharing check'
    }
    finally { $heldPublishedHandle.Dispose() }
    Assert-True ([IO.Directory]::Exists($successRoot) -and -not [IO.Directory]::Exists($movedSuccessRoot)) `
        'Held-handle rename check changed the published namespace.'

    $existingRoot = Join-Path $root 'existing\Issue961'
    New-Item -ItemType Directory -Path $existingRoot -Force | Out-Null
    $existingAuthority = Join-Path $existingRoot 'receipt-authority.json'
    $existingReceipt = Join-Path $existingRoot 'bootstrap-receipt.json'
    [IO.File]::WriteAllText($existingAuthority, '{"old":"authority"}')
    [IO.File]::WriteAllText($existingReceipt, '{"old":"receipt"}')
    $authorityBefore = Get-HerdrAuthoritySha256 -Path $existingAuthority
    $receiptBefore = Get-HerdrAuthoritySha256 -Path $existingReceipt
    $heldAuthority = [IO.File]::Open($existingAuthority, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        Assert-Throws {
            Publish-HerdrAuthorityFirstInstall -AuthorityPath $existingAuthority -AuthorityContent '{}' `
                -ReceiptPath $existingReceipt -ReceiptContent '{}' -RuntimeSid $runtimeSid -RuntimeToken $runtimeToken
        } 'first-install-only publication refuses replacement' 'held authority replacement refusal'
    }
    finally { $heldAuthority.Dispose() }
    Assert-True ((Get-HerdrAuthoritySha256 -Path $existingAuthority) -ceq $authorityBefore -and
        (Get-HerdrAuthoritySha256 -Path $existingReceipt) -ceq $receiptBefore) `
        'Held-authority refusal changed the last valid generation.'

    $failedParent = Join-Path $root 'failed'
    New-Item -ItemType Directory -Path $failedParent | Out-Null
    Protect-HostOwnedReadOnlyTree -TargetPath $failedParent -ReaderSid $runtimeSid
    Assert-HostOwnedReadOnlyTree -TargetPath $failedParent -ReaderSid $runtimeSid
    $failedTarget = Join-Path $failedParent 'Issue961'
    $failedReceipt = Join-Path $failedTarget 'bootstrap-receipt.json'
    $savedWindowsReceiptPath = $script:WindowsReceiptPath
    try {
        $script:WindowsReceiptPath = $failedReceipt
        Assert-Throws {
            Publish-HerdrAuthorityFirstInstall -AuthorityPath (Join-Path $failedTarget 'receipt-authority.json') `
                -AuthorityContent 'not-json' -ReceiptPath $failedReceipt -ReceiptContent '{}' `
                -RuntimeSid $runtimeSid -RuntimeToken $runtimeToken
        } 'Conversion from JSON failed' 'failed staged generation cleanup'
    }
    finally { $script:WindowsReceiptPath = $savedWindowsReceiptPath }
    Assert-True (-not (Test-Path -LiteralPath $failedTarget)) `
        'A failed first installation exposed a partial authority namespace.'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $failedTarget) -Filter '.issue-961-authority-*.tmp').Count -eq 0) `
        'A failed first installation retained a staged generation.'

    Write-Host ("Windows #1074 native positive acceptance PASS: runtime_pid={0} runtime_creation_utc={1} " +
        "runtime_session={2} runtime_sid={3} runtime_group_attributes=0x{4:x8} runtime_granted=0x{5:x8} " +
        "runner_group_attributes=0x{6:x8} runner_granted=0x{7:x8} uv_sha256={8} uv_version='{9}'." -f
        $RuntimeProcessId, $ExpectedRuntimeProcessCreationTimeUtc, $ExpectedRuntimeSessionId, $ExpectedRuntimeUserSid,
        $runtimeToken.AdministratorsGroupAttributes, $runtimeGranted, $runnerToken.AdministratorsGroupAttributes,
        $runnerGranted, $uv.sha256, $uv.version)
}
finally {
    $runnerToken.Dispose()
    $runtimeToken.Dispose()
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

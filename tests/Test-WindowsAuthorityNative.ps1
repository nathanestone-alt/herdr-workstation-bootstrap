$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrReviewStaging.ps1')
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrWindowsRuntimeTokenAccess.ps1')
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrHostOwnedAclPolicy.ps1')
. (Join-Path $PSScriptRoot '..\scripts\windows\WindowsReceiptAuthority.ps1')

if (-not $IsWindows) {
    Write-Host 'SKIP: Windows authority native token/link/publication checks require Windows.'
    exit 0
}

function Assert-Throws([scriptblock]$Action, [string]$Expected, [string]$Name) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw "$Name failed unexpectedly: $($_.Exception.Message)" }
        return
    }
    throw "$Name was accepted unexpectedly."
}

$process = Get-Process -Id $PID
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$creation = $process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
$token = Open-HerdrRuntimeTokenProof -ProcessId $PID -ExpectedCreationTimeUtc $creation `
    -ExpectedSessionId $process.SessionId -ExpectedUserSid $sid
$root = Join-Path ([IO.Path]::GetTempPath()) "herdr-windows-authority-native-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    Assert-Throws {
        Assert-HerdrRuntimeTokenCannotMutate -RuntimeToken $token -Path $root
    } 'effective mutation authority' 'actual token AccessCheck write detection'

    $profile = Join-Path $root 'profile'
    $links = Join-Path $profile 'AppData\Local\Microsoft\WinGet\Links'
    $packages = Join-Path $profile 'AppData\Local\Microsoft\WinGet\Packages'
    New-Item -ItemType Directory -Path $links -Force | Out-Null
    New-Item -ItemType Directory -Path $packages -Force | Out-Null
    $link = Join-Path $links 'uv.exe'
    Assert-Throws {
        Get-HerdrUvIdentity -RuntimeProfilePath $profile -ExpectedTargetSha256 ('0' * 64)
    } 'command link is missing' 'missing WinGet uv link rejection'
    [IO.File]::WriteAllText($link, 'direct-path-fixture')
    Assert-Throws {
        Get-HerdrUvIdentity -RuntimeProfilePath $profile -ExpectedTargetSha256 ('0' * 64)
    } 'not a reparse link' 'direct PATH uv executable rejection'
    Remove-Item -LiteralPath $link -Force

    $foreign = Join-Path $root 'foreign-uv.exe'
    Copy-Item -LiteralPath (Get-Process -Id $PID).Path -Destination $foreign
    New-Item -ItemType SymbolicLink -Path $link -Target $foreign | Out-Null
    Assert-Throws {
        Get-HerdrUvIdentity -RuntimeProfilePath $profile -ExpectedTargetSha256 (Get-HerdrAuthoritySha256 -Path $foreign)
    } 'outside the approved package root' 'foreign WinGet uv target rejection'
    Remove-Item -LiteralPath $link -Force

    $package = Join-Path $packages 'astral-sh.uv_Microsoft.Winget.Source_8wekyb3d8bbwe'
    New-Item -ItemType Directory -Path $package | Out-Null
    $approvedTarget = Join-Path $package 'uv.exe'
    Copy-Item -LiteralPath (Get-Process -Id $PID).Path -Destination $approvedTarget
    New-Item -ItemType SymbolicLink -Path $link -Target $approvedTarget | Out-Null
    Assert-Throws {
        Get-HerdrUvIdentity -RuntimeProfilePath $profile -ExpectedTargetSha256 ('0' * 64)
    } 'independently commissioned SHA-256' 'wrong WinGet uv target hash rejection'

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
                -ReceiptPath $existingReceipt -ReceiptContent '{}' -RuntimeSid $sid -RuntimeToken $token
        } 'first-install-only publication refuses replacement' 'held authority replacement refusal'
    }
    finally { $heldAuthority.Dispose() }
    if ((Get-HerdrAuthoritySha256 -Path $existingAuthority) -cne $authorityBefore -or
        (Get-HerdrAuthoritySha256 -Path $existingReceipt) -cne $receiptBefore) {
        throw 'Held-authority refusal changed the last valid generation.'
    }

    $failedTarget = Join-Path $root 'failed\Issue961'
    New-Item -ItemType Directory -Path (Split-Path -Parent $failedTarget) -Force | Out-Null
    $script:WindowsReceiptPath = Join-Path $failedTarget 'bootstrap-receipt.json'
    Assert-Throws {
        Publish-HerdrAuthorityFirstInstall -AuthorityPath (Join-Path $failedTarget 'receipt-authority.json') `
            -AuthorityContent 'not-json' -ReceiptPath $script:WindowsReceiptPath -ReceiptContent '{}' `
            -RuntimeSid $sid -RuntimeToken $token
    } 'Conversion from JSON failed' 'failed staged generation cleanup'
    if (Test-Path -LiteralPath $failedTarget) { throw 'A failed first installation exposed a partial authority namespace.' }
    if (@(Get-ChildItem -LiteralPath (Split-Path -Parent $failedTarget) -Filter '.issue-961-authority-*.tmp').Count -ne 0) {
        throw 'A failed first installation retained a staged generation.'
    }

    Write-Host 'Windows authority native token/link/publication tests passed.'
}
finally {
    $token.Dispose()
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

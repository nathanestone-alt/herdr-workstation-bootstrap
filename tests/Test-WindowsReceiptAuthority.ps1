$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrReviewStaging.ps1')
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrWindowsRuntimeTokenAccess.ps1')
. (Join-Path $PSScriptRoot '..\scripts\windows\WindowsReceiptAuthority.ps1')

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

$canonical = ConvertTo-HerdrCanonicalJson -Value ([ordered]@{ b = 1; a = [ordered]@{ z = 2; a = 1 } })
Assert-True ($canonical -ceq '{"a":{"a":1,"z":2},"b":1}') 'Canonical JSON did not recursively sort object keys.'
Assert-True ((Get-HerdrStringSha256 -Value '') -ceq 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') `
    'UTF-8 string hashing does not match SHA-256.'

$root = Join-Path ([IO.Path]::GetTempPath()) "herdr-windows-authority-$([Guid]::NewGuid().ToString('N'))"
try {
    New-Item -ItemType Directory -Path (Join-Path $root 'payload') -Force | Out-Null
    $payload = Join-Path $root 'payload\file.txt'
    [IO.File]::WriteAllText($payload, 'fixture', [Text.UTF8Encoding]::new($false))
    $manifest = Join-Path $root 'manifest.sha256'
    [IO.File]::WriteAllText($manifest, "$(Get-HerdrAuthoritySha256 -Path $payload)  file.txt`n", [Text.UTF8Encoding]::new($false))
    Test-HerdrPayloadManifest -PayloadRoot (Join-Path $root 'payload') -ManifestPath $manifest
    [IO.File]::WriteAllText($payload, 'tampered', [Text.UTF8Encoding]::new($false))
    Assert-Throws { Test-HerdrPayloadManifest -PayloadRoot (Join-Path $root 'payload') -ManifestPath $manifest } 'differs from manifest' 'payload tamper'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

$receipt = [ordered]@{
    receipt_id = 'fixture'
    verification_status = 'verified'
    source_commit_sha = ('a' * 40)
    payload_manifest_sha256 = ('b' * 64)
    bridge_allowlist_sha256 = ('c' * 64)
    platform = 'Windows'
    architecture = 'x86_64'
    python313 = [ordered]@{ executable = 'C:\Python313\python.exe'; sha256 = ('d' * 64); launcher = [ordered]@{ executable = 'C:\Windows\py.exe'; sha256 = ('e' * 64) } }
    uv = [ordered]@{ command_path = 'C:\Users\rdp-natha\AppData\Local\Microsoft\WinGet\Links\uv.exe'; command_path_is_reparse = $true; executable = 'C:\Users\rdp-natha\AppData\Local\Microsoft\WinGet\Packages\astral-sh.uv_Microsoft.Winget.Source_8wekyb3d8bbwe\uv.exe'; sha256 = ('f' * 64) }
    role_manifest_sha256 = ('1' * 64)
    runtime_identity = [ordered]@{ account = 'HERDR-WIN\rdp-natha'; sid = 'S-1-5-21-fixture' }
    provenance = [ordered]@{ producer = 'herdr-workstation-bootstrap' }
}
$envelope = New-HerdrWindowsAuthorityValue -Receipt $receipt -ReceiptPath 'C:\ProgramData\STModel\Issue961\bootstrap-receipt.json' -ReceiptSha256 ('2' * 64)
Assert-True ($envelope.authority_id -ceq '#961-installation-authority-v1') 'Authority ID changed.'
Assert-True ($envelope.python313.launcher.sha256 -ceq ('e' * 64)) 'Authority dropped the py launcher identity.'
Assert-True ($envelope.uv.command_path_is_reparse -eq $true -and $envelope.uv.executable.EndsWith('\uv.exe')) `
    'Authority dropped the uv reparse-source-to-target proof.'
Assert-True ($envelope.runtime_identity.account -ceq 'HERDR-WIN\rdp-natha') 'Authority dropped the approved runtime account.'

$entrypoint = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\scripts\windows\Install-WindowsReceiptAuthority.ps1'))
foreach ($required in @(
    '#Requires -RunAsAdministrator',
    "'C:\ProgramData\STModel\Issue961\receipt-authority.json'",
    "'HERDR-WIN\rdp-natha'",
    'Get-HerdrUvIdentity',
    'ExpectedUvTargetSha256',
    'RuntimeProcessId',
    'ExpectedRuntimeProcessCreationTimeUtc',
    'ExpectedRuntimeSessionId',
    'Open-HerdrRuntimeTokenProof',
    'Publish-HerdrAuthorityFirstInstall',
    'Protect-HostOwnedReadOnlyTree',
    '[IO.Directory]::Move',
    'first-install-only publication refuses replacement',
    'status',
    '--untracked-files=no'
)) {
    Assert-True ($entrypoint.Contains($required) -or ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\scripts\windows\WindowsReceiptAuthority.ps1')).Contains($required))) `
        "Windows authority implementation lacks required contract token: $required"
}
foreach ($forbidden in @('Everyone', 'S-1-1-0', 'Copy-Item')) {
    Assert-True (-not $entrypoint.Contains($forbidden)) "Windows authority entrypoint contains prohibited token: $forbidden"
}

$implementation = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\scripts\windows\WindowsReceiptAuthority.ps1'))
foreach ($required in @(
    'Microsoft\WinGet\Links\uv.exe',
    'astral-sh[.]uv_Microsoft[.]Winget[.]Source_',
    'not a reparse link',
    'outside the approved package root',
    'independently commissioned SHA-256'
)) {
    Assert-True $implementation.Contains($required) "WinGet uv enforcement lacks required proof: $required"
}

Write-Host 'Windows receipt-authority source fixture tests passed.'

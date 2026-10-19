$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrReviewStaging.ps1')
. (Join-Path $PSScriptRoot '..\scripts\windows\HerdrWindowsRuntimeTokenAccess.ps1')
. (Join-Path $PSScriptRoot '..\scripts\windows\WindowsReceiptAuthority.ps1')

$script:assertionCount = 0

function Assert-True([bool]$Condition, [string]$Message) {
    $script:assertionCount++
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Expected, [string]$Name) {
    $script:assertionCount++
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

$canonicalExpiry = '2026-10-05T04:20:46Z'
$expiryJson = '{"expires_at_utc":"' + $canonicalExpiry + '"}'
$coercedExpiry = ($expiryJson | ConvertFrom-Json -AsHashtable).expires_at_utc
Assert-True ($coercedExpiry -is [datetime]) 'Fixture no longer reproduces ConvertFrom-Json timestamp coercion.'
Assert-True ([string]$coercedExpiry -cne $canonicalExpiry) 'Fixture did not reproduce the DateTime-to-locale-string corruption.'
$parsedExpiry = Assert-HerdrWindowsReceiptExpiry -ReceiptJson $expiryJson -Now ([datetime]'2026-09-05T04:20:46Z')
Assert-True ($parsedExpiry.Kind -eq [DateTimeKind]::Utc -and $parsedExpiry.ToString('o').StartsWith('2026-10-05T04:20:46')) `
    'Canonical future receipt expiry was not preserved and parsed as UTC.'
Assert-Throws {
    Assert-HerdrWindowsReceiptExpiry -ReceiptJson '{"expires_at_utc":"2026-09-05T04:20:46Z"}' -Now ([datetime]'2026-09-05T04:20:46Z')
} 'expired' 'expired receipt timestamp'
foreach ($invalidExpiry in @(
    '{}',
    '{"expires_at_utc":null}',
    '{"expires_at_utc":20261005}',
    '{"expires_at_utc":"2026-10-05T04:20:46.000Z"}',
    '{"expires_at_utc":"2026-10-05T04:20:46+00:00"}',
    '{"expires_at_utc":"10/05/2026 04:20:46"}',
    '{"expires_at_utc":"2026-02-30T04:20:46Z"}'
)) {
    Assert-Throws {
        Assert-HerdrWindowsReceiptExpiry -ReceiptJson $invalidExpiry -Now ([datetime]'2026-09-05T04:20:46Z')
    } 'expires_at_utc' "invalid receipt timestamp $invalidExpiry"
}

$previousCulture = [Globalization.CultureInfo]::CurrentCulture
try {
    [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    $parsedExpiry = Assert-HerdrWindowsReceiptExpiry -ReceiptJson $expiryJson -Now ([datetime]'2026-09-05T04:20:46Z')
    Assert-True ($parsedExpiry.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -ceq $canonicalExpiry) `
        'Raw JSON expiry parsing changed under de-DE.'
}
finally { [Globalization.CultureInfo]::CurrentCulture = $previousCulture }
Assert-HerdrWindowsReceiptExpiry -ReceiptJson '{"expiry_policy":"none","expires_at_utc":null}'
foreach ($policy in @('"rolling"', 'null', 'false', '1', '[]', '{}')) {
    Assert-Throws {
        Assert-HerdrWindowsReceiptExpiry -ReceiptJson ('{"expiry_policy":' + $policy + ',"expires_at_utc":null}')
    } 'expiry_policy' "invalid expiry policy $policy"
}
foreach ($expiry in @('"2999-01-01T00:00:00Z"', 'false', '1', '[]', '{}')) {
    Assert-Throws {
        Assert-HerdrWindowsReceiptExpiry -ReceiptJson ('{"expiry_policy":"none","expires_at_utc":' + $expiry + '}')
    } 'expires_at_utc' "non-null expiry under none $expiry"
}
Assert-Throws {
    Assert-HerdrWindowsReceiptExpiry -ReceiptJson '{"expiry_policy":"none"}'
} 'expires_at_utc' 'missing expiry under none'
$expiredJson = '{"expires_at_utc":"2000-01-01T00:00:00Z"}'
Assert-True ((Assert-HerdrWindowsReceiptExpiry -ReceiptJson $expiredJson -SkipAgeCheck).Year -eq 2000) `
    'Replacement did not accept a well-formed expired legacy timestamp.'
Assert-Throws {
    Assert-HerdrWindowsReceiptExpiry -ReceiptJson '{"expiry_policy":false,"expires_at_utc":null}' -SkipAgeCheck
} 'expiry_policy' 'replacement policy validation'
Assert-Throws {
    Assert-HerdrWindowsReceiptExpiry -ReceiptJson '{"expires_at_utc":"garbage"}' -SkipAgeCheck
} 'expires_at_utc' 'replacement timestamp validation'

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
    'Commissioned uv version must be 0.12.6',
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

$aclPolicyPath = Join-Path $PSScriptRoot '..\scripts\windows\HerdrHostOwnedAclPolicy.ps1'
$parseErrors = $null
$aclPolicyAst = [Management.Automation.Language.Parser]::ParseFile($aclPolicyPath, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'Host-owned ACL policy did not parse for command-shape regression checks.'
$readOnlyFunction = @($aclPolicyAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Protect-HostOwnedReadOnlyTree'
}, $true))
Assert-True ($readOnlyFunction.Count -eq 1) 'Read-only ACL policy function cardinality changed.'
$icaclsCommands = @($readOnlyFunction[0].FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.Extent.Text.Contains('$icacls')
}, $true) | ForEach-Object { $_.Extent.Text })
$ownerCommands = @($icaclsCommands | Where-Object { $_.Contains("'/setowner'") })
$daclCommands = @($icaclsCommands | Where-Object { $_.Contains("'/grant:r'") })
Assert-True ($ownerCommands.Count -eq 1) 'Read-only ACL policy must issue exactly one owner command per item.'
Assert-True ($daclCommands.Count -eq 1) 'Read-only ACL policy must issue exactly one replacement-DACL command per item.'
Assert-True (-not $ownerCommands[0].Contains("'/grant:r'")) `
    'Read-only ACL policy recombined incompatible icacls owner and DACL operations.'
Assert-True (-not $daclCommands[0].Contains("'/setowner'")) `
    'Read-only ACL policy recombined incompatible icacls DACL and owner operations.'

Write-Host "Windows receipt-authority source fixture tests passed: $script:assertionCount assertions."

if (-not $IsWindows) {
    Write-Host 'Windows replacement native fixtures NOTRUN (requires Windows; run this suite in a non-elevated scratch directory).'
    return
}
$fixtureIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Assert-True (-not $fixtureIsAdmin) 'Replacement fixtures must run non-elevated.'
Assert-Throws { Assert-HerdrAuthorityAdministrator } 'elevated' 'replacement without elevation'
Assert-Throws {
    Publish-HerdrAuthorityReplacement -AuthorityPath (Join-Path ([IO.Path]::GetTempPath()) 'stm1658-refused-authority.json') `
        -AuthorityContent '{}' -ReceiptPath (Join-Path ([IO.Path]::GetTempPath()) 'stm1658-refused-receipt.json') `
        -ReceiptContent '{}' -RuntimeSid ([Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1000')) `
        -RuntimeToken @{} -RuntimeProfilePath ([IO.Path]::GetTempPath())
} 'elevated' 'replacement publisher without elevation'

# The fixture substitutes host-owner ACL operations and ancestor handles that
# require elevation. Check's identity/digest reader and the NTFS transaction run live.
& {
    function Assert-HerdrAuthorityAdministrator {}
    function Get-HerdrPathComponents { param($Path) return ,(Get-HerdrCanonicalPath -Path $Path) }
    function Ensure-HerdrManagedDirectory {
        param($Path, $Description, [switch]$RequireLeafCreation)
        if ($RequireLeafCreation -and (Test-Path -LiteralPath $Path)) { throw 'Fixture directory already exists.' }
        New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    }
    function Protect-HostOwnedReadOnlyTree { param($TargetPath, $ReaderSid) $script:fixtureProtected++ }
    function Assert-HostOwnedReadOnlyTree {
        param($TargetPath, $ReaderSid)
        $script:fixtureOwnerChecks++
        if ($script:fixtureRejectAcl) { throw 'fixture existing owner/ACL rejected' }
    }
    function Assert-HerdrAuthorityNamespaceRuntimeAccess {
        param($AuthorityRoot, $RuntimeToken)
        $script:fixtureAccessChecks++
        if ($script:fixtureRejectAccess) { throw 'fixture runtime access rejected' }
    }
    function Get-HerdrUvIdentity { param($RuntimeProfilePath, $ExpectedTargetSha256) return $script:fixtureUv }
    $script:fixtureProtected = 0
    $script:fixtureOwnerChecks = 0
    $script:fixtureAccessChecks = 0
    $script:fixtureRejectAcl = $false
    $script:fixtureRejectAccess = $false
    $savedAuthorityPath = $script:WindowsReceiptAuthorityPath
    $savedReceiptPath = $script:WindowsReceiptPath
    $root = Join-Path ([IO.Path]::GetTempPath()) "stm1658-pair-$([Guid]::NewGuid().ToString('N'))"
    try {
        $target = Join-Path $root 'Issue961'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        $script:WindowsReceiptAuthorityPath = Join-Path $target 'receipt-authority.json'
        $script:WindowsReceiptPath = Join-Path $target 'bootstrap-receipt.json'
        $executable = Join-Path $root 'fixture.exe'
        [IO.File]::WriteAllText($executable, 'fixture executable')
        $identity = [ordered]@{ executable = $executable; sha256 = Get-HerdrAuthoritySha256 $executable }
        $python = [ordered]@{ executable = $identity.executable; sha256 = $identity.sha256; launcher = $identity }
        $script:fixtureUv = [ordered]@{
            executable = $executable; sha256 = $identity.sha256; command_path = (Join-Path $root 'uv-link.exe')
            command_path_is_reparse = $true; version = 'uv 0.12.6'; version_output_sha256 = ('f' * 64)
        }
        $sid = [Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1000')
        $value = New-HerdrWindowsReceiptValues -SourceRoot $root -SourceCommit ('a' * 40) `
            -PayloadManifestSha256 ('b' * 64) -BridgeAllowlistSha256 ('c' * 64) `
            -ReceiptPath $script:WindowsReceiptPath -RuntimeAccount $script:WindowsRuntimeAccount -RuntimeSid $sid `
            -Python313 $python -Uv $script:fixtureUv -RoleIdentities ([ordered]@{ git = $identity; pwsh = $identity }) `
            -ProducerScriptSha256 ('d' * 64)
        $newReceipt = ConvertTo-HerdrCanonicalJson -Value $value
        $minted = [Text.Json.JsonDocument]::Parse($newReceipt)
        try {
            Assert-True ($minted.RootElement.GetProperty('schema_version').GetInt32() -eq 1 -and
                $minted.RootElement.GetProperty('expiry_policy').GetString() -ceq 'none' -and
                $minted.RootElement.GetProperty('expires_at_utc').ValueKind -eq [Text.Json.JsonValueKind]::Null) `
                'Minted Windows receipt did not preserve schema 1, policy none and an explicit JSON null.'
        }
        finally { $minted.Dispose() }
        $newAuthority = ConvertTo-HerdrCanonicalJson -Value (New-HerdrWindowsAuthorityValue -Receipt $value `
            -ReceiptPath $script:WindowsReceiptPath -ReceiptSha256 (Get-HerdrStringSha256 ($newReceipt + "`n")))
        $value.Remove('expiry_policy')
        $value.expires_at_utc = '2000-01-01T00:00:00Z'
        $value.receipt_id = 'legacy-expired-fixture'
        $oldReceipt = ConvertTo-HerdrCanonicalJson -Value $value
        $oldAuthority = ConvertTo-HerdrCanonicalJson -Value (New-HerdrWindowsAuthorityValue -Receipt $value `
            -ReceiptPath $script:WindowsReceiptPath -ReceiptSha256 (Get-HerdrStringSha256 ($oldReceipt + "`n")))
        Write-HerdrAuthorityStagedFile $script:WindowsReceiptPath $oldReceipt
        Write-HerdrAuthorityStagedFile $script:WindowsReceiptAuthorityPath $oldAuthority
        $check = @{ AuthorityPath = $script:WindowsReceiptAuthorityPath; RuntimeSid = $sid; RuntimeToken = @{}; RuntimeProfilePath = $root }
        $publish = @{
            AuthorityPath = $script:WindowsReceiptAuthorityPath; AuthorityContent = $newAuthority
            ReceiptPath = $script:WindowsReceiptPath; ReceiptContent = $newReceipt
            RuntimeSid = $sid; RuntimeToken = @{}; RuntimeProfilePath = $root
        }
        Assert-Throws { Assert-HerdrWindowsAuthority @check } 'expired' 'ordinary Check on expired legacy pair'
        Assert-HerdrWindowsAuthority @check -SkipExpiryAge
        $firstInstall = $publish.Clone()
        $firstInstall.Remove('RuntimeProfilePath')
        Assert-Throws { Publish-HerdrAuthorityFirstInstall @firstInstall } 'first-install-only' 'no-switch existing-pair refusal'
        $oldReceiptHash = Get-HerdrAuthoritySha256 $script:WindowsReceiptPath
        $oldAuthorityHash = Get-HerdrAuthoritySha256 $script:WindowsReceiptAuthorityPath
        $companion = $oldAuthority | ConvertFrom-Json -AsHashtable
        $companion.expiry_policy = 'none'
        $companion.expires_at_utc = $null
        [IO.File]::WriteAllText($script:WindowsReceiptAuthorityPath, (ConvertTo-HerdrCanonicalJson $companion) + "`n", [Text.UTF8Encoding]::new($false))
        Assert-HerdrWindowsAuthority @check -SkipExpiryAge
        $companion.expires_at_utc = '2999-01-01T00:00:00Z'
        [IO.File]::WriteAllText($script:WindowsReceiptAuthorityPath, (ConvertTo-HerdrCanonicalJson $companion) + "`n", [Text.UTF8Encoding]::new($false))
        Assert-Throws { Assert-HerdrWindowsAuthority @check -SkipExpiryAge } 'expires_at_utc' 'non-null companion expiry'
        $companion.expiry_policy = 'rolling'
        [IO.File]::WriteAllText($script:WindowsReceiptAuthorityPath, (ConvertTo-HerdrCanonicalJson $companion) + "`n", [Text.UTF8Encoding]::new($false))
        Assert-Throws { Assert-HerdrWindowsAuthority @check -SkipExpiryAge } 'expiry_policy' 'unknown companion policy'
        [IO.File]::WriteAllText($script:WindowsReceiptAuthorityPath, $oldAuthority + "`n", [Text.UTF8Encoding]::new($false))
        $script:fixtureRejectAcl = $true
        Assert-Throws { Publish-HerdrAuthorityReplacement @publish } 'owner/ACL rejected' 'invalid existing ACL'
        $script:fixtureRejectAcl = $false
        $script:fixtureRejectAccess = $true
        Assert-Throws { Publish-HerdrAuthorityReplacement @publish } 'runtime access rejected' 'writable existing namespace'
        $script:fixtureRejectAccess = $false
        [IO.File]::AppendAllText($script:WindowsReceiptPath, 'tamper')
        Assert-Throws { Publish-HerdrAuthorityReplacement @publish } 'receipt hash differs' 'invalid existing pair digest'
        [IO.File]::WriteAllText($script:WindowsReceiptPath, $oldReceipt + "`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::AppendAllText($executable, 'tamper')
        Assert-Throws { Assert-HerdrWindowsAuthority @check -SkipExpiryAge } 'identity hash changed' 'ordinary Check on existing executable drift'
        Assert-HerdrWindowsAuthority @check -SkipExpiryAge -SkipInstalledIdentityDrift
        [IO.File]::WriteAllText($executable, 'fixture executable')
        $badPublish = $publish.Clone()
        $badPublish.AuthorityContent = $newAuthority.Replace((Get-HerdrStringSha256 ($newReceipt + "`n")), ('0' * 64))
        Assert-Throws { Publish-HerdrAuthorityReplacement @badPublish } 'not internally coherent' 'invalid new generation'
        Assert-True ((Get-HerdrAuthoritySha256 $script:WindowsReceiptPath) -ceq $oldReceiptHash -and
            (Get-HerdrAuthoritySha256 $script:WindowsReceiptAuthorityPath) -ceq $oldAuthorityHash) `
            'Pre-publication failures changed the existing pair.'

        $heldReader = [IO.File]::Open($script:WindowsReceiptAuthorityPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            Assert-Throws { Publish-HerdrAuthorityReplacement @publish } 'Atomic authority pair move failed' 'held-reader rollback'
        }
        finally { $heldReader.Dispose() }
        Assert-True ((Get-HerdrAuthoritySha256 $script:WindowsReceiptPath) -ceq $oldReceiptHash -and
            (Get-HerdrAuthoritySha256 $script:WindowsReceiptAuthorityPath) -ceq $oldAuthorityHash) `
            'A concurrent held reader left a mixed or changed pair.'

        $movePair = ${function:Move-HerdrAuthorityPairTransaction}
        & {
            function Move-HerdrAuthorityPairTransaction {
                param($AuthorityPath, $ReceiptPath, $Stage, $Backup)
                Remove-Item -LiteralPath (Join-Path $Stage 'receipt-authority.json') -Force
                & $movePair -AuthorityPath $AuthorityPath -ReceiptPath $ReceiptPath -Stage $Stage -Backup $Backup
            }
            Assert-Throws { Publish-HerdrAuthorityReplacement @publish } 'Atomic authority pair move failed' 'fourth move rollback'
        }
        Assert-True ((Get-HerdrAuthoritySha256 $script:WindowsReceiptPath) -ceq $oldReceiptHash -and
            (Get-HerdrAuthoritySha256 $script:WindowsReceiptAuthorityPath) -ceq $oldAuthorityHash) `
            'Transaction rollback did not restore both original files.'
        Assert-True (@(Get-ChildItem -LiteralPath $target -Directory).Count -eq 0 -and
            @(Get-ChildItem -LiteralPath $root -Directory -Filter '.issue-961-replace-*').Count -eq 0) `
            'Failed replacement left a staged generation or backup.'
        $backup = Publish-HerdrAuthorityReplacement @publish
        Assert-True ((Split-Path -Parent $backup) -ceq $target -and
            (Split-Path -Leaf $backup) -cmatch '^backup-[0-9]{8}T[0-9]{13}Z-[0-9a-f]{32}$') 'Backup naming or protected location changed.'
        Assert-True ((Get-HerdrAuthoritySha256 (Join-Path $backup 'bootstrap-receipt.json')) -ceq $oldReceiptHash -and
            (Get-HerdrAuthoritySha256 (Join-Path $backup 'receipt-authority.json')) -ceq $oldAuthorityHash) `
            'Backup did not retain both exact previous files.'
        Assert-HerdrWindowsAuthority @check
        Assert-True ((Get-HerdrAuthoritySha256 $script:WindowsReceiptPath) -ceq (Get-HerdrStringSha256 ($newReceipt + "`n"))) `
            'Replacement did not publish the non-expiring receipt.'
        Assert-True ($script:fixtureProtected -ge 2 -and $script:fixtureOwnerChecks -ge 2 -and $script:fixtureAccessChecks -ge 2) `
            'Replacement skipped ACL protection or existing-pair validation calls.'
    }
    finally {
        $script:WindowsReceiptAuthorityPath = $savedAuthorityPath
        $script:WindowsReceiptPath = $savedReceiptPath
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}
Write-Host "Windows receipt-authority source and native transaction fixture tests passed: $script:assertionCount assertions."

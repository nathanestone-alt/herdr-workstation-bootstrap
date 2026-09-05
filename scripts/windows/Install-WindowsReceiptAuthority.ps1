#Requires -Version 7.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Check')][string]$Mode = 'Check',
    [string]$SourceRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedSourceCommit,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedPayloadManifestSha256,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedRoleAllowlistSha256,
    [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedProducerScriptSha256,
    [ValidatePattern('^HERDR-WIN\\rdp-natha$')][string]$RuntimeAccount = 'HERDR-WIN\rdp-natha',
    [ValidateSet('bash', 'gh', 'node', 'rtk')][string[]]$AdditionalRole = @(),
    [ValidatePattern('^C:\\ProgramData\\STModel\\Issue961\\receipt-authority[.]json$')]
    [string]$AuthorityPath = 'C:\ProgramData\STModel\Issue961\receipt-authority.json',
    [ValidatePattern('^C:\\ProgramData\\STModel\\Issue961\\bootstrap-receipt[.]json$')]
    [string]$ReceiptPath = 'C:\ProgramData\STModel\Issue961\bootstrap-receipt.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'HerdrReviewStaging.ps1')
. (Join-Path $PSScriptRoot 'HerdrHostOwnedAclPolicy.ps1')
. (Join-Path $PSScriptRoot 'WindowsReceiptAuthority.ps1')

if (-not $IsWindows) { throw 'The #961 Windows authority producer runs only on Windows.' }
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'The approved #961 Windows authority host architecture is x86_64.'
}
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'The #961 Windows authority producer requires an elevated administrator session.'
}
$source = Assert-HerdrAuthoritySafePath -Path $SourceRoot
$authority = Get-HerdrCanonicalPath -Path $AuthorityPath
$receipt = Get-HerdrCanonicalPath -Path $ReceiptPath
if ($authority -cne $script:WindowsReceiptAuthorityPath -or $receipt -cne $script:WindowsReceiptPath) {
    throw 'Production authority and receipt paths are fixed by the #961 contract.'
}
$runtimeSid = ([Security.Principal.NTAccount]::new($RuntimeAccount)).Translate([Security.Principal.SecurityIdentifier])
if ([string]::IsNullOrWhiteSpace($runtimeSid.Value)) { throw "Runtime account SID could not be resolved: '$RuntimeAccount'." }

if ($Mode -eq 'Check') {
    Assert-HerdrWindowsAuthority -AuthorityPath $authority -RuntimeSid $runtimeSid
    Write-Host "Windows #961 receipt authority check passed: $authority"
    exit 0
}

Assert-HerdrAuthorityHex -Value $ExpectedSourceCommit -Length 40 -Label 'ExpectedSourceCommit'
Assert-HerdrAuthorityHex -Value $ExpectedPayloadManifestSha256 -Length 64 -Label 'ExpectedPayloadManifestSha256'
Assert-HerdrAuthorityHex -Value $ExpectedRoleAllowlistSha256 -Length 64 -Label 'ExpectedRoleAllowlistSha256'
Assert-HerdrAuthorityHex -Value $ExpectedProducerScriptSha256 -Length 64 -Label 'ExpectedProducerScriptSha256'

$git = Get-HerdrAuthorityCommand -Name @('git.exe', 'git') -Label 'Git'
$actualCommit = Invoke-HerdrAuthorityCommand -Path $git.Path -ArgumentList @('-C', $source, 'rev-parse', 'HEAD') -Label 'Git source commit probe'
if ($actualCommit -cne $ExpectedSourceCommit) { throw "Source commit differs from commissioned commit: $actualCommit." }
$status = Invoke-HerdrAuthorityCommand -Path $git.Path -ArgumentList @('-C', $source, 'status', '--porcelain=v1', '--untracked-files=no') -Label 'Git source cleanliness probe'
if (-not [string]::IsNullOrWhiteSpace($status)) { throw 'Source checkout has tracked modifications; authority publication refused.' }

$manifestPath = Assert-HerdrAuthoritySafePath -Path (Join-Path $source 'config\payload-manifest.sha256')
$allowlistPath = Assert-HerdrAuthoritySafePath -Path (Join-Path $source 'config\receipt-authority-role-allowlist.txt')
$actualManifestSha256 = Get-HerdrAuthoritySha256 -Path $manifestPath
if ($actualManifestSha256 -cne $ExpectedPayloadManifestSha256) { throw 'Payload manifest differs from the independently commissioned SHA-256.' }
Test-HerdrPayloadManifest -PayloadRoot (Join-Path $source 'payload') -ManifestPath $manifestPath
$allowlistSha256 = Get-HerdrAuthoritySha256 -Path $allowlistPath
if ($allowlistSha256 -cne $ExpectedRoleAllowlistSha256) { throw 'Role allowlist differs from the independently commissioned SHA-256.' }
$producerScriptSha256 = Get-HerdrAuthoritySha256 -Path $MyInvocation.MyCommand.Path
if ($producerScriptSha256 -cne $ExpectedProducerScriptSha256) { throw 'Producer script differs from the independently commissioned SHA-256.' }
$definitions = Get-HerdrRoleDefinitions -AllowlistPath $allowlistPath
$roles = Get-HerdrRoleManifest -Definitions $definitions -RequiredRole (@('git', 'pwsh') + @($AdditionalRole)) -SourceCommit $actualCommit
$python = Get-HerdrPython313Identity
$uv = Get-HerdrUvIdentity
if ($python.version -cne '3.13.15') { throw "Commissioned CPython version must be 3.13.15, got '$($python.version)'." }
if ($uv.version -cnotmatch '^uv 0[.]12[.]5(?:\s|$)') { throw "Commissioned uv version must be 0.12.5, got '$($uv.version)'." }
$receiptValue = New-HerdrWindowsReceiptValues -SourceRoot $source -SourceCommit $actualCommit `
    -PayloadManifestSha256 $actualManifestSha256 -BridgeAllowlistSha256 $allowlistSha256 `
    -ReceiptPath $receipt -RuntimeAccount $RuntimeAccount -RuntimeSid $runtimeSid -Python313 $python -Uv $uv `
    -RoleIdentities $roles -ProducerScriptSha256 $producerScriptSha256
$receiptJson = ConvertTo-HerdrCanonicalJson -Value $receiptValue
Write-HerdrAuthorityAtomicFile -Path $receipt -Content $receiptJson -RuntimeSid $runtimeSid
$receiptSha256 = Get-HerdrAuthoritySha256 -Path $receipt
$authorityValue = New-HerdrWindowsAuthorityValue -Receipt $receiptValue -ReceiptPath $receipt -ReceiptSha256 $receiptSha256
$authorityJson = ConvertTo-HerdrCanonicalJson -Value $authorityValue
Write-HerdrAuthorityAtomicFile -Path $authority -Content $authorityJson -RuntimeSid $runtimeSid
Assert-HerdrWindowsAuthority -AuthorityPath $authority -RuntimeSid $runtimeSid
Write-Host "Windows #961 receipt authority installed: authority=$authority receipt=$receipt source=$actualCommit runtime_sid=$($runtimeSid.Value)"

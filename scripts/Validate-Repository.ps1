#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$failures = [Collections.Generic.List[string]]::new()

Get-ChildItem -LiteralPath $RepoRoot -Filter '*.ps1' -File -Recurse | ForEach-Object {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($parseError in $parseErrors) {
        $failures.Add("PowerShell syntax: $($_.FullName): $($parseError.Message)")
    }
}

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    Get-ChildItem -LiteralPath $RepoRoot -Filter '*.py' -File -Recurse | ForEach-Object {
        & $python.Source -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' $_.FullName
        if ($LASTEXITCODE -ne 0) { $failures.Add("Python syntax: $($_.FullName)") }
    }
} else {
    Write-Warning 'Python unavailable; skipped Python syntax validation.'
}

$bashCandidates = @(
    'C:\Program Files\Git\bin\bash.exe',
    (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
if ($bashCandidates) {
    $bash = $bashCandidates | Select-Object -First 1
    function Convert-ToBashPath([string]$Path) {
        if ($bash -like '*\Git\bin\bash.exe' -and $Path -match '^([A-Za-z]):\\(.*)$') {
            return '/' + $matches[1].ToLowerInvariant() + '/' + $matches[2].Replace('\', '/')
        }
        return $Path
    }
    Get-ChildItem -LiteralPath $RepoRoot -Filter '*.sh' -File -Recurse | ForEach-Object {
        $bashPath = Convert-ToBashPath -Path $_.FullName
        & $bash -n $bashPath
        if ($LASTEXITCODE -ne 0) { $failures.Add("Bash syntax: $($_.FullName)") }
    }
    foreach ($relativeTest in @(
        'tests\test-bootstrap-profile.sh',
        'tests\test-configure-excel-share-inputs.sh',
        'tests\test-configure-vps-client.sh',
        'tests\test-verify-vps-access.sh',
        'tests\test-verify-path.sh'
    )) {
        $testPath = Join-Path $RepoRoot $relativeTest
        & $bash (Convert-ToBashPath -Path $testPath)
        if ($LASTEXITCODE -ne 0) { $failures.Add("Behavioral regression test failed: $relativeTest") }
    }
} else {
    Write-Warning 'Bash unavailable; skipped Bash syntax validation.'
}
try {
    & (Join-Path $RepoRoot 'tests\Test-FirewallPolicy.ps1')
}
catch {
    $failures.Add("Behavioral regression test failed: tests\Test-FirewallPolicy.ps1 ($($_.Exception.Message))")
}
try {
    & (Join-Path $RepoRoot 'tests\Test-HostOwnedAclPolicy.ps1')
}
catch {
    $failures.Add("Behavioral regression test failed: tests\Test-HostOwnedAclPolicy.ps1 ($($_.Exception.Message))")
}
try {
    & (Join-Path $RepoRoot 'tests\Test-ExchangePathPolicy.ps1')
}
catch {
    $failures.Add("Behavioral regression test failed: tests\Test-ExchangePathPolicy.ps1 ($($_.Exception.Message))")
}
try {
    & (Join-Path $RepoRoot 'tests\Test-BootstrapVmDispatcher.ps1')
}
catch {
    $failures.Add("Behavioral regression test failed: tests\Test-BootstrapVmDispatcher.ps1 ($($_.Exception.Message))")
}

$requiredFiles = @(
    'scripts\windows\HerdrFirewallPolicy.ps1',
    'scripts\windows\HerdrHostOwnedAclPolicy.ps1',
    'scripts\windows\HerdrExchangePathPolicy.ps1',
    'scripts\windows\New-HerdrUbuntuVM.ps1',
    'scripts\windows\New-HerdrExchangeShare.ps1',
    'scripts\windows\Test-HerdrExchangeBoundary.ps1',
    'scripts\ubuntu\configure-excel-share.sh',
    'tests\test-bootstrap-profile.sh',
    'tests\test-configure-excel-share-inputs.sh',
    'tests\test-configure-vps-client.sh',
    'tests\test-verify-vps-access.sh',
    'tests\test-verify-path.sh',
    'tests\Test-FirewallPolicy.ps1',
    'tests\Test-ExchangePathPolicy.ps1',
    'tests\Test-BootstrapVmDispatcher.ps1',
    'tests\Test-HostOwnedAclPolicy.ps1',
    'config\ubuntu-toolchain.lock',
    'legacy\WSL2-FALLBACK.md'
)
foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $relativePath))) {
        $failures.Add("Required Hyper-V architecture file missing: $relativePath")
    }
}

$primaryFiles = @(
    'README.md',
    'MANUAL-START.md',
    'AGENT-HANDOFF.md',
    'REMOTE-ACCESS.md',
    'HERDR_WINDOWS_WORKSTATION_ARCHITECTURE.md',
    'HERDR_WORKSTATION_DEPENDENCY_SETUP_PLAN.md',
    'bootstrap.ps1',
    'herdr-workstation-build.html'
)
$stalePatterns = @(
    'WslInstall',
    'WslConfigure',
    'Ubuntu on WSL2',
    'inside Ubuntu WSL2',
    '/mnt/c/dev',
    'Register-UbuntuStartup',
    'wsl --install'
)
foreach ($relativePath in $primaryFiles) {
    $path = Join-Path $RepoRoot $relativePath
    $content = Get-Content -Raw -LiteralPath $path
    foreach ($pattern in $stalePatterns) {
        if ($content.Contains($pattern, [StringComparison]::OrdinalIgnoreCase)) {
            $failures.Add("Stale primary WSL instruction '$pattern': $relativePath")
        }
    }
}

# These are anti-deletion tripwires. Behavioral claims are covered by the
# executable regression tests above and by commissioning on the target host.
$contentAssertions = @(
    @{ Path = 'bootstrap.ps1'; Required = @("'VmComplete'", 'function Complete-UbuntuVm', '$vmParameters.InstallationComplete = $true', "'VmComplete'   { Complete-UbuntuVm }"); Forbidden = @() },
    @{ Path = 'scripts\windows\HerdrHostOwnedAclPolicy.ps1'; Required = @('Snapshot descendants before protecting the root', "'/inheritance:r'", "'/grant:r'", "'/remove'", 'S-1-5-18', 'S-1-5-32-544', '$OperatorSid.Value', 'Unexpected ACL entry'); Forbidden = @('AccessControlType]::Deny', 'S-1-5-11', "'/T'", "'/C'") },
    @{ Path = 'scripts\windows\New-HerdrExchangeShare.ps1'; Required = @('C:\HerdrTools', 'C:\HerdrReviewJobs', 'Resolve-HerdrExchangePath', '$AllowExistingSharePath', '.herdr-exchange-root', 'Protect-HostOwnedTree -TargetPath $toolsPathResolved', 'S-1-5-32-545', 'Add-LocalGroupMember', 'Get-NetConnectionProfile', 'Preflight found', 'AcceptedFirewallRule', 'LocalAddress', 'SetAccessRuleProtection($true, $false)', 'Get-NetFirewallPortFilter', 'Get-NetFirewallApplicationFilter', 'Get-NetFirewallServiceFilter', 'may belong only to the built-in Users group', 'Revoke-SmbShareAccess', 'Remove-NetFirewallRule', '-EncryptData $true', '-RotatePassword'); Forbidden = @('$Path\scripts', '-PasswordNeverExpires:$false', '$toolsPathResolved /remove:g', '$toolsPathResolved /inheritance:r') },
    @{ Path = 'scripts\windows\HerdrExchangePathPolicy.ps1'; Required = @('device namespace', 'local fixed drive', 'DriveType', 'protected system path', 'reparse point', 'ExistingManagedShare', 'AllowExistingUnmanagedPath'); Forbidden = @() },
    @{ Path = 'scripts\windows\Test-HerdrExchangeBoundary.ps1'; Required = @('-Credential $credential', '-WorkingDirectory "$env:SystemRoot\Temp"', 'C:\HerdrReviewJobs', 'AcceptedFirewallRule', 'LocalAddress', 'exit 41', 'exit 43', 'exit 44', 'exit 45', 'exit 46', 'Get-NetFirewallApplicationFilter', 'Get-NetFirewallServiceFilter', 'UnauthorizedAccessException', 'Boundary test passed'); Forbidden = @() },
    @{ Path = 'scripts\windows\Install-ExcelAutomation.ps1'; Required = @('C:\HerdrTools\excel-automation'); Forbidden = @('C:\HerdrExchange') },
    @{ Path = 'scripts\windows\Test-ExcelCom.py'; Required = @('C:\HerdrTools\excel-automation\smoke'); Forbidden = @('C:\HerdrExchange') },
    @{ Path = 'MANUAL-START.md'; Required = @('disposable workbook in `%USERPROFILE%\Documents`'); Forbidden = @('disposable workbook in `C:\HerdrExchange`') },
    @{ Path = 'HERDR_WORKSTATION_DEPENDENCY_SETUP_PLAN.md'; Required = @('disposable workbook in `%USERPROFILE%\Documents`', 'do not create `C:\HerdrExchange` before the guarded share step'); Forbidden = @() },
    @{ Path = 'scripts\windows\New-HerdrUbuntuVM.ps1'; Required = @('-InstallationComplete', 'Win32_ComputerSystem', 'HostProcessorReserve', 'HostMemoryReserveBytes', 'Orphan VHD', 'Get-VMSnapshot', '$existing.Path', 'residual configuration', 'Get-VHD -Path', 'New-VHD -Path', 'Remove-Item -LiteralPath $vhdPath', 'must be Off'); Forbidden = @('no changes were made') },
    @{ Path = 'scripts\ubuntu\bootstrap.sh'; Required = @('config/ubuntu-toolchain.lock', 'download_verified', 'converge_profile_hook', 'HERDR_PROFILE_CHAIN_ACTIVE', '$HOME/.bash_login', 'command -v "$executable"', 'cargo_install_root', '--prefix "$node_dir"', '$node_dir/lib/node_modules/$package_dir', '@openai/codex@$CODEX_VERSION', '@anthropic-ai/claude-code@$CLAUDE_VERSION', 'toolchain-manifest.txt'); Forbidden = @('curl -fsSL https://chatgpt.com/codex/install.sh | sh', 'curl -fsSL https://claude.ai/install.sh | bash', 'fnm install 24', 'rustup default stable') },
    @{ Path = 'scripts\ubuntu\configure-excel-share.sh'; Required = @('--owner', '--reassign-owner', 'nosharesock', 'Credential and live mount were not changed', 'replacement credential is installed', '# BEGIN herdr-bootstrap excel-share', 'unmanaged /etc/fstab entry', 'Mount point must be an absolute path', 'protected system path', 'direct /srv/herdr-* child', 'Refusing to change it', '$mount_point_exists', 'Windows host contains unsupported characters', 'SMB share name contains unsupported characters'); Forbidden = @() },
    @{ Path = 'scripts\ubuntu\configure-vps-client.sh'; Required = @('--host-key-fingerprint', 'recorded_fingerprints', 'ssh-keygen -R', 'ssh -G -F "$validation_config"', 'HERDR_SYSTEM_SSH_CONFIG', 'Include "%s"', 'IdentityFile "%s"', 'unsupported SSH configuration metacharacters', 'validate_managed_block_shape', 'validate_effective_alias', 'the client configuration was not changed', 'managed_blocks_dir', 'effective_identity_files', 'ClearAllForwardings yes', 'ForwardAgent no', 'ForwardX11 no', 'ForwardX11Trusted no', 'ControlMaster no', 'ControlPath none', 'GlobalKnownHostsFile none', 'ProxyCommand none', 'Host *', 'StrictHostKeyChecking yes', 'cmp -s', 'Host-key mismatch'); Forbidden = @('ssh -G -F "$replacement"', 'already exists in $config; no change made') },
    @{ Path = 'scripts\ubuntu\verify-vps-access.sh'; Required = @('OpenSSH could not resolve alias', 'VPS access was not attempted', '$1=""', 'effective IdentityFile'); Forbidden = @('ssh -G "$alias_name" 2>/dev/null') },
    @{ Path = 'scripts\ubuntu\verify.sh'; Required = @('PATH=/usr/bin:/bin HOME="$HOME" "$login_shell" -lc', 'PASS login command'); Forbidden = @('HERDR_VERIFY_TEST_MODE', 'HERDR_TEST_LOGIN_PROFILE') }
)
foreach ($assertion in $contentAssertions) {
    $assertionPath = Join-Path $RepoRoot $assertion.Path
    $assertionContent = Get-Content -Raw -LiteralPath $assertionPath
    foreach ($requiredText in $assertion.Required) {
        if (-not $assertionContent.Contains($requiredText, [StringComparison]::Ordinal)) {
            $failures.Add("Required remediation marker '$requiredText' missing: $($assertion.Path)")
        }
    }
    foreach ($forbiddenText in $assertion.Forbidden) {
        if ($assertionContent.Contains($forbiddenText, [StringComparison]::Ordinal)) {
            $failures.Add("Forbidden regressive marker '$forbiddenText': $($assertion.Path)")
        }
    }
}

$verifyContent = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'scripts\ubuntu\verify.sh')
$sanitizedLoginPrefix = 'PATH=/usr/bin:/bin HOME="$HOME" "$login_shell" -lc'
if ([regex]::Matches($verifyContent, [regex]::Escape($sanitizedLoginPrefix)).Count -ne 2) {
    $failures.Add('verify.sh must sanitize PATH independently at both login-shell call sites.')
}

Get-ChildItem -LiteralPath $RepoRoot -File -Recurse | Where-Object {
    $_.FullName -notlike "$(Join-Path $RepoRoot '.git')*" -and
    $_.Extension -in @('.md', '.ps1', '.py', '.sh', '.txt', '.env', '.html', '.lock')
} | ForEach-Object {
    $text = Get-Content -Raw -LiteralPath $_.FullName
    if ($text -match '(?:\r?\n){2,}\z') {
        $failures.Add("Extra blank line at EOF: $($_.FullName)")
    }
}

$forbidden = @('auth.json', 'credentials.json', 'id_ed25519', 'id_rsa', 'known_hosts')
Get-ChildItem -LiteralPath $RepoRoot -File -Recurse | Where-Object { $_.Name -in $forbidden } | ForEach-Object {
    $failures.Add("Forbidden credential-like file: $($_.FullName)")
}

if ($failures.Count) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "Repository validation failed with $($failures.Count) issue(s)."
}
Write-Host 'Repository validation passed.'

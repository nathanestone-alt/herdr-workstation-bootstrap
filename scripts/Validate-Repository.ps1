#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$RunPayloadRegression
)

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
        'tests\test-bootstrap-fencing.sh',
        'tests\test-bootstrap-privilege-model.sh',
        'tests\test-configure-excel-share-inputs.sh',
        'tests\test-configure-vps-client.sh',
        'tests\test-verify-vps-access.sh',
        'tests\test-verify-path.sh',
        'tests\test-rtk-release.sh',
        'tests\test-python-toolchain.sh',
        'tests\test-codex-update-policy.sh',
        'tests\test-bootstrap-tools.sh',
        'tests\test-receipt-authority.sh',
        'tests\test-tailscale-downgrade.sh',
        'tests\test-trusted-launcher.sh',
        'tests\test-install-payload.sh'
    )) {
        if (-not $IsLinux) {
            Write-Host "SKIP: $relativeTest requires a Linux Ubuntu execution environment."
            continue
        }
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
    & (Join-Path $RepoRoot 'tests\Test-HerdrReviewStaging.ps1')
}
catch {
    $failures.Add("Behavioral regression test failed: tests\Test-HerdrReviewStaging.ps1 ($($_.Exception.Message))")
}
try {
    & (Join-Path $RepoRoot 'tests\Test-HerdrExcelJobRunner.ps1')
}
catch {
    $failures.Add("Behavioral regression test failed: tests\Test-HerdrExcelJobRunner.ps1 ($($_.Exception.Message))")
}
try {
    & (Join-Path $RepoRoot 'tests\Test-HerdrWindowsSecurityIntegration.ps1')
}
catch {
    $failures.Add("Behavioral regression test failed: tests\Test-HerdrWindowsSecurityIntegration.ps1 ($($_.Exception.Message))")
}
try {
    & (Join-Path $RepoRoot 'tests\Test-BootstrapVmDispatcher.ps1')
}
catch {
    $failures.Add("Behavioral regression test failed: tests\Test-BootstrapVmDispatcher.ps1 ($($_.Exception.Message))")
}

$payloadRegressionTests = @(
    'payload\agents-skills\herdr-coordination\scripts\test_claude_session_refresh.ps1',
    'payload\agents-skills\herdr-coordination\scripts\test_codex_session_refresh.ps1',
    'payload\agents-skills\herdr-coordination\scripts\test_herdr_coordination.ps1',
    'payload\agents-skills\herdr-coordination\scripts\test_herdr_naming_lifecycle.ps1',
    'payload\agents-skills\herdr-coordination\scripts\test_herdr_pane_registry.ps1',
    'payload\agents-skills\herdr-coordination\scripts\test_herdr_pane_registry_cli.ps1',
    'payload\agents-skills\herdr-coordination\scripts\test_herdr_skill_compatibility.ps1',
    'payload\agents-skills\herdr-coordination\scripts\test_herdr_workflow.ps1',
    'payload\agents-skills\herdr-coordination\scripts\test_herdr_workflow_stress.ps1',
    'payload\agents-skills\st-herdr-dispatch\scripts\test_st_herdr_dispatch.ps1'
)
foreach ($relativeTest in $payloadRegressionTests) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $relativeTest))) {
        $failures.Add("Reconciled payload regression test missing: $relativeTest")
    }
}
if ($RunPayloadRegression) {
    if (-not $IsWindows) {
        $failures.Add('Payload behavioral regression suites require their Windows-only fixture runtime; use the static validator on Ubuntu and run -RunPayloadRegression on Windows.')
    }
    else {
        foreach ($relativeTest in $payloadRegressionTests) {
            try {
                & (Join-Path $RepoRoot $relativeTest)
            }
            catch {
                $failures.Add("Payload behavioral regression test failed: $relativeTest ($($_.Exception.Message))")
            }
        }
    }
}

$requiredFiles = @(
    'scripts\windows\HerdrFirewallPolicy.ps1',
    'scripts\windows\HerdrHostOwnedAclPolicy.ps1',
    'scripts\windows\HerdrExchangePathPolicy.ps1',
    'scripts\windows\HerdrReviewStaging.ps1',
    'scripts\windows\Stage-HerdrReviewWorkbook.ps1',
    'scripts\windows\HerdrExcelJobRunner.ps1',
    'scripts\windows\Invoke-HerdrExcelJob.ps1',
    'scripts\windows\New-HerdrUbuntuVM.ps1',
    'scripts\windows\New-HerdrExchangeShare.ps1',
    'scripts\windows\Test-HerdrExchangeBoundary.ps1',
    'scripts\ubuntu\configure-excel-share.sh',
    'scripts\ubuntu\receipt-authority.sh',
    'scripts\ubuntu\rtk-release.sh',
    'scripts\ubuntu\source-attestation.sh',
    'scripts\ubuntu\launcher-capability.sh',
    'scripts\ubuntu\trusted-launcher.sh',
    'scripts\ubuntu\install-trusted-launcher.sh',
    'config\bootstrap-policy.example',
    'docs\bootstrap-trust-anchor.md',
    'tests\test-bootstrap-profile.sh',
    'tests\test-bootstrap-fencing.sh',
    'tests\test-bootstrap-privilege-model.sh',
    'tests\test-configure-excel-share-inputs.sh',
    'tests\test-configure-vps-client.sh',
    'tests\test-verify-vps-access.sh',
    'tests\test-verify-path.sh',
    'tests\test-rtk-release.sh',
    'tests\test-codex-update-policy.sh',
    'tests\test-bootstrap-tools.sh',
    'tests\Test-FirewallPolicy.ps1',
    'tests\Test-ExchangePathPolicy.ps1',
    'tests\Test-HerdrReviewStaging.ps1',
    'tests\Test-HerdrExcelJobRunner.ps1',
    'tests\Test-HerdrWindowsSecurityIntegration.ps1',
    'tests\Test-BootstrapVmDispatcher.ps1',
    'tests\Test-HostOwnedAclPolicy.ps1',
    'config\ubuntu-toolchain.lock',
    'config\receipt-authority-role-allowlist.txt',
    'config\payload-manifest.sha256',
    'tests\test-python-toolchain.sh',
    'tests\test-receipt-authority.sh',
    'tests\test-tailscale-downgrade.sh',
    'tests\test-trusted-launcher.sh',
    'tests\test-install-payload.sh',
    'legacy\WSL2-FALLBACK.md'
)
foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $relativePath))) {
        $failures.Add("Required Hyper-V architecture file missing: $relativePath")
    }
}

$payloadManifestPath = Join-Path $RepoRoot 'config\payload-manifest.sha256'
$payloadRoot = Join-Path $RepoRoot 'payload'
$manifestEntries = [Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath $payloadManifestPath) {
    $manifestLineNumber = 0
    foreach ($line in Get-Content -LiteralPath $payloadManifestPath) {
        $manifestLineNumber++
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#', [StringComparison]::Ordinal)) { continue }
        if ($line -notmatch '^([0-9a-f]{64})  ([A-Za-z0-9._/-]+)$') {
            $failures.Add("Payload manifest syntax: line $manifestLineNumber")
            continue
        }
        $relativePayloadHash = $matches[1]
        $relativePayloadPath = $matches[2]
        if ($relativePayloadPath -notmatch '^(agents-skills|claude-skills)/' -or $relativePayloadPath.Contains('..')) {
            $failures.Add("Payload manifest path is outside the installable roots: $relativePayloadPath")
            continue
        }
        if ($manifestEntries.Path -contains $relativePayloadPath) {
            $failures.Add("Duplicate payload manifest path: $relativePayloadPath")
            continue
        }
        $manifestEntries.Add([pscustomobject]@{ Hash = $relativePayloadHash; Path = $relativePayloadPath })
    }
    $manifestPaths = @($manifestEntries | ForEach-Object Path)
    for ($index = 1; $index -lt $manifestPaths.Count; $index++) {
        if ([string]::CompareOrdinal($manifestPaths[$index - 1], $manifestPaths[$index]) -ge 0) {
            $failures.Add('Payload manifest paths are not strictly sorted.')
            break
        }
    }
    $filesystemPaths = @(
        foreach ($payloadSubtree in @('agents-skills', 'claude-skills')) {
            $payloadSubtreePath = Join-Path $payloadRoot $payloadSubtree
            if (-not (Test-Path -LiteralPath $payloadSubtreePath -PathType Container)) {
                $failures.Add("Installable payload root missing: $payloadSubtree")
                continue
            }
            Get-ChildItem -LiteralPath $payloadSubtreePath -File -Recurse | ForEach-Object {
                $_.FullName.Substring($payloadRoot.Length + 1).Replace('\', '/')
            }
        }
    ) | Sort-Object
    $manifestComparison = Compare-Object -ReferenceObject $manifestPaths -DifferenceObject $filesystemPaths
    if ($manifestComparison) {
        $failures.Add('Payload manifest paths do not exactly match the installable payload filesystem.')
    }
    foreach ($manifestEntry in $manifestEntries) {
        $manifestFilePath = Join-Path $payloadRoot ($manifestEntry.Path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $manifestFilePath -PathType Leaf)) {
            $failures.Add("Payload manifest file missing: $($manifestEntry.Path)")
            continue
        }
        $actualPayloadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestFilePath).Hash.ToLowerInvariant()
        if ($actualPayloadHash -cne $manifestEntry.Hash) {
            $failures.Add("Payload manifest hash mismatch: $($manifestEntry.Path)")
        }
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
    @{ Path = 'scripts\windows\HerdrReviewStaging.ps1'; Required = @('Offline', 'RecallOnOpen', 'RecallOnDataAccess', 'FileShare]::None', 'SHA256', 'herdr-review-staging-v1', 'stability_interval_milliseconds', 'source_preserved', 'FileFlagOpenReparsePoint', 'GetFinalPathNameByHandleW', 'NumberOfLinks', 'TrustedDestinationRoot', 'ExpectedRoot', 'herdr-windows-review-runtime-v1', 'HERDR_WINDOWS_REVIEW_CONFIG', 'one_drive_exchange_root', 'review_jobs_root', 'Test-HerdrCloudFilesReparseTag', 'Assert-HerdrAllowedReparsePoint', 'Cloud Files file leaf is permitted only inside the explicit', 'Assert-HerdrAllowedReparsePoint -ReparseTag $ReparseTag -IsDirectory:$false', 'Assert-HerdrAllowedReparsePoint -ReparseTag ([uint32]$identity.ReparseTag) -IsDirectory:$false', 'Open-HerdrNativeReadFile -Path $canonicalPath -AllowedCloudFilesRoot $AllowedCloudFilesRoot', 'Open-HerdrNativeReadFile -Path $source -AllowedCloudFilesRoot $SourceAllowedCloudFilesRoot', '-ReparseTag ([uint32]$proof.Leaf.ReparseTag)', 'allowCloudFilesReparsePoint'); Forbidden = @('Invoke-Expression', 'Start-Process', 'USERPROFILE') },
    @{ Path = 'tests\Test-HerdrReviewStaging.ps1'; Required = @('Fully hydrated Cloud Files attributes must not block ReparsePoint.', 'Cloud Files ReparsePoint must remain blocked without an allowed boundary.', 'Cloud Files ReparsePoint must remain blocked outside the allowed boundary.', 'Unrecognized reparse tags must remain blocked by the hydration filter.', 'Managed-directory trusted-root proof does not propagate the Cloud Files boundary.', 'Snapshot native reads do not propagate the Cloud Files boundary.', 'Copy native reads do not propagate the source Cloud Files boundary.', 'Runner JSON native reads do not preserve explicit Cloud Files boundary plumbing.'); Forbidden = @() },
    @{ Path = 'tests\Test-HerdrWindowsPathPolicy.ps1'; Required = @('Cloud Files file acceptance beneath its configured boundary failed.', 'Ensure-HerdrManagedDirectory Cloud Files fixture failed.', 'DirectoryExpected', 'FileExpected'); Forbidden = @() },
    @{ Path = 'scripts\windows\Stage-HerdrReviewWorkbook.ps1'; Required = @('RuntimeConfigurationPath', 'StabilityIntervalMilliseconds', 'Invoke-HerdrReviewStaging', 'HERDR_STAGING_FAILED'); Forbidden = @('Invoke-Expression', 'Start-Process', 'C:\HerdrExchange', 'C:\HerdrReviewJobs') },
    @{ Path = 'scripts\windows\HerdrExcelJobRunner.ps1'; Required = @('herdr-excel-job-v1', "-cne 'recalculate'", 'AutomationSecurity = 3', 'AskToUpdateLinks = $false', 'EnableRefresh = $false', 'RefreshOnFileOpen = $false', 'SaveCopyAs', '$excel.Calculate()', 'HerdrBridge', 'Assert-HerdrBridgeCannotWrite', 'HerdrHostOwnedAclPolicy.ps1', 'HostOwnedTreeProtector', 'Protect-HostOwnedTree -TargetPath $reviewJobPath', 'OneDriveOutboxRoot', 'OneDriveArchiveRoot', 'HERDR_DESIGNATED_INTERACTIVE_USER_SID', 'HERDR_BRIDGE_ACCOUNT_SID', 'HERDR_WINDOWS_REVIEW_CONFIG', 'Get-HerdrRuntimeConfiguration', 'Assert-HerdrOneDriveReady', 'Get-HerdrProcessIdentityProof', 'Assert-HerdrExcelProcessIdentity', 'TrustedDestinationRoot', 'canonical_workbook_mutated', 'trusted_locations', 'Open-HerdrNativeReadFile -Path $Path -AllowedCloudFilesRoot $AllowedCloudFilesRoot'); Forbidden = @('Invoke-Expression', 'Start-Process', 'RefreshAll', 'RunAutoMacros', 'TrustedLocation', '$workbook.Calculate()', 'C:\HerdrExchange', 'C:\HerdrReviewJobs', 'USERPROFILE') },
    @{ Path = 'scripts\windows\Invoke-HerdrExcelJob.ps1'; Required = @('RuntimeConfigurationPath', 'Invoke-HerdrExcelJob', 'HERDR_EXCEL_JOB_FAILED'); Forbidden = @('Invoke-Expression', 'Start-Process', 'BridgeAccount', 'C:\HerdrExchange', 'C:\HerdrReviewJobs') },
    @{ Path = 'tests\Test-HerdrExcelJobRunner.ps1'; Required = @('Review-job bridge ACL assertion ran before host-owned protection.', 'Review-job host-owned protection was not invoked.', 'HostOwnedTreeProtector', 'Protect-HostOwnedTree -TargetPath $reviewJobPath', 'Workbook-level Calculate is invalid and must not return.', 'Application-level Excel calculation call or ordering is missing.'); Forbidden = @() },
    @{ Path = 'tests\Test-HerdrWindowsSecurityIntegration.ps1'; Required = @('SKIP:', 'RunspaceFactory', 'PowerShell]::Create()', 'control-after-race', 'HardLink', 'Junction', 'HERDR_RUN_EXCEL_CANARY', 'Auto_Open', 'RefreshOnFileOpen', 'identity substitution', 'last-mile tamper', 'nested-group write grant', 'directory identity swap', 'destination directory boundary', 'atomic output boundary'); Forbidden = @('C:\HerdrExchange\scripts', 'Invoke-Expression', 'Start-Process') },
    @{ Path = 'scripts\windows\Test-HerdrExchangeBoundary.ps1'; Required = @('-Credential $credential', '-WorkingDirectory "$env:SystemRoot\Temp"', 'C:\HerdrReviewJobs', 'AcceptedFirewallRule', 'LocalAddress', 'exit 41', 'exit 43', 'exit 44', 'exit 45', 'exit 46', 'Get-NetFirewallApplicationFilter', 'Get-NetFirewallServiceFilter', 'UnauthorizedAccessException', 'Boundary test passed'); Forbidden = @() },
    @{ Path = 'scripts\windows\Install-ExcelAutomation.ps1'; Required = @('C:\HerdrTools\excel-automation'); Forbidden = @('C:\HerdrExchange') },
    @{ Path = 'scripts\windows\Test-ExcelCom.py'; Required = @('C:\HerdrTools\excel-automation\smoke'); Forbidden = @('C:\HerdrExchange') },
    @{ Path = 'MANUAL-START.md'; Required = @('disposable workbook in `%USERPROFILE%\Documents`', 'HERDR_WINDOWS_REVIEW_CONFIG'); Forbidden = @('disposable workbook in `C:\HerdrExchange`', 'C:\HerdrReviewJobs') },
    @{ Path = 'HERDR_WORKSTATION_DEPENDENCY_SETUP_PLAN.md'; Required = @('disposable workbook in `%USERPROFILE%\Documents`', 'HERDR_WINDOWS_REVIEW_CONFIG', 'SSH to `herdr-win`'); Forbidden = @('do not create `C:\HerdrExchange` before the guarded share step', 'C:\HerdrReviewJobs') },
    @{ Path = 'scripts\windows\New-HerdrUbuntuVM.ps1'; Required = @('-InstallationComplete', 'Win32_ComputerSystem', 'HostProcessorReserve', 'HostMemoryReserveBytes', 'Orphan VHD', 'Get-VMSnapshot', '$existing.Path', 'residual configuration', 'Get-VHD -Path', 'New-VHD -Path', 'Remove-Item -LiteralPath $vhdPath', 'must be Off'); Forbidden = @('no changes were made') },
    @{ Path = 'scripts\ubuntu\bootstrap.sh'; Required = @('#!/usr/bin/env -S -i BASH_ENV=', 'config/ubuntu-toolchain.lock', 'UV_VERSION', 'RTK_VERSION', 'RTK_URL', 'RTK_SHA256', 'attestation_create_git_snapshot', 'bootstrap_private_helper', 'bootstrap_trust_fail', 'attestation_canonical_cargo', 'rtk-release.sh', 'rtk_release_install_archive', 'install_receipt_from_snapshots', 'install_python_toolchain', 'write_py_compat', 'download_verified', 'bootstrap_exec_system', 'bootstrap_exec_privileged', 'bootstrap_run_as_runtime_phase', 'bootstrap_root_mode', 'base-user', 'tools-prepare', 'tools-finalize', 'bootstrap_exec_python', 'bootstrap_exec_node', 'bootstrap_exec_cargo', 'launcher-capability.sh', 'launcher_capability_lifetime', 'launcher_capability_policy_commit', 'apt_get_path=/usr/bin/apt-get', 'exec 8<', '/usr/bin/curl', '/usr/bin/sha256sum', 'converge_profile_hook', 'HERDR_PROFILE_CHAIN_ACTIVE', '$HOME/.bash_login', '$HOME/.cargo/bin/$executable', 'cargo_install_root', '--prefix "$node_anchor"', '$node_anchor/lib/node_modules/$package_dir', '@openai/codex@$CODEX_VERSION', '@anthropic-ai/claude-code@$CLAUDE_VERSION', 'toolchain-manifest.txt', 'py_3.13_probe'); Forbidden = @('HERDR_BOOTSTRAP_TRUSTED_LAUNCHER', 'HERDR_BOOTSTRAP_VERIFIED_ENTRYPOINT', 'HERDR_BOOTSTRAP_REPO_ROOT', 'HERDR_BOOTSTRAP_GIT_OWNER_UID', 'HERDR_BOOTSTRAP_GIT_OWNER_GID', 'HERDR_BOOTSTRAP_TEST_MODE', 'HERDR_BOOTSTRAP_TEST_SUDO', 'HERDR_BOOTSTRAP_TEST_APT_GET', 'HERDR_BOOTSTRAP_TEST_SYSTEMCTL', 'HERDR_BOOTSTRAP_TEST_TAILSCALE', 'RTK_REPO_URL', 'RTK_REF', 'install_rtk_snapshot', 'cargo install --path', 'curl -fsSL https://chatgpt.com/codex/install.sh | sh', 'curl -fsSL https://claude.ai/install.sh | bash', 'fnm install 24', 'rustup default stable') },
    @{ Path = 'scripts\ubuntu\rtk-release.sh'; Required = @('#!/usr/bin/bash', 'rtk_release_install_archive', 'after-rtk-archive-bind', 'before-rtk-publish', '--quoting-style=c', '--no-recursion', '--no-same-owner', '--no-same-permissions', 'archive.tar.gz', 'RTK version mismatch', 'RTK target was replaced during publication'); Forbidden = @('RTK_REPO_URL', 'RTK_REF', 'cargo install', 'git clone', 'git fetch') },
    @{ Path = 'scripts\ubuntu\receipt-authority.sh'; Required = @('#!/usr/bin/env -S -i BASH_ENV=', 'launcher-capability.sh', 'launcher_capability_lifetime', 'launcher_capability_policy_commit', 'receipt_materialize_helper_from_git', 'receipt_materialize_helper_from_payload', 'receipt_private_helper', 'receipt_trust_fail', 'receipt_canonical_git_storage_path', 'receipt_stage_executable', 'receipt_assert_source_identity', 'receipt_cleanup', 'receipt_exec_python_unprivileged', 'PYTHONSAFEPATH=1', 'receipt_bind_git_layout', 'receipt_assert_git_lifetime', 'RTK_VERSION', 'RTK_URL', 'RTK_SHA256', 'rtk_release_json', '.rtk_release', '--payload-manifest-sha256', '--source-commit'); Forbidden = @('HERDR_BOOTSTRAP_TRUSTED_LAUNCHER', 'HERDR_RECEIPT_TRUSTED_LAUNCHER', 'HERDR_RECEIPT_VERIFIED_PAYLOAD', 'HERDR_RECEIPT_GIT_OWNER_UID', 'HERDR_RECEIPT_GIT_OWNER_GID', 'HERDR_BOOTSTRAP_TEST_MODE', 'HERDR_BOOTSTRAP_TEST_SUDO', 'HERDR_BOOTSTRAP_TEST_APT_GET', 'RTK_REPO_URL', 'RTK_REF', 'rtk_source', '--rtk-source') },
    @{ Path = 'scripts\ubuntu\source-attestation.sh'; Required = @('#!/usr/bin/bash', 'attestation_register_temporary_path', 'attestation_cleanup_temporary_paths', 'attestation_snapshot_abort', 'attestation_validate_git_layout', 'attestation_bind_git_layout', 'attestation_assert_git_lifetime', 'attestation_verify_payload_manifest', 'attestation_canonical_cargo'); Forbidden = @() },
    @{ Path = 'scripts\ubuntu\trusted-launcher.sh'; Required = @('herdr-bootstrap-policy-v1', 'canonical_origin', 'policy_lifetime', 'GIT_OPTIONAL_LOCKS=0', 'protocol.file.allow=always', 'hash-object', 'exec 9<', 'exec 10<', 'exec 11<', 'launcher_fixture_receipt_pause_phase', 'HERDR_BOOTSTRAP_RUNTIME_UID', 'HERDR_BOOTSTRAP_RUNTIME_GID', 'HERDR_BOOTSTRAP_RUNTIME_HOME', '/usr/bin/setpriv', '--clear-groups', '--no-new-privs'); Forbidden = @('HERDR_BOOTSTRAP_TRUSTED_LAUNCHER', 'HERDR_BOOTSTRAP_VERIFIED_ENTRYPOINT', 'HERDR_RECEIPT_TRUSTED_LAUNCHER', 'HERDR_VERIFY_TRUSTED_LAUNCHER', 'git -C "$PWD"', 'source "$HOME') },
    @{ Path = 'scripts\ubuntu\install-trusted-launcher.sh'; Required = @('out-of-band', '--run-as-user', '--commit', '--re-pin', 'git_safe', 'protocol.file.allow=always', 'cat-file blob', 'atomic', 'bootstrap-policy.conf', 'herdr-bootstrap-policy-v1', '"$mv_bin" -T', '/usr/bin/gawk'); Forbidden = @('--source-root', 'installer_validate_git_layout', 'curl -fsSL', 'sudo sh', 'git rev-parse') },
    @{ Path = 'scripts\ubuntu\configure-excel-share.sh'; Required = @('--owner', '--reassign-owner', 'nosharesock', 'Credential and live mount were not changed', 'replacement credential is installed', '# BEGIN herdr-bootstrap excel-share', 'unmanaged /etc/fstab entry', 'Mount point must be an absolute path', 'protected system path', 'direct /srv/herdr-* child', 'Refusing to change it', '$mount_point_exists', 'Windows host contains unsupported characters', 'SMB share name contains unsupported characters'); Forbidden = @() },
    @{ Path = 'scripts\ubuntu\configure-vps-client.sh'; Required = @('--host-key-fingerprint', 'recorded_fingerprints', 'ssh-keygen -R', 'ssh -G -F "$validation_config"', 'HERDR_SYSTEM_SSH_CONFIG', 'Include "%s"', 'IdentityFile "%s"', 'unsupported SSH configuration metacharacters', 'validate_managed_block_shape', 'validate_effective_alias', 'the client configuration was not changed', 'managed_blocks_dir', 'effective_identity_files', 'ClearAllForwardings yes', 'ForwardAgent no', 'ForwardX11 no', 'ForwardX11Trusted no', 'ControlMaster no', 'ControlPath none', 'GlobalKnownHostsFile none', 'ProxyCommand none', 'Host *', 'StrictHostKeyChecking yes', 'cmp -s', 'Host-key mismatch'); Forbidden = @('ssh -G -F "$replacement"', 'already exists in $config; no change made') },
    @{ Path = 'scripts\ubuntu\verify-vps-access.sh'; Required = @('OpenSSH could not resolve alias', 'VPS access was not attempted', '$1=""', 'effective IdentityFile'); Forbidden = @('ssh -G "$alias_name" 2>/dev/null') },
    @{ Path = 'scripts\ubuntu\verify.sh'; Required = @('PATH=/usr/bin:/bin HOME="$HOME" "$login_shell" -lc', 'launcher-capability.sh', 'launcher_capability_lifetime', 'launcher_capability_policy_commit', 'validate_toolchain_lock', 'verify_main', 'verify_resolve_command', 'verify_system_command_path', 'verify_bootstrap_materialized_oid', 'verify_validate_git_layout', 'verify_assert_git_lifetime', 'export PATH="$verify_trusted_path"', 'python3.13', '--list', 'toolchain-manifest.txt', 'PASS login command'); Forbidden = @('HERDR_VERIFY_TRUSTED_LAUNCHER', 'HERDR_VERIFY_VERIFIED_ENTRYPOINT', 'HERDR_VERIFY_REPO_ROOT', 'HERDR_VERIFY_GIT_OWNER_UID', 'HERDR_VERIFY_GIT_OWNER_GID', 'HERDR_VERIFY_ENTRYPOINT_TEMP', 'HERDR_VERIFY_TEST_MODE', 'HERDR_TEST_LOGIN_PROFILE', 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin') },
    @{ Path = 'scripts\ubuntu\install-payload.sh'; Required = @('config/payload-manifest.sha256', 'ensure_source_clean', 'validate_payload_manifest', 'verify_installed_payload', 'payload-runtime-receipt.txt', 'previous destinations were restored', 'regression_test_count'); Forbidden = @('cp -a "$payload"') }
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

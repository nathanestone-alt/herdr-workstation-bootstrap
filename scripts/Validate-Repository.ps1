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
    Get-ChildItem -LiteralPath $RepoRoot -Filter '*.sh' -File -Recurse | ForEach-Object {
        $bashPath = $_.FullName
        if ($bash -like '*\Git\bin\bash.exe' -and $bashPath -match '^([A-Za-z]):\\(.*)$') {
            $bashPath = '/' + $matches[1].ToLowerInvariant() + '/' + $matches[2].Replace('\', '/')
        }
        & $bash -n $bashPath
        if ($LASTEXITCODE -ne 0) { $failures.Add("Bash syntax: $($_.FullName)") }
    }
} else {
    Write-Warning 'Bash unavailable; skipped Bash syntax validation.'
}

$requiredFiles = @(
    'scripts\windows\New-HerdrUbuntuVM.ps1',
    'scripts\windows\New-HerdrExchangeShare.ps1',
    'scripts\ubuntu\configure-excel-share.sh',
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

$forbidden = @('auth.json', 'credentials.json', 'id_ed25519', 'id_rsa', 'known_hosts')
Get-ChildItem -LiteralPath $RepoRoot -File -Recurse | Where-Object { $_.Name -in $forbidden } | ForEach-Object {
    $failures.Add("Forbidden credential-like file: $($_.FullName)")
}

if ($failures.Count) {
    $failures | ForEach-Object { Write-Error $_ }
    throw "Repository validation failed with $($failures.Count) issue(s)."
}
Write-Host 'Repository validation passed.'

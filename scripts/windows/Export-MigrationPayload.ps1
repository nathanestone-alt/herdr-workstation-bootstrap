[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
$Destination = [IO.Path]::GetFullPath($Destination)
$UserHome = [Environment]::GetFolderPath('UserProfile')
$allowlist = @(
    @{ Source = Join-Path $UserHome '.agents\skills\herdr'; Target = 'agents-skills\herdr' },
    @{ Source = Join-Path $UserHome '.agents\skills\herdr-coordination'; Target = 'agents-skills\herdr-coordination' },
    @{ Source = Join-Path $UserHome '.agents\skills\st-herdr-dispatch'; Target = 'agents-skills\st-herdr-dispatch' },
    @{ Source = Join-Path $UserHome '.claude\skills\grill-with-docs-stmodel'; Target = 'claude-skills\grill-with-docs-stmodel' },
    @{ Source = Join-Path $UserHome '.claude\skills\tier1'; Target = 'claude-skills\tier1' },
    @{ Source = Join-Path $UserHome '.claude\skills\wait-what'; Target = 'claude-skills\wait-what' }
)
$blockedNames = @('auth.json', 'credentials.json', 'id_ed25519', 'id_rsa', 'known_hosts')

foreach ($item in $allowlist) {
    if (-not (Test-Path -LiteralPath $item.Source)) {
        Write-Warning "Missing: $($item.Source)"
        continue
    }
    $target = Join-Path $Destination $item.Target
    if ($PSCmdlet.ShouldProcess($item.Source, "copy reviewed skill source to $target")) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Get-ChildItem -LiteralPath $item.Source -File -Recurse | Where-Object {
            $_.Name -notin $blockedNames -and $_.FullName -notmatch '\\(cache|sessions|logs|tmp)\\'
        } | ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($item.Source, $_.FullName)
            $output = Join-Path $target $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $output -Force
        }
    }
}

$publicKey = Join-Path $UserHome '.ssh\id_ed25519.pub'
if (Test-Path -LiteralPath $publicKey) {
    $target = Join-Path $Destination 'reference\surface-id_ed25519.pub'
    if ($PSCmdlet.ShouldProcess($publicKey, "copy public key to $target")) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $publicKey -Destination $target -Force
    }
}
Write-Host 'Export complete. Review every file before overriding .gitignore. No private key or authentication file is allowlisted.'


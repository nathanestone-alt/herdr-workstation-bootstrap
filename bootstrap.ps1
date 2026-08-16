#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Status', 'WindowsBase', 'WslInstall', 'WslConfigure', 'Excel')]
    [string]$Stage = 'Status'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$RepoRoot = $PSScriptRoot

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-Administrator)) {
        throw 'This stage changes Windows and must be run from an elevated PowerShell 7 window.'
    }
}

function Get-CommandState([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Install-WingetPackage([string]$Id) {
    $installed = winget list --id $Id --exact --accept-source-agreements 2>$null
    if ($LASTEXITCODE -eq 0 -and ($installed -join "`n") -match [regex]::Escape($Id)) {
        Write-Host "Already installed: $Id"
        return
    }
    Write-Host "Installing: $Id"
    winget install --id $Id --exact --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) { throw "winget failed for $Id (exit $LASTEXITCODE)" }
}

function Backup-AndCopy([string]$Source, [string]$Destination) {
    if (Test-Path -LiteralPath $Destination) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $Destination -Destination "$Destination.$stamp.bak"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Show-Status {
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $disk = Get-Volume -DriveLetter C -ErrorAction SilentlyContinue
    $activation = Get-CimInstance SoftwareLicensingProduct |
        Where-Object { $_.PartialProductKey -and $_.Name -like 'Windows*' } |
        Select-Object -First 1 Name, LicenseStatus
    $distros = @(& wsl.exe --list --quiet 2>$null) | ForEach-Object { $_ -replace "`0", '' } | Where-Object { $_.Trim() }

    [pscustomobject]@{
        ComputerName       = $env:COMPUTERNAME
        Windows            = $os.Caption
        WindowsVersion     = $os.Version
        Architecture       = $os.OSArchitecture
        MemoryGB           = [math]::Round($computer.TotalPhysicalMemory / 1GB, 1)
        LogicalProcessors  = $computer.NumberOfLogicalProcessors
        CDriveSizeGB       = if ($disk) { [math]::Round($disk.Size / 1GB, 1) } else { $null }
        CDriveFreeGB       = if ($disk) { [math]::Round($disk.SizeRemaining / 1GB, 1) } else { $null }
        Activation         = if ($activation) { "$($activation.Name); status=$($activation.LicenseStatus)" } else { 'not detected' }
        IsAdministrator    = Test-Administrator
        WslDistributions   = $distros -join ', '
        PowerShell         = $PSVersionTable.PSVersion.ToString()
        Git                = Get-CommandState git
        GitHubCLI          = Get-CommandState gh
        Python             = Get-CommandState python
        UV                 = Get-CommandState uv
        Tailscale          = Get-CommandState tailscale
    } | Format-List

    $excel = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\excel.exe' -ErrorAction SilentlyContinue
    Write-Host "Excel: $(if ($excel) { $excel.'(default)' } else { 'not detected' })"
}

function Install-WindowsBase {
    Assert-Administrator
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'WinGet is missing. Update App Installer from Microsoft Store, then rerun.'
    }
    @(
        'Microsoft.PowerShell'
        'Git.Git'
        'GitHub.cli'
        'Tailscale.Tailscale'
        'Python.Python.3.13'
        'astral-sh.uv'
    ) | ForEach-Object { Install-WingetPackage $_ }

    foreach ($directory in @('C:\dev', 'C:\HerdrExchange\in', 'C:\HerdrExchange\out', 'C:\HerdrExchange\logs', 'C:\HerdrExchange\scripts', 'C:\HerdrTools')) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Write-Host 'Windows base complete. Office activation, BitLocker recovery storage, Tailscale login, and UPS policy remain manual.'
}

function Install-Wsl {
    Assert-Administrator
    $distros = @(& wsl.exe --list --quiet 2>$null) | ForEach-Object { $_ -replace "`0", '' } | Where-Object { $_.Trim() }
    if ($distros -match '^Ubuntu') {
        Write-Host "Ubuntu already registered: $($distros -join ', ')"
        return
    }
    Write-Host 'Installing WSL2 and the current Ubuntu distribution.'
    & wsl.exe --install --distribution Ubuntu
    Write-Warning 'A Windows reboot and first interactive Ubuntu launch may be required. Stop here and complete both before WslConfigure.'
}

function Configure-Wsl {
    Assert-Administrator
    Backup-AndCopy -Source (Join-Path $RepoRoot 'config\wslconfig') -Destination (Join-Path $env:USERPROFILE '.wslconfig')
    & (Join-Path $RepoRoot 'scripts\windows\Register-UbuntuStartup.ps1')
    & wsl.exe --shutdown
    Write-Host 'WSL resource limits installed. WSL was shut down so the next launch loads them.'
}

function Install-ExcelEnvironment {
    & (Join-Path $RepoRoot 'scripts\windows\Install-ExcelAutomation.ps1')
}

switch ($Stage) {
    'Status'        { Show-Status }
    'WindowsBase'  { Install-WindowsBase }
    'WslInstall'   { Install-Wsl }
    'WslConfigure' { Configure-Wsl }
    'Excel'         { Install-ExcelEnvironment }
}


#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Status', 'WindowsBase', 'HyperVEnable', 'VmCreate', 'Excel')]
    [string]$Stage = 'Status'
    ,
    [string]$UbuntuIsoPath
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
    $hyperV = try {
        Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
    } catch {
        $null
    }
    $vm = if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        Get-VM -Name 'herdr-ubuntu' -ErrorAction SilentlyContinue
    }

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
        HypervisorPresent  = $computer.HypervisorPresent
        HyperV             = if ($hyperV) { $hyperV.State } else { 'not detected' }
        UbuntuVM           = if ($vm) { "$($vm.State); autostart=$($vm.AutomaticStartAction)" } else { 'not created' }
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

function Enable-HyperV {
    Assert-Administrator
    $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
    if ($feature.State -eq 'Enabled') {
        Write-Host 'Hyper-V is already enabled.'
        return
    }
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
    Write-Warning 'Hyper-V was enabled. Reboot Windows before running the VmCreate stage.'
}

function New-UbuntuVm {
    Assert-Administrator
    if (-not $UbuntuIsoPath) {
        throw 'VmCreate requires -UbuntuIsoPath pointing to the downloaded Ubuntu Server 24.04 LTS ISO.'
    }
    & (Join-Path $RepoRoot 'scripts\windows\New-HerdrUbuntuVM.ps1') -IsoPath $UbuntuIsoPath
}

function Install-ExcelEnvironment {
    & (Join-Path $RepoRoot 'scripts\windows\Install-ExcelAutomation.ps1')
}

switch ($Stage) {
    'Status'        { Show-Status }
    'WindowsBase'  { Install-WindowsBase }
    'HyperVEnable' { Enable-HyperV }
    'VmCreate'     { New-UbuntuVm }
    'Excel'         { Install-ExcelEnvironment }
}

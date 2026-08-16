#Requires -Version 7.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$IsoPath,

    [string]$VmName = 'herdr-ubuntu',
    [string]$SwitchName = 'Default Switch',
    [string]$VmRoot = 'C:\ProgramData\Microsoft\Windows\Hyper-V\Herdr',
    [int]$ProcessorCount = 16,
    [UInt64]$StartupMemoryBytes = 16GB,
    [UInt64]$MinimumMemoryBytes = 8GB,
    [UInt64]$MaximumMemoryBytes = 32GB,
    [UInt64]$VhdSizeBytes = 500GB
)

$ErrorActionPreference = 'Stop'
$resolvedIso = (Resolve-Path -LiteralPath $IsoPath).Path

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V PowerShell tools are unavailable. Run bootstrap.ps1 -Stage HyperVEnable, reboot, and retry.'
}
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V switch '$SwitchName' was not found. Create or select a switch, then pass -SwitchName explicitly."
}

$existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "VM '$VmName' already exists; no changes were made."
    Get-VM -Name $VmName | Format-List Name, State, ProcessorCount, AutomaticStartAction, AutomaticStopAction
    exit 0
}

$vhdDirectory = Join-Path $VmRoot 'Virtual Hard Disks'
New-Item -ItemType Directory -Path $vhdDirectory -Force | Out-Null
$vhdPath = Join-Path $vhdDirectory "$VmName.vhdx"

New-VM -Name $VmName -Generation 2 -MemoryStartupBytes $StartupMemoryBytes `
    -NewVHDPath $vhdPath -NewVHDSizeBytes $VhdSizeBytes -SwitchName $SwitchName | Out-Null
Set-VMProcessor -VMName $VmName -Count $ProcessorCount
Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $true `
    -MinimumBytes $MinimumMemoryBytes -StartupBytes $StartupMemoryBytes -MaximumBytes $MaximumMemoryBytes -Buffer 20
Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
Add-VMDvdDrive -VMName $VmName -Path $resolvedIso | Out-Null
$dvd = Get-VMDvdDrive -VMName $VmName
$disk = Get-VMHardDiskDrive -VMName $VmName
Set-VMFirmware -VMName $VmName -BootOrder @($dvd, $disk)
Set-VM -Name $VmName -AutomaticStartAction Start -AutomaticStartDelay 30 -AutomaticStopAction Save

Write-Host "Created '$VmName' with $ProcessorCount vCPUs, dynamic 8-32 GB RAM, and a dynamic 500 GB VHDX."
Write-Host "ISO attached: $resolvedIso"
Write-Host "Start it with: Start-VM -Name '$VmName'; vmconnect.exe localhost '$VmName'"
Write-Warning 'After Ubuntu installation, detach the ISO and put the VHD first in the firmware boot order.'

#Requires -Version 7.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$IsoPath,
    [switch]$InstallationComplete,
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
if ($ProcessorCount -lt 1 -or $MinimumMemoryBytes -gt $StartupMemoryBytes -or
    $StartupMemoryBytes -gt $MaximumMemoryBytes -or $VhdSizeBytes -lt 64GB) {
    throw 'Invalid VM resource bounds.'
}
if (-not $InstallationComplete) {
    if ([string]::IsNullOrWhiteSpace($IsoPath) -or -not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
        throw '-IsoPath must identify the verified Ubuntu ISO until -InstallationComplete is used.'
    }
    $resolvedIso = (Resolve-Path -LiteralPath $IsoPath).Path
}

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V PowerShell tools are unavailable. Run bootstrap.ps1 -Stage HyperVEnable, reboot, and retry.'
}
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V switch '$SwitchName' was not found. Create or select a switch, then pass -SwitchName explicitly."
}

$vhdDirectory = Join-Path $VmRoot 'Virtual Hard Disks'
$vhdPath = Join-Path $vhdDirectory "$VmName.vhdx"
$existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue

if (-not $existing) {
    if (Test-Path -LiteralPath $vhdPath) {
        throw "Orphan VHD '$vhdPath' exists without VM '$VmName'. Validate and move or remove it explicitly before retrying."
    }
    New-Item -ItemType Directory -Path $vhdDirectory -Force | Out-Null
    $createdVhd = $false
    try {
        New-VHD -Path $vhdPath -Dynamic -SizeBytes $VhdSizeBytes | Out-Null
        $createdVhd = $true
        New-VM -Name $VmName -Generation 2 -Path $VmRoot -MemoryStartupBytes $StartupMemoryBytes `
            -VHDPath $vhdPath -SwitchName $SwitchName | Out-Null
    }
    catch {
        if ($createdVhd -and -not (Get-VM -Name $VmName -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $vhdPath)) {
            Remove-Item -LiteralPath $vhdPath -Force
        }
        throw
    }
    $existing = Get-VM -Name $VmName
}

if ($existing.State -ne 'Off') {
    throw "VM '$VmName' must be Off before its desired state can be verified and converged (current state: $($existing.State))."
}
if ($existing.Generation -ne 2) {
    throw "VM '$VmName' is Generation $($existing.Generation); Generation 2 is required."
}

$disks = @(Get-VMHardDiskDrive -VMName $VmName)
if ($disks.Count -ne 1 -or -not ([IO.Path]::GetFullPath($disks[0].Path)).Equals([IO.Path]::GetFullPath($vhdPath), [StringComparison]::OrdinalIgnoreCase)) {
    throw "VM '$VmName' must have exactly one system VHD at '$vhdPath'."
}
$vhd = Get-VHD -Path $vhdPath
if ($vhd.VhdType -ne 'Dynamic' -or $vhd.Size -ne $VhdSizeBytes) {
    throw "VHD '$vhdPath' must be dynamic with virtual size $VhdSizeBytes bytes."
}

$networkAdapters = @(Get-VMNetworkAdapter -VMName $VmName)
if ($networkAdapters.Count -ne 1) {
    throw "VM '$VmName' must have exactly one network adapter."
}
if ($networkAdapters[0].SwitchName -ne $SwitchName) {
    Connect-VMNetworkAdapter -VMNetworkAdapter $networkAdapters[0] -SwitchName $SwitchName
}

Set-VMProcessor -VMName $VmName -Count $ProcessorCount
Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $true `
    -MinimumBytes $MinimumMemoryBytes -StartupBytes $StartupMemoryBytes -MaximumBytes $MaximumMemoryBytes -Buffer 20
Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
Set-VM -Name $VmName -AutomaticStartAction Start -AutomaticStartDelay 30 -AutomaticStopAction Save

$disk = $disks[0]
$dvdDrives = @(Get-VMDvdDrive -VMName $VmName)
if ($dvdDrives.Count -gt 1) {
    throw "VM '$VmName' has multiple DVD drives; reduce it to one before retrying."
}
if ($InstallationComplete) {
    if ($dvdDrives.Count -eq 1) {
        Set-VMDvdDrive -VMDvdDrive $dvdDrives[0] -Path $null
    }
    Set-VMFirmware -VMName $VmName -FirstBootDevice $disk
}
else {
    if ($dvdDrives.Count -eq 0) {
        Add-VMDvdDrive -VMName $VmName -Path $resolvedIso | Out-Null
        $dvdDrives = @(Get-VMDvdDrive -VMName $VmName)
    }
    else {
        Set-VMDvdDrive -VMDvdDrive $dvdDrives[0] -Path $resolvedIso
    }
    Set-VMFirmware -VMName $VmName -BootOrder @($dvdDrives[0], $disk)
}

Write-Host "Converged '$VmName': $ProcessorCount vCPUs, dynamic $MinimumMemoryBytes-$MaximumMemoryBytes bytes RAM, dynamic $VhdSizeBytes-byte VHDX, autostart enabled."
if ($InstallationComplete) {
    Write-Host 'Installation-complete state: ISO detached and system VHD first in boot order.'
}
else {
    Write-Host "Installation state: ISO attached from '$resolvedIso' and first in boot order."
    Write-Host "Start it with: Start-VM -Name '$VmName'; vmconnect.exe localhost '$VmName'"
}

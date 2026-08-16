#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$Distribution = 'Ubuntu')

$ErrorActionPreference = 'Stop'
$TaskName = 'Start Ubuntu WSL for Herdr'
$CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'

$action = New-ScheduledTaskAction -Execute $Wsl -Argument "-d $Distribution --exec /bin/true"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
$principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Registered '$TaskName' for $CurrentUser at logon. It does not bypass the Windows login screen."


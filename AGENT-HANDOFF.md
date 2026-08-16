# Agent Handoff Runbook

## Mission

Commission the MS-A2 without losing the known-good Surface workflow. Windows 11 Pro remains the Excel/COM host. Ubuntu 24.04 LTS in Hyper-V is the durable Herdr and AI CLI environment.

## Non-negotiable rules

1. Read the architecture and dependency plan before mutating the machine.
2. Run `bootstrap.ps1 -Stage Status` first.
3. Back up existing configuration before replacement.
4. Never copy or commit authentication files, tokens, browser profiles, private SSH keys, Office documents, SMB credentials or plugin caches.
5. Never alter the Surface source environment.
6. Treat reboots as phase boundaries and stop for the user.
7. Require human participation for browser/device authentication and recovery-key handling.
8. Run Excel COM only in the interactive Windows user session.
9. Keep repositories in `~/code`; exchange workbooks through `/srv/herdr-exchange`.
10. Record evidence in uncommitted `LOCAL-COMMISSIONING-LOG.md`.

## Phase A — Assess

~~~powershell
pwsh -File .\bootstrap.ps1 -Stage Status
~~~

Confirm Windows 11 Pro activation, AMD64, 64 GB memory, 32 logical processors, 2 TB storage, virtualization, Office, elevation and tools. Stop for materially wrong hardware, storage, edition or activation.

## Phase B — Windows base and recovery

Run elevated:

~~~powershell
pwsh -File .\bootstrap.ps1 -Stage WindowsBase
~~~

Then have the user complete Office activation, BitLocker recovery-key verification, Windows Tailscale login as `herdr-win`, UPS policy and Comet access.

## Phase C — Enable Hyper-V

Run elevated:

~~~powershell
pwsh -File .\bootstrap.ps1 -Stage HyperVEnable
~~~

If newly enabled, document the checkpoint and stop for reboot. Do not combine the reboot with unattended follow-on work.

## Phase D — Create and install Ubuntu

Verify the Ubuntu Server 24.04 LTS AMD64 ISO checksum. Then run elevated:

~~~powershell
pwsh -File .\bootstrap.ps1 -Stage VmCreate -UbuntuIsoPath C:\InstallMedia\ubuntu-24.04-live-server-amd64.iso
Start-VM -Name herdr-ubuntu
vmconnect.exe localhost herdr-ubuntu
~~~

The VM defaults are 16 vCPUs, dynamic 8–32 GB RAM and a dynamically expanding 500 GB VHDX. It uses the Default Switch and is configured to start 30 seconds after the Hyper-V service starts, before Windows user login.

Have the user install Ubuntu with OpenSSH enabled. After installation:

~~~powershell
Stop-VM -Name herdr-ubuntu
Get-VMDvdDrive -VMName herdr-ubuntu | Set-VMDvdDrive -Path $null
$disk = Get-VMHardDiskDrive -VMName herdr-ubuntu
Set-VMFirmware -VMName herdr-ubuntu -FirstBootDevice $disk
Start-VM -Name herdr-ubuntu
~~~

Confirm `AutomaticStartAction=Start` and `AutomaticStopAction=Save`.

## Phase E — Ubuntu bootstrap

Clone this repository fresh inside Ubuntu rather than using a Windows-mounted checkout:

~~~bash
mkdir -p ~/code
cd ~/code
git clone https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git
cd herdr-workstation-bootstrap
bash scripts/ubuntu/bootstrap.sh --phase base
bash scripts/ubuntu/bootstrap.sh --phase tools
~~~

This installs native PowerShell 7, CIFS support, systemd services, SSH, Mosh, Tailscale, Rust/RTK, Codex, Claude, Herdr, Bun and optional Node.

Have the user authenticate:

~~~bash
gh auth login --web
codex
claude
sudo tailscale up --hostname=herdr-ubuntu
~~~

Never record device codes or tokens.

## Phase F — Remote access

Follow [REMOTE-ACCESS.md](REMOTE-ACCESS.md). Required gates:

1. Windows and Ubuntu appear separately as `herdr-win` and `herdr-ubuntu`.
2. Laptop and phone use separate SSH keys.
3. Key login succeeds before passwords are disabled.
4. SSH and Mosh work from cellular/off-LAN.
5. Herdr detaches and reattaches through both transports.
6. A cold Windows boot with no user login still produces a reachable Ubuntu node.
7. No router port forwards exist for SSH, Mosh, SMB, RDP or KVM.

## Phase G — Excel exchange

From elevated interactive Windows PowerShell:

~~~powershell
pwsh -File .\scripts\windows\New-HerdrExchangeShare.ps1
pwsh -File .\bootstrap.ps1 -Stage Excel
~~~

The user supplies and stores the dedicated non-admin `HerdrBridge` password. From Ubuntu:

~~~bash
bash scripts/ubuntu/configure-excel-share.sh --host herdr-win
~~~

Confirm Ubuntu can write a disposable file and Windows can open it. The SMB account must not belong to Administrators or Remote Desktop Users.

Create a narrow Windows-side job runner for the actual workbook automation. It must run in the designated interactive Windows session, accept only reviewed operations and paths under `C:\HerdrExchange`, log every job, and reject arbitrary PowerShell/code payloads.

## Phase H — Herdr, skills and plugins

1. Record `herdr --version`.
2. Install current official Codex and Claude integrations.
3. Reinstall plugins through supported marketplaces; do not copy caches.
4. Reconnect external apps only with user approval.
5. Run `bash scripts/ubuntu/install-payload.sh`.

The payload installer intentionally blocks while `herdr-coordination` contains Windows-specific paths/options. Installing native `pwsh` is necessary but not sufficient. Port the coordination skill to Linux, replace Windows-only paths and process options, and run its regression suite under Ubuntu before enabling it.

## Phase I — Hostinger VPS

Follow [VPS-ACCESS.md](VPS-ACCESS.md). Preserve hPanel recovery and the Surface key, make a fresh Hostinger snapshot, add a dedicated MS-A2 public key, prove public SSH, then add Tailscale without prematurely removing existing recovery paths.

## Phase J — Repository migration

1. Clone repositories fresh under `~/code`.
2. Inspect their manifests and automation instructions.
3. Recreate AMD64 dependencies; never copy ARM64 binaries or virtual environments.
4. Keep Windows-only Python/COM dependencies on Windows.
5. Replace absolute Surface and Windows paths in Linux configuration.
6. Use the SMB exchange only for workbook inputs, outputs and logs—not as the Git working tree.

## Phase K — Verify and hand off

~~~bash
bash scripts/ubuntu/verify.sh
~~~

Also validate repository checks, Windows RDP, off-LAN SSH/Mosh, Herdr detach/reattach, cold-boot/no-login VM recovery, Comet/Fingerbot recovery, Excel COM, SMB permissions, VPS access and backup restoration once the deferred drive arrives.


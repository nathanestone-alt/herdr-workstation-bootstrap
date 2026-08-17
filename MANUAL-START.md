# Manual Start: From Sealed Box to First Agent

These steps require a person. Complete them in order. Do not automate Windows OOBE, account recovery, license acceptance, recovery-key storage, or credential entry.

## Before touching the MS-A2

On the current Surface:

1. Confirm this private repository is current on GitHub.
2. Confirm access to Microsoft/Office, GitHub (`nathanestone-alt`), Codex, Claude, Tailscale and Hostinger hPanel.
3. Save current recovery codes outside either computer.
4. Keep the Surface intact as the known-good reference until every commissioning gate passes.
5. Keep the Windows 11 Pro USB sealed until the installed Windows edition and activation are checked.
6. Export only reviewed custom skills with `scripts/windows/Export-MigrationPayload.ps1`. Never export authentication files, private SSH keys, browser profiles or plugin caches.

## 1. Physical setup

1. Put the MS-A2 and setup monitor on battery-backed UPS outlets.
2. Connect Ethernet to the primary 2.5 GbE port.
3. Connect the monitor and Logitech MK270 receiver directly.
4. Keep the Comet KVM as a second path until local Windows and networking are stable.
5. Confirm firmware detects about 64 GB RAM and the 2 TB SSD.
6. Enable AMD-V/SVM virtualization only if Task Manager later reports virtualization disabled.

## 2. Windows first boot

1. Complete Windows OOBE using the normal long-term account.
2. Verify **Settings > System > Activation**:
   - Activated Windows 11 Pro: return the unopened retail USB.
   - Windows Home: upgrade with the purchased Pro license.
   - No valid OS/license: install and activate from the purchased media.
3. Rename the computer `HERDR-WIN` and reboot.
4. Run Windows Update repeatedly, including relevant firmware and driver updates.
5. Confirm Task Manager reports 64 GB RAM, 32 logical processors and virtualization enabled.
6. Confirm Ethernet, time zone and display behavior.

## 3. Security, recovery and Excel

1. Enable BitLocker and verify the recovery key from another device.
2. Keep Defender and Windows Firewall enabled.
3. Configure firmware **Restore on AC Power Loss** if available.
4. Configure the CyberPower UPS for an orderly host shutdown.
5. Do not enable automatic Windows sign-in.
6. Install and activate 64-bit Microsoft 365 desktop Excel.
7. Create, save, reopen and close a disposable workbook in `%USERPROFILE%\Documents`.
8. Resolve Excel Trust Center, add-in, activation and Protected View prompts.
9. Sign in to the native Windows OneDrive client, create `Herdr Review Exchange\Inbox`, `Outbox`, and `Archive`, and mark the full tree Always keep on this device.
10. Do not make OneDrive, `C:\HerdrExchange`, `C:\HerdrReviewJobs`, or any child an Excel Trusted Location; trust macros, links and data connections only for a specifically verified workbook.

`New-HerdrExchangeShare.ps1` establishes direct membership of `HerdrBridge` in the built-in Users group and rejects membership in any other local group; do not add it to groups manually.

Excel COM still requires the designated Windows user to be interactively signed in. The Ubuntu VM can start and accept SSH before that login occurs.

## 4. Install the minimum bootstrap tools

From an elevated Windows Terminal or PowerShell window:

~~~powershell
winget install --id Microsoft.PowerShell --exact --accept-source-agreements --accept-package-agreements
winget install --id Git.Git --exact --accept-source-agreements --accept-package-agreements
winget install --id GitHub.cli --exact --accept-source-agreements --accept-package-agreements
~~~

Open PowerShell 7 and clone the repository:

~~~powershell
gh auth login --web
gh auth status
New-Item -ItemType Directory -Force C:\dev | Out-Null
Set-Location C:\dev
gh repo clone nathanestone-alt/herdr-workstation-bootstrap
Set-Location .\herdr-workstation-bootstrap
~~~

## 5. Download Ubuntu Server

Download the current Ubuntu Server 24.04 LTS AMD64 ISO from Ubuntu's official site. Save it under `C:\InstallMedia` and verify its SHA256 value against Ubuntu's published checksum before using it.

Do not use an ARM64 image and do not download an unofficial prebuilt VM.

## 6. Install one temporary Windows agent

Install either the current Codex Windows app/CLI or Claude Code from its official source and authenticate it. This Windows agent is the bootstrap operator and emergency fallback; durable Herdr work will run in Ubuntu.

Do not copy ARM64 executables from the Surface.

## 7. Hand control to the Windows agent

Give the agent the prompt from [README.md](README.md). It begins with:

~~~powershell
pwsh -File .\bootstrap.ps1 -Stage Status
pwsh -File .\bootstrap.ps1 -Stage WindowsBase
pwsh -File .\bootstrap.ps1 -Stage HyperVEnable
~~~

Stop and reboot when requested. After reboot, the agent creates the VM using the verified ISO:

~~~powershell
pwsh -File .\bootstrap.ps1 -Stage VmCreate -UbuntuIsoPath C:\InstallMedia\ubuntu-24.04-live-server-amd64.iso
~~~

The exact ISO filename may differ.

## 8. Human checkpoints after agent handoff

Remain available for:

1. The Hyper-V feature reboot.
2. Ubuntu installation through VMConnect and creation of the Linux username/password.
3. Stopping the VM and running the verified `bootstrap.ps1 -Stage VmComplete` convergence pass after installation. If `VmCreate` used `-Vm*` resource or host-reserve overrides, repeat those exact same arguments on `VmComplete`; a bare completion pass re-applies defaults.
4. `sudo` prompts.
5. GitHub, Codex, Claude and both Tailscale authentications.
6. Creating and storing the long, strong, non-expiring `HerdrBridge` SMB password; any later rotation must update Ubuntu in the same maintenance window.
7. Installing laptop and phone SSH keys.
8. Confirming Office UI prompts and interactive Excel COM.
9. Tailscale/SSH onboarding of the Hostinger VPS.
10. Recovery, KVM, UPS and off-LAN tests.

## Manual runway completion gate

The manual runway is complete when Windows 11 Pro and Office are activated, BitLocker recovery is proven, the verified Ubuntu ISO is available, GitHub can clone this private repository, and one Windows agent is running here. Continue with [AGENT-HANDOFF.md](AGENT-HANDOFF.md).

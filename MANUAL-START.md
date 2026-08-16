# Manual Start: From Sealed Box to First Agent

These are the steps that require a person. Complete them in order. Do not attempt to automate Windows OOBE, account recovery, license acceptance, or security-key storage.

## Before touching the new MS-A2

On the current Surface:

1. Confirm this repository is private on GitHub and the latest commit is pushed.
2. Confirm you can sign into:
   - the Microsoft account used for Windows/Office;
   - GitHub account `nathanestone-alt`;
   - ChatGPT/Codex;
   - Anthropic/Claude;
   - Tailscale;
   - Backblaze/Veeam later, when backup is installed.
3. Save recovery codes for accounts using two-factor authentication.
4. Do not retire or erase the Surface. It remains the known-good reference until the MS-A2 passes every validation gate.
5. Have the Windows 11 Pro USB/product key available, but first check whether the MS-A2 already has an activated Windows Pro license.

The custom-skill export is intentionally not automatic. After the repository exists, an agent on the Surface can run:

~~~powershell
pwsh -File .\scripts\windows\Export-MigrationPayload.ps1 -Destination .\payload
~~~

Review the resulting files for secrets before forcing them past `.gitignore` into this private repository. Never export Codex/Claude authentication files, plugin caches, private SSH keys, or browser profiles.

## 1. Physical setup

1. Connect the MS-A2 and monitor to battery-backed UPS outlets.
2. Connect Ethernet to the primary 2.5 GbE port.
3. Connect the monitor and the Logitech MK270 USB receiver directly for initial setup.
4. Keep the Comet KVM and Fingerbot available, but do not make them the only console path until Windows and networking are stable.
5. Power on and enter firmware setup if needed. Confirm approximately 64 GB RAM and a 2 TB SSD are detected.

## 2. Windows first boot

1. Complete Windows OOBE with the normal long-term user account.
2. Set a strong Windows Hello PIN and record the Microsoft-account recovery path.
3. Open **Settings → System → Activation**.
   - If Windows 11 Pro is already activated, leave the retail USB unopened and return it.
   - If Home is installed, use the purchased Pro license to upgrade.
   - If no valid license is present, install/activate Pro from the purchased media.
4. Rename the computer `HERDR-WIN` and reboot.
5. Run Windows Update repeatedly, including optional driver/firmware updates, until no important updates remain.
6. Install current MS-A2/AMD drivers from the manufacturer if Device Manager shows missing devices or Windows supplied older generic drivers.
7. Confirm the clock, time zone, Ethernet, audio, and display are correct.

## 3. Security and recovery

1. Enable BitLocker/device encryption.
2. Save the recovery key outside this computer and verify you can retrieve it.
3. Keep Windows Defender and the firewall enabled.
4. Set power behavior so AC restoration powers the machine on if the firmware supports it.
5. Install/configure the CyberPower utility only if it provides tested graceful shutdown for the UPS.
6. Do not enable automatic Windows sign-in. Excel COM requires an interactive user session; use RDP or the Comet KVM to sign in after a reboot.

## 4. Install Office and prove Excel manually

1. Install Microsoft 365 desktop apps, 64-bit.
2. Sign in and activate Office.
3. Launch Excel manually.
4. Create, save, reopen, and close a disposable workbook under `C:\HerdrExchange`.
5. Resolve Trust Center, add-in, activation, or Protected View prompts now.

## 5. Install the minimum bootstrap tools

Open **Windows Terminal or PowerShell as Administrator** and run:

~~~powershell
winget install --id Microsoft.PowerShell --exact --accept-source-agreements --accept-package-agreements
winget install --id Git.Git --exact --accept-source-agreements --accept-package-agreements
winget install --id GitHub.cli --exact --accept-source-agreements --accept-package-agreements
~~~

Close the terminal and open **PowerShell 7**. Authenticate GitHub:

~~~powershell
gh auth login --web
gh auth status
New-Item -ItemType Directory -Force C:\dev | Out-Null
Set-Location C:\dev
gh repo clone nathanestone-alt/herdr-workstation-bootstrap
Set-Location .\herdr-workstation-bootstrap
~~~

If the final repository name differs, use the URL shown at handoff.

## 6. Install one temporary Windows agent

Only one Windows agent is required to bootstrap Ubuntu. Installing both on Windows is optional because the durable agent environment will be Ubuntu.

### Preferred: Codex on Windows

Install the current Codex Windows app/CLI from official OpenAI sources, sign in, open this repository, and start a session. Official OpenAI guidance still treats WSL2 as the preferred Linux-native environment; this Windows installation is the bootstrap operator and emergency fallback.

### Alternative: Claude Code on Windows

Use Anthropic's current official Windows installation instructions, launch `claude` from PowerShell 7 in this repository, and sign in.

Do not copy an ARM64 Codex or Claude executable from the Surface.

## 7. Hand control to the Windows agent

Give the agent the prompt in [README.md](README.md). The agent should begin with:

~~~powershell
pwsh -File .\bootstrap.ps1 -Stage Status
pwsh -File .\bootstrap.ps1 -Stage WindowsBase
~~~

Expect the agent to stop for at least one reboot during WSL installation.

## 8. Human checkpoints during agent setup

Remain available for these interactive steps:

1. Rebooting Windows after WSL/feature installation.
2. Launching Ubuntu once and choosing the Linux username/password.
3. Approving `sudo` prompts in Ubuntu.
4. Browser authentication for GitHub, Codex, Claude, and Tailscale inside Ubuntu.
5. Confirming Office/Excel UI prompts.
6. Saving recovery keys and backup recovery media.
7. Logging back into Windows after a reboot so Excel COM and the WSL startup task can run.
8. Installing and signing into Tailscale on the laptop and phone.
9. Creating a separate SSH key in the laptop and phone clients.

## Manual runway completion gate

The manual runway is complete when:

- Windows 11 Pro and Microsoft 365 are activated.
- GitHub CLI can clone this private repository.
- A Windows Codex or Claude session is operating in the repository.
- The user knows where the BitLocker recovery key is stored.
- The Surface remains available as a reference.

From that point, follow the agent runbook.

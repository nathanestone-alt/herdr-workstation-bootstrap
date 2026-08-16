# Agent Handoff Runbook

## Mission

Commission the MS-A2 without losing the known-good Surface workflow. Automate deterministic steps, stop for human authentication/security decisions, and record evidence for every phase.

## Rules

1. Read the architecture and dependency plan completely before mutating the machine.
2. Run `bootstrap.ps1 -Stage Status` first.
3. Never overwrite an existing configuration without making a timestamped backup.
4. Never copy or commit authentication files, tokens, browser profiles, private SSH keys, Office documents, or plugin caches.
5. Never delete or alter the Surface source environment.
6. Treat reboots as phase boundaries. Record state, tell the user exactly why a reboot is needed, and stop.
7. Ask the user to perform browser/device-code authentication. Do not attempt to extract existing credentials.
8. Run Excel COM only in the interactive Windows user session.
9. Keep Linux repositories under `~/code`; exchange Excel files through `C:\HerdrExchange`.
10. Update `LOCAL-COMMISSIONING-LOG.md` after every phase. This file is local-only and must not be committed.

## Phase A — Assess

~~~powershell
pwsh -File .\bootstrap.ps1 -Stage Status
~~~

Confirm Windows Pro/activation, AMD64, 64 GB memory, expected CPU count, 2 TB storage, Office, WSL, elevation, and existing tools. Stop if the hardware, storage, Windows edition, or activation state is materially wrong.

## Phase B — Windows base

Run elevated:

~~~powershell
pwsh -File .\bootstrap.ps1 -Stage WindowsBase
~~~

This installs approved base tools. Office activation, BitLocker recovery-key storage, Tailscale authentication, and UPS policy remain manual.

## Phase C — WSL installation

Run elevated:

~~~powershell
pwsh -File .\bootstrap.ps1 -Stage WslInstall
~~~

If a reboot or first Ubuntu launch is required, stop. After the user creates the Ubuntu username/password:

~~~powershell
pwsh -File .\bootstrap.ps1 -Stage WslConfigure
~~~

The WSL ceiling is 36 GB RAM, 24 logical processors, and 8 GB swap.

## Phase D — Ubuntu base and systemd

~~~bash
cd /mnt/c/dev/herdr-workstation-bootstrap
bash scripts/ubuntu/bootstrap.sh --phase base
~~~

If `/etc/wsl.conf` changes, return to Windows, run `wsl --shutdown`, reopen Ubuntu, and rerun. Verify PID 1 is `systemd`.

## Phase E — Ubuntu agent toolchain

~~~bash
cd /mnt/c/dev/herdr-workstation-bootstrap
bash scripts/ubuntu/bootstrap.sh --phase tools
~~~

Then ask the user to authenticate:

~~~bash
gh auth login --web
codex
claude
sudo tailscale up --hostname=herdr-ubuntu
~~~

Never record device codes or tokens in the commissioning log.

## Phase F — Remote access

Follow [REMOTE-ACCESS.md](REMOTE-ACCESS.md). Use Tailscale as the private network layer and ordinary OpenSSH for compatibility with laptops, Termius, and Mosh clients. Do not expose TCP 22 or UDP 60000–61000 on the home router.

Required gates:

1. Tailscale is installed and authenticated on Windows, Ubuntu, the laptop, and phone.
2. Ubuntu appears as `herdr-ubuntu` in MagicDNS.
3. Laptop and phone each have their own SSH key.
4. Both keys are installed in Ubuntu `authorized_keys`.
5. Key login works before password login is disabled.
6. SSH works from cellular with home Wi-Fi disabled.
7. Mosh works over Tailscale and reconnects across Wi-Fi/cellular changes.
8. Herdr can detach and reattach through both SSH and Mosh.

## Phase G — Herdr and plugins

1. Record `herdr --version`.
2. Install official integrations supported by that exact version:

~~~bash
herdr integration install claude
herdr integration install codex
~~~

3. Install Codex plugins through the supported marketplace flow, not by copying caches.
4. Reconnect GitHub, Google Calendar, and Slack only with user approval.
5. Install context-mode through its supported plugin path and verify Bun/Node prerequisites.
6. Copy custom skills only from a reviewed payload.
7. Validate all Herdr command-sensitive skills against the installed Herdr version.

## Phase G1 — Hostinger VPS

Follow [VPS-ACCESS.md](VPS-ACCESS.md). Inventory without secrets, confirm hPanel recovery, create a fresh Hostinger snapshot, generate a dedicated MS-A2 key, and add only its public half. Test public SSH before installing Tailscale on the VPS. Test Tailscale before changing root/password/public-firewall access. Keep the Surface key and a working session until all acceptance tests pass.

## Phase H — Excel automation

From the interactive Windows PowerShell session:

~~~powershell
pwsh -File .\bootstrap.ps1 -Stage Excel
~~~

The disposable test must create a workbook under `C:\HerdrExchange\out`, close Excel, and leave no test-related orphaned process. Do not use the production workbook until it passes.

## Phase I — Repository migration

1. Create `~/code` in Ubuntu.
2. Clone repositories fresh with `gh repo clone`.
3. Inspect dependency manifests and automation instructions.
4. Create a Windows-only requirements lock for COM scripts if missing.
5. Replace absolute ARM64/Windows paths in user-level agent configuration.
6. Keep source in Ubuntu and workbook handoffs in `C:\HerdrExchange` unless tests prove another design is required.

## Phase J — Verify and hand off

~~~bash
bash scripts/ubuntu/verify.sh
~~~

Also validate Windows RDP, Ubuntu SSH/Mosh from another network, Herdr detach/reattach, reboot/login/service recovery, Comet KVM, Fingerbot, Excel COM, and backup after the deferred drive arrives.

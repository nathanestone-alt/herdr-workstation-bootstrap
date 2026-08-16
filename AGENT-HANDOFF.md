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

The VM defaults are 16 vCPUs, dynamic 8–32 GB RAM and a dynamically expanding 500 GB VHDX. Default safety reserves require at least 20 logical processors and a 64 GB-or-larger host; the preflight compares the requested 48 GiB total against memory visible to Windows, which is slightly below the installed amount. On other hardware, pass reviewed `-VmProcessorCount`, `-VmMinimumMemoryBytes`, `-VmStartupMemoryBytes`, `-VmMaximumMemoryBytes`, `-VmHostProcessorReserve`, and `-VmHostMemoryReserveBytes` overrides through `bootstrap.ps1 -Stage VmCreate`. The VM uses the Default Switch and starts 30 seconds after Hyper-V, before Windows user login.

If VM creation used any reviewed resource or host-reserve override, record the exact `-Vm*` arguments in the commissioning record and repeat every one of them on the later `bootstrap.ps1 -Stage VmComplete` command. A bare completion command re-applies the script defaults.

Have the user install Ubuntu with OpenSSH enabled. After installation:

~~~powershell
Stop-VM -Name herdr-ubuntu
pwsh -File .\bootstrap.ps1 -Stage VmComplete
Start-VM -Name herdr-ubuntu
~~~

The bare completion command above is only for a VM created with the defaults. Otherwise append the identical `-VmProcessorCount`, `-VmMinimumMemoryBytes`, `-VmStartupMemoryBytes`, `-VmMaximumMemoryBytes`, `-VmHostProcessorReserve`, and `-VmHostMemoryReserveBytes` arguments used for `VmCreate`; `bootstrap.ps1` translates and forwards them to the lower-level completion script.

The convergence pass verifies the system VHD, Generation 2, switch, CPU and dynamic-memory bounds, Secure Boot, and automatic start/stop settings before detaching the ISO. It fails closed on incompatible pre-existing state.

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

This installs native PowerShell 7, CIFS support, systemd services and SSH, plus the checksum-verified/version-locked Tailscale, Rust/RTK, Node, Codex, Claude, Herdr, and Bun toolchain.

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
$acceptedFirewallRules = @() # Populate only after reviewing and recording an exception reported by preflight.
& .\scripts\windows\New-HerdrExchangeShare.ps1 -AcceptedFirewallRule $acceptedFirewallRules
& .\scripts\windows\Test-HerdrExchangeBoundary.ps1 -AcceptedFirewallRule $acceptedFirewallRules
& .\bootstrap.ps1 -Stage Excel
~~~

The user supplies and stores a long, strong password for the fixed, dedicated non-admin `HerdrBridge` account. It intentionally does not expire because Ubuntu uses a root-only static mount credential. Rotate it only in a coordinated maintenance window: run the Windows script with `-RotatePassword` (it securely prompts for the new password), then immediately run the Ubuntu command below with that same password. The Ubuntu script unmounts any existing SMB session before replacing the credential, converges its managed `/etc/fstab` block, creates a fresh encrypted SMB session, and must pass the write test before the window ends.

The share script rejects drive roots, Windows system trees, reparse points, and any existing directory that is neither the already-marked path of the matching `HerdrExchange` SMB share nor explicitly approved. If a reviewed first-run or interrupted setup must adopt an existing ordinary directory, inspect the path and its contents, record that decision, and pass `-AllowExistingSharePath` once. The switch never overrides protected-system-path checks.

~~~bash
bash scripts/ubuntu/configure-excel-share.sh --host herdr-win --owner HERDR_UBUNTU_USER
~~~

The Windows script idempotently adds `HerdrBridge` directly to the built-in Users group and rejects every other direct group membership. Its firewall conflict gate runs before mutation and covers explicit port 445/ranges plus unscoped TCP-capable rules, including `Protocol=Any`; owner-scoped AppContainer rules are excluded. Tailscale rules whose local or remote addresses are confined to `100.64.0.0/10` or `fd7a:115c:a1e0::/48` are compatible by scope. On stock Windows 11, Network Discovery for Teredo and WFD Driver-only rules may be reported. Review each exact rule name: disable an unnecessary rule with the printed `Disable-NetFirewallRule -Name '<name>'` command, or record the reason for retaining it and pass that exact name through `-AcceptedFirewallRule` to both commands above. Never accept a rule by display name or merely to make the gate pass. The script also creates and recursively protects host-owned `C:\HerdrReviewJobs`, then reads its DACL back. The boundary test runs as `HerdrBridge` and must prove it can write `in`, cannot create files or directories directly under `C:\HerdrExchange` (including `scripts`), cannot write `C:\HerdrTools` or `C:\HerdrReviewJobs`, and that no unconfined, unaccepted inbound allow rule exposes TCP 445.

Keep the reviewed Windows-side job runner and all executable helpers under host-owned `C:\HerdrTools`, which is outside the SMB share. It must run in the designated interactive Windows session, accept only reviewed operations over workbook inputs/outputs under `C:\HerdrExchange`, log every job, and reject arbitrary PowerShell/code payloads.

Configure the Windows OneDrive client with `Herdr Review Exchange\Inbox`, `Outbox`, and `Archive`, all marked Always keep on this device. GitHub remains authoritative for repositories. The reviewed staging helper must reject Offline/Recall attributes, require stable size/time/hash across two exclusive reads, preserve and hash the Inbox original, copy and re-hash it under `C:\HerdrExchange\in\<job-id>`, then copy and re-hash it again into non-shared `C:\HerdrReviewJobs\<job-id>` immediately before Excel/COM opens it. Return results and the complete provenance manifest through OneDrive Outbox. Never automate inside OneDrive or a bridge-writable directory, mount OneDrive in Ubuntu, or make OneDrive, `C:\HerdrExchange`, or `C:\HerdrReviewJobs` an Excel Trusted Location.

## Phase H — Herdr, skills and plugins

1. Record `herdr --version`.
2. Install Codex and Claude integrations compatible with the locked CLI versions; review and update the lock before upgrading.
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

Bootstrap installs a convergent hook in `~/.profile` and updates `~/.bash_profile` only when that file already exists, preserving Ubuntu's normal `.profile` to `.bashrc` login chain. The verification script checks both its controlled PATH and a separate real Bash login shell; Phase K fails if `rtk`, `codex`, `claude`, or `herdr` is not discoverable through the login profile.

Also validate repository checks, Windows RDP, off-LAN SSH/Mosh, Herdr detach/reattach, cold-boot/no-login VM recovery, Comet/Fingerbot recovery, Excel COM, SMB permissions, VPS access and backup restoration once the deferred drive arrives.

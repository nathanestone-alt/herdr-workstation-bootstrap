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
9. Keep repositories in `~/code`; transfer finite #961 workbook payloads over SSH to `herdr-win` into the host-configured Windows OneDrive exchange.
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
sudo ./scripts/ubuntu/install-trusted-launcher.sh \
  --source-root "$PWD" \
  --origin https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git \
  --commit "$(git rev-parse --verify HEAD^{commit})" \
  --run-as-user "$USER"
sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint bootstrap --phase base
sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint bootstrap --phase tools
~~~

This installs native PowerShell 7, CIFS support, systemd services and SSH, plus the checksum-verified/version-locked Tailscale, Rust/RTK, Node, Codex, Claude, Herdr, and Bun toolchain.
The tools phase also installs the pinned x86-64 uv/CPython 3.13 runtime under
user-owned managed paths, exposes `python3.13`, and provides the narrow
fail-closed `py -3.13` compatibility command. Archive
`~/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt` after
verification.

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

The #961 workbook lane uses the native Windows OneDrive client and does not
install OneDrive or rclone in Ubuntu. Transfer each finite payload over SSH to
herdr-win into the host-configured OneDrive exchange; do not synchronize the
same OneDrive account concurrently from Ubuntu and Windows.

From an elevated interactive Windows PowerShell session, create the runtime
configuration outside Git from
config/windows-review-runtime.example.json. Set
HERDR_WINDOWS_REVIEW_CONFIG to that file and approve it only after recording
the host-owned OneDrive exchange root, account, local staging root, local
review-job root, reviewed-tools root, and designated interactive/bridge SIDs.
The configuration is rejected when missing, unapproved, malformed, overlapping,
reparse-point based, or otherwise inconsistent.

Commissioning must prove that OneDrive is running and signed in under the
designated interactive Windows user before staging or Excel work. Then run the
reviewed staging and runner entry points with the runtime configuration; they
reject Offline/Recall sources, stabilize and hash the Inbox original, stage a
copy in the configured local bridge root, and copy/re-hash a final local
review-job copy before Excel opens it. Results and provenance return through
the configured OneDrive Outbox. Excel never opens an exchange/OneDrive copy
directly, and the configured exchange, staging, review-job, and tools roots are
never Excel Trusted Locations.

~~~powershell
$env:HERDR_WINDOWS_REVIEW_CONFIG = '<host-owned runtime configuration path>'
& .\scripts\windows\Stage-HerdrReviewWorkbook.ps1 -SourcePath '<configured OneDrive Inbox workbook>' -JobId '<unique finite job id>' -RuntimeConfigurationPath $env:HERDR_WINDOWS_REVIEW_CONFIG
& .\scripts\windows\Invoke-HerdrExcelJob.ps1 -JobPath '<staged job definition>' -RuntimeConfigurationPath $env:HERDR_WINDOWS_REVIEW_CONFIG
~~~

The existing SMB bootstrap scripts are not the #961 workbook route. Ubuntu
must not mount OneDrive or run rclone for this lane; the only Ubuntu-side
requirement is a proven SSH path to herdr-win and an operational handoff that
does not bypass the Windows readiness gate.

## Phase H — Herdr, skills and plugins

1. Record `herdr --version`.
2. Install Codex and Claude integrations compatible with the locked CLI versions; review and update the lock before upgrading.
3. Reinstall plugins through supported marketplaces; do not copy caches.
4. Reconnect external apps only with user approval.
5. Run `bash scripts/ubuntu/install-payload.sh`.

The payload installer first requires a clean identified Git commit whose
tracked installable files exactly match `config/payload-manifest.sha256`, then
stages and verifies both managed destinations before committing the copy. It
records `~/.local/state/herdr-workstation-bootstrap/payload-runtime-receipt.txt`.
It intentionally blocks while `herdr-coordination` contains Windows-specific
paths/options. Installing native `pwsh` is necessary but not sufficient. Port
the coordination skill to Linux, replace Windows-only paths and process
options, and run its regression suite under Ubuntu before enabling it.

## Phase I — Hostinger VPS

Follow [VPS-ACCESS.md](VPS-ACCESS.md). Preserve hPanel recovery and the Surface key, make a fresh Hostinger snapshot, add a dedicated MS-A2 public key, prove public SSH, then add Tailscale without prematurely removing existing recovery paths.

## Phase J — Repository migration

1. Clone repositories fresh under `~/code`.
2. Inspect their manifests and automation instructions.
3. Recreate AMD64 dependencies; never copy ARM64 binaries or virtual environments.
4. Keep Windows-only Python/COM dependencies on Windows.
5. Replace absolute Surface and Windows paths in Linux configuration.
6. For #961, transfer finite workbook inputs over SSH to `herdr-win` and let the Windows OneDrive/Excel lane own exchange, staging, and output. The legacy SMB utility is outside this route and must not bypass the runtime configuration or readiness gate.

## Phase K — Verify and hand off

~~~bash
./scripts/ubuntu/verify.sh
~~~

Bootstrap installs a convergent hook in `~/.profile` and updates `~/.bash_profile` only when that file already exists, preserving Ubuntu's normal `.profile` to `.bashrc` login chain. The verification script checks both its controlled PATH and a separate real Bash login shell; Phase K fails if `rtk`, `codex`, `claude`, or `herdr` is not discoverable through the login profile.

Also validate repository checks, Windows RDP, off-LAN SSH/Mosh, Herdr detach/reattach, cold-boot/no-login VM recovery, Comet/Fingerbot recovery, Excel COM, SMB permissions, VPS access and backup restoration once the deferred drive arrives.

# Herdr Workstation Dependency and Migration Plan

Last updated: 2026-08-16

## Objective

Build the MINISFORUM MS-A2 as a recoverable, remotely accessible workstation with:

- Windows 11 Pro on bare metal for native desktop Excel and COM automation.
- Ubuntu Server 24.04 LTS in an auto-starting Hyper-V VM for Herdr, Codex, Claude, Git and general development.
- Independent Tailscale nodes for Windows and Ubuntu.
- A Windows-hosted finite-payload bridge between Ubuntu agents and the interactive Windows Excel session; issue #961 uses SSH to `herdr-win` and the native Windows OneDrive client.
- Reproducible dependencies that can be rebuilt on replacement hardware.

The prior WSL2 architecture is no longer primary because WSL lifecycle depends on user/session behavior, systemd services do not keep an instance alive, and simultaneous Windows/WSL Tailscale is discouraged. See `legacy/WSL2-FALLBACK.md` only if Hyper-V proves unsuitable.

## Runbook map

- `MANUAL-START.md` — physical/OOBE steps through the first Windows agent.
- `AGENT-HANDOFF.md` — authoritative commissioning sequence.
- `REMOTE-ACCESS.md` — Tailscale, SSH, Mosh and cold-boot testing.
- `VPS-ACCESS.md` — Hostinger onboarding and recovery gates.
- `bootstrap.ps1` — Windows packages, Hyper-V and VM entry points.
- `scripts/ubuntu/bootstrap.sh` — Linux dependencies and tools.
- `scripts/ubuntu/verify.sh` — non-destructive Linux verification.

## Migration rules

1. Do not copy ARM64 programs, Rust binaries, Python environments, Node modules or package caches from the Surface.
2. Reinstall AMD64/x86-64 executables from the reviewed official artifacts pinned in `config/ubuntu-toolchain.lock`.
3. Clone repositories fresh under `~/code` in Ubuntu.
4. Migrate only reviewed source, configuration, public keys and personal skills.
5. Re-authenticate every service. Never copy token/authentication files or browser profiles.
6. Keep the Surface unchanged until all restore and remote-access gates pass.

## Current Surface reference inventory

Collected 2026-08-16. Surface versions are reference evidence; Ubuntu recovery pins live in `config/ubuntu-toolchain.lock` and change only through a reviewed lock update.

| Component | Surface | MS-A2 treatment |
|---|---|---|
| Windows | Windows 11 Home ARM64 | Windows 11 Pro x86-64 |
| PowerShell | 7.6.4 | Current x64 Windows build plus native Ubuntu build |
| WSL | 2.7.8 | Not primary; use Ubuntu Hyper-V |
| RTK | 0.42.4 ARM64 Windows | Build AMD64 Linux from the reviewed fork/ref |
| Codex CLI | 0.147.0 Windows | Fresh native Ubuntu install |
| Claude Code | 2.1.233 Windows | Fresh native Ubuntu install |
| Herdr | 0.8.0 preview Windows | Fresh stable Linux install and exact-version validation |
| Git / GitHub CLI | 2.53.0 / 2.92.0 | Fresh Ubuntu installs; Windows copies retained for bootstrap |
| Node / npm | 24.15.0 / 11.12.1 | Ubuntu only when a plugin or repository needs them |
| Bun | 1.3.13 | Fresh Ubuntu install for plugin workflows |
| Python | 3.12/3.13 ARM64 | Windows x64 3.13 for COM; Ubuntu Python for Linux projects |
| uv | 0.11.19 ARM64 | Fresh x64 Windows install and optional Ubuntu install |
| Docker | Absent | Do not install without a repository requirement |

## Resource boundary

### Windows host

Windows owns hardware, Hyper-V, backup, remote recovery and desktop Excel.

Required:

- Windows 11 Pro x86-64, current updates and current MINISFORUM/AMD drivers.
- Hyper-V with the `herdr-ubuntu` Generation 2 VM.
- Microsoft 365 desktop applications, 64-bit.
- PowerShell 7 x64.
- Python 3.13 x64 and `uv`.
- Windows Excel environment: `pywin32==311`, `openpyxl==3.1.5`, `xlwings==0.34.0`, `numpy==2.4.6`, `xlsxwriter==3.2.9`, plus a validated `pytest` version.
- Tailscale node `herdr-win`.
- Restricted `HerdrExchange` SMB share and non-admin `HerdrBridge` account.
- UPS monitoring if it demonstrably provides graceful shutdown.
- Veeam and Backblaze when backup commissioning begins.

A temporary Windows Codex or Claude install may bootstrap the VM. Do not duplicate the durable Linux toolchain on Windows without a demonstrated need.

### Ubuntu Hyper-V VM

Initial VM resources:

- 16 virtual processors.
- Dynamic memory: 8 GB minimum, 16 GB startup, 32 GB maximum.
- 500 GB dynamically expanding VHDX.
- Hyper-V Default Switch.
- Automatic start `Start`, 30-second delay; automatic stop `Save`.

Base packages installed by the bootstrap include:

~~~text
apt-transport-https build-essential ca-certificates cifs-utils curl
git git-lfs gh gnupg jq mosh openssh-client openssh-server
pkg-config ripgrep rsync unzip zip
~~~

Tooling layer:

- Native PowerShell 7 from Microsoft's Ubuntu package repository.
- uv `0.12.5` and CPython `3.13.15` x86-64 from the exact official artifacts
  pinned in `config/ubuntu-toolchain.lock`, converged under user-owned managed
  paths and exposed as `python3.13` plus the fail-closed `py -3.13` command.
- Rust stable x86-64 via `rustup`.
- RTK from `https://github.com/nathanestone-alt/rtk.git`, initially pinned to `c1819ceff1ab8d75b88c1ff7a63f497914e8fe99` until a newer reviewed revision is selected.
- Codex CLI, Claude Code and stable Linux Herdr from their official installers.
- Bun; Node 24 through `fnm` when required.
- Tailscale node `herdr-ubuntu`.
- OpenSSH and Mosh.
- Repositories under `~/code`.
- SSH access to `herdr-win`; the #961 exchange is the host-configured Windows OneDrive tree, not an Ubuntu OneDrive/rclone mount. The legacy SMB helper is separate and out of route.

## Codex, Claude, skills and plugins

Reinstall rather than copy Codex, Claude, Herdr, plugin caches, marketplace staging, runtimes and authentication state.

Selectively migrate:

- `AGENTS.md`, rewritten for Linux paths.
- `RTK.md`, preserving the required `rtk` command prefix.
- Reviewed non-secret Codex and Claude settings.
- Git identity and public-key configuration.
- Repository-controlled `AGENTS.md` and `CLAUDE.md`.

Shared skills recorded in the Surface payload:

- `herdr`
- `herdr-coordination`
- `st-herdr-dispatch`

Claude-only personal skills:

- `grill-with-docs-stmodel`
- `tier1`
- `wait-what`

The exported `herdr-coordination` payload currently contains Windows paths, `USERPROFILE`, `-WindowStyle`, Windows mutex naming and CMD-based test fixtures. Native Ubuntu `pwsh` is required but does not make those constructs portable. `install-payload.sh` deliberately fails until those hazards are removed. Port and run the complete regression suite under Ubuntu before enabling coordination.

Recorded Codex plugins:

- Browser
- Sites
- Visualize
- GitHub
- OpenAI Templates
- Plugin Management
- Google Calendar
- Slack
- context-mode 1.0.169

Install through the supported marketplace flow, reconnect accounts individually and never copy `.codex/plugins/cache`.

## Excel bridge

The #961 lane does not install OneDrive or rclone in Ubuntu and does not use
the Ubuntu SMB mount as its workbook route. Ubuntu transfers finite payloads
over SSH to herdr-win; the Windows OneDrive client owns synchronization and
the Windows job runner owns Excel execution. Do not synchronize the same
OneDrive account concurrently from Ubuntu and Windows.

The Windows staging and runner entry points require the host-owned runtime
configuration selected by HERDR_WINDOWS_REVIEW_CONFIG or
-RuntimeConfigurationPath. Keep the completed JSON outside Git. It names the
approved OneDrive exchange root and account, a distinct local bridge staging
root, a distinct host-owned local Excel review-job root, a distinct reviewed
tools root, and the designated interactive/bridge SIDs. Start from
config/windows-review-runtime.example.json; the production file must be
explicitly approved and must not use placeholder values.

Commissioning must prove that OneDrive is running and signed in under the
designated interactive Windows user before staging or Excel work. The runtime
configuration and all roots are validated for existence, local-path policy,
reparse-point safety, non-overlap, and host ownership. Missing, unapproved, or
inconsistent configuration fails closed.

### OneDrive one-off file and workbook review lane

GitHub remains authoritative for repositories. Use the Windows OneDrive client
only for finite one-off file and workbook handoffs that do not justify a Git
branch or full project transfer.

- Create Herdr Review Exchange\Inbox, Outbox, and Archive under the
  signed-in Windows OneDrive root and mark them Always keep on this device.
- Transfer a uniquely named finite payload over SSH to herdr-win into the
  configured Inbox; do not install or run OneDrive/rclone in Ubuntu.
- Require a hydration/stability gate: reject Offline/Recall attributes and
  require two exclusive reads with stable size, last-write time and SHA-256
  across a settle interval.
- Preserve each Inbox original, stage a copied workbook below the configured
  local bridge staging root, and verify its hash again after the copy.
- Before Excel/COM opens a workbook, copy the accepted bridge file into the
  configured non-shared, host-owned local review-job root and re-verify the
  accepted hash. Excel opens only this last-mile copy.
- Return the result through the configured OneDrive Outbox with a manifest
  containing source, bridge-stage, last-mile and result paths/hashes, timestamps,
  and repository/branch/commit provenance when the workbook came from STModel
  work.
- Never operate Excel automation directly in OneDrive or a bridge-writable
  directory, and never store repositories, VM disks, secrets, logs, or
  databases there.
- Treat macros, external links, and data connections as executable content
  requiring an explicit trust decision. Never configure the OneDrive exchange,
  local staging root, local review-job root, or their children as Excel Trusted
  Locations.

Add and validate the reviewed Windows staging helper before the round-trip
commissioning checkbox can pass. It owns hydration/stability checks, path and
extension validation, collision-resistant job IDs, bridge and last-mile copies,
all hash comparisons, the provenance manifest, and cleanup; it never accepts
arbitrary commands.

## Installation and validation sequence

### Phase 0 — Manual runway

- [ ] Verify hardware, Windows 11 Pro, Office, BitLocker recovery and virtualization.
- [ ] Keep the Surface as the known-good reference.
- [ ] Install PowerShell, Git and GitHub CLI.
- [ ] Clone this private repository.
- [ ] Download and checksum the official Ubuntu Server 24.04 LTS AMD64 ISO.
- [ ] Start one temporary Windows Codex or Claude session.

### Phase 1 — Windows baseline

- [ ] Run `bootstrap.ps1 -Stage Status`.
- [ ] Run `bootstrap.ps1 -Stage WindowsBase`.
- [ ] Authenticate `herdr-win` in Tailscale and validate RDP.
- [ ] Configure UPS and Comet/Fingerbot recovery paths.
- [ ] Run Excel manually once using a disposable workbook in `%USERPROFILE%\Documents`; do not create a legacy SMB exchange root unless that separate utility is explicitly commissioned outside the #961 route.

### Phase 2 — Hyper-V and Ubuntu

- [ ] Run `bootstrap.ps1 -Stage HyperVEnable`; reboot if required.
- [ ] Run `bootstrap.ps1 -Stage VmCreate -UbuntuIsoPath <verified ISO>`.
- [ ] Install Ubuntu Server with OpenSSH.
- [ ] Stop the VM, run `bootstrap.ps1 -Stage VmComplete` with the exact same `-Vm*` resource and host-reserve overrides used for `VmCreate` (omit them only when creation used defaults), and restart it.
- [ ] Confirm the VM resource limits and autostart/stop actions.
- [ ] Clone this repository under `~/code`.
- [ ] Run Ubuntu bootstrap base and tools phases, prove `uv`, CPython 3.13,
  `python3.13` and `py -3.13`, and archive
  `~/.local/state/herdr-workstation-bootstrap/toolchain-manifest.txt` with the
  commissioning record.
- [ ] Authenticate GitHub, Codex, Claude and `herdr-ubuntu`.

### Phase 3 — Remote access

- [ ] Add separate laptop and phone SSH public keys.
- [ ] Prove a second key session before disabling password authentication.
- [ ] Test SSH and Mosh over cellular.
- [ ] Test Herdr detach/reattach.
- [ ] Cold-boot Windows without login and prove Ubuntu becomes reachable.
- [ ] Confirm no home-router port forwarding.

### Phase 4 — Excel bridge

- [ ] Create the host-owned runtime configuration from `config/windows-review-runtime.example.json`, store it outside Git, and record the approval decision.
- [ ] Sign in to OneDrive under the designated interactive Windows user; create the configured `Herdr Review Exchange` tree as Always keep on this device.
- [ ] Prove SSH transfer to `herdr-win` and verify the OneDrive process/account readiness gate.
- [ ] Run the disposable Excel COM test.
- [ ] Build and validate the narrow interactive Windows job runner.
- [ ] After the staging helper is implemented and tested, transfer an STModel workbook over SSH into Inbox and round-trip it through configured local staging, host-owned last-mile Excel review, and OneDrive Outbox without using GitHub for the workbook handoff.
- [ ] Confirm Excel and the workbook lane remain unavailable before the designated Windows login while Ubuntu and SSH remain available.

### Phase 5 — Skills, plugins and projects

- [ ] Record exact tool versions.
- [ ] Port and test `herdr-coordination` on native Ubuntu PowerShell.
- [ ] Confirm `config/payload-manifest.sha256`, run the clean-commit-gated
  payload installer, and archive its deterministic runtime receipt.
- [ ] Install plugins through marketplaces and reconnect accounts.
- [ ] Clone project repositories under `~/code`.
- [ ] Rebuild project dependencies separately on Linux and Windows.

### Phase 6 — Hostinger VPS

- [ ] Follow `VPS-ACCESS.md`.
- [ ] Preserve hPanel and Surface recovery.
- [ ] Create a fresh snapshot.
- [ ] Add an MS-A2-specific public key and prove SSH.
- [ ] Add Tailscale only after public SSH works.
- [ ] Avoid removing existing recovery access until sustained validation passes.

### Phase 7 — Recovery

- [ ] Reboot and cold-boot with no Windows login.
- [ ] Prove VM/Tailscale/SSH/Herdr availability.
- [ ] Prove RDP and interactive Excel after login.
- [ ] Prove Comet and Fingerbot recovery.
- [ ] Add the deferred 20 TB drive.
- [ ] Configure Veeam entire-computer images and Backblaze user-data backup.
- [ ] Store and boot-test Veeam recovery media through Comet.
- [ ] Perform a file restore and document a full replacement-hardware recovery drill.

## Rebuild records

Keep these source-controlled and secret-free:

- Windows and Ubuntu package manifests/versions.
- Public SSH fingerprints and hostnames, never private keys.
- VM resource settings and virtual-switch choice.
- Skills source and Linux regression results.
- Plugin list and reconnection checklist.
- Windows Excel requirements and smoke test.
- SMB/share configuration templates without credentials.
- Backup schedule and restore-test dates.

Keep passwords, tokens, recovery keys, SMB credentials, private SSH keys and Office workbooks outside Git.

## Remaining commissioning decisions

- Whether Node 24 is needed beyond plugin requirements.
- Whether the pinned RTK revision remains necessary.
- The validated `pytest` and Windows Python dependency lock.
- The retention period for the OneDrive review exchange. The narrow command
  schema and provenance records are locked in
  `docs/issue-961-bridge-runner-contract.md`.
- The exact deferred 20 TB backup-drive model and final Veeam/Backblaze schedule.

# Herdr Workstation Dependency and Migration Plan

Last updated: 2026-08-16

## Objective

Build the MINISFORUM MS-A2 as a reliable, remotely accessible workstation with:

- Windows 11 Pro on bare metal for native Microsoft Excel and COM automation.
- Ubuntu on WSL2 for Herdr, Codex CLI, Claude Code, Git repositories, and general development.
- A controlled bridge between Linux agent sessions and Windows Excel automation.
- Reproducible dependencies so the workstation can be restored onto replacement hardware.

This document is the dependency/install companion to `HERDR_WINDOWS_WORKSTATION_ARCHITECTURE.md`.

The executable sequence is split across:

- `MANUAL-START.md` — everything the user must do before an agent can safely take over.
- `AGENT-HANDOFF.md` — the phase-by-phase agent runbook.
- `REMOTE-ACCESS.md` — Tailscale, OpenSSH, phone/laptop keys, Mosh, and off-LAN tests.
- `bootstrap.ps1` and `scripts/ubuntu/bootstrap.sh` — deterministic installation entry points.

## Key migration rule

Do not copy installed programs or package directories from the ARM64 Surface. The Surface is ARM64 and the MS-A2 is x86-64/AMD64. Reinstall the AMD64 version of every executable.

Migrate only reviewed configuration, source files, personal skills, and data. Re-authenticate accounts on the new machine.

## Current Surface inventory

This inventory was collected on 2026-08-16 and is a reference baseline, not a requirement to pin every tool forever.

| Component | Current Surface state | MS-A2 treatment |
|---|---|---|
| Windows | Windows 11 Home, ARM64 | Clean Windows 11 Pro x86-64 install/activation |
| PowerShell | 7.6.4 | Install current x64 PowerShell 7 |
| WSL | WSL 2.7.8, Ubuntu default distro | Install current WSL2 and a fresh Ubuntu LTS distro |
| RTK | 0.42.4, ARM64 Windows; Cargo source from `rtk-ai/rtk` | Build/install AMD64 Linux version inside Ubuntu |
| Codex CLI | 0.147.0, Windows | Fresh install inside Ubuntu; do not copy the executable |
| Claude Code | 2.1.233, Windows | Fresh native install inside Ubuntu |
| Herdr | 0.8.0 preview build, Windows | Fresh Linux AMD64 install inside Ubuntu, then validate integrations |
| Git | 2.53.0.windows.3 | Install Linux Git in Ubuntu; optionally Git for Windows for Windows-only tasks |
| GitHub CLI | 2.92.0 | Install Linux `gh` in Ubuntu and authenticate again |
| Node.js/npm | 24.15.0 / 11.12.1 | Install in Ubuntu only if required by plugins or repositories |
| Bun | 1.3.13 npm global | Install in Ubuntu because the current context-mode/plugin workflow uses it |
| Python | 3.12.10 and 3.13.12 ARM64 | Install x64 Python 3.13 on Windows; use Ubuntu Python only for Linux-only tools |
| uv | 0.11.19 ARM64 Windows | Fresh x64 Windows install; optionally install separately in Ubuntu |
| Docker | Not present | Do not install unless a cloned repository actually requires it |
| VS Code | CLI not present | Optional; not required for the SSH/Herdr workflow |

### Current Windows Python compatibility set

The Surface's Python 3.13 environment contains the packages needed by the Excel workflow:

- `pywin32==311`
- `openpyxl==3.1.5`
- `xlwings==0.34.0`
- `numpy==2.4.6`
- `xlsxwriter==3.2.9`
- `pytest` is imported by the current STModel tests; capture its exact version before final migration.

The inspected STModel scripts directly import `pythoncom`, `win32com.client`, `openpyxl`, and `pytest`. That makes Windows x64 Python plus `pywin32` a required dependency, not an optional convenience.

The current repository does not contain a `requirements.txt`, `pyproject.toml`, or lock file. Creating a reviewed Windows requirements file is therefore a required migration task.

## Target dependency boundary

### Install on Windows 11 Pro

Windows owns hardware, remote recovery, backups, and anything that controls desktop Excel.

Required:

- Windows 11 Pro x86-64 and all Windows Update patches.
- Current MINISFORUM/AMD chipset, networking, and graphics drivers.
- Microsoft 365 desktop apps, 64-bit, including Excel.
- PowerShell 7 x64.
- Python 3.13 x64 from Python.org.
- `uv` for isolated Windows Python environments.
- The Excel Python environment: `pywin32`, `openpyxl`, `xlwings`, `numpy`, `xlsxwriter`, and `pytest`, pinned after validation.
- Tailscale for remote Windows/RDP access.
- CyberPower monitoring software only if it adds useful graceful-shutdown support for the UPS model.
- Backup clients when backup storage is added: Veeam Agent and/or Backblaze according to the final backup design.

Optional:

- Git for Windows and GitHub CLI if Windows-native scripts need them.
- Windows OpenSSH Server as an emergency management path. Routine CLI work should SSH directly into Ubuntu.
- VS Code plus the WSL extension if graphical editing becomes useful.

Do not install Docker Desktop, a Windows Node stack, or duplicate Windows copies of Codex/Claude/Herdr unless a demonstrated need appears.

### Install inside Ubuntu WSL2

Ubuntu owns the persistent agent workspace.

Base packages:

~~~text
build-essential
ca-certificates
curl
git
git-lfs
gnupg
jq
openssh-client
openssh-server
mosh
pkg-config
ripgrep
unzip
zip
~~~

Runtime/tooling layer:

- Rust via `rustup`, using the x86_64 Linux stable toolchain, to build the current RTK source.
- RTK from the user's [RTK fork](https://github.com/nathanestone-alt/rtk), pinned to commit `c1819ceff1ab8d75b88c1ff7a63f497914e8fe99` until an upstream/released build is proven equivalent.
- Codex CLI using the current [official Codex WSL installation](https://learn.chatgpt.com/docs/windows/wsl.md).
- Claude Code using the current [official Claude Code setup](https://docs.anthropic.com/en/docs/claude-code/getting-started).
- Herdr using the [official Linux installer](https://github.com/herdrdev/herdr), followed by its Claude and Codex integration installers.
- GitHub CLI from GitHub's official Linux packages.
- Bun, because the current plugin/context-mode setup uses it.
- Node.js 24 only if required by a selected plugin or repository. Use a version manager so Node can be changed without disturbing the OS.
- `uv` plus Ubuntu Python for Linux-only project tooling. Do not try to use Linux Python for Excel COM.
- Tailscale inside Ubuntu for a stable, direct SSH endpoint.
- Mosh inside Ubuntu for a more resilient phone terminal over Tailscale.

Recommended host names:

- Windows Tailscale node: `herdr-win`
- Ubuntu Tailscale node: `herdr-ubuntu`

This gives Windows/RDP and Ubuntu/SSH separate, unambiguous remote targets.

## Codex, Claude, skills, and plugins

### Reinstall, do not copy

- Codex CLI and Claude Code binaries.
- Herdr binary and its official Claude/Codex integrations.
- Codex plugin cache under `.codex/plugins/cache`.
- Claude plugin cache.
- Marketplace staging folders.
- ARM64 Rust/Cargo binaries, Python virtual environments, Node modules, and npm global package directories.
- Authentication/session/token files.

### Selectively migrate

- The user-level `AGENTS.md`, after replacing Windows-only paths and commands.
- `RTK.md`, rewritten for Linux paths while preserving the rule that shell commands are prefixed with `rtk`.
- Reviewed, non-secret portions of Codex `config.toml`.
- Reviewed, non-secret portions of Claude `settings.json`.
- Git user name/email and Git LFS settings.
- Repository-specific `AGENTS.md`/`CLAUDE.md` files through Git.

Do not copy the current Codex configuration wholesale. It contains Windows GUI paths, executable paths, trusted hashes, plugin cache paths, and local hook commands that will not be valid in Ubuntu.

### Personal/shared skills to migrate and validate

Shared agent skills currently present:

- `herdr`
- `herdr-coordination`
- `st-herdr-dispatch`

Claude-only personal skills currently present:

- `grill-with-docs-stmodel`
- `tier1`
- `wait-what`

Migration procedure:

1. Install the official Herdr skill/integrations from the new Herdr binary.
2. Copy the source-controlled personal/shared skills, not cached copies.
3. Convert PowerShell and `C:\...` assumptions where Linux execution is intended.
4. Keep Windows-only helper scripts clearly marked and invoke them through `powershell.exe` when needed.
5. Run each skill's validation or smoke test.
6. Review all Herdr command-sensitive skills against the exact Herdr version before enabling coordination automation.

### Codex plugins currently in use or installed

- Browser
- Sites
- Visualize
- GitHub
- OpenAI Templates
- Plugin Management
- Google Calendar
- Slack
- context-mode 1.0.169

Plugin migration procedure:

1. Install plugins through Codex/plugin management on the new machine.
2. Reconnect GitHub, Google Calendar, and Slack accounts rather than copying credentials.
3. Install context-mode through its supported marketplace/install path.
4. Confirm Bun/Node prerequisites after plugin installation.
5. Verify plugin permissions one at a time.
6. Do not copy the current `plugins/cache` directory; it is versioned generated state.

## Windows-to-Ubuntu Excel bridge

Use the existing architecture boundary:

- Source repositories live under `~/code` inside Ubuntu for Linux filesystem performance and predictable permissions.
- Excel input/output files use `C:\HerdrExchange`.
- Excel and COM execute in the interactive Windows user session.
- Ubuntu agents invoke a small reviewed Windows launcher using `powershell.exe`, passing Windows paths under `C:\HerdrExchange`.

Create these Windows folders:

~~~text
C:\HerdrExchange\in
C:\HerdrExchange\out
C:\HerdrExchange\logs
C:\HerdrExchange\scripts
~~~

Do not run Excel workbooks directly from `\\wsl.localhost\...` until that path has been tested for Office Trust Center, Protected View, locking, and COM behavior. The exchange directory keeps that risk out of the critical path.

## Installation sequence

### Phase 0 — Manual runway to the first agent

- [ ] Physically connect the MS-A2, monitor, keyboard/mouse, Ethernet, and UPS.
- [ ] Complete Windows OOBE with the long-term interactive user.
- [ ] Confirm/activate Windows 11 Pro; return the unopened retail USB only if the included license is valid.
- [ ] Rename the host `HERDR-WIN`, reboot, and finish Windows/driver updates.
- [ ] Enable BitLocker and store the recovery key somewhere off the MS-A2.
- [ ] Install and activate Microsoft 365 64-bit; manually create/save/reopen a disposable Excel workbook.
- [ ] Install PowerShell 7, Git, and GitHub CLI with WinGet.
- [ ] Authenticate `gh` and clone this private repository into `C:\dev\herdr-workstation-bootstrap`.
- [ ] Install and sign into either Codex on Windows (preferred bootstrap operator) or Claude Code on Windows.
- [ ] Start the agent in this repository with the prompt in `README.md`.
- [ ] Keep the Surface intact until the new workstation passes every validation gate.

The Windows agent can perform the remaining deterministic setup. It must stop for reboots, the first Ubuntu username/password prompt, `sudo`, browser/device-code authentication, Office prompts, recovery-key handling, and destructive choices.

### Phase 1 — Hardware and Windows baseline

- [ ] Confirm the Amazon MS-A2 configuration is 64 GB RAM and 2 TB SSD.
- [ ] Confirm whether Windows is already licensed; return the unopened retail USB if the included license is valid and transferable enough for the intended use.
- [ ] Install/activate Windows 11 Pro.
- [ ] Apply BIOS/firmware, Windows, chipset, GPU, and network updates.
- [ ] Create the normal interactive user account that will own Excel COM sessions.
- [ ] Enable BitLocker and save the recovery key somewhere off the MS-A2.
- [ ] Configure UPS behavior and test a graceful shutdown.
- [ ] Install Microsoft 365 64-bit and run Excel once interactively.
- [ ] Install Tailscale and validate remote RDP.

### Phase 2 — Windows Excel automation

- [ ] Install PowerShell 7 x64, Python 3.13 x64, and x64 `uv`.
- [ ] Create a dedicated virtual environment for STModel/Excel automation.
- [ ] Create a pinned `requirements-windows.txt` from the validated package set.
- [ ] Install the Excel packages and run `pywin32` post-install steps if the selected release requires them.
- [ ] Create `C:\HerdrExchange` and the Windows launcher.
- [ ] Run an Excel COM smoke test: launch Excel, create/open a workbook, write a cell, save, close, and confirm no orphaned Excel process remains.
- [ ] Run the current STModel COM harness against a disposable workbook.

### Phase 3 — WSL2 and Ubuntu

- [ ] Install WSL2 and a current Ubuntu LTS distribution.
- [ ] Enable systemd in Ubuntu.
- [ ] Apply the agreed `.wslconfig`: 36 GB memory, 24 logical processors, 8 GB swap.
- [ ] Install the Ubuntu base packages listed above.
- [ ] Enable and test `sshd`.
- [ ] Install Tailscale inside Ubuntu and name the node `herdr-ubuntu`.
- [ ] Create `~/code`; keep active repositories there rather than under `/mnt/c`.
- [ ] Add a Windows scheduled task that starts the Ubuntu distro after Windows boots so SSH/systemd services become available without manual launch.

### Phase 4 — Agent toolchain

- [ ] Install Rust and build/install the validated AMD64 RTK revision.
- [ ] Confirm `rtk --version` and the mandatory command-prefix behavior.
- [ ] Install Git LFS and GitHub CLI; configure Git identity.
- [ ] Generate a new server-specific SSH key or securely migrate the existing key; register it with GitHub.
- [ ] Authenticate `gh` again.
- [ ] Install Codex CLI and authenticate again.
- [ ] Install Claude Code and authenticate again.
- [ ] Install Herdr and its Codex/Claude integrations.
- [ ] Install Bun; install Node 24 only if a plugin/repository requires it.
- [ ] Install and validate the selected skills and plugins.

### Phase 4A — Tailscale, SSH, and mobile shell

- [ ] Install/sign into Tailscale on Windows as `herdr-win`.
- [ ] Install/sign into Tailscale inside Ubuntu as `herdr-ubuntu`.
- [ ] Install/sign into Tailscale on the laptop and phone.
- [ ] Enable Ubuntu `sshd` under systemd.
- [ ] Generate a unique Ed25519 SSH key on the laptop.
- [ ] Generate a separate SSH key in the phone client; do not reuse the laptop private key.
- [ ] Add both labeled public keys to Ubuntu `~/.ssh/authorized_keys`.
- [ ] Test both key logins before disabling password and keyboard-interactive SSH authentication.
- [ ] Keep TCP 22 private to Tailscale; do not port-forward it on the home router.
- [ ] Install Mosh on Ubuntu and a compatible phone client.
- [ ] For iPhone/iPad, use Blink Shell; for Android, use JuiceSSH or Termux.
- [ ] Permit Mosh UDP 60000–61000 only inside the tailnet, or select a single port such as UDP 60001.
- [ ] Test SSH and Mosh with phone Wi-Fi disabled so the connection truly crosses the cellular network.
- [ ] Switch the phone between cellular and Wi-Fi and verify Mosh resumes.
- [ ] Start/reconnect Herdr from both a laptop SSH session and phone Mosh session.
- [ ] Restrict the Tailscale policy to the intended laptop/phone identities or devices.

Mosh starts through SSH and then uses encrypted UDP. It improves interactive roaming but does not replace SSH for file transfer, port forwarding, or universal fallback. See the [Tailscale WSL2 guide](https://tailscale.com/docs/install/windows/wsl2), [Tailscale SSH comparison](https://tailscale.com/kb/1193/tailscale-ssh), and [Mosh documentation](https://mosh.org/).

### Phase 5 — Repository migration

- [ ] Clone each repository fresh into `~/code`.
- [ ] Inventory `pyproject.toml`, requirements files, lockfiles, `package.json`, Cargo files, shell scripts, and CI definitions.
- [ ] Replace machine-specific absolute paths.
- [ ] Keep Excel workbook handoffs in `C:\HerdrExchange`; do not put the live workbook solely inside WSL.
- [ ] Create missing dependency manifests, especially the Windows Excel requirements file.
- [ ] Run repository tests separately for Linux-only work and Windows COM work.

### Phase 6 — Persistence and recovery validation

- [ ] Start Codex and Claude panes in Herdr, detach, SSH back in, and reattach.
- [ ] Reboot Windows and confirm the Ubuntu distro, systemd, Tailscale, and SSH return automatically.
- [ ] Confirm Herdr session restore behavior after a host reboot; do not confuse detach persistence with power-loss persistence.
- [ ] Confirm Comet KVM console access when Windows networking is unavailable.
- [ ] Confirm Fingerbot power control while the MS-A2 is off.
- [ ] Test a remote Excel COM run while the interactive Windows user is logged in.
- [ ] From the laptop, test Ubuntu SSH over Tailscale from outside the home LAN.
- [ ] From the phone on cellular, test both SSH and Mosh over Tailscale.
- [ ] Confirm no router port-forward exists for SSH or Mosh.
- [ ] Add the deferred local backup drive and perform a bare-metal recovery test or at least recovery-media boot plus backup verification.

## Dependency records to create

The finished build should contain these small, restorable records in a private configuration repository or encrypted backup:

- `windows-packages.md` or a reviewed WinGet export.
- `requirements-windows.txt` for Excel automation.
- `ubuntu-packages.txt` for explicitly installed APT packages.
- `tool-versions.md` for Codex, Claude, Herdr, RTK, Rust, Bun, Node, Python, uv, Git, and GitHub CLI.
- Sanitized Codex and Claude configuration templates with no tokens.
- The source-controlled personal skills.
- A plugin list and reconnection checklist, not the plugin caches.
- Git configuration and the public SSH key fingerprint.
- `.wslconfig`, `/etc/wsl.conf`, and service/autostart notes.
- The Windows Excel launcher and a disposable COM smoke test.

## Decisions still open

- Which exact Ubuntu LTS release is installed by WSL at commissioning time.
- Whether Node 24 is needed beyond context-mode/plugin requirements.
- Whether the current RTK development branch is still required or a released build now contains the needed behavior.
- Whether to generate a new GitHub SSH key for the MS-A2 (recommended) or securely migrate the Surface key.
- Whether the Windows-side Excel environment should stay on Python 3.13 or use a repository-pinned alternative after full test execution.
- The final backup client combination after the deferred local drive is purchased.

## Immediate next artifact

After the MS-A2 arrives, create a single commissioning script/checklist that performs only deterministic installs and checks. Keep login, Office activation, Tailscale enrollment, plugin connections, and other interactive authentication as explicit manual steps.

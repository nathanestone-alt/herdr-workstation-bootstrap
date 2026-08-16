# Herdr Workstation Bootstrap

Reproducible setup and migration kit for the MINISFORUM MS-A2 workstation:

- Windows 11 Pro on bare metal for Microsoft Excel and COM automation.
- Ubuntu 24.04 LTS in an auto-starting Hyper-V VM for Herdr, Codex CLI, Claude Code, repositories, SSH, and Mosh.
- Separate Tailscale endpoints for Windows recovery/RDP and direct Ubuntu SSH/Mosh.
- An explicit manual runway followed by agent-executable setup phases.

## Start here on the new computer

Follow [MANUAL-START.md](MANUAL-START.md). It takes the machine from the first power-on to the point where a Windows Codex or Claude Code session can perform the rest.

Once an agent is running in this repository, give it this exact instruction:

> Read `AGENT-HANDOFF.md` and `HERDR_WORKSTATION_DEPENDENCY_SETUP_PLAN.md` completely. Inspect the current machine, then execute the next incomplete phase. Stop for reboots, account authentication, Windows/Office activation, Ubuntu installation/account creation, BitLocker recovery-key storage, SMB credentials, or any destructive choice. Record results in `LOCAL-COMMISSIONING-LOG.md`, which must remain uncommitted.

## Entry points

- `bootstrap.ps1` — Windows status, base packages, Hyper-V enablement, VM creation, and Excel environment.
- `scripts/windows/New-HerdrUbuntuVM.ps1` — convergent Generation 2 VM provisioning with invariant checks, partial-create cleanup, bounded resources, and host-level autostart.
- `scripts/windows/New-HerdrExchangeShare.ps1` — convergent Windows SMB exchange with a fixed non-admin identity, allowlisted writable directories, encrypted SMB, and a Tailscale-only firewall rule.
- `scripts/ubuntu/bootstrap.sh` — Ubuntu packages plus the checksum-verified, version-locked toolchain in `config/ubuntu-toolchain.lock`.
- `scripts/ubuntu/configure-excel-share.sh` — credential-protected SMB mount at `/srv/herdr-exchange`.
- `scripts/ubuntu/verify.sh` — non-destructive Ubuntu verification.
- `scripts/windows/Test-ExcelCom.py` — disposable native Excel COM smoke test.
- `scripts/windows/Test-HerdrExchangeBoundary.ps1` — live negative test proving the SMB bridge cannot modify host-owned automation code.
- `scripts/windows/Export-MigrationPayload.ps1` — allowlisted export from the old Surface; excludes credentials and plugin caches.

## Documentation

- [Manual runway](MANUAL-START.md)
- [Agent runbook](AGENT-HANDOFF.md)
- [Remote access](REMOTE-ACCESS.md)
- [Hostinger VPS management](VPS-ACCESS.md)
- [Full dependency plan](HERDR_WORKSTATION_DEPENDENCY_SETUP_PLAN.md)
- [Architecture and purchase record](HERDR_WINDOWS_WORKSTATION_ARCHITECTURE.md)
- [WSL2 fallback rationale](legacy/WSL2-FALLBACK.md)

This repository contains no passwords, tokens, private SSH keys, Office files, or generated plugin caches.

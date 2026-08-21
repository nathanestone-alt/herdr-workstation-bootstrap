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
- `scripts/windows/New-HerdrExchangeShare.ps1` — legacy, separately commissioned Windows SMB exchange with a fixed non-admin identity, fail-closed share-path adoption, allowlisted writable directories, encrypted SMB, and a Tailscale-only firewall rule; it is outside the issue #961 SSH-to-OneDrive route.
- `scripts/ubuntu/bootstrap.sh` — Ubuntu packages plus the checksum-verified, version-locked toolchain in `config/ubuntu-toolchain.lock`.
- `scripts/ubuntu/receipt-authority.sh` — installs and reconciles the root-owned #961 authority envelope at `/etc/stmodel/issue-961/receipt-authority.json` and its separate receipt body. The tools phase records RTK at the regular canonical `$HOME/.cargo/bin/rtk` path and attests the clean locked checkout at `$HOME/src/rtk` (URL, ref, commit, and cleanliness). Python 3.13 at the regular `$HOME/.local/bin/python3.13` path is attested with its controlling `pyvenv.cfg`, effective `base_prefix`/stdlib, and deterministic managed-runtime manifests; all identities are checked for duplicate, stale, symlinked, writable, and tampered state.
- `scripts/ubuntu/configure-excel-share.sh` — legacy credential-protected SMB mount at `/srv/herdr-exchange`; issue #961 does not install or run it.
- `scripts/ubuntu/verify.sh` — non-destructive Ubuntu verification.

The Ubuntu trust-boundary entrypoints must be launched directly (`./scripts/ubuntu/bootstrap.sh`,
`./scripts/ubuntu/receipt-authority.sh`, or `./scripts/ubuntu/verify.sh`). Do not invoke them as
`bash script`; Bash reads `BASH_ENV` before the script can establish its committed-byte boundary.
- `scripts/windows/Test-ExcelCom.py` — disposable native Excel COM smoke test.
- `scripts/windows/Test-HerdrExchangeBoundary.ps1` — live negative test proving the SMB bridge cannot modify the exchange root or host-owned automation code and that no competing firewall rule exposes SMB.
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

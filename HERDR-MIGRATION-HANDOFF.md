# Herdr migration handoff

Last verified: 2026-08-17 (America/Chicago)

## Objective

Migrate the Herdr/Claude/Codex workflow from the Surface to the Ubuntu server, keep STModel and STModel-Agent usable, validate the Windows installation on the server, and then choose a safe OneDrive strategy for Ubuntu.

## Current machine map

- Ubuntu server: `herdr-ubuntu`, Tailscale `100.98.75.37`, user `nathan`.
- Windows installation on the server: Tailscale node `HERDR-WIN`, `100.65.54.124`.
- Surface: `SURFACE7`, Tailscale `100.122.212.104`.
- Ubuntu SSH from the Surface works through the `herdr-ubuntu` alias.

## Completed and verified

### Ubuntu / repositories

- `/home/nathan/code/STModel-Private` cloned and clean at `62939e5b` (`master` tracks `origin/master`).
- STModel MCP configuration is present in `.mcp.json`.
- `uv` is installed at `/home/nathan/.local/bin/uv`; Python 3.13 environment and the STModel MCP package are working.
- STModel MCP smoke test succeeded and served the repository corpus.
- STModel local `diff.xlsx.textconv` is configured.
- Linux `bubblewrap` is installed at `/usr/bin/bwrap`.
- `/home/nathan/code/STModel-Agent-Private` cloned and clean at `619532b` on `main`.
- `/home/nathan/code/herdr-coordination` is on `agent/preserve-coordination-recovery` at `12cfc2b`; the installed coordination skill is synced to that exact commit.
- Context-mode is installed and its Claude/Codex diagnostics passed.
- Ubuntu has `mosh`/`mosh-server` 1.4.0, `tmux`, SSH, and Tailscale running.

### Herdr and Moshi

- A dedicated Herdr coordination workspace/tab and coordination/fix panes were created. Rediscover live IDs from the active Herdr pane; do not reuse stale pane IDs after moves.
- For one full-size session per tab, create a tab rather than splitting:

  ```bash
  HERDR_ENV=1 /home/nathan/.local/bin/herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$PWD" --label "LABEL" --focus
  ```

- To move an existing pane into a new tab in the same workspace:

  ```bash
  HERDR_ENV=1 /home/nathan/.local/bin/herdr pane move "$HERDR_PANE_ID" --new-tab --workspace "$HERDR_WORKSPACE_ID" --label "LABEL" --focus
  ```

- Moshi Easy Pair succeeded over Tailscale using `100.98.75.37`. From a plain Moshi shell, attach to the existing Herdr session with:

  ```bash
  env -u HERDR_ENV -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID -u HERDR_SESSION_ID /home/nathan/.local/bin/herdr --session herdr-main
  ```

### Windows OneDrive

- On `SURFACE7`, OneDrive is installed, running, set to start automatically, and signed into the personal account `nathanestone@gmail.com`.
- The laptop-to-cloud-to-`SURFACE7` test succeeded. The probe is still at:

  ```text
  _codex_onedrive_probe_20260817\surface-test.txt
  ```

- Relevant OneDrive diagnostics reported zero upload, hash-mismatch, and realizer errors.

## Open blocker: Windows on the server

`HERDR-WIN` is online on Tailscale, but no remote administration service is reachable:

- TCP 22 (SSH) timed out.
- TCP 3389 (RDP) did not respond.
- TCP 5985/5986 (WinRM) did not respond.

The Windows installation must be configured locally at home, unless another remote console is already available. Ubuntu SSH cannot switch into or administer the Windows OS without a Windows-side service.

### First commands to run locally on HERDR-WIN

Open **PowerShell as Administrator** on the Windows installation of the server, not on Ubuntu or the Surface:

```powershell
Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH*'
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

if (!(Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}

Get-Service sshd
Get-NetTCPConnection -LocalPort 22 -State Listen
```

If OpenSSH Server is already installed, skip the `Add-WindowsCapability` line. Microsoft reference: <https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse>

Then test from the Surface:

```powershell
Test-NetConnection 100.65.54.124 -Port 22
ssh YOUR_WINDOWS_USERNAME@100.65.54.124
```

After the first login, install the Surface public key and create a `herdr-win` SSH alias. Then inspect the Windows server's OneDrive process/root and confirm whether the existing probe arrived there.

## OneDrive status on Ubuntu

Ubuntu currently has no OneDrive client, `rclone`, configuration, mount, or sync service. Do not enable Linux synchronization until the Windows server side is checked and the sync direction is chosen. Recommended first Linux mode: a narrow, one-way dry-run for selected project folders; do not start bidirectional whole-drive synchronization.

## Remaining graph gates

1. Configure and verify OpenSSH on `HERDR-WIN`.
2. Confirm OneDrive on the Windows server and the existing probe.
3. Decide the Ubuntu OneDrive method and run a dry-run against a small allowlist.
4. Run the migration graph dry-run through the Herdr coordination/fix lanes.
5. Execute only after repository, MCP, transport, and sync gates pass.

## Safety notes

- Keep the current Ubuntu Herdr session open until the Windows-side access path is verified.
- Do not paste or transmit private SSH keys; only public keys belong in `authorized_keys`.
- Herdr pane IDs are live opaque handles. Rediscover them inside the active Herdr-managed pane and use explicit IDs; never use `--current` as recovery.

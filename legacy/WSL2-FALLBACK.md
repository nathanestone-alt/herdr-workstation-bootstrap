# WSL2 Fallback (Not the Primary Architecture)

The approved workstation architecture uses an Ubuntu Hyper-V VM. These files remain only as reference:

- `legacy/wsl/wslconfig`
- `legacy/wsl/wsl.conf`

Do not use the former `Register-UbuntuStartup.ps1`; it was removed because launching `/bin/true` exits immediately, systemd services do not keep WSL alive, and its interactive-logon trigger cannot provide cold-boot/no-login availability.

A WSL fallback would require a newly designed lifecycle mechanism and Windows-host-only Tailscale. It would lose the clean direct Mosh/Tailscale node, independent VM autostart and SMB boundary. It may still be useful for short-lived Windows/Linux interop, but it does not meet the primary always-on requirement.

If Hyper-V is later rejected, create a separate reviewed change rather than reactivating the old WSL commands.

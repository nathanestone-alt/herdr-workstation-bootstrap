# Remote Access: Tailscale, SSH, and Mosh

## Recommended design

Use two independent Tailscale nodes:

- `herdr-win` — Windows host for SSH, RDP, Excel, native OneDrive exchange and host administration; the legacy SMB exchange is separately commissioned only when explicitly needed.
- `herdr-ubuntu` — Ubuntu Hyper-V VM for SSH, Mosh, Herdr, Codex and Claude.

This is not the unsupported dual-Tailscale-inside-WSL arrangement. The VM is a separate operating system with its own virtual NIC and Tailscale tunnel. Do not forward any management port from the home router.

Use ordinary OpenSSH over Tailscale for broad client compatibility and as Mosh's SSH bootstrap. Tailscale SSH remains optional.

## Why Mosh for the phone

Mosh starts through SSH and then uses encrypted UDP. It tolerates sleep, packet loss and Wi-Fi/cellular transitions better than a long-lived SSH TCP connection.

Use SSH for file transfer, tunneling and fallback. Use Mosh for interactive Herdr work. Blink Shell is a common iPhone/iPad Mosh client; Android options include JuiceSSH and Termux. Termius can remain the SSH fallback.

## Node setup

Authenticate Windows in the Tailscale app and name it `herdr-win`.

Inside Ubuntu:

~~~bash
sudo tailscale up --hostname=herdr-ubuntu
tailscale status
tailscale ip -4
systemctl status ssh tailscaled --no-pager
~~~

Confirm MagicDNS resolves each node from the laptop and phone.

## SSH keys and hardening

Create a different Ed25519 key for each client. For example, on the laptop:

~~~bash
ssh-keygen -t ed25519 -a 64 -f ~/.ssh/herdr_laptop
~~~

Create a separate phone key and copy only public keys to Ubuntu:

~~~bash
install -d -m 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
~~~

Test a second key-authenticated session before placing this in `/etc/ssh/sshd_config.d/90-herdr.conf`:

~~~text
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
~~~

Then validate and reload without closing the working session:

~~~bash
sudo sshd -t
sudo systemctl reload ssh
~~~

## Mosh

Mosh normally uses UDP 60000–61000 after SSH login. Those ports should be reachable only through Tailscale.

~~~bash
mosh USER@herdr-ubuntu
cd ~/code
herdr
~~~

A fixed port such as UDP 60001 can simplify Tailscale policy:

~~~bash
mosh -p 60001 USER@herdr-ubuntu
~~~

## Tailscale policy intent

Once devices are named or tagged, use the current Tailscale policy editor and tests to limit:

- Laptop and phone to TCP 22 and the chosen Mosh UDP range on `herdr-ubuntu`.
- Approved user devices to RDP on `herdr-win`.
- Do not open an Ubuntu-to-Windows SMB mount for issue #961; use the approved SSH-to-`herdr-win` handoff and the Windows runtime-configured OneDrive exchange. Any legacy SMB firewall rule remains outside this lane.
- Administrative access to the Comet and Hostinger VPS to approved identities only.

Do not copy a stale ACL example without validating the current policy syntax.

## Acceptance tests

1. From a non-home network, SSH to `USER@herdr-ubuntu`.
2. From phone cellular, connect with SSH and Mosh.
3. Switch the phone between cellular and Wi-Fi and confirm Mosh resumes.
4. Detach and reattach Herdr while pane processes continue.
5. RDP to `herdr-win` and prove interactive Excel.
6. Confirm Ubuntu mounts `//herdr-win/HerdrExchange` and can write a disposable file.
7. Reboot Windows and do not sign in.
8. Confirm `herdr-ubuntu` starts automatically and becomes reachable through Tailscale.
9. Confirm Excel automation remains unavailable until the Windows automation user signs in.
10. Inspect the router and confirm no inbound port forwarding exists.

Record working names, usernames and test dates only in the uncommitted commissioning log. Follow [VPS-ACCESS.md](VPS-ACCESS.md) for the separate `hostinger-vps` endpoint.

## As built: who reaches what (2026-10-21)

Tailnet nodes: `surface7` (laptop), `herdr-win`, `herdr-ubuntu`, `openclaw-vps` (the Hostinger VPS; [VPS-ACCESS.md](VPS-ACCESS.md) plans the name `hostinger-vps`), `glkvm` (the Comet KVM) and the phone. The work computer is not on the tailnet: installing Tailscale needs admin rights it does not have. Its own security software blocks outbound SSH on 22 and on other high ports, but it lets raw TCP out on 443.

| From | VPS | herdr-ubuntu | herdr-win | Surface | KVM |
|---|---|---|---|---|---|
| Surface | `ssh vps` | `ssh herdr-ubuntu` | RDP shortcut, or `ssh herdr-win` | — | `https://glkvm` |
| Phone | Termius | Termius | Windows App (RDP) | Termius | browser, `https://glkvm` |
| Work computer | Termius, port 443 | `ssh herdr-ubuntu` from the VPS | Remote Desktop or the KVM; `ssh herdr-win` from the VPS for a shell | `ssh surface` from the VPS (shell only) | KVM remote access |

### From the work computer

1. In Termius, connect to the VPS's public address on **port 443** as the VPS's named admin user, with the Termius key. That key is in the admin user's `authorized_keys` on the VPS.
2. From that shell, run `ssh herdr-ubuntu`, `ssh herdr-win` or `ssh surface`. The hop aliases and the VPS key live in the admin user's `~/.ssh`.

### Why it is shaped this way

- **443 is shared.** `sslh` listens on the VPS's public 443 (IPv4 and IPv6). It sends SSH to `sshd` on `127.0.0.1:22` and TLS to Caddy, which now serves HTTPS on an internal port (`https_port 8443` in the Caddyfile, with an explicit `http://` redirect site because automatic redirects would point at the internal port). Port 80 is unchanged. Caddy's logs now show every HTTPS client as `127.0.0.1`.
- **Rollback:** stop and disable `sslh`, restore the Caddyfile backup taken on 2026-10-21, and reload Caddy.
- **Tailscale SSH is off on every node.** It worked, but the browser console was clumsy next to Termius. With it off, port 22 on each tailnet address is plain `sshd` with keys, the same for people and agents. The tailnet SSH rule is `accept`, but it has no effect while no node runs Tailscale SSH.
- **Test from the far end.** `portquiz.net` reported ports as open from the work computer that the VPS never saw. Confirm a path with a packet capture on the VPS instead. Filtering the capture by address can mislead too: the work computer and the home machines can share one public IP.
- The Surface runs Windows 11 Home, which cannot host RDP. From off the tailnet it is shell-only.
- The VPS key is authorized on `herdr-ubuntu`, on `herdr-win` (admin accounts read `C:\ProgramData\ssh\administrators_authorized_keys`) and on the Surface. Each host key was checked from a second trusted machine before it was pinned on the VPS.
- That makes the VPS a jump host into the home machines, so its public SSH is key-only: `/etc/ssh/sshd_config.d/00-keys-only.conf` turns off password and keyboard-interactive login, on 22 and through `sslh` on 443 alike.

### Shortcuts

- Surface `~/.ssh/config`: `vps` (Tailscale), `vps-public` (public-IP fallback), `herdr-ubuntu`, `herdr-win`, and `rdp-tunnel` (`ssh -N rdp-tunnel`, then RDP to `localhost:13389`). An RDP file for `herdr-win` is on the Surface desktop.
- VPS admin user `~/.ssh/config`: `herdr-ubuntu`, `herdr-win`, `surface`.
- Termius on the work computer: one host, the VPS on port 443.

### Not yet done

- Restricting the tailnet policy as described under "Tailscale policy intent".
- Saving phone Termius profiles for these hosts.

# Remote Access: Tailscale, SSH, and Mosh

## Recommended design

Use two independent Tailscale nodes:

- `herdr-win` — Windows host for RDP, Excel, SMB exchange and host administration.
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
- `herdr-ubuntu` to TCP 445 on `herdr-win` for the restricted SMB exchange.
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

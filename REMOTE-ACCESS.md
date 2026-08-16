# Remote Access: Tailscale, SSH, and Mosh

## Recommended design

Use two Tailscale nodes:

- `herdr-win` — Windows host for RDP, recovery, and general host administration.
- `herdr-ubuntu` — Ubuntu WSL2 node for SSH, Mosh, Herdr, Codex, and Claude.

Run ordinary OpenSSH inside Ubuntu over the Tailscale network. This works with standard SSH clients and supplies the SSH bootstrap Mosh expects. Do not forward SSH or Mosh ports from the home router.

Tailscale SSH is a valid alternative, but this build initially uses normal OpenSSH because some third-party clients do not handle Tailscale SSH's authentication method cleanly, and Mosh must bootstrap through a compatible SSH client. Tailscale still provides the private WireGuard network, stable address, and MagicDNS name.

## Why Mosh for the phone

Mosh is the name of the protocol/tool (not “Moshi”). It starts through SSH and then uses encrypted UDP. It tolerates roaming, packet loss, sleep, and switching between Wi-Fi and cellular much better than a long-lived SSH TCP connection.

Use SSH for file transfer, port forwarding, and emergency compatibility. Use Mosh for interactive Herdr work on a phone.

Mobile clients:

- iPhone/iPad: Blink Shell is the straightforward Mosh client listed by the Mosh project.
- Android: JuiceSSH supports Mosh; Termux can also install the Mosh package.

Termius can remain installed as the universal SSH fallback even if a different app is used for Mosh.

## Server installation

The Ubuntu bootstrap installs and enables:

- `tailscale` / `tailscaled`
- `openssh-server`
- `mosh`

Authenticate Ubuntu interactively:

~~~bash
sudo tailscale up --hostname=herdr-ubuntu
tailscale status
tailscale ip -4
~~~

Authenticate Windows separately in the Tailscale app and name it `herdr-win`.

## SSH keys

Use a different key for each client so one lost phone does not require rotating every device.

On the laptop:

~~~bash
ssh-keygen -t ed25519 -a 64 -f ~/.ssh/herdr_laptop
~~~

Create a separate key in the phone client and copy only its public key.

On Ubuntu:

~~~bash
install -d -m 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
~~~

Append the laptop and phone public keys as separate labeled lines. Never put private keys in this repository.

Test from each client:

~~~bash
ssh -i ~/.ssh/herdr_laptop USER@herdr-ubuntu
~~~

Replace `USER` with the Ubuntu username. After both keys work, harden OpenSSH:

~~~text
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
~~~

Put these settings in a dedicated `/etc/ssh/sshd_config.d/90-herdr.conf`, validate with `sudo sshd -t`, and reload SSH. Keep the current working session open until a second key-authenticated session succeeds.

## Mosh connection

Mosh uses SSH for login, then UDP ports 60000–61000 by default. These ports need to be reachable only inside the tailnet; do not expose them publicly.

Typical client command:

~~~bash
mosh USER@herdr-ubuntu
~~~

After connecting:

~~~bash
cd ~/code
herdr
~~~

For a narrower policy/firewall range, select one port:

~~~bash
mosh -p 60001 USER@herdr-ubuntu
~~~

Configure the phone client with the Ubuntu user, MagicDNS host `herdr-ubuntu`, and the phone-specific SSH key.

## Tailscale policy

Restrict access so only the user's laptop and phone identities/devices can reach:

- TCP 22 on `herdr-ubuntu`
- UDP 60000–61000 on `herdr-ubuntu` (or only UDP 60001 if fixed)
- RDP on `herdr-win` if RDP is enabled

Use the current Tailscale policy editor and tests rather than copying a stale policy example. Keep the default-deny principle once named devices/tags are established.

## Off-LAN acceptance test

1. Disconnect the laptop from home Wi-Fi and connect through another network.
2. Connect its Tailscale client.
3. SSH to `USER@herdr-ubuntu`.
4. On the phone, disable Wi-Fi and use cellular.
5. Connect Tailscale, then connect with SSH.
6. Connect with Mosh and run `herdr`.
7. Switch the phone from cellular to Wi-Fi and back; confirm Mosh resumes.
8. Detach/reconnect Herdr and confirm the pane processes remain.
9. Reboot Windows, sign in, and confirm the Ubuntu logon task, systemd, tailscaled, and ssh return.

Record the exact MagicDNS names and working usernames in the uncommitted commissioning log.

The Hostinger VPS is a separate endpoint named 'hostinger-vps'; follow [VPS-ACCESS.md](VPS-ACCESS.md) before changing its SSH or firewall configuration.

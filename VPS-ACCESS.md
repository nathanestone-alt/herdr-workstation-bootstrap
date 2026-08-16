# Hostinger VPS Management

## Goal

Manage the existing Hostinger VPS directly from Ubuntu on the MS-A2 while preserving an independent recovery path through Hostinger hPanel.

Preferred connection order:

1. Tailscale plus ordinary OpenSSH using the MagicDNS name 'hostinger-vps'.
2. Public-IP OpenSSH with the same dedicated key as a temporary/fallback path.
3. Hostinger hPanel console, recovery, or Emergency Mode if network or SSH configuration fails.

Do not route VPS administration through the Windows host or expose credentials to an agent repository.

## Information to collect without committing

Copy 'inventory/hostinger-vps.example.md' to 'LOCAL-VPS-INVENTORY.md'. The latter is ignored by Git.

Record the Hostinger VPS name/region, Linux version, public address, SSH port/user/login method, hosted services, domains, databases, containers or panel, firewall, DNS, backups, and the current Surface access path.

Never record passwords, private keys, API tokens, Tailscale auth keys, or recovery codes in the file.

## Safe onboarding sequence

### 1. Prove existing recovery

Before changing the VPS:

1. Sign into Hostinger hPanel.
2. Confirm the VPS dashboard and existing SSH access work.
3. Identify Hostinger console/recovery options.
4. Confirm the current backup date.
5. Create a fresh Hostinger snapshot before changing SSH, firewall, networking, packages, or the OS.
6. Obtain the VPS ED25519 host-key SHA-256 fingerprint from Hostinger hPanel/console or the already trusted Surface connection. Do not trust a new network scan as the fingerprint source.

Hostinger retains only one manual snapshot at a time and currently deletes snapshots after 20 days. A restore overwrites current VPS content, so also maintain application/data backups appropriate to the workload.

### 2. Generate a workstation-specific key

From Ubuntu on the MS-A2:

~~~bash
cd ~/code/herdr-workstation-bootstrap
bash scripts/ubuntu/configure-vps-client.sh \
  --alias hostinger-vps-public \
  --host PUBLIC_IP_OR_NAME \
  --user CURRENT_ADMIN_USER \
  --port CURRENT_SSH_PORT \
  --host-key-fingerprint SHA256:INDEPENDENTLY_VERIFIED_FINGERPRINT
~~~

Choose a strong passphrase when prompted. The private key remains only in Ubuntu at '~/.ssh/hostinger_vps_ed25519'.

Load that passphrase-protected identity into an agent before either non-interactive verification gate:

~~~bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/hostinger_vps_ed25519
~~~

`verify-vps-access.sh` fails with the exact `ssh-add` remediation when the configured public key is not loaded.

The script verifies the scanned ED25519 host key against the independent fingerprint, requires exactly one key for that host token, pins it in `known_hosts`, prints the public key, and converges every managed alias in one deterministic sorted region at the top of the client configuration. It validates every managed block against the template, then resolves every managed alias with `ssh -G` against the staged user configuration plus `/etc/ssh/ssh_config`. It requires exactly one managed identity, clears/rejects forwarding, certificate, `SetEnv`, proxy, and host-key redirection, and permits only Ubuntu's standard `SendEnv LANG LC_*` values. A parser failure names the alias and leaves the client configuration unchanged. Add only the public key through Hostinger hPanel under VPS → Manage → Settings → SSH keys, or append it through the existing trusted SSH session to the intended user's authorized_keys.

Do not remove the old Surface key yet.

### 3. Test public SSH with the new key

~~~bash
ssh hostinger-vps-public
bash scripts/ubuntu/verify-vps-access.sh hostinger-vps-public
~~~

Keep the old SSH session open during authentication changes. Do not disable password or root access until the new key succeeds in a second independent session.

### 4. Add the VPS to Tailscale

On the VPS:

~~~bash
installer="$(mktemp)"
curl --proto '=https' --tlsv1.2 -fsSLo "$installer" https://tailscale.com/install.sh
printf '%s  %s\n' 805e85ed6f6f81a7ea2e70d52d47e7d5290863299e5c922b2787d71aa312f22e "$installer" | sha256sum --check
sudo env TAILSCALE_VERSION=1.88.4 sh "$installer"
rm -f "$installer"
sudo tailscale up --hostname=hostinger-vps
tailscale status
tailscale ip -4
~~~

These Tailscale version and installer-checksum pins match `config/ubuntu-toolchain.lock`. Update both locations together after reviewing a newer official release.

Authenticate using the shown URL. Add the Tailscale SSH alias:

~~~bash
bash scripts/ubuntu/configure-vps-client.sh \
  --alias hostinger-vps \
  --host hostinger-vps \
  --user CURRENT_ADMIN_USER \
  --port 22 \
  --existing-key ~/.ssh/hostinger_vps_ed25519 \
  --host-key-fingerprint SHA256:THE_SAME_VERIFIED_VPS_HOST_KEY
~~~

Test before changing public firewall rules:

~~~bash
tailscale ping hostinger-vps
ssh hostinger-vps
bash scripts/ubuntu/verify-vps-access.sh hostinger-vps
~~~

### 5. Harden without lockout

After the new key and Tailscale path work:

1. Prefer a named non-root administrator with sudo.
2. Confirm that user's key login and sudo in a second session.
3. Put SSH changes under '/etc/ssh/sshd_config.d/'.
4. Set 'PermitRootLogin no', 'PasswordAuthentication no', and 'KbdInteractiveAuthentication no' only after testing.
5. Run 'sudo sshd -t' before reloading SSH.
6. Reload rather than restart SSH while a working session remains open.
7. Restrict the Tailscale policy to intended devices/identities.
8. Decide whether public SSH remains as a restricted fallback or is closed.
9. Never close it until hPanel recovery and Tailscale are proven.

Tailscale SSH is optional. This plan initially uses ordinary OpenSSH over Tailscale for consistent key-based behavior.

## Routine workstation management

~~~bash
ssh hostinger-vps
scp LOCAL_FILE hostinger-vps:REMOTE_PATH
rsync -av --dry-run LOCAL_DIR/ hostinger-vps:REMOTE_DIR/
~~~

Use '--dry-run' before consequential rsync. Add Ansible later for repeatable multi-step changes instead of accumulating one-off commands.

Before material changes, confirm backup/snapshot state, document rollback, check resources and failed services, preserve a working session, make the smallest change, and validate hosted applications externally.

## Acceptance tests

- [ ] Existing Surface SSH and Hostinger hPanel access work.
- [ ] A fresh snapshot exists before onboarding changes.
- [ ] MS-A2 public-IP SSH works with its dedicated key.
- [ ] VPS appears in Tailscale as 'hostinger-vps'.
- [ ] MS-A2 can Tailscale-ping and SSH to it.
- [ ] The admin user can run sudo.
- [ ] A second session succeeds after hardening.
- [ ] Hosted applications still pass external checks.
- [ ] The Surface key remains until the MS-A2 is stable.
- [ ] hPanel recovery is documented without secrets.

## Authoritative references

- [Hostinger SSH-key setup](https://www.hostinger.com/support/4792364-how-to-use-ssh-keys-at-hostinger-vps/)
- [Hostinger VPS backups and snapshots](https://support.hostinger.com/en/articles/1583232-how-to-back-up-or-restore-a-vps)
- [Hostinger Emergency Mode](https://www.hostinger.com/support/5726577-how-to-use-emergency-mode-on-your-vps-at-hostinger/)
- [Tailscale Linux installation](https://tailscale.com/docs/install/linux)
- [Tailscale SSH versus ordinary SSH](https://tailscale.com/kb/1193/tailscale-ssh)

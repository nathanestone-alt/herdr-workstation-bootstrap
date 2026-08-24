# VPS/OpenClaw inventory

Inventory date: 2026-08-24 UTC. Host: srv1493921.hstgr.cloud (primary SSH alias herdr-vps; public IPv4 187.124.224.160; Tailscale IPv4 100.110.80.25).

This is a read-only issue #2 inventory. The SSH probes are recorded in commands.log. No sudo, package install, systemctl state change, Docker state change, reboot, config edit, or remote file write was used. One malformed local shell invocation for probe 37 failed before reaching the VPS; probe 38 was the corrected read-only replacement.

## Host basics

- OS: Ubuntu 24.04.4 LTS (Noble).
- Kernel: Linux 6.8.0-117-generic, x86_64.
- Uptime at collection: 91 days, 13:25; load 0.02 / 0.03 / 0.00.
- Root filesystem: ext4, 193G total, 60G used, 133G free (32%).
- Boot: /boot 881M total, 117M used; EFI 105M total, 6.2M used.
- Memory: 15Gi total, 1.2Gi used, 2.7Gi free, 12Gi cache, 14Gi available.
- Swap: 4.0Gi total, 1.2Mi used.
- Login-shell accounts reported by getent: root (/root, /bin/bash), sync (/bin, /bin/sync), ubuntu (/home/ubuntu, /bin/bash), nathan (/home/nathan, /bin/bash), postgres (/var/lib/postgresql, /bin/bash). sync is a system account despite its non-nologin shell.
- Current/logged-in evidence: nathan has an active tmux session; historical logins were also observed. No account changes were made.

## Active application and platform services

| Service or unit | Evidence and state | Relevant paths / ports |
|---|---|---|
| Caddy | caddy.service enabled and active; Caddy 2.6.2 | /etc/caddy/Caddyfile; admin 127.0.0.1:2019; public *:80 and *:443 |
| OpenClaw gateway | User unit loaded but inactive/dead, disabled; unit declares v2026.6.6 | /home/nathan/.config/systemd/user/openclaw-gateway.service; binary /home/nathan/.npm-global/bin/openclaw; gateway port 18789; env-file path /home/nathan/.openclaw/gateway.systemd.env |
| OpenClaw node | User unit loaded but inactive/dead, disabled; unit declares v2026.4.22 | /home/nathan/.config/systemd/user/openclaw-node.service; intended localhost port 18789 |
| OpenClaw data/config | About 2.8G under /home/nathan/.openclaw; data, tasks, agents, workspaces, grok-proxy, credentials and memory-backup names were observed | Do not copy contents from this inventory; credentials path observed at /home/nathan/.openclaw/credentials/gmail-monitor.json |
| grok-proxy.service | User unit loaded but inactive/dead, disabled; description Anthropic-to-Grok API Proxy | /home/nathan/.openclaw/grok-proxy |
| voice-agent.service, voice-bridge.service, voice-worker.service | User units loaded but inactive/dead, disabled | /home/nathan/voice_agent; queue, bridge and agent scripts |
| onedrive-mount.service | User unit enabled and active/running | SSHFS dependency from surface7 to /home/nathan/onedrive |
| natesoc-upload.service | System unit enabled and active/running; PID 3011932 | /home/nathan/upload_server.py; localhost 8765 |
| natesoc-terminal.service | System unit enabled and active/running; PID 3011937 | /usr/bin/ttyd; localhost 8767 |
| natesoc-files.service | System unit enabled and active/running; PID 3011927 | /home/nathan/fileserver.py; localhost 8766 |
| natesoc-monday-proxy.service | System unit enabled and active/running; PID 3011931 | /home/nathan/monday-proxy.py; localhost 8770 |
| frank-bridge.service | System unit enabled and active/running; PID 3011962; description says ElevenLabs relay | /home/nathan/voice_agent/bridge.py; working directory /home/nathan/voice_agent; localhost 8013 |
| ttyd.service | System unit enabled and active/running; PID 3011941 | /usr/lib/systemd/system/ttyd.service; /etc/default/ttyd contains TTYD_OPTIONS (value not read); listener 127.0.0.1:7681 |
| Docker and containerd | docker.service and containerd.service enabled and active/running; Docker API commands returned permission denied for nathan | Docker socket; live container/image status is root/group restricted |
| PostgreSQL | postgresql.service active/exited wrapper and postgresql@16-main.service active/running; PostgreSQL 16.15; cluster online on 5432 | Data directory /var/lib/postgresql/16/main; local TCP/Unix listener 127.0.0.1/[::1]:5432 |
| Postfix | postfix.service active/exited wrapper and postfix@-.service active/running; Postfix 3.8.6 | Local SMTP listener 127.0.0.1:25 and [::1]:25 |
| Tailscale | tailscaled active/running; version 1.102.2 | Tailscale IPs 100.110.80.25 and fd7a:115c:a1e0::4c37:501a; UDP 41641; peer herdr-ubuntu observed |
| Tor | tor.service active/exited wrapper and tor@default.service active/running | localhost SOCKS listener 127.0.0.1:9050; /etc/tor/torrc readable by name only; /var/lib/tor root-restricted |
| Fail2ban | fail2ban.service active/running; version 1.0.2 | Security daemon; detailed jail state not collected with root-only commands |
| UFW | ufw.service active/exited and enabled | ufw status and nftables rules were not readable without root |
| unattended-upgrades and Canonical Livepatch | unattended-upgrades active/running; livepatch unit active/running | Standard host maintenance; livepatch working directory /var/snap/canonical-livepatch/406 |
| Monarx | monarx-agent 4.3.59-master, monarx-protect and monarx-protect-autodetect 5.2.67-master installed | A weekly /etc/cron.d/monarx-update job installs/updates these packages; no mutation was run |
| SSH | ssh.socket enabled; sshd processes observed; TCP 22 on IPv4 and IPv6 | Required administrative access; no SSH key contents were read |
| cron and system logging | cron active/running; rsyslog active/running | Standard host scheduling/logging |
| qemu-guest-agent | active/running | Hypervisor integration |
| ModemManager, multipathd, udisks2 | active platform services | No application dependency was established; treated as host baseline pending user decision |

Other active system units observed were standard Ubuntu/cloud-init, dbus, polkit, getty, apparmor, snapd, systemd, network, apt, filesystem, and device-management services. They were not altered.

## OpenClaw configuration and data

- Installed CLI: /home/nathan/.npm-global/bin/openclaw.
- Reported CLI version: OpenClaw 2026.6.6 (8c802aa).
- User service definitions exist for gateway and node, but both are inactive/dead and disabled. No OpenClaw system unit was found.
- No listener on 18789 was present during the socket probe.
- The gateway definition references /home/nathan/.openclaw/gateway.systemd.env and declares the environment variable name OPENAI_API_KEY; values were redacted/not read.
- /home/nathan/.openclaw is approximately 2.8G. Observed directory/file categories include agents, workspaces, tasks, runs.sqlite.migrated, grok-proxy, credentials, cache/shell-snapshots, memory-backup and gateway handoff metadata.
- A Gmail monitor credential file path was observed: /home/nathan/.openclaw/credentials/gmail-monitor.json. Only its name/path was recorded.
- Existing OpenClaw-related memory backup evidence includes /home/nathan/.openclaw/memory-backup and SQL-named artifacts for clearworth-portal. No restore was attempted.

## Web, vhosts, routes and document roots

The active edge is Caddy. Apache configuration remnants exist under /etc/apache2, but no Apache service or package was found active. Caddyfile backups were present at /etc/caddy/Caddyfile.bak-20260608-2137CT, /etc/caddy/Caddyfile.backup-20260716-170845, /etc/caddy/Caddyfile.bak.buzz-20260804T025318Z and /etc/caddy/Caddyfile.tmp.

| Site or route | Observed target / behavior |
|---|---|
| natesoc.cloud | Document root /home/nathan/www/natesoc. Caddy routes /terminal to 8767, /files to 8766, /frank and /llm to 8013, /voice-call to 8014, upload matcher @uploadapi to 8765, and /api/monday to 8770. /n8n, /dashboard, and /hooks explicitly return 410. /todo, /drinks.html and the default handler are in the same Caddy site and are static/handler routes. |
| n8n.natesoc.cloud | Caddy returns 410 for /n8n. DNS currently returned NOERROR with zero A answer. |
| hub.natesoc.cloud | Caddy reverse-proxies to 127.0.0.1:3000, consistent with the Homepage compose file. DNS currently returned NOERROR with zero A answer. |
| openclaw-vps.tail74cd4a.ts.net | Caddy returns 410. Tailscale DNS maps it to 100.110.80.25. |
| scarjay.natesoc.cloud | Caddy reverse-proxies to 127.0.0.1:8091. Current compose maps 127.0.0.1:8091 to container port 8080 and persists /var/lib/scarjay-daily:/data. |
| buzz.natesoc.cloud | Caddy returns 410. DNS points to the VPS IPv4. |
| Apache residuals | /etc/apache2/conf-available/ttyd.conf and javascript-common.conf were present; no active Apache listener was found. |

Listener summary: public TCP 22, 80 and 443; local 25, 2019, 3000, 5432, 7681, 8091, 8765, 8766, 8767 and 8770; Tailscale/SSH-related listeners also appeared. Port 8014 was referenced by Caddy but was not listening in the observed snapshot. Port 18789 was referenced by inactive OpenClaw units/Caddy backups but was not listening.

## DNS posture

- natesoc.cloud: A 187.124.224.160; AAAA 2a02:4780:4:94b9::1; observed answer TTL 0.
- scarjay.natesoc.cloud: CNAME natesoc.cloud, resolving to the natesoc A/AAAA; observed TTL 0.
- buzz.natesoc.cloud: A 187.124.224.160; observed TTL 0.
- openclaw-vps.tail74cd4a.ts.net: A 100.110.80.25; observed TTL 5.
- n8n.natesoc.cloud and hub.natesoc.cloud: resolver returned NOERROR with zero answers in the probe; no A/AAAA/CNAME answer was observed.
- natesoc.cloud nameservers: ns1.dns-parking.com and ns2.dns-parking.com. SOA primary ns1.dns-parking.com, responsible host dns.hostinger.com, serial 2026082001.

## SSL/TLS certificates

Public certificate metadata was collected with SNI handshakes; private key contents were never read.

| Name | Issuer | Valid through | Path/evidence |
|---|---|---|---|
| natesoc.cloud | Let's Encrypt YE2 | 2026-10-11 01:39:54 GMT | Public SNI certificate |
| scarjay.natesoc.cloud | Let's Encrypt YE1 | 2026-10-14 16:18:54 GMT | Public SNI certificate |
| buzz.natesoc.cloud | Let's Encrypt YE1 | 2026-11-02 01:54:49 GMT | Public SNI certificate |
| openclaw-vps.tail74cd4a.ts.net | Let's Encrypt E7; local cert metadata | 2026-07-16 10:47:46 GMT (expired) | /etc/caddy/certs/openclaw-vps.tail74cd4a.ts.net.crt |
| n8n.natesoc.cloud, hub.natesoc.cloud | No public SNI certificate observed | Unknown | DNS has no answer; no certificate was returned by direct SNI probes |

Caddy's standard certificate store /var/lib/caddy is owned caddy:caddy with mode 750. Its certificate contents were not readable as nathan, so automatic-certificate renewal state and any additional certificate paths require root or the caddy account. /etc/letsencrypt does not exist.

## Containers and compose

The Docker socket rejected nathan with permission denied for both docker ps -a and docker images. No Docker state was changed.

Visible compose definitions:

- /opt/homepage/docker-compose.yml: service homepage, image ghcr.io/gethomepage/homepage:latest, container name homepage, bind 127.0.0.1:3000:3000, config /opt/homepage/config:/app/config, Docker socket mounted read-only, restart unless-stopped.
- /opt/scarjay-daily/compose.yaml: service app built from ., env_file .env, bind 127.0.0.1:8091:8080, /var/lib/scarjay-daily:/data, restart unless-stopped.
- Archived Scarjay compose copies: /home/nathan/deploy-backups/scarjay-20260717T025345Z/app/compose.yaml and /home/nathan/deploy-backups/scarjay-20260717T031008Z/app/compose.yaml. They retain the same 8091/data shape.

Because Docker API access was denied, live container names, image IDs, status, networks, mounts beyond the visible compose files, and container environment names remain an investigate item.

## Databases

- PostgreSQL 16/main is online on port 5432, data directory /var/lib/postgresql/16/main, log /var/log/postgresql/postgresql-16-main.log.
- A read-only psql query as nathan failed with FATAL: role nathan does not exist. Database names, owners and sizes therefore could not be enumerated without an allowed root/database role.
- Scarjay has a persistent application data mount at /var/lib/scarjay-daily, but its schema/content was not read.
- OpenClaw has SQLite-named task/run data under its own data tree; contents were not read.

## Scheduling

Nathan's crontab was empty. Attempts to read ubuntu, postgres and root crontabs returned must be privileged to use -u; /var/spool/cron/crontabs was permission denied. These are explicit root-only limitations.

Readable /etc/cron entries:

- /etc/cron.d/sysstat and /etc/cron.daily/sysstat.
- /etc/cron.d/docker-image-prune: weekly Docker image prune.
- /etc/cron.d/docker-builder-prune: weekly Docker builder prune.
- /etc/cron.d/monarx-update: weekly Monarx package update/install.
- /etc/cron.d/e2scrub_all: standard filesystem scrub entries.
- Standard daily/weekly jobs: apt-compat, 00logwatch, apport, man-db, dpkg, logrotate and weekly tor/man-db; placeholders were also present.

Systemd timers observed include sysstat-collect, sysstat-summary, fwupd-refresh, dpkg-db-backup, logrotate, ua-timer, apt-daily, man-db, update-notifier-download, systemd-tmpfiles-clean, apt-daily-upgrade, motd-news, update-notifier-motd, e2scrub_all and fstrim. Disabled/no-schedule entries included apport-autoreport, snapd.snap-repair and pg_basebackup@. A user launchpadlib-cache-clean.timer was also observed.

## Storage, backups and monitoring

- /var/backups: 3.6M; latest visible package-backup evidence dated 2026-08-22. Contents were dpkg/alternatives-style host metadata, not a verified application backup.
- /home/nathan/.openclaw: 2.8G; memory-backup directory and SQL-named artifacts present, latest sampled backup artifacts dated May 2026.
- /home/nathan/deploy-backups: 1.3M; latest directory timestamp 2026-07-17, with archived Scarjay compose/source material.
- /home/nathan/.local/state/herdr-workstation-bootstrap/payload-backup-20260817-1: 932K directory.
- /etc/caddy contains dated Caddyfile backups, but these are configuration fallbacks, not full service/database backups.
- dpkg-db-backup.timer is enabled; pg_basebackup@.timer is disabled. No verified off-host destination, recent full application backup, or tested restore procedure was found in the readable evidence.
- Monitoring/security evidence: fail2ban active; Monarx installed and updated by cron; UFW/firewall rules unreadable without root; no Prometheus/Grafana/Zabbix service was found in the relevant unit scan.

## Secret paths and names recorded without values

Only names, paths and purposes are recorded here. No key, token, password, environment value or database credential was copied.

- /home/nathan/.openclaw/gateway.systemd.env — OpenClaw gateway managed environment file; OPENAI_API_KEY was an observed variable name only.
- OPENAI_API_KEY — provider credential name declared by the OpenClaw gateway unit; value redacted/not read.
- /home/nathan/.openclaw/credentials/gmail-monitor.json — Gmail monitor credential file.
- /etc/caddy/certs/openclaw-vps.tail74cd4a.ts.net.key — TLS private key paired with the observed Tailscale certificate.
- /opt/scarjay-daily/.env — compose environment file referenced by the current Scarjay definition; contents not read.
- Archived Scarjay compose env-file paths under /home/nathan/deploy-backups/scarjay-20260717T025345Z/app/.env and /home/nathan/deploy-backups/scarjay-20260717T031008Z/app/.env are potential secret copies; contents not read.
- /opt/scarjay-daily/initial-credentials.txt — filename indicates initial application credentials; contents not read.
- /etc/default/ttyd, variable TTYD_OPTIONS — ttyd runtime options; value not read because it may include access-control material.
- Local /home/nathan/.ssh private key contents were not read. Remote SSH key contents were not read.

## Read-only limitations

1. Docker API and live images/containers were root/group restricted.
2. PostgreSQL catalog access failed because the SSH user has no database role; no alternate/root role was used.
3. Root-owned user crontabs and /var/spool/cron/crontabs were unreadable.
4. UFW/nftables rules were root-only.
5. Caddy's /var/lib/caddy certificate store was caddy-owned and unreadable; public SNI certificates were used where possible.
6. Some process executable/cwd/environment fields were root-restricted; only environment variable names were attempted, never values.

These limitations are carried into classification.md as investigate items. They do not imply any mutation or permission escalation occurred.

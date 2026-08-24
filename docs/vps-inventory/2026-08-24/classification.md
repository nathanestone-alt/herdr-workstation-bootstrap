# VPS/OpenClaw classification

Classification is a decision aid for issue #2, not authorization to change anything. The labels are:

- migrate to herdr-ubuntu: reproduce the needed capability on the target, validate it, then cut traffic over.
- keep on VPS: retain the capability on the prepaid VPS, including a possible standby/public-edge role.
- retire: already retired/unused or explicitly returning 410; archive evidence before any later removal.
- investigate: an access gap, stale route, security concern or dependency must be resolved before choosing a move/retention action.

The count below is by scoped classification record. A route can refer to a service and an integration can refer to a service; that overlap is intentional so no coverage item is silently omitted.

Summary: 30 service/daemon records, 13 web-site/route records, 10 cron/timer records, 4 container records and 8 integration records = 65 scoped records. All 65 have an explicit classification: 23 migrate, 22 keep on VPS, 8 retire and 12 investigate.

## Services and daemons — 30 records

| # | Service/record | Classification | Rationale |
|---:|---|---|---|
| 1 | OpenClaw gateway user unit | migrate to herdr-ubuntu | Version 2026.6.6 is installed but unit is inactive; move only the required replacement capability after data/credential backup and target validation. |
| 2 | OpenClaw node user unit | retire | Unit is inactive/dead, disabled, and shares the unused 18789 intent; preserve an archive before retirement. |
| 3 | OpenClaw data/config/credential tree | migrate to herdr-ubuntu | 2.8G of operational history and task data exists; migrate only selected required data, with secrets re-issued rather than copied blindly. |
| 4 | grok-proxy.service | retire | Anthropic-to-Grok proxy is inactive/dead and has no observed listener. |
| 5 | voice-agent, voice-bridge and voice-worker user units | migrate to herdr-ubuntu | These are inactive application capabilities with source under /home/nathan/voice_agent; port and external credential testing is required on target. |
| 6 | onedrive-mount.service | keep on VPS | Active SSHFS dependency may be useful for operations; retain until a target storage replacement is tested. |
| 7 | Caddy service | keep on VPS | Active public edge for several sites; the prepaid VPS is a valid public-edge/standby role, and Caddy can remain until DNS cutover is complete. |
| 8 | caddy-api.service | retire | Disabled/not running; Caddy admin listener is already provided by the active Caddy service. |
| 9 | natesoc-upload.service | migrate to herdr-ubuntu | Active localhost upload backend behind Caddy; move source, data and route with access-control testing. |
| 10 | natesoc-terminal.service | investigate | Active web terminal is a high-risk exposed capability; validate authentication and necessity before reproducing it. |
| 11 | ttyd.service on port 7681 | investigate | A second active ttyd listener exists with options hidden in TTYD_OPTIONS; ownership, bind address and auth are not yet proven. |
| 12 | natesoc-files.service | migrate to herdr-ubuntu | Active file server behind Caddy; move only after path/data and authorization tests. |
| 13 | natesoc-monday-proxy.service | migrate to herdr-ubuntu | Active integration proxy on 8770; move with a re-issued Monday credential and webhook/API tests. |
| 14 | frank-bridge.service | migrate to herdr-ubuntu | Active ElevenLabs relay on 8013; source and voice data are identifiable and should be tested on target. |
| 15 | Docker and containerd runtime | investigate | Runtime is active, but Docker API access was denied; live container/image/network state is incomplete without an allowed root/group read. |
| 16 | Homepage compose service | migrate to herdr-ubuntu | Visible compose maps localhost 3000 and mounts config plus read-only Docker socket; reproduce after inspecting target Docker policy. |
| 17 | Scarjay compose service | migrate to herdr-ubuntu | Visible compose maps localhost 8091 and persistent /var/lib/scarjay-daily data; move with an application/data backup and restore test. |
| 18 | PostgreSQL 16/main | migrate to herdr-ubuntu | Online local database is a dependency candidate; catalog was not readable as nathan, so database inventory and target sizing are preconditions. |
| 19 | Postfix local mail | keep on VPS | Local-only SMTP listener was observed; retain unless application dependency analysis proves an external mail service is safer. |
| 20 | Tailscale daemon and mesh | keep on VPS | Provides the configured fallback path and target peer visibility; keep during and after migration for recovery access. |
| 21 | Tor daemon/SOCKS listener | investigate | Active localhost 9050 service has no confirmed issue-2 dependency; identify consumers and policy before retaining or removing. |
| 22 | Fail2ban | keep on VPS | Active host security control; preserve on any public edge and replicate policy before edge migration. |
| 23 | UFW/nftables firewall | investigate | Unit is enabled/active, but rules could not be read without root; no migration decision is safe until effective rules are known. |
| 24 | unattended-upgrades and Canonical Livepatch | keep on VPS | Host maintenance controls should remain on a retained VPS or be replaced by equivalent target maintenance. |
| 25 | qemu-guest-agent | keep on VPS | Hypervisor integration; not an application migration target. |
| 26 | Monarx agent/protect packages | keep on VPS | Installed security agent and updater are active host controls; preserve if the VPS remains public. |
| 27 | SSH service/socket | keep on VPS | Required recovery and operations path; retain until target access is proven, and never migrate private key material through this inventory. |
| 28 | cron service and standard maintenance | keep on VPS | Host scheduler and standard OS housekeeping remain needed while the VPS exists. |
| 29 | local resolver/systemd DNS | keep on VPS | Local DNS listeners are part of host operation; replace only with target resolver configuration as part of a separate host build. |
| 30 | rsyslog, gpg-agent, ModemManager, multipathd and udisks2 baseline | keep on VPS | Platform services observed active; no application dependency or safe removal case was established. |

## Sites and web routes — 13 records

| # | Site/route record | Classification | Rationale |
|---:|---|---|---|
| 1 | natesoc.cloud and /home/nathan/www/natesoc | migrate to herdr-ubuntu | Active public/static site and data tools are a clear portable workload; stage the document root and Caddy behavior first. |
| 2 | natesoc /terminal route | investigate | It reaches a web shell/ttyd capability; security, auth and the two ttyd listeners must be resolved before exposing it elsewhere. |
| 3 | natesoc /files route | migrate to herdr-ubuntu | Maps to the active file server on 8766. |
| 4 | natesoc /frank and /llm routes | migrate to herdr-ubuntu | Both map to the active Frank bridge on 8013; preserve route behavior and credential boundaries. |
| 5 | natesoc /voice-call route | investigate | Caddy points at 8014 but no listener was observed; determine whether it is stale or an inactive voice capability. |
| 6 | natesoc upload matcher | migrate to herdr-ubuntu | Active upload backend on 8765; move with storage and authorization tests. |
| 7 | natesoc /api/monday route | migrate to herdr-ubuntu | Active Monday proxy on 8770; migrate with secret rotation and API tests. |
| 8 | natesoc /n8n, /dashboard and /hooks routes | retire | Caddy explicitly returns 410 with retired messages; retain only a reversible config archive. |
| 9 | n8n.natesoc.cloud host | retire | Route is explicitly retired and DNS has no answer. |
| 10 | hub.natesoc.cloud host | investigate | Caddy targets the active-looking localhost 3000 Homepage path, but DNS has no answer and Docker state is root-restricted. |
| 11 | openclaw-vps.tail74cd4a.ts.net host | retire | Caddy returns 410; the observed local certificate expired 2026-07-16. |
| 12 | scarjay.natesoc.cloud host | migrate to herdr-ubuntu | Active public route to localhost 8091 and current Scarjay compose definition are portable. |
| 13 | buzz.natesoc.cloud host | retire | Caddy returns 410; preserve DNS/certificate evidence before any later cleanup. |

## Cron and timer records — 10 records

| # | Schedule record | Classification | Rationale |
|---:|---|---|---|
| 1 | Nathan user crontab | keep on VPS | It is empty; no workload to migrate. |
| 2 | Root, ubuntu and postgres crontabs/spool | investigate | Reads returned privilege errors and spool access was denied; hidden jobs could affect backup/migration order. |
| 3 | docker-image-prune cron | keep on VPS | Host hygiene job; retain only if Docker remains on the VPS and confirm its destructive retention policy. |
| 4 | docker-builder-prune cron | keep on VPS | Host hygiene job; retain only if Docker remains on the VPS. |
| 5 | monarx-update cron | keep on VPS | Security-agent maintenance; keep while the VPS is a public/standby edge. |
| 6 | e2scrub_all cron | keep on VPS | Standard filesystem maintenance. |
| 7 | sysstat and standard daily/weekly scripts | keep on VPS | OS observability and housekeeping. |
| 8 | dpkg-db-backup.timer | investigate | It is enabled and recent, but evidence is package metadata only, not an application restore point. |
| 9 | pg_basebackup@.timer | investigate | Template timer is disabled; PostgreSQL backup posture is not proven. |
| 10 | OS systemd timers: logrotate, apt, fwupd, ua, man-db, tmpfiles, update-notifier, motd, fstrim and related timers | keep on VPS | Standard host maintenance; move only as part of target OS provisioning. |

## Containers and compose records — 4 records

| # | Container record | Classification | Rationale |
|---:|---|---|---|
| 1 | Homepage current compose definition | migrate to herdr-ubuntu | Local 3000 service and config/Docker-socket mounts are visible; runtime status requires a privileged read. |
| 2 | Scarjay current compose definition | migrate to herdr-ubuntu | Local 8091 service and /var/lib/scarjay-daily data mount are visible. |
| 3 | Archived Scarjay compose copies | retire | They are dated deployment backups, not active services; retain as rollback artifacts until migration sign-off, then prune by user decision. |
| 4 | Unknown live Docker containers/images/networks | investigate | docker ps -a and docker images were denied; no container may be silently omitted from a final cutover. |

## External integrations and secret-bearing dependencies — 8 records

| # | Integration/dependency | Classification | Rationale |
|---:|---|---|---|
| 1 | OpenAI provider credential declared by OpenClaw | migrate to herdr-ubuntu | Re-issue/store the target credential; the observed variable name was OPENAI_API_KEY and its value was never read. |
| 2 | Gmail monitor credential | migrate to herdr-ubuntu | Credential path exists under the OpenClaw tree; validate the replacement monitor and rotate rather than copying blindly. |
| 3 | ElevenLabs voice relay | migrate to herdr-ubuntu | Frank bridge explicitly identifies the integration; stage voice calls and quotas before DNS cutover. |
| 4 | Monday API | migrate to herdr-ubuntu | Active Monday proxy route exists; issue a target credential and test idempotency/webhook behavior. |
| 5 | Anthropic-to-Grok proxy | retire | Its user unit is inactive/dead and no listener was observed. |
| 6 | Surface7 OneDrive over SSHFS | keep on VPS | Active mount is an external storage dependency; retain until target access and data consistency are proven. |
| 7 | Tailscale mesh | keep on VPS | Required for fallback SSH and observed target peer connectivity. |
| 8 | Hostinger DNS and Let's Encrypt/ACME | keep on VPS | DNS provider and certificate automation are shared edge dependencies; retain during staged migration, with the expired Tailscale certificate treated as an exception to fix or retire. |

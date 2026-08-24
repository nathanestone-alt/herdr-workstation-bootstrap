# DRAFT migration and rollback plan — NOT FOR EXECUTION

This document is a draft for user review only. It authorizes nothing and must not be used as an execution runbook until the user chooses the target topology, confirms the service matrix and approves a separate change window. The VPS has approximately 18 months prepaid; keeping it as a standby, backup host or public edge is a valid outcome, so full migration is not mandatory.

## Preconditions and gates

1. User approves which currently retired/stale routes stay retired and which active capabilities are actually wanted on herdr-ubuntu.
2. An off-host backup destination is selected and access-tested. Backups must cover the OpenClaw data/config tree, application source/data, Caddy routes, all readable unit/compose definitions, PostgreSQL data and Scarjay data.
3. Backup restores are tested on an isolated target. A file listing or a dated directory is not sufficient evidence. PostgreSQL requires both a logical restore test and a physical/base-backup decision.
4. Secrets are re-issued into the target secret store. Do not copy values from gateway.systemd.env, .env files, credential JSON, initial-credentials.txt, TLS keys or TTYD_OPTIONS into tickets/chat/artifacts.
5. Target host capacity, service accounts, firewall rules, SSH/Tailscale recovery, logging, unattended security updates and certificate automation are proven before public exposure.
6. DNS ownership and rollback access at Hostinger are confirmed. The observed TTL is 0 for the natesoc records, so DNS propagation behavior must be tested rather than assumed.
7. Staging ports and health checks are defined for each service. No public DNS or VPS service state is changed until the target passes checks.
8. Root-only gaps are closed by an authorized operator or explicitly accepted as residual risk: Docker live state, PostgreSQL catalogs, hidden crontabs, UFW/nftables and Caddy's private certificate store.

## Ordered migration steps

### Step 0 — Freeze evidence and make verified backups

Before touching any source service, export a manifest of the current Caddyfile, custom systemd units, user units, compose files, document root, application directories, OpenClaw data, /var/lib/scarjay-daily and PostgreSQL. Capture checksums and timestamps without including secret values. Create encrypted off-host backups, then restore each backup into an isolated test location.

Rollback: make no source changes; if backup verification fails, leave the VPS unchanged and stop. The current VPS remains the rollback source.

### Step 1 — OpenClaw data and provider dependencies

Scope: OpenClaw gateway user unit, OpenClaw data/config tree, OpenAI provider credential and Gmail monitor credential.

Preconditions: decide whether a replacement gateway is required at all because both gateway/node units are currently inactive/dead; inventory which agents, task queues, SQLite data and Gmail monitor behavior are still needed; test a target secret store and least-privilege service account.

Migration: back up the full tree and separately record a manifest of selected non-secret data. Recreate only required target functionality on herdr-ubuntu, inject newly issued provider/Gmail credentials, import selected data, and run offline/API health tests. Do not enable the old VPS units as part of the migration.

Rollback: keep the source tree and unit definitions untouched; revert target deployment to the pre-import snapshot, revoke target credentials if needed, and continue using the VPS only if the user explicitly re-enables a required source capability. Restore the target from the verified pre-import backup if data import is wrong.

### Step 2 — Frank/voice capabilities

Scope: frank-bridge.service, the voice-agent/voice-bridge/voice-worker source set, natesoc /frank and /llm routes, and the ElevenLabs integration. The natesoc /voice-call route is not included as a migration until its missing 8014 listener is explained.

Preconditions: back up /home/nathan/voice_agent, queues, journals and logs; identify whether queue files contain pending work; issue a target ElevenLabs credential; define duplicate-call/idempotency behavior.

Migration: deploy the bridge and any required workers to isolated target ports; test a non-production voice request, queue processing, failure/retry behavior and log redaction; only then put the target behind the equivalent route.

Rollback: route /frank and /llm back to the VPS Caddy target, stop target workers, and restore the target queue/data snapshot. Do not replay a queue without checking for duplicate side effects. Leave /voice-call untouched until its owner confirms the service.

### Step 3 — Natesoc application backends and static site

Scope: natesoc.cloud document root, natesoc-files.service, natesoc-upload.service, natesoc-monday-proxy.service, the /files route, upload matcher and /api/monday route.

Preconditions: back up /home/nathan/www/natesoc and the source scripts /home/nathan/fileserver.py, /home/nathan/upload_server.py and /home/nathan/monday-proxy.py; identify upload storage and Monday credential dependencies; test target authorization and path confinement.

Migration: deploy under target service accounts with non-public bind addresses, stage the static root and route map, issue a new Monday credential, and run read-only site, upload, file authorization and API tests. Keep the web-terminal route out of this step until the investigate decision is resolved.

Rollback: restore the target document/data snapshot, disable target routes, and point DNS/edge routing back to the VPS Caddy configuration. For a bad upload or API deployment, restore the previous target artifact and rotate any exposed target credential.

### Step 4 — PostgreSQL data

Scope: PostgreSQL 16/main and any applications that depend on it, including possible Scarjay or OpenClaw data.

Preconditions: an authorized database operator enumerates databases, roles, extensions, sizes, owners and active clients; choose logical versus physical migration; create and test a backup/restore; coordinate a write freeze or replication plan.

Migration: take the approved final backup, restore into a target PostgreSQL 16-compatible cluster, verify row counts/checksums/application migrations, then point staged applications to the target. Do not infer database completeness from the current nathan role failure.

Rollback: keep the VPS cluster intact and read-only/available during the observation window; revert application connection targets to the VPS and restore any target-side changes from the pre-cutover snapshot. If a final backup is invalid, abort before cutover.

### Step 5 — Docker workloads

Scope: Homepage compose service, Scarjay compose service and their current data/config mounts.

Preconditions: obtain an authorized read-only Docker inventory of all containers, images, networks, labels, mounts, restart policies and environment variable names. Back up /opt/homepage/config, /opt/scarjay-daily, the referenced .env files by encrypted secret-aware means, and /var/lib/scarjay-daily. Confirm whether unknown live containers exist.

Migration: build/pull pinned images on herdr-ubuntu rather than relying on latest, restore configs/data, run Homepage on a staging port and Scarjay on a staging port, then test health, persistence and Docker-socket least privilege. Record exact image digests.

Rollback: stop only the target workload, restore its target data snapshot and return the Caddy route/DNS to the VPS. Retain the original VPS compose/data until the observation window and user sign-off finish. Do not run Docker prune as part of migration.

### Step 6 — Edge routing and TLS

Scope: active Caddy routes for natesoc.cloud, scarjay.natesoc.cloud, hub.natesoc.cloud, the retired 410 routes, and public certificates.

Preconditions: user chooses whether Caddy remains on the prepaid VPS as public edge/standby. Copy route behavior from a sanitized manifest, not from unreviewed secret-bearing files. Confirm target firewall, certificate issuance, Caddy validation and DNS rollback access. The expired openclaw-vps certificate must be renewed or the retired name must remain retired.

Migration: stage the target Caddy/edge configuration, obtain certificates for only live domains, verify natesoc and scarjay SNI/expiry, verify retired routes remain 410 if retained, and test hub only after its DNS/ownership decision. Keep old certificates/route files as rollback artifacts without exposing private-key contents.

Rollback: restore the prior DNS records and route configuration to the VPS; if a target certificate or route is bad, remove target exposure and use the still-valid VPS edge. DNS rollback timing must account for observed TTL/real resolver caching.

### Step 7 — DNS and cutover

Scope: A/AAAA/CNAME records for natesoc.cloud, scarjay.natesoc.cloud, buzz.natesoc.cloud, n8n.natesoc.cloud, hub.natesoc.cloud and the Tailscale-only OpenClaw name.

Preconditions: target health checks pass from multiple networks; certificate SAN/expiry checks pass; retired names have explicit desired behavior; DNS records and the current Hostinger SOA are captured; a low-risk cutover window is approved.

Migration: cut over one live name at a time, starting with a non-critical staged name, monitor HTTP status, logs and backend health, then cut over the selected live names. Do not recreate n8n/dashboard/hooks/buzz/OpenClaw retired routes unless the user explicitly changes the decision.

Rollback: restore each previous A/AAAA/CNAME record at Hostinger, keep target services available for diagnosis, and serve from the unchanged VPS edge. For a secret compromise, revoke/rotate the affected credential before retrying.

### Step 8 — Observation and retirement gate

Observe target services, backups, certificate renewal, queues, database writes, mail, Tailscale recovery and logs for a user-selected period. Only after sign-off may the user retire inactive OpenClaw/grok/voice units, old Caddy routes, archived compose copies or unused VPS workloads.

Rollback: until the gate closes, retain the VPS data/config backups and route path. If a failure occurs, follow the per-step rollback above. Any actual stop, disable, delete, package change or DNS mutation requires a separate approved execution task.

## Migrate-item coverage map

All records classified migrate to herdr-ubuntu are assigned above:

- OpenClaw gateway and selected OpenClaw data: Step 1.
- OpenClaw provider/Gmail credentials: Step 1.
- Voice user-unit set, Frank bridge and ElevenLabs: Step 2.
- natesoc static root, file server, upload server, Monday proxy, /files, upload matcher and /api/monday: Step 3.
- /frank and /llm: Step 2.
- PostgreSQL: Step 4.
- Homepage and Scarjay current compose services: Step 5.
- natesoc.cloud site: Steps 3 and 6.
- scarjay.natesoc.cloud: Steps 5–7.

The /terminal, /voice-call, hub DNS, Docker live-state, firewall, hidden crontab and disabled PostgreSQL backup items remain investigate gates and are intentionally not treated as executable migrations.

# VPS backup and tested-restore plan

Status: execution plan only. No backup, restore, service change, DNS change, package
installation, or VPS write was performed while authoring this document.

Authoring date: 2026-08-25 UTC
Source evidence: `inventory.md`, `classification.md`, `migration-plan.md`, and
`commands.log` from commit `18bcfda`; the sizing probes recorded in the worker return
artifacts for this node.

This plan implements the user's decision that verified off-host backups and a tested
restore path come before any migrate or retire action.

## Operating choices and capacity

- Source is the VPS reached through the existing `herdr-vps` SSH alias.
- Pull direction is always **herdr-ubuntu -> `ssh herdr-vps` -> local destination**.
  Do not add a key, trust relationship, account, or backup agent on the VPS.
- Initial destination is `/home/nathan/backups/herdr-vps` on herdr-ubuntu. Create it
  with mode `0700`; use an encrypted local filesystem or an approved operator-only
  encryption mechanism for any credential-bearing backup. A root-owned destination such
  as `/var/backups` is optional and is a user-sudo-local choice, not a prerequisite.
- The local capacity probe found 28G free on a 98G filesystem (71% used). The known
  non-PostgreSQL, non-Docker payload is approximately 2.94G: OpenClaw 2.8G, the
  natesoc web root 64M, voice source 65M, and small configs/data/archives. PostgreSQL
  cluster size, Docker images/volumes, Caddy's private state, and hidden root-owned
  schedules are not included in that number. Complete those sizing gates before
  committing to the retention set below.
- Snapshot identifier format: `YYYYmmddTHHMMSSZ`; each snapshot contains separate
  `files/`, `postgres/`, `host-state/`, `manifests/`, and `restore-report/` areas.
- Retention is **N=14 promoted snapshots**: 7 daily, 4 weekly, and 3 monthly, plus
  the current last-known-good restore report. Unchanged files may be hard-linked with
  rsync `--link-dest`; PostgreSQL dumps are separately compressed artifacts. Prune
  only after the new snapshot has a valid manifest and the previous restore point is
  still present.

### Secret handling rule

The ordinary plan manifest records names, paths, ownership, modes, sizes, and checksums
only; it never records credential, token, password, private-key, or environment values.
For `/home/nathan/.openclaw` and any other secret-bearing path, prefer re-issuing the
credential into the target secret store. If continuity requires a backup, put the
artifact in a separately encrypted, operator-controlled area on herdr-ubuntu and
include only its checksum and access owner in the manifest. Never print or paste its
contents. The restore rehearsal uses test credentials or newly issued credentials and
does not start a service with the VPS secrets.

## Complete scope table

The size values are the 2026-08-25 read-only probe where available. `Unknown` is an
intentional gate, not permission to omit the asset.

| Inventory asset and location | Observed size | Backup method | Frequency and destination | Gate / owner |
|---|---:|---|---|---|
| PostgreSQL 16/main databases, roles, tablespaces, extensions, and globals; data directory `/var/lib/postgresql/16/main` | Unknown: `postgres`-owned and unreadable to the SSH user | As `postgres`, enumerate databases and sizes; stream `pg_dumpall --globals-only --no-role-passwords` plus one `pg_dump --format=custom` per database. Preserve a separate encrypted globals/role artifact if ACL/role fidelity requires it. | Initial now, logical dump nightly to `$ROOT/<id>/postgres/logical/`; keep 7 daily, 4 weekly, 3 monthly | **user-sudo-VPS** or an authorized database operator. The observed `nathan` role failure means no logical backup is PASS until the catalog is enumerated. |
| PostgreSQL physical cluster and WAL needed for point-in-time/base restore | Unknown; the data directory could not be traversed | Use installed PostgreSQL 16 `pg_basebackup --format=tar --wal-method=stream` with a manifest and stream its output over SSH to local storage; do not use the disabled VPS timer as evidence. Validate with `pg_verifybackup`. | Initial now and weekly thereafter to `$ROOT/<id>/postgres/physical/`; promote the latest known-good copy | **user-sudo-VPS** and a replication-capable PostgreSQL operator. Decide whether physical backup is required before migration; for this decision it is required as a tested option. |
| OpenClaw configuration, task/run history, agents, workspaces, cache, memory backups, and data tree `/home/nathan/.openclaw` | 2.8G | Pull with `rsync -aH --numeric-ids` or a tar stream, preserving symlinks, modes, and timestamps. Keep the full tree in restricted/encrypted storage; make a redacted file/path manifest separately. | Initial now, nightly while it is a retained dependency, to `$ROOT/<id>/files/home/nathan/.openclaw/` | User-readable pull is runnable now. Credential files are subject to the secret-handling rule; do not blindly import them. |
| OpenClaw user units and binary reference: `/home/nathan/.config/systemd/user/openclaw-gateway.service`, `openclaw-node.service`, `/home/nathan/.npm-global/bin/openclaw`, and `/home/nathan/.openclaw/gateway.systemd.env` | Units 8K each; binary/data size not separately measured | Archive unit definitions and a version/hash manifest. Back up the environment file only in the encrypted secret area; record variable names, not values. Reinstall/re-pin the binary on a target rather than treating a copied executable as a restore. | On every change and in each promoted snapshot under `host-state/openclaw/` | User-readable for definitions; credential restore is **user-sudo-local/operator-secret-store**. Both units were inactive/dead, so do not enable them during the test. |
| Natesoc static/document root `/home/nathan/www/natesoc` | 64M | Pull with rsync or tar; generate a SHA-256 manifest and preserve symlinks/modes. | Initial now and nightly to `$ROOT/<id>/files/home/nathan/www/natesoc/` | Runnable now; restore into a scratch directory only. |
| Natesoc application sources and active service data: `/home/nathan/upload_server.py`, `fileserver.py`, `monday-proxy.py`, and `/home/nathan/voice_agent` (Frank/voice source, queues, bridge/agent scripts) | 65M for `voice_agent`; scripts 44K combined | Pull source/data with rsync; archive readable unit definitions alongside it. Do not copy provider credentials; re-issue ElevenLabs and Monday credentials. | Initial now and nightly/on change to `$ROOT/<id>/files/home/nathan/` | User-readable source pull now; target execution waits for service/auth tests. |
| Caddy edge configuration, dated fallbacks, and route behavior under `/etc/caddy` | 36K; `Caddyfile` 4K | Pull readable Caddy files with rsync/tar and create a sanitized route/host manifest. Preserve dated fallback files as rollback evidence; validate a restored copy with `caddy validate` before any use. | Initial now and on every route change to `$ROOT/<id>/host-state/caddy/` | Readable Caddy config is runnable now. The active edge remains untouched. |
| Caddy certificate and ACME material: `/etc/caddy/certs` and Caddy-managed `/var/lib/caddy` | 12K in readable cert directory; `/var/lib/caddy` unknown and unreadable to `nathan` | Record public certificate issuer/SAN/expiry metadata and checksums. Put private keys and ACME state in the separate encrypted operator area, or re-issue certificates on the target; never put key contents in the ordinary archive. | Metadata on every snapshot; encrypted key/ACME copy only on change and before a cutover | **user-sudo-VPS/caddy-operator** for private store. The observed Tailscale certificate was expired; renew or explicitly keep that name retired. |
| Caddy-served sites/routes: `natesoc.cloud`, `scarjay.natesoc.cloud`, `buzz.natesoc.cloud`, `hub.natesoc.cloud`, `n8n.natesoc.cloud`, and `openclaw-vps.tail74cd4a.ts.net`, including 410 behavior and localhost backend mappings | Route facts are negligible; backend data is covered in other rows | Store a sanitized route manifest with Caddy config, domains, status/target behavior, and expected health checks. Do not copy secrets from route/config files. | On every edge change and before each cutover under `$ROOT/<id>/host-state/routes/` | DNS/edge operator review. Keep retired 410 routes as reversible evidence; do not recreate them during restore. |
| DNS zone facts for `natesoc.cloud`, subdomains, Tailscale name, nameservers, SOA, A/AAAA/CNAME records, and observed TTLs | Negligible | Run `dig`/`host` from herdr-ubuntu and save a timestamped, credential-free record/SOA manifest. Separately retain approved Hostinger rollback access; no provider credentials in this document. | Before initial snapshot, before every cutover, and on DNS change under `$ROOT/<id>/host-state/dns/` | **user/operator**; no DNS mutation is part of this plan. Observed natesoc TTL was 0, so verify resolver behavior rather than assuming propagation. |
| Homepage compose/config: `/opt/homepage/docker-compose.yml`, `/opt/homepage/config`, and its read-only Docker socket dependency | 48K observed for `/opt/homepage` | Pull compose and config with rsync; record image tag/digest and mount/port policy. Do not archive a live Docker socket. | Initial now and on change to `$ROOT/<id>/files/opt/homepage/` | Compose is readable now; live Docker inventory is **user-sudo-VPS/group-gated**. Pin an image digest before target restore. |
| Scarjay compose/source and persistent data: `/opt/scarjay-daily`, `/var/lib/scarjay-daily`, and archived compose copies under `/home/nathan/deploy-backups/` | 920K, 136K, and 1.3M respectively | Pull compose/source/data and archive copies. Keep `.env` and `initial-credentials.txt` only in encrypted secret storage or re-issue credentials; record their presence without values. | Initial now and nightly/on change to `$ROOT/<id>/files/scarjay/` | User-readable paths now; live Docker status and hidden mounts are **user-sudo-VPS**. Restore on an isolated port and data directory. |
| Unknown live Docker containers, images, networks, volumes, and environment names | Unknown; Docker API denied the SSH user | Authorized read-only operator captures `docker ps -a`, image digests, networks, mounts, labels, and env variable names. Export only required images/volumes after review; never include secret values. | Initial privileged inventory and on every compose/image change | **user-sudo-VPS/group-gated**. This is a hard completeness gate for a full migration backup. |
| System service definitions: Caddy, natesoc upload/files/Monday/terminal, Frank bridge, Docker/containerd, PostgreSQL, Postfix, Tailscale, Tor, Fail2ban, UFW, and other non-standard units | Selected unit files 4K each; exact total not material | Pull readable unit definitions and record `systemctl` state, `FragmentPath`, user/group, working directory, ports, and environment-file names. Root-only definitions/state require an authorized tar/rsync read. | Initial now and on unit change under `$ROOT/<id>/host-state/systemd/` | Readable natesoc/Frank/OpenClaw definitions now; root-only state/config is **user-sudo-VPS**. Do not start/stop/enable anything during backup or restore. |
| Crontabs, `/etc/cron.d`, systemd timers, and scheduler state | `/etc/cron.d` 48K; Nathan's crontab empty; root/ubuntu/postgres spools unknown | Archive readable `/etc/cron*` and user crontabs; save a sanitized `systemctl list-timers`/unit-state manifest. Read root/ubuntu/postgres spools only with authorized root. Treat `pg_basebackup@.timer` as disabled/inadequate until replaced by the herdr-ubuntu pull cadence. | Initial now and on schedule change under `$ROOT/<id>/host-state/scheduling/` | **user-sudo-VPS** for hidden spools. Never restore a cron/timer into production automatically; review each job. |
| Host access, security, mesh, and local service state: SSH/Tailscale, Tor, UFW/nftables, Fail2ban, Postfix, and related config/data | Several state directories are root-owned; exact total unknown | Preserve readable config and a sanitized state manifest. Capture root-only `/var/lib` state and firewall rules only through an authorized read; do not copy private SSH keys into the ordinary snapshot. OneDrive is an external dependency: back up mount/unit metadata, not an unrelated remote data tree. | On change and before a recovery/cutover under `$ROOT/<id>/host-state/` | **user-sudo-VPS/operator**. Restore only deliberately on a target after access/recovery tests. |
| Secret-bearing dependency references: OpenAI, Gmail monitor, ElevenLabs, Monday API, Scarjay env, TTYD options, TLS private key, and SSH key names | Negligible in the redacted manifest; values intentionally unknown | Maintain a redacted dependency inventory and rotation checklist. Re-issue target credentials; if an approved encrypted secret backup is required, checksum it without exposing contents. | On credential rotation and before target activation under `$ROOT/<id>/host-state/secrets-manifest/` | **operator-secret-store**. No secret value is copied to this plan, return, ledger, or ordinary checksum log. |
| Existing VPS metadata backups: `/var/backups`, `/home/nathan/deploy-backups`, and the local payload-backup directory | 3.6M, 1.3M, and 932K | Pull as historical rollback evidence and checksum them, while labeling `/var/backups` as package/alternatives metadata rather than an application restore point. | Initial now and on change under `$ROOT/<id>/files/existing-backups/` | Runnable for readable paths; never use these artifacts as proof that application restore works. |

Known sizes total approximately 2.94G before PostgreSQL, Docker live state, Caddy private
state, hidden crontabs, and other root-only data. The final snapshot size must be measured
after the privileged inventory; stop if the destination cannot retain N=14 snapshots with
at least one known-good restore point.

## Command skeletons (run locally on herdr-ubuntu)

These are execution templates, not commands run while authoring this plan. Set `ROOT`
to the approved local destination and replace `<id>` with one UTC snapshot identifier.
The commands deliberately use the existing alias and write only to herdr-ubuntu.

### Preflight and readable file pull

```sh
set -euo pipefail
umask 077
ROOT=/home/nathan/backups/herdr-vps
SNAP="$ROOT/<id>"
mkdir -p "$SNAP"/{files,postgres/logical,postgres/physical,host-state,manifests,restore-report}
chmod 700 "$ROOT" "$SNAP"
ssh -o BatchMode=yes -o ConnectTimeout=10 herdr-vps true
df -hT "$ROOT"

mkdir -p "$SNAP/files/home/nathan/.openclaw"
rsync -aH --numeric-ids --protect-args --info=stats2 \
  herdr-vps:/home/nathan/.openclaw/ "$SNAP/files/home/nathan/.openclaw/"

mkdir -p "$SNAP/files/home/nathan/www/natesoc"
rsync -aH --numeric-ids --protect-args --info=stats2 \
  herdr-vps:/home/nathan/www/natesoc/ "$SNAP/files/home/nathan/www/natesoc/"

mkdir -p "$SNAP/files/home/nathan/voice_agent"
rsync -aH --numeric-ids --protect-args --info=stats2 \
  herdr-vps:/home/nathan/voice_agent/ "$SNAP/files/home/nathan/voice_agent/"

for spec in \
  "/home/nathan/upload_server.py home/nathan" \
  "/home/nathan/fileserver.py home/nathan" \
  "/home/nathan/monday-proxy.py home/nathan" \
  "/opt/homepage opt" \
  "/opt/scarjay-daily opt" \
  "/var/lib/scarjay-daily var/lib" \
  "/home/nathan/deploy-backups home/nathan" \
  "/var/backups var"; do
  src=${spec%% *}; dst=${spec#* }
  mkdir -p "$SNAP/files/$dst"
  rsync -aH --numeric-ids --protect-args --info=stats2 \
    "herdr-vps:$src" "$SNAP/files/$dst/"
done
```

Pull readable Caddy and unit files separately so a permission error cannot be mistaken
for a complete archive. Add each file confirmed readable by the privileged inventory;
do not use a broad `--ignore-errors` pull:

```sh
mkdir -p "$SNAP/host-state/caddy" "$SNAP/host-state/systemd" "$SNAP/host-state/scheduling"
rsync -aH --numeric-ids --protect-args herdr-vps:/etc/caddy/ \
  "$SNAP/host-state/caddy/"
rsync -aH --numeric-ids --protect-args herdr-vps:/etc/default/ttyd \
  "$SNAP/host-state/systemd/ttyd.default"
rsync -aH --numeric-ids --protect-args herdr-vps:/etc/cron.d/ \
  "$SNAP/host-state/scheduling/cron.d/"
```

### PostgreSQL logical and physical artifacts (user-sudo-VPS)

Run these from herdr-ubuntu only after an authorized operator has closed the database
gate. `pg_dumpall --no-role-passwords` keeps production role passwords out of the
ordinary globals artifact; if exact ACL/role continuity needs the password-bearing
globals, put that separate stream in the encrypted secret area.

```sh
set -euo pipefail
DBS=$(ssh herdr-vps \
  "sudo -u postgres psql -XAtqc \"select datname from pg_database where datallowconn and not datistemplate order by 1\"")
printf '%s\n' "$DBS" > "$SNAP/postgres/database-list.txt"

tmp="$SNAP/postgres/logical/globals.sql.partial"
ssh herdr-vps 'sudo -u postgres pg_dumpall --globals-only --no-role-passwords' > "$tmp"
test -s "$tmp" && mv "$tmp" "$SNAP/postgres/logical/globals.sql"

while IFS= read -r db; do
  [ -n "$db" ] || continue
  # The allow-list/database-name quoting must be kept; never concatenate an unreviewed
  # value into a shell command without shell-quoting it.
  qdb=$(printf '%q' "$db")
  tmp="$SNAP/postgres/logical/${db}.dump.partial"
  ssh herdr-vps "sudo -u postgres pg_dump --format=custom --no-owner --dbname=$qdb" > "$tmp"
  test -s "$tmp" && mv "$tmp" "$SNAP/postgres/logical/${db}.dump"
done < "$SNAP/postgres/database-list.txt"

# Run only after confirming the v16 client supports stdout tar output and the cluster
# has no unhandled tablespace layout. Otherwise use the SSH-tunnel/local-directory form
# described below; never leave the backup staged on the VPS.
tmp="$SNAP/postgres/physical/base.tar.gz.partial"
ssh herdr-vps \
  'sudo -u postgres pg_basebackup --pgdata=- --format=tar --wal-method=stream \
   --gzip --manifest-checksums=SHA256 --progress' > "$tmp"
test -s "$tmp" && mv "$tmp" "$SNAP/postgres/physical/base.tar.gz"
```

If the physical backup has multiple tablespaces or the installed client does not support
the stdout form, open a loopback-only SSH tunnel and run the same PostgreSQL 16
`pg_basebackup` client against the forwarded endpoint into a local directory; capture
each output tar file in `$SNAP/postgres/physical/`. The operator must record which form
was used and must not create a remote staging directory.

### Checksums and manifest

```sh
set -euo pipefail
cd "$SNAP"
find . -type f ! -name manifest.sha256 -print0 | sort -z | xargs -0 sha256sum > manifest.sha256
sha256sum -c manifest.sha256
find . -type f -printf '%P\t%s bytes\n' | sort > manifests/file-sizes.tsv
find . -type l -printf '%P\t->\t%l\n' | sort > manifests/symlinks.tsv
```

Record the remote command log, source timestamp, tool versions, expected path list, and
any `permission denied`/unknown result beside this manifest. A non-zero checksum or an
unexplained missing path is a failed snapshot, not a warning.

## Execution sequence

The labels identify who must authorize a step. This node performed none of the backup or
restore steps below.

1. **[NOW, no sudo] Preflight herdr-ubuntu.** Confirm the existing alias with
   `ssh -o BatchMode=yes -o ConnectTimeout=10 herdr-vps true`; create the mode-0700 local
   destination; check free space, local encryption, and the retention budget. Record a
   UTC snapshot ID. Do not create a new SSH trust path.
2. **[NOW, read-only] Re-measure the source.** From herdr-ubuntu run `df` and `du` for
   every readable path in the scope table and record command/output. Repeat after any
   long transfer if the source is active. Do not use `sudo`, write redirections on the
   VPS, `systemctl`, Docker mutations, or package commands.
3. **[SUDO-VPS, user approval] Close root/database gates.** An authorized operator
   enumerates PostgreSQL databases/owners/extensions/sizes and captures logical dump
   row/table-count metadata; reads hidden crontabs, Docker live state, UFW/nftables,
   Tailscale/Tor state, and Caddy's private store. If a gap cannot be safely read, mark
   it as a blocker rather than silently declaring the backup complete.
4. **[NOW for readable paths] Take the initial file snapshot.** Pull OpenClaw, the
   natesoc/voice sources, Caddy route/config files, compose/data paths, readable service
   definitions, scheduler files, existing metadata backups, and redacted manifests with
   rsync/tar over `ssh herdr-vps`. Use a temporary local filename for every streamed
   artifact and rename it only after the command exits successfully and the file is
   non-empty.
5. **[SUDO-VPS] Take database artifacts.** Stream globals, one custom-format logical dump
   per enumerated database, and the selected PostgreSQL 16 physical/base backup directly
   to the local snapshot. Do not stage a backup file on the VPS. Capture the installed
   tool versions and the database inventory used to choose the dump set.
6. **[NOW, local] Verify the snapshot.** Generate SHA-256 checksums for every archive and
   regular file, record bytes/file counts and symlink/mode metadata, then run
   `sha256sum -c`. Inspect archive listings, confirm no expected scope row is `MISSING`,
   and keep the source command log with the snapshot. A checksum proves transfer
   integrity; it does not prove that an application can restore.
7. **[SUDO-LOCAL only if needed] Perform the restore rehearsal below.** Use a disposable
   local PostgreSQL 16 instance/container and scratch directories on herdr-ubuntu. Bind
   only to loopback or an isolated network; do not point any service or DNS record at it.
8. **[GATE] Record PASS/BLOCK.** PASS requires every required asset to have a verified
   artifact and the restore criteria below to pass. A root-only or Docker gap is a
   BLOCK for a full migration/retire decision unless the user explicitly narrows the
   scope and records that residual risk. Only after PASS may a separate approved task
   stage target services, cut traffic, or retire VPS workloads.

## Concrete restore rehearsal

Create a disposable local test root such as `/tmp/herdr-vps-restore-<id>` or an
operator-owned scratch directory. Never extract into `/etc`, `/var/lib/postgresql`, a
live application directory, or the VPS. Start with a clean scratch area and retain the
restore report until the next successful rehearsal.

### 1. Artifact and file restore

- Run `sha256sum -c` against the snapshot manifest before extraction; require zero
  failures and non-zero sizes for every expected artifact.
- Restore `files/home/nathan/www/natesoc` into a scratch web-root directory and compare
  file names, symlinks, modes, byte counts, and SHA-256 values. Run `diff -qr` (with an
  explicit documented exclusion list for any volatile cache) and spot-check the static
  entry points and upload/file data directories.
- Restore the OpenClaw tree into scratch without starting either user unit. Verify the
  manifest and representative task/run, workspace, agent, memory-backup, and SQLite
  artifacts; where `sqlite3` is available, run read-only `PRAGMA integrity_check` on
  each identified database copy. Test only with newly issued/test credentials.
- Restore Caddy, service, compose, and scheduler files into scratch paths. Run
  `caddy validate --config <scratch>/etc/caddy/Caddyfile` and
  `systemd-analyze verify` against copied unit files where the tools are available.
  Confirm all expected routes, 410 responses, localhost ports, working directories,
  and secret-file references are present. Do not run `systemctl` against the source or
  enable any restored unit.
- Run `docker compose config` against the restored Homepage and Scarjay definitions
  using temporary test environment values, then inspect that mounts, ports, restart
  policy, and image digests match the manifest. If the privileged inventory found
  additional volumes/images, restore and test those explicitly; unknown live Docker
  state is not a PASS.

### 2. PostgreSQL logical restore

1. Provision a disposable PostgreSQL **16** cluster/container on herdr-ubuntu, with a
   random loopback-only port and no public exposure. Use a pinned, already-approved
   local runtime/image; package installation is outside this plan.
2. Apply the globals/roles artifact in the disposable cluster only after reviewing it.
   If the ordinary globals dump omitted passwords, inject test credentials or new
   target credentials; do not need or copy production password values.
3. Create each database named by the source inventory, restore its custom dump with
   `pg_restore --exit-on-error`, and capture the restore log. Recreate required
   extensions and tablespaces in the disposable environment or record why a target
   equivalent is intentionally absent.
4. Compare source dump metadata with the restored catalog: database list, owners,
   schemas, table/index counts, extension list, and the row-count/checksum probes
   captured at dump time. Run application-level read-only smoke queries for each
   known consumer (including Scarjay/OpenClaw only where the dependency is confirmed).

Logical restore PASS means every enumerated database restored with exit status 0 and
no unreviewed errors, catalog/object counts match the source evidence, required
extensions are present, and the smoke queries return expected results. If the source
database inventory was not authorized or row-count evidence was not captured, the
logical restore is BLOCKED rather than inferred from a successful `pg_restore`.

### 3. PostgreSQL physical restore

- Extract the physical tar artifact into a disposable directory and run
  `pg_verifybackup` against the extracted backup manifest; require a clean result.
- Restore/start it with a PostgreSQL 16 disposable instance on loopback only, using a
  temporary port and no production credentials. Confirm the cluster starts, accepts a
  local connection, exposes the expected databases, and passes the same read-only
  catalog/smoke checks as the logical restore.
- Stop and delete only the disposable local instance after retaining its report. Never
  test the base backup by replacing or stopping the VPS cluster.

Physical restore PASS requires both manifest verification and a successful disposable
cluster start/read test. A tar listing alone is not evidence of a usable PostgreSQL
restore.

### 4. Restore report and gate evidence

Write a report beside the snapshot containing snapshot ID, source host, artifact list,
byte sizes, SHA-256 results, tools/versions, source catalog evidence, scratch paths,
restore commands (without secret arguments), start/end times, and PASS/BLOCK reasons.
The report must explicitly list any unavailable root/Docker asset. The migration/retire
gate is PASS only when the file/config tests, logical PostgreSQL test, selected physical
PostgreSQL test, and all required asset coverage checks pass.

## Recurring cadence on herdr-ubuntu

After the initial snapshot and restore PASS, create a local pull script and a
`systemd --user` service/timer (or a reviewed system timer if the operator needs root)
on herdr-ubuntu. The script must:

1. acquire a lock so two pulls cannot overlap;
2. create a new mode-0700 snapshot directory and use the existing `herdr-vps` alias;
3. pull user-readable files nightly at 02:15 UTC;
4. run the authorized PostgreSQL logical dump nightly and physical/base backup weekly;
5. write checksums and a source/transfer manifest, fail closed on any missing expected
   asset, and leave the previous snapshot untouched on failure;
6. run the retention policy only after checksum verification; and
7. alert the operator on SSH, dump, checksum, capacity, or restore-test failure.

The initial follow-up schedule is:

| Job | Cadence | Retention / test |
|---|---|---|
| File/config/OpenClaw/compose pull | Nightly | 7 daily promoted snapshots; unchanged files may use `--link-dest` |
| PostgreSQL logical dumps | Nightly | 7 daily, 4 weekly, 3 monthly; retain globals with each promoted set |
| PostgreSQL physical/base backup | Weekly | 4 weekly and 3 monthly, each `pg_verifybackup`-checked |
| DNS/TLS/route and scheduler manifests | Before every change and nightly | Included in each promoted snapshot; no secret values |
| Full disposable restore rehearsal | Monthly and after backup-method/schema/host changes | Must pass before migration/retire work resumes |

An unattended timer cannot safely perform the root-only VPS reads unless an authorized
operator has already arranged a narrowly scoped, auditable privilege path. If that is
not available, keep those artifacts as an explicit manual weekly step and keep the
full migration gate BLOCKED. Do not solve this by adding a new SSH trust or copying
secrets into a cron file.

## Immediate versus gated work

Runnable immediately from herdr-ubuntu: local capacity/destination setup, existing-alias
connectivity check, read-only sizing, pulling readable user/application/config files,
DNS/TLS public metadata capture, checksums, and scratch file/config restore tests.

Requires user-sudo-VPS or an authorized operator: PostgreSQL catalog/dumps/base backup,
root/ubuntu/postgres crontabs, Docker live state/volumes/images, Caddy's private ACME
store, UFW/nftables, root-owned Tailscale/Tor state, and any unreadable service data.

May require user-sudo-local: a root-owned destination/timer, a disposable local
PostgreSQL/container runtime, or local encrypted-secret storage. The home-directory
destination and scratch tests do not inherently require local root when the required
runtime already exists.

No migrate, retire, disable, delete, DNS cutover, public exposure, or source-service
stop is authorized by this plan. Those actions remain blocked until the initial off-host
snapshot is checksum-verified, every required scope gap is closed or explicitly accepted
by the user, and the disposable restore rehearsal has a recorded PASS.

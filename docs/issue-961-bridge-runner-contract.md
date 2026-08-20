# Issue #961 bridge staging and Excel runner contract

This repository owns two Windows-side entry points for the OneDrive review lane:

- `scripts/windows/Stage-HerdrReviewWorkbook.ps1` accepts one workbook in the
  configured Windows OneDrive `Inbox` and creates one collision-resistant job
  directory below the configured local bridge staging root.
- `scripts/windows/Invoke-HerdrExcelJob.ps1` accepts one reviewed job definition
  and runs the finite `recalculate` operation in the designated interactive
  Excel session.

## Operating route and runtime configuration

Ubuntu does not install or run OneDrive or rclone for this lane. A finite
payload is transferred over SSH to `herdr-win` into the Windows OneDrive
exchange configured on that host. Windows alone owns OneDrive synchronization,
staging, and Excel execution. The route must not synchronize the same OneDrive
account concurrently from Ubuntu and Windows.

Production entry points require a host-owned JSON file selected by
`-RuntimeConfigurationPath` or `HERDR_WINDOWS_REVIEW_CONFIG`. Start from
`config/windows-review-runtime.example.json`, fill it in outside Git, and set
`approved` to `true` only after commissioning. The configuration must contain
the schema `herdr-windows-review-runtime-v1`, the OneDrive exchange root and
account, the local bridge staging root, the host-owned local Excel review-job
root, the reviewed-tools root, and the designated interactive/bridge SIDs.
All four roots must be distinct; the local roots and configuration file must
be outside the OneDrive exchange root. The configuration file itself is a
non-reparse, host-owned ACL-protected file that the bridge account cannot
write. Missing, unapproved, malformed, reparse-point, overlapping, or
otherwise inconsistent configuration fails closed. No machine-specific
absolute path is committed here.

Before staging or Excel work, commissioning must prove that the native
OneDrive client is running in the designated interactive Windows session and
that its signed-in account owns the configured OneDrive root. The runner also
proves the current process and Explorer identity/session. A cold Windows boot
may leave Ubuntu and SSH available, but the workbook lane remains unavailable
until this interactive OneDrive/Excel precondition is true.

## Staging schema

The staging helper emits `staging-provenance.json` with schema
`herdr-review-staging-v1`. The source and bridge-stage records contain the
canonical path, extension, size, last-write time, and SHA-256. The manifest
also records the exact configured Inbox, Outbox, Archive, and local staging
roots, the locked workbook allowlist, repository/branch/commit provenance, and
`source_preserved=true`.

The exact workbook allowlist is `.xlsx`, `.xlsm`, and `.xlsb`. The helper rejects
all other extensions, device/UNC paths, traversal outside the configured Inbox,
symlinks, junctions, mount points, and unrecognized reparse tags. The only
accepted reparse case is a native Cloud Files directory tag on the path to a
configured OneDrive exchange root or one of its Inbox/Outbox/Archive children;
workbook files themselves must remain non-reparse and fully hydrated. The
configured exchange root used for Cloud Files tag admission is not a general
containment root for every physical proof; lexical and final-handle containment
continues to be enforced by the dedicated trusted-root and exchange-boundary
checks. Offline/
Recall attributes, hard-linked sources, unstable exclusive reads, collisions,
and source/stage size, hash, or physical file-identity mismatches are also
rejected. Windows production paths are proven through no-follow handles,
final-handle paths, volume/file identities, and revalidation before and after
read/copy/hash transitions. Managed-directory creation, temp file creation,
atomic text output, atomic commit/rename, and failure cleanup are
handle-relative to pinned no-follow directory handles; path checks are
test-only seams on non-Windows hosts. Destination parents are likewise tied to
their trusted job root before commit and the committed leaf is re-proven
afterward. It never deletes or moves the Inbox original.

## Job schema and Excel boundary

The runner accepts only JSON objects with schema `herdr-excel-job-v1` and these
fields:

- required: `schema`, `job_id`, `operation`, `staging_manifest`;
- optional provenance: `source_repository`, `source_branch`, `source_commit`;
- optional named approval record: `approval_name`, `approver`, `approved_utc`,
  `scope`, and `reason` under `trust_approval`.

The only operation is `recalculate`. Unknown fields, arbitrary input/output
paths, PowerShell, commands, scripts, macros, and other operations are
rejected. The runner re-hashes the canonical OneDrive Inbox source and bridge
stage, reads JSON through a supported `FileStream`-backed UTF-8 reader over the
validated native handle, copies the accepted stage into the configured
host-owned local review-job workspace, and opens only that last-mile copy. The
source and last-mile hashes are checked again after Excel. Results and compact
provenance/log records are copied to the configured local output and the
OneDrive Outbox; the configured OneDrive Archive is validated as a distinct
Cloud Files directory under the configured exchange boundary. The runner
never opens an exchange/OneDrive copy directly, and never moves or deletes the
Inbox original.

Excel automation is default-deny: `AutomationSecurity=ForceDisable`, links are
not updated, data connections cannot refresh, events are disabled, and no
Trusted Location is configured. A named approval is provenance only; this
version exposes no operation that turns any default-deny control on.

Production execution requires the runtime configuration's designated user
SID, interactive session ID, and fixed non-admin bridge-account SID. The runner
proves the current process, Explorer, OneDrive process, and signed-in OneDrive
account before work, then Windows Authz evaluates effective bridge access to
every host-owned tools or review-job root; any effective write grant is denied.
Effective-access evaluation does not generate Authz audits or require
`SeAuditPrivilege`: the bridge initializes its Authz resource manager with
`AUTHZ_RM_FLAG_NO_AUDIT` for an access decision only. Central-access-policy
behavior remains unchanged.
Test probes are available only behind the explicit hermetic `-TestMode` seam;
the production wrappers expose no bridge-account or path override.

# Issue #961 bridge staging and Excel runner contract

This repository owns two Windows-side entry points for the OneDrive review lane:

- `scripts/windows/Stage-HerdrReviewWorkbook.ps1` accepts one configured Inbox workbook and creates one collision-resistant job directory under `C:\HerdrExchange\in`.
- `scripts/windows/Invoke-HerdrExcelJob.ps1` accepts one reviewed job definition and runs the finite `recalculate` operation in the designated interactive Excel session.

## Staging schema

The staging helper emits `staging-provenance.json` with schema
`herdr-review-staging-v1`. The source and bridge-stage records contain the
canonical path, extension, size, last-write time, and SHA-256. The manifest also
records the exact configured Inbox and exchange roots, the locked workbook
allowlist, repository/branch/commit provenance, and `source_preserved=true`.

The exact workbook allowlist is `.xlsx`, `.xlsm`, and `.xlsb`. The helper rejects
all other extensions, device/UNC paths, traversal outside the configured Inbox,
reparse points (including every ancestor), Offline/Recall attributes, hard-linked
sources, unstable exclusive reads, collisions, and source/stage size, hash, or
physical file-identity mismatches. Windows production paths are proven through
no-follow handles, final-handle paths, volume/file identities, and revalidation
before and after read/copy/hash transitions. Destination parents are likewise
tied to their trusted job root before commit and the committed leaf is re-proven
afterward. It never deletes or moves the Inbox original.

## Job schema

The runner accepts only JSON objects with schema `herdr-excel-job-v1` and these
fields:

- required: `schema`, `job_id`, `operation`, `staging_manifest`;
- optional provenance: `source_repository`, `source_branch`, `source_commit`;
- optional named approval record: `approval_name`, `approver`, `approved_utc`,
  `scope`, and `reason` under `trust_approval`.

The only operation is `recalculate`. Unknown fields, arbitrary input/output
paths, PowerShell, commands, scripts, macros, and other operations are rejected.
The runner re-hashes the canonical Inbox source and bridge stage, copies the
accepted stage into protected `C:\HerdrReviewJobs\<job-id>`, and opens only that
last-mile copy. The source and last-mile hashes are checked again after Excel
and the result is copied into both `C:\HerdrExchange\out\<job-id>` for the
Ubuntu bridge and the configured OneDrive `Outbox\<job-id>` for human review.
The configured OneDrive `Archive` is validated as a distinct, non-reparse root;
the runner does not move or delete the Inbox original.

Excel automation is default-deny: `AutomationSecurity=ForceDisable`, links are
not updated, data connections cannot refresh, events are disabled, and no
Trusted Location is configured. A named approval is provenance only; this
version exposes no operation that turns any default-deny control on.

The result manifest uses `herdr-excel-job-result-v1` and records source,
bridge-stage, last-mile, and result paths/hashes, timestamps, repository
provenance, the operation, approval record, and security decisions. A compact
job log is written under `C:\HerdrExchange\logs`; neither contains workbook
content or credentials.

Production execution requires deployment configuration for
`HERDR_DESIGNATED_INTERACTIVE_USER_SID`,
`HERDR_DESIGNATED_INTERACTIVE_SESSION_ID`, and
`HERDR_BRIDGE_ACCOUNT_SID`. The runner proves the current process, Explorer,
and Excel owner/session against the first two values. The fixed local
`HerdrBridge` account and its complete effective group membership are checked
against the third value and are denied write access to every host-owned tools or
review-jobs root. Test probes are available only behind the explicit hermetic
`-TestMode` seam; the production wrapper exposes no bridge-account override.

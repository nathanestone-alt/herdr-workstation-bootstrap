# Issue #961 bridge consumables record

This is the clean bootstrap-repository handoff for #957. Pin the final commit
reported in the node return artifact on branch
`codex/issue-961-bridge-helpers`; no OneDrive, Excel, SSH, or host commissioning
was performed by this change.

## Exact consumables

| Purpose | Path | Entry points or seams |
|---|---|---|
| Staging implementation | `scripts/windows/HerdrReviewStaging.ps1` | `Invoke-HerdrReviewStaging`, `Get-HerdrFileSnapshot`, `Copy-HerdrFileExclusive`, `Assert-HerdrWorkbookFile` |
| Staging production wrapper | `scripts/windows/Stage-HerdrReviewWorkbook.ps1` | Runtime, identity, bridge-ACL, and OneDrive readiness gates |
| Runner implementation | `scripts/windows/HerdrExcelJobRunner.ps1` | `Read-HerdrExcelJob`, `Get-HerdrManifestRecord`, `Invoke-HerdrExcelJob`, `Invoke-HerdrExcelRecalculate` |
| Runner production wrapper | `scripts/windows/Invoke-HerdrExcelJob.ps1` | Runtime-configured job invocation; no test-mode switch |
| Host-owned ACL policy | `scripts/windows/HerdrHostOwnedAclPolicy.ps1` | `Protect-HostOwnedTree` |
| Runtime shape | `config/windows-review-runtime.example.json` | `herdr-windows-review-runtime-v1` |
| Staging tests and mutation fixture | `tests/Test-HerdrReviewStaging.ps1` | Hydration, exclusive stability, path/job allowlists, and extension-guard mutation check |
| Runner tests | `tests/Test-HerdrExcelJobRunner.ps1` | Job schema, provenance, stage/last-mile hash gates, session, ACL, collision, and command rejection |

## Schemas to pin

- Runtime configuration: `herdr-windows-review-runtime-v1`.
- Staging provenance: `herdr-review-staging-v1`, with `source`,
  `bridge_stage`, `source_preserved`, configured Inbox/Outbox/Archive and
  exchange roots, locked `.xlsx`/`.xlsm`/`.xlsb` allowlist, and repository,
  branch, and commit provenance.
- Job input: `herdr-excel-job-v1`; required fields are `schema`, `job_id`,
  `operation`, and `staging_manifest`; the only operation is `recalculate`.
- Result provenance: `herdr-excel-job-result-v1`, with source, bridge-stage,
  protected last-mile, result, OneDrive-Outbox, security, and optional named
  `trust_approval` records.
- Job log: `herdr-excel-job-log-v1`.

The protected last-mile record explicitly carries
`immutable_for_bridge_account=true`; the runner opens only that local copy.
The Inbox original is never moved or deleted.

## Windows-only seams

Ubuntu `pwsh` tests use explicit `-TestMode` seams: staging's
`BetweenSourceReads`; runner `InteractiveSessionProbe`/`IdentityProbe`,
`OneDriveReadyProbe`, `HostOwnedAccessProbe`, `HostOwnedTreeProtector`,
`ExcelInvoker`, `ExcelProcessProbe`, and `AfterExcelHook`; and ACL
`AclReader`, `GroupSidReader`, and `BridgeIdentityProbe`. Production wrappers
do not expose `-TestMode` or path overrides. Native OneDrive attributes,
no-follow handles, final paths, file identities, session/process identities,
Authz, and ACLs stay in the Windows implementation; seams only supply
deterministic test observations and cannot authorize an operation. Hermetic
runner execution requires the tree-protection seam, so a test cannot emit a
protected-last-mile claim without modeling that gate.

## File hashes

These SHA-256 values are computed from the final committed blobs and are the
values #957 should verify after pinning the returned commit. The consumables
record intentionally does not self-list its own hash.

| Path | SHA-256 |
|---|---|
| `config/windows-review-runtime.example.json` | `c891cc842279ff36af03eae7d16b415db504276aa3982efc764265af7f415c89` |
| `scripts/windows/HerdrReviewStaging.ps1` | `4c75d64721bddee7bdbcb99a0c7d8f2eb9f3738599d252290c2aa2a5137d839c` |
| `scripts/windows/Stage-HerdrReviewWorkbook.ps1` | `3131be6149d1d1a7c4693809f3bee09b50e381176df2cec220094912b6fcbf89` |
| `scripts/windows/HerdrExcelJobRunner.ps1` | `3f94861157e9ebaf7fb63a2a89ca73ff88b93bbeb61bd69d4563e4da5735b675` |
| `scripts/windows/Invoke-HerdrExcelJob.ps1` | `78a47af85b02789c765829bb5f7bd480115e4771faa303a2180848b69bc22130` |
| `scripts/windows/HerdrHostOwnedAclPolicy.ps1` | `100f8d875daec671f0b1209c3bbe7e8c4f3c8aad580e02920325ae03c094af05` |
| `tests/Test-HerdrReviewStaging.ps1` | `7d699d05f90fb7236aac4525fe924bde9cee4ba75e7657440677eef6fcafae56` |
| `tests/Test-HerdrExcelJobRunner.ps1` | `0bd4032ab6ece01fe5b86a08e779829ac157fc7c78b509119a18ab7045525baf` |

## Exact validation commands

Run from the repository root:

```text
pwsh -NoLogo -NoProfile -File tests/Test-HerdrReviewStaging.ps1
pwsh -NoLogo -NoProfile -File tests/Test-HerdrExcelJobRunner.ps1
for test in tests/test-*.sh; do bash "$test"; done
for script in $(git ls-files '*.sh'); do bash -n "$script"; done
pwsh -NoLogo -NoProfile -File scripts/Validate-Repository.ps1
```

The full matrix must retain the repository's documented pre-existing
`tests/test-bootstrap-fencing.sh` host/environment failure if it reproduces at
the base. Windows validation still includes PowerShell parsing and the native
path, ACL, session, OneDrive, and Excel commissioning checks on `herdr-win`.

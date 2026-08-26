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
  `trust_approval` records plus `trust_approval_verified=false`.
- Job log: `herdr-excel-job-log-v1`.

The result's protected last-mile record carries `protected` and
`immutable_for_bridge_account` as the observed boolean results of the
host-owned tree-protection and bridge-write-denial checks; a test-mode value is
only the corresponding probe observation. The runner opens only that local
copy. The Inbox original is never moved or deleted.

`trust_approval`, when present, is a declarative caller assertion. It is
shape-checked only, corroborated by nothing host-owned, and must not be treated
as proof of human approval. `trust_approval_verified` is always `false` in
this schema. A host-owned approval store is deferred to #957 live commissioning.

## Windows-only seams

Ubuntu `pwsh` tests use explicit `-TestMode` seams: staging's
`BetweenSourceReads` (the helper rejects it without `-TestMode`); runner
`InteractiveSessionProbe`/`IdentityProbe`, `OneDriveReadyProbe`,
`HostOwnedAccessProbe`, `HostOwnedTreeProtector`, `ExcelInvoker`,
`ExcelProcessProbe`, and `AfterExcelHook`; and ACL `AclReader`,
`GroupSidReader`, and `BridgeIdentityProbe`. The OneDrive and host-owned
protection gates reject missing observations in test mode, and the access and
protection probes must report a successful observation before it is recorded.
Production wrappers do not expose `-TestMode` or path overrides. Native
OneDrive attributes, no-follow handles, final paths, file identities,
session/process identities, Authz, and ACLs stay in the Windows
implementation; seams only supply deterministic test observations and cannot
authorize an operation. Hermetic runner execution requires the tree-protection
seam, so a test cannot emit a protected-last-mile claim without modeling that
gate.

## File hashes

These SHA-256 values are computed from the final committed blobs and are the
values #957 should verify after pinning the returned commit. The consumables
record intentionally does not self-list its own hash.

| Path | SHA-256 |
|---|---|
| `config/windows-review-runtime.example.json` | `c891cc842279ff36af03eae7d16b415db504276aa3982efc764265af7f415c89` |
| `scripts/windows/HerdrReviewStaging.ps1` | `a515a62a05ffd798a13465a980ffb673ef3563dc8a9eafc7f026c309a56dddea` |
| `scripts/windows/Stage-HerdrReviewWorkbook.ps1` | `3131be6149d1d1a7c4693809f3bee09b50e381176df2cec220094912b6fcbf89` |
| `scripts/windows/HerdrExcelJobRunner.ps1` | `e7d96816b3883eef97760ef53a420f34eee56cde73f7b3416ed23e156bd361ec` |
| `scripts/windows/Invoke-HerdrExcelJob.ps1` | `78a47af85b02789c765829bb5f7bd480115e4771faa303a2180848b69bc22130` |
| `scripts/windows/HerdrHostOwnedAclPolicy.ps1` | `100f8d875daec671f0b1209c3bbe7e8c4f3c8aad580e02920325ae03c094af05` |
| `tests/Test-HerdrReviewStaging.ps1` | `5eab29c6fe7cbd0e9fad12bb42c12765c2ad116db3133423b50cf2a9fe1abb42` |
| `tests/Test-HerdrExcelJobRunner.ps1` | `3a667077074c31221df296f67d7774f59acf36ea16e6e2018b2e9e436bea2bf1` |

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

VERDICT: BLOCK

CLAIMS

- Independently reviewed candidate `f701e3213c8aef3cc950213cec7234461e771e97` against base `cbc43993769cb32a2aa2aef79f8a6ab7dece9c08`.
- Reviewed all seven changed source/test/doc files, direct Windows helper dependencies, the immutable consumer contract, Decision 28 Amendment A3, and the account-scope approval.
- The producer/consumer JSON field interface is structurally compatible, but the authority producer is not safe to commission because three trust-boundary defects remain.

CARDINALITY

- P1: 1
- P2: 2
- P3: 0
- All P1/P2 findings are blocking.
- P3 disposition: none identified; no P3 is being deferred.

FINDINGS

P1 — The ACL proof does not establish effective runtime immutability or secure the authority’s ancestors.

`scripts/windows/HerdrHostOwnedAclPolicy.ps1:68-69` and `:114-115` enumerate only the supplied root and its descendants. `scripts/windows/WindowsReceiptAuthority.ps1:320` and `:351` supply only `C:\ProgramData\STModel\Issue961`, leaving `C:\ProgramData\STModel` and other mutable ancestors outside the ACL assertion. In addition, `scripts/windows/HerdrHostOwnedAclPolicy.ps1:129-153` evaluates ACEs by their literal SID and checks write bits only on the explicit reader-SID ACE, while `:145-148` deliberately grants BUILTIN\Administrators FullControl. It never checks whether `HERDR-WIN\rdp-natha` belongs to Administrators or another effective writer group.

Consequence: the producer can publish and report success without proving that the runtime account lacks effective write/delete authority, and without proving that an ancestor cannot rename or replace the protected authority subtree. This violates the locked ACL/effective-rights/ancestor requirement and can make the trusted authority runtime-mutable or substitution-prone.

P2 — Two individually atomic replacements do not provide coherent authority/receipt publication under held handles.

`scripts/windows/Install-WindowsReceiptAuthority.ps1:78-82` replaces the fixed receipt first and the authority second. Each replacement occurs independently at `scripts/windows/WindowsReceiptAuthority.ps1:333-334`, with no rollback or generation-specific receipt path. A consumer may already hold the old authority with delete sharing denied while not yet holding the receipt. In that valid interleaving, receipt replacement succeeds, authority replacement fails with a sharing violation, and the old authority permanently points to a receipt whose hash and contents have changed.

Consequence: an ordinary concurrent consumer can make Install fail after committing half the publication, stranding an invalid authority/receipt pair until a later successful repair. This contradicts the required held-handle-compatible atomic publication and exact failure/cleanup behavior.

P2 — The uv probe does not require the commissioned WinGet reparse-link identity.

`scripts/windows/WindowsReceiptAuthority.ps1:105` explicitly accepts a non-reparse command by returning its own path. `:221-228` permits either form and records `command_path_is_reparse = false` when applicable. `scripts/windows/Install-WindowsReceiptAuthority.ps1:70-72` checks only the reported `uv 0.12.5` version; it does not require a reparse leaf or bind the command path to the WinGet link location.

Consequence: any directly executable `uv` 0.12.5 found first on PATH can be commissioned, despite the frozen requirement for the actual WinGet reparse link and its real resolved target. The fixture at `tests/Test-WindowsReceiptAuthority.ps1:48` and `:56-57` only supplies a synthetic true-valued envelope; it does not exercise rejection of a direct executable.

CHANGES

- None. Review was read-only; no files, commits, installs, authority state, or host state were changed.

CHECKS

- HEAD: `f701e3213c8aef3cc950213cec7234461e771e97`.
- Worktree status: clean.
- `git diff --check cbc43993769cb32a2aa2aef79f8a6ab7dece9c08 f701e3213c8aef3cc950213cec7234461e771e97`: PASS.
- All seven candidate file SHA-256 values match the builder report.
- Confirmed the producer’s fixed path, authority ID, receipt fields, Python 3.13.15 object, launcher object, source/payload/allowlist bindings, role-manifest hash, platform, architecture, and receipt hash are shaped compatibly with the immutable consumer.
- Builder evidence records focused fixture PASS, PowerShell sweep 5 PASS/4 expected non-Windows SKIP/0 FAIL, parser sweep PASS, and repository validator INCOMPLETE after its 120-second cap.
- Tests were not rerun because execution mode was read-only and the focused fixtures create temporary files.
- No native Windows deployment, ACL/effective-access probe, held-handle interleaving test, authority publication, or consumer replay exists; none is inferred.

OPEN

1. Protect and assert the complete fixed-path ancestor trust boundary, and fail closed unless the actual runtime account has no effective write/delete rights through group membership.
2. Redesign publication so failure replacing the authority cannot invalidate the previously committed authority/receipt generation; add a held-authority-before-receipt interleaving regression.
3. Require the uv command leaf to be the approved WinGet reparse link, validate its allowed parent topology, and reject a direct PATH executable.
4. After correction and independent source review, perform the separate native Windows commissioning/acceptance node, including negative effective-write proof and consumer replay.

BLOCK FOR CORRECTION

VERDICT: BLOCK

CLAIMS

- The three accepted R1 defects are corrected in the working-tree bytes: actual-process-token
  `AccessCheck` proof plus retained ancestor handles; first-install-only atomic directory
  publication; and canonical WinGet Links `uv.exe` reparse/target/hash enforcement.
- The actual runtime token is opened from the supplied PID and bound to the supplied UTC process
  creation time, session ID, and resolved `HERDR-WIN\rdp-natha` SID. Windows evaluates the token's
  enabled and deny-only groups; caller booleans are not accepted. Any effective mutation access to
  the Issue961 tree fails closed. Ancestors are checked only for delete-child/delete/change-ACL/
  change-owner rights, avoiding a broad ProgramData ACL rewrite.
- Publication refuses any existing Issue961 directory or fixed file before mutation. Both files
  are written, ACL-converged, and coherency-checked in a private sibling directory; one atomic
  directory rename publishes the pair. A held old authority therefore causes refusal before either
  old file changes, and failed staging is removed without exposing a fixed-path partial pair.
- `uv` is resolved directly at the runtime profile's
  `AppData\Local\Microsoft\WinGet\Links\uv.exe`; the leaf must be a reparse link, its ancestors
  must be non-reparse, its target must be a non-reparse regular file beneath the approved
  `astral-sh.uv_Microsoft.Winget.Source_*` package topology, and its bytes must equal the separately
  commissioned target SHA-256 before version probing.
- The authority/receipt JSON schema and fixed native receipt locator are unchanged. The immutable
  consumer at `/tmp/stmodel-1074-runtime-review-fb02f8d2` still requires the exact existing key set,
  so no new JSON keys were introduced.
- No commit is claimed. The required source commit could not be created because the linked-worktree
  index metadata is read-only in this sandbox.

CARDINALITY

- Accepted findings addressed in source: P1 1, P2 2, P3 0.
- Working-tree deliverables: 8 files (6 modified, 2 added), excluding this report and the required
  `.node-return.md` transport artifact.
- Entry tracked HEAD: `35bc5ec1d758075e86430e597aa004c0defcfff0` on
  `issue-1074/windows-authority-20260905`; tracked tree was clean at entry. This HEAD consists of
  source `f701e3213c8aef3cc950213cec7234461e771e97` plus the two prior report-only commits.

CHANGES

- `scripts/windows/HerdrWindowsRuntimeTokenAccess.ps1` (added): real process/token acquisition,
  PID/creation/session/SID binding, elevation and Administrators group-attribute evidence, and
  native file-object `AccessCheck`.
- `scripts/windows/HerdrHostOwnedAclPolicy.ps1`: retained no-delete-share handles for every fixed
  namespace ancestor plus precise ancestor and authority-tree effective-access checks.
- `scripts/windows/WindowsReceiptAuthority.ps1`: canonical WinGet link and package-target policy,
  commissioned target-byte hash binding, atomic first-install directory publication, staged pair
  coherency validation, and effective-token enforcement in Check mode.
- `scripts/windows/Install-WindowsReceiptAuthority.ps1`: mandatory runtime process tuple and uv
  target hash inputs, real token proof lifetime, first-install publication, and explicit token
  evidence output.
- `tests/Test-WindowsAuthorityNative.ps1` (added): native actual-token positive-write detection,
  missing/direct/foreign/wrong-hash uv negatives, held-authority refusal with byte preservation,
  and failed-stage/no-partial-publication regression.
- `tests/Test-WindowsReceiptAuthority.ps1`: updated schema fixture and source contract assertions.
- `scripts/Validate-Repository.ps1`: native fixture registration and anti-deletion tripwires.
- `docs/windows-receipt-authority.md`: exact runtime-process proof inputs, WinGet target hash input,
  first-install-only publication contract, effective-rights semantics, and consumer handoff.

Exact working-tree SHA-256 values:

- `979e484d5fa947449ce268aae508e4bd96b98241ebc221344dd72f1ea4e32574`  `docs/windows-receipt-authority.md`
- `cb19ba2d06fc512efbd67f0f576cdf3941818accc22719aaa260665268a5e8d2`  `scripts/Validate-Repository.ps1`
- `b4a7a644d475b6b7068b7de1ab2a72fda568c3d278a76d9014497a60a9e0850f`  `scripts/windows/HerdrHostOwnedAclPolicy.ps1`
- `777297681c1c185a1853a0f06eedbec5f0ecca21feb769fb5af16ab6774f3af5`  `scripts/windows/Install-WindowsReceiptAuthority.ps1`
- `c9cda441f180b97c9e623e04afdc289248d2021651748690e0c294e2c6104e44`  `scripts/windows/WindowsReceiptAuthority.ps1`
- `05d9b3bb07c6cd26b59ec9f7faffcde5bbaba49f7b94f079374ace4779e401b6`  `scripts/windows/HerdrWindowsRuntimeTokenAccess.ps1`
- `40cbae5ecb968ef9f9bbe683b013ab5090290d2d27c9b787fd2dcbeeb745e2a8`  `tests/Test-WindowsReceiptAuthority.ps1`
- `66656632b56231e0da43a2689f300b0f7f112451061df017787c80f27989aba9`  `tests/Test-WindowsAuthorityNative.ps1`

CHECKS

- PowerShell parser sweep over the 7 changed/added `.ps1` implementation/test/validator files:
  PASS, exit 0.
- Extracted companion C# `Add-Type` compilation: PASS, exit 0.
- `tests/Test-WindowsReceiptAuthority.ps1`: PASS, exit 0.
- `tests/Test-HostOwnedAclPolicy.ps1`: expected non-Windows SKIP, exit 0.
- `tests/Test-WindowsAuthorityNative.ps1`: expected non-Windows SKIP, exit 0.
- `git diff --check`: PASS, exit 0.
- Whole-repository validation: NOT RUN, per the brief's instruction not to repeat the prior
  over-120-second broad validator during this correction node.
- nativeNOTRUN: no Windows token/ACL/link/publication fixture execution, commissioning, authority
  write, host ACL/account mutation, deployment, install, or consumer replay occurred.

OPEN

1. Mechanical host-side commit is required. Exact failure from `git add`:
   `fatal: Unable to create '/home/nathan/code/herdr-workstation-bootstrap/.git/worktrees/issue-1074-windows-authority-20260905/index.lock': Read-only file system`.
   Per the node brief, this sandbox did not retry or claim a commit.
2. The host finalizer must verify the eight hashes above, stage exactly those eight paths plus this
   report as appropriate, create the required commit(s), and confirm a clean tracked candidate
   before independent review. No push/merge/PR is authorized here.
3. Native Windows review/acceptance must run the new fixture and commissioning checks. In
   particular, the approved account's direct Administrators membership is not itself rejection:
   the actual runtime process token must be UAC-filtered/deny-only or otherwise have no effective
   prohibited rights. An elevated enabled-Administrators runtime token must fail.
4. Consumer enforcement handoff: the STModel consumer must open and bind its own live runtime
   process token and apply handle-bound effective-access checks before trusting the authority. It
   must not treat this producer's commissioning result, group membership, or any caller boolean as
   proof for a later process.

# Issue 1074 Windows authority native-positive source build R3

CLAIMS

- Entry HEAD was `bce0a77e4b9e66da3f4213cb6dc50827720b5c4a`, consisting of exact reviewed
  source `6e390fc08b6d2b160a06c689576e422ec3ee204a` plus report-only commits. The
  only entry worktree artifact was the prior worker return `.node-return.md`.
- The bounded native fixture now admits only the actual commissioned limited/UAC-filtered
  `rdp-natha` token bound by the production helper to PID, UTC creation time, session, and SID.
  It asserts exact deny-only/enabled Administrators attributes and exact Windows `AccessCheck`
  grant masks against a private protected ACL. The actual bound elevated runner token is the
  effective-writer rejection case; there is no caller boolean or synthetic passing identity.
- Missing live-process inputs report `nativeNOTRUN` and cannot emit the full #1074 native PASS.
  Non-Windows execution also explicitly reports `nativeNOTRUN`.
- The positive uv case copies the independently hashed installed executable into a private
  WinGet-shaped package fixture, creates a private canonical command reparse leaf, and calls the
  production resolver to prove topology, copied bytes, and exact executable version output.
  Existing missing-link, direct-file, foreign-target, and wrong-hash rejections remain.
- The positive first-install case calls the production publisher in a private namespace, reaches
  its atomic directory move, verifies both published files and hashes, verifies the protected
  ACL tree, proves no staging residue, and exercises real no-delete-share directory-handle behavior.
  Existing held-old-authority, unchanged-old-bytes, and failed-stage cleanup cases remain.
- Orchestrator disposition is applied exactly: the Windows producer requires installed `uv 0.12.6`
  and retains the independently commissioned SHA/link/topology enforcement. It does not allow an
  arbitrary version or PATH binary and does not change Ubuntu/global pins or installed Windows bytes.

CARDINALITY

- Accepted R2 findings addressed: P1 0, P2 2, P3 0.
- Native positive acceptance families added: 3 (token/ACL, uv resolver/version, atomic publisher).
- Production behavior changes: 1 bounded Windows uv-version assertion, `0.12.5` to `0.12.6`.
- Modified source/test/doc paths: 5. Added report paths: 1.

CHANGES

- `tests/Test-WindowsAuthorityNative.ps1`: commissioned-process parameters; real limited and
  elevated token proofs; exact group/mask assertions; private canonical uv success; private
  coherent first-install success; published pair/hash/ACL/residue checks; held-handle rename proof.
- `scripts/windows/Install-WindowsReceiptAuthority.ps1`: exact installed Windows uv expectation is
  now 0.12.6 while SHA, canonical link, and package topology remain independently enforced.
- `tests/Test-WindowsReceiptAuthority.ps1`: source fixture requires the 0.12.6 producer assertion.
- `scripts/Validate-Repository.ps1`: native fixture is now an anti-deletion required file with
  positive-path wiring tokens.
- `docs/windows-receipt-authority.md`: records the 0.12.6 disposition and the commissioned native
  fixture inputs/non-PASS behavior.

Exact working-tree SHA-256 values for the five non-report deliverables:

- `917f73e068caf3d405bfc89d46dc24262361fdbc058d1a10b0b4fd5518b8b1c1`  `tests/Test-WindowsAuthorityNative.ps1`
- `4f2f86371931d9ca3ccdd378cb19cb1af871dea757f86f7452141b33c247636d`  `tests/Test-WindowsReceiptAuthority.ps1`
- `f7466ad7c15f9eb0c82e93375662d217d44f0f7aaa63383a1a6c670ad7e73e80`  `scripts/windows/Install-WindowsReceiptAuthority.ps1`
- `14a26905a5b196f1207adce4cdc89cd2e6741e85d2c53374da74f43067085eb6`  `scripts/Validate-Repository.ps1`
- `eea4c6b6385c78f95135c49f9136ec917e3bd6aefc78c49ee101beb564687120`  `docs/windows-receipt-authority.md`

CHECKS

- PowerShell parser sweep over the four changed `.ps1` files: PASS, exit 0.
- Extracted `Herdr.Authority.RuntimeToken` C# compilation: PASS, exit 0.
- Extracted `Herdr.Security.NativeMethods` C# compilation: PASS, exit 0.
- `pwsh -NoLogo -NoProfile -File tests/Test-WindowsReceiptAuthority.ps1`: PASS, exit 0.
- `pwsh -NoLogo -NoProfile -File tests/Test-WindowsAuthorityNative.ps1`: expected Linux
  `nativeNOTRUN`, exit 0.
- Scoped stale `0.12.5` scan across producer/native/source fixtures/docs: PASS, no matches.
- `git diff --check`: PASS, exit 0.
- The single authorized `git add` attempt was BLOCKED exactly by
  `fatal: Unable to create '/home/nathan/code/herdr-workstation-bootstrap/.git/worktrees/issue-1074-windows-authority-20260905/index.lock': Read-only file system`.
- Candidate commit and clean tracked HEAD: NOT CREATED because the common Git index is read-only.
- Whole repository validator: NOT RUN, per the brief's 120-second ceiling.
- Native Windows commissioning fixture: NOT RUN by this source node.

OPEN

1. A writable parent finalizer must verify the exact five hashes above, stage those five paths plus
   this report, commit them, and confirm a clean tracked candidate. No retry was made in this node.
2. The owning orchestrator must independently review that new clean SHA before commissioning.
3. The later Windows gate must re-observe the live `rdp-natha` PID/creation/session/SID tuple and run
   the bounded native fixture plus the separately authorized commissioning checks.
4. nativeNOTRUN: no live Windows token/ACL/link/publication execution, host mutation, install,
   production authority publication, downgrade/reinstall, deployment, consumer replay, or live
   authority validation occurred in this source node.

# Issue #8 — R5 independent cross-review return

- Reviewer pane: `w1:p10` (STM-T-C1), workflow `[WF:0facc591]`, relay `[HR:ff8a3d5c]`
- Candidate: `86a14069d5cf65ca2ca3571aa595661bfd502a17`
- Base: `008a2f10720834efdf80d7abee56b6dd74c4aff6`
- Review worktree: `/tmp/herdr-bootstrap-issue-8-cross-review-86a14069` (verified `git rev-parse HEAD` == candidate)
- Scope reviewed: complete `008a2f1..86a1406` range (4 commits: `d5c40c1`, `2fcc25e`, `6cede18`, `86a1406`), plus the surrounding production contract in `scripts/ubuntu/launcher-capability.sh`, `scripts/ubuntu/receipt-authority.sh`, `scripts/ubuntu/source-attestation.sh`, `scripts/ubuntu/bootstrap.sh`, `scripts/ubuntu/trusted-launcher.sh`, `scripts/ubuntu/verify.sh`.
- Read-only: no file in the worktree was edited; no commit, push, install, sudo, GitHub mutation, or agent dispatch was performed.

## Verification performed

Independent re-derivation of the production invariant (brief items 1–3):

- `attestation_create_git_snapshot` materializes committed `100755` blobs at `0755`
  (`scripts/ubuntu/source-attestation.sh:687`, via `attestation_snapshot_mode`
  `source-attestation.sh:412-419`), then strips **every** write bit from every snapshot
  file at `source-attestation.sh:778-781` (`chmod a-w`) **before** the manifest is
  emitted at `source-attestation.sh:782-792`. The manifest therefore records the
  post-hardening mode (`stat -c '%a'` at `source-attestation.sh:787`), i.e. `555` for
  committed-executable blobs and `444` otherwise. Directories are then forced to `0555`
  (`source-attestation.sh:793-795`) and `.source-attestation` to `0444`
  (`source-attestation.sh:792`).
- `git ls-tree HEAD` confirms `scripts/ubuntu/launcher-capability.sh` and
  `scripts/ubuntu/receipt-authority.sh` are both committed `100755`. The real payload
  entrypoint and capability helper are therefore root-owned `0555`, exactly as the new
  comment at `scripts/ubuntu/launcher-capability.sh:42-50` claims.
- The production payload path confirms this end to end:
  `scripts/ubuntu/bootstrap.sh:649` copies the hardened snapshot with `cp -a`;
  `bootstrap.sh:660` tars it to the root transaction, which extracts with
  `--no-same-owner --no-same-permissions` (`bootstrap.sh:707`) and `chown -R 0:0`
  (`bootstrap.sh:708`). Under the inherited `umask 022`, `0555 & ~022 == 0555`, and the
  in-line `root_verify_payload` then asserts `actual_mode == manifest_mode`
  (`bootstrap.sh:770-772`), pinning the extracted mode to the attested `555`/`444`.
- Consequently the pre-candidate code — which demanded exact `755` for the entrypoint and
  helper in **both** roles — rejected every real production payload receipt at
  `'entrypoint owner or mode is unsafe'` before the trust prelude could run. `6cede18`
  fixes a genuine production break, and the base fixture masked it only because
  `chmod -R u+w "$payload_probe"` widened the probe to `0755`/`0644` **before**
  `attestation_build_payload_manifest`, so the fixture manifest was self-consistent but
  production-inaccurate. Removing that chmod (`d5c40c1`) restores fidelity.
- Selector fail-closure: `launcher_capability_bind` is reached from exactly three call
  sites — `bootstrap.sh:74` (`source ... bootstrap`, `$2` unset → `0`), `verify.sh:38`
  (`source ... verify`, `$2` unset → `0`), and `receipt-authority.sh:88`
  (`$receipt_capability_payload_mode`, set only to literal `0` or `1` at
  `receipt-authority.sh:67,75`). No caller can supply a third value; the new
  `case` at `launcher-capability.sh:53-57` now aborts on one anyway, where the base
  silently fell through to the installed-launcher branch. This is strictly fail-closed.
- Role/mode discrimination is bound to the correct axis: `entry_expected_mode` derives
  from `payload_mode` (how the tree was materialized), not from `expected_entry` (which
  entrypoint). `payload_mode == 1` additionally requires
  `expected_entry == receipt-authority && id -u == 0` (`launcher-capability.sh:342-343`),
  descriptor-bound stage identity (`:344-349`), and a `root-receipt` parent capability
  (`:382-398`), so the `0555` acceptance cannot be reached from an installed-launcher
  staging tree. `0555` is strictly more restrictive than `0755`; no owner, group, other,
  regular-file, topology, descriptor, or lifetime check was relaxed.
- `payload_probe_commit` (brief item 3) is captured at
  `tests/test-receipt-authority.sh:441`, after `attestation_create_git_snapshot`
  (`:410`) and after `attestation_build_payload_manifest` (`:435`) — neither of which
  mutates `attestation_snapshot_commit` — and before the alternate snapshot at `:533`
  overwrites the global. It is now supplied at **every** `payload_probe` call site that
  takes a commit: `:496`, `:501`, `:509`, `:516`, `:517`, `:553`. The deliberately empty
  commit at `:513` (`unsigned-payload-source-commit`) is correctly left empty.
  `alternate_source_commit` (`:540`) intentionally stays bound to the alternate snapshot
  and is used only at `:549`. The pre-`86a1406` defect is real and confirmed: at base the
  tamper probe supplied the alternate commit, so
  `receipt_materialize_helper_from_payload` failed at
  `'receipt authority trust prelude: source snapshot commit is not externally bound'`
  (`scripts/ubuntu/receipt-authority.sh:490-492`), never reaching the asserted
  `'receipt authority: source snapshot manifest is invalid or externally unbound'`.
- Diagnostic ordering for the two new probes is correct and discriminating. The
  capability bind runs at `receipt-authority.sh:88`, strictly before the trust prelude and
  before `attestation_verify_snapshot` (`receipt-authority.sh:729`), so the mode probes at
  `tests/test-receipt-authority.sh:494-502` cannot be satisfied by a later,
  differently-worded failure. `expect_failure_diagnostic` uses `grep -Fqx`
  (`tests/test-receipt-authority.sh:235`), i.e. an exact whole-line match, and the two
  expected strings are distinct (`launcher-capability.sh:361` vs `:367`). Under the base
  contract the `0755` entrypoint would have *passed* the capability gate, so the probe
  genuinely discriminates old from new behavior. Modes are symmetrically restored at
  `:497` and `:502`, and `payload_stage_writable_mode` is saved/restored at `:505`/`:510`.
- TOCTOU / symlink / privilege boundaries: the production diff adds no filesystem
  operation — only a mode-string computation — so it introduces no new check-to-use
  window. Symlink rejection (`launcher-capability.sh:322-327,362-365`), descriptor
  re-assertion (`:378-380`), parent-capability binding (`:387-398`), and
  `launcher_capability_lifetime` (`:430-443`) are byte-for-byte unchanged. The new global
  `launcher_capability_entry_mode` is unconditionally reset at
  `launcher-capability.sh:52` before use, so a pre-seeded exported environment variable
  of that name cannot influence the resolved mode, and it is consumed into a function
  local at `:270` before any further work.
- Compatibility: no change to the receipt-authority JSON contract, the fencing contract,
  the trusted-launcher staging contract, or the pinned-upstream RTK installation path.
  `install-trusted-launcher.sh`, `rtk-release.sh`, `install-payload.sh`, and
  `config/ubuntu-toolchain.lock` are untouched by the range.

Executed checks:

- `bash -n` clean on all three changed files.
- `tests/test-trusted-launcher.sh` run non-root (uid 1000): **exit 0**, including the new
  line `capability entrypoint payload/installed-launcher mode contract tests passed.`
- Mutation probe (run in a scratchpad copy, not in the worktree) used to falsify the
  selector assertions — see P3-1.
- The root-only branch of `tests/test-receipt-authority.sh`
  (`tests/test-receipt-authority.sh:400-555`) could not be executed here: this reviewer is
  uid 1000 and the brief forbids `sudo`. For that branch I relied on the orchestrator's
  anchored aggregate `__R5_ROOT_RC__=0` plus the static derivation above.

## Findings

### P1

None.

### P2

None.

### P3

**P3-1 — `invalid-selector` / `empty-selector` assertions pass for the wrong reason.**
`tests/test-trusted-launcher.sh:346-347` assert only `status != 0`
(`tests/test-trusted-launcher.sh:340`). The subshell at `:322-329` runs
`launcher_capability_expected_entry_mode "$payload_mode"` followed by
`launcher_capability_owner_mode ... "$launcher_capability_entry_mode"`. If the fail-closed
abort at `scripts/ubuntu/launcher-capability.sh:56` were removed, the global would remain
`''` (set at `:52`) and `launcher_capability_owner_mode` would still return 1 on the
empty expected-mode comparison (`launcher-capability.sh:39`). I verified this by mutation
in a scratchpad copy: replacing `launcher_capability_fail 'payload mode selector is
invalid'` with a no-op still yields status 1 for selector `2`, so both cases keep
"passing". Neither the exit code `24` nor the diagnostic
`herdr launcher capability: payload mode selector is invalid` is covered anywhere.
*Safety-relevant: yes* (it is the fail-closure of the new selector).
*Recommendation: fix* — assert the exact diagnostic and/or status 24 for these two cases,
as `tests/test-receipt-authority.sh` already does via `expect_failure_diagnostic`.
Non-blocking: production remains doubly fail-closed via `launcher-capability.sh:271-272`.

**P3-2 — the documented "aborts the real process, not a subshell" property is untested.**
`scripts/ubuntu/launcher-capability.sh:49-50` justifies the global-publication design by
that property, but the only exercise of it (`tests/test-trusted-launcher.sh:319-329`) runs
inside `$( ( ... ) )`, i.e. exactly the subshell the design avoids.
*Safety-relevant: yes* (the claim is a security rationale).
*Recommendation: accept* — the design itself is correct and the real call site at
`launcher-capability.sh:269` is not in a command substitution; this is a documentation/
coverage mismatch only. Fixing P3-1 would partially address it.

**P3-3 — unreachable defensive branch.**
`scripts/ubuntu/launcher-capability.sh:271-272`
(`entrypoint mode contract is unresolved`) cannot be reached: `:51-58` either assigns
`755`/`555` or exits 24. No test can cover it, so "all changed production branches are
covered" is not literally achievable for this line.
*Safety-relevant: no.* *Recommendation: accept* — cheap belt-and-braces that would catch a
future edit to the resolver.

**P3-4 — the `0555` contract is an unasserted dependency on committed Git file modes.**
The payload role now requires exactly `555`, which holds only because
`scripts/ubuntu/launcher-capability.sh` and `scripts/ubuntu/receipt-authority.sh` are
committed `100755`. If either is ever committed `100644`, the snapshot materializes `0644`
(`source-attestation.sh:687`), `a-w` yields `0444` (`source-attestation.sh:780`), and every
production payload receipt fails closed at `launcher-capability.sh:360-361`. The mirror
hazard already existed for the `0755` installed-launcher role. No test asserts the
committed modes of these two blobs.
*Safety-relevant: yes* (availability of the trusted install path, fail-closed — no
integrity loss). *Recommendation: fix* — add a one-line `git ls-tree` assertion pinning
both blobs to `100755`.

**P3-5 — redundant live-tree chmod in the root fixture.**
`tests/test-receipt-authority.sh:407-409` re-applies `0755` to
`$source_root/scripts/ubuntu/{launcher-capability,receipt-authority}.sh`. Lines `98-101`
already set both to `0755` before the fixture commit, and `:322` restores
`receipt-authority.sh` after the only mutation of it (`:313`, reverted at `:320-321`). I
traced every `$source_root` reference between `:102` and `:410` and found no path that
strips an executable bit, so the comment's stated ordering requirement is not currently
violated by anything.
*Safety-relevant: no.* *Recommendation: accept* — harmless, and it genuinely pins the
`attestation_compare_live_checkout` executable-bit invariant
(`source-attestation.sh:420-429,478-482`) against future fixture edits.

**P3-6 — "foreign owner" cases do not create a foreign-owned file.**
`tests/test-trusted-launcher.sh:344` and `:349` pass `capability_mode_foreign_uid`
(`:342`, `id -u` + 1) as the *expected* uid rather than chowning the fixture file, so they
exercise the string comparison in `launcher_capability_owner_mode`
(`launcher-capability.sh:39`), not a real ownership boundary. The label overstates what is
proven. For this pure `stat`-and-compare function the two are equivalent, and chowning
would need root, which this block deliberately does not require.
*Safety-relevant: no.* *Recommendation: accept.*

**P3-7 — the "tampered payload tree" probe adds a file rather than modifying one.**
`tests/test-receipt-authority.sh:550` appends to `$payload_probe/source/README`, but the
fixture source tree contains only `config/` and `scripts/ubuntu/`
(`tests/test-receipt-authority.sh:86-93`) — there is no `README`, so the probe creates an
unmanifested extra file. `attestation_verify_snapshot` rejects it on the
untracked-path branch rather than the digest-mismatch branch; both produce the asserted
`receipt authority: source snapshot manifest is invalid or externally unbound`
(`receipt-authority.sh:729`), which is why the probe is still valid. The digest-mismatch
branch for a *manifested* file is not covered by this probe. Shape is unchanged from base.
*Safety-relevant: no.* *Recommendation: accept*; optionally retarget the append at an
existing manifested blob to also cover the digest branch.

## Summary

No P1 or P2 findings. The production change in `6cede18` is correct, minimal, strictly
fail-closed, and repairs a real pre-existing break of the production payload receipt path.
The three fixture commits remove production-inaccurate mode widening, restore the
executable-bit ordering, and correctly rebind the tampered-payload probe to its own source
commit while leaving `alternate_source_commit` bound to the alternate snapshot. All seven
findings are P3; two are safety-relevant and recommended for fix (P3-1, P3-4), and neither
blocks — both concern test/guard strength rather than the shipped trust boundary.

PASS FOR CROSS-REVIEW

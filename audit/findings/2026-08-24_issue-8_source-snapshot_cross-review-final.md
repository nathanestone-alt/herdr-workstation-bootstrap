I could not create the file: the `Write` tool is disabled in this session, and plan mode blocks other write paths — so `/tmp/issue-8-source-snapshot-cross-review.md` was **not** created. The complete self-contained report follows; it can be redirected to that path verbatim.

---

# Issue #8 — Source Snapshot Managed-Staging Cross-Review

**Candidate:** `2a8b77f02e490e43b52cde16e25c5d359c5f02f7` — *Use managed staging for source snapshots*
**Evidence-only baseline:** `7642442b8a75dc10dec16136a4705b91da9536b5`
**Prior reviewed substantive candidate:** `90f40c6ca17823f8ab9e2c23216d0b0bdf1a478f` (PASS at `/tmp/issue-8-final-cross-review.md`)
**Reviewer context:** fresh headless Claude (Anthropic `claude-opus-5`, reasoning effort high, normal tier, fast mode off), read-only detached worktree `/tmp/herdr-bootstrap-issue-8-review-2a8b77f`
**Controlling issue:** nathanestone-alt/herdr-workstation-bootstrap#8

Focused substantive diff `7642442..2a8b77f`: 3 files, +192 / −9.

| File | ± |
| --- | --- |
| `scripts/ubuntu/receipt-authority.sh` | +106 / −6 |
| `scripts/ubuntu/source-attestation.sh` | +24 / −3 |
| `tests/test-receipt-authority.sh` | +71 / −1 |

Verified: `git rev-parse HEAD` = `2a8b77f0…`, working tree clean, diff confined to the three files above.

---

## 1. Diagnosis verified against code, not narrative

The builder artifact `/tmp/issue-8-live-source-snapshot-correction.md` claims two defects. Both confirmed directly against the baseline blob (`git show 7642442:scripts/ubuntu/receipt-authority.sh`):

1. **`/tmp` snapshot allocation.** At baseline, `attestation_create_git_snapshot` had no parent parameter and hard-coded `mktemp -d /tmp/herdr-source-snapshot.XXXXXX`. The receipt trust prelude called it as `attestation_create_git_snapshot "$receipt_repo_root" '' ''`, so the launcher-bound checkout was always hardened into `/tmp`. Confirmed.

2. **`.git`-less re-snapshot.** At baseline the prelude retained only `attestation_snapshot_dir` (`receipt_source_snapshot`) and discarded `attestation_snapshot_manifest`. `repo_root`/`source_root` then defaulted to that hardened, `.git`-less tree while `source_manifest` stayed empty, so the main phase unconditionally fell into `attestation_create_git_snapshot "$source_root" '' ''` on a tree with no `.git` — guaranteed failure of every entrypoint-shaped (`--source-root`-less) invocation. Confirmed; **this**, not the `/tmp` allocation alone, is the root cause of the live `exit 24` at `90f40c6`.

The `/tmp` ancestry rejection referenced in the brief is the pre-existing, previously-reviewed `receipt_bundle_validate_authority_path` (`scripts/ubuntu/receipt-authority.sh:1022`) applied to the runtime-bundle staging chain; the candidate does not alter it and the corresponding negative is preserved (`tests/test-receipt-authority.sh:797`).

**Rubric 1: satisfied.**

---

## 2. The new staging parent is capability-derived, canonical, and ancestry-proved

`receipt_prepare_source_snapshot_parent` (`scripts/ubuntu/receipt-authority.sh:199`) derives its root from the already-bound capability, not from caller input:

- `scripts/ubuntu/receipt-authority.sh:201` reads `launcher_capability_policy_path`, which is `readonly` (`scripts/ubuntu/launcher-capability.sh:421`) and set from `realpath -e /proc/$BASHPID/fd/9` (`scripts/ubuntu/launcher-capability.sh:298`) — the descriptor-bound policy object, not a caller-steerable pathname.
- `scripts/ubuntu/receipt-authority.sh:203-206` re-asserts the `*/etc/herdr-workstation/bootstrap-policy.conf` suffix and strips it. Byte-identical to the prefix derivation the capability helper already performed and validated (`scripts/ubuntu/launcher-capability.sh:309-315`), and identical to the accepted runtime-bundle derivation (`scripts/ubuntu/receipt-authority.sh:1065-1067`). `policy_suffix` is a local literal with no glob metacharacters, so the unquoted `%` pattern is safe.
- `scripts/ubuntu/receipt-authority.sh:207` yields exactly the `expected_staging` value the capability helper already bound and symlink-scanned (`scripts/ubuntu/launcher-capability.sh:315,326,332`).

`receipt_trust_validate_source_snapshot_path` (`scripts/ubuntu/receipt-authority.sh:165`) then proves, per ancestor from the staging root up to the boundary inclusive:

- absolute, existing, non-symlink directory, with a full symlink-component scan of the leaf path (`:173-178`);
- `realpath -e "$current" == "$current"` — **a per-ancestor canonicality check the accepted bundle validator at `:1022` does not have**, additionally closing a symlink swapped in after the component scan (`:180,184`);
- `uid == expected_uid && gid == expected_gid` (`:181-184`);
- `mode =~ ^[0-7]+$ && (8#mode & 022) == 0` — not group- or other-writable; setuid/sticky bits tolerated, write bits not (`:183-185`);
- termination at the boundary, with `/` reached without matching the boundary treated as escape (`:191-194`).

For production the boundary is `/` and the expected owner is `0:0` (`:216-221`), so `/var/lib/herdr-workstation/bootstrap/staging` → `/var/lib/herdr-workstation/bootstrap` → … → `/` must all be root-owned and non-group/other-writable. I confirmed empirically that the `||` short-circuit inside `[[ … ]]` prevents `$((8#$mode))` from being evaluated when the regex guard fails, so a malformed or empty `stat` result fails closed rather than raising an arithmetic error.

Non-root cannot substitute this path in production: the installed launcher refuses to run as anyone but the trust-anchor owner (`scripts/ubuntu/trusted-launcher.sh:74`), which is uid 0 when the prefix is empty (`scripts/ubuntu/launcher-capability.sh:336-339`), and standalone invocation requires fd 9 on a `0600` root-owned policy file (`scripts/ubuntu/launcher-capability.sh:304-308`). Live proof: `tests/test-receipt-authority.sh:808-813` asserts `0:0:755` on the real production-shaped parent, and that assertion passed at root (`/tmp/issue-8-2a8b77f-root-receipt.log:51`).

**Rubric 2: satisfied.**

---

## 3. Creation, revalidation, race, path-replacement, symlink, cleanup, collision

**Creation/revalidation.** `scripts/ubuntu/receipt-authority.sh:225-247` mirrors the previously accepted `receipt_bundle_prepare_stage_parent` (`:1074-1090`): symlink-component scan of the leaf, reject-not-repair for an existing non-directory, `mkdir` → `chmod 0755` → (production only) `chown 0:0`, then an unconditional second full ancestry revalidation. All three binaries are asserted canonical and non-group/other-writable before use (`:138-146`) and invoked through `receipt_exec_system`'s scrubbed `env -i` (`:148-163`).

**TOCTOU.** The create/validate window is not attacker-influenceable: every ancestor was just proved root-owned and non-group/other-writable, so no unprivileged principal can create, replace, or rename `source-attestation`. The post-creation revalidation additionally catches a pre-existing hostile directory. `mktemp -d` inside the parent (`scripts/ubuntu/source-attestation.sh:651`) is an atomic `mkdir` at `0700`, so the snapshot child cannot be pre-seeded.

**Path replacement / symlink.** Three independent layers: `receipt_trust_reject_symlink_components` on the leaf (`:225`), the `-e || -L` reject-not-repair gate (`:228-231`), and the per-ancestor `realpath` identity check in the revalidation (`:180,184`). A symlinked `source-attestation` is rejected before any write.

**Cleanup escape.** The snapshot child is registered as a temporary path at creation (`scripts/ubuntu/source-attestation.sh:655`) and removed by the receipt `EXIT` trap via `attestation_cleanup_temporary_paths` (`scripts/ubuntu/receipt-authority.sh:628-630`). Every registered path is self-created by `mktemp`; none is caller-supplied. The narrowed `attestation_snapshot_cleanup` guard (`scripts/ubuntu/source-attestation.sh:406-413`) replaces the old `path == /tmp/*` prefix match — which accepted any `/tmp` descendant at any depth — with `dirname == recorded parent && basename == herdr-source-snapshot.*`. Strictly narrower; the only call site (`:515`, via `attestation_snapshot_abort`) runs after `attestation_snapshot_parent` is set at `:557`.

**Cross-run collision.** `mktemp -d` guarantees unique children. Two concurrent first runs could both observe `! -e "$parent"` and race the `mkdir`; the loser aborts. Fail-closed, root-only, identical in shape to the already-accepted bundle staging parent. Logged as P3-4.

**Rubric 3: satisfied.**

---

## 4. Fixture isolation and the `/tmp` unsafe-ancestry negative

Fixture mode is not caller-selectable in a production install. `scripts/ubuntu/receipt-authority.sh:208-212` requires simultaneously `realpath -e "$receipt_prelude_fixture_root" == "$receipt_prelude_fixture_root"` **and** `prefix == "$receipt_prelude_fixture_root"`. Since `prefix` is capability-derived, a production install (prefix `''`) can never satisfy this, so `--fixture-root` against a production launcher now hard-fails in the prelude — strictly tighter than baseline, where fixture mode was only rejected later and only for default authority paths (`:814-816`). Conversely, fixture mode expects `launcher_capability_owner_uid/gid` and stops the ancestry walk at the fixture root (`:213-215,222-223`), so the test tree under `/tmp` need not be root-owned — isolation preserved.

The explicit `/tmp` negative is present, distinct, and correctly ordered:

- `tests/test-receipt-authority.sh:790-792` asserts the exact diagnostic `receipt authority trust prelude: production source snapshot staging parent is not root-owned and non-writable: /tmp`. The walk from `<prefix>/var/lib/…/staging` succeeds through the `0755` mktemp prefix and fails precisely at `/tmp` (`1777`; `8#1777 & 022 = 18`). The fixture pre-asserts `/tmp` is canonical, root-owned and writable (`:671-682`), so the negative cannot silently degenerate.
- `tests/test-receipt-authority.sh:793-796` proves fail-closed-before-mutation: `source-attestation` must not exist after rejection. This holds because validation of `authority_root` (`:222`) precedes any `mkdir` (`:233`).
- The pre-existing runtime-bundle `/tmp` negative is retained unchanged (`:797-800`).
- The rejection fixture is torn down and the prefix reset before the positive simulation (`:801-807`), so it is never reused.

**Rubric 4: satisfied.**

---

## 5. Carrying the prelude manifest/commit cannot accept stale, substituted, partial or mismatched source

The internal-manifest gate (`scripts/ubuntu/receipt-authority.sh:737-741`) arms only when all three hold: repo mode, **no** `--source-root` in argv, **no** `--source-manifest` in argv. `--source-manifest` in the main loop clears the flag (`:776`).

The carried manifest is **not** trusted as a prior result — the main phase re-verifies from scratch:

- `:835` requires `source_manifest == "$source_root/.source-attestation"`, so the manifest must live inside the tree it describes.
- `:836` runs the full `attestation_verify_snapshot` (`scripts/ubuntu/source-attestation.sh:838-912`), which re-reads header/grammar, rejects duplicate paths and non-`F` lines, then performs a **complete `find -P` walk of the snapshot** rejecting any symlink, non-regular entry, unmanifested file, unmanifested directory, mode mismatch or digest mismatch (`:887-903`), and separately requires every manifested path to exist and re-hash correctly (`:904-909`). Extra files, missing files, mutated bytes and mode drift are all caught — "partial" and "substituted" covered.
- `source_commit_binding` is the launcher-bound `launcher_capability_policy_commit` (`:739`), enforced inside `attestation_verify_snapshot` (`scripts/ubuntu/source-attestation.sh:852`) and again at `:844-845`. "Stale" covered.
- `:850-855` binds the *invoked* `receipt-authority.sh` and `source-attestation.sh` bytes to the manifest digests, so an entrypoint/helper mismatch fails even if the tree verifies.
- `source_manifest_internal` correctly suppresses `source_manifest_supplied` (`:833`) so the internally generated manifest does not trip the "supplied manifest requires an externally bound payload" gate (`:866`) — and a genuinely caller-supplied manifest still does, because the prelude gate at `:737` would have left the flag at 0.

Adversarial combinations checked, all fail closed:
- `--source-manifest Y` alone: prelude sees it, internal not armed, `:835` forces `Y` to be the snapshot's own manifest, but `source_manifest_supplied=1` then requires `--payload-root` at `:866` → fail.
- `--source-commit Z` alongside internal mode: overrides the binding, then `attestation_verify_snapshot` rejects the commit mismatch → fail.
- `--payload-root` alongside repo mode: `launcher_capability_bind` requires `repo_root == stage_dir/source` and a `0:0:700` stage in payload mode (`scripts/ubuntu/launcher-capability.sh:344-349`), which an installed-launcher `.incoming.*` stage cannot satisfy → fail.

**No `.git`-less re-snapshot remains** on the entrypoint path: with the internal manifest armed, `:832` takes the verify branch and `attestation_create_git_snapshot` is never re-entered on the hardened tree.

Between prelude snapshot and main-phase verification the tree is immutable to anyone but the owning principal: files `a-w` (`scripts/ubuntu/source-attestation.sh:798-801`), manifest `0444` (`:812`), every directory including the snapshot root `0555` (`:813-815`), inside the root-owned `0755` managed parent inside a root-owned chain to `/`.

**Rubric 5: satisfied.**

---

## 6. Explicit source-root callers and the optional parent argument

**Explicit `--source-root` callers are hardened, not weakened.** In repo mode with `--source-root`, `receipt_source_snapshot_parent` is already populated by the prelude, so `:838` routes that snapshot through the same validated managed parent instead of `/tmp`. This is the path `run_authority` exercises throughout the suite.

**The new fifth argument cannot weaken the helper.** `attestation_create_git_snapshot` validates the supplied parent before use (`scripts/ubuntu/source-attestation.sh:544-557`): absolute, existing, non-symlink directory; `realpath -e` lexically identical; full symlink-component scan. It records the *canonical* value and allocates from that, never from the raw argument (`:557,651`). Arguments 1–4 are unchanged, and both new call sites pass `require_live=true` explicitly — exactly the previous default, so no behavioural relaxation. The standalone default remains `/tmp`, leaving `scripts/ubuntu/bootstrap.sh:640` (3-arg call) bit-for-bit unchanged in behaviour.

The one residual is the `${receipt_source_snapshot_parent:-/tmp}` fallback at `scripts/ubuntu/receipt-authority.sh:838` — see P3-1. Not attacker-reachable: it requires non-repo mode (root payload transaction), no `--source-manifest`, and the payload's `$stage/source` is itself a `.git`-less hardened snapshot, so the call fails anyway.

**Rubric 6: satisfied.**

---

## 7. Interaction with runtime bundle sealing, receipt metadata, launcher boundary

- **Runtime bundle sealing:** untouched. `receipt_bundle_validate_authority_path` / `receipt_bundle_prepare_stage_parent` / `receipt_bundle_prepare_scratch` (`:1022`, `:1061`, `:1092`) are byte-identical to baseline; the new code is a parallel sibling, not a modification.
- **Staging-root namespace:** `source-attestation` is a new sibling of `receipt-runtime` under `.../bootstrap/staging`. It cannot collide with the launcher's `.incoming.*` stage (`scripts/ubuntu/trusted-launcher.sh:122`, matched exactly at `scripts/ubuntu/launcher-capability.sh:351`) or `.parent-capability.*` (`scripts/ubuntu/trusted-launcher.sh:192,202`). `install-trusted-launcher.sh` never enumerates or sweeps staging children (`:190-196`), so re-pin is unaffected.
- **Receipt metadata:** `source_commit_sha` now derives from the verified manifest via `attestation_verify_snapshot` (`scripts/ubuntu/source-attestation.sh:849`) rather than a fresh snapshot, still gated on the policy commit (`:844-845`). Origin/URL handling is provably unchanged (grep for `attestation_snapshot_url|repository_url|policy_origin` is empty in both baseline and candidate `receipt-authority.sh`). The root suite asserts the bound commit end-to-end (`tests/test-receipt-authority.sh:820-823`, `:861-864`).
- **Trusted launcher boundary:** `trusted-launcher.sh` and `launcher-capability.sh` are unmodified. The new code consumes only `readonly` capability outputs (`launcher_capability_policy_path`, `_owner_uid`, `_owner_gid`, `_policy_commit`) and introduces no new descriptor, environment, or PATH surface.

**Rubric 7: satisfied.**

---

## 8. Do the root regressions execute production-shaped behaviour, and do both logs support PASS?

**Yes, production-shaped.** `run_production_entrypoint_authority` (`tests/test-receipt-authority.sh:713-724`) invokes the installed launcher with `--entrypoint receipt-authority` and passes **no `--source-root` and no `--fixture-root`**. That drives the production branch of `receipt_prepare_source_snapshot_parent` (`expected_uid=0`, boundary `/`), the root requirement at `:819-821`, the root-owned `setpriv` boundary at `:873-875`, and the real `/etc/os-release` Ubuntu gate at `:877-881`. The ancestry walk traverses the genuine `/var/lib/herdr-workstation/bootstrap/staging` → `/var/lib` → `/var` → `/` chain, pre-asserted by `assert_root_owned_nonwritable_chain` (`:634-670`). This is the automated equivalent of the triggering live standalone `--install`, and the argv shape that failed at `90f40c6`.

**Both logs support PASS and are consistent with *this* test file:**

- `/tmp/issue-8-2a8b77f-root-receipt.log` terminates with `receipt authority install, reconciliation, provenance and fail-closed tamper tests passed.` (line 56), the exact sentinel at `tests/test-receipt-authority.sh:960`. Its structure corroborates the candidate rather than a stale run: **two** fixture installs (log lines 5, 8 — the new `run_entrypoint_authority --install` at `:378` plus the pre-existing `run_authority --install` at `:391`) and **two** production installs (log lines 51, 52 — the new `run_production_entrypoint_authority --install` at `:808` plus the pre-existing payload install at `:860`). It also shows both the `/tmp/herdr-test-production-ancestry-rejection.*` rejection fixture and the `/var/lib/…/staging/herdr-test-production-simulation.*` positive prefix, i.e. the new negative and positive both ran. The suite is `set -euo pipefail` with `expect_failure*` helpers, so reaching the sentinel means the `0:0:755` parent assertion, the no-residue assertions, and the `/tmp` fail-closed assertions all held.
- `/tmp/issue-8-2a8b77f-root-tools.log` terminates with `Bootstrap tools phase fixture passed.`, matching the final-line sentinel of `tests/test-bootstrap-tools.sh`, and shows the managed `/var/lib/…/staging/herdr-test-bootstrap-tools.*` prefix introduced at `90f40c6`. It is terse because that is the suite's normal output; it confirms no regression but carries little information about the new source-snapshot path, which the tools phase does not reach.

Independently verified: `bash -n` clean on `receipt-authority.sh`, `source-attestation.sh`, `test-receipt-authority.sh`.

**Rubric 8: satisfied.**

---

## 9. Findings

### P1 — none
### P2 — none

### P3 findings (all dispositioned; none blocking)

**P3-1 — `/tmp` retained as a silent fallback in the very path whose `/tmp` ancestry is being rejected.**
`scripts/ubuntu/receipt-authority.sh:838` — `… true "${receipt_source_snapshot_parent:-/tmp}"`. The commit's thesis is that `/tmp` is untrusted staging; an implicit fallback in the same expression reads as a policy exception rather than a decision.
*Disposition: accept.* Not attacker-reachable. Requires `receipt_repo_mode == 0` (root payload transaction only — an installed-launcher stage always carries `.git`, so `payload_mode == 0` cannot reach it) together with no `--source-manifest`; `bootstrap.sh:878-886` always supplies one, and the payload's `$stage/source` is `.git`-less so the call fails closed regardless. `mktemp -d` under sticky `/tmp` as root yields a `0700` root-owned directory, so no confidentiality or integrity loss even if reached. A future `[[ -n "$receipt_source_snapshot_parent" ]] || fail …` would make the invariant explicit; not required for this gate.

**P3-2 — Prelude and main argv scanners can desync on unknown-option values.**
`scripts/ubuntu/receipt-authority.sh:651-694` vs `:768-785`. The prelude scanner does not consume values for `--authority-path`, `--receipt-path`, `--install`, `--check`, so a literal such as `--authority-path --source-root` makes the prelude believe a source root was supplied and suppresses the internal manifest (`:737`), yielding the opaque `source Git checkout failed hardened source attestation` instead of a clear diagnostic.
*Disposition: accept.* Fail-closed and unreachable in practice — it requires an unknown option's *value* to be literally one of the eight prelude-recognised option names. Every real caller (`bootstrap.sh:878-886`, all four test harness wrappers) passes path-shaped values. The scanner shape predates this commit; the candidate only adds a new consumer of it.

**P3-3 — `attestation_snapshot_parent` is reset by re-sourcing while `attestation_snapshot_dir` is restored.**
`scripts/ubuntu/source-attestation.sh:56` (top-level reset) versus `scripts/ubuntu/bootstrap.sh:648,654`, which re-sources the helper from the snapshot and restores `attestation_snapshot_dir` but not the new `attestation_snapshot_parent`. `attestation_snapshot_cleanup`'s `${attestation_snapshot_parent:-/tmp}` default masks this today only because bootstrap uses the `/tmp` default.
*Disposition: accept (latent only).* `bootstrap.sh` never calls `attestation_snapshot_cleanup`, and the only call site (`source-attestation.sh:515`, via `attestation_snapshot_abort`) always runs inside `attestation_create_git_snapshot` after `:557` sets the global. Worth a comment if a managed parent is ever threaded into bootstrap.

**P3-4 — Concurrent first-run `mkdir` race on the managed parent.**
`scripts/ubuntu/receipt-authority.sh:228-235` is check-then-create with a bare `mkdir` (no `-p`), so two simultaneous first runs make one abort with `source snapshot staging parent could not be created`.
*Disposition: accept.* Fail-closed, root-only, structurally identical to the already-accepted `receipt_bundle_prepare_stage_parent` (`:1074-1082`). Receipt authority runs inside a serialized root transaction.

**P3-5 — `--help` now performs managed-staging creation before printing usage.**
Because the prelude runs before argument parsing, `--help` creates `<prefix>/var/lib/herdr-workstation/bootstrap/staging/source-attestation` and takes a full Git snapshot before reaching `:782`. The test had to be amended to pass `--fixture-root` to the `--help` invocation (`tests/test-receipt-authority.sh:183-184`) for exactly this reason.
*Disposition: accept.* The full snapshot on `--help` is pre-existing baseline behaviour; only the persistent `mkdir` is new, and it is idempotent and confined to the managed, capability-derived prefix.

**P3-6 — Managed parent is `0755` where `0700` would suffice.**
`scripts/ubuntu/receipt-authority.sh:236`. Unlike `receipt-runtime`, which must stay traversable for unprivileged role probes, the source-attestation parent is read only by the root/owner process; its children are `0555` and its contents are the public repository at the policy commit.
*Disposition: accept.* No confidentiality or integrity exposure. `0755` keeps the mode contract symmetric with the sibling staging parent and matches the assertions at `tests/test-receipt-authority.sh:379-383` and `:810-813`.

**P3-7 — No re-run of the exact triggering standalone live command was supplied.**
The brief's trigger was a live standalone `trusted-launcher … --entrypoint receipt-authority -- --install`; the supplied evidence is the two root suite logs only. `tests/test-trusted-launcher.sh` uses stub entrypoints and does not invoke the real receipt authority, so it cannot cover this.
*Disposition: accept.* The new `run_production_entrypoint_authority --install` regression is the production-shaped automation of that exact command (root, no `--fixture-root`, no `--source-root`, real `/var/lib` ancestry, real os-release gate) and it passed at root. Recommend the orchestrator additionally capture one live standalone `--install` before terminal disposition, as confirmation rather than as a gate condition.

---

## Conclusion

The diagnosis is independently confirmed against the baseline blob. The new staging parent is derived exclusively from the descriptor-bound launcher policy prefix and proved canonical, non-symlinked, correctly owned and non-group/other-writable through `/` in production, with a per-ancestor `realpath` identity check strictly stronger than the previously accepted runtime-bundle validator. Creation is reject-not-repair with unconditional post-creation revalidation, in a chain no unprivileged principal can influence. Fixture mode is bound to the capability prefix and cannot be asserted against a production install. The carried prelude manifest is fully re-verified — grammar, complete tree walk, per-file mode and digest, exact path-set equality, and policy-commit binding — before any authority input is read, and no `.git`-less re-snapshot remains on the entrypoint path. Explicit source-root callers are hardened rather than weakened, and the optional parent argument is validated before use with the standalone `/tmp` default preserved. No interaction with the previously passed runtime bundle sealing, receipt metadata, or trusted launcher boundary is degraded. Both supplied root logs terminate at their suites' PASS sentinels and their internal structure corroborates execution of the candidate's new positive and negative coverage.

Seven P3 findings, all dispositioned as accept; none blocking.

PASS FOR CROSS-REVIEW

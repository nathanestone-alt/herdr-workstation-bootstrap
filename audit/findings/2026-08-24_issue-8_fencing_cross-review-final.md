File capture was not possible: the `Write` tool is disabled for this session and plan mode bars non-read-only tool use, so the report is delivered inline below for capture to `/tmp/issue-8-fencing-final-cross-review.md`.

---

# Issue #8 — Fencing Receipt Fixture Staging: Final Cross-Review

- **Candidate:** `daf84bfac353c01e510e1825709295ac90589561` — "Align fencing receipt fixture staging"
- **Prior reviewed candidate:** `2a8b77f02e490e43b52cde16e25c5d359c5f02f7` — "Use managed staging for source snapshots"
- **Scope:** exact diff `2a8b77f..daf84bf`, plus its interaction with the source-snapshot correction already passed at `/tmp/issue-8-source-snapshot-cross-review.md`
- **Controlling issue:** `nathanestone-alt/herdr-workstation-bootstrap#8`
- **Reviewer lane:** independent fresh context, read-only, detached worktree `/tmp/herdr-bootstrap-issue-8-review-daf84bf`
- **Worker:** Anthropic / claude-opus-5 / high / normal; fast mode disabled
- **Inputs read:** `/tmp/issue-8-source-snapshot-neutral-runner.md`, `/tmp/issue-8-fencing-source-staging-correction.md`, `/tmp/issue-8-source-snapshot-cross-review.md`, `/tmp/issue-8-2a8b77f-fencing-repro.log`, `/tmp/issue-8-2a8b77f-root-receipt.log`, `/tmp/issue-8-2a8b77f-root-tools.log`, `/tmp/issue-8-fencing-source-staging-*.out`

## 0. Candidate exactness

```
git rev-parse --verify HEAD              -> daf84bfac353c01e510e1825709295ac90589561
git status --porcelain=v1                -> empty
git diff 2a8b77f..daf84bf --name-only    -> tests/test-bootstrap-fencing.sh
git diff 2a8b77f..daf84bf -- scripts/    -> 0 lines
git diff --check 2a8b77f..daf84bf        -> exit 0, no output
bash -n tests/test-bootstrap-fencing.sh  -> exit 0
```

Diff is 4 insertions / 2 deletions in one file. The two deletions are the two lines that were replaced; no test block, assertion, or negative case was removed.

## 1. Do the two `--fixture-root` arguments correctly bind receipt-authority fixture semantics, in the accepted parser order?

**Yes, and the binding is not a free bypass.**

`receipt-authority.sh` has two argument scanners:

- The **prelude scanner**, `scripts/ubuntu/receipt-authority.sh:649-700`, is an index walk over `receipt_prelude_args=("$@")` (`:648`) and is therefore **position-independent**. `--fixture-root` is recognised at `:688-691` and sets `receipt_prelude_fixture_root`. This scanner runs *before* any staging work.
- The **main scanner**, `:770-784`, is the conventional `shift`-based loop. `-h|--help` is at `:782` and does `usage; exit 0`.

Because the prelude is position-independent, `--help --fixture-root "$fixture_root"` binds fixture mode exactly as `--fixture-root "$fixture_root" --help` would. In the main scanner `--help` short-circuits first, so `--fixture-root` is never consumed there — irrelevant, because `usage` is reached and exit is 0 either way.

**Order matches established precedent exactly.** `tests/test-receipt-authority.sh:183-184` already uses the identical shape:

```
"$launcher" --entrypoint receipt-authority -- --help \
  --fixture-root "$fixture_root" > "$test_root/receipt-help-output" 2>&1
```

`tests/test-bootstrap-fencing.sh:79-80` and `:107-108` are now the same argument order. This is the accepted order, not a new one.

**The flag is capability-bound, not attacker-selectable.** `receipt_prepare_source_snapshot_parent` (`scripts/ubuntu/receipt-authority.sh:208-220`) derives `prefix` from `launcher_capability_policy_path` (the descriptor-bound policy path) and then requires, at `:209-211`:

```
boundary="$(realpath -e -- "$receipt_prelude_fixture_root")"
[[ -n "$boundary" && "$boundary" == "$receipt_prelude_fixture_root" && "$prefix" == "$boundary" ]] ||
  receipt_trust_fail 'fixture source snapshot staging root escaped the fixture root'
```

The passed `--fixture-root` must be canonical **and** exactly equal the policy-path prefix. On a production install the policy path is `/etc/herdr-workstation/bootstrap-policy.conf`, so `prefix` is the empty string and **any** non-empty `--fixture-root` fails closed at `:210`. `--fixture-root` therefore cannot relax a production install. In the fencing fixture, `install-trusted-launcher.sh` was already invoked with `--fixture-root "$fixture_root"` (`tests/test-bootstrap-fencing.sh:36-38`) and the policy lands at `$fixture_root/etc/herdr-workstation/bootstrap-policy.conf` (`:41`), so `prefix == $fixture_root` and the binding holds. `expected_uid/gid` become `launcher_capability_owner_uid/gid` (`:213-214`), which `scripts/ubuntu/launcher-capability.sh:422-423` captures from the validated policy-file owner — again descriptor-derived, not caller-supplied.

## 2. Did production code change, or any production authority assertion weaken?

**No.** `git diff 2a8b77f..daf84bf -- scripts/` is empty; the only changed path is `tests/test-bootstrap-fencing.sh`. Every production trust check in `receipt_prepare_source_snapshot_parent`, `receipt_trust_validate_source_snapshot_path` (`scripts/ubuntu/receipt-authority.sh:170-206`), the payload prelude, the launcher capability seam, and the runtime-bundle validator is byte-identical to the already-passed `2a8b77f`.

Critically, **no previously-green production assertion was traded away.** At the substantive base `7642442`, `receipt_prepare_source_snapshot_parent` did not exist (`git show 7642442:scripts/ubuntu/receipt-authority.sh` contains only the bare `attestation_create_git_snapshot "$receipt_repo_root" '' ''` at `:630`). The production ancestry gate became *newly reachable* at `2a8b77f`; the fencing fixture, running as uid 1000 under a `mktemp` root, then correctly failed closed. Adding `--fixture-root` selects the fixture branch of a gate this test never previously asserted in its production form. This completes a fixture migration; it does not relax an invariant.

Independent corroboration: the prior cross-review anticipated this precise amendment. P3-5 of `/tmp/issue-8-source-snapshot-cross-review.md` states that `--help` now performs managed-staging creation before printing usage and that "the test had to be amended to pass `--fixture-root` to the `--help` invocation (`tests/test-receipt-authority.sh:183-184`) for exactly this reason." The fencing suite's two sibling call sites were missed in that amendment; `daf84bf` finishes it.

## 3. Is the surrounding fencing coverage intact?

Verified line by line against the candidate file. All intact:

| Coverage | Location | Status |
|---|---|---|
| Launcher publication + policy/staging owner-mode asserts | `tests/test-bootstrap-fencing.sh:43-47` | unchanged |
| Hostile `PATH` shims (14 commands) + `BASH_ENV` | `:49-62`, consumed at `:67-68` | unchanged |
| Clean end-to-end bootstrap through the launcher | `:72-78` | unchanged |
| Clean end-to-end receipt authority | `:79-85` | **argument-only change**; `Usage:` assertion at `:84` retained |
| Dirty-checkout mutation + hash-differs proof | `:90-105` | unchanged |
| Dirty-path launcher runs (bootstrap / receipt / verify) | `:106-111` | **argument-only change on the receipt line**; verify status-1 assert at `:115-119` unchanged |
| Pre-line-10 forged-marker negatives (3 entrypoints) | `:91-101` markers, asserted `:120-125` | unchanged |
| Direct-execution capability negatives with forged `HERDR_*` markers and caller-selected roots | `:127-149` | unchanged — these deliberately pass **no** `--fixture-root` |
| PowerShell trust seam, 6 cases | `:151-310` | unchanged |
| Retired-invariant greps (`.cargo/env`, `RTK_REPO_URL`, `RTK_SHA256`, `/proc/${BASHPID}/fd`, attestation cleanup) | `:312-322` | unchanged |
| Hostile-PATH and `BASH_ENV` reached-marker assertions | `:324-333` | unchanged |
| Terminal PASS sentinel | `:335` | unchanged |

The two assertions that could conceivably be dulled by a fixture-mode argument are not: the forged-marker checks at `:120-125` are filesystem sentinels evaluated independently of receipt-authority's exit status, and the direct-execution negatives at `:127-149` invoke entrypoints without the launcher and without `--fixture-root`, so they still fail at the capability seam before any argument scanning (asserted by the `capability|launcher` grep at `:147-148`).

## 4. Can `--fixture-root` on `--help` mask a production-path regression elsewhere?

**No, for four independent reasons — with one honest residual, logged as P3-1.**

1. **Production mode was unreachable by these calls anyway.** As non-root under a `mktemp` root, the production branch (`boundary='/'`, `expected_uid=0`) can never pass. Before the fix the test was simply red, not more rigorous.

2. **`--fixture-root` cannot smuggle fixture semantics into a production install.** `:210` requires `prefix == boundary`; with a production policy path `prefix` is empty and any `--fixture-root` fails closed. A fail-closed asymmetry, not a mode toggle.

3. **The `--help` path is narrow and its fixture-sensitive surface is exactly one function.** Executed before `:782`: launcher capability validation, prelude argv scan, `receipt_materialize_helper_from_git` (`:723`), `receipt_prepare_source_snapshot_parent` (`:727`), and a full `attestation_create_git_snapshot` (`:728`). Of the other `receipt_prelude_fixture_root` consumers, `receipt_exec_python_unprivileged` (`:302`) and `receipt_materialize_helper_from_payload` (`:552`) are not on the `--help` path (`:552` requires `receipt_repo_mode == 0`; a launcher-materialized stage always carries `.git`). So the flag changes exactly one gate on this path — and the path still performs a full capability validation and a real Git snapshot, so `--help` remains a substantive end-to-end probe rather than a no-op smoke test.

4. **The production branch retains dedicated, currently-green coverage elsewhere.** `tests/test-receipt-authority.sh:713-724` (`run_production_entrypoint_authority`) drives the installed launcher with **no `--fixture-root` and no `--source-root`**, taking the production branch with `expected_uid=0` and boundary `/`. Both polarities are asserted:
   - **Negative:** `:789-796` — `prepare_production_payload_environment /tmp herdr-test-production-ancestry-rejection`, then `expect_failure_diagnostic` on the exact string `receipt authority trust prelude: production source snapshot staging parent is not root-owned and non-writable: /tmp`, followed by a no-silent-repair assertion at `:793-796`.
   - **Positive:** `:808-813` — `run_production_entrypoint_authority --install` against the real `/var/lib/herdr-workstation/bootstrap/staging` chain, with a `0:0:755` assertion on the created source-snapshot parent.

   `/tmp/issue-8-2a8b77f-root-receipt.log` shows both fixtures executing (`/tmp/herdr-test-production-ancestry-rejection.weuePo/transport` and `/var/lib/herdr-workstation/bootstrap/staging/herdr-test-production-simulation.vuMMPy/transport`) and terminates at the suite sentinel `receipt authority install, reconciliation, provenance and fail-closed tamper tests passed.` Under `set -euo pipefail`, reaching that sentinel means both assertions held. `tests/test-receipt-authority.sh` is byte-identical at `daf84bf` and `2a8b77f`, and all of `scripts/` is byte-identical, so those root logs remain evidentially valid for `daf84bf`.

**Accounting for the separate root production-entrypoint regression and the live gate requirement.** P3-7 of the prior cross-review recorded that no re-run of the exact triggering *live standalone* `--install` was supplied, dispositioned accept on the strength of `run_production_entrypoint_authority --install`, with a recommendation that the orchestrator capture one live standalone `--install` before terminal disposition. `daf84bf` changes nothing bearing on that: it touches no production code and no part of `test-receipt-authority.sh`. **That recommendation carries forward unchanged and is neither satisfied nor weakened by this candidate.** It is not a condition of this cross-review.

## 5. Is the neutral failure specifically resolved, and are the focused PASS logs credible?

**The failure is identified exactly, not merely plausibly.**

`/tmp/issue-8-source-snapshot-neutral-runner.md` records `tests/test-bootstrap-fencing.sh` exit 1 as the first nonzero, stopping the matrix at 1 of 14. `/tmp/issue-8-2a8b77f-fencing-repro.log` gives the exact diagnostic:

```
receipt authority trust prelude: production source snapshot staging parent is not root-owned and
non-writable: /tmp/tmp.zqKCddwOfx/fixture/var/lib/herdr-workstation/bootstrap/staging
```

That string is emitted only from `receipt_trust_validate_source_snapshot_path` (`scripts/ubuntu/receipt-authority.sh:198`) on the `authority_kind == production` branch — exactly the branch selected when `receipt_prelude_fixture_root` is empty. The path in the message is `$fixture_root/var/lib/herdr-workstation/bootstrap/staging`, confirming `prefix` came from the fixture policy path while the trust rules were production. Setting `--fixture-root` is the precise and minimal inversion of that condition.

**Log structure corroborates the failure site.** The repro log is: one `From …/fixture/transport` fetch pair, a second pair, then the diagnostic. That is the signature of failing at `tests/test-bootstrap-fencing.sh:79-83` — the launcher-install fetch leaks to stderr (`:38-39` redirects stdout only), the bootstrap run at `:73` is fully redirected into `$bootstrap_output` and passes silently, and the failing receipt call's capture is `cat`-ed to stderr at `:81`, contributing its own fetch pair plus the diagnostic. It cannot be the dirty call at `:107`, which is never reached.

**The PASS logs are credible.** `/tmp/issue-8-fencing-source-staging-fencing-final.out` (13 lines) contains exactly five `From … /transport` stderr fetch lines — one from the main fixture launcher install (`:38-39`, stdout-only redirect) and one each from the four non-root PowerShell case installs (`:246-249`, also stdout-only). All five main-fixture entrypoint runs (`:73`, `:79`, `:106`, `:107`, `:110`) and all four pwsh launcher runs (`:253-255`) redirect both streams into files and correctly contribute nothing. The log then shows the two expected uid-1000 SKIPs (`:164-167`) and terminates at the exact `:335` sentinel `bootstrap launcher fencing, dirty-checkout, forged-marker, and pre-line-10 tests passed.` Under `set -euo pipefail` that terminal line cannot be reached unless every intervening assertion held. This structure is only producible by the corrected file.

`/tmp/issue-8-fencing-source-staging-receipt-final.out` terminates at the `tests/test-receipt-authority.sh:960` sentinel and shows the expected uid-1000 root-only SKIP.

The builder's disclosure at correction line 41 — that an initial combined wrapper timed out and only the completed reruns are claimed — is consistent with the artifacts: the 00:37 `…-fencing.out` is 4 lines with no sentinel (truncated), while the claimed 00:43 `…-fencing-final.out` carries it. The disclosure is accurate.

**Reviewer limitation, stated plainly:** this lane is read-only and did not execute either suite. Resolution is established by static derivation against the candidate blob plus the pre-existing repro and PASS artifacts. Live re-execution at `daf84bf` is the neutral runner's job and remains required.

## 6. Findings

### P1 — none
### P2 — none

### P3 findings (all dispositioned; none blocking)

**P3-1 — At root, the fencing run's ancestry walk now stops at the fixture root instead of `/`.**
`tests/test-bootstrap-fencing.sh:7` puts `test_root` under `/var/lib/herdr-bootstrap-fencing.XXXXXX` when uid 0. Before this change a root fencing run would have taken the production branch of `receipt_prepare_source_snapshot_parent` and walked the full chain to `/`; with `--fixture-root` it breaks at `boundary == $fixture_root` (`scripts/ubuntu/receipt-authority.sh:203`) with `expected_uid = launcher_capability_owner_uid` (0 at root).
*Disposition: accept.* A coverage relocation, not a loss: the production walk to `/` is asserted directly and in both polarities by `tests/test-receipt-authority.sh:789-796` (negative, `/tmp`) and `:808-813` (positive, real `/var/lib`), both green in `/tmp/issue-8-2a8b77f-root-receipt.log`. The fencing suite's purpose is launcher fencing, not receipt ancestry semantics. Note the fencing suite has not itself been re-run at root at `daf84bf`; including it in the root gate is a cheap confirmation.

**P3-2 — The test passes a non-canonicalised `$fixture_root` into a strict equality check.**
`tests/test-bootstrap-fencing.sh:14` sets `fixture_root="$test_root/fixture"` from `mktemp -d` without `realpath`. `scripts/ubuntu/receipt-authority.sh:210` requires `realpath -e "$receipt_prelude_fixture_root" == "$receipt_prelude_fixture_root"`. If `TMPDIR` ever contains a symlinked component, both new calls fail closed with `fixture source snapshot staging root escaped the fixture root` rather than an obviously fixture-related message.
*Disposition: accept.* Fail-closed, and identical to the accepted precedent at `tests/test-receipt-authority.sh:183-184`. Empirically fine in the builder's run, which executed under `TMPDIR=/tmp/.ctx-mode-rR0XZw` (visible in the PASS log paths) — a nested but non-symlinked prefix. The fixture branch never walks above `$fixture_root`, so the sandboxed `TMPDIR` does not affect the result.

**P3-3 — The dirty-path receipt call has no diagnostic dump and no output assertion.**
`tests/test-bootstrap-fencing.sh:107-108` runs under `set -e` with both streams redirected to `$test_root/dirty-receipt-output`, which is never `cat`-ed and never grepped. A future regression there aborts the suite with no stderr explanation — unlike the clean call at `:79-85`, which dumps the capture (`:81`) and asserts `Usage:` (`:84`). The correction touched this exact line and could have added an `if ! … then cat … fi` guard.
*Disposition: accept.* Pre-existing shape (the same holds for the dirty bootstrap call at `:106`, untouched here); the exit-status assertion via `set -e` is still real coverage. Worth tightening opportunistically, not a gate condition.

**P3-4 — `--help` remains a partial exercise of receipt authority.**
`-h|--help` exits at `scripts/ubuntu/receipt-authority.sh:782`, before fixture-root output-path validation (`:810-817`), role resolution (`:945-955`), and the authority-root fixture binding (`:1068-1071`). The fencing suite's receipt coverage is launcher → capability → prelude → git snapshot → usage.
*Disposition: accept.* By design — this is a launcher-fencing suite; `test-receipt-authority.sh` owns install/check semantics.

**P3-5 — Prior-review P3-7 (live standalone `--install`) is still outstanding.**
Carried forward from `/tmp/issue-8-source-snapshot-cross-review.md`; untouched by this candidate.
*Disposition: accept, carried forward.* Recommendation only, not a condition of this gate; the production-shaped automation in `run_production_entrypoint_authority --install` passed at root.

## 7. Conduct

No edit, chmod, commit, dispatch, install, push, merge, issue mutation, sudo, or live-state mutation was performed. All repository inspection was read-only against the detached worktree at `daf84bf`; the only supporting artifacts consulted were pre-existing files under `/tmp`. The candidate worktree remained clean and at the exact candidate SHA throughout.

## Conclusion

The correction is fixture-only, four lines across one test file, and touches no production code. The two added `--fixture-root` arguments are position-independent for the prelude scanner that actually consumes them, match the argument order already accepted at `tests/test-receipt-authority.sh:183-184`, and bind to a boundary that must equal the descriptor-derived capability policy prefix — so the flag fails closed against any production install and cannot serve as a bypass. The gate it selects did not exist at the substantive base `7642442`; it became reachable at `2a8b77f`, which is precisely why the neutral fixture failed, so no previously-green production assertion is surrendered. The prior cross-review's P3-5 predicted this exact amendment for the receipt suite; this candidate completes it for the two fencing call sites that were missed. Every fencing invariant — dirty checkout, hostile `PATH`/`BASH_ENV`, forged markers, pre-line-10 non-execution, direct-execution capability rejection, PowerShell trust seam, retired-invariant greps — survives unmodified. The production ancestry branch retains dedicated positive and negative root coverage that is green and still evidentially valid at `daf84bf`. The neutral failure is resolved by exact diagnostic match, and the PASS logs' internal fetch/SKIP/sentinel structure is uniquely consistent with the corrected file. Five P3 findings, all dispositioned as accept; none blocking. Live re-execution at `daf84bf` remains the neutral runner's requirement, as does the carried-forward live standalone `--install` confirmation.

PASS FOR CROSS-REVIEW

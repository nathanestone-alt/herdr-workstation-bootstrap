# Independent cross-review return (final re-review) — herdr-workstation-bootstrap issue #8

- Reviewer: Anthropic `claude-opus-5`, reasoning `high`, service tier `normal`, fast mode disabled.
- Repository: `nathanestone-alt/herdr-workstation-bootstrap`
- Detached review worktree: `/tmp/herdr-bootstrap-issue-8-review-ca863b9` (clean; `HEAD` verified).
- **Exact candidate SHA: `ca863b98902dca85f16513f9a934d4d1046b001c`**
- **Review base: `2e3a2cc63c2e81a2e695951687e385decd02b7a5`**
- Range reviewed: the complete `2e3a2cc..ca863b9` diff — all six commits `5f7e823`, `8a583b3`,
  `47ba3e3`, `9b36b7f`, `b842f3d`, `ca863b9` — not only the correction tip.
- Prior blocked candidate: `b842f3d07c961aae488eeec8aa1804bcd9ed16eb`
  (prior return: `/tmp/issue-8-opus-rereview-return.md`).
- Builder correction artifact: `/tmp/issue-8-fixture-execution-correction-return.md`.
- Read-only boundary honored: no edits to tracked files, no sudo, no install/commission, no
  push/merge, no GitHub mutation, no pane control, no downstream dispatch. Only this artifact and
  throwaway probes under the session scratchpad were written; all probe temporaries were removed.
- The native root gate is a separate orchestrator-owned step. No root PASS is inferred here, and
  none is claimed; the two P1 resolutions below are established by execution of the fixture
  *generation* path plus static evidence, at uid 1000.

## Scope of change in the tip

`git diff --stat b842f3d..ca863b9` touches exactly one file,
`tests/test-bootstrap-privilege-model.sh` (+10 / −11). No production file, document, or validator
entry changed between `b842f3d` and `ca863b9`. The production correction re-verified below is
therefore byte-identical to the one already approved, and I re-verified it independently rather
than carrying the prior verdict forward.

## Verification performed

Static: full `2e3a2cc..ca863b9` diff across all 9 changed files; full read of
`tests/test-bootstrap-privilege-model.sh` (293 lines) and of the changed regions of
`scripts/ubuntu/bootstrap.sh`, `scripts/ubuntu/trusted-launcher.sh`,
`tests/test-trusted-launcher.sh`, `docs/bootstrap-trust-anchor.md`,
`scripts/Validate-Repository.ps1`. `bash -n` clean on all seven changed shell files.
`git diff --check` clean.

Dynamic (non-root, non-mutating; each suite run independently with its own exit recorded):

| Suite | Result | Exit |
|---|---|---:|
| `tests/test-bootstrap-profile.sh` | PASS | 0 |
| `tests/test-trusted-launcher.sh` | PASS (root-gated drop section SKIPped at uid 1000) | 0 |
| `tests/test-bootstrap-fencing.sh` | PASS (root-only PowerShell cases SKIPped) | 0 |
| `tests/test-receipt-authority.sh` | PASS | 0 |
| `tests/test-bootstrap-privilege-model.sh` | SKIP at uid 1000 (root gate, line 6) | 0 |

Targeted execution probes (scratchpad only, since the suite's own root gate cannot be satisfied
in this session):

1. **Fixture-generation harness.** An unmodified copy of
   `tests/test-bootstrap-privilege-model.sh` lines 1–156 with only the uid-0 gate (lines 6–9)
   neutered, the two `chown` calls (lines 36–37) neutered, and `repo_root` pinned — all strictly
   before or irrelevant to the failure point that blocked `b842f3d`. **Exit 0.** At `b842f3d` this
   same harness aborted with `bootstrap_command_index: unbound variable`.
2. **Generated-fixture inspection.** The emitted
   `$case_root/source/scripts/ubuntu/bootstrap.sh` is `bash -n` clean, and the appended block
   (generated lines 2361–2405) contains *only* function definitions and the final
   `case "$phase" in … esac` dispatch — zero top-level statements, confirmed by a
   column-0 scan of the appended region.
3. **Stub materialization.** `$case_root/bin` after outer setup contains
   `apt-get git ps pwsh sudo systemctl tailscale`, all mode `0755`; `bin/git` carries the intended
   literal body (`[[ "$*" == 'lfs install --system' ]]`, `"$CASE_ROOT/git-lfs-home"`, `"$HOME"`).
4. **End-to-end root-scoped-HOME path.** Executing the *generated* `bootstrap_exec_system`
   override with `HOME=$root_home /usr/bin/git lfs install --system` rewrote the argument to the
   stub, the stub was reached, and `$case_root/git-lfs-home` contained exactly `$root_home` —
   i.e. GNU `env`'s last-assignment-wins ordering carries the production `HOME=/root` past the
   fixture's `HOME=$fixture_home`, and assertion line 229 is live.

---

## P1 findings (blocking)

**None.** Both prior P1s are resolved.

### Prior P1-1 (heredoc arithmetic evaluated by the outer shell) — resolved

`tests/test-bootstrap-privilege-model.sh:119` is now
`    bootstrap_command_index=\$((bootstrap_command_index + 1))`. With the outer delimiter still
unquoted (`:108` `cat >> … <<EOF`), the escape stops the outer shell from evaluating the
arithmetic under `set -u`, and the construct reaches the generated fixture literally as
`bootstrap_command_index=$((bootstrap_command_index + 1))` (generated line 2377, inside
`bootstrap_exec_system`, where `local bootstrap_command_index=0` at generated line 2374 defines
it). Verified by execution: probe 1 now exits 0 where `b842f3d` exited 1, and probe 2 shows the
literal text in the emitted fixture. The escaping is now consistent with every other `$`-construct
in that heredoc (`\$@` :116, `\${bootstrap_exec_args[…]}` :118/:121/:125, `\$1` :110/:112,
`\$phase` :145).

### Prior P1-2 (top-level `git`-stub write re-executed by every `nobody` runtime child) — resolved

The `cat`/`chmod` pair no longer exists inside the generated fixture. The stub is created once in
outer root setup at `tests/test-bootstrap-privilege-model.sh:92-100`, using a **quoted**
`<<'EOF'` delimiter so `$*`, `$HOME`, and `$CASE_ROOT` reach the stub literally, and it is placed
**before** the bulk `chmod 0755 "$case_root/bin/"*` at `:101`, so it inherits executable mode with
the other six stubs (verified: `-rwxr-xr-x … git`). Probe 2 confirms the appended fixture block
contains no `cat`, `chmod`, or any other top-level statement, so
`bootstrap_run_as_runtime_phase`'s `setpriv --reuid=nobody … --no-new-privs` re-exec
(`scripts/ubuntu/bootstrap.sh:255-275`) now only defines functions at load time before dispatching
on `$phase`. The `EACCES`/`EPERM` abort path is gone.

Two secondary properties I checked because the relocation moved the stub earlier in the script:
- `$case_root/bin` is not on the ambient `PATH` used for `install-trusted-launcher.sh` (`:196`) or
  for the `/usr/bin/git init|add|commit|clone` calls at `:158-165`, and `$case_root/bin` is a
  sibling of `$source_root`, so the earlier materialization cannot shadow or be captured by the
  fixture repository construction.
- `bootstrap_git_bin` is `readonly … '/usr/bin/git'` (`scripts/ubuntu/bootstrap.sh:10`) and is not
  routed through `bootstrap_command_path`, so the override's exact-match rewrite at
  `tests/test-bootstrap-privilege-model.sh:121-123` remains the only interception point; the
  fixture's `bootstrap_command_path` whitelist (`:111`) legitimately omits `git`. The trust
  prelude's own Git invocation (`scripts/ubuntu/bootstrap.sh:533-551`) builds its own `env -i`
  directly and runs before the override is defined, so it is unaffected.

## P2 findings (blocking)

**None.**

---

## Required items — verification results

| # | Item | Result |
|---|------|--------|
| 1 | Root `install_base` must not create or replace root-owned artifacts in the runtime user's HOME | **Pass.** `bootstrap.sh:1959-1963, 1970, 1978` route the three offending commands through `bootstrap_exec_root_scoped` / `bootstrap_exec_user_runtime`. `bootstrap_exec_system` (`:215-229`) passes only `PATH`, `LC_ALL`, `TZ` under `env -i` — no `HOME` at all — so every other privileged seam (`apt-get update/install`, `bootstrap_install_locked_deb`, `systemctl enable --now`, `install_locked_tailscale`'s root stages) runs `HOME`-less. Re-walked `install_base` (`:1930-1998`) end to end: the only remaining ambient-environment root calls are `ps -p 1 -o comm=` (`:1966`) and `tailscale version` (`:1509`), neither of which writes `$HOME`. |
| 2 | Root-scoped Git LFS system scope, root-scoped PowerShell HOME, non-root behavior, fail-closed seams | **Pass.** `--system` targets `/etc/gitconfig`; both PowerShell probes go through `bootstrap_probe_powershell_version` (`:314-321`) → `bootstrap_exec_root_scoped` (`:306-312`) with `HOME=$bootstrap_root_home`. `bootstrap_exec_root_scoped` returns 24 outside root mode; at `:1960` `set -e` aborts, and the `$( )` capture at `:1978` turns a 24 into a lock mismatch and `exit 24`. The `|| true` at `:1970` is a deliberate presence check. Non-root keeps the user's `HOME` via `bootstrap_exec_user_runtime` (`:294-303`). `bootstrap_root_home` is unconditionally set at `:305`, so the environment cannot influence it. Nothing downstream consumes the user-global LFS config (only dpkg presence checks in `verify.sh` / `install-payload.sh`). |
| 3 | Strengthened native root fixture is generatable and genuinely detects the pollution | **Pass.** Generation now exits 0 (probe 1); the emitted fixture is `bash -n` clean with no top-level side effects (probe 2); the `git` argument rewrite plus root-scoped `HOME` was exercised end to end and produced `$root_home` (probe 4). Assertions `:229-233` (git-lfs HOME), `:234-238` (pwsh HOME), `:239-248` (root artifacts exist and are `0:0`), `:249-259` (runtime-HOME artifacts absent) are all reachable, as are the pre-existing `setpriv`/`sudo` contradiction probe (`:168-194`), the `sudo`-not-invoked check (`:219-220`), the runtime-HOME handoff (`:274-290`), and the fd 13/14/15 one-use coverage (`:260-273`). See P3-1 for the one assertion in that set that is inert by construction. Root execution itself is the orchestrator's gate, not claimed here. |
| 4 | Launcher-bound identity | **Pass.** Supplied only via `env -i` at `trusted-launcher.sh:241-250`; `home` is derived from `getent passwd "$launcher_runtime_uid"` (`:182-183`). `bootstrap.sh:668-683` validates numeric uid/gid and an absolute non-`/` home, and requires `HOME` to equal the bound runtime home. Runtime children get `env -i` *without* those variables, so they re-derive from their own credentials and land in `bootstrap_root_mode=0` (`:681-684`). |
| 5 | Root transaction for `bootstrap`; other entrypoints unchanged | **Pass.** `trusted-launcher.sh:241-250` runs `bootstrap` with no `setpriv`; `:251-252` keeps `receipt-authority` root-scoped and the same-uid case direct; `:253-256` still `setpriv`-drops `verify`. `test-trusted-launcher.sh:574-589` now exercises that drop through a real `verify` fixture (`:43-58`), and the suite passes at exit 0 here. |
| 6 | `setpriv --clear-groups --no-new-privs` runtime children; no nested sudo | **Pass.** `bootstrap.sh:259-262`. In root mode every `sudo` seam is replaced by direct execution: `sudo_bin=''` at `:766-770`, `:1501-1505`, `:1935-1939`, and `bootstrap_exec_privileged` (`:231-238`) drops the argument entirely when `bootstrap_root_mode == 1`, so no empty argv0 is ever executed and no `no_new_privs` child reaches `sudo`. |
| 7 | Policy descriptor pool (fd 13/14/15) | **Pass.** `trusted-launcher.sh:169-179` re-opens `/proc/$policy_pid/fd/9` three times — independent open descriptions on an already-bound inode, not a mutable pathname — identity-checks each against `policy_id`, then re-runs `policy_lifetime`; opened only for the `bootstrap` entrypoint. One-use is enforced by the counter at `bootstrap.sh:241-256`; the child dups its one descriptor onto fd 9 and closes 13/14/15 before `exec` (`:265-274`). Pool size 3 exactly matches `base-user` + `tools-prepare` + `tools-finalize` for `--phase all`; both exhaustion and non-root call fail closed with 24. Cleanup extended to 13/14/15 (`trusted-launcher.sh:135-137`). |
| 8 | Trusted-Bash HOME handoff | **Pass.** `bootstrap.sh:257-275` passes `HOME="$bootstrap_runtime_home"` into `bootstrap_exec_system` and the child `exec`s `"$trusted_bash" "$bootstrap_script_path" --phase …` directly, bypassing the `env -S -i` shebang that would otherwise collapse `HOME`. Argument threading (`_ <fd> <bash> <script> --phase <phase>`, then `shift`/`shift`) resolves correctly. |
| 9 | Receipt sequencing | **Pass.** `install_tools` (`:2351-2359`): `tools-prepare` (runtime) → `install_receipt_from_snapshots` (root) → `tools-finalize` (runtime). Receipt authority stays root-scoped at the launcher (`trusted-launcher.sh:251`). |
| 10 | Documentation and validator registration | **Pass with P3-3/P3-4/P3-5.** `docs/bootstrap-trust-anchor.md:75-84` accurately describes the root transaction and the `verify` drop; the new suite is registered in both `Validate-Repository.ps1:50` and `:172`; launcher-side `HERDR_BOOTSTRAP_RUNTIME_UID/GID/HOME` pins are present at `:316`. Nothing stated is wrong; the gaps are completeness only. |
| 11 | No workbook / web-port / HyperFormula coupling | **Pass.** Case-insensitive scan of the full `2e3a2cc..ca863b9` diff for `hyperformula`, `workbook`, `stmodel`, `web-port`, `localhost:<port>`, `.xlsm` matches only two pre-existing **context** lines in `Validate-Repository.ps1` (unchanged Windows-side `MANUAL-START.md` / dependency-plan assertions). No such token is added or removed anywhere in this candidate. |

---

## P3 observations (each explicitly disposed of)

### P3-1 — NEW: the `$fixture_home/.gitconfig` assertion is inert by construction
`tests/test-bootstrap-privilege-model.sh:92-100` (stub) vs. `:249-259` (assertion loop). The `git`
stub never writes any `gitconfig`; it only records `$HOME` and rejects any argv other than
`lfs install --system`. So `[[ ! -e "$fixture_home/.gitconfig" ]]` at `:250` can never fail — it
would hold even if the production code regressed. **Disposition: accepted, not blocking.** The
regression this assertion nominally guards is caught twice over by live checks: reverting to
`bootstrap_exec_user_runtime "$bootstrap_git_bin" lfs install` in root mode makes `$*` become
`lfs install`, so the stub exits 24 and the base phase fails at `:209-215`; and any HOME-scoping
regression trips the live `:229-233` check, which probe 4 confirms is wired correctly. Making the
stub emit a `$HOME/.gitconfig` on the non-`--system` path would turn `:250` into a real assertion.

### P3-2 — `/root` is used as a root HOME without any validation
`scripts/ubuntu/bootstrap.sh:305`. Unlike every other trusted path in this script, `/root` is not
checked for existence, ownership, mode, or symlink components (contrast
`bootstrap_trust_assert_root_owned_parent_chain`, `:110-125`). **Disposition: accepted, not
blocking** (carried forward, unchanged). Only root can retarget `/root`, so an attacker able to do
so already holds the privilege the bootstrap is exercising. A
`bootstrap_trust_reject_symlink_components '/root'` is the tightening.

### P3-3 — `bootstrap_root_home` is a mutable global by design
`scripts/ubuntu/bootstrap.sh:305`, overridden by the fixture at
`tests/test-bootstrap-privilege-model.sh:147`. Every other trusted seam in the prelude is
`readonly`. **Disposition: accepted** (carried forward). The test-only override is precisely why it
cannot be `readonly`; the assignment executes in the prelude, long before the appended `case`
dispatch, and the environment cannot influence it. I re-confirmed the ordering in the generated
fixture: production `:305` lands well ahead of the appended block at generated line 2361.

### P3-4 — `git lfs install --system` is a new, undocumented system-wide side effect
`scripts/ubuntu/bootstrap.sh:1960`; `docs/bootstrap-trust-anchor.md` contains no occurrence of
`lfs` or `gitconfig` (grepped: none). Root provisioning now writes `filter.lfs.*` into
`/etc/gitconfig` for *all* accounts on the host, where the base behavior touched one user's
`~/.gitconfig`. **Disposition: accepted** (carried forward, unchanged by `ca863b9`). It is the
correct fix for the earlier P2, and strictly more consistent for a provisioned workstation, but an
operator reading the trust anchor today would not expect `/etc/gitconfig` to change.

### P3-5 — Documentation still omits the `base-user` child and the fd 13/14/15 pool
`docs/bootstrap-trust-anchor.md:75-84`. The revised paragraph correctly states that `bootstrap`
stays in the root transaction and that tools work runs in a `setpriv --no-new-privs` child, but it
does not mention the `base-user` child that publishes `base-complete`
(`scripts/ubuntu/bootstrap.sh:1996`) nor the three-descriptor policy pool
(`scripts/ubuntu/trusted-launcher.sh:169-179`) that makes those children possible.
**Disposition: accepted** (carried forward). Nothing stated is wrong.

### P3-6 — Validator registration does not cover the new root-scoped seams
`scripts/Validate-Repository.ps1:312`. The `Required` list for `bootstrap.sh` gained
`bootstrap_exec_privileged`, `bootstrap_run_as_runtime_phase`, `bootstrap_root_mode`, `base-user`,
`tools-prepare`, `tools-finalize`, but a grep for `bootstrap_exec_root_scoped`,
`bootstrap_probe_powershell_version`, and `lfs install --system` in that file returns **0**
matches. **Disposition: accepted** (carried forward). The new suite is correctly registered in both
`:50` and `:172`, and the launcher-side runtime-identity pins are present at `:316`. Adding the
three tokens would make the root-scoping fix itself tamper-evident to the validator.

### P3-7 — The fixture's `bootstrap_exec_system` override drops the `/proc/self/fd/` rewriting
`tests/test-bootstrap-privilege-model.sh:115-126` vs. `scripts/ubuntu/bootstrap.sh:216-223`. The
production helper rewrites `/proc/self/fd/N` arguments to `/proc/$BASHPID/fd/N`; the override does
not. **Disposition: accepted** (carried forward, unchanged by `ca863b9`). No path reachable from
`install_base` passes such an argument, so the fidelity gap is inert today.

### P3-8 — `run_launcher` still passes the fixture cwd through as an entrypoint argument
`tests/test-trusted-launcher.sh:107-113`. `shift 2 || true` (`:110`) is a no-op returning 1 when
`$#` is 1, so single-argument call sites invoke
`"$launcher" --entrypoint bootstrap -- "$test_root"`. **Disposition: accepted, not blocking**
(carried forward). The fixture `bootstrap.sh` ignores `"$@"`, and every affected case is either a
pass-through or an `expect_failure` that aborts before argument handling.
`shift $(( $# > 2 ? 2 : $# ))` is the tightening. The suite passes here at exit 0.

### P3-9 — fds 13/14/15 leak into the root receipt hand-off
`scripts/ubuntu/trusted-launcher.sh:169-179` opens the pool for every `bootstrap` invocation, and in
root mode `install_receipt_from_snapshots` (`scripts/ubuntu/bootstrap.sh:769`) is reached without
`sudo`, so `sudo`'s descriptor closing no longer applies. Only the runtime children close them
(`scripts/ubuntu/bootstrap.sh:274`). **Disposition: accepted as non-escalating** (carried forward).
The leaked descriptors are read-only handles on the `0600` root-owned policy object whose contents
— canonical HTTPS origin and pinned commit — are public. A one-line `exec 13<&- 14<&- 15<&-`
before the hand-off would close it.

### P3-10 — Manifest emission is still duplicated between the transaction and finalize paths
`scripts/ubuntu/bootstrap.sh:2159-2226` vs. `:2255-2325`. **Disposition: accepted** (carried
forward). The blocks remain byte-identical apart from `install_tools_finalize` correctly omitting
`close_fence_fd "$profile_dir_fd"`. Extraction into a shared helper is the follow-up.

### P3-11 — `bootstrap_exec_privileged` keys on mode rather than on its `sudo_bin` argument
`scripts/ubuntu/bootstrap.sh:231-238`. **Disposition: accepted** (carried forward). Every call site
sets `sudo_bin=''` under exactly the same `bootstrap_root_mode == 1` condition (`:766-770`,
`:1501-1505`, `:1935-1939`), and in that mode the helper discards the argument, so the empty-argv0
combination cannot arise today.

### P3-12 — Fenced directory creation still crosses a privilege boundary
`scripts/ubuntu/bootstrap.sh:1949-1950` and `:278-291` run as root inside a tree the runtime user
controls. **Disposition: accepted** (carried forward). The walk is fd-anchored rather than
pathname-resolved, `chown` uses `--no-dereference` with a post-check, and in root mode no file
content is written through the anchors. Worst case for a lost race is a root-owned `mkdir`, not
attacker-writable state.

---

## Summary

`ca863b9` changes exactly one file relative to `b842f3d`, and it changes precisely the two things
the prior review blocked on. Both are resolved, and both resolutions are demonstrated rather than
asserted:

- **P1-1** — the arithmetic increment is escaped at
  `tests/test-bootstrap-privilege-model.sh:119`, so it survives the outer unquoted heredoc and
  executes only inside the generated fixture. The generation path that aborted at `b842f3d` with
  `bootstrap_command_index: unbound variable` now runs to completion (exit 0) in a faithful
  harness, and the emitted fixture carries the construct literally.
- **P1-2** — the `git` stub is created once in outer root setup with a quoted heredoc
  (`:92-100`), ahead of the bulk `chmod 0755 "$case_root/bin/"*` at `:101`, and verified present at
  mode `0755` with the intended literal body. The generated fixture's appended block now contains
  only function definitions and the phase dispatch — no top-level statement of any kind — so
  `nobody` runtime-child re-execs no longer attempt to rewrite a root-owned file.

The already-approved production correction re-verifies clean on independent re-review: root-scoped
Git LFS system config, root-scoped PowerShell probe HOME, preserved non-root behavior, fail-closed
`bootstrap_exec_root_scoped`, launcher-bound identity, the root `bootstrap` transaction,
`--clear-groups --no-new-privs` runtime children with no nested `sudo`, the one-use fd 13/14/15
descriptor pool, the trusted-Bash HOME handoff, receipt sequencing, and no workbook / web-port /
HyperFormula coupling anywhere in the range. I found no P1 and no P2.

Twelve P3 observations are recorded and each is explicitly disposed of; one (P3-1, the inert
`.gitconfig` assertion) is new to this candidate and is a test-fidelity note, not a coverage hole,
because two live assertions catch the same regression.

Scope note carried into the verdict: this session runs at uid 1000 and cannot obtain root, so the
root-gated suite itself was not executed here — it SKIPs at line 6 with exit 0, as expected. The
orchestrator's native root gate remains the authority on that execution, and this review makes no
claim about it. Given the prior gate's aggregate-marker problem, that gate should record per-suite
exit statuses for `tests/test-bootstrap-privilege-model.sh` specifically.

PASS FOR CROSS-REVIEW

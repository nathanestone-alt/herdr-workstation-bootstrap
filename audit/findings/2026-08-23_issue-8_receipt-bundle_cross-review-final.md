# Independent Cross-Review — Issue #8 Receipt Authority & Tooling Candidate

## Candidate / Base / Route

| Field | Value |
|---|---|
| Candidate | `90f40c6ca17823f8ab9e2c23216d0b0bdf1a478f` ("Use managed ancestry for root tools fixture") |
| Base | `710e2ca` (origin/main at dispatch) |
| Range reviewed | `git diff 710e2ca..90f40c6` (12 commits, 4 files, +1511/−215) plus the exact candidate tree |
| Worktree | `/tmp/herdr-bootstrap-issue-8-review-90f40c6` (detached, read-only) |
| Route | Fresh headless Claude invocation, provider Anthropic, `claude-opus-5`, reasoning effort high, service tier normal, fast mode disabled |
| Controlling issue | `nathanestone-alt/herdr-workstation-bootstrap#8` |
| Constraints honoured | No edits, no chmod, no commit/dispatch/install/push/merge, no issue mutation, no `sudo`, no live installed state touched. Builder reasoning documents were **not** used as evidence; all conclusions derive from the candidate tree, the diff, and the two gate logs. |

## Reviewed Surfaces

Full diff, not only the last two fixture corrections:

- `scripts/ubuntu/bootstrap.sh` (+298/−…): root receipt payload extracted to a literal heredoc producer (`747-889`), `bootstrap_exec_privileged_payload` (`891-895`), rewired caller (`898-926`).
- `scripts/ubuntu/receipt-authority.sh` (+643/−20): whole file read (1923 lines). New sealed directory-bundle subsystem (`896-1462`), staging-ancestry validation (`928-996`), cleanup change (`530-548`), fixture-root canonicalisation (`718-723`), fixture pwsh rebinding (`852`), sealed-prefix Python probe bindings (`1681-1689`), durable receipt bundle metadata (`1690-1752`), new receipt contract assertion (`1861`).
- `tests/test-receipt-authority.sh` (+313): bundle mutation harness (`273-364`), writable-stage-parent rejection (`386-397`), production simulation environment (`607-682`), `/tmp` ancestry rejection (`748-756`), production install handoff (`798-802`), race-glob rebinding (`533`).
- `tests/test-bootstrap-tools.sh` (+452): root-mode fixture ancestry (`7-20`, `86-90`), fixture rewrites with post-conditions (`152-170`), `assert_payload_delivery` (`173-294`), PowerShell package-shaped fixture and probe accounting (`470-520`, `785-830`).
- Unchanged-but-load-bearing context read for correctness of new dependencies: `scripts/ubuntu/launcher-capability.sh` (`296-447`), `scripts/ubuntu/bootstrap.sh:188-193, 214-239, 1425-1475, 1795-1820, 1950-2015, 2414-2431`.

## Evidence Assessed

- `/tmp/issue-8-90f40c6-root-tools.log` — root tools gate PASS; fixture ancestry resolved under `/var/lib/herdr-workstation/bootstrap/staging/herdr-test-bootstrap-tools.iaoJ2x`.
- `/tmp/issue-8-90edc93-root-receipt.log` — root receipt gate PASS; contains the decisive line proving the production simulation genuinely ran production authority: `receipt authority install: authority=/var/lib/herdr-workstation/bootstrap/staging/herdr-test-production-simulation.iJDfBa/output/...`, and the `/tmp/herdr-test-production-ancestry-rejection.bb02p8` fixture is separately visible. Delta `90edc93..90f40c6` touches only `tests/test-bootstrap-tools.sh`, so the receipt gate remains applicable.
- Builder artifacts `/tmp/issue-8-pyvenv-root-correction.md`, `/tmp/issue-8-root-tools-staging-correction.md` and the prior `issue-8-receipt-handoff-cross-review*` artifacts were deliberately **not** used as reasoning evidence per the brief.

## Rubric Findings

### 2 — Privileged receipt handoff payload — **clean**

- The payload is now a quoted heredoc (`bootstrap.sh:748` `<<'HERDR_RECEIPT_ROOT_PAYLOAD'`), so the body is structurally literal: `$1..$3`, `$BASHPID`, `${line:0:2}` with an embedded literal TAB, `\0` traversal and `\t` field splitting all reach root unexpanded. The prior double-escaping (`\$1`, `\"commit\"`, `\$1` inside gawk) is gone.
- **Source-commit parsing is balanced**: `bootstrap.sh:821` is `'{ if ($1 == "commit") { print $2; found++ } } END { exit(found == 1 ? 0 : 1) }'`. The base form nested `END` inside the main action block — a malformed program. Fixed.
- **Positional arguments survive delivery**: `bootstrap_exec_privileged_payload` (`891-895`) → `bootstrap_exec_privileged` (`231-239`) → `bootstrap_exec_system` (`214-228`) → `env -i PATH=… /usr/bin/bash -c "$payload" -- a b c`. `$0` is `--`; `$1..$3` are the three arguments. `env` and `sudo` both pass argv verbatim.
- **Null-delimited traversal survives**: `find -P "$root" -mindepth 1 -print0` with `read -r -d ''` is delivered byte-for-byte, and `tests/test-bootstrap-tools.sh:283-292` greps for exactly those fragments.
- **Byte-safety is proven, not asserted**: `assert_payload_delivery` (`173-294`) re-extracts the heredoc body, stubs `bootstrap_exec_privileged` to capture argv element 4, asserts the argv *shape* (`$# == 8`, `-c`, `--`, three expected values) and `cmp`s the delivered string against the heredoc source. `receipt_root_payload+=$'\n'` (`bootstrap.sh:921`) exactly compensates the trailing-newline strip of command substitution — and the `cmp` proves it.

### 3 — Directory-backed pwsh and locked Python bundles — **clean**

- **Bounded roots.** pwsh: `dirname(role_path[pwsh])`, enumerated at `-maxdepth 1` only (`1140`); `Modules|Schemas|en-US|ref` are validated as real directories but never staged, and the two legacy OpenSSL aliases are the only permitted symlinks, pinned to exact targets (`1127-1133`). Python: an explicit file/dir list plus a full walk of `$python_stdlib_root` only (`1168-1193`); the runtime root must be lexically inside the managed prefix (`1163-1167`).
- **Complete source snapshot + manifest.** Two manifests are produced per role: a normal manifest (path/mode/uid/gid/digest/transform) and a snapshot manifest that additionally carries `%d:%i` device/inode identity (`1045-1046`, `1081-1082`), sorted deterministically under `LC_ALL=C` (`1085-1098`).
- **Stage/source closure equality.** `receipt_bundle_assert_stage` (`1333-1391`) builds `expected` from the manifest and `actual` from a physical walk of the stage, sorts both, and `cmp -s`. Extra or omitted entries fail (`1374`).
- **Fail-closed mutations.** Symlink in stage → `1361-1362`; unsupported entry → `1367-1368`; path traversal → `receipt_bundle_safe_relative_path` (`899-910`, component charset `[A-Za-z0-9._+@=-]`, no `.`/`..`/absolute/tab/newline) enforced on both source (`1030`, `1058`) and stage (`1360`); owner → `1381`; mode → `1389` against `receipt_bundle_stage_mode` (`912-918`, write bits masked to `0555`); digest → `1387` against the per-file staged digest recorded at copy time (`1313`).
- **Source races.** Every file is digested through a held descriptor (`1070-1080`, `1256-1268`), with `%d:%i` compared across fd/live before and after (`1289-1297`), and the whole source manifest is rebuilt and `cmp`'d after staging and again after probing (`1393-1403`, `1529-1532`, `1589-1591`, `1726-1728`).
- The mutation harness (`tests/test-receipt-authority.sh:273-364`) exercises extra/omitted/traversal/mode/digest/owner/symlink against a live paused authority; the path-traversal case symlinks to `/tmp` and the cleanup path (`chmod -R` and `rm -rf`, both coreutils `-P` by default) does not dereference it — no escape.

### 4 — Authority-controlled staging ancestry and cleanup — **clean**

- The staging root is not a free parameter: it is derived from `launcher_capability_policy_path` (`967-973`), which `launcher-capability.sh:298-338, 421-423` already binds to the fd-9 policy object, requires to end in `/etc/herdr-workstation/bootstrap-policy.conf`, mode `600`, and for which it independently asserts `"$prefix/var/lib/herdr-workstation/bootstrap/staging"` is owner-matched and `755`, root:root when the prefix is empty.
- `receipt_bundle_validate_authority_path` (`928-965`) additionally walks every ancestor to `/` in production, requiring uid 0, gid 0 and no group/other write bit at each level. `/tmp`-rooted staging is therefore structurally impossible — and this is asserted with the exact diagnostic in the root gate.
- The run-independent `receipt-runtime` parent is **rejected, not repaired**, when it already exists in an unsafe state (`985-993`), and the test proves the mode is left untouched after rejection (`tests/test-receipt-authority.sh:393-397`).
- TOCTOU: the scratch root is `mktemp -d` (unguessable, `0700` at creation) inside a root-owned non-writable parent, then re-validated after every permission change (`1004-1016`). Path replacement of the source is caught by fd-stable identity comparison. Cleanup (`530-548`) only widens `u+w` on the two paths it created and `rm -rf`s `mktemp`-generated paths; it cannot leave an attacker-writable parent (`receipt-runtime` remains `0755` root:root).

### 5 — Durable receipt metadata and check-mode binding — **clean**

- Exact source commit: `source_commit == launcher_capability_policy_commit` (`750-751`); in payload mode the external `--source-commit` must equal both the prelude binding and the policy commit (`765-766`).
- Runtime bundles, transforms, manifests: `bundle.{kind,source_root,source_entry,execution_root,manifest_sha256,file_count,directory_count,source_owner,stage_mode_policy}` for both `pwsh` (`1752`) and `python313` (`1723`). `manifest_sha256` covers per-entry mode/uid/gid/digest **and** the transform label (`1081`), so `pyvenv-home-sealed-runtime-v1` is bound.
- Executables: `execution_path` / `execution_sha256` (`1455-1460`) with the staged digest re-verified in `receipt_assert_source_identity` (`1538-1540`).
- pyvenv semantics: `home` must equal the locked runtime root, `include-system-site-packages` must be `false`, `version` must equal the lock (`1607-1612`); the sealing transform requires exactly one `home =` line or aborts (`1270-1282`).
- Check mode is a true rebind, not a re-read: `--check` re-stages, recomputes `python_json` and `role_manifest_json`, and `validate_installed_authority` compares the stored values byte-for-byte against the recomputed ones (`1879-1883`), plus the new structural contract at `1861`. The tampered-`manifest_sha256` test (`tests/test-receipt-authority.sh:406-409`) confirms the binding bites.
- Probe binding now targets the sealed tree, not the live one: `prefix`, `base_prefix` and `stdlib` are asserted against the stage-derived paths (`1681-1687`), while the durable receipt records the *stable* managed paths plus stable `sealed://` labels (`1688-1689`, `1718-1722`) — correctly avoiding the unstable `mktemp` component in durable state.

### 6 — Root test faithfulness and isolation — **clean**

- The production simulation passes **no** `--fixture-root`, so the authority takes every production branch: root requirement (`468`, `725-729`), root-owned payload closure (`469-476`), `/etc/os-release` Ubuntu check (`783-787`), setpriv boundary (`779-781`), canonical system role binaries (`861-874`), `chown 0:0` staging, and unprivileged setpriv Python probes. The root receipt log line naming `/var/lib/.../herdr-test-production-simulation.iJDfBa/output/...` confirms it executed end to end.
- The negative `/tmp` ancestry rejection remains and is exact-message matched (`748-756`): `receipt authority: production runtime bundle staging parent is not root-owned and non-writable: /tmp`. I traced the walk and confirm `/tmp` is the first failing ancestor, so the assertion cannot pass for the wrong reason.
- The two fixtures are separate objects with distinct names; the rejection fixture is destroyed and its variables reset before the positive simulation is prepared (`757-762`).
- Cleanup is pattern-bounded in both suites (`tests/test-receipt-authority.sh:6-24`; `tests/test-bootstrap-tools.sh:9-20`) — an `rm -rf` only fires for paths matching the two literal fixture-name prefixes, plus the `mktemp` test root. The receipt suite adds HUP/INT/QUIT/TERM traps.
- Live-state hygiene improved elsewhere: the role-stage race loop no longer globs all of `/tmp/herdr-receipt-exec.*` but only the fixture's own staging parent (`533`).

### 7 — Bootstrap tools lifecycle compatibility — **clean**

- `bootstrap.sh`'s only behavioural change is the payload extraction; the RTK, Node/npm, Codex, Claude, Bun, Herdr, Python and PowerShell install paths are untouched by the diff. The locked official RTK contract (`receipt-authority.sh:814-817`, exact `rtk-x86_64-unknown-linux-musl.tar.gz` URL, semver, lowercase SHA-256) and the single-canonical-candidate rule (`1630-1643`) are unchanged.
- PowerShell remains bound to the official `.deb` layout: `bootstrap.sh:28-29, 188-193` prefer `/opt/microsoft/powershell/7/pwsh`, matching the authority's own binding and its production assertion that pwsh is one of the two canonical paths (`861-866`).
- The tools fixture now models the package-shaped PowerShell root and *accounts for every probe*: exactly `--version` (receipt authority, through the staged execution object) and `-NoProfile -Command $PSVersionTable.PSVersion.ToString()` (manifest), with any other argv failing closed and an explicit "no unrecorded probe" assertion (`tests/test-bootstrap-tools.sh:812-828`). In root mode it asserts the receipt bound the **host** package (`/opt/microsoft/powershell/7/pwsh`) with `bundle.kind == sealed-directory-v1` and `file_count > 1` (`790-806`).
- The fixture's `tools-prepare` / `tools-finalize` branches mirror the real dispatch at `bootstrap.sh:2429-2430`; both real functions exist at base.

### 8 — Issue register

**P1: none.**

**P2: none.**

**P3 (five, all dispositioned below).**

## P3 Dispositions

**P3-1 — Root fixtures depend on, and write into, live `/var/lib/herdr-workstation/bootstrap/staging`.**
`tests/test-bootstrap-tools.sh:7, 86-90`; `tests/test-receipt-authority.sh:5, 607-635`. Both root fixtures `mktemp -d` inside the live launcher staging root because production ancestry validation requires an unbroken root-owned, non-group/other-writable chain to `/`. The receipt suite first asserts that chain (`assert_root_owned_nonwritable_chain`, `607`); the tools suite does not — it will die on a bare `mktemp` error if the launcher is not installed. Neither suite skips gracefully on a host without the launcher.
**Disposition: accept.** Non-blocking. The rationale is sound (no other reachable location supplies production-shaped ancestry), the names cannot collide with real launcher artefacts (`.incoming.*`, `receipt-runtime`), and cleanup is prefix-guarded in both suites. *Recommended follow-up (not required for this gate):* have `test-bootstrap-tools.sh` reuse `assert_root_owned_nonwritable_chain`, and emit an explicit `SKIP:` when the staging root is absent, matching the existing skip idiom at `tests/test-bootstrap-tools.sh:44-50`.

**P3-2 — Bundle-mutation tests conflate detection channels for the mode/digest/owner cases.**
`tests/test-receipt-authority.sh:312-315, 359-363`. Each mutation first runs `chmod u+w` over the staged directory spine, which is itself a mode mutation that `receipt_bundle_assert_stage` detects at `receipt-authority.sh:1389` when it reaches the `.` entry — before it ever reaches `fixture.py`. Since the harness asserts only `status != 0`, `bundle-mode-substitution`, `bundle-digest-substitution` and `bundle-owner-substitution` may be proving the sealing of the stage rather than the specific mutation they name. (The extra/omitted/traversal/symlink cases are cleanly attributed: the closure comparison at `1374` and the symlink check at `1361` run before the mode loop.)
**Disposition: accept.** Non-blocking — the property under test (any post-staging mutation is rejected) is genuinely proven, and the u+w step is unavoidable because the stage is sealed read-only. *Recommended follow-up:* assert the expected per-case diagnostic via the existing `expect_failure_diagnostic` idiom so the three conflated cases become self-describing.

**P3-3 — Symlink policy diverges between the two manifest builders, and the fixture that covered the tolerant branch was deleted in this candidate.**
`receipt-authority.sh:1184-1185` (sealed bundle: any symlink under the managed stdlib is a hard failure) versus `receipt-authority.sh:1552-1556` (`build_tree_manifest`, which walks the *same* `$python_stdlib_root` at `1626`, still records `L` entries and validates that they resolve inside the managed root). This candidate removed `ln -s fixture.py "$stdlib_root/fixture-link.py"` from the receipt fixture (diff at `tests/test-receipt-authority.sh:97`); I verified no symlink now exists under any runtime or stdlib fixture root in either suite, so the `L` branch at `1552-1556` — including its escape guard — is now entirely uncovered. Neither gate exercises a real `python-build-standalone` `install_only_stripped` tree (`config/ubuntu-toolchain.lock:24`); both fixtures use a one-file synthetic stdlib and a shell-script "interpreter". The bundle also hard-requires `lib/libpython3.13.so.1.0` (`1179`).
**Disposition: accept.** Non-blocking: the tightening is fail-closed (loud abort, no partial receipt, no security consequence), and I found no evidence that the real layout violates it — the staged venv reproduces the real `.local` `$ORIGIN/../lib` relationship exactly, so a launcher that works today works staged. *Recommended follow-up before production rollout:* one `receipt-authority.sh --check` against an actually-installed managed Python, and restoration of a stdlib-symlink fixture asserting the new `Python runtime closure rejects a symlink` diagnostic, so the policy change is documented rather than silently uncovered.

**P3-4 — No `umask` is set in the receipt authority; `mkdir`- and redirection-created staging objects briefly carry caller-controlled modes.**
`receipt-authority.sh:988, 1010, 1224, 1248, 1279` create directories and the transformed `pyvenv.cfg` before the explicit `chmod` on the following line. Unlike `mktemp -d` (always `0700`), these inherit the caller's umask.
**Disposition: accept.** Non-blocking and, in the real flow, not reachable: `scripts/ubuntu/trusted-launcher.sh:3` sets `umask 022` and umask is inherited across the `env -i` / `sudo` / `bash -c` chain into the payload. Every affected object also sits inside a root-owned, non-writable parent and is re-validated after the `chmod` (`994`, `1008`, `1016`). *Recommended follow-up:* add `umask 077` to the receipt authority prelude so the property is intrinsic rather than inherited.

**P3-5 — Production-scale cost of the sealed Python bundle is unmeasured.**
`receipt-authority.sh:1181-1193` copies the entire managed stdlib, and `receipt_assert_source_identity` (`1529-1532`) re-derives the source manifest **and** re-verifies the whole stage on each of its three invocation sites (`1589-1591`, `1726-1728`, plus the in-staging call at `1448-1449`) — with a separate `env`-wrapped `stat`/`sha256sum` process per file per pass. Fixtures contain a single stdlib file, so wall-clock at real scale (thousands of files) has no coverage.
**Disposition: accept.** Non-blocking — a correctness- and security-neutral performance characteristic. *Recommended follow-up:* time one production `--install` against the real runtime; if it is material, hoist the per-file `receipt_exec_system` wrappers to batched `sha256sum`/`stat` invocations.

## Out-of-Scope Observation (not a finding against this diff)

`receipt_test_pause` (`receipt-authority.sh:698-706`) remains compiled into the production authority and will truncate `$HERDR_RECEIPT_TEST_READY_FILE` if the caller controls the environment. I verified this is **pre-existing at base** (`710e2ca:scripts/ubuntu/receipt-authority.sh:687`), is not reachable through the production path (`env -i` on every launch seam), and is unchanged by this candidate. Recorded for completeness only; it does not bear on this gate.

## Limitations

- The candidate worktree is read-only and I executed nothing from it; all behavioural conclusions about runtime outcomes rest on code reading plus the two supplied gate logs.
- I did not inspect, read, or modify live installed state (`/opt/microsoft/powershell/7`, the managed `~/.local` Python runtime, `/etc/herdr-workstation`, `/var/lib/herdr-workstation`), per the brief. Consequently P3-3's real-layout question is stated as an unverified risk rather than resolved in either direction.
- `--check` mode against the production simulation is not exercised by the suite (only `--install`, which internally runs `validate_installed_authority`); the fixture-mode `--check` path is exercised extensively.
- The non-root `sudo` branch of `bootstrap_exec_privileged` is not covered by `assert_payload_delivery`, which pins `bootstrap_root_mode=1` and asserts `$1 == ''`.
- Builder narrative artifacts were excluded by instruction; the diff and tree are the sole basis for every claim above.

PASS FOR CROSS-REVIEW

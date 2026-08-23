# Independent cross-review return — Issue #8 pinned npm correction

- Reviewer pane: `w1:p10` (canonical name at review time: `Hdr-T-C1`; see Coordination note)
- Reviewer route: Anthropic / `claude-opus-5` / high / `normal` tier; fast mode disabled, not requested
- Review worktree: `/tmp/herdr-bootstrap-issue-8-review-f3fcbb8`
- Exact candidate reviewed: `f3fcbb863a65d13256ca459ff308e2eba16088c4` (verified `git rev-parse HEAD`)
- Correction base: `7260b6481ecaf0e8d71840a2fab4947806503fdf`
- Delta reviewed: `7260b648..f3fcbb8` — `scripts/ubuntu/bootstrap.sh` (3 lines), `tests/test-bootstrap-tools.sh` (+46/-2)
- Boundary honored: read-only. No repository writes, commits, dispatches, pane control, sudo, installs, pushes, merges, or GitHub mutation. Writes confined to this artifact and disposable `/tmp` diagnostics.

## Summary

The npm correction itself is **correct, minimal, and well covered**. Rubric items 1-7 all pass on their own terms, and the builder's evidence reproduces exactly.

However, the correction is **incomplete against the defect class it addresses**. The identical ambient-`node` shebang dependency remains on `$node_anchor/bin/codex`, which the tools transaction executes at `scripts/ubuntu/bootstrap.sh:2165` — sixteen lines after the fixed npm call, inside the same hermetic-PATH region. The live transaction will still exit 127; the correction moves the failure from line 2143 to line 2165. The fixture cannot detect this because it rewrites `codex` as a `#!/usr/bin/bash` script.

Because the orchestrator's stated next action is a root gate and installation retry, shipping this as-is would consume a privileged retry on a transaction that is still known-broken.

**Terminal disposition: BLOCK FOR CORRECTION** on P1-1. Keep the npm change as written; extend it.

## Findings

### P1-1 (BLOCKS) — `codex` retains the exact ambient-`node` dependency the correction removed for npm

**Evidence — file and line**

- `scripts/ubuntu/bootstrap.sh:2139` — `export PATH="$bootstrap_trusted_path"` (hermetic; `bootstrap_trusted_path='/usr/sbin:/usr/bin:/sbin:/bin'` at line 8 — no `$HOME/.local/bin`).
- `scripts/ubuntu/bootstrap.sh:2165` — `[[ "$("$node_anchor/bin/codex" --version | /usr/bin/gawk '{ print $NF }')" == "$CODEX_VERSION" ]]`
- `scripts/ubuntu/bootstrap.sh:2223` — `printf 'codex=%s\n' "$("$node_anchor/bin/codex" --version)"` (transaction snapshot)
- `scripts/ubuntu/bootstrap.sh:2325` — same, finalize snapshot

`npm install --global --prefix` publishes POSIX bin entries as symlinks to the package's entry file. On the locked Node tree, `bin/codex` resolves to `lib/node_modules/@openai/codex/bin/codex.js`, whose first line is `#!/usr/bin/env node`. Executing it under the hermetic PATH reproduces the original defect verbatim.

**Reproduction on the locked runtime** (`~/.local/lib/node-v24.19.0-linux-x64`, matching `NODE_VERSION=24.19.0`):

```text
$ readlink -f bin/codex
lib/node_modules/@openai/codex/bin/codex.js
$ head -1 lib/node_modules/@openai/codex/bin/codex.js
#!/usr/bin/env node

$ env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=$HOME bash -c \
    "exec {fd}<'$n'; '/proc/self/fd/'\$fd'/bin/codex' --version"
/usr/bin/env: 'node': No such file or directory
EXIT=127

# control, managed PATH
$ env -i PATH="$n/bin:/usr/bin:/bin" HOME=$HOME bash -c \
    "exec {fd}<'$n'; '/proc/self/fd/'\$fd'/bin/codex' --version"
codex-cli 0.149.0
EXIT=0
```

This is byte-for-byte the failure signature in the dispatch's `strace` capture, relocated to `codex`.

**Scope is precisely `codex`, not the other three.** Verified at the exact locked versions:

| executable | bin target | format | hermetic-PATH safe |
|---|---|---|---|
| `codex` | `@openai/codex/bin/codex.js` | `#!/usr/bin/env node` | **NO** |
| `claude` 2.1.235 | `@anthropic-ai/claude-code/bin/claude.exe` | ELF | yes |
| `bun` / `bunx` 1.3.14 | `bun/bin/bun.exe`, `bunx.exe` | ELF | yes |
| `herdr` | downloaded binary, `$bin_dir/herdr` | ELF | yes |

`claude` and `bun` are at the exact locked versions (2.1.235, 1.3.14). The host's `codex` is 0.149.0 against a locked 0.148.0; I could not verify 0.148.0's tarball directly without installing, which is outside the read-only boundary. The `bin: {"codex": "bin/codex.js"}` JS-wrapper shape is the package's stable form across this release line, so I assess the finding as applying to 0.148.0 — but that single point is inference, not direct observation, and is cheap for the builder to confirm.

**Suggested correction** (builder's call on form): apply the same treatment at lines 2165, 2223, 2325 — `"$node_anchor/bin/node" "$node_anchor/bin/codex" --version` — after confirming `bin/codex` resolves to a JS entry at the locked version. Extending it to `claude`/`bun` would be wrong: they are ELF binaries and Node cannot execute them.

### P2-1 (BLOCKS) — regression coverage is npm-shaped and cannot detect this defect class

`tests/test-bootstrap-tools.sh:276-286` gives `npm` a realistic `#!/usr/bin/env node` shim, but leaves `codex`, `claude`, `bun`, `bunx`, `npx`, and `corepack` as `make_version_tool` fixtures — `#!/usr/bin/bash` scripts (lines 147-159). Every npm-published executable therefore executes successfully in the fixture regardless of whether production resolves `node` ambiently. The new coverage proves exactly one call site and is structurally blind to the other three.

The dispatch asked for coverage proving "npm execution does not depend on ambient `node` resolution," and the builder delivered precisely that — so this is a scope gap in the dispatch as much as in the build. It nonetheless blocks, because it is the reason P1-1 shipped undetected through a green suite.

**Suggested correction:** give `codex` a `#!/usr/bin/env node` fixture body and route it through the fixture `node` dispatcher with its own marker line, mirroring the npm pattern at lines 240-280.

## P3 findings — all explicitly disposed

- **P3-1 — `npx` and `corepack` carry the same shebang, latent.** `bin/npx` → `npm/bin/npx-cli.js` and `bin/corepack` → `corepack/dist/corepack.js`, both `#!/usr/bin/env node`. **Disposed: no action.** `bootstrap.sh:2131-2135` only resolves and symlinks them; neither is ever executed under the hermetic PATH. Latent, not live. Would become live only if a future probe executes them.
- **P3-2 — the fix depends on `bin/npm` being a JS file, unasserted.** `node <script>` requires `$node_anchor/bin/npm` to resolve to `npm-cli.js`, not the POSIX `sh` wrapper at `lib/node_modules/npm/bin/npm`. Verified on the locked Node 24.19.0 tarball. Nothing in `bootstrap.sh` asserts it. **Disposed: acceptable.** A layout change fails loudly at line 2143 with a Node parse error, not silently — fail-closed, consistent with the file's posture.
- **P3-3 — fixture marker write modes are order-dependent.** `tests/test-bootstrap-tools.sh:257` truncates (`>`) on `install`; line 260 appends (`>>`) on `--version`. The assertions at lines 349-350 pass only because they run after the first `run_tools` and before the negative reruns at line 357 onward. **Disposed: correct as written.** The ordering is load-bearing but undocumented; a comment would help future edits. Not a defect.
- **P3-4 — fixture `node` rejects any future Node flag.** The `--version` branch matches `$1` first; a call like `node --no-warnings <script>` would fall to `*)` and exit 24. **Disposed: intentional.** Strictness is the point of the fixture and it fails closed.
- **P3-5 — no assertion on install/probe call counts.** `grep -Fqx` confirms presence, not multiplicity; a duplicated install would still pass. **Disposed: out of scope** for this correction and not a regression risk.

## Rubric dispositions

| # | Item | Verdict | Basis |
|---|---|---|---|
| 1 | npm install via pinned Node + pinned npm script, correct argv | **PASS** | `bootstrap.sh:2143`. Node takes argv[1] as the script and strips the shebang; `install --global --save-exact --prefix` reach npm as `process.argv[2..]`. `bin/npm` → `npm-cli.js` confirmed JS. |
| 2 | Both npm version probes pinned, no ambient PATH resolution | **PASS** | `bootstrap.sh:2222` and `:2324` both updated. Grep confirms these are the only two npm probe sites in the file. Neither involves a PATH lookup. |
| 3 | No user-writable PATH entry; no weakened fence/ownership/hash/descriptor/identity check | **PASS** | Delta touches exactly 3 lines, all npm invocation. Line 2139 and the line-8 constant are unchanged; `fence_*`, `path_is_under`, `realpath -e`, and `validate_managed_paths` are untouched. |
| 4 | fd-anchored `$node_anchor` still valid for Node and npm script execution | **PASS** | bash `exec {fd}<` descriptors are inherited across `execve` — verified directly on bash 5.2.21, so `/proc/self/fd/N` resolves inside the Node process for both argv[1] and `--prefix`. The fixture's `realpath -e -- "$1"` equality gate (`tests:250-254`) proves it post-exec. |
| 5 | Coverage fails under old behavior, passes only with pinned Node; no inert assertions | **PASS** | Reverted `bootstrap.sh` to `7260b648` keeping the new tests: exit 1, `/usr/bin/env: 'node': No such file or directory`. At the candidate: exit 0. Assertions fail closed on a missing marker. Genuine guard, not a false positive — see P2-1 for what it does *not* cover. |
| 6 | Transaction/finalize parity; no adjacent regression introduced | **PASS, with P1-1 noted** | The two snapshot blocks are byte-identical across the printf region (only a blank line and `close_fence_fd "$state_fd"` differ in surrounding context). No regression is *introduced*; P1-1 is an adjacent defect *left unfixed* that this correction now promotes to the next failure point. |
| 7 | Builder evidence credible | **PASS** | Independently re-run at the candidate SHA, all exit 0 (below). |

## Independent verification re-run at `f3fcbb8`

| command | exit |
|---|---|
| `bash tests/test-bootstrap-tools.sh` | 0 |
| `bash tests/test-bootstrap-profile.sh` | 0 |
| `bash tests/test-python-toolchain.sh` | 0 |
| `pwsh -NoProfile -File scripts/Validate-Repository.ps1` | 0 |
| `git diff --check` | 0 |

Negative control, `bootstrap.sh` reverted to `7260b648` with the candidate's tests, in a disposable `/tmp` copy:

| command | exit | signature |
|---|---|---|
| `bash tests/test-bootstrap-tools.sh` | 1 | `/usr/bin/env: 'node': No such file or directory` |

`Validate-Repository.ps1` reported the expected non-root skips (root-gated launcher privilege-drop, Windows ACL/path/COM fixtures) and passed.

## Coordination note — not a code finding

The bootstrap instruction issued to this pane specified `-RepoCode 'HDR'`, so the coordinator applied canonical name `Hdr-T-C1` and renamed tab `w1:t1H`. Work request `[WF:55fedd45]` was reserved earlier with `target_tab_label: "STM-T-C1"` and `bootstrap_naming_relay_ref: null`, so `herdr_workflow.ps1 -Action ack` refuses:

```text
ACK refused because the target label changed without an exact bootstrap
naming proof: workflow has no bootstrap-owned naming relay
```

Every prior session on this pane was named `STM-T-C1` (`RepoCode 'STM'`). The `HDR` code in the bootstrap message appears to be the origin. Resolution is the orchestrator's: either reissue the work request against the current label, or re-request the name under `STM`. I did not send a corrective naming relay, as the brief forbids originating downstream or pane-control actions. This review was performed and returned regardless; the ACK is a receipt, not a precondition for the read-only work.

Separately, the first `report-profile` bootstrap call failed with all profile fields empty on readback and succeeded unmodified on retry — a transient write/readback race, not a route problem. The route itself is as specified: Anthropic / `claude-opus-5` / high / normal, fast mode disabled.

BLOCK FOR CORRECTION

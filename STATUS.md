# Issue #8 operational checkpoint

## Objective and phase

Close `nathanestone-alt/herdr-workstation-bootstrap#8` (installed receipt authority with attested RTK role). **The verifier code fix is complete and independently verified.** The remaining work is the privileged live deployment, which is **blocked pending human oversight** (see below).

## Deploy commit

- **Deploy target: `b825e3661cc6aececdeb7a794170afa93f0a6b2c`** (branch `codex/issue-8-receipt-authority`, pushed to origin).
- Behavior-identical predecessor `7ac24a690355a6665d40c8d5830267f1719472e6` is the SHA the final independent gate verified; `b825e36` differs only by a consolidated comment (proven: the only-comment diff, gawk program byte-identical).
- Fast-forwards cleanly onto `origin/main`.

## What was fixed and verified this session (2026-08-24)

Three independent adversarial-review rounds each surfaced a **real, exploitable** divergence between `read_receipt_pyvenv_value` (scripts/ubuntu/verify.sh) and the actual consumer, CPython `site.py`. All three are fixed:

1. **Case-fold + non-ASCII (P2).** Parser matched keys case-sensitively and byte-for-byte; CPython folds `key.strip().lower()` and resolves duplicates last-wins. `Include-System-Site-Packages = true` after `... = false` (or an NBSP/control byte in the key) let the verifier attest isolation while the runtime enabled system-site-packages. Fixed: reject non-ASCII/non-tab bytes, `tolower()` key match, reject duplicate normalized keys.
2. **Print-on-exit trusted stdout (P2).** The caller reads the parser's stdout through `|| true`, discarding the exit code. An in-rule `exit 2` still ran gawk's `END`, which reprinted the last valid value — so a rejected file's stale value was trusted. Fixed: defer rejection to `END` via a `bad` flag so a rejecting path prints nothing.
3. **Embedded carriage return (P2).** A lone CR is a line separator to CPython's universal-newline `for line in f` but not to a newline-only reader; `decoy = 1\rinclude-system-site-packages = true` smuggled a directive past the parser. Fixed structurally: `RS="\r\n|\r|\n"` splits records exactly as CPython does, so the smuggled directive becomes its own record and trips duplicate rejection.

Verification: fixture suite `tests/test-verify-path.sh` PASS with new regressions (case-variant/upper/home, NBSP, control-char, embedded-CR site+home); local parity battery + an 8k-case fuzz and an independent 18k-case fuzz against a faithful `for line in f` site.py oracle found **zero attested-but-divergent inputs** (negative control: prior parser showed 168 bypasses). Final independent gate: 3/3 review lenses CLEAR, 0 confirmed blocking, 6/6 neutral suites PASS, mutation discriminates (the embedded-CR test fails against the prior parser for the right reason). The real production `~/.local/pyvenv.cfg` (3 ASCII LF lines) still verifies correctly.

Tickets #9 (P2 pyvenv parsing) and #10 (P3 coverage) are resolved by this code and referenced `Closes #9 / Closes #10` in commit `b66b124`.

## BLOCKED: privileged live deployment

The remaining steps require privileged trust-anchor mutation and were **blocked by the Claude Code auto-mode classifier** (human-in-the-loop guardrail); not worked around. The overnight NOPASSWD sudoers drop-in was **removed** (`/etc/sudoers.d/issue8-overnight` deleted; passwordless sudo revoked). Remaining steps, in order, each gated:

1. Re-pin launcher to `b825e36`:
   `sudo /tmp/herdr-install-trusted-launcher.sh --origin https://github.com/nathanestone-alt/herdr-workstation-bootstrap.git --commit b825e3661cc6aececdeb7a794170afa93f0a6b2c --run-as-user nathan --re-pin`
   (installer sha256 `08052064…` == repo installer at deploy commit; verified. Confirm policy `commit=` == deploy SHA, launcher root:root 0755.)
2. `sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint bootstrap --phase tools`
   Re-establishes a **consistent** authority+manifest in one transaction (see desync note). Gate on rc==0 + "Tool installation complete".
3. `sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint verify`
   Gate on rc==0 + "Ubuntu bootstrap verification passed." + no FAIL lines.
4. Fast-forward merge to `main` (`git push origin b825e36:main`), then close #8/#9/#10 with the verify evidence.

Full runbook: `/tmp/claude-1000/.../scratchpad/DEPLOY-RUNBOOK.md`.

## Live-environment finding (must be handled by step 2)

The live `/etc/stmodel/issue-961/receipt-authority.json` (mtime 01:42, digest `01ac3f70…`, **carries the attested rtk role**) is newer than the toolchain manifest (mtime 01:21, records `receipt_authority_sha256=a06c3b89…`). The authority embeds a timestamp in `receipt_id`, so it is non-deterministic; a standalone `receipt-authority --install` after the manifest was finalized desynced them. `verify` compares the manifest's recorded authority digest to the live file, so it fails on that one field until the manifest is regenerated **after** the final authority install. Running `--phase tools` (step 2) does both in one transaction and resolves it. Python digest matches; uv is healthy (earlier "uv missing" was transient, pre-symlink).

Provisioning code (`bootstrap.sh`, `receipt-authority.sh`, `trusted-launcher.sh`, `install-trusted-launcher.sh`, `launcher-capability.sh`) is **byte-identical** `daf84bf..b825e36`, so re-pin + tools behave exactly as the proven prior run; only `verify.sh` changed.

## Stop conditions

Stop on any nonzero rc at deploy steps 1–3, any FAIL in verify, policy `commit` != deploy SHA, launcher not root:root 0755, dirty-tree ambiguity, or protocol mismatch. Do not merge or close #8 until live verify passes. Never self-approve past a failing gate.

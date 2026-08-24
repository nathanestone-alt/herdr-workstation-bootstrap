# Issue #8 operational checkpoint — COMPLETE

`nathanestone-alt/herdr-workstation-bootstrap#8` (installed receipt authority with attested RTK role) is **implemented, independently verified, deployed live, and verified green.**

## Deployed commit

- **`115515e459f877e629be48fd8317054d5a1e8278`** on `codex/issue-8-receipt-authority`, merged to `main`.
- Launcher policy pinned to this commit; launcher `root:root 0755`.
- Live `verify`: **PASS** (99 PASS, 0 FAIL — `/tmp/issue-8-deploy-verify-final.log`).
- Receipt authority `/etc/stmodel/issue-961/receipt-authority.json` published with the attested `rtk_release` (v0.45.0); authority and toolchain manifest consistent (both `459d97d3…`); authority `source_commit_sha` = deployed commit.

## What was fixed (all independently reviewed + fuzzed + live-verified)

The `pyvenv.cfg` receipt-evidence reader in `scripts/ubuntu/verify.sh` disagreed with the actual consumer, CPython `site.py`, in four ways — three security divergences and one resolver gap. All fixed:

1. **Case-fold / non-ASCII key smuggling** (was ticket #9's P2 + wider): match keys `tolower()`, reject non-ASCII/non-tab bytes, reject duplicate normalized keys.
2. **Print-on-reject trusted stdout**: the caller reads stdout through `|| true`; a rejecting path now prints nothing (deferred `bad` flag).
3. **Embedded carriage return**: `RS="\r\n|\r|\n"` splits records exactly as CPython's universal-newline `for line in f`, so a CR-smuggled directive becomes a duplicate and is rejected.
4. **uv resolution**: `verify_resolve_command` now allows uv's managed runtime dir `~/.local/lib/herdr-workstation/uv/<UV_VERSION>/<UV_PLATFORM>` (uv is a symlink there, like the Node tools). The verify fixture was corrected to model that symlink layout (it had used a plain file, masking the gap).

Verification across the arc: fixture suite + parity batteries + an 8k and an 18k differential fuzz against a real `site.py` oracle (zero attested-but-divergent inputs; negative controls bit); four independent multi-agent review rounds (final verdicts CLEAR); 6/6 neutral suites in fresh clones; mutation checks discriminating each regression. Tickets #9 and #10 resolved in code.

## Deploy record

Re-pin → `--phase tools` (reconciled the authority/manifest digest desync from a prior standalone authority install; provisioning code was byte-identical to the known-good run) → live `verify` PASS, done at commit `115515e`. The overnight NOPASSWD sudoers drop-in (`/etc/sudoers.d/issue8-overnight`) was removed at the end.

## Follow-ups

None outstanding for #8. #9/#10 closed. Herdr coordination items (#25/#26/#28) tracked separately as before.

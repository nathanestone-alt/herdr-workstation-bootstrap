# Agent practices (herdr-workstation-bootstrap)

Canonical source of truth for how agents (Claude or Codex) work in this repo.
`CLAUDE.md` and `AGENTS.md` are thin pointers here — edit this file, not those.
Learned from issue #8, which took four days for ~50 lines of code.

## Definition of done is executable

A bootstrap/verifier change is done when the live launcher verify exits 0:

```
sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint verify   # rc=0, 0 FAIL lines
```

Pin that as the target from the start; run it (or the relevant fixture suite) early
even when it fails — its FAIL lines are the real to-do list and surface hidden
acceptance gates before they cost days at deploy time. If a review finding blocks
that check, fix it in this arc; ticket only genuine enhancements — never the blocker.

## verify.sh must be proven against the real consumer, not memory

`scripts/ubuntu/verify.sh` attests that producer-written evidence matches what the real
consumer does. Do NOT reason about the consumer from memory — run it. For any change to
`read_receipt_pyvenv_value` or similar, first write a **differential test** that runs the
managed interpreter's real logic and the parser over thousands of generated inputs and
diffs them; watch it fail before fixing. Safety invariant: whenever the verifier attests a
value, the real consumer must resolve that key identically. Prefer a structural fix that
kills a whole divergence class over patching bytes one at a time. Full method + harness
template: the `verify-parity` skill.

CPython `site.py` pyvenv.cfg semantics (the oracle): default text-mode `for line in f`
(universal newlines: `\r\n`, `\r`, `\n`), `line.partition('=')`, `key.strip().lower()`,
`value.strip()`, duplicates resolved last-wins.

## Fixtures must model production layout

`tests/test-verify-path.sh` fixtures must match how bootstrap actually installs things or
they go green while the host fails (this hid the uv bug for the whole arc). Managed tools
are published as **symlinks** into versioned lib dirs (`uv` →
`~/.local/lib/herdr-workstation/uv/<ver>/<plat>/uv`; node tools → the node lib root), NOT
plain files in `~/.local/bin`. `verify_resolve_command`'s allow-set and the fixtures must
both reflect that.

## Deployment needs root — arrange it up front

The finish line (re-pin the trusted launcher, run `--phase tools`, run `verify`) needs sudo
and follows `docs/bootstrap-trust-anchor.md`. Establish durable privileged access at the
START of a deploy task, not after the code is ready. Re-pin only to a commit pushed to
origin whose installer bytes you verified; `--phase tools` reconciles the authority/manifest
digest (the authority embeds a timestamp, so the manifest must be finalized after the
authority install).

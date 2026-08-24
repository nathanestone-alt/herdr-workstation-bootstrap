# herdr-workstation-bootstrap — working notes

Engineering practices that this repo learned the hard way (issue #8 took four days;
the code that closed it was ~50 lines). Keep them.

## Definition of "done" is executable

A change to the Ubuntu bootstrap/verifier is done when the **live launcher verify
exits 0**:

```
sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint verify   # expect rc=0, 0 FAIL lines
```

Pin that as the target from the start. Corollary: run it (or the relevant fixture
suite) early even when it will fail — its FAIL lines are the real to-do list and
surface hidden acceptance gates (schema mismatches, resolver gaps) before they cost
days at deploy time.

## `scripts/ubuntu/verify.sh` must agree with the real consumer, tested by oracle

`verify.sh` attests what a producer wrote (e.g. `pyvenv.cfg`) matches what the actual
consumer does. Do NOT reason about the consumer from memory — run it. For any change to
`read_receipt_pyvenv_value` or similar, first write a **differential test** that runs the
managed interpreter's real logic (CPython `site.py`: default text-mode `for line in f`
universal newlines, `line.partition('=')`, `key.strip().lower()`, `value.strip()`,
last-wins) and the gawk parser over thousands of generated inputs, and diff. Watch it
fail before fixing. The safety invariant: whenever the verifier attests a value, the real
consumer must resolve that key identically. Prefer a structural fix that kills a whole
divergence class over patching bytes one at a time.

## Fixtures must model production layout

`tests/test-verify-path.sh` fixtures must match how bootstrap actually installs things, or
they go green while the host fails. Known trap: managed tools are published as **symlinks**
into versioned lib dirs (`uv` -> `~/.local/lib/herdr-workstation/uv/<ver>/<plat>/uv`; node
tools -> the node lib root), NOT plain files in `~/.local/bin`. `verify_resolve_command`'s
allow-set and the fixtures must both reflect that.

## Deployment needs root — arrange it up front

The finish line (re-pin the trusted launcher, run the tools phase, run verify) requires
sudo and follows the out-of-band procedure in `docs/bootstrap-trust-anchor.md`. Establish
durable privileged access at the START of a deploy task, not after the code is ready —
expiring sudo/keepalives and unattended-privilege blocks were a recurring time sink.
Re-pin only to a commit that is pushed to origin and whose installer bytes you verified;
the tools phase reconciles the authority/manifest digest (the authority embeds a timestamp,
so the manifest must be finalized after the authority install).

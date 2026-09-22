---
name: verify-parity
description: Prove a producer/consumer verifier (herdr-workstation-bootstrap scripts/ubuntu/verify.sh, especially read_receipt_pyvenv_value) agrees with the REAL consumer by differential testing against the live program, not memory. Use before changing any parser/allow-set in verify.sh, when a fixture passes but the live host fails, or when asked to make verify exit 0. Also covers the re-pin through tools and verify deployment sequence.
---

# Verify-parity: differential testing for verify.sh

Rule: when code must match another program's behavior, the FIRST artifact is a test
that runs the real program over many inputs and diffs it against ours — watch it fail
before fixing. Do not reason about the consumer from memory.

## The oracle (pyvenv.cfg consumer = CPython site.py)

CPython reads pyvenv.cfg as: default text-mode `for line in f` (universal newlines
`\r\n`,`\r`,`\n`), `key,_,value = line.partition('=')`, `key = key.strip().lower()`,
`value = value.strip()`, duplicates last-wins. Confirm on the box:
`grep -n "partition('=')" $(/home/nathan/.local/bin/python3.13 -c 'import site;print(site.__file__)')`

## Method (red -> green -> refactor)

1. Extract the exact parser under test from verify.sh (don't paraphrase it).
2. Build a Python oracle mirroring the consumer's real logic (above), reading the file
   the same way the consumer does (file iteration, NOT str.splitlines()).
3. Fuzz thousands of files combining a legit case with adversarial extras: case-variant
   keys, NBSP/control bytes, embedded `\r`/`\r\n`/`\n`, decoy-key prefixes, split keys,
   trailing/no-trailing newline, value-side whitespace, duplicates.
4. Model the REAL caller: it captures stdout through `|| true` and IGNORES the exit code,
   so a rejecting path must print NOTHING. Check the end-to-end security invariant, not
   raw equality: whenever the verifier's contract attests (home==runtime_root AND
   include-system-site-packages=="false" AND version==PYTHON_VERSION), CPython must resolve
   those keys identically. Zero attested-but-divergent inputs = pass.
5. Negative control: run the fuzz against the pre-fix parser and confirm it finds bypasses,
   proving the harness bites.
6. Prefer a structural fix (e.g. gawk `RS="\r\n|\r|\n"` to split lines exactly like CPython)
   over patching one byte at a time.

## Fixture fidelity

`tests/test-verify-path.sh` must install managed tools the way production does — symlinks
into versioned lib dirs (`uv` -> `~/.local/lib/herdr-workstation/uv/<ver>/<plat>/uv`; node
tools -> node lib root), NOT plain files in `~/.local/bin`. A fixture that cheats the layout
hides real bugs (it hid the uv resolver gap for the whole issue-8 arc). Add a mutation check:
revert only the fix in a scratch copy and confirm the fixture now fails.

## Done + deploy

Done = live `verify` exits 0. Deploy (needs root, arranged up front):
1. Gate: installer sha at the deploy commit == /tmp installer; provisioning files unchanged
   vs the known-good pin; commit fetchable from origin.
2. `sudo /tmp/herdr-install-trusted-launcher.sh --origin <url> --commit <sha> --run-as-user nathan --re-pin` (confirm policy commit + launcher root:root 0755).
3. `sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint bootstrap --phase tools` (reconciles authority/manifest; the authority embeds a timestamp so the manifest must be finalized after it).
4. `sudo /usr/local/libexec/herdr-workstation-bootstrap --entrypoint verify` -> rc=0, 0 FAIL.
Stop on any nonzero rc / any FAIL / policy-commit mismatch. Never merge or close on a failing verify.

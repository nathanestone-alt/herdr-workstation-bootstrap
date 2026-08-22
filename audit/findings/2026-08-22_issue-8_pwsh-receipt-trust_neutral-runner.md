# Issue #8 — PowerShell and receipt trust neutral runner

- Candidate: `3b65a2a8b3d99d09d0d570cb25d5b842ce9285d0`
- Immediate parent: `bfec382971dbe98351d28d184843410dc1c82879`
- Arc base: `b694eae65cbbecabd10ad3fb42101968868df572`
- Corrected workflow: `[WF:fcb928b3]`
- Route: OpenAI / `gpt-5.6-luna` / max / priority
- Capability profile: `tooling-core`
- Final artifact: `/tmp/herdr-bootstrap-neutral-3b65a2a-r2.md`
- Final artifact SHA-256: `0ab446285a0c5ce8b11ffd310fe234fef3ad8eadb45de4dc46da60f52f8c84e8`

## Result

**PASS FOR NEUTRAL RUNNER.** Every available required check passed under the host-semantic Context
Mode boundary. The candidate remained exact, detached, clean, and unchanged.

## Environment correction

The first neutral artifact, `/tmp/herdr-bootstrap-neutral-3b65a2a.md` (SHA-256
`3745b21aa9548645633f752f527e6db41b21b174fefa1c2eeb47ae7783a050dd`), correctly recorded BLOCK
for what its Codex shell observed: `/usr/bin/uname` appeared non-root-owned and the trust check
failed closed. That shell runs in a filesystem sandbox that maps host system-file ownership to uid
`65534`; it was not a valid authority for host ownership predicates.

The single corrected rerun used Context Mode for every command. It proved `/usr/bin/uname` as
`uid=0 mode=755 type=regular file`, and the same exact candidate then passed bootstrap fencing.
The prior artifact remains durable execution evidence but is superseded as the candidate verdict by
this host-semantic run.

## Checks

- Repository origin, detached HEAD, candidate, parent, and initial clean-tree proofs passed.
- `git diff --check b694eae65cbbecabd10ad3fb42101968868df572..3b65a2a8b3d99d09d0d570cb25d5b842ce9285d0`
  exited 0.
- All 25 tracked shell files passed `bash -n`; cardinality 25/25 with zero failures.
- Host `/usr/bin/uname` ownership proof passed: uid 0, mode `0755`, regular file.
- `bash tests/test-bootstrap-fencing.sh` exited 0.
- `bash tests/test-receipt-authority.sh` exited 0.
- `pwsh -NoProfile -File scripts/Validate-Repository.ps1` ran exactly once as a standalone Context
  Mode process with no caller-imposed timeout, exited 0, and returned terminal PASS.
- Final HEAD remained exact and `git status --short` remained empty.

## Deferred coverage

- Root-only PowerShell ownership and writable-parent regressions.
- Root-only production payload-stage ownership and payload-authenticity cases.
- Root-gated launcher privilege-drop cases.
- Windows ACL, path-policy, handle, process-identity, and Excel COM fixtures.
- Python syntax validation because Python was unavailable in the host-semantic runner.

These are explicit deferrals, not PASS claims. Root-only Linux cases are required during
commissioning before installation is called complete.

No repository edit, commit, push, merge, install, sudo, issue mutation, or downstream dispatch
occurred in the neutral-runner context.

Terminal verdict: **PASS FOR NEUTRAL RUNNER**

# Issue #20 — RTK v0.49.0 cross-review and neutral-runner verdict

Candidate: `dd8cc9fa9c4d846e265e9b29ff0c41fabdf76cb9`  
Base: `cbc43993769cb32a2aa2aef79f8a6ab7dece9c08` (`origin/main`)  
Scope: governed RTK release pin, release fixture/current-surface documentation, and one pre-existing EOF-only validation correction.

## Builder evidence

- Official upstream stable release: `v0.49.0`, published 2026-09-11.
- Asset: `rtk-x86_64-unknown-linux-musl.tar.gz`.
- Directly verified archive SHA-256: `7278231dfd7e6a730a4ab7f847b195bcf02289c2d57622b0dab75a6411100c8f`.
- Archive shape: one regular executable named `rtk`, mode 0755; extracted binary reported `rtk 0.49.0`.
- `bash tests/test-rtk-release.sh`: PASS.
- `bash tests/test-bootstrap-tools.sh`: PASS (expected non-root trusted-launcher handoff skip).
- `pwsh -NoProfile -File scripts/Validate-Repository.ps1`: PASS after removing an extra EOF blank line from the historical issue-8 verdict; no verdict text changed.
- `git diff --check`: PASS.
- Live launcher verify was not runnable: `sudo -n` requires a password, and unprivileged execution correctly refused because the trust anchor must run as its installed owner.

## Independent cross-review

Ledger node `20-rtk-049-review-r2` reviewed the exact detached candidate through the policy-selected OpenAI `gpt-5.6-luna`, max reasoning, priority route. Node r1 was a pre-inference transport ERROR because the governed Python frontend removed the Codex CLI from PATH and is not candidate evidence.

Cross-review r2 returned:

- P1: 0
- P2: 0
- P3: 0
- RTK release fixtures: PASS
- Bootstrap tools fixtures: PASS
- `git diff --check`: PASS
- Exact candidate/worktree identity: PASS
- Terminal verdict: `PASS FOR CROSS-REVIEW`

## Deterministic neutral runner

All neutral nodes used the exact candidate and policy-selected OpenAI `gpt-5.6-sol`, medium reasoning, priority route.

- `20-rtk-049-neutral-r1`: ERROR because the read-only sandbox made `/tmp` unwritable.
- `20-rtk-049-neutral-r2`: six of seven predicates passed; ERROR because Context Mode terminated the long repository validator at its 300-second RPC cap.
- `20-rtk-049-neutral-r3`: reused worktree was pre-contaminated by `.node-return.md`; BLOCK on clean-state predicates and a fencing-suite failure. The fencing suite passed immediately afterward on the host and no validator process remained.
- `20-rtk-049-neutral-r4`: fresh exact-SHA worktree; initial/final status clean; RTK release fixtures PASS; bootstrap tools fixtures PASS; lock assertions PASS; `git diff --check` PASS. The full repository validator again returned exit 1 only at `tests/test-bootstrap-fencing.sh` inside the Codex workspace-write sandbox.

The repeated sandbox-only validator failure prevents a neutral PASS. Builder verification and cross-review PASS do not substitute for the required deterministic neutral verdict.

## Verdict

**BLOCK FOR MERGE/PUSH/DEPLOYMENT.**

Unblock conditions:

1. Run the deterministic neutral matrix in an independent context that can execute the full repository validator without the Codex sandbox incompatibility, obtaining PASS at this exact substantive candidate SHA; and
2. establish durable privileged access for the trusted-launcher deployment and required live `--entrypoint verify` check (exit 0, zero FAIL lines).

This evidence-only verdict record does not create a new substantive review candidate.

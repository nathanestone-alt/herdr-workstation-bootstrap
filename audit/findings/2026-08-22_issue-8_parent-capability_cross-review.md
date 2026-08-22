# Issue 8 cross-UID parent-capability cross-review

## Verdict

`PASS FOR CROSS-REVIEW`

- Candidate: `50970caa066c366aa245d2d4eddb91034afdc6d0`
- Parent: `9de6ef0a495c754969ce51b17a137acade894d69`
- Repository: `nathanestone-alt/herdr-workstation-bootstrap`
- Detached review worktree: `/tmp/herdr-bootstrap-issue-8-review-50970ca`
- Route: Anthropic / `claude-opus-5` / high / normal non-fast
- Fast-mode control: `CLAUDE_CODE_DISABLE_FAST_MODE=1`; no fallback model
- Review artifact: `/tmp/herdr-bootstrap-issue-8-cross-review-50970ca.md`
- Artifact SHA-256: `79459fa0402ed097ad3fb73c81d1715c7fa5582c8a7776e124a1dbd60b6effb2`

## Scope and checks

The reviewer independently inspected the exact five-file `+185/-8` candidate,
the complete capability helper, trusted launcher, bootstrap root transaction,
receipt and verify preludes, validator contracts, and touched tests. Syntax,
trusted-launcher, receipt-authority, bootstrap-fencing, the full repository
validator, and diff checks all passed in the clean detached worktree.

The review found no P1 or P2. It concluded that fd 12 is a genuine inherited
kernel-object capability that the dropped child can validate through its own fd
table without environment or argv authority, cross-process `/proc` inspection,
or path reopen. Producer-side descriptor re-pinning closes the open race; the
installed-launcher regular-file and root-receipt directory roles remain
distinct; same-UID ancestry is tightened by requiring the identical fd 12.

## P3 dispositions

1. The validator token contract does not yet require fd 12 or the new helper.
   Accepted for commissioning because end-to-end behavioural coverage fails if
   the capability is removed; follow up with static required tokens.
2. The consumer verifies owner, mode, type, size, and identity but does not
   itself require the fd 12 target to show `(deleted)` or read the `L` byte.
   Accepted as defence-in-depth because a non-root runtime cannot forge or open
   the required root-owned `0600` object.
3. fd 12 is not required to have a distinct device/inode from fds 9-11. A root
   receipt actor could alias fd 10, but that actor is already uid 0 and same-UID
   ancestry still requires the identical descriptor. Accepted as latent and
   non-exploitable; add distinctness as hardening.
4. Missing fd 12 has a focused negative control, but not a same-UID end-to-end
   launcher negative. Accepted because direct invocation, substitution, role
   confusion, and positive wiring are covered; add the end-to-end negative.
5. SIGKILL can leave a root-owned `0600` `.parent-capability.*` residue. Accepted
   as hygiene-only because the runtime cannot open or reuse it; add cleanup
   residue coverage.
6. The root-to-`nobody` fixture is structurally correct but was not executable
   at uid 1000. Accepted provisionally. Live root commissioning and root-gated
   launcher/receipt suites remain mandatory before issue closure.

The complete artifact contains exact file-and-line evidence and the disposition
of carried-forward P3s. None blocks commissioning.

## Mandatory live gate

Run the commissioned launcher base phase and both root-gated test suites under
root. This review does not certify the cross-UID path until that live gate
passes.

PASS FOR CROSS-REVIEW

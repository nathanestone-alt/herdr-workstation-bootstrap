# Issue 16 Python inspect-mode cross-review

## Verdict

`PASS FOR CROSS-REVIEW`

- Candidate: `8be9a87846a5da1666651527c3d428424c19f3c0`
- Parent: `2487b3e1345ffefad11456417036f31eb6d23819`
- Detached review worktree: `/tmp/herdr-bootstrap-issue16-review-8be9a87`
- Route: Anthropic / `claude-opus-5` / high / normal non-fast
- Fast-mode control: `CLAUDE_CODE_DISABLE_FAST_MODE=1`; no fallback model
- Artifact: `/tmp/herdr-bootstrap-issue16-cross-review-8be9a87.md`
- Artifact SHA-256: `02c63a47881b01a31ccecae5749bcff6f48e340c7a2a60e3e92a0706c8f8254d`

The reviewer found no P1 or P2. It independently reproduced that nonempty
`PYTHONINSPECT=0` enters inspect mode under a PTY, verified all three production
Python environments exit cleanly after its removal, ran the exact no-input PTY
regression, and proved the parent hangs while the candidate does not. Bash
syntax and the complete receipt-authority suite passed in both non-PTY and real
PTY contexts.

## P3 dispositions

1. The source guard targets the removed literal rather than every possible
   `PYTHONINSPECT` assignment. Accepted because it pins the realistic revert;
   broaden to any assignment as follow-up hardening.
2. The PTY probe duplicates the relevant environment rather than invoking the
   production helpers. Accepted because the divergent variables are irrelevant
   to inspect mode and all real helper environments were independently tested;
   prefer direct helper invocation later.
3. The five-second `timeout --foreground` lacks `--kill-after`. Accepted because
   util-linux `script` demonstrably terminates and reaps the PTY child; optional
   hardening is a bounded kill-after.
4. The test assumes `/usr/bin/script` and `/usr/bin/timeout`. Accepted as a
   fail-closed Ubuntu base dependency: absence exits 127 and fails the suite.

Root-gated receipt positives were skipped at uid 1000 and are not claimed.

PASS FOR CROSS-REVIEW

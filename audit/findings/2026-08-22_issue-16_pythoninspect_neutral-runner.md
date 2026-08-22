# Issue 16 Python inspect-mode neutral runner

## Verdict

`PASS FOR NEUTRAL RUNNER`

- Candidate: `8be9a87846a5da1666651527c3d428424c19f3c0`
- Parent: `2487b3e1345ffefad11456417036f31eb6d23819`
- Detached runner worktree: `/tmp/herdr-bootstrap-issue16-neutral-8be9a87`
- Route: OpenAI / `gpt-5.6-luna` / max / priority
- Artifact: `/tmp/herdr-bootstrap-issue16-neutral-8be9a87.md`
- Artifact SHA-256: `15a1eeb5b7a0f65bd040384c5ad8ae85c05d44fa6d79253aea767c9c94d127fc`

The independent non-PTY runner proved the exact candidate, parent, detached
state, clean tree, and three-file scope before and after testing. All required
checks passed:

1. Bash syntax for both production helpers and the receipt test.
2. Exact-parent `git diff --check`.
3. Source guards confirmed the removed literal is absent from both helpers.
4. The bounded real-PTY no-input regression exited 0 with no `>>>` prompt and
   no hang.
5. The full receipt-authority suite passed non-PTY in 45.368 seconds.
6. `pwsh -NoProfile -File scripts/Validate-Repository.ps1` exited 0 and ended
   with `Repository validation passed.`

Root-gated payload positives were skipped at uid 1000. Windows ACL, path,
handle, process-identity, and Excel COM fixtures were skipped on Linux. No
coverage is claimed for those environmental skips.

PASS FOR NEUTRAL RUNNER

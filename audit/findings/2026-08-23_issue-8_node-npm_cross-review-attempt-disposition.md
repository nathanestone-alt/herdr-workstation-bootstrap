# Issue #8 Node executable cross-review attempt — orchestrator disposition

- Candidate: `f3fcbb863a65d13256ca459ff308e2eba16088c4`
- Review workflow: `[WF:55fedd45]`
- Review artifact: `audit/findings/2026-08-23_issue-8_node-npm_cross-review-blocked-attempt.md`
- Artifact SHA-256: `72bdaa92ff2c5c0409290ab1d3e02b7587cf064db64e744bd11be624919992a4`

## Disposition

The review's P1 and P2 findings are accepted as blocking diagnostic evidence and returned to the builder:

1. `codex` remains a `#!/usr/bin/env node` JS entrypoint and is executed directly under the hermetic system-only PATH at the version probes and manifest snapshots, so the live tools transaction still exits 127 after the npm correction.
2. The focused fixture models `codex` as a Bash script and therefore cannot detect this ambient-Node dependency.

The review attempt is **not** accepted as a terminal independent cross-review. Its negative-control procedure copied a linked Git worktree and then ran `git checkout` inside the copy; because the copied `.git` link still referenced the original detached worktree metadata, the disposable review worktree became dirty (`MM scripts/ubuntu/bootstrap.sh`). That violates the read-only review boundary even though the substantive branch was not changed.

The Herdr workflow ACK also failed after an asynchronous label drift from `STM-T-C1` to `Hdr-T-C1`; this is operational transport evidence, not a code finding.

After the builder returns a new clean SHA, the orchestrator must create a fresh detached worktree and commission a new independent review. No PASS from this attempt may be reused.

`BLOCK FOR CORRECTION`

# Issue #8 operational checkpoint

## Objective and phase

Close `nathanestone-alt/herdr-workstation-bootstrap#8` (installed receipt authority with attested RTK role). Implementation is complete but the final verifier-schema candidate is **blocked at independent cross-review**.

## Lane and scope

- Write lane: tooling build/audit/document only.
- Worktree: `/home/nathan/code/herdr-workstation-bootstrap-worktrees/issue-8`
- Branch: `codex/issue-8-receipt-authority`
- No STModel workbook/model writes are authorized or present.
- Do not modify the dirty normal checkout at `/home/nathan/code/herdr-workstation-bootstrap`.

## Git state

- Substantive candidate: `56a3820c3a6909ccb6868fb345012932fd1542dd`
- Candidate parent/evidence baseline: `896a66e2ad7e4f69591d1470c9fb98e899861d9e`
- Candidate changes: `scripts/ubuntu/verify.sh`, `tests/test-verify-path.sh`.
- The only post-candidate changes at checkpoint are this `STATUS.md` and the blocked review finding; commit/push them as mechanical evidence only.

## Completed and verified

- Earlier Issue #8 implementation, correction reviews, and neutral validation are recorded under `audit/findings/` through evidence commit `896a66e`.
- Live trusted launcher was pinned to reviewed substantive SHA `daf84bfac353c01e510e1825709295ac90589561`.
- Live base phase: PASS.
- Live tools phase: PASS.
- Live receipt-authority install: PASS (`/tmp/issue-8-final-live-receipt.log`).
- Live verify exposed five producer/consumer schema mismatches and returned 1 (`/tmp/issue-8-final-live-verify.log`).
- Opus 5 high normal-tier builder produced candidate `56a3820`; `bash -n` and `tests/test-verify-path.sh` passed.
- Herdr downgrade incident was repaired: both sessions are independently verified at Herdr 0.8.2/protocol 20. Herdr follow-ups are in `nathanestone-alt/herdr-coordination#25`, `#26`, and lineage naming `#28`.
- A 24-hour B1 sudo keepalive was started as PID `2126299`; do not assume it remains valid after restart/time passage—probe safely before use.

## Blocking verdict and follow-ups

- Durable finding: `audit/findings/2026-08-24_issue-8_verify-schema_cross-review-blocked.md`.
- P2: ambiguous `pyvenv.cfg` parsing can ignore content after an additional `=`. Ticket: `nathanestone-alt/herdr-workstation-bootstrap#9`.
- P3: incomplete duplicate/missing-key regression coverage. Ticket: `nathanestone-alt/herdr-workstation-bootstrap#10`.
- User directive: ticket findings; do not continue fixing inline in this exhausted arc.
- Because P2 blocks, no neutral runner, live deployment of `56a3820`, merge to `main`, or Issue #8 close was performed.

## Pane/workflow state

- Orchestrator: `w1:p1` / `STM-T-O1`.
- Builder shell: `w1:p26` / `STM-T-B1` (existing name remains valid until retirement).
- Reviewer shell: `w1:p10` / `STM-T-C1`.
- New downstream naming after herdr-coordination #28 must include owner lineage, e.g. `STM-T-O1-B1`.

## Next safe action for Fable Ultracode

Start from this checkpoint and the exact candidate/finding. Decide explicitly whether Issue #8 is superseded by #9 or whether #9 should be resolved in a fresh correction arc. Do not merge `56a3820` while the P2 verdict stands. If a new substantive SHA is produced, commission fresh independent cross-review and a separate neutral runner, then repin/install and rerun live verify before any merge or close.

## Stop conditions

Stop on any P1/P2, dirty-tree ambiguity, candidate SHA mismatch, unavailable independent reviewer/runner, expired sudo authority, or Herdr protocol mismatch. Never self-approve or deploy around those conditions.

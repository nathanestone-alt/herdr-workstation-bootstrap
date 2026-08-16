# Independent cross-review — issue #923

Candidate: `21aa284f2a8eb4fcded9a7cae74f20f16f2d7818`
Parent: `86f4bce75f44281702f08e16d956651929aee16a`
Scope: `git diff 86f4bce75f44281702f08e16d956651929aee16a 21aa284f2a8eb4fcded9a7cae74f20f16f2d7818`

## Checks

- `pwsh -NoProfile -File scripts/test_st_herdr_dispatch.ps1` — PASS.
- `git diff --check 86f4bce75f44281702f08e16d956651929aee16a 21aa284f2a8eb4fcded9a7cae74f20f16f2d7818` — PASS.
- Candidate checkout was clean before and after the checks; no candidate files were modified.

## Findings

### P2 — Native routes are blocked by an unqualified Herdr completion gate

Evidence: `SKILL.md:8-14` says the skill applies automatically to dispatched nodes
and owns Herdr receipts only when Herdr is selected; `SKILL.md:40-51` places native
isolated and native subagent execution ahead of Herdr. However, the all-nodes
completion rule at `SKILL.md:85-87` requires “the tracked Herdr workflow” to record
completion and return-body acknowledgement, without a Herdr-selected qualifier.

For a valid native route there is no Herdr workflow/ACK-return lifecycle, so this
contract either makes native work unable to reach PASS or forces Herdr mechanics onto
the first two adapter choices. Qualify the Herdr receipt requirement to the case where
Herdr is the selected/requested adapter and state the adapter-neutral durable return
condition for native execution.

P1: none.

P3: none.

## Verdict

BLOCK FOR CORRECTION

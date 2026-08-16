---
name: st-herdr-dispatch
description: Automatically support provider-neutral dispatch for substantive workflow nodes that need a worker, handoff, independent review, gate, or durable completion return, while keeping graph policy with the active orchestrator. Validate explicit worker routing and execution-adapter selection for native, subagent, or Herdr execution. Activate Herdr pane/session/ACK/watchdog mechanics only when the user explicitly requests Herdr or the orchestrator selects Herdr for transport, observability, or recovery. Also trigger when the user names `$st-herdr-dispatch` or asks to inspect or control Herdr.
---

# Use Herdr as an execution adapter

Apply this skill automatically when an orchestrated workflow reaches a node that
needs dispatch, handoff, independent review, a gate, or a durable completion
return. The upstream orchestrator owns the DAG, scope, routing decision,
evidence invalidation, repository governance, and human gates. This skill
validates the resolved worker and adapter boundary. It owns Herdr transport,
identity proof, workflow receipts, monitoring, and recovery only when Herdr is
the selected adapter.

Explicit invocation: `$st-herdr-dispatch`.

## Preserve the resolved worker

Require every dispatched worker, reviewer, or scout to carry an explicit
`resolved_worker` record:

```yaml
resolved_worker:
  provider: <explicit provider>
  model: <explicit model>
  reasoning_effort: <explicit effort>
  service_tier: <explicit tier>
```

Reject a packet that omits any field. Never inherit the resident orchestrator's
model, effort, or tier for a worker. Never replace the manually selected
orchestrator or silently downgrade a worker. The orchestrator may be any model;
model identity is routing state, not graph structure.

Herdr transport must preserve the resolved worker exactly. If the selected
Herdr adapter cannot launch that configuration, return `ERROR/INCOMPLETE` so the
orchestrator can choose another allowed adapter or ask the user.

## Adapter selection boundary

The normal adapter order belongs to the upstream graph policy:

1. native isolated noninteractive execution;
2. compatible native subagent execution;
3. ephemeral background Herdr execution;
4. visible Herdr pane when observation, interaction, approval, or recovery helps.

Do not force Herdr when either native route satisfies isolation, tools, explicit
routing, budgets, and durable return requirements. Once Herdr is selected, do
not bypass its identity and receipt controls with raw prompts or guessed keys.

## Preconditions for actual Herdr calls

Check `HERDR_ENV=1` in the native host shell only when a Herdr helper will run.
Absence of `HERDR_ENV` is irrelevant to native execution and must not block the
normal graph workflow.

Before dispatch, prove the exact live workspace, tab, pane, stable label, agent
kind, native session, terminal identity, revision, and status. Re-resolve the
tuple immediately before transport. Never infer identity from focus, layout,
old transcripts, or stale relays.

Read [references/herdr-workflow.md](references/herdr-workflow.md) completely
before making a Herdr dispatch, handling a Herdr return, or recovering a Herdr
workflow. It contains the helper resolution, request lifecycle, naming, gate,
watchdog, and stop contracts.

## Compact dispatch contract

Require the orchestrator's packet to name:

- node/task identity and dependencies;
- exact candidate or artifact identity;
- objective, acceptance, frozen scope, and exclusions;
- exact worktree and write boundary;
- explicit `resolved_worker` provider/model/effort/tier;
- target and cap budgets plus stopping rule;
- prohibited actions;
- one durable return artifact and `PASS/BLOCK/ERROR` schema.

Do not forward full orchestrator or builder transcripts. A reviewer receives the
candidate diff, acceptance contract, and relevant evidence—not builder reasoning.

A node completes only after its named artifact is durable and the selected adapter
returns the complete result body to the orchestrator. When Herdr is the selected or
explicitly requested adapter, the tracked Herdr workflow must also record completion
and return-body acknowledgement. Process exit, prompt acceptance, ACK, elapsed time,
or a visible `PASS` string is not PASS.

## Authority and failure behavior

Repository governance controls merge, push, issue closure, Tier 2, destructive
actions, and other human gates. Do not duplicate or override those rules here.
A workflow result is evidence, never authorization.

Permit at most one transport retry, within the original invocation/time caps,
and only when work ownership, explicit routing, and independence remain intact.
A substantive `BLOCK` creates a targeted repair path; it is not a transport
retry. Missing identity, missing artifact, malformed return, expired budget, or
unavailable required configuration is `ERROR/INCOMPLETE`.

## Source and installed copies

Never edit installed copies directly. Change the clean sibling source repository,
commit and publish it, then synchronize both managed roots:

```powershell
pwsh -NoProfile -File scripts\sync_installed_skill.ps1 -Action install
pwsh -NoProfile -File scripts\sync_installed_skill.ps1 -Action check
```

Both installs must report the same source commit and `current: true` before a
Herdr dispatch relies on the revision.

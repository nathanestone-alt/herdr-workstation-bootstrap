# ADR Format

> **STModel note**: STModel's project-equivalent of an ADR is a Decision doc at `..\model\_handoff\from-audit\<topic>.md`, locked via chat-gate. These already encode ADR shape, so a separate `docs/adr/` is not needed. **Use this short-form template only if you need a lightweight ADR outside the Decision-doc convention** — e.g. for cross-bot architecture notes that don't belong inside a Phase A dispatch.

Canonical ADRs (when used) live in `docs/adr/` with sequential numbering: `0001-slug.md`, `0002-slug.md`, etc. Create the directory lazily — only when the first ADR is needed.

## Template

```md
# {Short title of the decision}

{1-3 sentences: what's the context, what did we decide, and why.}
```

That's it. An ADR can be a single paragraph. The value is in recording *that* a decision was made and *why* — not in filling out sections.

## Optional sections

Only include these when they add genuine value. Most ADRs won't need them.

- **Status** frontmatter (`proposed | accepted | deprecated | superseded by ADR-NNNN`) — useful when decisions are revisited
- **Considered Options** — only when the rejected alternatives are worth remembering
- **Consequences** — only when non-obvious downstream effects need to be called out

## Numbering

Scan `docs/adr/` for the highest existing number and increment by one.

## When to offer an ADR

All three of these must be true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will look at the code and wonder "why on earth did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If a decision is easy to reverse, skip it — you'll just reverse it. If it's not surprising, nobody will wonder why. If there was no real alternative, there's nothing to record beyond "we did the obvious thing."

### What qualifies

- **Architectural shape.** "We're using a monorepo." "The write model is event-sourced, the read model is projected into Postgres."
- **Integration patterns between contexts.** "Ordering and Billing communicate via domain events, not synchronous HTTP."
- **Technology choices that carry lock-in.** Database, message bus, auth provider, deployment target. Not every library — just the ones that would take a quarter to swap out.
- **Boundary and scope decisions.** "Customer data is owned by the Customer context; other contexts reference it by ID only." The explicit no-s are as valuable as the yes-s.
- **Deliberate deviations from the obvious path.** "We're using manual SQL instead of an ORM because X." Anything where a reasonable reader would assume the opposite. These stop the next engineer from "fixing" something that was deliberate.
- **Constraints not visible in the code.** "We can't use AWS because of compliance requirements." "Response times must be under 200ms because of the partner API contract."
- **Rejected alternatives when the rejection is non-obvious.** If you considered GraphQL and picked REST for subtle reasons, record it — otherwise someone will suggest GraphQL again in six months.

---

## STModel mapping

When the 3-criteria filter triggers during an STModel grill, the output path is:

- **Decision doc** at `..\model\_handoff\from-audit\<topic>.md` (preferred — the existing Phase A / Decision convention)
- **Cross-phase ADR** at `..\docs\AI\30_decisions\` (Scribe-owned; surface as Scribe ripple, do not write directly)

STModel decisions that historically would qualify under the 3-criteria filter:
- Snapshot-switch architecture (D-RR-30) — hard-to-reverse, surprising, real trade-off vs frozen-pod-clone
- xlsm canonical baseline (D-RR-31f) — hard-to-reverse, surprising (deprecates backup-replace), real trade-off vs regenerate-per-dispatch
- Single-chart-three-views (D-TAX-2) — hard-to-reverse, surprising vs separate trees, real trade-off
- Per-slot tax solver (D2.9) — hard-to-reverse, real trade-off vs 25-name 8-prefix legacy
- PFI tri-tab principle (PFI v14) — hard-to-reverse, surprising vs PFI=view, real trade-off
- Audit = quarterback (3-bot system 2026-05-08) — hard-to-reverse workflow lock-in

Decisions that would NOT qualify (resolution belongs in dispatch scope, not ADR):
- A name-spelling correction
- A row-count threshold
- A test-suite green/red criterion
- A scope narrowing within an in-flight dispatch

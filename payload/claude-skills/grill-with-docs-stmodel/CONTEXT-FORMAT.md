# CONTEXT.md Format

> **STModel note**: STModel's project-equivalent of `CONTEXT.md` is `..\docs\AI\GLOSSARY.md` (Scribe-owned, read-only for Audit). This file is kept as a reference template — useful if (a) STModel ever creates a project-local CONTEXT.md, (b) you adapt this skill for a different project that follows the canonical layout, or (c) Scribe wants to align GLOSSARY.md to this format. **The Audit lane does not write CONTEXT.md inline during a grill** — surface resolutions as Scribe ripples (see SKILL.md).

## Structure

```md
# {Context Name}

{One or two sentence description of what this context is and why it exists.}

## Language

**Order**:
{A one or two sentence description of the term}
_Avoid_: Purchase, transaction

**Invoice**:
A request for payment sent to a customer after delivery.
_Avoid_: Bill, payment request

**Customer**:
A person or organization that places orders.
_Avoid_: Client, buyer, account
```

## Rules

- **Be opinionated.** When multiple words exist for the same concept, pick the best one and list the others as aliases to avoid.
- **Flag conflicts explicitly.** If a term is used ambiguously, call it out in "Flagged ambiguities" with a clear resolution.
- **Keep definitions tight.** One or two sentences max. Define what it IS, not what it does.
- **Show relationships.** Use bold term names and express cardinality where obvious.
- **Only include terms specific to this project's context.** General programming concepts (timeouts, error types, utility patterns) don't belong even if the project uses them extensively. Before adding a term, ask: is this a concept unique to this context, or a general programming concept? Only the former belongs.
- **Group terms under subheadings** when natural clusters emerge. If all terms belong to a single cohesive area, a flat list is fine.
- **Write an example dialogue.** A conversation between a dev and a domain expert that demonstrates how the terms interact naturally and clarifies boundaries between related concepts.

## Single vs multi-context repos

**Single context (most repos):** One `CONTEXT.md` at the repo root.

**Multiple contexts:** A `CONTEXT-MAP.md` at the repo root lists the contexts, where they live, and how they relate to each other:

```md
# Context Map

## Contexts

- [Ordering](./src/ordering/CONTEXT.md) — receives and tracks customer orders
- [Billing](./src/billing/CONTEXT.md) — generates invoices and processes payments
- [Fulfillment](./src/fulfillment/CONTEXT.md) — manages warehouse picking and shipping

## Relationships

- **Ordering → Fulfillment**: Ordering emits `OrderPlaced` events; Fulfillment consumes them to start picking
- **Fulfillment → Billing**: Fulfillment emits `ShipmentDispatched` events; Billing consumes them to generate invoices
- **Ordering ↔ Billing**: Shared types for `CustomerId` and `Money`
```

The skill infers which structure applies:

- If `CONTEXT-MAP.md` exists, read it to find contexts
- If only a root `CONTEXT.md` exists, single context
- If neither exists, create a root `CONTEXT.md` lazily when the first term is resolved

When multiple contexts exist, infer which one the current topic relates to. If unclear, ask.

---

## STModel-specific contexts (mapping notes)

If we were to apply the multi-context model to STModel, the natural bounded contexts would be:

| Context | Glossary scope |
|---|---|
| **RR (Rent Roll)** | snapshots, T1/T2/T3 tiers, `idr_*` / `rd_b_*` aliases, snapshot-switch architecture |
| **UW (Underwriting)** | slot model, `mu_*` / `au_*` prefix families, P&L 4-block, cascade defaults |
| **PFI (v14 architecture)** | mu/au prefix family, per-slot tax solver, sidebar + freeze-pane layout |
| **Taxonomy** | prefix families, zero-padding, single-chart-three-views, account map |
| **Loan / Deal** | `loan_*` per-loan, `deal_*` workbook-deal, loan-sizing publish surface |
| **Build infra** | dispatch loop, 3-bot lanes, worktrees, rollback tags, Tier 1/2 split |

These are descriptive — they exist in Scribe's domain (`..\docs\AI\GLOSSARY.md` and `..\docs\AI\30_decisions\`), not as separate CONTEXT.md files.

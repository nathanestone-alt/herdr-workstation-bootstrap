---
name: grill-with-docs-stmodel
description: STModel-adapted grilling session that challenges a plan against the locked Phase 2 taxonomy + Scribe-owned glossary + audit-lane Decision docs, sharpens terminology against the live workbook, and surfaces ADR-worthy decisions while respecting the 3-bot lane write-rules. Use when user wants to stress-test a plan before Phase A authoring, scope lock, or Decision chat-gate. (Forked from mattpocock/skills `grill-with-docs`; pull a fresh upstream copy to `~/.claude/skills/grill-with-docs/` when starting a new project and re-adapt.)
---

<what-to-do>

Interview the user relentlessly about every aspect of the plan until reaching shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide a recommended answer.

Ask questions one at a time, waiting for feedback on each before continuing.

If a question can be answered by exploring the codebase, the live workbook, or existing docs, explore them instead of asking.

</what-to-do>

<supporting-info>

## Project layout (STModel-adapted)

This skill is adapted for STModel's 3-bot lane system (Audit / Builder / Scribe). Paths assume an Audit-lane session running from `audit\`.

### Authoritative sources (read-only for Audit)

| Source | Path | What it holds |
|---|---|---|
| Glossary | `..\docs\AI\GLOSSARY.md` | Scribe-owned project terminology |
| Cross-phase ADRs | `..\docs\AI\30_decisions\` | 97-row × 11-domain cross-phase decision aggregator |
| Named-range contracts | `..\docs\AI\20_contracts\` | Per-Calc-tab NR contract docs |
| Phase specs | `..\model\_spec\phase_<N>_<topic>.md` | Spec source-of-truth for grounding |
| Builder return docs | `..\model\_handoff\to-audit\<topic>.md` | Phase B return + verify-PASS evidence |
| Live workbook | `..\model\workbook\STModel.xlsm` | Read via openpyxl (`keep_vba=True`) or COM-attach (`GetActiveObject`) |
| Audit memory | `audit\CLAUDE.md` + `~/.claude/projects/.../memory/MEMORY.md` | Locked patterns + decisions snapshot |

### Audit-writable surface (the ONLY paths to write)

| Target | Path | When to write |
|---|---|---|
| Decision doc | `..\model\_handoff\from-audit\<topic>.md` | Grill produces an ADR-worthy decision (see filter) |
| Phase A dispatch | `..\model\_handoff\from-audit\<topic>.md` | Grill closes Phase A and dispatch can be authored |
| Findings | `audit\findings\<topic>.md` | Grill surfaces a formal audit finding |
| Scribe ripple | `audit\_handoff\to-scribe\<topic>.md` | A glossary term was resolved; surface for Scribe fold-in |

**Do NOT write to `..\docs\` directly** — that's Scribe lane. Surface terminology resolutions as ripples, never inline edits.

**Do NOT touch `..\model\` outside `_handoff\from-audit\`** — Builder lane.

## During the session

### Challenge against the glossary + locked taxonomy

When the user uses a term that conflicts with `..\docs\AI\GLOSSARY.md` or with the Phase 2 taxonomy lock (see `audit\CLAUDE.md` "Locked decisions snapshot"), call it out immediately:

> Your glossary defines `<term>` as X, but you seem to mean Y — which is it?

STModel locked taxonomy to enforce on sight:
- **Prefix families**: `mu_*` (Main UW per-slot), `au_*` (Agency UW per-slot), `loan_*` (per-loan), `deal_*` (workbook deal-level), `rediq_*` (add-in owned, immutable), `def_*` (definition tables), `pca_*` (P&L calc), `idr_*` (RR snapshot T1)
- **Zero-padding universal**: 2-digit zero-pad on ALL numeric suffixes (`mu_slot_01`, `pcm_mguw_g00`, `_RediQ_*_PF01`) — exception: `rediq_*` and `_RediQ_*` sheets
- **Single chart, three views**: ONE table at `def_account_map_main` (78 RedIQ rows); RedIQ full / Agency 48-code / Main 26-code rollup. No separate `def_account_map_agency` or `def_uw_account_tree`.
- **PFI ownership**: PFI = ONLY input surface. MCFE = pure calc. MCFV = view mirror. Tri-tab principle.
- **Per-slot tax solver**: 22 names/slot under `mu_slot_NN_tax_*` / `au_slot_NN_tax_*`; supersedes the legacy 25-name 8-prefix tax scheme.

### Sharpen fuzzy STModel language

Common ambiguities worth pre-empting:

| Fuzzy term | Force precision |
|---|---|
| "cascade" | Tier-3 line-item cascade? Slot pointer cascade? Reset Defaults cascade-restore? |
| "defaults" | Q-selector defaults? Per-row R/S/T/U init? Cascade defaults? PFI Import-RedIQ defaults? |
| "snapshot" | RR snapshot (`idr_*` T1)? Scenario snapshot? Reset-Defaults snapshot-restore? |
| "slot" | UW slot (1-5 per UW tab)? PFI slot? Tax solver slot? |
| "block" | P&L 4-block matrix? UW block-persistence block? Section block? |
| "view" | View-switching layer (D-RR-31)? Static visible tabs view? Account-tree view (RedIQ/Agency/Main)? |
| "scope" | Workbook scope NR? Sheet scope NR? Dispatch scope? Class-A vs Class-B Tier-1 scope? |
| "sign convention" | P&L canonical (Less: rows POSITIVE, subtotals subtract) vs RedIQ raw sign? |

### Discuss concrete scenarios

Stress-test domain relationships with STModel edge cases:
- **Cross-shape T2 switch**: variable-cardinality data across snapshots (mandate from D-RR-30+)
- **Per-slot vs per-deal scope**: which NR family fits?
- **Write-time vs migration-time**: pipeline write-time fix vs surgical migration script
- **Class B precondition**: probe SKIP (not FAIL) on pre-migration state
- **Pointer SSOT vs derived flags**: slot visibility — which is source-of-truth?

### Cross-reference live state, not memory

Per `feedback_quote_live_workbook_not_memory`: when the user (or you) state how a name / sheet / formula works, **read it before asserting**. Three sources in priority order:

1. **Live workbook** via openpyxl `wb.defined_names` or `ws[cell].value` (~1-2s read)
2. **Audit memory** in `audit\CLAUDE.md` "Locked decisions snapshot" section
3. **Live runtime** via pywin32 COM-attach (`GetActiveObject("Excel.Application")`) for runtime values or runtime-only behavior

If memory contradicts live state, **live wins** and the memory entry needs an update.

### Surface terminology resolutions to Scribe

When a term is resolved during the grill, do NOT edit `..\docs\AI\GLOSSARY.md`. Instead, append a single block to `audit\_handoff\to-scribe\glossary_ripple_<YYYY-MM-DD>.md`:

```md
## <term> — resolved <YYYY-MM-DD>
- Canonical: <term>
- Avoid: <aliases>
- Definition: <one or two sentences>
- Trigger: <which dispatch / Phase A / grill>
```

Scribe folds these during the next ripple cycle.

### Offer Decision docs sparingly

STModel's `..\model\_handoff\from-audit\<topic>.md` Decision convention already encodes ADR shape. Offer a formal Decision doc only when ALL THREE are true:

1. **Hard to reverse** — meaningful future cost to change (architectural shape, NR taxonomy lock-in, sheet-class handler structure, sign-convention transforms)
2. **Surprising without context** — a future reader will wonder "why?" (non-obvious deviations from FAST / DAG-flow / non-volatile principles)
3. **Real trade-off** — genuine alternatives with explicit rationale (Option A vs B with reasoning, locked via chat-gate)

If any of the three is missing, **capture the resolution in the Phase A dispatch scope** or as a scope note — not as a formal Decision doc.

See [ADR-FORMAT.md](./ADR-FORMAT.md) for short-form ADR shape if needed outside the Decision-doc convention.
See [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md) for canonical glossary format (Scribe-owned target).

## When NOT to grill

- During Builder Phase B execution — grilling delays the build. Save grill rounds for Phase A authoring or pre-Decision chat-gate.
- During mechanical gate-review (G1-Gn) — that's evidence-checking, not design exploration.
- When the user signals "lock and ship" — chat-gate locks decisions; grilling reopens them.

Best windows:
- **Phase A authoring** before dispatch draft (D-UW-03 Phase A; D-TAX-4 Phase A)
- **Pre-Decision chat-gate** when scope feels mushy
- **Scope lock** for substantial new dispatches (PFI v14 phases, future MCFE phases)
- **Cross-bot ripple framing** when terminology disagreement surfaces between Audit/Builder/Scribe

</supporting-info>

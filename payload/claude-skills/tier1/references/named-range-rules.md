# Named-range rules (what a gate must respect)

The model is 100% named ranges (principle #3). Gates read by name; a gate that
reads A1 is wrong. Source of truth is the workbook `key` sheet -- read it, not
this snapshot.

## NR tier model (cross-tab data)

A single logical series exists at three reference tiers. Reading the wrong tier is
the classic wrong-snapshot leak -- a Tier-1 round-trip assertion is the canonical
detector.

- **T1 snapshot-locked** (`idr_rr_rentroll_<NN>`): per-snapshot fixed reference.
- **T2 unsuffixed alias** (`idr_rr_rentroll`): redirects to the *active* snapshot's
  T1 via `SetActiveSnapshotPointer`.
- **T3 cross-tab consumer**: reads **T1 directly** to avoid wrong-snapshot
  leakage. A gate verifying a cross-tab consumer must assert it bound to T1, not
  T2 -- T2 leaks the wrong snapshot when the active pointer moves.

Vector vs scalar vs selector: index series -> vectorize; selector -> redirect;
single field -> scalar.

## Boundary-NR principle (#10)

MUST be named: cross-sheet references; multi-row same-sheet ranges. Exempt:
same-row references; criteria cells; cell-arithmetic subtotals. A schema gate
enumerates defined names and flags any cross-sheet/multi-row ref that is a raw A1.

## Prefix taxonomy (locked)

Pattern: `[tier][scope][subtype?]_<name>`. Tier = position 1, scope
(`d` deal / `s` scenario) = position 2 (except `m_*` handoff, no scope). Tiers:
`i` Input, `t` Tax/Val, `u` UW, `p` P&L, `r` RR, `c` Collections, `l` Loan Sizing,
`n` S&U, `e` MCFE, `w` Waterfall, `o` Output, `v` View, `m` Handoff, `def_` Admin.
Scope-prefix families: `mu_*`/`au_*` (per-slot UW), `loan_*` (per-loan), `deal_*`
(per-workbook deal-level). **Zero-padding is universal** on numeric suffixes
(`mu_slot_01`, `pcm_mguw_g00`). `ValidatePrefixes` macro enforces forward (every
NR matches a prefix) and reverse (every prefix has a user or "reserved").

## Immutable names

`rediq_*` and the `_RediQ_*` sheets are **add-in owned -- immutable.** A gate must
never expect to rename, pad, or rewrite them. They are also why LibreOffice recalc
fails (the add-in isn't loaded there). Legacy `bridge_*` is dead -- do not migrate.

## The array-formula phantom-delta pitfall (critical for diff gates)

openpyxl `ArrayFormula` / `DataTableFormula` have **no value-equality** -- comparing
two loads with `cell.value != other` falls back to *identity* (object id), which
always differs. A naive zero-delta / parity gate then flags EVERY array-formula
cell as a phantom delta (a real case went 723 phantom -> 0 once fixed). Normalize
before diffing: `("ARR", v.ref, v.text)` for `ArrayFormula`. If a survivor-isolation
gate "fails" with deltas concentrated on calc/array-heavy sheets, inspect the cell
types before believing the failure. `canon_diff.py` already handles this.

# The 10 non-negotiable model principles

A Tier-1 gate exists to defend these. Any pattern (especially one carried from a
prior repo) must satisfy them first. Source of truth: `model/CLAUDE.md` and
`audit/CLAUDE.md`; this is the orientation copy -- if they diverge, those win.

1. **DAG flow** -- calculations move one direction; **no circular references.**
   (A runtime gate catches a circular ref that schema cannot.)
2. **Backend solvers** replace circular dependencies (VBA now, Python at web port).
3. **100% named ranges** throughout, for portability. Gates read by name, not A1.
4. **FAST modeling** -- inputs separated from calculations.
5. **Maximum two functions per calculation** -- outputs feed sequentially.
6. **Each scenario fully self-contained** -- no cross-scenario dependencies.
7. **Four-tier tab system** at the visual layer: Input / Calc / Output / View.
8. **Excel-first, web-portable** -- Excel must work flawlessly on its own.
9. **Non-volatile formulas only** -- no `OFFSET`, `INDIRECT`, `NOW`, `TODAY`,
   `RAND`, `RANDBETWEEN`, `CELL`(cell-args), `INFO`. Volatile functions recalc on
   every change and kill scenario-flip speed. Substitutes: `INDEX` for dynamic
   refs (returns a reference, non-volatile), `SUMIFS`/`SUMPRODUCT` for conditional
   sums, `INDEX/MATCH` for lookups, `INDEX(range,,start):INDEX(range,,end)` for
   trailing-N-period sums. **No exceptions.** A schema gate can grep formula text
   for these tokens.
10. **Boundary-named-range principle** (web-port-driven): cross-sheet refs +
    multi-row same-sheet ranges MUST be named ranges; same-row refs, criteria
    cells, and cell-arithmetic subtotals are exempt.

## How gates map to principles

- **#1 no-circular** -> runtime gate: `CalculateFull()` then assert no cell holds
  a circular-ref error; or check the solver run order produced a stable result.
- **#3 named ranges / #10 boundary-NR** -> schema gate: enumerate
  `wb.defined_names`, assert every cross-sheet/multi-row reference is named.
- **#9 non-volatile** -> schema gate: scan formula text for the banned tokens.
- **#6 self-contained scenarios** -> runtime gate: flip the active scenario and
  assert no other scenario's outputs moved.

## Solver run order (load-bearing for runtime gates)

`Tax -> Loan Sizing -> Cash Flow -> Interest Carry -> Waterfall.` Interest carry
runs AFTER cash flow. Plan-level passes: 0a RR aggregation, 0b RedIQ P&L parser,
0c UW scenario resolution, 1 Tax, 2 Loan sizing, 2.5 S&U balance, 3 Reno ramp,
4 MCFE/cash-flow, 5 Interest carry, 6 Waterfall. A runtime gate that drives the
engine should respect this order (e.g. call `RunMle` which orchestrates it) before
reading downstream values.

# Workbook architecture (which surface a gate reads)

`model/workbook/STModel.xlsm` is the durable canonical baseline. It
does NOT regenerate per dispatch -- migrations are surgical. A gate is only as good
as the surface it reads; this is the map. Visual tiers: Input / Calc / Output /
View (principle #7).

**Never hard-code a sheet count in a gate.** This file used to say "~66 sheets";
the real total drifts with post-lock engine/cache sheets and is **user-variable** --
RR snapshot tabs (`RR Landing_*`, `RR Unit Mix Landing_*`, `RR Source Landing_*`)
are created and deleted as rent rolls are added and removed. A gate that pins a
count fails the next time the user touches a rent roll. Derive it live from
`sheet_state` via openpyxl (#711).

## Engine caches (hidden / veryHidden -- where runtime values live)

These are written by the VBA engine (`RunMle` etc.) and are usually what a runtime
gate asserts against:

- `_MLECache` (hidden, ~4393 rows x 70) -- levered cash-flow cache; 30 scenario
  blocks. The MLE runtime gate reads month-indexed strips here (`mle_*`).
- `_MLEStrip` (hidden) -- per-run strip the cache is built from.
- `_MCFEStmtCache` (veryHidden) -- consolidated MCFE statement cache feeding MCFLV.
- `_UWArmCache` (hidden) -- always-full UW cache. (Distinct from `_LoanSlotCache`,
  which is demand-driven -- do not conflate the two.)
- `_LoanSlotCache` (hidden) -- per-loan-slot, populated on demand.
- `_agcy_arc` (hidden) -- agency pricing arc data.

## View tabs (read ONLY from Outputs)

`MCFE`, `MCFLV`, `Main UW`, `Agency UW`, plus output/summary tabs. View tabs read
from the `_Outputs` block, never from source (one exception: a live active-scenario
preview may read source for the active scenario only). A gate checking a view tab
should trace back through `_Outputs`.

## Landing + snapshot tabs (the T1/T2 split is physical here)

- `P&L Landing`, `RR Landing_01` (veryHidden) / `RR Landing_02` (visible), and the
  `RR Source Landing_*` / `RR Unit Mix Landing_*` pairs. The `_01`/`_02` suffix is
  the snapshot tier -- see `named-range-rules.md`. `_RRSnapshotIndex` is the
  selector.

## RedIQ add-in sheets (IMMUTABLE, add-in owned)

`_RediQ_Scalars`, `_RediQ_RentRoll`, `_RediQ_RentRollComm`, `_RediQ_RRSource`
(spans the full 1,048,576-row sheet -- do not iter_rows it blindly),
`_RediQ_Floorplan/Cashflow/LineItems*`. These hold the live deal feed. **Their
functions are why LibreOffice recalc is invalid** -- the add-in isn't loaded there.
Never rewrite or rename `rediq_*` ranges.

## Audit-log / test sheets (built-in self-checks)

`_AuditLog_TaxSolver`, `_AuditLog_PLPipeline` (~10k rows), `_AuditLog_RRPipeline`,
and `_Test_TaxSolver` / `_Test_PLPipeline` / `_Test_RRPipeline`. These are the
in-workbook test harnesses; the Python `model/_archive/test_*_tier1.py` runners
drive/read them. A runtime gate can read these logs to confirm a pipeline ran
clean rather than re-deriving every value.

## Admin / catalog

`key` (prefix taxonomy -- authoritative), `_Defaults_Catalog` / `_PFIDefaults`
(catalog defaults -- a gate comparing defaults must match live cell values, never
invent them), `_Color_Palette`, `_StaleUWDecisions`.

## Practical gate hints

- Many sheets are 1x1 stubs (`Deal`, `Waterfall`, `Summary`, ...) -- placeholders;
  don't assume emptiness means a defect.
- `_RediQ_RRSource` reports `max_row` as the full sheet -- bound your scans.
- Read engine outputs from the caches above, not from the View tabs, when checking
  runtime correctness; View tabs lag until `_Outputs` is refreshed.

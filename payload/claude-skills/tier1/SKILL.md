---
name: tier1
description: >-
  The STModel verification gate, invoked as /tier1. Use for any model/audit gate
  or verification of model/workbook/STModel.xlsm: Tier-1 openpyxl schema and
  Excel-COM runtime checks, recalc, #REF!/#NAME? scans, solver/cache validation
  after RunMle, gate/probe authoring or re-run, and merge/block verdicts. Also use
  for every exported-VBA change/review, compile/static-diagnostic investigation,
  or call-graph/dependency/unreachable-code analysis. Trigger on casual requests
  such as "recalc the model", "does this pass?", "re-run the gate", or "check the
  cache". IMPORTANT: recalc only through real Excel COM, never LibreOffice;
  without the RedIQ add-in and VBA UDFs, alternate engines create false
  #NAME?/#REF! results.
---

# STModel Tier-1 / Tier-2 gate

## Gate depth: LIGHT (default) vs FULL — pick first, before any agent spend

Two depths, one skill. **Default is LIGHT.** The token sink in past gates was an
LLM re-deriving checks that are deterministic scripts; the misses (DV surface,
pointer numfmt — D-UWRC-D3-R2a) were COVERAGE gaps, not depth gaps. So: the
scripted battery carries the accumulated trip-wires and never forgets a lesson;
LLM effort is reserved for novel surfaces.

**LIGHT (default — hotfix-scale arcs, .bas-only fixes, small cell/NR patches):**
run the standing deterministic battery + diff-scoped asserts, driven inline by
the orchestrator or ONE cheap agent (sonnet or below). The battery runner is
**`py -3.13 audit/_tools/t1_lite.py`** (add `--runtime` for the COM leg;
baseline = `audit/_tools/t1_lite_baseline.json`, restamped via
`--update-baseline` ONLY against an authorized post-merge master — a baseline
restamp legalizes state, so it needs the same authorization chain as the merge
that produced it). Battery = cached exported-VBA static-analysis delta + reserved-word
lint on touched `.bas` + module-parity gate + defined-name prefix taxonomy +
drawing/part census + cached-error surface delta + pointer-format & DV census
(raw-XML, never openpyxl `number_format`) + corner-cell zero-delta via the COM
runtime scaffold +
idempotency re-run. Still an independent context from the builder, still writes
the git-tracked verdict (root §5 is NOT waived — light is a depth, not an
exemption).

**FULL (independent re-derivation, opus-or-better, current classic style):**
required when ANY of these hold —
- structural workbook migration: NR family create/delete/repoint at scale,
  formula-class rewrite across many cells, sheet add/remove, capacity change
- new VBA subsystem, pipeline-coordination change, or embedded-part surgery
  (customUI/ribbon, zip-level edits)
- a locked Decision flags the arc contentious, or builder returned deviations
- **any LIGHT battery failure → escalate to FULL** (never patch-and-rerun light)
- user asks for the full gate.

When new defect classes surface (every T2 fail teaches one), add the probe to
the battery — that is how light stays trustworthy.

## What this is for

STModel's verification is split into two passes that must both pass before
anything merges to `master`:

- **Tier 1** = automated gates. Two halves: a fast **schema** pass (openpyxl,
  pure Python, ~1-2s, reads structure/formulas/named-range geometry) and a
  **runtime** pass (pywin32 COM drives a real headless Excel, `CalculateFull()`,
  ~20s, reads computed values). They are complementary: schema catches broken
  refs and wrong geometry; runtime catches anything that only goes wrong when the
  engine actually calculates (a solver that doesn't converge, a cache that is
  stale after `RunMle`, a circular ref).
- **Tier 2** = the user exercises the live workbook end-to-end. The skill helps
  you set up read-only Tier-2 state probes against the user's open Excel.

There is no single "gate runner" to invoke. Gates are small per-dispatch scripts.
The reusable part -- the COM attach, retry, resilience contract, result
collection, and verdict format -- lives in **`audit/_tools/com_gate_lib.py`**.
You write ~30 lines of dispatch-specific asserts on top of it.

## The one rule that matters most

**Recalc STModel through Excel COM, never through LibreOffice.** The workbook
depends on the RedIQ add-in (`rediq_*` ranges) and custom VBA functions that
LibreOffice cannot load, so a LibreOffice recalc reports massive false
`#NAME?`/`#REF!` errors and its "zero formula errors" verdict is noise. The
`document-skills:xlsx` skill's `scripts/recalc.py` is also Linux-only and crashes
on Windows. Use the COM path below.

## Interpreter

Always `py -3.13`. pywin32 (COM), openpyxl, formulas, ruff are installed there;
bare `python` resolves to 3.12 which is openpyxl-only and cannot drive COM. Every
command and shebang in this skill assumes `py -3.13`.

## Exported-VBA preflight (mandatory, before Excel)

Run this before any Excel/COM work and for every exported-VBA review. Tier-1
LIGHT and FULL inherit it automatically through the registered `vba-static`
check in `t1_lite.py`:

```powershell
py -3.13 audit/_tools/vba_static_preflight.py --json
```

The normal path is deliberately cheap: verify the exported corpus, analyzer
inputs/policy, report bytes, and integrity sidecar; reuse the matching report;
then evaluate the accepted-actionable multiset. The full analyzer runs and
publishes atomically only when one of those identities changed. A missing or
mismatched exact-pinned dependency target, malformed/vacuous report, or new
actionable diagnostic fails closed; none may be silently skipped.

Keep the pinned analyzer dependencies outside the repo and outside global
site-packages. If the per-user target is absent, obtain dependency-install
authority once and bootstrap it with:

```powershell
$stVbaDeps = Join-Path $env:LOCALAPPDATA "STModel\vba-analysis-deps\py313-v1"
py -3.13 -m pip install --target $stVbaDeps -r audit/_tools/st_vba_analysis/requirements.txt
```

After either PASS or BLOCK, consume the published report with the MCP tool
`summarize_vba_analysis_report` when it is loaded. For a session started before
the MCP registration, use the installed STModelAgent CLI's
`vba-analysis summarize <report>` command (and its bounded module query) rather
than skipping report consumption.

Only a new actionable `(path, code, message)` multiset delta blocks. Line-only
movement does not; duplicate counts do. Advisory, host-gap, and reference-gap
findings stay visible but non-blocking. Never auto-restamp the accepted baseline:
that requires explicit user authority and independent review. Record the report
path, corpus hash, cached/regenerated mode, elapsed time, and diagnostic counts
in the verdict.

## Running a runtime gate (the common case)

Always run against a **COPY** of the built workbook, never the canonical or the
user's open file -- the isolated runtime mutates probe inputs and may `RunMle`.

```bash
# 1. make a copy (preserves the binary; the gate may mutate it)
cp model/workbook/STModel.xlsm /tmp/STModel_gate_copy.xlsm   # or a scratchpad path

# 2. run the gate against the copy
py -3.13 model/_archive/gate_<dispatch>_runtime.py /tmp/STModel_gate_copy.xlsm
echo "exit=$?"   # 0 = all PASS/SKIP (or COM_UNAVAILABLE); 1 = a hard FAIL
```

Authoring a new runtime gate: **copy `scripts/com_gate_scaffold.py`** to
`model/_archive/gate_<dispatch>_runtime.py` (build-lane) or
`audit/probe_<dispatch>_gate.py` (audit independent re-run), then replace the
`checks()` body. The scaffold already imports `com_gate_lib` and wires every
contract below; do not re-derive the attach/retry/exit logic by hand -- that
copy-drift is the historical source of flaky gates.

If the arc intentionally ships `model/workbook/STModel.xlsm`, put the exact
standalone metadata comment `# st_gate: allow_workbook=True` in one registered
Python arc gate. `st_gate_runner.py` discovers it from the gate source; without
that declaration (or the legacy explicit override), an `.xlsm` diff remains a
blocking `diff_isolation` failure. Remove the comment when copying that gate for
an arc that does not ship the workbook.

## The load-bearing contracts (all provided by com_gate_lib)

These are non-negotiable; the lib implements them so you inherit them for free.

- **Isolated attach.** `isolated_runtime(copy)` -> `DispatchEx("Excel.Application")`,
  `Visible=False`, `DisplayAlerts=False`, `ScreenUpdating=False`,
  `AskToUpdateLinks=False`, `EnableEvents=False`, `Open(path, UpdateLinks=0)`. The
  flags matter: a missing `UpdateLinks=0`/`AskToUpdateLinks=False` pops a modal
  that hangs a headless run.
- **COM_UNAVAILABLE -> exit 0.** If pywin32/Excel is missing, print
  `COM_UNAVAILABLE` and exit 0. The schema gate still governs and runtime defers
  to user Tier-2 -- a runtime gate must never block a merge just because the CI
  box has no Excel. `run_runtime()` does this for you.
- **Transient-busy retry.** Excel rejects COM calls mid-paint/mid-calc with
  specific HRESULTs (`RETRY_HRESULTS`); `retry(fn)` backs off and re-tries only
  those, re-raising any real error. Wrap `xl.Run(...)` and `xl.CalculateFull()`.
- **Class B = SKIP, not FAIL.** A check that asserts *post*-migration state must
  `gate.skip(...)` (not fail) when run against a *pre*-migration workbook -- it is
  a precondition, not a defect. SKIPs never flip the exit code.
- **Live Tier-2 is read-only.** `live_readonly()` uses `GetActiveObject` onto the
  user's open Excel and never mutates, saves, or quits it.

## Named-range access (the model is 100% named ranges)

Read by name, never by raw A1 -- principle #3. The lib gives you:

```python
L.scalar(wb, "mle_runid")          # scalar NR -> float|None
L.cellv(wb, "mle_bal_end", month)  # strip/vector NR, month-indexed (Cells(m+1))
L.nr(wb, "<name>").Value           # raw RefersToRange for anything else
L.name_exists(wb, "<name>")        # NON-throwing existence check (see below)
```

Use `name_exists` for precondition probes -- a throwing existence guard
(`On Error Resume Next: wb.Names(nm)`) raises a handled 1004 on every absent
name, which floods VBE Break-on-All-Errors during step-debug.

## Schema (openpyxl) side

Faster, no Excel. For a quick broken-ref scan after a migration:

```python
import com_gate_lib as L
errs = L.scan_formula_errors("path.xlsm")   # {'#REF!': ['Sheet!A1', ...], ...}
```

`scan_formula_errors` reads formula *text* -- it finds structurally broken refs
but does NOT recalc. A value-side error that only appears at calc time needs the
COM runtime gate. Heavy schema gates (geometry, NR-delta / zero-delta isolation)
stay per-dispatch; see `references/gate-pattern.md`.

## Writing the verdict

The audit gate writes a git-tracked verdict that merges or blocks. Format and
location are fixed -- `Gate.verdict_md(dispatch)` renders the standard
`Gate | Status | Evidence` table plus a bold verdict line. Write it to
`audit/findings/<dispatch>_gate_review.md` (or `model/_handoff/from-audit/` for a
cross-lane reply). A board transition is not a gate; the verdict file is.

## Bundled references (read when relevant)

- `references/gate-pattern.md` -- full per-dispatch gate anatomy, the schema/runtime
  split in depth, existing exemplars to copy, and the verdict-writing recipe.
- `references/ten-principles.md` -- the 10 non-negotiable model principles a change
  must satisfy (DAG/no-circular, 100% named ranges, non-volatile only, etc.). A
  gate exists to defend these.
- `references/named-range-rules.md` -- the NR tier model (T1/T2/T3), boundary-NR
  principle, prefix taxonomy, and the array-formula equality pitfall that produces
  phantom deltas.
- `references/workbook-architecture.md` -- sheet/cache map (the hidden caches,
  landing tabs, RedIQ add-in sheets) so a gate reads the right surface.

## Quick checklist before you call a gate "done"

- Ran against a **copy**, not the canonical / open workbook.
- Used `py -3.13`.
- Ran the exported-VBA preflight and consumed its report; no automatic baseline restamp.
- Recalc via **COM**, not LibreOffice.
- Read values by **named range**, not A1.
- Post-migration asserts **SKIP** (not FAIL) when run pre-migration.
- Exit code is 0 only when there are no hard FAILs.
- Verdict written to `audit/findings/` in the standard table format.

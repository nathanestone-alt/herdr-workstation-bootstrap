# Gate pattern (per-dispatch anatomy)

There is no central gate orchestrator. Each dispatch ships small standalone gate
scripts, copy-adapted from a shared pattern. This file is the pattern in depth.
The reusable contracts live in `audit/_tools/com_gate_lib.py`; the copy-adapt
template is `scripts/com_gate_scaffold.py`.

## The schema / runtime split

A dispatch that touches the workbook is gated by up to three scripts:

| Suffix | Engine | Speed | Catches |
|---|---|---|---|
| `_schema` / `_static` | openpyxl | ~1-2s | NR existence + geometry (stride, header keys), values-not-formulas where required, structurally broken `#REF!`/`#NAME?` in formula text, HEAD-vs-built zero-delta isolation |
| `_runtime` | pywin32 COM | ~20s | computed values after `CalculateFull()` / `RunMle`: solver convergence, cache freshness, no circular ref, exit-month balances |
| `_idempotency` | either | varies | re-running the migration/apply is a no-op (state-detect markers) |

Build-lane authors them as `model/_archive/gate_<dispatch>_*.py`. Audit's
independent re-run lives as `audit/probe_<dispatch>_gate*.py` and must reach the
same verdict from a clean context.

## Per-gate G1-G8

"G1-G8 trip-wires" are **not** a fixed global list -- each gate script defines its
own numbered checks (a geometry gate's G1-G8 differ from a runtime gate's). Number
them in the script and carry the same IDs into the verdict table so evidence is
traceable. The *durable* non-negotiables are the 10 model principles
(`references/ten-principles.md`); the per-gate Gn checks are how a specific
dispatch defends them.

## Existing exemplars worth copying

- `audit/_tools/t1_lite.py` -- the standing LIGHT-depth battery (8 baseline-delta
  checks incl. module parity, part census, error surface, pointer DV; `--runtime`
  adds the COM leg). Baseline `t1_lite_baseline.json`; `--update-baseline` only
  post-merge under user authorization.
- `audit/_tools/module_parity_gate.py` -- repo-wide reusable gate
  (VBA `.bas` <-> loaded-module parity, with symmetric mojibake repair). Required
  on every xlsm-bundling PR. `--selftest`, exit 0/1/2.
- `audit/_tools/canon_diff.py` -- the NR-delta + `#REF!`/`#NAME?` diff engine
  (HEAD vs worktree). Use for zero-delta isolation.
- `audit/_archive/ls_rev1_t1_smoke.py` -- large smoke harness; the EV-dict +
  Class-B-precondition-SKIP + temp-copy idiom at scale.
- `model/_archive/gate_d_mcflv_1_r2_runtime.py` -- canonical runtime gate
  (RunMle restamp -> CalculateFull -> per-month asserts).

## Writing the verdict

`run_runtime()` returns just the exit code. To emit a verdict file, drive the
`Gate` yourself so you keep the instance:

```python
import sys, com_gate_lib as L

def checks(xl, wb, gate):
    ...  # gate.chk(...) / gate.skip(...)

gate = L.Gate("D-EXAMPLE-runtime")
try:
    with L.isolated_runtime(sys.argv[1]) as (xl, wb):
        L.retry(lambda: xl.CalculateFull())
        checks(xl, wb, gate)
except L.ComUnavailable as e:
    print(f"COM_UNAVAILABLE: {e}")   # still exit 0
    sys.exit(0)

gate.summary()
md = gate.verdict_md("D-EXAMPLE", evidence_extra="Re-run from clean audit context.")
# write md to audit/findings/<dispatch>_gate_review.md
sys.exit(gate.exit_code)
```

Verdict location: `audit/findings/<dispatch>_gate_review.md` (or `_gate_verdict.md`),
and `model/_handoff/from-audit/<topic>.md` for a cross-lane reply. The file is the
gate of record -- a Kanban/board move is not.

## Resilience & isolation reminders

- Run against a **copy**; the runtime mutates probe inputs / runs `RunMle`.
- Never `GetActiveObject` for a gate -- that attaches the user's live Excel.
  `GetActiveObject` is only for read-only Tier-2 probes (`live_readonly()`).
- Wrap `xl.Run`/`xl.CalculateFull` in `retry()`; headless DispatchEx races the
  paint/calc loop.
- A check is only as good as the surface it reads -- confirm the right sheet/cache
  (`references/workbook-architecture.md`); the model leaks wrong-snapshot data if
  a T3 consumer reads T2 instead of T1.

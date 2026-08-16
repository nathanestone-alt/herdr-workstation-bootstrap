#!/usr/bin/env py -3.13
"""
com_gate_scaffold.py -- COPY-ADAPT template for an STModel Tier-1 runtime gate.

HOW TO USE
----------
1. Copy this file to model/_archive/gate_<dispatch-id>_runtime.py (build-lane) or
   audit/probe_<dispatch-id>_gate.py (audit independent re-run).
2. Replace the checks() body with your dispatch-specific asserts.
3. Run against a COPY of the built workbook:
     py -3.13 <your-gate>.py path/to/COPY.xlsm
   It restamps via CalculateFull() and exits 0 (all PASS / SKIP / COM_UNAVAILABLE)
   or 1 (any FAIL).
4. If registering the gate with st_gate_runner, follow the "Arc-gate authoring
   contract" in audit/CLAUDE.md for its summary, exit-code, and command form.

WHY A COPY: the isolated runtime mutates probe inputs and may RunMle; never point
it at the canonical or the user's open workbook. The schema (openpyxl) gate is a
separate, faster pass -- keep it in its own gate_<id>_schema.py.

This scaffold imports audit/_tools/com_gate_lib.py for the load-bearing contracts
(isolated attach, retry, COM_UNAVAILABLE->exit-0, Class-B SKIP, verdict writer).
Do not re-derive those by hand -- that copy-drift is where gates go wrong.
"""
import sys
from pathlib import Path


def _import_lib():
    """Locate audit/_tools/com_gate_lib.py by walking up from this file / cwd."""
    here = Path(__file__).resolve()
    for base in [here, *here.parents, Path.cwd(), *Path.cwd().parents]:
        cand = base / "audit" / "_tools"
        if (cand / "com_gate_lib.py").is_file():
            sys.path.insert(0, str(cand))
            import com_gate_lib  # type: ignore

            return com_gate_lib
    raise SystemExit(
        "FAIL: cannot find audit/_tools/com_gate_lib.py -- run from inside the "
        "STModel repo (main checkout or a worktree)."
    )


L = _import_lib()


def checks(xl, wb, gate):
    """Dispatch-specific Tier-1 runtime asserts. REPLACE this body.

    `gate` is a com_gate_lib.Gate. Use:
      gate.chk("C1 <claim>", <bool>, "<evidence>")   # PASS/FAIL
      gate.skip("C2 <claim>", "pre-migration")        # Class-B precondition
    Read live values with the lib accessors:
      L.scalar(wb, "mle_runid")          # scalar NR
      L.cellv(wb, "mle_bal_end", month)  # strip/vector NR, month-indexed
      L.nr(wb, "<name>").Value           # raw RefersToRange
    Drive the engine with the retry wrapper:
      status = L.retry(lambda: xl.Run("RunMle", True))
      gate.chk("C1 RunMle status", isinstance(status, str) and status.startswith("OK: "))
      L.retry(lambda: xl.CalculateFull())
    """
    # --- example: precondition guard (Class B -> SKIP, never FAIL) -----------
    if not L.name_exists(wb, "mle_runid"):
        gate.skip("C0 engine present", "mle_runid absent -> pre-migration workbook")
        return

    # --- example asserts (delete; write your own) ---------------------------
    run_status = L.retry(lambda: xl.Run("RunMle", True))
    if not gate.chk(
        "C1 RunMle returned OK status",
        isinstance(run_status, str) and run_status.startswith("OK: "),
        f"status={run_status!r}",
    ):
        return
    L.retry(lambda: xl.CalculateFull())
    runid = L.nr(wb, "mle_runid").Value
    gate.chk("C2 fresh runid after RunMle", runid not in (None, ""), f"runid={runid}")

    flag = L.scalar(wb, "mle_ctl_flagmo")
    if flag and 1 <= flag <= 144:
        fm = int(round(flag))
        bal = L.cellv(wb, "mle_bal_end", fm)
        gate.chk(
            f"C3 mle_bal_end == 0 at exit month {fm}",
            bal is not None and abs(bal) < 1e-3,
            f"bal_end[{fm}]={bal}",
        )


def main():
    if len(sys.argv) < 2:
        print("Usage: py -3.13 <gate>.py <path-to-COPY.xlsm>")
        return 2
    copy_path = sys.argv[1]
    code = L.run_runtime(copy_path, checks, gate_name="D-<DISPATCH>-runtime")
    # To emit a verdict file, capture the Gate instead of run_runtime; see
    # references/gate-pattern.md "Writing the verdict".
    return code


if __name__ == "__main__":
    sys.exit(main())

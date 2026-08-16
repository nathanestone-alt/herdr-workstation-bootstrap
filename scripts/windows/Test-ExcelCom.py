"""Disposable Excel COM smoke test. Never touches a production workbook."""

from __future__ import annotations

import json
import time
from pathlib import Path

import pythoncom
import win32com.client

OUTPUT_DIR = Path(r"C:\HerdrExchange\out")
OUTPUT_FILE = OUTPUT_DIR / "excel-com-smoke-test.xlsx"


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    if OUTPUT_FILE.exists():
        OUTPUT_FILE.unlink()
    pythoncom.CoInitialize()
    excel = None
    workbook = None
    try:
        excel = win32com.client.DispatchEx("Excel.Application")
        excel.Visible = False
        excel.DisplayAlerts = False
        workbook = excel.Workbooks.Add()
        sheet = workbook.Worksheets(1)
        sheet.Cells(1, 1).Value = "Herdr Excel COM smoke test"
        sheet.Cells(2, 1).Value = 42
        workbook.SaveAs(str(OUTPUT_FILE), FileFormat=51)
        workbook.Close(SaveChanges=False)
        workbook = None
        excel.Quit()
        excel = None
        time.sleep(1)
        if not OUTPUT_FILE.exists() or OUTPUT_FILE.stat().st_size == 0:
            raise RuntimeError("Excel did not create a valid output file")
        print(json.dumps({"status": "PASS", "file": str(OUTPUT_FILE), "bytes": OUTPUT_FILE.stat().st_size}))
    finally:
        if workbook is not None:
            workbook.Close(SaveChanges=False)
        if excel is not None:
            excel.Quit()
        pythoncom.CoUninitialize()


if __name__ == "__main__":
    main()


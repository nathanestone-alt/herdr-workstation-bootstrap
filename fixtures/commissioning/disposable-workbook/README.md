# Disposable commissioning workbook

No workbook binary is tracked here. Generate a fresh, noncanonical macro-enabled
container only on the Windows host, then delete it after the commissioning
roundtrip. The file must never be the STModel canonical workbook.

The preferred smoke path is:

~~~powershell
$smoke = & .\scripts\commissioning\windows\Test-HerdrExcelComSmoke.ps1 -KeepOutput |
    ConvertFrom-Json
~~~

That creates a disposable .xlsx under the Windows temporary directory. If a
macro-enabled container is specifically required for the acceptance record,
use this equivalent interactive-only generator and keep the output under the
Windows temporary directory until it is copied into the configured OneDrive
Inbox:

~~~powershell
$root = Join-Path ([IO.Path]::GetTempPath()) ('herdr-commissioning-xlsm-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$path = Join-Path $root 'commissioning-fixture.xlsm'
$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false
$book = $excel.Workbooks.Add()
$book.Worksheets.Item(1).Cells.Item(1, 1).Value2 = 'Herdr disposable commissioning fixture'
$book.Worksheets.Item(1).Cells.Item(2, 1).Value2 = 42
$book.SaveAs($path, 52)
$book.Close($false)
$excel.Quit()
[Runtime.InteropServices.Marshal]::ReleaseComObject($book) | Out-Null
[Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
$path
~~~

The generated fixture contains no VBA project and no production data. Copy it
to the host-owned OneDrive Inbox, verify Always keep on this device, and pass
that Inbox path to
scripts/commissioning/windows/Invoke-HerdrReviewCommissioningRoundtrip.ps1.
Do not place it in Git, C:\HerdrTools, C:\HerdrReviewJobs, or the Ubuntu
exchange before the ordered commissioning steps call for it.

#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$KeepOutput
)

$ErrorActionPreference = 'Stop'

try {
    if (-not $IsWindows) {
        throw 'Excel COM smoke is Windows-only.'
    }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $OutputDirectory = Join-Path $tempRoot ('herdr-commissioning-excel-smoke-' + [Guid]::NewGuid().ToString('N'))
    }
    $outputRoot = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
    if (-not $outputRoot.Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        -not $outputRoot.StartsWith("$tempRoot\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Disposable COM smoke output must remain under the system temp directory: '$outputRoot'."
    }
    if (Test-Path -LiteralPath $outputRoot -PathType Any) {
        throw "Refusing to reuse an existing COM smoke directory: '$outputRoot'."
    }
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    $outputPath = Join-Path $outputRoot 'excel-com-smoke.xlsx'
    $excel = $null
    $workbook = $null
    $sheet = $null
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $excel.EnableEvents = $false
        $excel.AutomationSecurity = 3
        $excel.AskToUpdateLinks = $false
        $workbook = $excel.Workbooks.Add()
        $sheet = $workbook.Worksheets.Item(1)
        $sheet.Cells.Item(1, 1).Value2 = 'Herdr disposable Excel COM smoke test'
        $sheet.Cells.Item(2, 1).Value2 = 42
        $workbook.SaveAs($outputPath, 51)
        $workbook.Close($false)
        $excel.Quit()
    }
    finally {
        if ($null -ne $workbook) {
            try { $workbook.Close($false) } catch {}
        }
        if ($null -ne $excel) {
            try { $excel.Quit() } catch {}
        }
        if ($null -ne $sheet) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sheet)
        }
        if ($null -ne $workbook) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($workbook)
        }
        if ($null -ne $excel) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
        }
    }
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw 'Excel COM did not produce the disposable smoke workbook.'
    }
    $hash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $result = [pscustomobject][ordered]@{
        schema = 'herdr-excel-com-smoke-v1'
        status = 'PASS'
        output_path = $outputPath
        size_bytes = (Get-Item -LiteralPath $outputPath).Length
        sha256 = $hash
        macros = 'disabled'
        external_links = 'not-updated'
        data_connections = 'not-present'
        trusted_locations = 'none-added'
        canonical_workbook_mutated = $false
        retained = [bool]$KeepOutput
    }
    $json = $result | ConvertTo-Json -Depth 6 -Compress
    if (-not $KeepOutput) {
        Remove-Item -LiteralPath $outputRoot -Recurse -Force
    }
    $json
}
catch {
    Write-Error "HERDR_EXCEL_COM_SMOKE_FAILED: $($_.Exception.Message)"
    exit 1
}

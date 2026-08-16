[CmdletBinding()]
param(
    [ValidateRange(1, 2880)]
    [int]$Iterations = 1,

    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 30,

    [switch]$Notify,

    [Nullable[datetime]]$NowUtc,

    [string]$LedgerPath = "C:\tmp\herdr-workflow-ledger.jsonl",
    [string]$WatchLogPath = "C:\tmp\herdr-coordination-watch.md",
    [string]$CoordinationLogPath = "C:\tmp\herdr-coordination.md",
    [string]$WorkflowScriptPath = $(Join-Path $PSScriptRoot "herdr_workflow.ps1")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$OutputEncoding = $utf8NoBom
try {
    [Console]::OutputEncoding = $utf8NoBom
}
catch {
    # A detached watchdog may not own a console.
}

if (-not (Test-Path -LiteralPath $WorkflowScriptPath)) {
    throw "Workflow script not found: $WorkflowScriptPath"
}

$summaries = [Collections.Generic.List[object]]::new()
for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    $scanArgs = @{
        Action = "scan"
        LedgerPath = $LedgerPath
        WatchLogPath = $WatchLogPath
        CoordinationLogPath = $CoordinationLogPath
    }
    if ($Notify) {
        $scanArgs.Notify = $true
    }
    if ($PSBoundParameters.ContainsKey("NowUtc")) {
        $scanArgs.NowUtc = [datetime]$NowUtc
    }

    $raw = & $WorkflowScriptPath @scanArgs
    $scan = ($raw -join [Environment]::NewLine) | ConvertFrom-Json -Depth 30
    $summaries.Add([pscustomobject]@{
        iteration = $iteration
        scanned = [int]$scan.scanned
        new_alert_count = @($scan.new_alerts).Count
        new_alerts = @($scan.new_alerts)
    })

    if ($iteration -lt $Iterations) {
        Start-Sleep -Seconds $IntervalSeconds
    }
}

[pscustomobject]@{
    action = "watchdog"
    iterations = $Iterations
    interval_seconds = $IntervalSeconds
    notified = [bool]$Notify
    results = @($summaries)
} | ConvertTo-Json -Depth 20

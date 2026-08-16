[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workflowPath = Join-Path $PSScriptRoot "herdr_workflow.ps1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-workflow-stress-$([Guid]::NewGuid().ToString('N'))"
$ledgerPath = Join-Path $tempRoot "ledger.jsonl"
$watchLogPath = Join-Path $tempRoot "watch.md"
$coordLogPath = Join-Path $tempRoot "coordination.md"
$fakeCoordPath = Join-Path $tempRoot "coord.ps1"
$fakeRtkPath = Join-Path $tempRoot "rtk.cmd"

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [Parameter(Mandatory)][string]$Message
    )
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', observed '$Actual'."
    }
}

function Start-RequestProcess {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$CandidateId,
        [Parameter(Mandatory)][int]$Index
    )

    $stdoutPath = Join-Path $tempRoot "stdout-$Index.txt"
    $stderrPath = Join-Path $tempRoot "stderr-$Index.txt"
    $command = @"
& '$workflowPath' -Action request -TaskId '$TaskId' -CandidateId '$CandidateId' -ReviewType 'stress-review' -PaneId 'w1:p2' -ExpectedTabLabel 'Stress Reviewer' -Message 'StressReview' -AckTimeoutSeconds 120 -NowUtc '2026-01-01T00:00:00Z' -LedgerPath '$ledgerPath' -WatchLogPath '$watchLogPath' -CoordinationLogPath '$coordLogPath' -CoordinationHelperPath '$fakeCoordPath'
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process -FilePath "pwsh" `
        -ArgumentList @("-NoProfile", "-EncodedCommand", $encoded) `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden `
        -PassThru
    return [pscustomobject]@{
        Process = $process
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
    }
}

function Wait-RequestBatch {
    param([Parameter(Mandatory)][object[]]$Batch)

    foreach ($item in $Batch) {
        $item.Process.WaitForExit()
        if ($item.Process.ExitCode -ne 0) {
            $stderrText = if (Test-Path -LiteralPath $item.StderrPath) {
                Get-Content -LiteralPath $item.StderrPath -Raw
            }
            else {
                ""
            }
            throw "Stress request process failed with exit code $($item.Process.ExitCode): $stderrText"
        }
        $item.Process.Dispose()
    }
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    @'
@echo off
setlocal EnableDelayedExpansion
if /I "%~1"=="proxy" shift
if /I not "%~1"=="herdr" exit /b 2
shift
if /I "%~1"=="agent" if /I "%~2"=="get" (
  set "testSession=session-stress"
  if /I "%~3"=="w2:p1" set "testSession=session-source"
  echo {"id":"stress:agent:get","result":{"type":"agent_info","agent":{"pane_id":"%~3","workspace_id":"w1","tab_id":"w1:t2","terminal_id":"stress-terminal","revision":1,"state_change_seq":1,"agent":"codex","agent_status":"idle","agent_session":{"agent":"codex","value":"!testSession!"}}}}
  exit /b 0
)
if /I "%~1"=="agent" if /I "%~2"=="read" (
  echo ready prompt
  exit /b 0
)
if /I "%~1"=="tab" if /I "%~2"=="get" (
  echo {"id":"stress:tab:get","result":{"type":"tab_info","tab":{"tab_id":"w1:t2","workspace_id":"w1","label":"Stress Reviewer","pane_count":1}}}
  exit /b 0
)
echo unexpected fake rtk invocation: %* 1>&2
exit /b 2
'@ | Set-Content -LiteralPath $fakeRtkPath -Encoding ascii

    @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Action,
    [string]$To,
    [string]$Message,
    [string]$TargetPane,
    [string]$PaneId,
    [string]$ExpectedAgent,
    [string]$ExpectedSession,
    [string]$ExpectedTabLabel,
    [string]$ExpectedTabId,
    [string]$LogPath
)
if ($Action -eq "deliver") {
    [pscustomobject]@{
        action = $Action
        delivery = [pscustomobject]@{
            pane_id = $PaneId
            delivery_state = "active_prompt"
            token = "[HC:stress01]"
            submitted = $true
            error = $null
        }
    } | ConvertTo-Json -Depth 5 -Compress
    exit 0
}
if ($Action -eq "prove-caller") {
    [pscustomobject]@{
        action = $Action
        proven = $true
        caller = [pscustomobject]@{
            pane_id = $PaneId
            agent = $ExpectedAgent
            session = $ExpectedSession
            caller_process_bound = $true
        }
    } | ConvertTo-Json -Depth 5 -Compress
    exit 0
}
[pscustomobject]@{
    action = $Action
    target_pane = $To
    relay_ref = "[HR:stress01]"
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath $fakeCoordPath -Encoding utf8

    $originalPath = $env:PATH
    $originalHerdrEnv = $env:HERDR_ENV
    $originalPaneId = $env:HERDR_PANE_ID
    try {
        $env:PATH = "$tempRoot;$originalPath"
        $env:HERDR_ENV = "1"
        $env:HERDR_PANE_ID = "w2:p1"

        Write-Output "CASE: 16 concurrent duplicate requests"
        $duplicateBatch = @(
            for ($index = 0; $index -lt 16; $index++) {
                Start-RequestProcess -TaskId "#700" -CandidateId "same-candidate" -Index $index
            }
        )
        Wait-RequestBatch -Batch $duplicateBatch

        Write-Output "CASE: 12 concurrent distinct requests"
        $uniqueBatch = @(
            for ($index = 0; $index -lt 12; $index++) {
                Start-RequestProcess `
                    -TaskId "#$([int](701 + $index))" `
                    -CandidateId "candidate-$index" `
                    -Index ([int](100 + $index))
            }
        )
        Wait-RequestBatch -Batch $uniqueBatch

        $events = @(Get-Content -LiteralPath $ledgerPath | ForEach-Object {
            $_ | ConvertFrom-Json -Depth 20
        })
        $reserves = @($events | Where-Object { $_.event -eq "request_reserved" })
        $requests = @($events | Where-Object { $_.event -eq "request" })
        $duplicateReserves = @($reserves | Where-Object { $_.task_id -eq "#700" })
        $duplicateJobKey = [string]$duplicateReserves[0].job_key
        $duplicateRequests = @($requests | Where-Object { $_.job_key -eq $duplicateJobKey })

        Assert-Equal -Actual $duplicateReserves.Count -Expected 1 -Message "Concurrent duplicate reservation was not idempotent."
        Assert-Equal -Actual $duplicateRequests.Count -Expected 1 -Message "Concurrent duplicate request was delivered more than once."
        Assert-Equal -Actual $reserves.Count -Expected 13 -Message "Concurrent distinct reservations were lost or duplicated."
        Assert-Equal -Actual $requests.Count -Expected 13 -Message "Concurrent distinct deliveries were lost or duplicated."
        Assert-Equal -Actual @($events | Where-Object { -not $_.event_id }).Count -Expected 0 -Message "A stress ledger event lacks an event ID."

        Write-Output "PASS: herdr workflow concurrent idempotency stress"
    }
    finally {
        $env:PATH = $originalPath
        $env:HERDR_ENV = $originalHerdrEnv
        $env:HERDR_PANE_ID = $originalPaneId
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

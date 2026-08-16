[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$wrapperPath = Join-Path $env:USERPROFILE ".claude\hooks\herdr-agent-state-async.mjs"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-claude-refresh-test-$([Guid]::NewGuid().ToString('N'))"
$reporterPath = Join-Path $tempRoot "reporter.mjs"
$callLogPath = Join-Path $tempRoot "calls.jsonl"
$failureDir = Join-Path $tempRoot "failures"

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Invoke-Wrapper {
    param(
        [Parameter(Mandatory)][hashtable]$Payload,
        [string]$PaneId = "w9:p9",
        [string]$HerdrEnv = "1",
        [int]$ReporterExit = 0
    )

    $env:HERDR_ENV = $HerdrEnv
    $env:HERDR_PANE_ID = $PaneId
    $env:HERDR_SESSION_REPORTER_EXE = (Get-Command node -ErrorAction Stop).Source
    $env:HERDR_SESSION_REPORTER_PREFIX_JSON = ConvertTo-Json -InputObject @($reporterPath) -Compress
    $env:HERDR_SESSION_REPORT_TEST_LOG = $callLogPath
    $env:HERDR_SESSION_REPORT_TEST_EXIT = "$ReporterExit"
    $env:HERDR_SESSION_REPORT_FAILURE_DIR = $failureDir
    $json = $Payload | ConvertTo-Json -Compress
    $json | & node $wrapperPath
    if ($LASTEXITCODE -ne 0) {
        throw "Claude provenance wrapper exited $LASTEXITCODE."
    }
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
$saved = @{}
foreach ($name in @(
        "HERDR_ENV", "HERDR_PANE_ID", "HERDR_SESSION_REPORTER_EXE",
        "HERDR_SESSION_REPORTER_PREFIX_JSON", "HERDR_SESSION_REPORT_TEST_LOG",
        "HERDR_SESSION_REPORT_TEST_EXIT", "HERDR_SESSION_REPORT_FAILURE_DIR"
    )) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}

try {
    @'
import { appendFileSync } from "node:fs";
const record = { args: process.argv.slice(2), pane: process.env.HERDR_PANE_ID };
appendFileSync(process.env.HERDR_SESSION_REPORT_TEST_LOG, JSON.stringify(record) + "\n", "utf8");
process.exit(Number(process.env.HERDR_SESSION_REPORT_TEST_EXIT || "0"));
'@ | Set-Content -LiteralPath $reporterPath -Encoding utf8

    Write-Output "CASE: top-level SessionStart reports exact native provenance"
    Invoke-Wrapper -Payload @{
        hook_event_name = "SessionStart"
        session_id = "11111111-2222-3333-4444-555555555555"
        transcript_path = "C:\tmp\claude-session.jsonl"
        source = "startup"
    }
    $calls = @(Get-Content -LiteralPath $callLogPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True -Condition ($calls.Count -eq 1) -Message "SessionStart did not invoke exactly one reporter."
    $argsText = $calls[0].args -join " "
    Assert-True -Condition ($argsText -match '^pane report-agent-session w9:p9 ') -Message "Reporter targeted the wrong pane."
    Assert-True -Condition ($argsText -match '--agent claude') -Message "Reporter lost the Claude agent kind."
    Assert-True -Condition ($argsText -match '--agent-session-id 11111111-2222-3333-4444-555555555555') -Message "Reporter lost the native session ID."
    Assert-True -Condition ($argsText -match '--agent-session-path C:\\tmp\\claude-session\.jsonl') -Message "Reporter lost the transcript path."
    Assert-True -Condition ($argsText -match '--session-start-source startup') -Message "Reporter lost the startup source."

    Write-Output "CASE: UserPromptSubmit refreshes provenance"
    Invoke-Wrapper -Payload @{
        hook_event_name = "UserPromptSubmit"
        session_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        transcript_path = "C:\tmp\claude-refresh.jsonl"
    }
    $calls = @(Get-Content -LiteralPath $callLogPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True -Condition ($calls.Count -eq 2) -Message "UserPromptSubmit did not invoke the reporter."
    $refreshArgs = $calls[1].args -join " "
    Assert-True -Condition ($refreshArgs -match '--agent-session-id aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') -Message "Refresh lost the native session ID."
    Assert-True -Condition ($refreshArgs -notmatch '--session-start-source') -Message "Refresh fabricated a SessionStart source."

    Write-Output "CASE: nested agent and unmanaged environment are ignored"
    Invoke-Wrapper -Payload @{
        hook_event_name = "UserPromptSubmit"
        session_id = "99999999-8888-7777-6666-555555555555"
        agent_id = "nested-agent"
    }
    Invoke-Wrapper -HerdrEnv "0" -Payload @{
        hook_event_name = "UserPromptSubmit"
        session_id = "99999999-8888-7777-6666-555555555555"
    }
    $calls = @(Get-Content -LiteralPath $callLogPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True -Condition ($calls.Count -eq 2) -Message "An untrusted nested or unmanaged event reached the reporter."

    Write-Output "CASE: reporter failure preserves native payload evidence"
    Invoke-Wrapper -ReporterExit 7 -Payload @{
        hook_event_name = "Stop"
        session_id = "12345678-1234-1234-1234-123456789abc"
    }
    $failurePayloads = @(Get-ChildItem -LiteralPath $failureDir -Filter "payload-*.json")
    Assert-True -Condition ($failurePayloads.Count -eq 1) -Message "Reporter failure did not preserve one native payload."
    $failure = Get-Content -LiteralPath $failurePayloads[0].FullName -Raw | ConvertFrom-Json
    Assert-True -Condition ([string]$failure.session_id -eq "12345678-1234-1234-1234-123456789abc") -Message "Failure evidence lost the native session ID."
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $failureDir "failures.log")) -Message "Reporter failure did not create a diagnostic log."

    Write-Output "PASS: Claude native-session refresh hook"
}
finally {
    foreach ($name in $saved.Keys) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name])
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

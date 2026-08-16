[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$refreshHook = Join-Path $env:USERPROFILE ".codex\herdr-agent-session-refresh.ps1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-codex-refresh-test-$([Guid]::NewGuid().ToString('N'))"
$fakeHerdr = Join-Path $tempRoot "herdr.cmd"
$callLog = Join-Path $tempRoot "calls.log"

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-RefreshFixture {
    param([Parameter(Mandatory)][hashtable]$Payload)

    $Payload | ConvertTo-Json -Compress |
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $refreshHook
    if ($LASTEXITCODE -ne 0) {
        throw "Refresh hook process failed with exit code $LASTEXITCODE."
    }
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    @'
@echo off
echo %*>>"%HERDR_REFRESH_TEST_LOG%"
if /I "%~1"=="pane" if /I "%~2"=="get" (
  echo {"id":"test:pane:get","result":{"type":"pane_info","pane":{"pane_id":"%~3","agent":"codex","agent_status":"idle"}}}
  exit /b 0
)
if /I "%~1"=="pane" if /I "%~2"=="process-info" (
  echo {"id":"test:pane:process-info","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:pG","shell_pid":0,"foreground_processes":[]}}}
  exit /b 0
)
if /I "%~1"=="pane" if /I "%~2"=="report-agent-session" (
  echo {"id":"test:pane:report-agent-session","result":{"type":"agent_session_reported"}}
  exit /b 0
)
echo unexpected fake herdr invocation: %* 1>&2
exit /b 2
'@ | Set-Content -LiteralPath $fakeHerdr -Encoding ascii

    $originalPath = $env:PATH
    $originalHerdrEnv = $env:HERDR_ENV
    $originalPaneId = $env:HERDR_PANE_ID
    $originalTestLog = $env:HERDR_REFRESH_TEST_LOG
    $originalCodexThreadId = $env:CODEX_THREAD_ID
    try {
        $env:PATH = "$tempRoot;$originalPath"
        $env:HERDR_ENV = "1"
        $env:HERDR_PANE_ID = "w1:pG"
        $env:HERDR_REFRESH_TEST_LOG = $callLog
        $env:CODEX_THREAD_ID = ""

        Invoke-RefreshFixture -Payload @{
            hook_event_name = "UserPromptSubmit"
            session_id = "session-prompt"
            transcript_path = "C:\tmp\session-prompt.jsonl"
        }
        Invoke-RefreshFixture -Payload @{
            hook_event_name = "Stop"
            session_id = "session-stop"
            transcript_path = "C:\tmp\session-stop.jsonl"
        }
        Invoke-RefreshFixture -Payload @{
            hook_event_name = "PreToolUse"
            session_id = "session-wrong-event"
            transcript_path = "C:\tmp\session-wrong-event.jsonl"
        }
        Invoke-RefreshFixture -Payload @{
            hook_event_name = "Stop"
            session_id = "session-subagent"
            transcript_path = "C:\tmp\session-subagent.jsonl"
            agent_id = "subagent-1"
        }
        Invoke-RefreshFixture -Payload @{
            hook_event_name = "Stop"
            session_id = "session-missing-transcript"
        }

        $calls = @(Get-Content -LiteralPath $callLog)
        $reports = @($calls | Where-Object { $_ -match '^pane report-agent-session ' })
        Assert-True -Condition ($reports.Count -eq 2) -Message "Expected exactly two native-session reports; calls: $($calls -join '; ')"
        Assert-True -Condition ([bool]($reports -match '--source herdr:codex --agent codex .+--agent-session-id session-prompt')) -Message "UserPromptSubmit did not refresh the exact native session."
        Assert-True -Condition ([bool]($reports -match '--source herdr:codex --agent codex .+--agent-session-id session-stop')) -Message "Stop did not refresh the exact native session."
        Assert-True -Condition (-not [bool]($calls -match 'session-wrong-event|session-subagent')) -Message "Rejected event or subagent provenance reached Herdr."

        Write-Output "PASS: Codex native-session refresh hook"
    }
    finally {
        $env:PATH = $originalPath
        $env:HERDR_ENV = $originalHerdrEnv
        $env:HERDR_PANE_ID = $originalPaneId
        $env:HERDR_REFRESH_TEST_LOG = $originalTestLog
        $env:CODEX_THREAD_ID = $originalCodexThreadId
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

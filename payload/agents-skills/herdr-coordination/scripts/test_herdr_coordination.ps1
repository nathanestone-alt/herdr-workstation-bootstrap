[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$helperPath = Join-Path $PSScriptRoot "herdr_coordination.ps1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-coordination-test-$([Guid]::NewGuid().ToString('N'))"
$fakeRtkPath = Join-Path $tempRoot "rtk.cmd"
$logPath = Join-Path $tempRoot "calls.log"
$coordLogPath = Join-Path $tempRoot "coordination.md"
$tabStatePath = Join-Path $tempRoot "tab-label.txt"

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

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

function Invoke-DeliveryCase {
    param(
        [Parameter(Mandatory)][ValidateSet("idle", "working", "blocked")][string]$Status,
        [Parameter(Mandatory)][bool]$FailPrompt,
        [bool]$SessionMismatch = $false,
        [bool]$SessionAgentMismatch = $false,
        [bool]$MissingSession = $false,
        [bool]$ProcessLease = $false,
        [bool]$HiddenPrompt = $false,
        [bool]$EnterRetry = $false,
        [bool]$EnterRetryWorking = $false,
        [ValidateSet("active", "empty-then-active", "history-then-active", "history-placeholder", "history-user-input", "wrapped-active", "long-wrapped-active", "delayed-active")][string]$QueuedPromptState = "active",
        [ValidateRange(1000, 5000)][int]$EarlyAlertMs = 4000,
        [Parameter(Mandatory)][string]$Message
    )

    Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
    $env:HERDR_TEST_STATUS = $Status
    $env:HERDR_TEST_FAIL_PROMPT = if ($FailPrompt) { "1" } else { "0" }
    $env:HERDR_TEST_SESSION_MISMATCH = if ($SessionMismatch) { "1" } else { "0" }
    $env:HERDR_TEST_SESSION_AGENT_MISMATCH = if ($SessionAgentMismatch) { "1" } else { "0" }
    $env:HERDR_TEST_MISSING_SESSION = if ($MissingSession) { "1" } else { "0" }
    $env:HERDR_TEST_PROCESS_LEASE = if ($ProcessLease) { "1" } else { "0" }
    $env:HERDR_TEST_HIDDEN_PROMPT = if ($HiddenPrompt) { "1" } else { "0" }
    $env:HERDR_TEST_ENTER_RETRY = if ($EnterRetry) { "1" } else { "0" }
    $env:HERDR_TEST_ENTER_RETRY_WORKING = if ($EnterRetryWorking) { "1" } else { "0" }
    $env:HERDR_TEST_QUEUED_PROMPT_STATE = $QueuedPromptState

    $output = & pwsh -NoProfile -File $helperPath `
        -Action deliver -PaneId "w1:p2" -Message $Message -WatchTimeoutMs 20000 -EarlyAlertMs $EarlyAlertMs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Helper process failed: $($output -join [Environment]::NewLine)"
    }

    return [pscustomobject]@{
        Result = (($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20)
        Calls = @((Get-Content -LiteralPath $logPath) | Where-Object { $_ })
    }
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    @'
@echo off
setlocal EnableDelayedExpansion
if /I "%~3"=="agent" if /I "%~4"=="prompt" goto logPrompt
echo %*>>"%HERDR_TEST_LOG%"
goto logged
:logPrompt
set "promptMessage=%~6"
if /I "%~7"=="--wait" (
  >>"%HERDR_TEST_LOG%" echo(proxy herdr agent prompt %~5 "!promptMessage!" --wait --until working --until blocked --until idle --until done --timeout 7000
) else (
  >>"%HERDR_TEST_LOG%" echo(proxy herdr agent prompt %~5 "!promptMessage!"
)
:logged
if /I "%~1"=="proxy" shift
if /I not "%~1"=="herdr" (
  echo expected herdr as first argument 1>&2
  exit /b 2
)
shift
set "testAgent=codex"
if not "%HERDR_TEST_LIVE_AGENT%"=="" set "testAgent=%HERDR_TEST_LIVE_AGENT%"
set "testSessionAgent=!testAgent!"
if "%HERDR_TEST_SESSION_AGENT_MISMATCH%"=="1" set "testSessionAgent=claude"
if /I "%~1"=="workspace" if /I "%~2"=="list" (
  echo {"id":"test:workspace:list","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w1","label":"Primary"}]}}
  exit /b 0
)
if /I "%~1"=="tab" if /I "%~2"=="list" (
  echo {"id":"test:tab:list","result":{"type":"tab_list","tabs":[{"tab_id":"w1:t9","workspace_id":"w1","label":"Coordination","pane_count":1}]}}
  exit /b 0
)
if /I "%~1"=="pane" if /I "%~2"=="list" (
  echo {"id":"test:pane:list","result":{"type":"pane_list","panes":[{"pane_id":"w1:pJ","workspace_id":"w1","tab_id":"w1:t9","agent":"codex","agent_status":"idle","cwd":"C:\\test"},{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2","agent":"codex","agent_status":"%HERDR_TEST_STATUS%","cwd":"C:\\test"}]}}
  exit /b 0
)
if /I "%~1"=="tab" if /I "%~2"=="get" (
  set "testTabId=%~3"
  set "testTabLabel=#567 - Independent review"
  if /I "!testTabId!"=="w1:t9" set "testTabLabel=Coordination"
  if /I "!testTabId!"=="w1:t3" set "testTabLabel=Explore-CC"
  if /I "!testTabId!"=="w1:t2" if exist "%HERDR_TEST_TAB_STATE%" set /p "testTabLabel="<"%HERDR_TEST_TAB_STATE%"
  echo {"id":"test:tab:get","result":{"type":"tab_info","tab":{"tab_id":"!testTabId!","workspace_id":"w1","label":"!testTabLabel!","pane_count":1}}}
  exit /b 0
)
if /I "%~1"=="tab" if /I "%~2"=="rename" (
  set "newTabLabel=%~4"
  >"%HERDR_TEST_TAB_STATE%" echo(!newTabLabel!
  echo {"id":"test:tab:rename","result":{"type":"tab_renamed","tab_id":"%~3"}}
  exit /b 0
)
if /I "%~1"=="pane" if /I "%~2"=="get" (
  set "testPaneId=%~3"
  set "testTabId=w1:t2"
  if /I "!testPaneId!"=="w1:pJ" set "testTabId=w1:t9"
  if /I "!testPaneId!"=="w1:p2" if not "%HERDR_TEST_PANE_TAB_ID%"=="" set "testTabId=%HERDR_TEST_PANE_TAB_ID%"
  if "%HERDR_TEST_MISSING_SESSION%"=="1" (
    echo {"id":"test:pane:get","result":{"type":"pane_info","pane":{"pane_id":"!testPaneId!","workspace_id":"w1","tab_id":"!testTabId!","terminal_id":"term-test","revision":7,"state_change_seq":17,"agent":"!testAgent!","agent_status":"%HERDR_TEST_STATUS%"}}}
    exit /b 0
  )
  echo {"id":"test:pane:get","result":{"type":"pane_info","pane":{"pane_id":"!testPaneId!","workspace_id":"w1","tab_id":"!testTabId!","terminal_id":"term-test","revision":7,"state_change_seq":17,"agent":"!testAgent!","agent_status":"%HERDR_TEST_STATUS%","agent_session":{"agent":"!testSessionAgent!","value":"session-before"}}}}
  exit /b 0
)
if /I "%~1"=="pane" if /I "%~2"=="process-info" (
  if not "%HERDR_TEST_CALLER_AGENT_PID%"=="" (
    echo {"id":"test:pane:process-info","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4000,"foreground_processes":[{"name":"!testAgent!.exe","pid":%HERDR_TEST_CALLER_AGENT_PID%}]}}}
    exit /b 0
  )
  if "%HERDR_TEST_PROCESS_LEASE%"=="1" (
    echo {"id":"test:pane:process-info","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4000,"foreground_processes":[{"name":"codex.exe","pid":4001}]}}}
  ) else (
    echo {"id":"test:pane:process-info","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":0,"foreground_processes":[]}}}
  )
  exit /b 0
)
if /I "%~1"=="agent" if /I "%~2"=="prompt" (
  if "%HERDR_TEST_FAIL_PROMPT%"=="1" (
    echo agent_prompt_stalled: no lifecycle change observed 1>&2
    exit /b 1
  )
  echo {"id":"test:agent:prompt","result":{"type":"agent_prompted","agent":{"pane_id":"%~3","agent":"codex","agent_status":"%HERDR_TEST_STATUS%"}}}
  exit /b 0
)
if /I "%~1"=="agent" if /I "%~2"=="get" (
  if "%HERDR_TEST_MISSING_SESSION%"=="1" (
    findstr /C:"herdr agent send-keys %~3 Enter" "%HERDR_TEST_LOG%" >nul 2>&1
    if not errorlevel 1 (
      echo {"id":"test:agent:get","result":{"type":"agent_info","agent":{"pane_id":"%~3","workspace_id":"w1","tab_id":"w1:t2","terminal_id":"term-test","revision":7,"state_change_seq":17,"agent":"!testAgent!","agent_status":"working"}}}
    ) else (
      echo {"id":"test:agent:get","result":{"type":"agent_info","agent":{"pane_id":"%~3","workspace_id":"w1","tab_id":"w1:t2","terminal_id":"term-test","revision":7,"state_change_seq":17,"agent":"!testAgent!","agent_status":"%HERDR_TEST_STATUS%"}}}
    )
    exit /b 0
  )
  set "testSession=session-before"
  if "%HERDR_TEST_SESSION_MISMATCH%"=="1" set "testSession=session-after"
  if not "%HERDR_TEST_AGENT_NAME%"=="" (
    findstr /C:"herdr agent rename w1:p2 --clear" "%HERDR_TEST_LOG%" >nul 2>&1
    if errorlevel 1 (
      echo {"id":"test:agent:get","result":{"type":"agent_info","agent":{"pane_id":"%~3","workspace_id":"w1","tab_id":"w1:t2","terminal_id":"term-test","revision":7,"state_change_seq":17,"agent":"!testAgent!","agent_status":"%HERDR_TEST_STATUS%","agent_session":{"agent":"!testSessionAgent!","value":"!testSession!"},"name":"%HERDR_TEST_AGENT_NAME%"}}}
      exit /b 0
    )
  )
  findstr /C:"herdr agent send-keys %~3 Enter" "%HERDR_TEST_LOG%" >nul 2>&1
  if not errorlevel 1 (
    set "postEnterStatus=working"
    if "%HERDR_TEST_ENTER_RETRY%"=="1" set "postEnterStatus=%HERDR_TEST_STATUS%"
    if "%HERDR_TEST_ENTER_RETRY_WORKING%"=="1" set "postEnterStatus=working"
      echo {"id":"test:agent:get","result":{"type":"agent_info","agent":{"pane_id":"%~3","workspace_id":"w1","tab_id":"w1:t2","terminal_id":"term-test","revision":7,"state_change_seq":17,"agent":"!testAgent!","agent_status":"!postEnterStatus!","agent_session":{"agent":"!testSessionAgent!","value":"!testSession!"}}}}
  ) else (
    findstr /C:"herdr agent wait w1:p2 --until idle" "%HERDR_TEST_LOG%" >nul 2>&1
    if not errorlevel 1 (
      echo {"id":"test:agent:get","result":{"type":"agent_info","agent":{"pane_id":"%~3","workspace_id":"w1","tab_id":"w1:t2","terminal_id":"term-test","revision":7,"state_change_seq":17,"agent":"!testAgent!","agent_status":"idle","agent_session":{"agent":"!testSessionAgent!","value":"!testSession!"}}}}
    ) else (
      echo {"id":"test:agent:get","result":{"type":"agent_info","agent":{"pane_id":"%~3","workspace_id":"w1","tab_id":"w1:t2","terminal_id":"term-test","revision":7,"state_change_seq":17,"agent":"!testAgent!","agent_status":"%HERDR_TEST_STATUS%","agent_session":{"agent":"!testSessionAgent!","value":"!testSession!"}}}}
    )
  )
  exit /b 0
)
if /I "%~1"=="agent" if /I "%~2"=="rename" if /I "%~4"=="--clear" (
  echo {"id":"test:agent:rename","result":{"type":"agent_info","agent":{"pane_id":"%~3","workspace_id":"w1","tab_id":"w1:t2","terminal_id":"term-test","revision":7,"agent":"codex","agent_status":"%HERDR_TEST_STATUS%","agent_session":{"agent":"codex","value":"session-before"}}}}
  exit /b 0
)
if /I "%~1"=="agent" if /I "%~2"=="read" (
  findstr /C:"herdr agent send-keys %~3 Enter" "%HERDR_TEST_LOG%" >nul 2>&1
  if not errorlevel 1 (
    if "%HERDR_TEST_ENTER_RETRY%"=="1" (
      for /f %%C in ('findstr /C:"herdr agent send-keys %~3 Enter" "%HERDR_TEST_LOG%" ^| "%SystemRoot%\System32\find.exe" /C /V ""') do set "enterCount=%%C"
      if "!enterCount!"=="1" (
        for /f "usebackq delims=" %%L in (`findstr /C:"herdr agent prompt %~3" "%HERDR_TEST_LOG%"`) do echo ^> %%L
        exit /b 0
      )
    )
    for /f "usebackq delims=" %%L in (`findstr /C:"herdr agent prompt %~3" "%HERDR_TEST_LOG%"`) do echo ^> %%L
    echo ^> newer prompt marker
    exit /b 0
  )
  if "%HERDR_TEST_HIDDEN_PROMPT%"=="1" (
    echo Waiting for 2 background agents to finish
    exit /b 0
  )
  if /I "%HERDR_TEST_QUEUED_PROMPT_STATE%"=="empty-then-active" (
    for /f %%C in ('findstr /C:"herdr agent read w1:p2" "%HERDR_TEST_LOG%" ^| "%SystemRoot%\System32\find.exe" /C /V ""') do set "readCount=%%C"
    if "!readCount!"=="1" exit /b 0
  )
  if /I "%HERDR_TEST_QUEUED_PROMPT_STATE%"=="delayed-active" (
    for /f %%C in ('findstr /C:"herdr agent read w1:p2" "%HERDR_TEST_LOG%" ^| "%SystemRoot%\System32\find.exe" /C /V ""') do set "readCount=%%C"
    if !readCount! LEQ 5 (
      echo processing without a rendered composer
      exit /b 0
    )
  )
  if /I "%HERDR_TEST_QUEUED_PROMPT_STATE%"=="history-then-active" (
    for /f %%C in ('findstr /C:"herdr agent read w1:p2" "%HERDR_TEST_LOG%" ^| "%SystemRoot%\System32\find.exe" /C /V ""') do set "readCount=%%C"
    if "!readCount!"=="1" (
      for /f "usebackq delims=" %%L in (`findstr /C:"herdr agent prompt %~3" "%HERDR_TEST_LOG%"`) do echo ^> %%L
      echo ^> newer prompt marker
      exit /b 0
    )
  )
  if /I "%HERDR_TEST_QUEUED_PROMPT_STATE%"=="history-placeholder" (
    for /f "usebackq delims=" %%L in (`findstr /C:"herdr agent prompt %~3" "%HERDR_TEST_LOG%"`) do echo ^> %%L
    echo ^> Improve documentation in @filename
    exit /b 0
  )
  if /I "%HERDR_TEST_QUEUED_PROMPT_STATE%"=="history-user-input" (
    for /f "usebackq delims=" %%L in (`findstr /C:"herdr agent prompt %~3" "%HERDR_TEST_LOG%"`) do echo ^> %%L
    echo ^> user-authored correction waiting here
    exit /b 0
  )
  if /I "%HERDR_TEST_QUEUED_PROMPT_STATE%"=="wrapped-active" (
    echo ^> earlier queued message
    for /f "usebackq delims=" %%L in (`findstr /C:"herdr agent prompt %~3" "%HERDR_TEST_LOG%"`) do echo   %%L
    exit /b 0
  )
  if /I "%HERDR_TEST_QUEUED_PROMPT_STATE%"=="long-wrapped-active" (
    echo ^> earlier queued message
    for /L %%N in (1,1,40) do echo   wrapped continuation %%N
    if "%~7"=="128" (
      for /f "usebackq delims=" %%L in (`findstr /C:"herdr agent prompt %~3" "%HERDR_TEST_LOG%"`) do echo   %%L
    )
    exit /b 0
  )
  for /f "usebackq delims=" %%L in (`findstr /C:"herdr agent prompt %~3" "%HERDR_TEST_LOG%"`) do echo ^> %%L
  exit /b 0
)
if /I "%~1"=="agent" if /I "%~2"=="send-keys" if /I "%~4"=="Enter" (
  echo {"id":"test:agent:send-keys","result":{"type":"agent_keys_sent","pane_id":"%~3"}}
  exit /b 0
)
if /I "%~1"=="agent" if /I "%~2"=="wait" (
  echo {"id":"test:agent:wait","result":{"type":"agent_waited","agent":{"pane_id":"%~3","agent":"codex","agent_status":"working","agent_session":{"agent":"codex","value":"session-before"}}}}
  exit /b 0
)
if /I "%~1"=="notification" if /I "%~2"=="show" (
  echo {"id":"test:notification:show","result":{"type":"notification_shown"}}
  exit /b 0
)
echo unexpected fake rtk invocation: %* 1>&2
exit /b 2
'@ | Set-Content -LiteralPath $fakeRtkPath -Encoding ascii

    $originalPath = $env:PATH
    $originalHerdrEnv = $env:HERDR_ENV
    $originalTestLog = $env:HERDR_TEST_LOG
    $originalWorkspaceId = $env:HERDR_WORKSPACE_ID
    $originalTabId = $env:HERDR_TAB_ID
    $originalPaneId = $env:HERDR_PANE_ID
    $originalCodexThreadId = $env:CODEX_THREAD_ID
    $originalHerdrAgentSessionId = $env:HERDR_AGENT_SESSION_ID
    try {
        $env:PATH = "$tempRoot;$originalPath"
        $env:HERDR_ENV = "1"
        $env:HERDR_TEST_LOG = $logPath
        $env:HERDR_TEST_TAB_STATE = $tabStatePath
        $env:HERDR_COORDINATION_WATCH_INLINE = "1"
        $env:HERDR_TEST_AGENT_NAME = ""

        Write-Output "CASE: working queued delivery"
        $working = Invoke-DeliveryCase -Status working -FailPrompt $false -Message "working delivery"
        $workingDelivery = $working.Result.delivery
        $workingCalls = $working.Calls -join "`n"
        Assert-True -Condition ([bool]$workingDelivery.submitted) -Message "Working delivery was not submitted. Error: $($workingDelivery.error) Calls: $workingCalls"
        Assert-True -Condition ([bool]$workingDelivery.queued) -Message "Working delivery was not classified as queued."
        Assert-Equal -Actual $workingDelivery.transport -Expected "agent_prompt+queued_watch_enter" -Message "Wrong transport."
        Assert-Equal -Actual $workingDelivery.delivery_state -Expected "accepted_after_queued_enter_recovery" -Message "Wrong working delivery state."
        Assert-True -Condition (-not [bool]$workingDelivery.prompt_waited) -Message "Working delivery must not wait on an unrelated turn."
        Assert-True -Condition ([bool]$workingDelivery.watch_started -and [bool]$workingDelivery.watch_completed) -Message "Working delivery watcher did not complete in the deterministic test mode."
        Assert-True -Condition ([bool]$workingDelivery.enter_recovered) -Message "Working queued delivery did not recover the staged prompt."
        Assert-True -Condition ($workingCalls -match 'herdr agent prompt w1:p2.+\[HC:[0-9a-f]{8}\].+\[ROUTE .+ -> w1:p2 \(#567 - Independent review\)\].+working delivery') -Message "Working delivery did not include the HC token and live pane-label route. Calls: $workingCalls"
        Assert-True -Condition ($workingCalls -notmatch 'agent wait w1:p2 --until idle --until done --until blocked') -Message "Working delivery watcher blocked on availability instead of inspecting the staged prompt."
        Assert-Equal -Actual (@($working.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 1 -Message "Working delivery watcher did not send exactly one Enter."
        Assert-True -Condition ($workingCalls -notmatch 'pane run|pane read') -Message "Working delivery used a legacy pane command."

        Write-Output "CASE: fresh active token with false-positive working state permits one bounded Enter retry"
        $retry = Invoke-DeliveryCase -Status idle -FailPrompt $false -EnterRetry $true -EnterRetryWorking $true -Message "fresh token retry"
        $retryDelivery = $retry.Result.delivery
        $retryCalls = $retry.Calls -join "`n"
        Assert-True -Condition ([bool]$retryDelivery.submitted) -Message "Fresh active token retry was not submitted. Error: $($retryDelivery.error) Calls: $retryCalls"
        Assert-Equal -Actual $retryDelivery.delivery_state -Expected "accepted_after_queued_enter_recovery" -Message "Wrong fresh-token retry delivery state."
        Assert-Equal -Actual ([int]$retryDelivery.recovery_attempts) -Expected 2 -Message "Fresh active token did not report two bounded recovery attempts."
        Assert-Equal -Actual (@($retry.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 2 -Message "Fresh active token retry did not send exactly two bounded Enters."
        Assert-True -Condition ($retryCalls -notmatch 'agent focus|pane run|pane read') -Message "Fresh active token retry used an unsafe focus or legacy pane command."

        Write-Output "CASE: empty detection then active"
        $emptyThenActive = Invoke-DeliveryCase -Status working -FailPrompt $false -QueuedPromptState empty-then-active -Message "empty detection recovery"
        $emptyThenActiveDelivery = $emptyThenActive.Result.delivery
        $emptyThenActiveCalls = $emptyThenActive.Calls -join "`n"
        Assert-Equal -Actual $emptyThenActiveDelivery.delivery_state -Expected "accepted_after_queued_enter_recovery" -Message "An empty detection snapshot crashed or stranded the queued watcher."
        Assert-True -Condition (@($emptyThenActive.Calls | Where-Object { $_ -match 'herdr agent read w1:p2 --source detection --lines 128' }).Count -ge 3) -Message "Watcher did not continue polling after the empty detection snapshot."
        Assert-Equal -Actual (@($emptyThenActive.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 1 -Message "Empty-then-active watcher did not send exactly one Enter."
        Assert-True -Condition ($emptyThenActiveCalls -notmatch 'pane run|pane read|agent focus') -Message "Empty-then-active delivery used UI focus or a legacy pane command."

        Write-Output "CASE: history then active"
        $historyThenActive = Invoke-DeliveryCase -Status working -FailPrompt $false -QueuedPromptState history-then-active -Message "history then active"
        $historyThenActiveDelivery = $historyThenActive.Result.delivery
        $historyThenActiveCalls = $historyThenActive.Calls -join "`n"
        Assert-Equal -Actual $historyThenActiveDelivery.delivery_state -Expected "accepted_after_queued_enter_recovery" -Message "History-before-staging was incorrectly accepted without recovery."
        Assert-Equal -Actual (@($historyThenActive.Calls | Where-Object { $_ -match 'herdr agent read w1:p2 --source detection --lines 128' }).Count) -Expected 3 -Message "Watcher did not keep polling through history, active staging, and post-Enter queue proof."
        Assert-Equal -Actual (@($historyThenActive.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 1 -Message "History-then-active watcher did not send exactly one Enter."
        Assert-True -Condition ($historyThenActiveCalls -notmatch 'pane run|pane read') -Message "History-then-active delivery used a legacy pane command."

        Write-Output "CASE: wrapped active queued token"
        $wrapped = Invoke-DeliveryCase -Status working -FailPrompt $false -QueuedPromptState wrapped-active -Message "wrapped active delivery"
        $wrappedDelivery = $wrapped.Result.delivery
        $wrappedCalls = $wrapped.Calls -join "`n"
        Assert-Equal -Actual $wrappedDelivery.delivery_state -Expected "accepted_after_queued_enter_recovery" -Message "A token on an active composer continuation line was not recovered."
        Assert-Equal -Actual (@($wrapped.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 1 -Message "Wrapped active delivery did not send exactly one Enter."
        Assert-True -Condition ($wrappedCalls -match 'herdr agent read w1:p2 --source detection --lines 128') -Message "Wrapped active delivery did not inspect the expanded detection window."

        Write-Output "CASE: long wrapped active queued token"
        $longWrapped = Invoke-DeliveryCase -Status working -FailPrompt $false -QueuedPromptState long-wrapped-active -Message "second queued token after long wrapped message"
        $longWrappedDelivery = $longWrapped.Result.delivery
        $longWrappedCalls = $longWrapped.Calls -join "`n"
        Assert-Equal -Actual $longWrappedDelivery.delivery_state -Expected "accepted_after_queued_enter_recovery" -Message "A token beyond the old 24-line window was not recovered."
        Assert-Equal -Actual (@($longWrapped.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 1 -Message "Long wrapped delivery did not send exactly one Enter."
        Assert-True -Condition ($longWrappedCalls -match 'herdr agent read w1:p2 --source detection --lines 128') -Message "Long wrapped delivery did not use the expanded detection window."

        Write-Output "CASE: healthy working queue suppresses early alert before delayed active recovery"
        $delayedActive = Invoke-DeliveryCase -Status working -FailPrompt $false -QueuedPromptState delayed-active -EarlyAlertMs 1000 -Message "delayed active delivery"
        $delayedActiveDelivery = $delayedActive.Result.delivery
        $delayedActiveCalls = $delayedActive.Calls -join "`n"
        Assert-Equal -Actual $delayedActiveDelivery.delivery_state -Expected "accepted_after_queued_enter_recovery" -Message "Delayed active delivery did not recover."
        Assert-True -Condition (-not [bool]$delayedActiveDelivery.early_alert_sent) -Message "Healthy working queue emitted a false early alert."
        Assert-Equal -Actual (@($delayedActive.Calls | Where-Object { $_ -match 'herdr notification show "?Cross-talk delivery stalled' }).Count) -Expected 0 -Message "Healthy working queue emitted a stalled popup before becoming available."
        Assert-Equal -Actual (@($delayedActive.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 1 -Message "Delayed active delivery did not send exactly one Enter after the token became active."

        Write-Output "CASE: asynchronous watcher does not convert hard prompt failure into submitted"
        $env:HERDR_COORDINATION_WATCH_INLINE = "0"
        $asyncPromptFailure = Invoke-DeliveryCase -Status idle -FailPrompt $true -Message "async prompt failure"
        Assert-True -Condition (-not [bool]$asyncPromptFailure.Result.delivery.submitted) -Message "Hard prompt failure was reported submitted merely because a watcher started."
        Assert-True -Condition ([bool]$asyncPromptFailure.Result.delivery.watch_started) -Message "Hard prompt failure lost asynchronous watcher ownership."
        Assert-Equal -Actual $asyncPromptFailure.Result.delivery.delivery_state -Expected "pending_watch_after_prompt_error" -Message "Hard prompt failure did not remain pending on its watcher."
        $env:HERDR_COORDINATION_WATCH_INLINE = "1"

        Write-Output "CASE: idle delivery"
        $idle = Invoke-DeliveryCase -Status idle -FailPrompt $false -Message "idle delivery"
        $idleDelivery = $idle.Result.delivery
        $idleCalls = $idle.Calls -join "`n"
        Assert-True -Condition ([bool]$idleDelivery.submitted) -Message "Idle delivery was not submitted."
        Assert-True -Condition (-not [bool]$idleDelivery.queued) -Message "Idle delivery was incorrectly classified as queued."
        Assert-True -Condition ([bool]$idleDelivery.prompt_waited) -Message "Idle delivery did not request lifecycle verification."
        Assert-True -Condition ([bool]$idleDelivery.watch_started) -Message "Idle delivery did not retain proof-bound watcher ownership."
        Assert-Equal -Actual $idleDelivery.delivery_state -Expected "accepted_after_queued_enter_recovery" -Message "Idle false-positive prompt receipt was not recovered."
        Assert-Equal -Actual (@($idle.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 1 -Message "Idle false-positive prompt receipt did not send exactly one proof-bound Enter."
        Assert-True -Condition ($idleCalls -match 'agent prompt.+--wait.+--until working.+--until blocked.+--until idle.+--until done.+--timeout 7000') -Message "Idle delivery did not use the bounded lifecycle wait."

        Write-Output "CASE: expected native-session delivery proof"
        Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
        $expectedOutput = & pwsh -NoProfile -File $helperPath `
            -Action deliver `
            -PaneId "w1:p2" `
            -Message "session-bound delivery" `
            -ExpectedAgent "codex" `
            -ExpectedSession "session-before" 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Matching expected-session delivery failed."
        $expectedResult = ($expectedOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-True -Condition ([bool]$expectedResult.delivery.submitted) -Message "Matching expected-session delivery was not submitted."

        Write-Output "CASE: changed expected native-session refusal"
        Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
        $wrongExpectedOutput = & pwsh -NoProfile -File $helperPath `
            -Action deliver `
            -PaneId "w1:p2" `
            -Message "must not reach replacement session" `
            -ExpectedAgent "codex" `
            -ExpectedSession "session-replaced" 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Changed expected session was accepted."
        Assert-True -Condition (($wrongExpectedOutput -join [Environment]::NewLine) -match "no longer hosts the expected native agent session") -Message "Changed expected-session refusal was not explained."
        $wrongExpectedCalls = (Get-Content -LiteralPath $logPath) -join "`n"
        Assert-True -Condition ($wrongExpectedCalls -notmatch "agent prompt") -Message "Changed expected session received a prompt."

        Write-Output "CASE: tracked Enter recovery"
        $recovered = Invoke-DeliveryCase -Status idle -FailPrompt $true -Message "recovered delivery"
        $recoveredDelivery = $recovered.Result.delivery
        $recoveredCalls = $recovered.Calls -join "`n"
        Assert-True -Condition ([bool]$recoveredDelivery.submitted) -Message "Stalled prompt was not recovered. Error: $($recoveredDelivery.error) Calls: $recoveredCalls"
        Assert-True -Condition ([bool]$recoveredDelivery.enter_recovered) -Message "Recovered delivery did not report tracked Enter recovery."
        Assert-Equal -Actual $recoveredDelivery.transport -Expected "agent_prompt+tracked_enter" -Message "Wrong recovery transport."
        Assert-Equal -Actual $recoveredDelivery.delivery_state -Expected "accepted_after_enter_recovery" -Message "Wrong recovery delivery state."
        Assert-True -Condition ($recoveredCalls -match 'herdr agent get w1:p2') -Message "Recovery did not inspect the explicit agent target."
        Assert-True -Condition ($recoveredCalls -match 'herdr agent read w1:p2 --source detection --lines 128') -Message "Recovery did not inspect the expanded detection buffer."
        Assert-Equal -Actual (@($recovered.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 1 -Message "Recovery did not send exactly one Enter."
        Assert-True -Condition ($recoveredCalls -match 'herdr agent wait w1:p2 --until working --until blocked --timeout 7000') -Message "Recovery did not verify a lifecycle transition."
        Assert-True -Condition ($recoveredCalls -notmatch 'pane run|pane read') -Message "Recovery used UI focus or a legacy pane command."

        Write-Output "CASE: stalled receipt history then active render"
        $renderRace = Invoke-DeliveryCase -Status idle -FailPrompt $true -QueuedPromptState history-then-active -Message "render race recovery"
        $renderRaceDelivery = $renderRace.Result.delivery
        $renderRaceCalls = $renderRace.Calls -join "`n"
        Assert-True -Condition ([bool]$renderRaceDelivery.submitted) -Message "Render-race prompt was not recovered. Error: $($renderRaceDelivery.error) Calls: $renderRaceCalls"
        Assert-Equal -Actual $renderRaceDelivery.delivery_state -Expected "accepted_after_enter_recovery" -Message "Wrong render-race recovery state."
        Assert-True -Condition ([bool]$renderRaceDelivery.enter_recovered) -Message "Render-race delivery did not report tracked Enter recovery."
        Assert-True -Condition (@($renderRace.Calls | Where-Object { $_ -match 'herdr agent read w1:p2 --source detection --lines 128' }).Count -ge 2) -Message "Render-race recovery did not poll through history to the active composer."
        Assert-Equal -Actual (@($renderRace.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 1 -Message "Render-race recovery did not send exactly one Enter."

        Write-Output "CASE: stalled fresh token in history with empty placeholder recovery"
        $historyPlaceholder = Invoke-DeliveryCase -Status idle -FailPrompt $true -QueuedPromptState history-placeholder -Message "history placeholder recovery"
        $historyPlaceholderDelivery = $historyPlaceholder.Result.delivery
        Assert-True -Condition ([bool]$historyPlaceholderDelivery.submitted) -Message "Fresh history token with an empty placeholder was stranded. Error: $($historyPlaceholderDelivery.error)"
        Assert-Equal -Actual $historyPlaceholderDelivery.transport -Expected "agent_prompt+receipt_enter" -Message "Wrong history-placeholder recovery transport."
        Assert-Equal -Actual $historyPlaceholderDelivery.delivery_state -Expected "accepted_after_receipt_enter_recovery" -Message "Wrong history-placeholder recovery state."
        Assert-Equal -Actual (@($historyPlaceholder.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 1 -Message "History-placeholder recovery did not send exactly one Enter."

        Write-Output "CASE: stalled history token refuses different user-authored prompt"
        $historyUserInput = Invoke-DeliveryCase -Status idle -FailPrompt $true -QueuedPromptState history-user-input -Message "must not submit another prompt"
        $historyUserInputDelivery = $historyUserInput.Result.delivery
        Assert-True -Condition (-not [bool]$historyUserInputDelivery.submitted) -Message "History recovery submitted different user-authored prompt text."
        Assert-True -Condition ([string]$historyUserInputDelivery.error -match "different user-authored text") -Message "User-authored prompt refusal was not explained."
        Assert-Equal -Actual (@($historyUserInput.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 0 -Message "History recovery sent Enter into user-authored text."

        Write-Output "CASE: hidden composer receipt-bound Enter recovery"
        $hiddenComposer = Invoke-DeliveryCase -Status idle -FailPrompt $true -HiddenPrompt $true -Message "hidden composer delivery"
        $hiddenComposerDelivery = $hiddenComposer.Result.delivery
        $hiddenComposerCalls = $hiddenComposer.Calls -join "`n"
        Assert-True -Condition ([bool]$hiddenComposerDelivery.submitted) -Message "Receipt-bound recovery did not submit the hidden prompt. Error: $($hiddenComposerDelivery.error) Calls: $hiddenComposerCalls"
        Assert-Equal -Actual $hiddenComposerDelivery.transport -Expected "agent_prompt+receipt_enter" -Message "Wrong hidden-composer recovery transport."
        Assert-Equal -Actual $hiddenComposerDelivery.delivery_state -Expected "accepted_after_receipt_enter_recovery" -Message "Wrong hidden-composer recovery state."
        Assert-Equal -Actual (@($hiddenComposer.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 1 -Message "Hidden-composer recovery did not send exactly one Enter."
        Assert-True -Condition ($hiddenComposerCalls -match 'herdr agent wait w1:p2 --until working --until blocked --timeout 7000') -Message "Hidden-composer recovery did not verify a lifecycle transition."
        Assert-True -Condition ($hiddenComposerCalls -notmatch 'pane run|pane read|agent focus') -Message "Hidden-composer recovery used UI focus or a legacy pane command."

        Write-Output "CASE: hidden blocked prompt refuses receipt-bound Enter"
        $hiddenBlocked = Invoke-DeliveryCase -Status blocked -FailPrompt $true -HiddenPrompt $true -Message "blocked hidden composer"
        $hiddenBlockedDelivery = $hiddenBlocked.Result.delivery
        $hiddenBlockedCalls = $hiddenBlocked.Calls -join "`n"
        Assert-True -Condition (-not [bool]$hiddenBlockedDelivery.submitted) -Message "Receipt-bound recovery submitted into a blocked agent UI."
        Assert-Equal -Actual $hiddenBlockedDelivery.delivery_state -Expected "failed" -Message "Wrong blocked hidden-composer recovery state."
        Assert-True -Condition ($hiddenBlockedCalls -notmatch 'agent send-keys') -Message "Receipt-bound recovery sent Enter to a blocked agent."

        Write-Output "CASE: changed native session refusal"
        $refused = Invoke-DeliveryCase -Status idle -FailPrompt $true -SessionMismatch $true -Message "refused delivery"
        $refusedDelivery = $refused.Result.delivery
        $refusedCalls = $refused.Calls -join "`n"
        Assert-True -Condition (-not [bool]$refusedDelivery.submitted) -Message "Session-mismatched recovery was reported as submitted."
        Assert-Equal -Actual $refusedDelivery.delivery_state -Expected "failed" -Message "Wrong refused delivery state."
        Assert-True -Condition ([string]$refusedDelivery.error -match 'native agent session changed') -Message "Session mismatch refusal was not explained. Error: $($refusedDelivery.error)"
        Assert-True -Condition ($refusedCalls -notmatch 'agent send-keys') -Message "Session-mismatched recovery sent a key."

        Write-Output "CASE: wrong session-agent refusal"
        $wrongAgent = Invoke-DeliveryCase -Status idle -FailPrompt $true -SessionAgentMismatch $true -Message "wrong session agent"
        $wrongAgentDelivery = $wrongAgent.Result.delivery
        $wrongAgentCalls = $wrongAgent.Calls -join "`n"
        Assert-True -Condition (-not [bool]$wrongAgentDelivery.submitted) -Message "Agent-kind-mismatched recovery was reported as submitted."
        Assert-True -Condition ([string]$wrongAgentDelivery.error -match 'matching native (?:agent )?session proof') -Message "Agent-kind mismatch refusal was not explained. Error: $($wrongAgentDelivery.error)"
        Assert-True -Condition ($wrongAgentCalls -notmatch 'agent send-keys') -Message "Agent-kind-mismatched recovery sent a key."

        Write-Output "CASE: missing native session refusal"
        $missingSession = Invoke-DeliveryCase -Status idle -FailPrompt $true -MissingSession $true -Message "missing native session"
        $missingSessionDelivery = $missingSession.Result.delivery
        $missingSessionCalls = $missingSession.Calls -join "`n"
        Assert-True -Condition (-not [bool]$missingSessionDelivery.submitted) -Message "Missing-session recovery was reported as submitted."
        Assert-Equal -Actual $missingSessionDelivery.delivery_state -Expected "failed" -Message "Wrong missing-session delivery state."
        Assert-True -Condition ([string]$missingSessionDelivery.error -match 'matching native (?:agent )?session proof') -Message "Missing-session refusal was not explained. Error: $($missingSessionDelivery.error)"
        Assert-True -Condition ($missingSessionCalls -notmatch 'agent send-keys') -Message "Missing-session recovery sent a key."

        Write-Output "CASE: accepted working queue without session proof"
        $unwatchedQueue = Invoke-DeliveryCase -Status working -FailPrompt $false -MissingSession $true -Message "accepted but unwatched queue"
        $unwatchedQueueDelivery = $unwatchedQueue.Result.delivery
        $unwatchedQueueCalls = $unwatchedQueue.Calls -join "`n"
        Assert-True -Condition (-not [bool]$unwatchedQueueDelivery.submitted) -Message "Accepted-but-unwatched working queue was reported as submitted."
        Assert-True -Condition ([bool]$unwatchedQueueDelivery.queued) -Message "Accepted-but-unwatched working delivery did not preserve queued=true."
        Assert-Equal -Actual $unwatchedQueueDelivery.delivery_state -Expected "failed" -Message "Wrong accepted-but-unwatched delivery state."
        Assert-True -Condition (-not [bool]$unwatchedQueueDelivery.watch_started) -Message "Missing-session working queue reported a watcher."
        Assert-True -Condition ([string]$unwatchedQueueDelivery.error -match 'matching native (?:agent )?session proof') -Message "Accepted-but-unwatched failure was not explained. Error: $($unwatchedQueueDelivery.error)"
        Assert-True -Condition ($unwatchedQueueCalls -notmatch 'agent send-keys') -Message "Accepted-but-unwatched queue sent a key."

        Write-Output "CASE: stable agent-process lease recovery"
        $processLeaseQueue = Invoke-DeliveryCase -Status working -FailPrompt $false -MissingSession $true -ProcessLease $true -Message "process lease queue"
        $processLeaseDelivery = $processLeaseQueue.Result.delivery
        $processLeaseCalls = $processLeaseQueue.Calls -join "`n"
        Assert-True -Condition ([bool]$processLeaseDelivery.submitted) -Message "Stable process-lease queue was not submitted. Error: $($processLeaseDelivery.error)"
        Assert-Equal -Actual $processLeaseDelivery.delivery_state -Expected "accepted_after_queued_enter_recovery" -Message "Wrong process-lease delivery state."
        Assert-Equal -Actual (@($processLeaseQueue.Calls | Where-Object { $_ -match 'herdr agent send-keys w1:p2 Enter' }).Count) -Expected 1 -Message "Process-lease recovery did not send exactly one Enter."
        Assert-True -Condition ($processLeaseCalls -match 'herdr pane process-info --pane w1:p2') -Message "Process-lease recovery did not verify the explicit pane process."
        Assert-True -Condition ($processLeaseCalls -notmatch 'pane run|pane read') -Message "Process-lease recovery used UI focus or a legacy pane command."

        Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
        Remove-Item -LiteralPath $tabStatePath -Force -ErrorAction SilentlyContinue
        $env:HERDR_TEST_STATUS = "idle"
        $env:HERDR_TEST_FAIL_PROMPT = "0"
        $env:HERDR_TEST_SESSION_MISMATCH = "0"
        $env:HERDR_TEST_SESSION_AGENT_MISMATCH = "0"
        $env:HERDR_TEST_MISSING_SESSION = "0"
        $env:HERDR_TEST_PROCESS_LEASE = "0"
        $longRelay = "long relay fixture " + ("X" * 2500)
        Write-Output "CASE: compact coordinator relay"
        $sendOutput = & pwsh -NoProfile -File $helperPath `
            -Action send -To coordinator -Message $longRelay -LogPath $coordLogPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Send helper process failed: $($sendOutput -join [Environment]::NewLine)"
        }
        $sendResult = (($sendOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20)
        $sendCalls = @((Get-Content -LiteralPath $logPath) | Where-Object { $_ })
        $sendPromptCall = @($sendCalls | Where-Object { $_ -match 'herdr agent prompt w1:pJ' } | Select-Object -Last 1)[0]
        $coordLogText = Get-Content -LiteralPath $coordLogPath -Raw
        Assert-True -Condition ([bool]$sendResult.delivered -and [bool]$sendResult.delivery.submitted) -Message "Compact coordinator relay notice was not submitted."
        Assert-True -Condition ([bool]$sendResult.notice_submitted -and -not [bool]$sendResult.body_read) -Message "Coordinator relay conflated pointer submission with body consumption."
        Assert-Equal -Actual $sendResult.delivery_scope -Expected "pointer_only" -Message "Coordinator relay omitted pointer-only delivery scope."
        Assert-True -Condition ([bool]$sendResult.read_ack_required) -Message "Coordinator relay did not require a body-read acknowledgement."
        Assert-True -Condition ([string]$sendResult.relay_ref -match '^\[HR:[0-9a-f]{8}\]$') -Message "Coordinator relay did not return a durable HR reference."
        Assert-True -Condition ($sendPromptCall -match '\[ROUTE .+ -> w1:pJ \(Coordination\)\].+COORDINATION LOG NOTICE \[HR:[0-9a-f]{8}\]') -Message "Coordinator prompt did not contain the labeled compact log notice. Call: $sendPromptCall"
        Assert-True -Condition ($sendPromptCall.Length -lt 1000 -and $sendPromptCall -notmatch ('X' * 200)) -Message "Coordinator prompt included the long durable relay body."
        Assert-True -Condition ($sendPromptCall -match "ack-read.+RelayRef.+\[HR:[0-9a-f]{8}\]") -Message "Coordinator pointer did not instruct the recipient to prove body consumption."
        Assert-True -Condition ($sendPromptCall -match 'immediately execute the instructions in the relay body as your current task; the ACK is a receipt, not completion; do not end your turn after ACKing') -Message "Coordinator pointer did not instruct the recipient to continue into the relay body after ACKing."
        Assert-True -Condition ($coordLogText.Contains([string]$sendResult.relay_ref) -and $coordLogText.Contains("X" * 2000)) -Message "Durable coordination log did not retain the full relay body and HR reference."

        Write-Output "CASE: explicit-pane send routes directly with readable labels"
        Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
        $directOutput = & pwsh -NoProfile -File $helperPath `
            -Action send `
            -From "w1:pN" `
            -To "w1:p2" `
            -ExpectedTabLabel "#567 - Independent review" `
            -Message "w1:pJ accepted workflow for w1:p2 and started work." `
            -LogPath $coordLogPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Direct send helper process failed: $($directOutput -join [Environment]::NewLine)"
        }
        $directResult = (($directOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20)
        $directCalls = @((Get-Content -LiteralPath $logPath) | Where-Object { $_ })
        $directPromptCall = @($directCalls | Where-Object { $_ -match 'herdr agent prompt w1:p2' } | Select-Object -Last 1)[0]
        $directEntry = [string]$directResult.entry
        Assert-True -Condition ([bool]$directResult.delivered -and [bool]$directResult.delivery.submitted) -Message "Explicit-pane send was not delivered."
        Assert-Equal -Actual $directResult.recipient_pane_id -Expected "w1:p2" -Message "Explicit-pane send targeted the wrong pane."
        Assert-True -Condition ($null -eq $directResult.coordinator_pane_id) -Message "Explicit-pane send incorrectly depended on the coordinator."
        Assert-True -Condition ($directPromptCall -match '\[ROUTE w1:pN \(#567 - Independent review\) -> w1:p2 \(#567 - Independent review\)\]') -Message "Direct prompt omitted source/target tab labels."
        Assert-True -Condition (($directCalls -join "`n") -notmatch 'herdr agent prompt w1:pJ') -Message "Explicit-pane send was misrouted through the coordinator."
        Assert-True -Condition ($directEntry -match 'FROM w1:pN TO w1:p2: \[HR:[0-9a-f]{8}\] \[ROUTE w1:pN \(#567 - Independent review\) -> w1:p2 \(#567 - Independent review\)\] \[RECIPIENT-PANE w1:p2\]') -Message "Durable direct entry omitted its labeled route or stable recipient metadata."
        Assert-True -Condition ($directEntry -match 'w1:pJ \(Coordination\) accepted workflow for w1:p2 \(#567 - Independent review\)') -Message "Bare pane references in the durable message were not labeled."

        Write-Output "CASE: workflow relay pointer selects workflow-aware read receipt"
        Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
        $workflowRelayOutput = & pwsh -NoProfile -File $helperPath `
            -Action send `
            -From "w1:pN" `
            -To "w1:p2" `
            -ExpectedTabLabel "#567 - Independent review" `
            -ExpectedAgent "codex" `
            -ExpectedSession "session-before" `
            -WorkflowRef "[WF:ab12cd34]" `
            -WorkflowLedgerPath "C:\tmp\fixture-ledger.jsonl" `
            -Message "Workflow completion verdict body." `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Workflow-aware relay send failed."
        $workflowRelayCalls = @((Get-Content -LiteralPath $logPath) | Where-Object { $_ })
        $workflowRelayPrompt = @($workflowRelayCalls | Where-Object { $_ -match 'herdr agent prompt w1:p2' } | Select-Object -Last 1)[0]
        Assert-True -Condition ($workflowRelayPrompt -match 'herdr_workflow\.ps1.+-Action ack-return.+\[WF:ab12cd34\].+fixture-ledger\.jsonl') -Message "Workflow relay pointer did not name the single workflow-aware read receipt."
        Assert-True -Condition ($workflowRelayPrompt -notmatch '-Action ack-read') -Message "Workflow relay pointer exposed two competing read-receipt commands."

        Write-Output "CASE: relay status distinguishes notice from body read"
        $statusBeforeOutput = & pwsh -NoProfile -File $helperPath `
            -Action relay-status `
            -RelayRef ([string]$directResult.relay_ref) `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Pre-ack relay status failed."
        $statusBefore = ($statusBeforeOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-True -Condition (-not [bool]$statusBefore.body_read) -Message "A submitted pointer was incorrectly reported as a read body."

        Add-Content -LiteralPath $coordLogPath -Value "- [2026-07-31 12:00 -06:00] FROM w1:p9 TO w1:pN: quoted later reference [re $($directResult.relay_ref)] is not a receipt"
        $quotedStatusOutput = & pwsh -NoProfile -File $helperPath `
            -Action relay-status `
            -RelayRef ([string]$directResult.relay_ref) `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Relay status failed after a textual reference."
        $quotedStatus = ($quotedStatusOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-True -Condition (-not [bool]$quotedStatus.body_read) -Message "A later textual relay reference was misclassified as a read receipt."

        Write-Output "CASE: native-session relay read acknowledgement is durable and idempotent"
        $env:HERDR_WORKSPACE_ID = "w1"
        $env:HERDR_TAB_ID = "w1:t2"
        $env:HERDR_PANE_ID = "w1:p2"
        $env:CODEX_THREAD_ID = "session-before"
        $env:HERDR_AGENT_SESSION_ID = "session-before"
        $env:HERDR_AGENT_SESSION_ID = "session-before"
        $env:HERDR_TEST_CALLER_AGENT_PID = "$PID"

        Write-Output "CASE: copied environment/session metadata without process binding cannot acknowledge"
        Remove-Item Env:HERDR_TEST_CALLER_AGENT_PID -ErrorAction SilentlyContinue
        $unboundLineCount = @(Get-Content -LiteralPath $coordLogPath).Count
        $unboundOutput = & pwsh -NoProfile -File $helperPath `
            -Action ack-read `
            -RelayRef ([string]$directResult.relay_ref) `
            -LogPath $coordLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Environment-only caller forged a relay read acknowledgement."
        Assert-True -Condition (($unboundOutput -join [Environment]::NewLine) -match 'not process-bound') -Message "Environment-only read refusal was not explained."
        Assert-Equal -Actual @(Get-Content -LiteralPath $coordLogPath).Count -Expected $unboundLineCount -Message "Environment-only read attempt mutated the log."
        $env:HERDR_TEST_CALLER_AGENT_PID = "$PID"

        Write-Output "CASE: tracked relay payload tampering fails before read receipt"
        $tamperLogPath = Join-Path $tempRoot "tampered-coordination.md"
        $tamperSendOutput = & pwsh -NoProfile -File $helperPath `
            -Action send `
            -From "w1:p2" `
            -To "w1:p2" `
            -ExpectedTabLabel "#567 - Independent review" `
            -ExpectedAgent "codex" `
            -ExpectedSession "session-before" `
            -Message "immutable tracked payload" `
            -LogPath $tamperLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Tamper fixture send failed."
        $tamperSend = ($tamperSendOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        $tamperedText = (Get-Content -LiteralPath $tamperLogPath -Raw).Replace("immutable tracked payload", "altered tracked payload")
        Set-Content -LiteralPath $tamperLogPath -Value $tamperedText -NoNewline -Encoding utf8
        $tamperLineCount = @(Get-Content -LiteralPath $tamperLogPath).Count
        $tamperAckOutput = & pwsh -NoProfile -File $helperPath `
            -Action ack-read `
            -RelayRef ([string]$tamperSend.relay_ref) `
            -LogPath $tamperLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Tampered tracked relay was acknowledged."
        Assert-True -Condition (($tamperAckOutput -join [Environment]::NewLine) -match 'invalid payload hash') -Message "Tampered relay refusal was not explained."
        Assert-Equal -Actual @(Get-Content -LiteralPath $tamperLogPath).Count -Expected $tamperLineCount -Message "Tampered relay acknowledgement mutated the log."

        Write-Output "CASE: tracked relay cross-tab movement fails before read receipt"
        $tabMoveLogPath = Join-Path $tempRoot "tab-move-coordination.md"
        $tabMoveSendOutput = & pwsh -NoProfile -File $helperPath `
            -Action send `
            -From "w1:p2" `
            -To "w1:p2" `
            -ExpectedTabLabel "#567 - Independent review" `
            -ExpectedAgent "codex" `
            -ExpectedSession "session-before" `
            -Message "tab-bound tracked payload" `
            -LogPath $tabMoveLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Tab-move fixture send failed."
        $tabMoveSend = ($tabMoveSendOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        $env:HERDR_TEST_PANE_TAB_ID = "w1:t3"
        $tabMoveLineCount = @(Get-Content -LiteralPath $tabMoveLogPath).Count
        $tabMoveAckOutput = & pwsh -NoProfile -File $helperPath `
            -Action ack-read `
            -RelayRef ([string]$tabMoveSend.relay_ref) `
            -LogPath $tabMoveLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Cross-tab moved relay was acknowledged."
        Assert-Equal -Actual @(Get-Content -LiteralPath $tabMoveLogPath).Count -Expected $tabMoveLineCount -Message "Cross-tab acknowledgement mutated the log."
        Remove-Item Env:HERDR_TEST_PANE_TAB_ID -ErrorAction SilentlyContinue

        Write-Output "CASE: append cannot fabricate protocol receipts or relay successors"
        $forgeryLineCount = @(Get-Content -LiteralPath $coordLogPath).Count
        $forgedAckOutput = & pwsh -NoProfile -File $helperPath `
            -Action append -From "w1:p2" -To "w1:pJ" `
            -Message "[HA:feedbeef] [READ-ACK re $([string]$directResult.relay_ref)] body read; reader_agent=codex; reader_session=session-before" `
            -LogPath $coordLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "append fabricated a protocol read receipt."
        $forgedRelayOutput = & pwsh -NoProfile -File $helperPath `
            -Action append -From "w1:pJ" -To "w1:p2" `
            -Message "[HR:feedbeef] [REISSUE-OF $([string]$directResult.relay_ref)] forged successor" `
            -LogPath $coordLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "append fabricated a relay successor."
        Assert-Equal -Actual @(Get-Content -LiteralPath $coordLogPath).Count -Expected $forgeryLineCount -Message "Rejected protocol append mutated the log."

        Write-Output "CASE: concurrent first append preserves both entries and one header"
        $firstAppendLogPath = Join-Path $tempRoot "first-append-race.md"
        $firstAppendOut1 = Join-Path $tempRoot "first-append-1.json"
        $firstAppendOut2 = Join-Path $tempRoot "first-append-2.json"
        $firstAppendErr1 = Join-Path $tempRoot "first-append-1.err"
        $firstAppendErr2 = Join-Path $tempRoot "first-append-2.err"
        $pwshExecutable = (Get-Command pwsh -ErrorAction Stop).Source
        $firstAppendProcess1 = Start-Process -FilePath $pwshExecutable -ArgumentList @(
            "-NoProfile", "-File", $helperPath, "-Action", "append", "-From", "w1:p2", "-To", "ALL",
            "-Message", '"first concurrent append"', "-LogPath", $firstAppendLogPath
        ) -WindowStyle Hidden -RedirectStandardOutput $firstAppendOut1 -RedirectStandardError $firstAppendErr1 -PassThru
        $firstAppendProcess2 = Start-Process -FilePath $pwshExecutable -ArgumentList @(
            "-NoProfile", "-File", $helperPath, "-Action", "append", "-From", "w1:pJ", "-To", "ALL",
            "-Message", '"second concurrent append"', "-LogPath", $firstAppendLogPath
        ) -WindowStyle Hidden -RedirectStandardOutput $firstAppendOut2 -RedirectStandardError $firstAppendErr2 -PassThru
        Assert-True -Condition ($firstAppendProcess1.WaitForExit(30000) -and $firstAppendProcess2.WaitForExit(30000)) -Message "Concurrent first append processes timed out."
        $firstAppendProcess1.Refresh()
        $firstAppendProcess2.Refresh()
        $firstAppendErrors = ((Get-Content -LiteralPath $firstAppendErr1 -Raw -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $firstAppendErr2 -Raw -ErrorAction SilentlyContinue))
        Assert-Equal -Actual $firstAppendProcess1.ExitCode -Expected 0 -Message "First concurrent initial append failed: $firstAppendErrors"
        Assert-Equal -Actual $firstAppendProcess2.ExitCode -Expected 0 -Message "Second concurrent initial append failed: $firstAppendErrors"
        $firstAppendText = Get-Content -LiteralPath $firstAppendLogPath -Raw
        Assert-Equal -Actual ([regex]::Matches($firstAppendText, '(?m)^# Herdr Coordination Log\r?$')).Count -Expected 1 -Message "Concurrent initialization duplicated or lost the header."
        Assert-Equal -Actual ([regex]::Matches($firstAppendText, 'first concurrent append')).Count -Expected 1 -Message "Concurrent initialization lost the first entry."
        Assert-Equal -Actual ([regex]::Matches($firstAppendText, 'second concurrent append')).Count -Expected 1 -Message "Concurrent initialization lost the second entry."

        Write-Output "CASE: route-first legacy relay remains acknowledgement-compatible"
        $legacyRelayRef = "[HR:ab12cd34]"
        Add-Content -LiteralPath $coordLogPath -Value "- [2026-07-31 12:01 -06:00] FROM w1:pN TO w1:p2: [ROUTE w1:pN (#567 - Independent review) -> w1:p2 (#567 - Independent review)] $legacyRelayRef [RECIPIENT-PANE w1:p2] legacy route-first relay"
        $legacyAckOutput = & pwsh -NoProfile -File $helperPath `
            -Action ack-read `
            -RelayRef $legacyRelayRef `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Route-first legacy relay acknowledgement failed: $($legacyAckOutput -join [Environment]::NewLine)"
        $legacyAck = ($legacyAckOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-True -Condition ([bool]$legacyAck.body_read -and -not [bool]$legacyAck.duplicate) -Message "Route-first legacy relay was not acknowledged."

        $ackOutput = & pwsh -NoProfile -File $helperPath `
            -Action ack-read `
            -RelayRef ([string]$directResult.relay_ref) `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Session-bound read acknowledgement failed: $($ackOutput -join [Environment]::NewLine)"
        $ackResult = ($ackOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-True -Condition ([bool]$ackResult.body_read -and -not [bool]$ackResult.duplicate) -Message "First read acknowledgement was not recorded."
        Assert-True -Condition ([string]$ackResult.read_ack.ack_ref -match '^\[HA:[0-9a-f]{8}\]$') -Message "Read acknowledgement lacked a durable HA reference."

        $statusAfterOutput = & pwsh -NoProfile -File $helperPath `
            -Action relay-status `
            -RelayRef ([string]$directResult.relay_ref) `
            -LogPath $coordLogPath 2>&1
        $statusAfter = ($statusAfterOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-True -Condition ([bool]$statusAfter.body_read) -Message "Relay status did not observe the durable read acknowledgement."
        Assert-Equal -Actual $statusAfter.read_ack.reader_session -Expected "session-before" -Message "Read status lost native-session provenance."

        $ackLineCount = @(Get-Content -LiteralPath $coordLogPath).Count
        $duplicateAckOutput = & pwsh -NoProfile -File $helperPath `
            -Action ack-read `
            -RelayRef ([string]$directResult.relay_ref) `
            -LogPath $coordLogPath 2>&1
        $duplicateDebugLines = @((Get-Content -LiteralPath $coordLogPath) | Where-Object { $_ -match [regex]::Escape([string]$directResult.relay_ref) })
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Idempotent read acknowledgement retry failed: $($duplicateAckOutput -join [Environment]::NewLine); prior_status=$($statusAfter | ConvertTo-Json -Compress -Depth 10); lines=$($duplicateDebugLines -join ' || ')"
        $duplicateAck = ($duplicateAckOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-True -Condition ([bool]$duplicateAck.duplicate) -Message "Repeated read acknowledgement was not identified as idempotent."
        Assert-Equal -Actual @(Get-Content -LiteralPath $coordLogPath).Count -Expected $ackLineCount -Message "Idempotent read acknowledgement appended a duplicate entry."

        Write-Output "CASE: native-session rotation creates an exact lineage-bound replacement"
        $rotationMessage = "rotation-safe payload for w1:pJ (Coordination)`r`nsecond durable line"
        $rotationPayload = "rotation-safe payload for w1:pJ (Coordination) second durable line"
        $rotationPayloadBytes = [Text.Encoding]::UTF8.GetBytes($rotationPayload)
        $rotationSha = [Security.Cryptography.SHA256]::HashData($rotationPayloadBytes)
        $rotationPayloadHash = ([BitConverter]::ToString($rotationSha) -replace '-', '').ToLowerInvariant()
        $rotationLabelBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("#567 - Independent review"))
        $rotationSendOutput = & pwsh -NoProfile -File $helperPath `
            -Action send `
            -From "w1:p2" `
            -To "w1:p2" `
            -ExpectedTabLabel "#567 - Independent review" `
            -ExpectedAgent "codex" `
            -ExpectedSession "session-before" `
            -Message $rotationMessage `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Rotation-safe self-send fixture failed."
        $rotationSend = ($rotationSendOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        $rotationOriginalRef = [string]$rotationSend.relay_ref
        Assert-True -Condition ([string]$rotationSend.entry -match ([regex]::Escape($rotationPayload))) -Message "Multiline relay payload was not normalized to the durable one-line form."
        $env:HERDR_TEST_SESSION_MISMATCH = "1"
        # Compaction can refresh Herdr's native-session registry while the
        # already-running agent process still exposes its inherited old hint.
        $env:CODEX_THREAD_ID = "session-before"
        $env:HERDR_AGENT_SESSION_ID = "session-before"
        $rotationAckOutput = & pwsh -NoProfile -File $helperPath `
            -Action ack-read `
            -RelayRef $rotationOriginalRef `
            -ExpectedSession "session-before" `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Safe session-rotation acknowledgement failed: $($rotationAckOutput -join [Environment]::NewLine)"
        $rotationAck = ($rotationAckOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-True -Condition ([bool]$rotationAck.body_read -and [bool]$rotationAck.session_rotated) -Message "Session rotation did not prove replacement-body consumption."
        Assert-True -Condition ([bool]$rotationAck.replacement_created) -Message "Session rotation did not create a replacement relay."
        Assert-Equal -Actual $rotationAck.requested_relay_ref -Expected $rotationOriginalRef -Message "Session rotation lost the original relay lineage."
        Assert-True -Condition ([string]$rotationAck.relay_ref -match '^\[HR:[0-9a-f]{8}\]$' -and [string]$rotationAck.relay_ref -ne $rotationOriginalRef) -Message "Session rotation did not return a distinct replacement relay."
        Assert-Equal -Actual $rotationAck.read_ack.reader_session -Expected "session-after" -Message "Replacement ACK was not bound to the new native session."
        Assert-True -Condition (-not [bool]$rotationAck.reader.session_hint_matches) -Message "Rotation fixture did not exercise the stale caller-session hint."
        $rotationLogText = Get-Content -LiteralPath $coordLogPath -Raw
        Assert-True -Condition ($rotationLogText -match "\[REISSUE-OF $([regex]::Escape($rotationOriginalRef))\]") -Message "Replacement relay omitted its immutable lineage reference."
        Assert-True -Condition ($rotationLogText -match '\[RECIPIENT-AGENT codex\].+\[RECIPIENT-TAB w1:t2\].+\[RECIPIENT-LABEL-B64 [A-Za-z0-9+/=]+\].+\[PAYLOAD-SHA256 [0-9a-f]{64}\]') -Message "Rotation-safe relay metadata was not recorded."

        $rotationStatusOutput = & pwsh -NoProfile -File $helperPath `
            -Action relay-status `
            -RelayRef $rotationOriginalRef `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Rotated relay status failed."
        $rotationStatus = ($rotationStatusOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-True -Condition (-not [bool]$rotationStatus.body_read -and [bool]$rotationStatus.superseded) -Message "Original relay was mutated or not marked superseded."
        Assert-True -Condition ([bool]$rotationStatus.effective_body_read) -Message "Rotated relay status did not expose effective body consumption."
        Assert-Equal -Actual $rotationStatus.effective_relay_ref -Expected $rotationAck.relay_ref -Message "Rotated relay status resolved the wrong successor."

        $rotationLineCount = @(Get-Content -LiteralPath $coordLogPath).Count
        $rotationRetryOutput = & pwsh -NoProfile -File $helperPath `
            -Action ack-read `
            -RelayRef $rotationOriginalRef `
            -ExpectedSession "session-before" `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Rotated relay idempotent retry failed."
        $rotationRetry = ($rotationRetryOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-True -Condition ([bool]$rotationRetry.duplicate -and [bool]$rotationRetry.session_rotated) -Message "Rotated relay retry was not idempotent."
        Assert-Equal -Actual @(Get-Content -LiteralPath $coordLogPath).Count -Expected $rotationLineCount -Message "Rotated relay retry appended duplicate lineage or ACK entries."

        Write-Output "CASE: concurrent rotation ACKs create one successor and one receipt"
        $env:CODEX_THREAD_ID = "session-after"
        $env:HERDR_AGENT_SESSION_ID = "session-after"
        $concurrentSendOutput = & pwsh -NoProfile -File $helperPath `
            -Action send `
            -From "w1:p2" `
            -To "w1:p2" `
            -ExpectedTabLabel "#567 - Independent review" `
            -ExpectedAgent "codex" `
            -ExpectedSession "session-before" `
            -Message "concurrent rotation payload" `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Concurrent rotation fixture send failed."
        $concurrentSend = ($concurrentSendOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        $concurrentRef = [string]$concurrentSend.relay_ref
        $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
        $concurrentOut1 = Join-Path $tempRoot "concurrent-ack-1.json"
        $concurrentOut2 = Join-Path $tempRoot "concurrent-ack-2.json"
        $concurrentErr1 = Join-Path $tempRoot "concurrent-ack-1.err"
        $concurrentErr2 = Join-Path $tempRoot "concurrent-ack-2.err"
        $concurrentArguments = @(
            "-NoProfile", "-File", $helperPath,
            "-Action", "ack-read",
            "-RelayRef", $concurrentRef,
            "-ExpectedSession", "session-before",
            "-LogPath", $coordLogPath
        )
        $concurrentProcess1 = Start-Process -FilePath $pwshPath -ArgumentList $concurrentArguments -WindowStyle Hidden -RedirectStandardOutput $concurrentOut1 -RedirectStandardError $concurrentErr1 -PassThru
        $concurrentProcess2 = Start-Process -FilePath $pwshPath -ArgumentList $concurrentArguments -WindowStyle Hidden -RedirectStandardOutput $concurrentOut2 -RedirectStandardError $concurrentErr2 -PassThru
        Assert-True -Condition ($concurrentProcess1.WaitForExit(30000) -and $concurrentProcess2.WaitForExit(30000)) -Message "Concurrent rotation ACK processes did not finish within 30 seconds."
        $concurrentProcess1.Refresh()
        $concurrentProcess2.Refresh()
        $concurrentErrorText = ((Get-Content -LiteralPath $concurrentErr1 -Raw -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $concurrentErr2 -Raw -ErrorAction SilentlyContinue))
        Assert-Equal -Actual $concurrentProcess1.ExitCode -Expected 0 -Message "First concurrent ACK failed: $concurrentErrorText"
        Assert-Equal -Actual $concurrentProcess2.ExitCode -Expected 0 -Message "Second concurrent ACK failed: $concurrentErrorText"
        $concurrentResults = @(
            (Get-Content -LiteralPath $concurrentOut1 -Raw | ConvertFrom-Json -Depth 20),
            (Get-Content -LiteralPath $concurrentOut2 -Raw | ConvertFrom-Json -Depth 20)
        )
        Assert-Equal -Actual @($concurrentResults | Where-Object { [bool]$_.duplicate }).Count -Expected 1 -Message "Concurrent ACKs did not produce exactly one idempotent duplicate."
        Assert-Equal -Actual @($concurrentResults | Where-Object { -not [bool]$_.duplicate }).Count -Expected 1 -Message "Concurrent ACKs did not produce exactly one first receipt."
        Assert-Equal -Actual @($concurrentResults | Select-Object -ExpandProperty relay_ref -Unique).Count -Expected 1 -Message "Concurrent ACKs resolved different successor relays."
        $concurrentStatusOutput = & pwsh -NoProfile -File $helperPath -Action relay-status -RelayRef $concurrentRef -LogPath $coordLogPath 2>&1
        $concurrentStatus = ($concurrentStatusOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-Equal -Actual @($concurrentStatus.replacement_relay_refs).Count -Expected 1 -Message "Concurrent ACKs created multiple successor relays."
        Assert-True -Condition ([bool]$concurrentStatus.effective_body_read) -Message "Concurrent ACK successor has no durable read receipt."

        Write-Output "CASE: Claude tool shell without session env uses exact process-bound rotation proof"
        $claudeRotationRef = "[HR:de45fa67]"
        Add-Content -LiteralPath $coordLogPath -Value "- [2026-07-31 12:03 -06:00] FROM w1:pN TO w1:p2: $claudeRotationRef [ROUTE w1:pN (#567 - Independent review) -> w1:p2 (#567 - Independent review)] [RECIPIENT-PANE w1:p2] [RECIPIENT-SESSION session-before] [RECIPIENT-AGENT claude] [RECIPIENT-TAB w1:t2] [RECIPIENT-LABEL-B64 $rotationLabelBase64] [PAYLOAD-SHA256 $rotationPayloadHash] $rotationPayload"
        $env:HERDR_TEST_LIVE_AGENT = "claude"
        Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_AGENT_SESSION_ID -ErrorAction SilentlyContinue
        $claudeRotationOutput = & pwsh -NoProfile -File $helperPath `
            -Action ack-read `
            -RelayRef $claudeRotationRef `
            -ExpectedSession "session-before" `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Process-bound Claude rotation ACK failed: $($claudeRotationOutput -join [Environment]::NewLine)"
        $claudeRotation = ($claudeRotationOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-True -Condition ([bool]$claudeRotation.body_read -and [bool]$claudeRotation.session_rotated) -Message "Claude rotation did not produce a successor receipt."
        Assert-Equal -Actual $claudeRotation.reader.agent -Expected "claude" -Message "Claude rotation resolved the wrong live agent type."
        Assert-True -Condition ([bool]$claudeRotation.reader.caller_process_bound) -Message "Claude rotation was not bound to the live pane agent process."
        Assert-Equal -Actual $claudeRotation.read_ack.reader_session -Expected "session-after" -Message "Claude rotation ACK lost the hook-reported live session."
        $env:HERDR_TEST_LIVE_AGENT = "codex"
        $env:CODEX_THREAD_ID = "session-before"
        $env:HERDR_AGENT_SESSION_ID = "session-before"

        Write-Output "CASE: legacy relay rotation remains fail-closed"
        $legacyRotationRef = "[HR:bc23de45]"
        Add-Content -LiteralPath $coordLogPath -Value "- [2026-07-31 12:02 -06:00] FROM w1:pN TO w1:p2: $legacyRotationRef [RECIPIENT-PANE w1:p2] [RECIPIENT-SESSION session-before] legacy rotation payload"
        $legacyRotationLineCount = @(Get-Content -LiteralPath $coordLogPath).Count
        $legacyRotationOutput = & pwsh -NoProfile -File $helperPath `
            -Action ack-read `
            -RelayRef $legacyRotationRef `
            -ExpectedSession "session-before" `
            -LogPath $coordLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Legacy relay without rotation-safe metadata was rebound."
        Assert-True -Condition (($legacyRotationOutput -join [Environment]::NewLine) -match 'predates rotation-safe metadata') -Message "Legacy rotation refusal was not explained."
        Assert-Equal -Actual @(Get-Content -LiteralPath $coordLogPath).Count -Expected $legacyRotationLineCount -Message "Legacy rotation refusal mutated the log."

        $env:HERDR_TEST_SESSION_MISMATCH = "0"
        Remove-Item Env:HERDR_TEST_CALLER_AGENT_PID -ErrorAction SilentlyContinue
        $env:CODEX_THREAD_ID = "session-before"
        $env:HERDR_AGENT_SESSION_ID = "session-before"

        Write-Output "CASE: relay read acknowledgement refuses wrong pane and missing session proof"
        $env:HERDR_PANE_ID = "w1:pJ"
        $wrongReaderOutput = & pwsh -NoProfile -File $helperPath `
            -Action ack-read `
            -RelayRef ([string]$directResult.relay_ref) `
            -LogPath $coordLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Wrong-pane reader acknowledged the relay."
        Assert-True -Condition (($wrongReaderOutput -join [Environment]::NewLine) -match 'belongs to w1:p2') -Message "Wrong-pane read refusal was not explained."
        $env:HERDR_PANE_ID = "w1:p2"
        $env:HERDR_TEST_MISSING_SESSION = "1"
        $missingReaderOutput = & pwsh -NoProfile -File $helperPath `
            -Action ack-read `
            -RelayRef ([string]$directResult.relay_ref) `
            -LogPath $coordLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Reader without native-session proof acknowledged the relay."
        Assert-True -Condition (($missingReaderOutput -join [Environment]::NewLine) -match 'native agent-session proof') -Message "Missing-session read refusal was not explained."
        $env:HERDR_TEST_MISSING_SESSION = "0"
        $env:HERDR_AGENT_SESSION_ID = $originalHerdrAgentSessionId

        Write-Output "CASE: explicit-pane send requires expected stable label before HR creation"
        Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
        $coordLineCount = @(Get-Content -LiteralPath $coordLogPath).Count
        $missingLabelOutput = & pwsh -NoProfile -File $helperPath `
            -Action send `
            -From "w1:pJ" `
            -To "w1:p2" `
            -Message "role-bearing dispatch without a label assertion" `
            -LogPath $coordLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Explicit-pane send without -ExpectedTabLabel was accepted."
        Assert-True -Condition (($missingLabelOutput -join [Environment]::NewLine) -match "ExpectedTabLabel") -Message "Missing-label refusal was not explained."
        Assert-Equal -Actual @(Get-Content -LiteralPath $coordLogPath).Count -Expected $coordLineCount -Message "Missing-label refusal created an HR/log entry."
        Assert-True -Condition (((Get-Content -LiteralPath $logPath) -join "`n") -notmatch "agent prompt|agent send-keys") -Message "Missing-label refusal touched transport."

        Write-Output "CASE: wrong pane with same agent type fails before log and transport"
        Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
        Set-Content -LiteralPath $tabStatePath -Value "Explore-CC" -Encoding ascii
        $coordLineCount = @(Get-Content -LiteralPath $coordLogPath).Count
        $wrongLabelOutput = & pwsh -NoProfile -File $helperPath `
            -Action send `
            -From "w1:pJ" `
            -To "w1:p2" `
            -ExpectedAgent "codex" `
            -ExpectedSession "session-before" `
            -ExpectedTabLabel "AGENT CC R" `
            -Message "FINAL I3 restricted reviewer dispatch" `
            -LogPath $coordLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Same-agent wrong-label pane was accepted."
        Assert-True -Condition (($wrongLabelOutput -join [Environment]::NewLine) -match "expected 'AGENT CC R', observed 'Explore-CC'") -Message "Wrong-label refusal did not identify both labels."
        Assert-Equal -Actual @(Get-Content -LiteralPath $coordLogPath).Count -Expected $coordLineCount -Message "Wrong-label refusal created an HR/log entry."
        Assert-True -Condition (((Get-Content -LiteralPath $logPath) -join "`n") -notmatch "agent prompt|agent send-keys") -Message "Wrong-label refusal touched transport."

        Write-Output "CASE: matching stable label plus agent-session proof succeeds"
        Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
        Set-Content -LiteralPath $tabStatePath -Value "AGENT CC R" -Encoding ascii
        $matchingLabelOutput = & pwsh -NoProfile -File $helperPath `
            -Action send `
            -From "w1:pJ" `
            -To "w1:p2" `
            -ExpectedAgent "codex" `
            -ExpectedSession "session-before" `
            -ExpectedTabLabel "AGENT CC R" `
            -Message "FINAL I3 restricted reviewer dispatch" `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Matching label/agent/session dispatch failed."
        $matchingLabelResult = ($matchingLabelOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-True -Condition ([bool]$matchingLabelResult.delivered -and [bool]$matchingLabelResult.delivery.submitted) -Message "Matching label/agent/session dispatch was not delivered."
        Assert-True -Condition (((Get-Content -LiteralPath $logPath) -join "`n") -match "agent prompt w1:p2") -Message "Matching stable-label dispatch did not reach transport."

        Write-Output "CASE: live tab-swap race fails closed"
        Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
        Remove-Item -LiteralPath $tabStatePath -Force -ErrorAction SilentlyContinue
        $env:HERDR_TEST_PANE_TAB_ID = "w1:t3"
        $coordLineCount = @(Get-Content -LiteralPath $coordLogPath).Count
        $tabSwapOutput = & pwsh -NoProfile -File $helperPath `
            -Action send `
            -From "w1:pJ" `
            -To "w1:p2" `
            -ExpectedAgent "codex" `
            -ExpectedSession "session-before" `
            -ExpectedTabLabel "AGENT CC R" `
            -Message "must not follow a pane into a different tab" `
            -LogPath $coordLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Tab-swapped pane was accepted."
        Assert-True -Condition (($tabSwapOutput -join [Environment]::NewLine) -match "expected 'AGENT CC R', observed 'Explore-CC'") -Message "Tab-swap refusal was not explained."
        Assert-Equal -Actual @(Get-Content -LiteralPath $coordLogPath).Count -Expected $coordLineCount -Message "Tab-swap refusal created an HR/log entry."
        Assert-True -Condition (((Get-Content -LiteralPath $logPath) -join "`n") -notmatch "agent prompt|agent send-keys") -Message "Tab-swap refusal touched transport."
        Remove-Item Env:HERDR_TEST_PANE_TAB_ID -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_CALLER_AGENT_PID -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_LIVE_AGENT -ErrorAction SilentlyContinue

        Write-Output "CASE: ambiguous send recipient fails closed"
        $coordLineCount = @(Get-Content -LiteralPath $coordLogPath).Count
        $ambiguousOutput = & pwsh -NoProfile -File $helperPath `
            -Action send `
            -From "w1:pN" `
            -To "ALL" `
            -Message "must use append" `
            -LogPath $coordLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Ambiguous send recipient was accepted."
        Assert-True -Condition (($ambiguousOutput -join [Environment]::NewLine) -match "explicit pane ID") -Message "Ambiguous send refusal was not explained."
        Assert-Equal -Actual @(Get-Content -LiteralPath $coordLogPath).Count -Expected $coordLineCount -Message "Rejected ambiguous send mutated the durable log."

        Write-Output "CASE: self rename is disabled in favor of coordinator-owned naming"
        Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
        $env:HERDR_TEST_STATUS = "idle"
        $env:HERDR_TEST_FAIL_PROMPT = "0"
        $env:HERDR_TEST_SESSION_MISMATCH = "0"
        $env:HERDR_TEST_SESSION_AGENT_MISMATCH = "0"
        $env:HERDR_TEST_MISSING_SESSION = "0"
        $env:HERDR_TEST_AGENT_NAME = "issue-579-publish"
        $env:HERDR_WORKSPACE_ID = "w1"
        $env:HERDR_TAB_ID = "w1:t2"
        $env:HERDR_PANE_ID = "w1:p2"
        $env:CODEX_THREAD_ID = "session-before"
        $renameOutput = & pwsh -NoProfile -File $helperPath `
            -Action rename-current -Label "#578 - Build" 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Self rename unexpectedly succeeded."
        $renameCalls = @((Get-Content -LiteralPath $logPath) | Where-Object { $_ })
        Assert-True -Condition (($renameOutput -join [Environment]::NewLine) -match 'PANE NAMING REQUEST') -Message "Self-rename refusal did not direct the pane to Coordination."
        Assert-True -Condition (($renameCalls -join "`n") -notmatch 'agent rename|tab rename') -Message "Rejected self rename mutated agent or tab metadata."
        $env:HERDR_TEST_MISSING_SESSION = "0"

        Write-Output "CASE: validated name-request emits one coordinator relay"
        Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
        Remove-Item Env:HERDR_TEST_CALLER_AGENT_PID -ErrorAction SilentlyContinue
        $unboundNameLineCount = @(Get-Content -LiteralPath $coordLogPath).Count
        $unboundNameRequest = & pwsh -NoProfile -File $helperPath `
            -Action name-request -From "w1:p2" -RepoCode AGT -LaneCode T -RoleCode R `
            -WorkKind issue -IssueNumber 828 -WorkTitle "must not relay" -LogPath $coordLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Process-unbound name-request was accepted."
        Assert-True -Condition (($unboundNameRequest -join [Environment]::NewLine) -match 'not process-bound') -Message "Process-unbound name-request refusal was not explained."
        Assert-Equal -Actual @(Get-Content -LiteralPath $coordLogPath).Count -Expected $unboundNameLineCount -Message "Process-unbound name-request created a relay."
        $env:HERDR_TEST_CALLER_AGENT_PID = "$PID"
        $nameRequestOutput = & pwsh -NoProfile -File $helperPath `
            -Action name-request `
            -From "w1:p2" `
            -RepoCode AGT `
            -LaneCode T `
            -RoleCode R `
            -WorkKind issue `
            -IssueNumber 828 `
            -WorkTitle "UserForm diagnostic coordinate mapping" `
            -PreviousName "AGT-T-R1" `
            -PreviousWork "#829" `
            -WatchTimeoutMs 20000 `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Validated name-request failed: $($nameRequestOutput -join [Environment]::NewLine)"
        $nameRequest = ($nameRequestOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 32
        Assert-Equal -Actual $nameRequest.action -Expected "name-request" -Message "Name-request action was not reported."
        Assert-True -Condition ([string]$nameRequest.request -match 'issue=#828') -Message "Name-request did not normalize the issue number."
        Assert-True -Condition ([string]$nameRequest.request -match 'lifecycle=assignment') -Message "Ordinary name-request did not declare assignment lifecycle."
        Assert-True -Condition ([string]$nameRequest.request -match 'requester_pane=w1:p2') -Message "Name-request lost requester pane provenance."
        Assert-True -Condition ([string]$nameRequest.request -match 'requester_tab=w1:t2') -Message "Name-request lost requester tab provenance."
        Assert-True -Condition ([string]$nameRequest.request -match 'requester_agent=codex') -Message "Name-request lost requester agent provenance."
        Assert-True -Condition ([string]$nameRequest.request -match 'requester_session=session-before') -Message "Name-request lost requester session provenance."
        Assert-True -Condition ([string]$nameRequest.request -match 'previous_work=#829') -Message "Name-request lost the redirect provenance."
        Assert-True -Condition ([string]$nameRequest.request -match 'coordinator_action=apply-name-and-return-proof') -Message "Name-request did not require coordinator application proof."
        Assert-True -Condition ([string]$nameRequest.request -match 'coordinator_command=consume-name-requests') -Message "Name-request did not require the coordinator consumer command."
        Assert-True -Condition ([string]$nameRequest.request -match 'routing_gate=continue-by-stable-pane-id-while-pending') -Message "Name-request did not declare asynchronous stable-ID routing."
        $nameRequestLog = (Get-Content -LiteralPath $coordLogPath) -join "`n"
        Assert-True -Condition ($nameRequestLog -match 'PANE NAMING REQUEST: repo=AGT; lifecycle=assignment; requester_pane=w1:p2; requester_tab=w1:t2') -Message "Name-request body/provenance was missing or pane-label enrichment corrupted its machine fields."

        $invalidNameRequest = & pwsh -NoProfile -File $helperPath `
            -Action name-request -From "w1:p2" -RepoCode AGT -LaneCode T -RoleCode R `
            -WorkKind issue -IssueNumber 828 -WorkTitle "bad`nvalue" -LogPath $coordLogPath 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message "Newline-bearing name-request was accepted."

        Write-Output "CASE: retirement name-request declares terminal close gate"
        Set-Content -LiteralPath $logPath -Value "" -Encoding utf8
        Set-Content -LiteralPath $coordLogPath -Value "" -Encoding utf8
        $retirementRequestOutput = & pwsh -NoProfile -File $helperPath `
            -Action name-request -NamingLifecycle retirement -From "w1:p2" `
            -RepoCode AGT -LaneCode T -RoleCode R -WorkKind issue -IssueNumber 828 `
            -WorkTitle "retired" -PreviousName "AGT-T-R1" -PreviousWork "#828 · completed" `
            -WatchTimeoutMs 20000 `
            -LogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Retirement name-request failed: $($retirementRequestOutput -join [Environment]::NewLine)"
        $retirementRequest = ($retirementRequestOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 32
        Assert-True -Condition ([string]$retirementRequest.request -match 'lifecycle=retirement') -Message "Retirement lifecycle marker was missing."
        Assert-True -Condition ([string]$retirementRequest.request -match 'close_gate=wait-for-applied-or-retirement_target_gone') -Message "Retirement close gate was missing."
        Assert-True -Condition ([string]$retirementRequest.request -match 'previous_name=AGT-T-R1') -Message "Retirement previous identity was missing."
        $retirementRequestLog = (Get-Content -LiteralPath $coordLogPath) -join "`n"
        Assert-True -Condition ($retirementRequestLog -match 'lifecycle=retirement; requester_pane=w1:p2; requester_tab=w1:t2') -Message "Retirement relay provenance was corrupted during nested send."

        Write-Output "CASE: large-log relay lineage lookup remains bounded"
        $largeLogPath = Join-Path $tempRoot "coordination-large.md"
        $largePayload = "bounded lineage lookup payload"
        $largeHashBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($largePayload))
        $largeHash = ([BitConverter]::ToString($largeHashBytes) -replace '-', '').ToLowerInvariant()
        $largeLabel = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("#567 - Independent review"))
        $largeRelayRef = "[HR:face0001]"
        $largeLines = [Collections.Generic.List[string]]::new()
        $largeLines.Add("- [2026-07-31 12:10 -06:00] FROM w1:pN TO w1:p2: $largeRelayRef [RECIPIENT-PANE w1:p2] [RECIPIENT-SESSION session-before] [RECIPIENT-AGENT codex] [RECIPIENT-TAB w1:t2] [RECIPIENT-LABEL-B64 $largeLabel] [PAYLOAD-SHA256 $largeHash] $largePayload")
        for ($index = 1; $index -le 2000; $index++) {
            $decoyRef = "[HR:$($index.ToString('x8'))]"
            $largeLines.Add("- [2026-07-31 12:11 -06:00] FROM w1:p8 TO w1:p9: $decoyRef [RECIPIENT-PANE w1:p9] decoy-$index")
        }
        Set-Content -LiteralPath $largeLogPath -Value $largeLines -Encoding utf8
        $largeLookupWatch = [Diagnostics.Stopwatch]::StartNew()
        $largeStatusOutput = & pwsh -NoProfile -File $helperPath `
            -Action relay-status `
            -RelayRef $largeRelayRef `
            -LogPath $largeLogPath 2>&1
        $largeLookupWatch.Stop()
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Large-log relay status failed: $($largeStatusOutput -join [Environment]::NewLine)"
        $largeStatus = ($largeStatusOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
        Assert-Equal -Actual $largeStatus.effective_relay_ref -Expected $largeRelayRef -Message "Large-log status resolved a false successor."
        Assert-True -Condition ($largeLookupWatch.ElapsedMilliseconds -lt 5000) -Message "Large-log relay lookup regressed beyond five seconds: $($largeLookupWatch.ElapsedMilliseconds) ms."

        Write-Output "PASS: herdr-coordination agent prompt transport"
    }
    finally {
        $env:PATH = $originalPath
        $env:HERDR_ENV = $originalHerdrEnv
        $env:HERDR_TEST_LOG = $originalTestLog
        $env:HERDR_WORKSPACE_ID = $originalWorkspaceId
        $env:HERDR_TAB_ID = $originalTabId
        $env:HERDR_PANE_ID = $originalPaneId
        $env:CODEX_THREAD_ID = $originalCodexThreadId
        $env:HERDR_AGENT_SESSION_ID = $originalHerdrAgentSessionId
        Remove-Item Env:HERDR_TEST_STATUS -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_FAIL_PROMPT -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_SESSION_MISMATCH -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_SESSION_AGENT_MISMATCH -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_MISSING_SESSION -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_PROCESS_LEASE -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_HIDDEN_PROMPT -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_QUEUED_PROMPT_STATE -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_AGENT_NAME -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_TAB_STATE -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_PANE_TAB_ID -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_COORDINATION_WATCH_INLINE -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workflowPath = Join-Path $PSScriptRoot "herdr_workflow.ps1"
$watchdogPath = Join-Path $PSScriptRoot "herdr_workflow_watchdog.ps1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-workflow-test-$([Guid]::NewGuid().ToString('N'))"
$isWindowsPlatform = [IO.Path]::DirectorySeparatorChar -eq [char]92
$fakeRtkPath = Join-Path $tempRoot $(if ($isWindowsPlatform) { "rtk.cmd" } else { "rtk" })
$fakeCoordPath = Join-Path $tempRoot "coord.ps1"
$callLogPath = Join-Path $tempRoot "calls.jsonl"
$ledgerPath = Join-Path $tempRoot "ledger.jsonl"
$watchLogPath = Join-Path $tempRoot "watch.md"
$coordLogPath = Join-Path $tempRoot "coordination.md"
$reconcileArtifactPath = Join-Path $tempRoot "reconcile-review.md"
$wrongArtifactPath = Join-Path $tempRoot "wrong-review.md"
$completionArtifactPath = Join-Path $tempRoot "completion-review.md"
$returnRetryArtifactPath = Join-Path $tempRoot "return-retry-review.md"

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

function Invoke-Workflow {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$ExpectFailure
    )

    $output = & pwsh -NoProfile -File $workflowPath @Arguments `
        -LedgerPath $ledgerPath `
        -WatchLogPath $watchLogPath `
        -CoordinationLogPath $coordLogPath `
        -CoordinationHelperPath $fakeCoordPath 2>&1
    $exitCode = $LASTEXITCODE
    if ($ExpectFailure) {
        Assert-True -Condition ($exitCode -ne 0) -Message "Workflow command unexpectedly succeeded."
        return [pscustomobject]@{
            ExitCode = $exitCode
            Text = $output -join [Environment]::NewLine
        }
    }
    if ($exitCode -ne 0) {
        throw "Workflow command failed: $($output -join [Environment]::NewLine)"
    }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 30)
}

function Get-Calls {
    if (-not (Test-Path -LiteralPath $callLogPath)) {
        return @()
    }
    return @(Get-Content -LiteralPath $callLogPath |
        Where-Object { $_ -match '^\s*\{' } |
        ForEach-Object { $_ | ConvertFrom-Json -Depth 10 })
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    if ($isWindowsPlatform) {
    @'
@echo off
setlocal EnableDelayedExpansion
echo %*>>"%HERDR_TEST_CALL_LOG%"
if /I "%~1"=="proxy" shift
if /I not "%~1"=="herdr" exit /b 2
shift
if /I "%~1"=="pane" if /I "%~2"=="get" (
  if "%HERDR_TEST_PERMISSION_DENIED%"=="1" (
    echo {"id":"test:pane:get","error":{"code":"PermissionDenied","message":"PermissionDenied: native pane access unavailable"}}
    exit /b 1
  )
  set "paneCwd=C:\dev\stmodel"
  if /I "%~3"=="w2:p1" set "paneCwd=C:\dev\Codex\Herder"
  if not "%HERDR_TEST_PANE_CWD%"=="" set "paneCwd=%HERDR_TEST_PANE_CWD%"
  set "paneForeground=!paneCwd!"
  if not "%HERDR_TEST_PANE_FOREGROUND_CWD%"=="" set "paneForeground=%HERDR_TEST_PANE_FOREGROUND_CWD%"
  echo {"id":"test:pane:get","result":{"type":"pane_info","pane":{"pane_id":"%~3","workspace_id":"w1","tab_id":"w1:t2","terminal_id":"term-test","cwd":"!paneCwd!","foreground_cwd":"!paneForeground!","label":"%HERDR_TEST_PANE_LABEL%"}}}
  exit /b 0
)
if /I "%~1"=="agent" if /I "%~2"=="get" if not "%HERDR_TEST_PANE_SUBTITLE%"=="" (
  set "namedSession=session-target"
  if /I "%~3"=="w2:p1" set "namedSession=session-source"
  set "profileFields="
  if "%HERDR_TEST_PROFILE%"=="1" set "profileFields=,"provider":"openai","model":"luna-max","reasoning_effort":"max","service_tier":"priority""
  if "%HERDR_TEST_PROFILE_MISMATCH%"=="1" set "profileFields=,"provider":"anthropic","model":"terra","reasoning_effort":"xhigh","service_tier":"standard""
  if "%HERDR_TEST_PROFILE_MALFORMED%"=="1" set "profileFields=,"provider":"openai","model":{"name":"luna-max"},"reasoning_effort":"max","service_tier":"priority""
  if "%HERDR_TEST_TARGET_SESSION_ROTATED%"=="1" if /I "%~3"=="w1:p2" set "namedSession=session-replaced"
  set "agentKind=codex"
  if not "%HERDR_TEST_AGENT_KIND%"=="" set "agentKind=%HERDR_TEST_AGENT_KIND%"
  set "agentCwd=%HERDR_TEST_AGENT_CWD%"
  set "testTabId=w1:t2"
  if not "%HERDR_TEST_TARGET_TAB_ID%"=="" if /I "%~3"=="w1:p2" set "testTabId=%HERDR_TEST_TARGET_TAB_ID%"
  echo {"id":"test:agent:get","result":{"type":"agent_info","agent":{"pane_id":"%~3","workspace_id":"w1","tab_id":"!testTabId!","terminal_id":"term-test","revision":7,"state_change_seq":42,"agent":"!agentKind!","agent_status":"%HERDR_TEST_STATUS%","cwd":"!agentCwd!","title":"%HERDR_TEST_PANE_SUBTITLE%","display_agent":"%HERDR_TEST_PANE_SUBTITLE%","agent_session":{"agent":"!agentKind!","value":"!namedSession!"}!profileFields!}}}
  exit /b 0
)
if /I "%~1"=="agent" if /I "%~2"=="get" (
  set "testSession=session-target"
  if /I "%~3"=="w2:p1" set "testSession=session-source"
  if "%HERDR_TEST_TARGET_SESSION_ROTATED%"=="1" if /I "%~3"=="w1:p2" set "testSession=session-replaced"
  if /I "%~3"=="w2:p1" if "%HERDR_TEST_SOURCE_SESSION_MISMATCH%"=="1" set "testSession=session-replaced"
  set "agentKind=codex"
  if not "%HERDR_TEST_AGENT_KIND%"=="" set "agentKind=%HERDR_TEST_AGENT_KIND%"
  set "agentCwd=%HERDR_TEST_AGENT_CWD%"
  if "%HERDR_TEST_MISSING_SESSION%"=="1" (
    echo {"id":"test:agent:get","result":{"type":"agent_info","agent":{"pane_id":"%~3","workspace_id":"w1","tab_id":"w1:t2","terminal_id":"term-test","revision":7,"state_change_seq":42,"agent":"!agentKind!","agent_status":"%HERDR_TEST_STATUS%","cwd":"!agentCwd!"}}}
  ) else (
    set "profileFields="
    if "%HERDR_TEST_PROFILE%"=="1" set "profileFields=,"provider":"openai","model":"luna-max","reasoning_effort":"max","service_tier":"priority""
    if "%HERDR_TEST_PROFILE_MISMATCH%"=="1" set "profileFields=,"provider":"anthropic","model":"terra","reasoning_effort":"xhigh","service_tier":"standard""
    if "%HERDR_TEST_PROFILE_MALFORMED%"=="1" set "profileFields=,"provider":"openai","model":{"name":"luna-max"},"reasoning_effort":"max","service_tier":"priority""
    set "testTabId=w1:t2"
    if not "%HERDR_TEST_TARGET_TAB_ID%"=="" if /I "%~3"=="w1:p2" set "testTabId=%HERDR_TEST_TARGET_TAB_ID%"
    echo {"id":"test:agent:get","result":{"type":"agent_info","agent":{"pane_id":"%~3","workspace_id":"w1","tab_id":"!testTabId!","terminal_id":"term-test","revision":7,"state_change_seq":42,"agent":"!agentKind!","agent_status":"%HERDR_TEST_STATUS%","cwd":"!agentCwd!","agent_session":{"agent":"!agentKind!","value":"!testSession!"}!profileFields!}}}
  )
  exit /b 0
)
if /I "%~1"=="agent" if /I "%~2"=="read" (
  pwsh -NoProfile -Command "[Console]::Write($env:HERDR_TEST_DETECTION)"
  exit /b %errorlevel%
)
if /I "%~1"=="tab" if /I "%~2"=="get" if not "%HERDR_TEST_TAB_LABEL%"=="" (
  echo {"id":"test:tab:get","result":{"type":"tab_info","tab":{"tab_id":"%~3","workspace_id":"w1","label":"%HERDR_TEST_TAB_LABEL%","pane_count":1}}}
  exit /b 0
)
if /I "%~1"=="tab" if /I "%~2"=="get" (
  echo {"id":"test:tab:get","result":{"type":"tab_info","tab":{"tab_id":"%~3","workspace_id":"w1","label":"#600 - Review","pane_count":1}}}
  exit /b 0
)
if /I "%~1"=="notification" if /I "%~2"=="show" (
  echo {"id":"test:notification:show","result":{"type":"notification_shown"}}
  exit /b 0
)
echo unexpected fake rtk invocation: %* 1>&2
exit /b 2
'@ | Set-Content -LiteralPath $fakeRtkPath -Encoding ascii
    }
    else {
        @'
#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$arguments = @($args)
Add-Content -LiteralPath $env:HERDR_TEST_CALL_LOG -Value ($arguments -join " ") -Encoding utf8
if ($arguments.Count -gt 0 -and $arguments[0] -ieq "proxy") { $arguments = @($arguments[1..($arguments.Count - 1)]) }
if ($arguments.Count -lt 1 -or $arguments[0] -ine "herdr") { exit 2 }
$arguments = @($arguments[1..($arguments.Count - 1)])
function Write-Result {
    param([Parameter(Mandatory)]$Value)
    $Value | ConvertTo-Json -Depth 12 -Compress
    exit 0
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "pane" -and $arguments[1] -ieq "get") {
    if ($env:HERDR_TEST_PERMISSION_DENIED -eq "1") {
        Write-Error "PermissionDenied: native pane access unavailable"
        exit 1
    }
    $cwd = if ($env:HERDR_TEST_PANE_CWD) { $env:HERDR_TEST_PANE_CWD } elseif ([string]$arguments[2] -ieq "w2:p1") { "C:\dev\Codex\Herder" } else { "C:\dev\stmodel" }
    $foregroundCwd = if ($env:HERDR_TEST_PANE_FOREGROUND_CWD) { $env:HERDR_TEST_PANE_FOREGROUND_CWD } else { $cwd }
    $paneLabel = if ($env:HERDR_TEST_PANE_LABEL) { $env:HERDR_TEST_PANE_LABEL } else { "" }
    Write-Result ([ordered]@{ id = "test:pane:get"; result = [ordered]@{ type = "pane_info"; pane = [ordered]@{ pane_id = [string]$arguments[2]; workspace_id = "w1"; tab_id = "w1:t2"; terminal_id = "term-test"; cwd = $cwd; foreground_cwd = $foregroundCwd; label = $paneLabel } } })
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "agent" -and $arguments[1] -ieq "get") {
    $paneId = [string]$arguments[2]
    $session = if ($paneId -ieq "w2:p1") { "session-source" } else { "session-target" }
    if ($env:HERDR_TEST_TARGET_SESSION_ROTATED -eq "1" -and $paneId -ieq "w1:p2") { $session = "session-replaced" }
    if ($paneId -ieq "w2:p1" -and $env:HERDR_TEST_SOURCE_SESSION_MISMATCH -eq "1") { $session = "session-replaced" }
    $tabId = "w1:t2"
    if ($env:HERDR_TEST_TARGET_TAB_ID -and $paneId -ieq "w1:p2") { $tabId = $env:HERDR_TEST_TARGET_TAB_ID }
    $agentKind = if ($env:HERDR_TEST_AGENT_KIND) { $env:HERDR_TEST_AGENT_KIND } else { "codex" }
    $agentCwd = if ($env:HERDR_TEST_AGENT_CWD) { $env:HERDR_TEST_AGENT_CWD } else { "" }
    $agent = [ordered]@{
        pane_id = $paneId; workspace_id = "w1"; tab_id = $tabId; terminal_id = "term-test"
        revision = 7; state_change_seq = 42; agent = $agentKind; agent_status = $env:HERDR_TEST_STATUS; cwd = $agentCwd
    }
    if ($env:HERDR_TEST_PANE_SUBTITLE) {
        $agent.title = $env:HERDR_TEST_PANE_SUBTITLE
        $agent.display_agent = $env:HERDR_TEST_PANE_SUBTITLE
    }
    if ($env:HERDR_TEST_MISSING_SESSION -ne "1") {
        $agent.agent_session = [ordered]@{ agent = $agentKind; value = $session }
    }
    $profile = if ($env:HERDR_TEST_PROFILE_MALFORMED -eq "1") {
        [ordered]@{ provider = "openai"; model = [ordered]@{ name = "luna-max" }; reasoning_effort = "max"; service_tier = "priority" }
    } elseif ($env:HERDR_TEST_PROFILE_MISMATCH -eq "1") {
        [ordered]@{ provider = "anthropic"; model = "terra"; reasoning_effort = "xhigh"; service_tier = "standard" }
    } elseif ($env:HERDR_TEST_PROFILE -eq "1") {
        [ordered]@{ provider = "openai"; model = "luna-max"; reasoning_effort = "max"; service_tier = "priority" }
    } else { $null }
    if ($null -ne $profile) { foreach ($property in $profile.Keys) { $agent[$property] = $profile[$property] } }
    Write-Result ([ordered]@{ id = "test:agent:get"; result = [ordered]@{ type = "agent_info"; agent = $agent } })
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "agent" -and $arguments[1] -ieq "read") {
    [Console]::Write([string]$env:HERDR_TEST_DETECTION)
    exit 0
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "tab" -and $arguments[1] -ieq "get") {
    $label = if ($env:HERDR_TEST_TAB_LABEL) { $env:HERDR_TEST_TAB_LABEL } else { "#600 - Review" }
    Write-Result ([ordered]@{ id = "test:tab:get"; result = [ordered]@{ type = "tab_info"; tab = [ordered]@{ tab_id = [string]$arguments[2]; workspace_id = "w1"; label = $label; pane_count = 1 } } })
}
if ($arguments.Count -ge 2 -and $arguments[0] -ieq "notification" -and $arguments[1] -ieq "show") {
    Write-Result ([ordered]@{ id = "test:notification:show"; result = [ordered]@{ type = "notification_shown" } })
}
Write-Error "unexpected fake rtk invocation: $($arguments -join ' ')"
exit 2
'@ | Set-Content -LiteralPath $fakeRtkPath -Encoding utf8
        & chmod +x $fakeRtkPath
        if ($LASTEXITCODE -ne 0) { throw "Unable to mark the fake RTK shim executable." }
    }

    @'
[CmdletBinding()]
param(
    [string]$Action,
    [string]$From,
    [string]$To,
    [string]$Message,
    [string]$PaneId,
    [string]$ExpectedAgent,
    [string]$ExpectedSession,
    [string]$ExpectedTabLabel,
    [string]$ExpectedTabId,
    [string]$RelayRef,
    [string]$WorkflowRef,
    [string]$WorkflowLedgerPath,
    [string]$WatchLogPath,
    [string]$RepoCode,
    [string]$LaneCode,
    [string]$RoleCode,
    [string]$WorkKind,
    [string]$IssueNumber,
    [string]$WorkTitle,
    [string]$Topic,
    [string]$PreviousName,
    [string]$PreviousWork,
    [string]$LogPath
)
$record = [ordered]@{
    action = $Action
    from = $From
    to = $To
    pane_id = $PaneId
    repo_code = $RepoCode
    lane_code = $LaneCode
    role_code = $RoleCode
    work_kind = $WorkKind
    issue_number = $IssueNumber
    work_title = $WorkTitle
    previous_work = $PreviousWork
    expected_agent = $ExpectedAgent
    expected_session = $ExpectedSession
    expected_tab_label = $ExpectedTabLabel
    message = $Message
    workflow_ref = $WorkflowRef
    workflow_ledger_path = $WorkflowLedgerPath
}
Add-Content -LiteralPath $env:HERDR_TEST_CALL_LOG -Value ($record | ConvertTo-Json -Compress)
switch ($Action) {
    "prove-caller" {
        [pscustomobject]@{
            action = "prove-caller"
            proven = $true
            caller = [pscustomobject]@{
                pane_id = $PaneId
                agent = $ExpectedAgent
                session = $ExpectedSession
                caller_process_bound = $true
            }
        } | ConvertTo-Json -Depth 8
    }
    "discover" {
        [pscustomobject]@{
            action = "discover"
            found = $true
            ambiguous = $false
            coordinator = [pscustomobject]@{
                pane_id = "w1:pJ"
                agent = "codex"
                agent_status = "idle"
            }
        } | ConvertTo-Json -Depth 5
    }
    "append" {
        [pscustomobject]@{
            action = "append"
            log_path = $LogPath
            entry = $Message
        } | ConvertTo-Json -Depth 5
    }
    "deliver" {
        $submitted = $env:HERDR_TEST_DELIVERY_FAIL -ne "1"
        [pscustomobject]@{
            action = "deliver"
            delivery = [pscustomobject]@{
                pane_id = $PaneId
                agent = "codex"
                token = "[HC:test0001]"
                submitted = $submitted
                queued = $false
                transport = "agent_prompt"
                delivery_state = if ($submitted) { "accepted" } else { "failed" }
                error = if ($submitted) { $null } else { "fixture failure" }
            }
        } | ConvertTo-Json -Depth 8
    }
    "send" {
        $relay = if ($To -eq "w2:p1") { "[HR:feed0001]" } else { "[HR:notice01]" }
        [pscustomobject]@{
            action = "send"
            relay_ref = $relay
            delivered = $true
            notice_submitted = $true
            delivery_scope = "pointer_only"
            body_read = $false
            delivery = [pscustomobject]@{
                submitted = $true
                token = "[HC:notice01]"
                watch_started = $false
            }
        } | ConvertTo-Json -Depth 8
    }
    "ack-read" {
        $sessionRotated = $env:HERDR_TEST_SOURCE_SESSION_MISMATCH -eq "1"
        $effectiveRelay = if ($sessionRotated) { "[HR:feed0002]" } else { $RelayRef }
        [pscustomobject]@{
            action = "ack-read"
            relay_ref = $effectiveRelay
            requested_relay_ref = $RelayRef
            body_read = $true
            duplicate = $false
            session_rotated = $sessionRotated
            replacement_created = $sessionRotated
            replacement_relay_refs = if ($sessionRotated) { @($effectiveRelay) } else { @() }
            read_ack = [pscustomobject]@{
                ack_ref = "[HA:return01]"
                relay_ref = $effectiveRelay
                reader_pane_id = "w2:p1"
                reader_agent = "codex"
                reader_session = if ($sessionRotated) { "session-replaced" } else { "session-source" }
            }
        } | ConvertTo-Json -Depth 8
    }
    "relay-status" {
        [pscustomobject]@{
            action = "relay-status"
            relay_ref = $RelayRef
            body_read = $true
            read_ack = [pscustomobject]@{
                ack_ref = "[HA:return01]"
                relay_ref = $RelayRef
                reader_pane_id = "w2:p1"
                returned_to = "w1:p2"
                reader_agent = "codex"
                reader_session = "session-source"
            }
            conflicting_ack_count = 0
            superseded = $false
            effective_relay_ref = $RelayRef
            relay = [pscustomobject]@{
                sender = "w1:p2"
                recipient = "w2:p1"
                recipient_session = "session-source"
            }
        } | ConvertTo-Json -Depth 8
    }
    "name-request" {
        if ($env:HERDR_TEST_NAME_REQUEST_FAIL -eq "1") {
            throw "fixture name-request failure"
        }
        [pscustomobject]@{
            action = "name-request"
            request = "PANE NAMING REQUEST: repo=$RepoCode; lane=$LaneCode; role=$RoleCode; work=$WorkKind; issue=$IssueNumber; title=$WorkTitle"
            relay = [pscustomobject]@{
                action = "send"
                relay_ref = "[HR:naming01]"
                delivered = $true
            }
        } | ConvertTo-Json -Depth 8
    }
    default {
        throw "unexpected coordination action $Action"
    }
}
'@ | Set-Content -LiteralPath $fakeCoordPath -Encoding utf8

    $originalPath = $env:PATH
    $originalHerdrEnv = $env:HERDR_ENV
    $originalPaneId = $env:HERDR_PANE_ID
    try {
        $pwshDirectory = Split-Path -Parent (Get-Command pwsh -ErrorAction Stop).Source
        $env:PATH = [string]::Join([IO.Path]::PathSeparator, @($tempRoot, $pwshDirectory))
        $env:HERDR_ENV = "1"
        $env:HERDR_PANE_ID = "w2:p1"
        $env:HERDR_TEST_CALL_LOG = $callLogPath
        $env:HERDR_TEST_STATUS = "idle"
        $env:HERDR_TEST_MISSING_SESSION = "0"
        $env:HERDR_TEST_PERMISSION_DENIED = "0"
        $env:HERDR_TEST_SOURCE_SESSION_MISMATCH = "0"
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "0"
        $env:HERDR_TEST_PROFILE = "1"
        $env:HERDR_TEST_PROFILE_MISMATCH = "0"
        $env:HERDR_TEST_PROFILE_MALFORMED = "0"
        $env:HERDR_TEST_TARGET_TAB_ID = ""
        $env:HERDR_TEST_AGENT_KIND = ""
        $env:HERDR_TEST_AGENT_CWD = ""
        $env:HERDR_TEST_PANE_CWD = ""
        $env:HERDR_TEST_PANE_FOREGROUND_CWD = ""
        $env:HERDR_TEST_PANE_LABEL = ""
        $env:HERDR_TEST_DETECTION = "ready prompt"
        $env:HERDR_TEST_DELIVERY_FAIL = "0"
        Set-Content -LiteralPath $completionArtifactPath -Value "PASS. All correction checks succeeded; no authorization is implied." -Encoding utf8
        Set-Content -LiteralPath $returnRetryArtifactPath -Value "PASS. Return retry fixture verdict reasoning." -Encoding utf8

        Write-Output "CASE: ready reviewer preflight"
        $preflight = Invoke-Workflow -Arguments @(
            "-Action", "preflight",
            "-PaneId", "w1:p2"
        )
        Assert-True -Condition ([bool]$preflight.preflight.ready) -Message "Ready reviewer failed preflight."
        Assert-Equal -Actual $preflight.preflight.session_id -Expected "session-target" -Message "Preflight lost native session proof."
        Assert-Equal -Actual $preflight.preflight.cwd -Expected "C:\dev\stmodel" -Message "Preflight did not expose the live foreground cwd."

        Write-Output "CASE: Claude agent workspace cwd outranks context-mode child cwd"
        $claudeWorkspaceCwd = "/tmp/herdr-bootstrap-961-review-1eef5ef"
        $env:HERDR_TEST_AGENT_KIND = "claude"
        $env:HERDR_TEST_AGENT_CWD = $claudeWorkspaceCwd
        $env:HERDR_TEST_PANE_CWD = $claudeWorkspaceCwd
        $env:HERDR_TEST_PANE_FOREGROUND_CWD = "/home/nathan/.claude/plugins/cache/context-mode/context-mode/1.0.169"
        $env:HERDR_TEST_TAB_LABEL = "STM-T-C1"
        $env:HERDR_TEST_PANE_LABEL = ""
        $claudePreflight = Invoke-Workflow -Arguments @(
            "-Action", "preflight", "-PaneId", "w1:p2", "-ExpectedTabLabel", "STM-T-C1",
            "-ExpectedCwd", $claudeWorkspaceCwd
        )
        Assert-True -Condition ([bool]$claudePreflight.preflight.ready) -Message "Claude child-process cwd incorrectly failed the exact-worktree preflight."
        Assert-Equal -Actual $claudePreflight.preflight.cwd -Expected $claudeWorkspaceCwd -Message "Preflight selected the context-mode child cwd instead of the Claude workspace cwd."
        Assert-Equal -Actual $claudePreflight.preflight.cwd_source -Expected "agent.workspace_cwd" -Message "Preflight did not identify the native agent workspace cwd source."
        Assert-Equal -Actual $claudePreflight.preflight.agent_workspace_cwd -Expected $claudeWorkspaceCwd -Message "Preflight lost the native Claude workspace cwd."
        Assert-Equal -Actual $claudePreflight.preflight.foreground_cwd -Expected $env:HERDR_TEST_PANE_FOREGROUND_CWD -Message "Preflight did not retain the child foreground cwd as diagnostic data."

        Write-Output "CASE: pane label mismatch fails closed against canonical tab label"
        $env:HERDR_TEST_PANE_LABEL = "STM-T-A1"
        $paneLabelMismatch = Invoke-Workflow -Arguments @(
            "-Action", "preflight", "-PaneId", "w1:p2", "-ExpectedTabLabel", "STM-T-C1",
            "-ExpectedCwd", $claudeWorkspaceCwd
        )
        Assert-True -Condition (-not [bool]$paneLabelMismatch.preflight.ready) -Message "A visible pane label mismatch passed preflight."
        Assert-True -Condition ([bool](@($paneLabelMismatch.preflight.reasons) -match "pane label mismatch")) -Message "Pane label mismatch was not reported by preflight."
        Assert-Equal -Actual $paneLabelMismatch.preflight.tab_label -Expected "STM-T-C1" -Message "Preflight lost the canonical tab label while reporting pane-label drift."
        Assert-Equal -Actual $paneLabelMismatch.preflight.pane_label -Expected "STM-T-A1" -Message "Preflight lost the visible pane label while reporting pane-label drift."
        Assert-True -Condition (-not [bool]$paneLabelMismatch.preflight.labels_consistent) -Message "Pane/tab label inconsistency was reported as consistent."

        $env:HERDR_TEST_AGENT_KIND = ""
        $env:HERDR_TEST_AGENT_CWD = ""
        $env:HERDR_TEST_PANE_CWD = ""
        $env:HERDR_TEST_PANE_FOREGROUND_CWD = ""
        $env:HERDR_TEST_PANE_LABEL = ""
        $env:HERDR_TEST_TAB_LABEL = ""
        $cwdMismatch = Invoke-Workflow -Arguments @(
            "-Action", "preflight", "-PaneId", "w1:p2", "-ExpectedTabLabel", "#600 - Review",
            "-ExpectedCwd", "C:\dev\other"
        )
        Assert-True -Condition (-not [bool]$cwdMismatch.preflight.ready) -Message "A mismatched expected cwd passed preflight."
        Assert-True -Condition ([bool](@($cwdMismatch.preflight.reasons) -match "cwd mismatch")) -Message "Cwd mismatch was not reported by preflight."

        Write-Output "CASE: sandbox host access denial fails closed before workflow mutation"
        $ledgerBeforeHostAccess = if (Test-Path -LiteralPath $ledgerPath) { @(Get-Content -LiteralPath $ledgerPath).Count } else { 0 }
        $env:HERDR_TEST_PERMISSION_DENIED = "1"
        $hostAccessRefusal = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#host-access",
            "-CandidateId", "sandbox-denied",
            "-ReviewType", "host-access-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Must stop before workflow or naming mutation."
        ) -ExpectFailure
        $env:HERDR_TEST_PERMISSION_DENIED = "0"
        $ledgerAfterHostAccess = if (Test-Path -LiteralPath $ledgerPath) { @(Get-Content -LiteralPath $ledgerPath).Count } else { 0 }
        Assert-True -Condition ($hostAccessRefusal.Text -match "host_access_unavailable") -Message "PermissionDenied was not classified as host_access_unavailable."
        Assert-Equal -Actual $ledgerAfterHostAccess -Expected $ledgerBeforeHostAccess -Message "Host-access refusal mutated the workflow ledger."

        Write-Output "CASE: suppressed composer preflight refusal"
        $env:HERDR_TEST_DETECTION = "Waiting for 2 background agents to finish"
        $suppressed = Invoke-Workflow -Arguments @(
            "-Action", "preflight",
            "-PaneId", "w1:p2"
        )
        Assert-True -Condition (-not [bool]$suppressed.preflight.ready) -Message "Suppressed composer passed preflight."
        Assert-True -Condition (@($suppressed.preflight.flags) -contains "background_agents") -Message "Suppressed composer flag was not reported."
        Assert-Equal -Actual $suppressed.preflight.detection_scope -Expected "full_buffer_no_prompt_marker" -Message "Suppressed composer did not retain fail-closed full-buffer detection."

        Write-Output "CASE: active blockers after final prompt marker"
        $env:HERDR_TEST_DETECTION = "old transcript`n❯ run task`nWaiting for 1 background agent to finish`nPermission approval required: allow or deny`nPasted text #42"
        $activeBlockers = Invoke-Workflow -Arguments @(
            "-Action", "preflight",
            "-PaneId", "w1:p2"
        )
        Assert-True -Condition (-not [bool]$activeBlockers.preflight.ready) -Message "Active interactive blockers passed preflight."
        Assert-True -Condition (@($activeBlockers.preflight.flags) -contains "background_agents") -Message "Active background-agent blocker was not reported."
        Assert-True -Condition (@($activeBlockers.preflight.flags) -contains "interactive_block") -Message "Active permission blocker was not reported."
        Assert-True -Condition (@($activeBlockers.preflight.flags) -contains "collapsed_paste") -Message "Active collapsed-paste blocker was not reported."
        Assert-Equal -Actual $activeBlockers.preflight.detection_scope -Expected "after_final_prompt_marker" -Message "Active blocker scan used the wrong detection scope."

        Write-Output "CASE: stale historical blockers before empty prompt"
        $env:HERDR_TEST_DETECTION = "Waiting for 1 background agent to finish`nPermission approval required: allow or deny`nPasted text #42`nAgent finished`n❯`nstatus bar"
        $staleBlockers = Invoke-Workflow -Arguments @(
            "-Action", "preflight",
            "-PaneId", "w1:p2"
        )
        Assert-True -Condition ([bool]$staleBlockers.preflight.ready) -Message "Historical blockers before the final empty prompt stranded an idle reviewer."
        Assert-Equal -Actual @($staleBlockers.preflight.flags).Count -Expected 0 -Message "Historical blockers leaked into current UI flags."
        Assert-True -Condition ([bool]$staleBlockers.preflight.prompt_marker_found) -Message "Final prompt marker was not recognized."

        Write-Output "CASE: missing native-session preflight refusal"
        $env:HERDR_TEST_DETECTION = "ready prompt"
        $env:HERDR_TEST_MISSING_SESSION = "1"
        $missingSession = Invoke-Workflow -Arguments @(
            "-Action", "preflight",
            "-PaneId", "w1:p2"
        )
        Assert-True -Condition (-not [bool]$missingSession.preflight.ready) -Message "Missing session proof passed preflight."
        $env:HERDR_TEST_MISSING_SESSION = "0"

        Write-Output "CASE: unproven execution profile preflight refusal"
        $env:HERDR_TEST_PROFILE = "0"
        $unprovenPreflight = Invoke-Workflow -Arguments @(
            "-Action", "preflight",
            "-PaneId", "w1:p2"
        )
        Assert-True -Condition (-not [bool]$unprovenPreflight.preflight.ready) -Message "Unproven execution profile passed preflight."
        Assert-True -Condition (-not [bool]$unprovenPreflight.preflight.execution_profile_proven) -Message "Unproven execution profile was reported as proven."
        Assert-True -Condition (@($unprovenPreflight.preflight.reasons) -contains "native execution profile is not proven") -Message "Unproven execution profile refusal was not explained."
        $env:HERDR_TEST_PROFILE = "1"

        Write-Output "CASE: request stable-label mismatch fails before ledger and delivery"
        $callsBeforeLabelMismatch = @(Get-Calls).Count
        $labelMismatch = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#599",
            "-CandidateId", "wrong-lane",
            "-ReviewType", "final-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "AGENT CC R",
            "-Message", "Must not reach the wrong stable lane.",
            "-NowUtc", "2026-01-01T00:00:00Z"
        )
        Assert-True -Condition (-not [bool]$labelMismatch.created) -Message "Workflow request ignored the stable-label mismatch."
        Assert-True -Condition ([string]$labelMismatch.error -match "expected 'AGENT CC R', observed '#600 - Review'") -Message "Workflow label mismatch was not explained."
        Assert-Equal -Actual @(Get-Calls).Count -Expected $callsBeforeLabelMismatch -Message "Workflow label mismatch reached coordination append/delivery."

        Write-Output "CASE: create request with ACK deadline"
        $requestArgs = @(
            "-Action", "request",
            "-TaskId", "#600",
            "-CandidateId", "abc123",
            "-ReviewType", "final-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Review the exact candidate.",
            "-ArtifactPath", "C:\tmp\review-600.md",
            "-AckTimeoutSeconds", "120",
            "-CompletionTimeoutSeconds", "600",
            "-NowUtc", "2026-01-01T00:00:00Z"
        )
        $request = Invoke-Workflow -Arguments $requestArgs
        Assert-True -Condition ([bool]$request.created -and -not [bool]$request.duplicate) -Message "Request was not created."
        Assert-True -Condition ([bool]$request.request.transport_accepted) -Message "Request transport was not accepted."
        Assert-Equal -Actual $request.request.source_pane -Expected "w2:p1" -Message "Request lost its originating pane."
        Assert-Equal -Actual $request.request.source_agent -Expected "codex" -Message "Request lost its originating agent kind."
        Assert-Equal -Actual $request.request.source_session -Expected "session-source" -Message "Request lost its originating native session."
        Assert-Equal -Actual $request.request.source_tab_id -Expected "w1:t2" -Message "Request lost its originating stable tab ID."
        Assert-Equal -Actual $request.request.source_tab_label -Expected "#600 - Review" -Message "Request lost its originating stable label."
        Assert-Equal -Actual $request.request.target_tab_label -Expected "#600 - Review" -Message "Request lost its target stable label."
        Assert-Equal -Actual ([datetime]$request.request.ack_deadline_utc).ToUniversalTime().ToString("o") -Expected "2026-01-01T00:02:00.0000000Z" -Message "ACK deadline was wrong."
        $workflowRef = [string]$request.workflow_ref
        $requestCalls = Get-Calls
        Assert-Equal -Actual (@($requestCalls | Where-Object { $_.action -eq "append" }).Count) -Expected 1 -Message "Request did not append exactly once."
        Assert-Equal -Actual (@($requestCalls | Where-Object { $_.action -eq "deliver" }).Count) -Expected 1 -Message "Request did not deliver exactly once."
        $requestDeliveryCall = @($requestCalls | Where-Object { $_.action -eq "deliver" })[0]
        Assert-Equal -Actual $requestDeliveryCall.expected_tab_label -Expected "#600 - Review" -Message "Request delivery did not propagate the stable-label assertion."
        Assert-True -Condition ([string]$requestDeliveryCall.message -match 'After running the workflow ACK command above, immediately execute the instructions in the relay body as your current task; the ACK is a receipt, not completion; do not end your turn after ACKing') -Message "Workflow request notice did not instruct the reviewer to continue into the relay body after ACKing."

        Write-Output "CASE: duplicate request suppression"
        $duplicate = Invoke-Workflow -Arguments $requestArgs
        Assert-True -Condition ([bool]$duplicate.duplicate -and -not [bool]$duplicate.created) -Message "Duplicate request was not suppressed."
        $duplicateCalls = Get-Calls
        Assert-Equal -Actual (@($duplicateCalls | Where-Object { $_.action -eq "deliver" }).Count) -Expected 1 -Message "Duplicate request redelivered."

        Write-Output "CASE: ACK provenance refusal"
        $env:HERDR_PANE_ID = "w1:p9"
        $wrongAck = Invoke-Workflow -ExpectFailure -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $workflowRef,
            "-NowUtc", "2026-01-01T00:01:00Z"
        )
        Assert-True -Condition ($wrongAck.Text -match "not target pane") -Message "Wrong-pane ACK did not fail with provenance evidence."

        Write-Output "CASE: ACK and duplicate suppression"
        $env:HERDR_PANE_ID = "w1:p2"
        $ack = Invoke-Workflow -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $workflowRef,
            "-Message", "STARTED",
            "-NowUtc", "2026-01-01T00:01:00Z"
        )
        Assert-True -Condition (-not [bool]$ack.duplicate) -Message "First ACK was marked duplicate."
        $ackDuplicate = Invoke-Workflow -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $workflowRef,
            "-NowUtc", "2026-01-01T00:01:30Z"
        )
        Assert-True -Condition ([bool]$ackDuplicate.duplicate) -Message "Duplicate ACK was not suppressed."
        $ackCalls = Get-Calls
        Assert-Equal -Actual (@($ackCalls | Where-Object { $_.action -eq "send" }).Count) -Expected 1 -Message "ACK coordinator notice was not idempotent."

        Write-Output "CASE: dormant target session rotation reissues exactly once with the original deadline"
        $env:HERDR_TEST_PROFILE = "1"
        $rotationRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#601",
            "-CandidateId", "rotation-candidate",
            "-ReviewType", "rotation-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Reissue this exact review body after a dormant-pane session rotation.",
            "-ArtifactPath", $completionArtifactPath,
            "-AckTimeoutSeconds", "120",
            "-NowUtc", "2026-01-01T00:00:00Z"
        )
        $rotationRef = [string]$rotationRequest.workflow_ref
        $originalRotationDeadline = [string]$rotationRequest.request.ack_deadline_utc
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "1"
        $rotatedAck = Invoke-Workflow -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $rotationRef,
            "-NowUtc", "2026-01-01T00:01:00Z"
        )
        Assert-True -Condition ([bool]$rotatedAck.session_rotated -and [bool]$rotatedAck.reissued) -Message "Dormant target rotation did not produce a deterministic replacement."
        Assert-Equal -Actual $rotatedAck.original_target_session -Expected "session-target" -Message "Rotation replacement lost the original target session."
        Assert-Equal -Actual $rotatedAck.replacement_target_session -Expected "session-replaced" -Message "Rotation replacement did not bind the live target session."
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$rotatedAck.replacement_relay_ref)) -Message "Rotation replacement did not create a relay reference."
        Assert-Equal -Actual ([string]$rotatedAck.ack_deadline_utc) -Expected $originalRotationDeadline -Message "Rotation replacement extended the original ACK deadline."
        $rotationLedger = @(Get-Content -LiteralPath $ledgerPath | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } | Where-Object { $_.workflow_ref -eq $rotationRef -and $_.event -eq "request_reissued" })
        Assert-Equal -Actual $rotationLedger.Count -Expected 1 -Message "Rotation produced more than one durable replacement event."
        Assert-Equal -Actual $rotationLedger[0].artifact_path -Expected $completionArtifactPath -Message "Rotation replacement changed the artifact path."

        Write-Output "CASE: repeated rotated ACK is idempotent and does not create a second replacement"
        $rotatedAckAccepted = Invoke-Workflow -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $rotationRef,
            "-NowUtc", "2026-01-01T00:01:10Z"
        )
        Assert-True -Condition (-not ($rotatedAckAccepted.PSObject.Properties.Name -contains "session_rotated") -and -not [bool]$rotatedAckAccepted.duplicate) -Message "Replacement-bound ACK did not continue through the normal work ACK path."
        $rotationLedgerAfterAck = @(Get-Content -LiteralPath $ledgerPath | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } | Where-Object { $_.workflow_ref -eq $rotationRef -and $_.event -eq "request_reissued" })
        Assert-Equal -Actual $rotationLedgerAfterAck.Count -Expected 1 -Message "Repeated ACK created a duplicate replacement."

        Write-Output "CASE: changed model profile fails closed without replacement"
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "0"
        $env:HERDR_TEST_PROFILE_MISMATCH = "0"
        $wrongProfileRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#602",
            "-CandidateId", "wrong-profile",
            "-ReviewType", "rotation-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Refuse a model-profile-changing replacement.",
            "-AckTimeoutSeconds", "120",
            "-NowUtc", "2026-01-01T00:00:00Z"
        )
        $wrongProfileRef = [string]$wrongProfileRequest.workflow_ref
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "1"
        $env:HERDR_TEST_PROFILE_MISMATCH = "1"
        $wrongProfileAck = Invoke-Workflow -ExpectFailure -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $wrongProfileRef,
            "-NowUtc", "2026-01-01T00:01:00Z"
        )
        $wrongProfileText = $wrongProfileAck.Text
        Assert-True -Condition ($wrongProfileText -match 'model' -and $wrongProfileText -match 'reasoning' -and $wrongProfileText -match 'service tier' -and $wrongProfileText -match 'changed') -Message "Changed model profile did not fail closed."
        $wrongProfileReissues = @(Get-Content -LiteralPath $ledgerPath | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } | Where-Object { $_.workflow_ref -eq $wrongProfileRef -and $_.event -eq "request_reissued" })
        Assert-Equal -Actual $wrongProfileReissues.Count -Expected 0 -Message "Changed model profile created a replacement despite failing closed."
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "0"
        $env:HERDR_TEST_PROFILE_MISMATCH = "0"
        Write-Output "CASE: unavailable model profile fails closed without guessing"
        $callsBeforeUnprovenProfile = @(Get-Calls).Count
        $ledgerEventsBeforeUnprovenProfile = @(Get-Content -LiteralPath $ledgerPath | Where-Object { $_ } ).Count
        $env:HERDR_TEST_PROFILE = "0"
        $unprovenProfileRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#603",
            "-CandidateId", "unproven-profile",
            "-ReviewType", "rotation-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Do not guess a profile that Herdr cannot prove.",
            "-AckTimeoutSeconds", "120",
            "-NowUtc", "2026-01-01T00:00:00Z"
        )
        Assert-True -Condition (-not [bool]$unprovenProfileRequest.created) -Message "Unavailable model profile reached reservation or transport."
        Assert-True -Condition (-not [bool]$unprovenProfileRequest.preflight.execution_profile_proven) -Message "Unavailable model profile request did not expose unproven preflight."
        Assert-True -Condition ([string]$unprovenProfileRequest.error -match "execution profile") -Message "Unavailable model profile refusal was not explained."
        Assert-Equal -Actual @(Get-Calls).Count -Expected $callsBeforeUnprovenProfile -Message "Unavailable model profile reached coordination transport."
        Assert-Equal -Actual @(Get-Content -LiteralPath $ledgerPath | Where-Object { $_ } ).Count -Expected $ledgerEventsBeforeUnprovenProfile -Message "Unavailable model profile mutated the workflow ledger."
        $env:HERDR_TEST_PROFILE = "1"

        Write-Output "CASE: malformed model profile fails closed without coercion"
        $env:HERDR_TEST_PROFILE_MALFORMED = "0"
        $malformedProfileRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#608",
            "-CandidateId", "malformed-profile",
            "-ReviewType", "rotation-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Do not coerce a nested model profile.",
            "-AckTimeoutSeconds", "120",
            "-NowUtc", "2026-01-01T00:00:00Z"
        )
        $malformedProfileRef = [string]$malformedProfileRequest.workflow_ref
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "1"
        $env:HERDR_TEST_PROFILE_MALFORMED = "1"
        $malformedProfileAck = Invoke-Workflow -ExpectFailure -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $malformedProfileRef,
            "-NowUtc", "2026-01-01T00:01:00Z"
        )
        $malformedProfileText = [regex]::Replace([string]$malformedProfileAck.Text, "\x1b\[[0-9;]*m", "") -replace "\s+", " "
        Assert-True -Condition ($malformedProfileText -match "continuity" -and $malformedProfileText -match "natively" -and $malformedProfileText -match "proven") -Message "Malformed model profile was coerced instead of failing closed."
        $malformedProfileReissues = @(Get-Content -LiteralPath $ledgerPath | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } | Where-Object { $_.workflow_ref -eq $malformedProfileRef -and $_.event -eq "request_reissued" })
        Assert-Equal -Actual $malformedProfileReissues.Count -Expected 0 -Message "Malformed model profile created a replacement."
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "0"
        $env:HERDR_TEST_PROFILE_MALFORMED = "0"

        Write-Output "CASE: in-progress replacement refuses a duplicate delivery"
        $env:HERDR_TEST_PROFILE = "1"
        $inProgressRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#604",
            "-CandidateId", "in-progress-reissue",
            "-ReviewType", "rotation-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Do not duplicate a replacement whose lease is active.",
            "-AckTimeoutSeconds", "120",
            "-NowUtc", "2026-01-01T00:00:00Z"
        )
        $inProgressRef = [string]$inProgressRequest.workflow_ref
        Add-Content -LiteralPath $ledgerPath -Value (([ordered]@{
                    event = "request_reissue_reserved"
                    workflow_ref = $inProgressRef
                    job_key = [string]$inProgressRequest.job_key
                    reissue_attempt_id = "[WR:inprogress]"
                    superseded_relay_ref = [string]$inProgressRequest.relay_ref
                    original_target_session = "session-target"
                    target_pane = "w1:p2"
                    target_agent = "codex"
                    target_session = "session-replaced"
                    target_tab_id = "w1:t2"
                    target_tab_label = "#600 - Review"
                    target_provider = "openai"
                    target_model = "luna-max"
                    target_reasoning_effort = "max"
                    target_service_tier = "priority"
                    target_execution_profile_proven = $true
                    message_sha256 = "test"
                    artifact_path = ""
                    ack_deadline_utc = "2026-01-01T00:02:00.0000000Z"
                    lease_expires_utc = "not-a-date"
                    timestamp_utc = "2026-01-01T00:01:00.0000000Z"
                } | ConvertTo-Json -Compress))
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "1"
        $inProgressAck = Invoke-Workflow -ExpectFailure -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $inProgressRef,
            "-NowUtc", "2026-01-01T00:01:10Z"
        )
        Assert-True -Condition ($inProgressAck.Text -match "replacement delivery already in progress") -Message "Active reissue lease did not refuse a duplicate replacement."
        $inProgressReissues = @(Get-Content -LiteralPath $ledgerPath | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } | Where-Object { $_.workflow_ref -eq $inProgressRef -and $_.event -eq "request_reissued" })
        Assert-Equal -Actual $inProgressReissues.Count -Expected 0 -Message "Active reissue lease produced a duplicate replacement."
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "0"

        Write-Output "CASE: original ACK deadline is a hard reissue budget"
        $deadlineRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#605",
            "-CandidateId", "deadline-reissue",
            "-ReviewType", "rotation-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Do not extend the original ACK deadline during reissue.",
            "-AckTimeoutSeconds", "120",
            "-NowUtc", "2026-01-01T00:00:00Z"
        )
        $deadlineRef = [string]$deadlineRequest.workflow_ref
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "1"
        $deadlineAck = Invoke-Workflow -ExpectFailure -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $deadlineRef,
            "-NowUtc", "2026-01-01T00:02:01Z"
        )
        Assert-True -Condition ($deadlineAck.Text -match "exceeded its original ACK deadline") -Message "Expired original ACK deadline was extended by reissue."
        $deadlineReissues = @(Get-Content -LiteralPath $ledgerPath | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } | Where-Object { $_.workflow_ref -eq $deadlineRef -and $_.event -eq "request_reissued" })
        Assert-Equal -Actual $deadlineReissues.Count -Expected 0 -Message "Expired original ACK deadline produced a replacement."
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "0"

        Write-Output "CASE: changed stable tab label refuses replacement"
        $tabRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#606",
            "-CandidateId", "wrong-tab",
            "-ReviewType", "rotation-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Refuse a reissue after the pane changed tabs.",
            "-AckTimeoutSeconds", "120",
            "-NowUtc", "2026-01-01T00:00:00Z"
        )
        $tabRef = [string]$tabRequest.workflow_ref
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "1"
        $env:HERDR_TEST_TAB_LABEL = "#606 - Wrong Tab"
        $tabAck = Invoke-Workflow -ExpectFailure -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $tabRef,
            "-NowUtc", "2026-01-01T00:01:00Z"
        )
        Assert-True -Condition ($tabAck.Text -match "target pane, agent, tab, or stable label changed") -Message "Changed stable tab label did not fail closed."
        $tabReissues = @(Get-Content -LiteralPath $ledgerPath | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } | Where-Object { $_.workflow_ref -eq $tabRef -and $_.event -eq "request_reissued" })
        Assert-Equal -Actual $tabReissues.Count -Expected 0 -Message "Changed stable tab label produced a replacement."
        $env:HERDR_TEST_TAB_LABEL = ""
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "0"
        $env:HERDR_TEST_PROFILE = "0"

        Write-Output "CASE: changed stable tab ID refuses replacement"
        $env:HERDR_TEST_PROFILE = "1"
        $tabIdRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#607",
            "-CandidateId", "wrong-tab-id",
            "-ReviewType", "rotation-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Refuse a reissue after the pane moved tabs.",
            "-AckTimeoutSeconds", "120",
            "-NowUtc", "2026-01-01T00:00:00Z"
        )
        $tabIdRef = [string]$tabIdRequest.workflow_ref
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "1"
        $env:HERDR_TEST_TARGET_TAB_ID = "w1:t3"
        $tabIdAck = Invoke-Workflow -ExpectFailure -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $tabIdRef,
            "-NowUtc", "2026-01-01T00:01:00Z"
        )
        $tabIdText = [regex]::Replace([string]$tabIdAck.Text, "\x1b\[[0-9;]*m", "") -replace "\s+", " "
        Assert-True -Condition ($tabIdText -match "target pane, agent, tab, or stable label changed") -Message "Changed stable tab ID did not fail closed."
        $tabIdReissues = @(Get-Content -LiteralPath $ledgerPath | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } | Where-Object { $_.workflow_ref -eq $tabIdRef -and $_.event -eq "request_reissued" })
        Assert-Equal -Actual $tabIdReissues.Count -Expected 0 -Message "Changed stable tab ID produced a replacement."
        $env:HERDR_TEST_TARGET_SESSION_ROTATED = "0"
        $env:HERDR_TEST_TARGET_TAB_ID = ""
        $env:HERDR_TEST_PROFILE = "1"

        Write-Output "CASE: completion and duplicate suppression"
        $deliveriesBeforeCompletion = @((Get-Calls) | Where-Object { $_.action -eq "deliver" }).Count
        $complete = Invoke-Workflow -Arguments @(
            "-Action", "complete",
            "-WorkflowRef", $workflowRef,
            "-Outcome", "PASS",
            "-ArtifactPath", $completionArtifactPath,
            "-NowUtc", "2026-01-01T00:02:00Z"
        )
        Assert-True -Condition (-not [bool]$complete.duplicate) -Message "First completion was marked duplicate."
        Assert-True -Condition (-not [bool]$complete.origin_return.returned -and [bool]$complete.origin_return.pending) -Message "Completion pointer submission was conflated with a read verdict body."
        Assert-Equal -Actual $complete.origin_return.state -Expected "awaiting_read_ack" -Message "Completion return did not wait for body-read proof."
        Assert-Equal -Actual $complete.origin_return.event.source_pane -Expected "w2:p1" -Message "Completion returned to the wrong pane."
        Assert-Equal -Actual $complete.origin_return.event.source_session -Expected "session-source" -Message "Completion return lost source-session proof."
        Assert-True -Condition (-not [bool]$complete.origin_return.event.body_read) -Message "Completion notice was incorrectly recorded as body-read."
        Assert-Equal -Actual $complete.origin_return.event.return_relay_ref -Expected "[HR:feed0001]" -Message "Completion return lost its durable relay reference."
        $completionCalls = Get-Calls
        $completionDeliveries = @($completionCalls | Where-Object { $_.action -eq "deliver" })
        Assert-Equal -Actual $completionDeliveries.Count -Expected $deliveriesBeforeCompletion -Message "Completion return unexpectedly bypassed the tracked pointer transport."
        $completionReturns = @($completionCalls | Where-Object { $_.action -eq "send" -and $_.to -eq "w2:p1" })
        Assert-Equal -Actual $completionReturns.Count -Expected 1 -Message "Completion return did not add exactly one tracked relay to the origin."
        Assert-Equal -Actual $completionReturns[-1].expected_agent -Expected "codex" -Message "Completion return omitted expected agent proof."
        Assert-Equal -Actual $completionReturns[-1].expected_session -Expected "session-source" -Message "Completion return omitted expected native-session proof."
        Assert-Equal -Actual $completionReturns[-1].workflow_ref -Expected $workflowRef -Message "Completion pointer did not select the workflow-aware read receipt."
        Assert-Equal -Actual $completionReturns[-1].workflow_ledger_path -Expected $ledgerPath -Message "Completion pointer did not preserve the active workflow ledger."
        Assert-True -Condition ([string]$completionReturns[-1].message -match ([regex]::Escape($workflowRef))) -Message "Completion return omitted the workflow reference."
        Assert-True -Condition ([string]$completionReturns[-1].message -match "CANDIDATE abc123") -Message "Completion return omitted the stable candidate."
        Assert-True -Condition ([string]$completionReturns[-1].message -match "All correction checks succeeded") -Message "Completion return did not place verdict reasoning in the durable body."

        $readTimeoutScan = Invoke-Workflow -Arguments @(
            "-Action", "scan",
            "-NowUtc", "2026-01-02T00:04:01Z"
        )
        $readTimeoutAlerts = @($readTimeoutScan.new_alerts | Where-Object {
                $_.workflow_ref -eq $workflowRef
            })
        Assert-Equal -Actual $readTimeoutAlerts.Count -Expected 1 -Message "Missing completion body-read ACK did not create an alert."
        Assert-Equal -Actual $readTimeoutAlerts[0].alert_kind -Expected "completion_return_read_timeout" -Message "Completion body-read timeout used the wrong alert kind."

        Write-Output "CASE: originating builder proves completion body read"
        $env:HERDR_PANE_ID = "w2:p1"
        $returnAck = Invoke-Workflow -Arguments @(
            "-Action", "ack-return",
            "-WorkflowRef", $workflowRef,
            "-NowUtc", "2026-01-01T00:04:15Z"
        )
        Assert-True -Condition ([bool]$returnAck.body_read -and -not [bool]$returnAck.duplicate) -Message "Origin did not durably acknowledge the verdict body."
        Assert-Equal -Actual $returnAck.return_read.actor_session -Expected "session-source" -Message "Completion read receipt lost native-session proof."
        $returnAckDuplicate = Invoke-Workflow -Arguments @(
            "-Action", "ack-return",
            "-WorkflowRef", $workflowRef,
            "-NowUtc", "2026-01-01T00:04:20Z"
        )
        Assert-True -Condition ([bool]$returnAckDuplicate.duplicate) -Message "Duplicate completion read receipt was not idempotent."
        Assert-Equal -Actual (@(Get-Calls | Where-Object { $_.action -eq "ack-read" }).Count) -Expected 1 -Message "Duplicate completion read receipt repeated coordination work."

        Write-Output "CASE: coordinator reconciles durable completion-return read proof"
        $env:HERDR_PANE_ID = "w2:p1"
        $returnReadRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#605",
            "-CandidateId", "return-read-proof",
            "-ReviewType", "return-read-recovery",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Review durable return read recovery.",
            "-NowUtc", "2026-01-01T00:04:30Z"
        )
        $env:HERDR_PANE_ID = "w1:p2"
        $null = Invoke-Workflow -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $returnReadRequest.workflow_ref,
            "-NowUtc", "2026-01-01T00:04:40Z"
        )
        $returnReadComplete = Invoke-Workflow -Arguments @(
            "-Action", "complete",
            "-WorkflowRef", $returnReadRequest.workflow_ref,
            "-Outcome", "PASS",
            "-ArtifactPath", $completionArtifactPath,
            "-Message", "Durable return-read proof candidate.",
            "-NowUtc", "2026-01-01T00:04:50Z"
        )
        Assert-Equal -Actual $returnReadComplete.origin_return.event.return_relay_ref -Expected "[HR:feed0001]" -Message "Recovery fixture recorded the wrong return relay."

        $env:HERDR_PANE_ID = "w1:pJ"
        $wrongReturnRead = Invoke-Workflow -Arguments @(
            "-Action", "reconcile-return-read",
            "-WorkflowRef", $returnReadRequest.workflow_ref,
            "-EvidenceRelayRef", "[HR:feed0001]",
            "-EvidenceAckRef", "[HA:wrong001]",
            "-ExpectedSourceSession", "session-source",
            "-NowUtc", "2026-01-01T00:05:00Z"
        ) -ExpectFailure
        Assert-True -Condition ($wrongReturnRead.Text -match "proof does not match") -Message "Mismatched durable read proof did not fail closed."

        $returnReadReconciled = Invoke-Workflow -Arguments @(
            "-Action", "reconcile-return-read",
            "-WorkflowRef", $returnReadRequest.workflow_ref,
            "-EvidenceRelayRef", "[HR:feed0001]",
            "-EvidenceAckRef", "[HA:return01]",
            "-ExpectedSourceSession", "session-source",
            "-NowUtc", "2026-01-01T00:05:10Z"
        )
        Assert-True -Condition ([bool]$returnReadReconciled.body_read -and -not [bool]$returnReadReconciled.duplicate) -Message "Coordinator did not reconcile the durable completion-return read proof."
        Assert-Equal -Actual $returnReadReconciled.return_read.reconciliation_policy -Expected "coordinator_durable_return_read_v1" -Message "Reconciled return read omitted its recovery policy."
        Assert-Equal -Actual $returnReadReconciled.return_read.reconciled_by_pane -Expected "w1:pJ" -Message "Reconciled return read lost coordinator identity."

        $returnReadDuplicate = Invoke-Workflow -Arguments @(
            "-Action", "reconcile-return-read",
            "-WorkflowRef", $returnReadRequest.workflow_ref,
            "-EvidenceRelayRef", "[HR:feed0001]",
            "-EvidenceAckRef", "[HA:return01]",
            "-ExpectedSourceSession", "session-source",
            "-NowUtc", "2026-01-01T00:05:20Z"
        )
        Assert-True -Condition ([bool]$returnReadDuplicate.duplicate) -Message "Duplicate durable return-read reconciliation was not idempotent."
        $returnReadStatus = Invoke-Workflow -Arguments @(
            "-Action", "status",
            "-WorkflowRef", $returnReadRequest.workflow_ref
        )
        Assert-Equal -Actual $returnReadStatus.workflows[0].completion_return_read.read_ack_ref -Expected "[HA:return01]" -Message "Status did not expose the reconciled read proof."

        Write-Output "CASE: originating builder session rotation reissues completion return safely"
        $env:HERDR_PANE_ID = "w2:p1"
        $rotationRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#600-return-rotation",
            "-CandidateId", "return-rotation-candidate",
            "-ReviewType", "return-session-rotation",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Exercise safe completion-return session rotation.",
            "-ArtifactPath", $completionArtifactPath,
            "-NowUtc", "2026-01-01T00:04:30Z"
        )
        $rotationWorkflowRef = [string]$rotationRequest.workflow_ref
        $env:HERDR_PANE_ID = "w1:p2"
        $null = Invoke-Workflow -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $rotationWorkflowRef,
            "-NoCoordinatorNotice",
            "-NowUtc", "2026-01-01T00:04:40Z"
        )
        $rotationComplete = Invoke-Workflow -Arguments @(
            "-Action", "complete",
            "-WorkflowRef", $rotationWorkflowRef,
            "-Outcome", "PASS",
            "-ArtifactPath", $completionArtifactPath,
            "-NowUtc", "2026-01-01T00:04:50Z"
        )
        Assert-True -Condition ([bool]$rotationComplete.origin_return.pending) -Message "Rotation fixture did not create a pending completion return."
        $env:HERDR_TEST_SOURCE_SESSION_MISMATCH = "1"
        $env:HERDR_PANE_ID = "w2:p1"
        $rotationReturnAck = Invoke-Workflow -Arguments @(
            "-Action", "ack-return",
            "-WorkflowRef", $rotationWorkflowRef,
            "-NowUtc", "2026-01-01T00:05:00Z"
        )
        Assert-True -Condition ([bool]$rotationReturnAck.body_read -and [bool]$rotationReturnAck.relay_ack.session_rotated) -Message "Rotated origin did not consume a lineage-bound replacement return."
        Assert-Equal -Actual $rotationReturnAck.return_read.actor_session -Expected "session-replaced" -Message "Rotated return ACK lost the new actor session."
        Assert-Equal -Actual $rotationReturnAck.return_read.source_session_rotated_from -Expected "session-source" -Message "Rotated return ACK lost the prior-session lineage."
        Assert-Equal -Actual $rotationReturnAck.return_read.effective_return_relay_ref -Expected "[HR:feed0002]" -Message "Rotated return ACK recorded the wrong effective relay."
        Assert-True -Condition ([bool]$rotationReturnAck.return_read.source_session_rotated) -Message "Rotated return ledger event omitted its rotation marker."
        $rotationAckCalls = @(Get-Calls | Where-Object { $_.action -eq "ack-read" })
        Assert-True -Condition ($rotationAckCalls.Count -gt 0) -Message "Rotated return did not invoke the coordination ACK helper."
        Assert-Equal -Actual $rotationAckCalls[-1].expected_session -Expected "session-source" -Message "Rotated return did not bind reissue authorization to the original session."
        $env:HERDR_TEST_SOURCE_SESSION_MISMATCH = "0"

        $env:HERDR_PANE_ID = "w1:p2"
        $completeDuplicate = Invoke-Workflow -Arguments @(
            "-Action", "complete",
            "-WorkflowRef", $workflowRef,
            "-Outcome", "PASS",
            "-NowUtc", "2026-01-01T00:02:30Z"
        )
        Assert-True -Condition ([bool]$completeDuplicate.duplicate) -Message "Duplicate completion was not suppressed."
        Assert-True -Condition ([bool]$completeDuplicate.origin_return.duplicate) -Message "Duplicate completion did not reuse the durable return."
        $postDuplicateCalls = Get-Calls
        Assert-Equal -Actual (@($postDuplicateCalls | Where-Object { $_.action -eq "send" -and $_.to -eq "w2:p1" }).Count) -Expected 3 -Message "Duplicate completion redelivered to the builder."
        $env:HERDR_PANE_ID = "w1:p9"
        $wrongDuplicateCompletion = Invoke-Workflow -ExpectFailure -Arguments @(
            "-Action", "complete",
            "-WorkflowRef", $workflowRef,
            "-Outcome", "PASS",
            "-NowUtc", "2026-01-01T00:02:45Z"
        )
        Assert-True -Condition ($wrongDuplicateCompletion.Text -match "not target pane") -Message "Wrong-pane duplicate completion bypassed provenance validation."
        $env:HERDR_PANE_ID = "w1:p2"
        $status = Invoke-Workflow -Arguments @(
            "-Action", "status",
            "-WorkflowRef", $workflowRef
        )
        Assert-Equal -Actual $status.workflows[0].status -Expected "completed" -Message "Completed workflow status was wrong."

        Write-Output "CASE: failed origin return and idempotent retry"
        $env:HERDR_PANE_ID = "w2:p1"
        $returnRetryRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#600-return-retry",
            "-CandidateId", "return-candidate",
            "-ReviewType", "return-routing",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Exercise origin return retry.",
            "-ArtifactPath", $returnRetryArtifactPath,
            "-NowUtc", "2026-01-01T00:03:00Z"
        )
        $returnRetryRef = [string]$returnRetryRequest.workflow_ref
        $env:HERDR_PANE_ID = "w1:p2"
        $null = Invoke-Workflow -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $returnRetryRef,
            "-NoCoordinatorNotice",
            "-NowUtc", "2026-01-01T00:03:30Z"
        )
        $callsBeforeFailedReturn = Get-Calls
        $returnsBeforeFailedReturn = @($callsBeforeFailedReturn | Where-Object { $_.action -eq "send" -and $_.to -eq "w2:p1" }).Count
        $env:HERDR_TEST_SOURCE_SESSION_MISMATCH = "1"
        $failedReturn = Invoke-Workflow -Arguments @(
            "-Action", "complete",
            "-WorkflowRef", $returnRetryRef,
            "-Outcome", "PASS",
            "-ArtifactPath", $returnRetryArtifactPath,
            "-NowUtc", "2026-01-01T00:04:00Z"
        )
        Assert-True -Condition (-not [bool]$failedReturn.origin_return.returned) -Message "Changed origin session was treated as returned."
        Assert-True -Condition ([string]$failedReturn.origin_return.error -match "exact native session") -Message "Changed origin-session refusal was not explained."
        $callsAfterFailedReturn = Get-Calls
        Assert-Equal -Actual (@($callsAfterFailedReturn | Where-Object { $_.action -eq "send" -and $_.to -eq "w2:p1" }).Count) -Expected $returnsBeforeFailedReturn -Message "Failed origin proof still delivered a completion relay."
        $failedReturnScan = Invoke-Workflow -Arguments @(
            "-Action", "scan",
            "-NowUtc", "2026-01-01T00:04:30Z"
        )
        $returnAlerts = @($failedReturnScan.new_alerts | Where-Object {
                $_.workflow_ref -eq $returnRetryRef
            })
        Assert-Equal -Actual $returnAlerts.Count -Expected 1 -Message "Failed origin return did not create a workflow alert."
        Assert-Equal -Actual $returnAlerts[0].alert_kind -Expected "completion_return_failed" -Message "Failed origin return used the wrong alert kind."

        $env:HERDR_TEST_SOURCE_SESSION_MISMATCH = "0"
        $retriedReturn = Invoke-Workflow -Arguments @(
            "-Action", "complete",
            "-WorkflowRef", $returnRetryRef,
            "-Outcome", "PASS",
            "-ArtifactPath", $returnRetryArtifactPath,
            "-NowUtc", "2026-01-01T00:05:00Z"
        )
        Assert-True -Condition ([bool]$retriedReturn.duplicate) -Message "Return retry rewrote the durable completion."
        Assert-True -Condition (-not [bool]$retriedReturn.origin_return.returned -and [bool]$retriedReturn.origin_return.pending) -Message "Restored origin session did not receive one pending read-proof relay."
        $callsAfterReturnRetry = Get-Calls
        Assert-Equal -Actual (@($callsAfterReturnRetry | Where-Object { $_.action -eq "send" -and $_.to -eq "w2:p1" }).Count) -Expected ($returnsBeforeFailedReturn + 1) -Message "Restored origin return was not relayed exactly once."
        $env:HERDR_PANE_ID = "w2:p1"
        $retriedReturnAck = Invoke-Workflow -Arguments @(
            "-Action", "ack-return",
            "-WorkflowRef", $returnRetryRef,
            "-NowUtc", "2026-01-01T00:05:15Z"
        )
        Assert-True -Condition ([bool]$retriedReturnAck.body_read) -Message "Restored origin did not prove reading the retried verdict body."
        $env:HERDR_PANE_ID = "w1:p2"
        $settledReturn = Invoke-Workflow -Arguments @(
            "-Action", "complete",
            "-WorkflowRef", $returnRetryRef,
            "-Outcome", "PASS",
            "-ArtifactPath", $returnRetryArtifactPath,
            "-NowUtc", "2026-01-01T00:05:30Z"
        )
        Assert-True -Condition ([bool]$settledReturn.origin_return.duplicate) -Message "Settled origin return was not recognized as idempotent."
        $callsAfterSettledReturn = Get-Calls
        Assert-Equal -Actual (@($callsAfterSettledReturn | Where-Object { $_.action -eq "send" -and $_.to -eq "w2:p1" }).Count) -Expected ($returnsBeforeFailedReturn + 1) -Message "Settled origin return redelivered."

        Write-Output "CASE: completion reconciliation proof failures"
        $env:HERDR_PANE_ID = "w2:p1"
        $reconcileRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#604",
            "-CandidateId", "code-sha+artifact-sha",
            "-ReviewType", "reconcile-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Review the reconciliation candidate.",
            "-ArtifactPath", $reconcileArtifactPath,
            "-NowUtc", "2026-01-01T00:10:00Z"
        )
        $reconcileWorkflowRef = [string]$reconcileRequest.workflow_ref
        $reconcileRequestRelay = [string]$reconcileRequest.relay_ref
        $env:HERDR_PANE_ID = "w1:p2"
        $null = Invoke-Workflow -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $reconcileWorkflowRef,
            "-NowUtc", "2026-01-01T00:10:30Z",
            "-NoCoordinatorNotice"
        )
        $artifactText = @"
# Reconciliation review
Request $reconcileRequestRelay / $reconcileWorkflowRef
Exact candidate code-sha + artifact-sha
Verdict PASS
"@
        Set-Content -LiteralPath $reconcileArtifactPath -Value $artifactText -Encoding utf8
        Set-Content -LiteralPath $wrongArtifactPath -Value $artifactText -Encoding utf8
        $reconcileArtifactHash = (Get-FileHash -LiteralPath $reconcileArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $wrongArtifactHash = (Get-FileHash -LiteralPath $wrongArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $evidenceRelay = "[HR:feedcafe]"
        $requestRelayId = $reconcileRequestRelay.Substring(4, 8)
        $requestRelayReference = "[re HR:$requestRelayId]"
        $evidenceLine = "- [2026-01-01 00:11 +00:00] FROM w1:p2 TO coordinator: $evidenceRelay $requestRelayReference $reconcileWorkflowRef PASS exact candidate code-sha + artifact-sha. Artifact: $reconcileArtifactPath"
        $referenceLine = "- [2026-01-01 00:12 +00:00] FROM w1:pJ TO w2:p1: [HR:deadbeef] Follow-up quotes log line 1 (FROM w1:p2 TO coordinator: $evidenceRelay ...) but is not its authoritative entry."
        Set-Content -LiteralPath $coordLogPath -Value @($evidenceLine, $referenceLine) -Encoding utf8
        $reconcileArgs = @(
            "-Action", "reconcile-completion",
            "-WorkflowRef", $reconcileWorkflowRef,
            "-PaneId", "w1:p2",
            "-ExpectedTargetSession", "session-target",
            "-CandidateId", "code-sha+artifact-sha",
            "-Outcome", "PASS",
            "-ArtifactPath", $reconcileArtifactPath,
            "-ArtifactSha256", $reconcileArtifactHash,
            "-EvidenceRelayRef", $evidenceRelay,
            "-Message", "Fixture reconciliation."
        )

        $wrongCaller = Invoke-Workflow -Arguments $reconcileArgs -ExpectFailure
        Assert-True -Condition ($wrongCaller.Text -match "coordinator-only") -Message "Non-coordinator reconciliation did not fail closed."
        $env:HERDR_PANE_ID = "w1:pJ"

        Write-Output "CASE: reconciliation evidence relay anchoring"
        Set-Content -LiteralPath $coordLogPath -Value $referenceLine -Encoding utf8
        $referenceOnly = Invoke-Workflow -Arguments $reconcileArgs -ExpectFailure
        Assert-True -Condition ($referenceOnly.Text -match "exactly one durable evidence entry") -Message "A textual relay reference was treated as authoritative evidence."
        $duplicateEvidenceLine = $evidenceLine -replace "00:11", "00:13"
        Set-Content -LiteralPath $coordLogPath -Value @($evidenceLine, $duplicateEvidenceLine, $referenceLine) -Encoding utf8
        $duplicateEvidence = Invoke-Workflow -Arguments $reconcileArgs -ExpectFailure
        Assert-True -Condition ($duplicateEvidence.Text -match "exactly one durable evidence entry") -Message "Duplicate authoritative evidence entries did not fail closed."
        Set-Content -LiteralPath $coordLogPath -Value @($evidenceLine, $referenceLine) -Encoding utf8
        $wrongRequestRelayLine = $evidenceLine.Replace($requestRelayReference, "[re HR:baadf00d]")
        Set-Content -LiteralPath $coordLogPath -Value @($wrongRequestRelayLine, $referenceLine) -Encoding utf8
        $wrongRequestRelay = Invoke-Workflow -Arguments $reconcileArgs -ExpectFailure
        Assert-True -Condition ($wrongRequestRelay.Text -match "exact" -and $wrongRequestRelay.Text -match "request" -and $wrongRequestRelay.Text -match "relay") -Message "Wrong request relay evidence did not fail closed."
        $substringRequestRelayLine = $evidenceLine.Replace($requestRelayReference, "[re HR:${requestRelayId}0]")
        Set-Content -LiteralPath $coordLogPath -Value @($substringRequestRelayLine, $referenceLine) -Encoding utf8
        $substringRequestRelay = Invoke-Workflow -Arguments $reconcileArgs -ExpectFailure
        Assert-True -Condition ($substringRequestRelay.Text -match "exact" -and $substringRequestRelay.Text -match "request" -and $substringRequestRelay.Text -match "relay") -Message "Request relay substring evidence was accepted."
        Set-Content -LiteralPath $coordLogPath -Value @($evidenceLine, $referenceLine) -Encoding utf8

        $wrongPaneArgs = @($reconcileArgs)
        $wrongPaneArgs[([array]::IndexOf($wrongPaneArgs, "w1:p2"))] = "w1:p3"
        $wrongPane = Invoke-Workflow -Arguments $wrongPaneArgs -ExpectFailure
        Assert-True -Condition ($wrongPane.Text -match "target pane") -Message "Wrong target pane reconciliation did not fail closed."
        $wrongSessionArgs = @($reconcileArgs)
        $wrongSessionArgs[([array]::IndexOf($wrongSessionArgs, "session-target"))] = "wrong-session"
        $wrongSession = Invoke-Workflow -Arguments $wrongSessionArgs -ExpectFailure
        Assert-True -Condition ($wrongSession.Text -match "target session") -Message "Wrong target session reconciliation did not fail closed."
        $wrongCandidateArgs = @($reconcileArgs)
        $wrongCandidateArgs[([array]::IndexOf($wrongCandidateArgs, "code-sha+artifact-sha"))] = "wrong-candidate"
        $wrongCandidate = Invoke-Workflow -Arguments $wrongCandidateArgs -ExpectFailure
        Assert-True -Condition ($wrongCandidate.Text -match "candidate") -Message "Wrong candidate reconciliation did not fail closed."
        $wrongArtifactArgs = @($reconcileArgs)
        $wrongArtifactArgs[([array]::IndexOf($wrongArtifactArgs, $reconcileArtifactPath))] = $wrongArtifactPath
        $wrongArtifactArgs[([array]::IndexOf($wrongArtifactArgs, $reconcileArtifactHash))] = $wrongArtifactHash
        $wrongArtifact = Invoke-Workflow -Arguments $wrongArtifactArgs -ExpectFailure
        Assert-True -Condition ($wrongArtifact.Text -match "artifact path") -Message "Wrong artifact reconciliation did not fail closed."
        $wrongHashArgs = @($reconcileArgs)
        $wrongHashArgs[([array]::IndexOf($wrongHashArgs, $reconcileArtifactHash))] = ("0" * 64)
        $wrongHash = Invoke-Workflow -Arguments $wrongHashArgs -ExpectFailure
        Assert-True -Condition ($wrongHash.Text -match "artifact hash") -Message "Wrong artifact hash reconciliation did not fail closed."
        $preReconcileStatus = Invoke-Workflow -Arguments @(
            "-Action", "status",
            "-WorkflowRef", $reconcileWorkflowRef
        )
        Assert-Equal -Actual $preReconcileStatus.workflows[0].status -Expected "work_acknowledged" -Message "A failed reconciliation mutated workflow state."

        Write-Output "CASE: legitimate and duplicate completion reconciliation"
        $reconcileReturnsBefore = @((Get-Calls) | Where-Object { $_.action -eq "send" -and $_.to -eq "w2:p1" }).Count
        $reconciled = Invoke-Workflow -Arguments $reconcileArgs
        Assert-True -Condition (-not [bool]$reconciled.duplicate) -Message "Legitimate reconciliation was marked duplicate."
        Assert-Equal -Actual $reconciled.completion.event -Expected "completion_reconciled" -Message "Reconciliation wrote the wrong event type."
        Assert-Equal -Actual $reconciled.completion.artifact_sha256 -Expected $reconcileArtifactHash -Message "Reconciliation lost the artifact hash."
        Assert-True -Condition ([bool]$reconciled.origin_return.pending -and -not [bool]$reconciled.origin_return.returned) -Message "Reconciled completion did not wait for origin body-read proof."
        Assert-Equal -Actual @((Get-Calls) | Where-Object { $_.action -eq "send" -and $_.to -eq "w2:p1" }).Count -Expected ($reconcileReturnsBefore + 1) -Message "Reconciled completion did not add exactly one tracked origin return."
        $reconciledStatus = Invoke-Workflow -Arguments @(
            "-Action", "status",
            "-WorkflowRef", $reconcileWorkflowRef
        )
        Assert-Equal -Actual $reconciledStatus.workflows[0].status -Expected "completed" -Message "Reconciled workflow did not derive completed status."
        $env:HERDR_PANE_ID = "w2:p1"
        $reconciledAck = Invoke-Workflow -Arguments @(
            "-Action", "ack-return",
            "-WorkflowRef", $reconcileWorkflowRef,
            "-NowUtc", "2026-01-01T00:12:30Z"
        )
        Assert-True -Condition ([bool]$reconciledAck.body_read) -Message "Reconciled verdict body was not acknowledged by its origin."
        $env:HERDR_PANE_ID = "w1:pJ"
        $duplicateReconcile = Invoke-Workflow -Arguments $reconcileArgs
        Assert-True -Condition ([bool]$duplicateReconcile.duplicate) -Message "Duplicate reconciliation was not idempotent."
        Assert-True -Condition ([bool]$duplicateReconcile.origin_return.duplicate) -Message "Duplicate reconciliation did not reuse the durable origin return."
        Assert-Equal -Actual @((Get-Calls) | Where-Object { $_.action -eq "send" -and $_.to -eq "w2:p1" }).Count -Expected ($reconcileReturnsBefore + 1) -Message "Duplicate reconciliation redelivered to the origin."

        Write-Output "CASE: conflicting reconciled outcome refusal"
        $conflictArgs = @($reconcileArgs)
        $conflictArgs[([array]::IndexOf($conflictArgs, "PASS"))] = "BLOCK"
        $conflict = Invoke-Workflow -Arguments $conflictArgs -ExpectFailure
        Assert-True -Condition ($conflict.Text -match "conflicts with the existing") -Message "Conflicting reconciled outcome did not fail closed."

        Write-Output "CASE: missing ACK alert and notification idempotency"
        $env:HERDR_PANE_ID = "w2:p1"
        $request2 = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#601",
            "-CandidateId", "def456",
            "-ReviewType", "static-review",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Review candidate two.",
            "-AckTimeoutSeconds", "60",
            "-NowUtc", "2026-01-01T01:00:00Z"
        )
        $scan = Invoke-Workflow -Arguments @(
            "-Action", "scan",
            "-Notify",
            "-NowUtc", "2026-01-01T01:02:00Z"
        )
        Assert-Equal -Actual @($scan.new_alerts).Count -Expected 1 -Message "Missing ACK did not create one alert."
        Assert-Equal -Actual $scan.new_alerts[0].alert_kind -Expected "ack_timeout" -Message "Wrong missing-ACK alert kind."
        $scanAgain = Invoke-Workflow -Arguments @(
            "-Action", "scan",
            "-Notify",
            "-NowUtc", "2026-01-01T01:03:00Z"
        )
        Assert-Equal -Actual @($scanAgain.new_alerts).Count -Expected 0 -Message "Repeated scan duplicated the ACK alert."
        $notificationCalls = Get-Calls
        Assert-Equal -Actual (@($notificationCalls | Where-Object {
                    $_ -is [string] -and $_ -match "notification"
                }).Count) -Expected 0 -Message "Call log parser produced an unexpected notification record."
        $rawCalls = Get-Content -LiteralPath $callLogPath -Raw
        Assert-Equal -Actual ([regex]::Matches($rawCalls, "notification show").Count) -Expected 1 -Message "ACK timeout notification was not emitted exactly once."

        Write-Output "CASE: watcher failure reconciliation"
        $request3 = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#602",
            "-CandidateId", "ghi789",
            "-ReviewType", "merge-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Review candidate three.",
            "-AckTimeoutSeconds", "300",
            "-NowUtc", "2026-01-01T02:00:00Z"
        )
        $token3 = [string]$request3.request.delivery_token
        $watchRecord = [ordered]@{
            pane_id = "w1:p2"
            agent = "codex"
            token = $token3
            submitted = $false
            delivery_state = "queued_recovery_failed"
            error = "fixture watcher failure"
        } | ConvertTo-Json -Compress
        $unrelatedWatchRecord = [ordered]@{
            pane_id = "w1:p2"
            agent = "codex"
            token = "[HC:deadbeef]"
            submitted = $true
            delivery_state = "accepted"
            error = $null
        } | ConvertTo-Json -Compress
        Set-Content -LiteralPath $watchLogPath -Value @(
            "- [2026-01-01 02:00 +00:00] FROM queued-watcher TO w1:p2: $watchRecord",
            "- [2026-01-01 02:00 +00:00] FROM queued-watcher TO w1:p2: $unrelatedWatchRecord"
        ) -Encoding utf8
        $watchScan = Invoke-Workflow -Arguments @(
            "-Action", "scan",
            "-NowUtc", "2026-01-01T02:01:00Z"
        )
        $transportAlerts = @($watchScan.new_alerts | Where-Object { $_.workflow_ref -eq $request3.workflow_ref })
        Assert-Equal -Actual $transportAlerts.Count -Expected 1 -Message "Watcher failure was not reconciled."
        Assert-Equal -Actual $transportAlerts[0].alert_kind -Expected "transport_failed" -Message "Wrong watcher-failure alert kind."

        Write-Output "CASE: bounded watchdog scan"
        $request4 = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#603",
            "-CandidateId", "jkl012",
            "-ReviewType", "release-review",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review",
            "-Message", "Review candidate four.",
            "-AckTimeoutSeconds", "60",
            "-NowUtc", "2026-01-01T03:00:00Z"
        )
        $watchdogRaw = & pwsh -NoProfile -File $watchdogPath `
            -Iterations 2 `
            -IntervalSeconds 1 `
            -NowUtc "2026-01-01T03:02:00Z" `
            -LedgerPath $ledgerPath `
            -WatchLogPath $watchLogPath `
            -CoordinationLogPath $coordLogPath 2>&1
        Assert-Equal -Actual $LASTEXITCODE -Expected 0 -Message "Bounded watchdog failed: $($watchdogRaw -join [Environment]::NewLine)"
        $watchdog = ($watchdogRaw -join [Environment]::NewLine) | ConvertFrom-Json -Depth 30
        Assert-Equal -Actual $watchdog.iterations -Expected 2 -Message "Watchdog did not run the requested iterations."
        Assert-Equal -Actual $watchdog.results[0].new_alert_count -Expected 1 -Message "Watchdog did not emit the due ACK alert."
        Assert-Equal -Actual $watchdog.results[1].new_alert_count -Expected 0 -Message "Watchdog repeated an existing alert."
        $watchdogAlerts = @($watchdog.results[0].new_alerts | Where-Object { $_.workflow_ref -eq $request4.workflow_ref })
        Assert-Equal -Actual $watchdogAlerts.Count -Expected 1 -Message "Watchdog alert was not tied to the expected workflow."

        Write-Output "CASE: completion before durable work ACK fails closed"
        $env:HERDR_PANE_ID = "w2:p1"
        $preAckRequest = Invoke-Workflow -Arguments @(
            "-Action", "request", "-TaskId", "#604", "-CandidateId", "preack",
            "-ReviewType", "preack-gate", "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review", "-Message", "Do not complete before ACK.",
            "-NowUtc", "2026-01-01T04:00:00Z"
        )
        $env:HERDR_PANE_ID = "w1:p2"
        $preAckCompletion = Invoke-Workflow -ExpectFailure -Arguments @(
            "-Action", "complete", "-WorkflowRef", [string]$preAckRequest.workflow_ref,
            "-Outcome", "PASS", "-ArtifactPath", $completionArtifactPath,
            "-NowUtc", "2026-01-01T04:01:00Z"
        )
        Assert-True -Condition ($preAckCompletion.Text -match 'no durable work ACK') -Message "Pre-ACK completion refusal was not explained."

        Write-Output "CASE: reservation-only workflow resumes exact request delivery"
        $env:HERDR_PANE_ID = "w2:p1"
        $resumeArgs = @(
            "-Action", "request", "-TaskId", "#605", "-CandidateId", "resume-only",
            "-ReviewType", "crash-recovery", "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review", "-Message", "Resume the reserved request.",
            "-NowUtc", "2026-01-01T04:10:00Z"
        )
        $resumeSeed = Invoke-Workflow -Arguments $resumeArgs
        $resumeRef = [string]$resumeSeed.workflow_ref
        $retainedLedgerLines = [Collections.Generic.List[string]]::new()
        foreach ($ledgerLine in Get-Content -LiteralPath $ledgerPath) {
            $ledgerEvent = $ledgerLine | ConvertFrom-Json -Depth 20
            if ([string]$ledgerEvent.workflow_ref -eq $resumeRef -and [string]$ledgerEvent.event -in @("request", "request_delivery_reserved")) {
                continue
            }
            $retainedLedgerLines.Add([string]$ledgerLine)
        }
        Set-Content -LiteralPath $ledgerPath -Value @($retainedLedgerLines) -Encoding utf8
        $resumeRetryArgs = @(
            "-Action", "request", "-TaskId", "#605", "-CandidateId", "resume-only",
            "-ReviewType", "crash-recovery", "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review", "-Message", "Resume the reserved request.",
            "-NowUtc", "2026-01-01T04:11:00Z"
        )
        $resumedRequest = Invoke-Workflow -Arguments $resumeRetryArgs
        Assert-True -Condition ([bool]$resumedRequest.created -and [bool]$resumedRequest.resumed -and -not [bool]$resumedRequest.duplicate) -Message "Reservation-only request did not resume delivery."
        Assert-Equal -Actual $resumedRequest.workflow_ref -Expected $resumeRef -Message "Reservation recovery changed the workflow identity."
        Assert-Equal -Actual $resumedRequest.relay_ref -Expected $resumeSeed.relay_ref -Message "Reservation recovery changed the durable relay identity."
        Assert-Equal -Actual $resumedRequest.request.ack_deadline_utc -Expected $resumeSeed.request.ack_deadline_utc -Message "Reservation recovery extended the original ACK deadline."

        Write-Output "CASE: job-key serialization resists delimiter collisions and normalizes NFC"
        $collisionA = Invoke-Workflow -Arguments @(
            "-Action", "request", "-TaskId", "a|b", "-CandidateId", "c", "-ReviewType", "d",
            "-PaneId", "w1:p2", "-ExpectedTabLabel", "#600 - Review", "-Message", "Tuple A.",
            "-NowUtc", "2026-01-01T04:20:00Z"
        )
        $collisionB = Invoke-Workflow -Arguments @(
            "-Action", "request", "-TaskId", "a", "-CandidateId", "b|c", "-ReviewType", "d",
            "-PaneId", "w1:p2", "-ExpectedTabLabel", "#600 - Review", "-Message", "Tuple B.",
            "-NowUtc", "2026-01-01T04:20:01Z"
        )
        Assert-True -Condition ([bool]$collisionA.created -and [bool]$collisionB.created -and $collisionA.workflow_ref -ne $collisionB.workflow_ref) -Message "Length-ambiguous workflow tuples collided."
        $composedCandidate = "caf$([char]0x00E9)"
        $decomposedCandidate = "cafe$([char]0x0301)"
        $unicodeA = Invoke-Workflow -Arguments @(
            "-Action", "request", "-TaskId", "unicode", "-CandidateId", $composedCandidate, "-ReviewType", "nfc",
            "-PaneId", "w1:p2", "-ExpectedTabLabel", "#600 - Review", "-Message", "Unicode A.",
            "-NowUtc", "2026-01-01T04:21:00Z"
        )
        $unicodeB = Invoke-Workflow -Arguments @(
            "-Action", "request", "-TaskId", "unicode", "-CandidateId", $decomposedCandidate, "-ReviewType", "nfc",
            "-PaneId", "w1:p2", "-ExpectedTabLabel", "#600 - Review", "-Message", "Unicode B.",
            "-NowUtc", "2026-01-01T04:21:01Z"
        )
        Assert-True -Condition ([bool]$unicodeA.created -and [bool]$unicodeB.duplicate) -Message "Canonically equivalent Unicode workflow identity was not deduplicated."

        Write-Output "CASE: concurrent conflicting completions append exactly one verdict"
        $concurrentRequest = Invoke-Workflow -Arguments @(
            "-Action", "request", "-TaskId", "#606", "-CandidateId", "concurrent-verdict",
            "-ReviewType", "race-gate", "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "#600 - Review", "-Message", "Concurrent completion fixture.",
            "-NowUtc", "2026-01-01T04:30:00Z"
        )
        $env:HERDR_PANE_ID = "w1:p2"
        $null = Invoke-Workflow -Arguments @(
            "-Action", "ack", "-WorkflowRef", [string]$concurrentRequest.workflow_ref,
            "-NowUtc", "2026-01-01T04:30:10Z"
        )
        $racePwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $raceOut1 = Join-Path $tempRoot "complete-race-1.out"
        $raceOut2 = Join-Path $tempRoot "complete-race-2.out"
        $raceErr1 = Join-Path $tempRoot "complete-race-1.err"
        $raceErr2 = Join-Path $tempRoot "complete-race-2.err"
        $commonRaceArgs = @(
            "-NoProfile", "-File", $workflowPath, "-Action", "complete",
            "-WorkflowRef", [string]$concurrentRequest.workflow_ref,
            "-ArtifactPath", $completionArtifactPath,
            "-LedgerPath", $ledgerPath, "-WatchLogPath", $watchLogPath,
            "-CoordinationLogPath", $coordLogPath, "-CoordinationHelperPath", $fakeCoordPath,
            "-NowUtc", "2026-01-01T04:30:20Z"
        )
        $raceProcess1 = Start-Process -FilePath $racePwsh -ArgumentList @($commonRaceArgs + @("-Outcome", "PASS")) -RedirectStandardOutput $raceOut1 -RedirectStandardError $raceErr1 -PassThru
        $raceProcess2 = Start-Process -FilePath $racePwsh -ArgumentList @($commonRaceArgs + @("-Outcome", "BLOCK")) -RedirectStandardOutput $raceOut2 -RedirectStandardError $raceErr2 -PassThru
        Assert-True -Condition ($raceProcess1.WaitForExit(30000) -and $raceProcess2.WaitForExit(30000)) -Message "Concurrent completion processes timed out."
        $raceProcess1.Refresh(); $raceProcess2.Refresh()
        $raceSuccessCount = @(@($raceProcess1.ExitCode, $raceProcess2.ExitCode) | Where-Object { $_ -eq 0 }).Count
        Assert-Equal -Actual $raceSuccessCount -Expected 1 -Message "Concurrent conflicting completions did not produce exactly one success."
        $concurrentCompletionEvents = @(Get-Content -LiteralPath $ledgerPath | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } | Where-Object {
                $_.event -eq "completed" -and [string]$_.workflow_ref -eq [string]$concurrentRequest.workflow_ref
            })
        Assert-Equal -Actual $concurrentCompletionEvents.Count -Expected 1 -Message "Concurrent conflicting completions appended more than one durable verdict."

        Write-Output "CASE: duplicate completion refuses changed artifact content"
        $originalCompletionArtifact = Get-Content -LiteralPath $completionArtifactPath -Raw
        try {
            Set-Content -LiteralPath $completionArtifactPath -Value "BLOCK. Artifact replaced after completion." -Encoding utf8
            $changedArtifactRetry = Invoke-Workflow -ExpectFailure -Arguments @(
                "-Action", "complete", "-WorkflowRef", $workflowRef, "-Outcome", "PASS",
                "-ArtifactPath", $completionArtifactPath, "-NowUtc", "2026-01-01T04:40:00Z"
            )
            Assert-True -Condition ($changedArtifactRetry.Text -match 'artifact content changed') -Message "Changed completion artifact retry was not rejected."
        }
        finally {
            Set-Content -LiteralPath $completionArtifactPath -Value $originalCompletionArtifact -NoNewline -Encoding utf8
        }

        Write-Output "CASE: subtitle currency skips non-ticket task labels"
        $env:HERDR_PANE_ID = "w2:p1"
        $env:HERDR_TEST_STATUS = "idle"
        $env:HERDR_TEST_DETECTION = "ready prompt"
        $env:HERDR_TEST_TAB_LABEL = "STM-WB-O1"
        $env:HERDR_TEST_PANE_SUBTITLE = "#870 - stale ticket"
        $namingCallsBeforeSkip = @(Get-Calls | Where-Object { $_.action -eq "name-request" }).Count
        $subtitleSkipped = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "adhoc-sweep",
            "-CandidateId", "subtitle-skip",
            "-ReviewType", "final-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "STM-WB-O1",
            "-Message", "Ad-hoc labels carry no ticket token.",
            "-NowUtc", "2026-01-01T05:00:00Z"
        )
        Assert-True -Condition ([bool]$subtitleSkipped.created) -Message "Subtitle-skip request was not created."
        Assert-Equal -Actual $subtitleSkipped.subtitle_task_token -Expected $null -Message "Malformed TaskId produced a subtitle token."
        Assert-True -Condition (-not [bool]$subtitleSkipped.subtitle_stale) -Message "Malformed TaskId warned about subtitle staleness."
        Assert-Equal -Actual $subtitleSkipped.subtitle_hint -Expected $null -Message "Malformed TaskId emitted a naming hint."
        Assert-Equal `
            -Actual @(Get-Calls | Where-Object { $_.action -eq "name-request" }).Count `
            -Expected $namingCallsBeforeSkip `
            -Message "Malformed TaskId still fired a naming request."

        Write-Output "CASE: current subtitle produces no naming warning"
        $env:HERDR_TEST_PANE_SUBTITLE = "#900 - live ticket"
        $subtitleCurrent = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#900",
            "-CandidateId", "subtitle-current",
            "-ReviewType", "final-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "STM-WB-O1",
            "-Message", "Subtitle already names the ticket.",
            "-NowUtc", "2026-01-01T05:05:00Z"
        )
        Assert-True -Condition ([bool]$subtitleCurrent.created) -Message "Current-subtitle request was not created."
        Assert-Equal -Actual $subtitleCurrent.subtitle_task_token -Expected "#900" -Message "Current-subtitle request lost its ticket token."
        Assert-True -Condition (-not [bool]$subtitleCurrent.subtitle_stale) -Message "A subtitle carrying the TaskId was reported stale."
        Assert-True -Condition (-not [bool]$subtitleCurrent.subtitle_request_fired) -Message "A current subtitle still fired a naming request."
        Assert-Equal -Actual $subtitleCurrent.subtitle_hint -Expected $null -Message "A current subtitle emitted a naming hint."

        Write-Output "CASE: stale subtitle warns and auto-fires the caller's own naming request"
        $env:HERDR_TEST_PANE_SUBTITLE = "#870 - stale ticket"
        $staleSubtitleRequest = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#901",
            "-CandidateId", "subtitle-stale",
            "-ReviewType", "final-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "STM-WB-O1",
            "-Message", "Subtitle still names the previous ticket.",
            "-NowUtc", "2026-01-01T05:10:00Z"
        )
        Assert-True -Condition ([bool]$staleSubtitleRequest.created) -Message "Stale-subtitle request was not created."
        Assert-True -Condition ([bool]$staleSubtitleRequest.subtitle_stale) -Message "A stale subtitle was not reported."
        Assert-Equal -Actual $staleSubtitleRequest.subtitle_current -Expected "#870 - stale ticket" -Message "Stale subtitle was not reported verbatim."
        Assert-True -Condition ([string]$staleSubtitleRequest.subtitle_hint -match '-Action name-request') -Message "Stale subtitle did not emit a runnable naming hint."
        Assert-True -Condition ([bool]$staleSubtitleRequest.subtitle_request_fired) -Message "Stale subtitle did not auto-fire the naming request."
        Assert-Equal -Actual $staleSubtitleRequest.subtitle_request_error -Expected $null -Message "A successful naming request recorded an error."
        $namingCall = @(Get-Calls | Where-Object { $_.action -eq "name-request" } | Select-Object -Last 1)[0]
        Assert-Equal -Actual $namingCall.from -Expected "w2:p1" -Message "Naming request was not sent from the calling pane."
        Assert-Equal -Actual $namingCall.repo_code -Expected "STM" -Message "Naming request lost the repo code parsed from the canonical name."
        Assert-Equal -Actual $namingCall.lane_code -Expected "WB" -Message "Naming request lost the lane code parsed from the canonical name."
        Assert-Equal -Actual $namingCall.role_code -Expected "O" -Message "Naming request lost the role code parsed from the canonical name."
        Assert-Equal -Actual $namingCall.issue_number -Expected "901" -Message "Naming request did not carry the action's ticket."
        Assert-Equal -Actual $namingCall.previous_work -Expected "#870 - stale ticket" -Message "Naming request did not carry the superseded subtitle."

        Write-Output "CASE: acking pane requests its own name at work ACK"
        $staleAckRef = [string]$staleSubtitleRequest.workflow_ref
        $env:HERDR_PANE_ID = "w1:p2"
        $ackNamingBefore = @(Get-Calls | Where-Object { $_.action -eq "name-request" }).Count
        $subtitleAck = Invoke-Workflow -Arguments @(
            "-Action", "ack",
            "-WorkflowRef", $staleAckRef,
            "-Message", "STARTED",
            "-NowUtc", "2026-01-01T05:11:00Z"
        )
        Assert-True -Condition (-not [bool]$subtitleAck.duplicate) -Message "Subtitle-currency ACK was marked duplicate."
        Assert-Equal -Actual $subtitleAck.subtitle_task_token -Expected "#901" -Message "ACK did not recover the TaskId from the ledger."
        Assert-True -Condition ([bool]$subtitleAck.subtitle_stale) -Message "ACK did not report the acking pane's stale subtitle."
        Assert-True -Condition ([bool]$subtitleAck.subtitle_request_fired) -Message "ACK did not auto-fire the acking pane's naming request."
        Assert-Equal `
            -Actual @(Get-Calls | Where-Object { $_.action -eq "name-request" }).Count `
            -Expected ($ackNamingBefore + 1) `
            -Message "ACK naming request was not sent exactly once."
        $ackNamingCall = @(Get-Calls | Where-Object { $_.action -eq "name-request" } | Select-Object -Last 1)[0]
        Assert-Equal -Actual $ackNamingCall.from -Expected "w1:p2" -Message "ACK naming request was not sent from the acking pane itself."
        Assert-Equal -Actual $ackNamingCall.issue_number -Expected "901" -Message "ACK naming request did not carry the workflow ticket."

        Write-Output "CASE: naming auto-fire failure never fails the carrying action"
        $env:HERDR_PANE_ID = "w2:p1"
        $env:HERDR_TEST_NAME_REQUEST_FAIL = "1"
        $namingFailure = Invoke-Workflow -Arguments @(
            "-Action", "request",
            "-TaskId", "#902",
            "-CandidateId", "subtitle-fire-failure",
            "-ReviewType", "final-gate",
            "-PaneId", "w1:p2",
            "-ExpectedTabLabel", "STM-WB-O1",
            "-Message", "Naming failure must not fail the request.",
            "-NowUtc", "2026-01-01T05:15:00Z"
        )
        Assert-True -Condition ([bool]$namingFailure.created) -Message "A failed naming request killed the parent request."
        Assert-True -Condition ([bool]$namingFailure.request.transport_accepted) -Message "A failed naming request blocked request delivery."
        Assert-True -Condition ([bool]$namingFailure.subtitle_stale) -Message "Naming-failure case lost its staleness warning."
        Assert-True -Condition (-not [bool]$namingFailure.subtitle_request_fired) -Message "A failed naming request was reported as fired."
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$namingFailure.subtitle_request_error)) -Message "A failed naming request recorded no error."
        $env:HERDR_TEST_NAME_REQUEST_FAIL = "0"
        $env:HERDR_TEST_PANE_SUBTITLE = ""
        $env:HERDR_TEST_TAB_LABEL = ""

        Write-Output "CASE: live Ubuntu request/ACK/complete/ack-return round-trip"
        $roundtripPath = Join-Path $PSScriptRoot "test_herdr_workflow_roundtrip.ps1"
        $roundtripOutput = & pwsh -NoProfile -File $roundtripPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Live Ubuntu workflow round-trip regression failed: $($roundtripOutput -join [Environment]::NewLine)"
        }
        $roundtripOutput | ForEach-Object { Write-Output $_ }

        Write-Output "PASS: herdr workflow ledger, ACKs, preflight, alerts, and watchdog"
    }
    finally {
        $env:PATH = $originalPath
        $env:HERDR_ENV = $originalHerdrEnv
        $env:HERDR_PANE_ID = $originalPaneId
        Remove-Item Env:HERDR_TEST_CALL_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_STATUS -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_MISSING_SESSION -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_SOURCE_SESSION_MISMATCH -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_TARGET_SESSION_ROTATED -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_PROFILE -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_PROFILE_MISMATCH -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_PROFILE_MALFORMED -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_TARGET_TAB_ID -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_DETECTION -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_DELIVERY_FAIL -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_PANE_SUBTITLE -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_TAB_LABEL -ErrorAction SilentlyContinue
        Remove-Item Env:HERDR_TEST_NAME_REQUEST_FAIL -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

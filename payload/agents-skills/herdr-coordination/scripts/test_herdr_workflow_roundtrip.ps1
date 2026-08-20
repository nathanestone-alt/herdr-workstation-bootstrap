[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workflowPath = Join-Path $PSScriptRoot "herdr_workflow.ps1"
$coordinationPath = Join-Path $PSScriptRoot "herdr_coordination.ps1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-workflow-roundtrip-$([Guid]::NewGuid().ToString('N'))"
$paneRegistryPath = Join-Path $tempRoot "pane-registry.jsonl"
$stateRoot = Join-Path $tempRoot "state"
$fakeHerdrPath = Join-Path $tempRoot $(if ([IO.Path]::DirectorySeparatorChar -eq [char]92) { "herdr.ps1" } else { "herdr" })
$ledgerPath = Join-Path $tempRoot "ledger.jsonl"
$watchLogPath = Join-Path $tempRoot "watch.md"
$coordinationLogPath = Join-Path $tempRoot "coordination.md"
$artifactPath = Join-Path $tempRoot "verdict.md"
$callLogPath = Join-Path $tempRoot "calls.log"
$pwshExecutable = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

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

function Invoke-RoundtripStep {
    param(
        [Parameter(Mandatory)][string]$CallerPane,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $env:HERDR_PANE_ID = $CallerPane
    $env:HERDR_AGENT_SESSION_ID = if ($CallerPane -eq "w2:p1") { "session-source" } else { "session-target" }
    $output = & $pwshExecutable -NoProfile -File $workflowPath @Arguments `
        -LedgerPath $ledgerPath `
        -WatchLogPath $watchLogPath `
        -CoordinationLogPath $coordinationLogPath `
        -CoordinationHelperPath $coordinationPath `
        -PaneRegistryPath $paneRegistryPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Workflow round-trip step failed for $($Arguments[1]): $($output -join [Environment]::NewLine)"
    }

    $text = $output -join [Environment]::NewLine
    try {
        # ConvertFrom-Json rejects a second top-level document. This is the
        # regression assertion: the real coordination helper must return one
        # protocol object even while its watcher is a detached child process.
        return $text | ConvertFrom-Json -Depth 40
    }
    catch {
        throw "Workflow round-trip step emitted more than one JSON document or invalid JSON for $($Arguments[1]): $text"
    }
}

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
try {
$fakeHerdrContent = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$arguments = @($args)
if ($arguments.Count -gt 0 -and $arguments[0] -ieq "proxy") {
    $arguments = @($arguments | Select-Object -Skip 1)
}
if ($arguments.Count -gt 0 -and $arguments[0] -ieq "herdr") {
    $arguments = @($arguments | Select-Object -Skip 1)
}
if ($arguments.Count -lt 1) {
    throw "live round-trip transport expected a Herdr command"
}

$stateRoot = [string]$env:HERDR_LIVE_STATE
$callLog = [string]$env:HERDR_LIVE_CALL_LOG
if ([string]::IsNullOrWhiteSpace($stateRoot) -or [string]::IsNullOrWhiteSpace($callLog)) {
    throw "live round-trip transport state was not configured"
}
Add-Content -LiteralPath $callLog -Value ($arguments -join " ") -Encoding utf8

function Get-SafePaneName {
    param([Parameter(Mandatory)][string]$PaneId)
    return [regex]::Replace($PaneId, '[^A-Za-z0-9_-]', '_')
}

function Get-State {
    param([Parameter(Mandatory)][string]$PaneId)
    $path = Join-Path $stateRoot ("state-" + (Get-SafePaneName -PaneId $PaneId) + ".txt")
    if (-not (Test-Path -LiteralPath $path)) {
        [IO.File]::WriteAllText($path, "idle|0")
    }
    $parts = ([IO.File]::ReadAllText($path)).Trim() -split '\|'
    return [pscustomobject]@{
        status = [string]$parts[0]
        sequence = [int]$parts[1]
    }
}

function Set-State {
    param(
        [Parameter(Mandatory)][string]$PaneId,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][int]$Sequence
    )
    $path = Join-Path $stateRoot ("state-" + (Get-SafePaneName -PaneId $PaneId) + ".txt")
    [IO.File]::WriteAllText($path, "$Status|$Sequence")
}

function Get-PromptPath {
    param([Parameter(Mandatory)][string]$PaneId)
    return Join-Path $stateRoot ("prompt-" + (Get-SafePaneName -PaneId $PaneId) + ".txt")
}

function Get-TabId {
    param([Parameter(Mandatory)][string]$PaneId)
    if ($PaneId -eq "w1:pJ") { return "w1:t9" }
    return "w1:t2"
}

function Get-SessionId {
    param([Parameter(Mandatory)][string]$PaneId)
    switch ($PaneId) {
        "w2:p1" { return "session-source" }
        "w1:pJ" { return "session-coordinator" }
        default { return "session-target" }
    }
}

function Get-TabLabel {
    param([Parameter(Mandatory)][string]$TabId)
    if ($TabId -eq "w1:t9") { return "Coordination" }
    return "#600 - Review"
}

function Get-PaneRecord {
    param([Parameter(Mandatory)][string]$PaneId)
    $state = Get-State -PaneId $PaneId
    $tabId = Get-TabId -PaneId $PaneId
    return [ordered]@{
        pane_id = $PaneId
        workspace_id = "w1"
        tab_id = $tabId
        terminal_id = "term-live-roundtrip"
        revision = 7
        state_change_seq = $state.sequence
        agent = "codex"
        agent_status = $state.status
        cwd = "/fixture/$PaneId"
        agent_session = [ordered]@{ agent = "codex"; value = Get-SessionId -PaneId $PaneId }
    }
}

function Get-AgentRecord {
    param([Parameter(Mandatory)][string]$PaneId)
    $record = Get-PaneRecord -PaneId $PaneId
    $record.provider = "openai"
    $record.model = "gpt-5.6-luna"
    $record.reasoning_effort = "max"
    $record.service_tier = "priority"
    return $record
}

function Write-JsonAndExit {
    param([Parameter(Mandatory)]$Value)
    $Value | ConvertTo-Json -Depth 30 -Compress
    exit 0
}

$command = if ($arguments.Count -ge 2) { "$($arguments[0]) $($arguments[1])" } else { "" }
switch ($command) {
    "workspace list" {
        Write-JsonAndExit ([ordered]@{
                id = "live:workspace:list"
                result = [ordered]@{
                    type = "workspace_list"
                    workspaces = @([ordered]@{ workspace_id = "w1"; label = "Live round-trip fixture" })
                }
            })
    }
    "tab list" {
        Write-JsonAndExit ([ordered]@{
                id = "live:tab:list"
                result = [ordered]@{
                    type = "tab_list"
                    tabs = @(
                        [ordered]@{ tab_id = "w1:t9"; workspace_id = "w1"; label = "Coordination"; pane_count = 1 },
                        [ordered]@{ tab_id = "w1:t2"; workspace_id = "w1"; label = "#600 - Review"; pane_count = 2 }
                    )
                }
            })
    }
    "pane list" {
        Write-JsonAndExit ([ordered]@{
                id = "live:pane:list"
                result = [ordered]@{
                    type = "pane_list"
                    panes = @((Get-PaneRecord -PaneId "w1:pJ")
                    )
                }
            })
    }
    "tab get" {
        $tabId = [string]$arguments[2]
        Write-JsonAndExit ([ordered]@{
                id = "live:tab:get"
                result = [ordered]@{
                    type = "tab_info"
                    tab = [ordered]@{
                        tab_id = $tabId
                        workspace_id = "w1"
                        label = Get-TabLabel -TabId $tabId
                        pane_count = if ($tabId -eq "w1:t9") { 1 } else { 2 }
                    }
                }
            })
    }
    "pane get" {
        Write-JsonAndExit ([ordered]@{
                id = "live:pane:get"
                result = [ordered]@{ type = "pane_info"; pane = Get-PaneRecord -PaneId ([string]$arguments[2]) }
            })
    }
    "pane process-info" {
        $paneId = [string]$arguments[3]
        $agentPid = [int]$env:HERDR_LIVE_AGENT_PID
        if ($agentPid -le 0) { $agentPid = 1 }
        Write-JsonAndExit ([ordered]@{
                id = "live:pane:process-info"
                result = [ordered]@{
                    type = "pane_process_info"
                    process_info = [ordered]@{
                        pane_id = $paneId
                        shell_pid = $agentPid
                        foreground_processes = @([ordered]@{ name = "codex"; pid = $agentPid })
                    }
                }
            })
    }
    "agent get" {
        Write-JsonAndExit ([ordered]@{
                id = "live:agent:get"
                result = [ordered]@{ type = "agent_info"; agent = Get-AgentRecord -PaneId ([string]$arguments[2]) }
            })
    }
    "agent read" {
        $paneId = [string]$arguments[2]
        $promptPath = Get-PromptPath -PaneId $paneId
        if (Test-Path -LiteralPath $promptPath) {
            Write-Output ("> " + [IO.File]::ReadAllText($promptPath))
        }
        else {
            Write-Output ">"
        }
        exit 0
    }
    "agent prompt" {
        $paneId = [string]$arguments[2]
        $promptPath = Get-PromptPath -PaneId $paneId
        [IO.File]::WriteAllText($promptPath, [string]$arguments[3])
        $state = Get-State -PaneId $paneId
        Write-JsonAndExit ([ordered]@{
                id = "live:agent:prompt"
                result = [ordered]@{
                    type = "agent_prompted"
                    agent = [ordered]@{ pane_id = $paneId; agent = "codex"; agent_status = $state.status }
                }
            })
    }
    "agent send-keys" {
        $paneId = [string]$arguments[2]
        Remove-Item -LiteralPath (Get-PromptPath -PaneId $paneId) -Force -ErrorAction SilentlyContinue
        $state = Get-State -PaneId $paneId
        Set-State -PaneId $paneId -Status "working" -Sequence ($state.sequence + 1)
        Write-JsonAndExit ([ordered]@{
                id = "live:agent:send-keys"
                result = [ordered]@{ type = "agent_keys_sent"; pane_id = $paneId }
            })
    }
    "agent wait" {
        $paneId = [string]$arguments[2]
        $state = Get-State -PaneId $paneId
        Set-State -PaneId $paneId -Status "working" -Sequence $state.sequence
        Write-JsonAndExit ([ordered]@{
                id = "live:agent:wait"
                result = [ordered]@{
                    type = "agent_waited"
                    agent = [ordered]@{
                        pane_id = $paneId
                        agent = "codex"
                        agent_status = "working"
                        agent_session = [ordered]@{ agent = "codex"; value = Get-SessionId -PaneId $paneId }
                    }
                }
            })
    }
    "notification show" {
        Write-JsonAndExit ([ordered]@{
                id = "live:notification:show"
                result = [ordered]@{ type = "notification_shown" }
            })
    }
    default {
        throw "unexpected live round-trip transport command: $($arguments -join ' ')"
    }
}
'@
if ([IO.Path]::DirectorySeparatorChar -ne [char]92) {
    $fakeHerdrContent = "#!/usr/bin/env pwsh`n" + $fakeHerdrContent
}
$fakeHerdrContent | Set-Content -LiteralPath $fakeHerdrPath -Encoding utf8

if ([IO.Path]::DirectorySeparatorChar -ne [char]92) {
    $executableMode = [IO.UnixFileMode]::UserRead -bor
        [IO.UnixFileMode]::UserWrite -bor
        [IO.UnixFileMode]::UserExecute -bor
        [IO.UnixFileMode]::GroupRead -bor
        [IO.UnixFileMode]::GroupExecute -bor
        [IO.UnixFileMode]::OtherRead -bor
        [IO.UnixFileMode]::OtherExecute
    [IO.File]::SetUnixFileMode($fakeHerdrPath, $executableMode)
}

$originalPath = $env:PATH
$originalHerdrEnv = $env:HERDR_ENV
$originalPaneId = $env:HERDR_PANE_ID
$originalWorkspaceId = $env:HERDR_WORKSPACE_ID
$originalTabId = $env:HERDR_TAB_ID
$originalAgentSession = $env:HERDR_AGENT_SESSION_ID
$originalLiveState = $env:HERDR_LIVE_STATE
$originalLiveLog = $env:HERDR_LIVE_CALL_LOG
$originalLiveAgentPid = $env:HERDR_LIVE_AGENT_PID
$originalWatchInline = $env:HERDR_COORDINATION_WATCH_INLINE
try {
    $pwshDirectory = Split-Path -Parent $pwshExecutable
    $env:PATH = [string]::Join([IO.Path]::PathSeparator, @($tempRoot, $pwshDirectory))
    $resolvedHerdr = Get-Command herdr -ErrorAction Stop
    Assert-Equal -Actual ([IO.Path]::GetFullPath($resolvedHerdr.Source)) -Expected ([IO.Path]::GetFullPath($fakeHerdrPath)) -Message "The live round-trip did not resolve its explicit Herdr transport."
    $env:HERDR_ENV = "1"
    $env:HERDR_WORKSPACE_ID = "w1"
    $env:HERDR_TAB_ID = "w1:t2"
    $env:HERDR_LIVE_STATE = $stateRoot
    $env:HERDR_LIVE_CALL_LOG = $callLogPath
    $env:HERDR_LIVE_AGENT_PID = "$PID"
    $env:HERDR_COORDINATION_WATCH_INLINE = "0"
    Set-Content -LiteralPath $artifactPath -Value "PASS. Live request/ACK/complete/ack-return round-trip." -Encoding utf8

    Write-Output "CASE: live Ubuntu request/ACK/complete/ack-return emits one JSON document per step"
    $request = Invoke-RoundtripStep -CallerPane "w2:p1" -Arguments @(
        "-Action", "request",
        "-TaskId", "#961",
        "-CandidateId", "roundtrip-r2",
        "-ReviewType", "correction-round-2",
        "-PaneId", "w1:p2",
        "-ExpectedTabLabel", "#600 - Review",
        "-Message", "Live Ubuntu request/ACK/complete/ack-return watcher regression.",
        "-AckTimeoutSeconds", "120",
        "-NowUtc", "2026-08-17T23:50:00Z"
    )
    Assert-True -Condition ([bool]$request.created) -Message "Live round-trip request was not created."
    Assert-True -Condition ([bool]$request.request.transport_accepted) -Message "Live round-trip request transport was not accepted."
    $workflowRef = [string]$request.workflow_ref
    Assert-True -Condition ($workflowRef -match '^\[WF:[0-9a-f]{8}\]$') -Message "Live round-trip request lost its workflow reference."

    $ack = Invoke-RoundtripStep -CallerPane "w1:p2" -Arguments @(
        "-Action", "ack",
        "-WorkflowRef", $workflowRef,
        "-Message", "STARTED",
        "-NowUtc", "2026-08-17T23:51:00Z"
    )
    Assert-True -Condition (-not [bool]$ack.duplicate) -Message "Live round-trip ACK was marked duplicate."

    $complete = Invoke-RoundtripStep -CallerPane "w1:p2" -Arguments @(
        "-Action", "complete",
        "-WorkflowRef", $workflowRef,
        "-Outcome", "PASS",
        "-ArtifactPath", $artifactPath,
        "-NowUtc", "2026-08-17T23:52:00Z"
    )
    Assert-True -Condition (-not [bool]$complete.duplicate) -Message "Live round-trip completion was marked duplicate."
    Assert-True -Condition ([bool]$complete.origin_return.pending) -Message "Live round-trip completion return was not durably pending read proof."
    Assert-True -Condition ([string]$complete.origin_return.event.return_relay_ref -match '^\[HR:[0-9a-f]{8}\]$') -Message "Live round-trip completion return lost its relay reference."

    $returnAck = Invoke-RoundtripStep -CallerPane "w2:p1" -Arguments @(
        "-Action", "ack-return",
        "-WorkflowRef", $workflowRef,
        "-NowUtc", "2026-08-17T23:53:00Z"
    )
    Assert-True -Condition ([bool]$returnAck.body_read) -Message "Live round-trip return ACK did not prove body consumption."

    $events = @(Get-Content -LiteralPath $ledgerPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 40 })
    foreach ($eventName in @("request", "work_ack", "completed", "completion_returned", "completion_return_read")) {
        Assert-True -Condition (@($events | Where-Object { [string]$_.event -eq $eventName -and [string]$_.workflow_ref -eq $workflowRef }).Count -eq 1) -Message "Live round-trip ledger did not contain exactly one $eventName event."
    }

    $watchDeadline = [DateTime]::UtcNow.AddSeconds(30)
    $watchSubmitted = 0
    do {
        if (Test-Path -LiteralPath $watchLogPath) {
            $watchSubmitted = @((Get-Content -LiteralPath $watchLogPath) | Where-Object { $_ -match '"submitted":true' }).Count
        }
        if ($watchSubmitted -ge 4) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $watchDeadline)
    $watchDump = if (Test-Path -LiteralPath $watchLogPath) { Get-Content -LiteralPath $watchLogPath -Raw } else { "<watch log missing>" }
    $streamDump = @(
        Get-ChildItem -LiteralPath $tempRoot -Filter "*.stdout" -File -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $tempRoot -Filter "*.stderr" -File -ErrorAction SilentlyContinue
    ) | ForEach-Object {
        "$($_.Name): " + (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue)
    }
    Assert-True -Condition ($watchSubmitted -ge 4) -Message "Live round-trip did not finish all detached watcher proofs; observed $watchSubmitted submitted watcher records. Watch log: $watchDump Streams: $($streamDump -join ' | ')"
    Assert-True -Condition ((Get-Content -LiteralPath $callLogPath -Raw) -notmatch 'Additional text encountered') -Message "Live round-trip transport leaked a JSON parse error into its call log."

    Write-Output "PASS: Herdr workflow live Ubuntu request/ACK/complete/ack-return round-trip"
}
finally {
    $env:PATH = $originalPath
    $env:HERDR_ENV = $originalHerdrEnv
    $env:HERDR_PANE_ID = $originalPaneId
    $env:HERDR_WORKSPACE_ID = $originalWorkspaceId
    $env:HERDR_TAB_ID = $originalTabId
    $env:HERDR_AGENT_SESSION_ID = $originalAgentSession
    $env:HERDR_LIVE_STATE = $originalLiveState
    $env:HERDR_LIVE_CALL_LOG = $originalLiveLog
    $env:HERDR_LIVE_AGENT_PID = $originalLiveAgentPid
    $env:HERDR_COORDINATION_WATCH_INLINE = $originalWatchInline
}
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

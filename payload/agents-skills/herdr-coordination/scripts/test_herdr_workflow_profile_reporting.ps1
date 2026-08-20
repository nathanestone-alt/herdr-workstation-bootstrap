[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workflowPath = Join-Path $PSScriptRoot "herdr_workflow.ps1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-workflow-profile-$([Guid]::NewGuid().ToString('N'))"
$isWindowsPlatform = [IO.Path]::DirectorySeparatorChar -eq [char]92
$fakeRtkPath = Join-Path $tempRoot $(if ($isWindowsPlatform) { "rtk.cmd" } else { "rtk" })
$fakeCoordPath = Join-Path $tempRoot "coord.ps1"
$statePath = Join-Path $tempRoot "metadata.json"
$ledgerPath = Join-Path $tempRoot "ledger.jsonl"
$watchLogPath = Join-Path $tempRoot "watch.md"
$coordLogPath = Join-Path $tempRoot "coordination.md"

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
    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', observed '$Actual'."
    }
}

function Invoke-Workflow {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & pwsh -NoProfile -File $workflowPath @Arguments `
        -LedgerPath $ledgerPath `
        -WatchLogPath $watchLogPath `
        -CoordinationLogPath $coordLogPath `
        -CoordinationHelperPath $fakeCoordPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Workflow profile command failed: $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    [IO.File]::WriteAllText(
        $statePath,
        ([ordered]@{ tokens = [ordered]@{} } | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false)
    )

    if ($isWindowsPlatform) {
        @'
@echo off
pwsh -NoProfile -File "%~dp0mock_rtk.ps1" %*
exit /b %ERRORLEVEL%
'@ | Set-Content -LiteralPath (Join-Path $tempRoot "rtk.cmd") -Encoding ascii
        @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$arguments = @($args)
if ($arguments.Count -gt 0 -and $arguments[0] -ieq "proxy") { $arguments = @($arguments[1..($arguments.Count - 1)]) }
if ($arguments.Count -lt 1 -or $arguments[0] -ine "herdr") { exit 2 }
$arguments = @($arguments[1..($arguments.Count - 1)])
$statePath = $env:HERDR_PROFILE_TEST_STATE
function Write-Result {
    param([Parameter(Mandatory)]$Value)
    $Value | ConvertTo-Json -Depth 12 -Compress
    exit 0
}
function Read-Tokens {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return [ordered]@{} }
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 12
    if ($state.PSObject.Properties["tokens"] -and $state.tokens) { return $state.tokens }
    return [ordered]@{}
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "agent" -and $arguments[1] -ieq "get") {
    $paneId = [string]$arguments[2]
    $session = if ($env:HERDR_PROFILE_TEST_SESSION) { $env:HERDR_PROFILE_TEST_SESSION } else { "session-profile" }
    Write-Result ([ordered]@{ id = "profile:agent:get"; result = [ordered]@{ type = "agent_info"; agent = [ordered]@{
        pane_id = $paneId; workspace_id = "w2"; tab_id = "w2:t2"; terminal_id = "profile-terminal"
        revision = 4; state_change_seq = 9; agent = "codex"; agent_status = "idle"
        agent_session = [ordered]@{ agent = "codex"; value = $session }
    } } })
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "pane" -and $arguments[1] -ieq "get") {
    $paneId = [string]$arguments[2]
    Write-Result ([ordered]@{ id = "profile:pane:get"; result = [ordered]@{ type = "pane_info"; pane = [ordered]@{
        pane_id = $paneId; workspace_id = "w2"; tab_id = "w2:t2"; tokens = Read-Tokens
    } } })
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "pane" -and $arguments[1] -ieq "report-metadata") {
    $tokens = [ordered]@{}
    $existing = Read-Tokens
    foreach ($property in $existing.PSObject.Properties) { $tokens[$property.Name] = [string]$property.Value }
    for ($i = 3; $i -lt $arguments.Count; $i++) {
        if ($arguments[$i] -eq "--token" -and $i + 1 -lt $arguments.Count) {
            $parts = $arguments[$i + 1] -split "=", 2
            if ($parts.Count -eq 2) { $tokens[$parts[0]] = $parts[1] }
            $i++
        }
    }
    [ordered]@{ tokens = $tokens } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding utf8
    Write-Result ([ordered]@{ id = "profile:pane:report-metadata"; result = [ordered]@{ type = "pane_metadata_reported" } })
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "agent" -and $arguments[1] -ieq "read") {
    Write-Output "ready prompt"
    exit 0
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "tab" -and $arguments[1] -ieq "get") {
    Write-Result ([ordered]@{ id = "profile:tab:get"; result = [ordered]@{ type = "tab_info"; tab = [ordered]@{
        tab_id = [string]$arguments[2]; workspace_id = "w2"; label = "Fix"; pane_count = 1
    } } })
}
Write-Error "unexpected profile fixture invocation: $($arguments -join ' ')"
exit 2
'@ | Set-Content -LiteralPath (Join-Path $tempRoot "mock_rtk.ps1") -Encoding utf8
    }
    else {
        @'
#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$arguments = @($args)
if ($arguments.Count -gt 0 -and $arguments[0] -ieq "proxy") { $arguments = @($arguments[1..($arguments.Count - 1)]) }
if ($arguments.Count -lt 1 -or $arguments[0] -ine "herdr") { exit 2 }
$arguments = @($arguments[1..($arguments.Count - 1)])
$statePath = $env:HERDR_PROFILE_TEST_STATE
function Write-Result {
    param([Parameter(Mandatory)]$Value)
    $Value | ConvertTo-Json -Depth 12 -Compress
    exit 0
}
function Read-Tokens {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return [ordered]@{} }
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 12
    if ($state.PSObject.Properties["tokens"] -and $state.tokens) { return $state.tokens }
    return [ordered]@{}
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "agent" -and $arguments[1] -ieq "get") {
    $paneId = [string]$arguments[2]
    $session = if ($env:HERDR_PROFILE_TEST_SESSION) { $env:HERDR_PROFILE_TEST_SESSION } else { "session-profile" }
    Write-Result ([ordered]@{ id = "profile:agent:get"; result = [ordered]@{ type = "agent_info"; agent = [ordered]@{
        pane_id = $paneId; workspace_id = "w2"; tab_id = "w2:t2"; terminal_id = "profile-terminal"
        revision = 4; state_change_seq = 9; agent = "codex"; agent_status = "idle"
        agent_session = [ordered]@{ agent = "codex"; value = $session }
    } } })
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "pane" -and $arguments[1] -ieq "get") {
    $paneId = [string]$arguments[2]
    Write-Result ([ordered]@{ id = "profile:pane:get"; result = [ordered]@{ type = "pane_info"; pane = [ordered]@{
        pane_id = $paneId; workspace_id = "w2"; tab_id = "w2:t2"; tokens = Read-Tokens
    } } })
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "pane" -and $arguments[1] -ieq "report-metadata") {
    $tokens = [ordered]@{}
    $existing = Read-Tokens
    foreach ($property in $existing.PSObject.Properties) { $tokens[$property.Name] = [string]$property.Value }
    for ($i = 3; $i -lt $arguments.Count; $i++) {
        if ($arguments[$i] -eq "--token" -and $i + 1 -lt $arguments.Count) {
            $parts = $arguments[$i + 1] -split "=", 2
            if ($parts.Count -eq 2) { $tokens[$parts[0]] = $parts[1] }
            $i++
        }
    }
    [ordered]@{ tokens = $tokens } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $statePath -Encoding utf8
    Write-Result ([ordered]@{ id = "profile:pane:report-metadata"; result = [ordered]@{ type = "pane_metadata_reported" } })
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "agent" -and $arguments[1] -ieq "read") {
    Write-Output "ready prompt"
    exit 0
}
if ($arguments.Count -ge 3 -and $arguments[0] -ieq "tab" -and $arguments[1] -ieq "get") {
    Write-Result ([ordered]@{ id = "profile:tab:get"; result = [ordered]@{ type = "tab_info"; tab = [ordered]@{
        tab_id = [string]$arguments[2]; workspace_id = "w2"; label = "Fix"; pane_count = 1
    } } })
}
Write-Error "unexpected profile fixture invocation: $($arguments -join ' ')"
exit 2
'@ | Set-Content -LiteralPath (Join-Path $tempRoot "mock_rtk.ps1") -Encoding utf8
        [IO.File]::Copy((Join-Path $tempRoot "mock_rtk.ps1"), $fakeRtkPath)
        & chmod +x $fakeRtkPath
        if ($LASTEXITCODE -ne 0) { throw "Unable to mark the profile fixture executable." }
    }

    @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Action,
    [string]$PaneId,
    [string]$ExpectedAgent,
    [string]$ExpectedSession,
    [string]$LogPath,
    [string]$WatchLogPath
)
if ($Action -eq "prove-caller") {
    [ordered]@{
        action = "prove-caller"
        proven = $true
        caller = [ordered]@{
            pane_id = $PaneId
            agent = $ExpectedAgent
            session = $ExpectedSession
            caller_process_bound = $true
        }
    } | ConvertTo-Json -Depth 8 -Compress
    exit 0
}
throw "unexpected profile coordination action: $Action"
'@ | Set-Content -LiteralPath $fakeCoordPath -Encoding utf8

    $oldPath = $env:PATH
    $oldHerdrEnv = $env:HERDR_ENV
    $oldPaneId = $env:HERDR_PANE_ID
    $oldSession = $env:HERDR_PROFILE_TEST_SESSION
    $oldState = $env:HERDR_PROFILE_TEST_STATE
    try {
        $pwshDirectory = Split-Path -Parent (Get-Command pwsh -ErrorAction Stop).Source
        $env:PATH = [string]::Join([IO.Path]::PathSeparator, @($tempRoot, $pwshDirectory))
        $env:HERDR_ENV = "1"
        $env:HERDR_PANE_ID = "w2:p3"
        $env:HERDR_PROFILE_TEST_SESSION = "session-profile"
        $env:HERDR_PROFILE_TEST_STATE = $statePath

        Write-Output "CASE: native Luna Max/priority profile report"
        $report = Invoke-Workflow -Arguments @(
            "-Action", "report-profile",
            "-Provider", "openai",
            "-Model", "gpt-5.6-luna",
            "-ReasoningEffort", "max",
            "-ServiceTier", "priority"
        )
        Assert-True -Condition ([bool]$report.execution_profile_proven) -Message "Profile report was not proven."
        Assert-Equal -Actual $report.provider -Expected "openai" -Message "Profile report lost provider."
        Assert-Equal -Actual $report.model -Expected "gpt-5.6-luna" -Message "Profile report lost model."
        Assert-Equal -Actual $report.reasoning_effort -Expected "max" -Message "Profile report lost reasoning effort."
        Assert-Equal -Actual $report.service_tier -Expected "priority" -Message "Profile report lost service tier."

        Write-Output "CASE: preflight exposes the session-bound reported profile"
        $preflight = Invoke-Workflow -Arguments @(
            "-Action", "preflight",
            "-PaneId", "w2:p3",
            "-ExpectedTabLabel", "Fix"
        )
        Assert-True -Condition ([bool]$preflight.preflight.ready) -Message "Reported-profile preflight was not ready."
        Assert-True -Condition ([bool]$preflight.preflight.execution_profile_proven) -Message "Preflight did not prove the reported profile."
        Assert-Equal -Actual $preflight.preflight.provider -Expected "openai" -Message "Preflight lost provider."
        Assert-Equal -Actual $preflight.preflight.model -Expected "gpt-5.6-luna" -Message "Preflight lost model."
        Assert-Equal -Actual $preflight.preflight.reasoning_effort -Expected "max" -Message "Preflight lost reasoning effort."
        Assert-Equal -Actual $preflight.preflight.service_tier -Expected "priority" -Message "Preflight lost service tier."
        Assert-Equal -Actual $preflight.preflight.execution_profile_source -Expected "herdr-workflow" -Message "Preflight lost profile source."

        Write-Output "CASE: restored session invalidates stale profile until re-report"
        $env:HERDR_PROFILE_TEST_SESSION = "session-restored"
        $stale = Invoke-Workflow -Arguments @(
            "-Action", "preflight",
            "-PaneId", "w2:p3",
            "-ExpectedTabLabel", "Fix"
        )
        Assert-True -Condition (-not [bool]$stale.preflight.execution_profile_proven) -Message "Stale profile survived a native-session rotation."

        $restoredReport = Invoke-Workflow -Arguments @(
            "-Action", "report-profile",
            "-Provider", "openai",
            "-Model", "gpt-5.6-luna",
            "-ReasoningEffort", "max",
            "-ServiceTier", "priority"
        )
        Assert-True -Condition ([bool]$restoredReport.execution_profile_proven) -Message "Restored-session profile report was not proven."
        $restoredPreflight = Invoke-Workflow -Arguments @(
            "-Action", "preflight",
            "-PaneId", "w2:p3",
            "-ExpectedTabLabel", "Fix"
        )
        Assert-True -Condition ([bool]$restoredPreflight.preflight.execution_profile_proven) -Message "Restored-session profile was not exposed by preflight."

        Write-Output "PASS: Herdr workflow execution-profile reporting"
    }
    finally {
        if ($null -eq $oldPath) { Remove-Item Env:PATH -ErrorAction SilentlyContinue } else { $env:PATH = $oldPath }
        if ($null -eq $oldHerdrEnv) { Remove-Item Env:HERDR_ENV -ErrorAction SilentlyContinue } else { $env:HERDR_ENV = $oldHerdrEnv }
        if ($null -eq $oldPaneId) { Remove-Item Env:HERDR_PANE_ID -ErrorAction SilentlyContinue } else { $env:HERDR_PANE_ID = $oldPaneId }
        if ($null -eq $oldSession) { Remove-Item Env:HERDR_PROFILE_TEST_SESSION -ErrorAction SilentlyContinue } else { $env:HERDR_PROFILE_TEST_SESSION = $oldSession }
        if ($null -eq $oldState) { Remove-Item Env:HERDR_PROFILE_TEST_STATE -ErrorAction SilentlyContinue } else { $env:HERDR_PROFILE_TEST_STATE = $oldState }
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

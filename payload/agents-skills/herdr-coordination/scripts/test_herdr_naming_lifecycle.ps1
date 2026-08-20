[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# The helper pins [Console]::OutputEncoding to UTF-8 before emitting JSON, so its
# stdout carries raw UTF-8 bytes. PowerShell decodes native-command output using
# the CALLER's [Console]::OutputEncoding, which on a stock Windows console is the
# OEM code page (cp437). Left unpinned, the subtitle separator U+00B7 (UTF-8
# 0xC2 0xB7) came back decoded as U+252C U+2556 -- cp437's glyphs for those two
# bytes -- and every subtitle assertion failed. Writer and reader must agree on
# one decoder.
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }

# Regression cover for the coordinator-owned pane naming lifecycle:
#   1. a naming request that was read-ACKed but never applied is detected;
#   2. one APPLIED proof clears the outstanding request;
#   3. a wrong caller or a stale target session fails closed before mutation;
#   4. consuming the same request twice stays idempotent.

$helperPath = Join-Path $PSScriptRoot "herdr_coordination.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-naming-lifecycle-$([Guid]::NewGuid().ToString('N'))"
$mockBin = Join-Path $testRoot "bin"
$isWindowsPlatform = [IO.Path]::DirectorySeparatorChar -eq [char]92
$statePath = Join-Path $testRoot "mock-state.json"
$callsPath = Join-Path $testRoot "mock-calls.log"
$null = New-Item -ItemType Directory -Path $mockBin -Force

$separator = [string][char]0x00B7
$coordinatorPane = "w1:p1"
$targetPane = "w2:p2"
$targetTab = "w2:t2"
$requestPayload = "PANE NAMING REQUEST: repo=STM; lane=T; role=O; work=issue; issue=#901; " +
    "title=Naming lifecycle regression; coordinator_action=apply-name-and-return-proof; " +
    "routing_gate=continue-by-stable-pane-id-while-pending"
$expectedName = "STM-T-O2"
$expectedSubtitle = "#901 $separator Naming lifecycle regression"

$script:Passed = 0
$oldPath = $env:PATH
$oldValues = @{}
foreach ($name in @("HERDR_ENV", "HERDR_WORKSPACE_ID", "HERDR_TAB_ID", "HERDR_PANE_ID",
        "HERDR_AGENT_SESSION_ID", "CODEX_THREAD_ID", "HERDR_TEST_STATE", "HERDR_TEST_CALLS")) {
    $oldValues[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:Passed++
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Message (expected '$Expected', observed '$Actual')"
    }
    $script:Passed++
}

function Set-Caller {
    param([ValidateSet("coordinator", "target")][string]$Caller)
    $env:HERDR_ENV = "1"
    if ($Caller -eq "coordinator") {
        $env:HERDR_WORKSPACE_ID = "w1"
        $env:HERDR_TAB_ID = "w1:t1"
        $env:HERDR_PANE_ID = $coordinatorPane
        $env:HERDR_AGENT_SESSION_ID = "coord-session"
    }
    else {
        $env:HERDR_WORKSPACE_ID = "w2"
        $env:HERDR_TAB_ID = $targetTab
        $env:HERDR_PANE_ID = $targetPane
        $env:HERDR_AGENT_SESSION_ID = "target-session"
    }
}

function Reset-MockState {
    param(
        [string]$TargetTabLabel = "shell",
        [ValidateSet('none', 'pane_not_found', 'generic_failure')][string]$TargetError = 'none'
    )
    $state = [ordered]@{
        target_tab_label = $TargetTabLabel
        target_pane_label = "shell"
        target_title = ""
        target_display_agent = ""
        target_error = $TargetError
    }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($callsPath, "", [Text.UTF8Encoding]::new($false))
}

function Get-MockCalls {
    if (-not (Test-Path -LiteralPath $callsPath)) { return "" }
    return ((Get-Content -LiteralPath $callsPath) -join "`n")
}

function Get-Sha256Hex {
    param([string]$Text)
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Format-Stamp {
    param([datetime]$Value)
    return ([DateTimeOffset]$Value).ToString("yyyy-MM-dd HH:mm zzz", [Globalization.CultureInfo]::InvariantCulture)
}

function New-NamingLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelayRef,
        [bool]$WithReadAck = $true,
        [string]$RecipientPane = $coordinatorPane,
        [string]$RecipientTab = "w1:t1",
        [string]$RecipientSession = "coord-session",
        [string]$Payload = $requestPayload
    )

    $labelB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Coordination"))
    $payloadHash = Get-Sha256Hex -Text $Payload
    $requestStamp = Format-Stamp -Value (Get-Date).AddHours(-3)
    $ackStamp = Format-Stamp -Value (Get-Date).AddHours(-2)

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("# Herdr Coordination Log")
    $lines.Add("")
    $lines.Add("## Messages")
    $lines.Add("")
    $lines.Add("- [$requestStamp] FROM $targetPane TO coordinator: $RelayRef " +
        "[RECIPIENT-PANE $RecipientPane] [RECIPIENT-SESSION $RecipientSession] [RECIPIENT-AGENT codex] " +
        "[RECIPIENT-TAB $RecipientTab] [RECIPIENT-LABEL-B64 $labelB64] [PAYLOAD-SHA256 $payloadHash] $Payload")
    if ($WithReadAck) {
        $lines.Add("- [$ackStamp] FROM $RecipientPane TO $targetPane`: [HA:aaaa0001] " +
            "[READ-ACK re $RelayRef] body read; reader_agent=codex; reader_session=$RecipientSession")
    }
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}

function Invoke-Helper {
    param([string[]]$Arguments)
    $output = & pwsh -NoProfile -File $helperPath @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text = ($output -join [Environment]::NewLine)
    }
}

function Invoke-HelperJson {
    param([string[]]$Arguments)
    $result = Invoke-Helper -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "helper failed ($($result.ExitCode)): $($result.Text)"
    }
    return ($result.Text | ConvertFrom-Json -Depth 32)
}

try {
    $mockScript = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$statePath = $env:HERDR_TEST_STATE
$state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 16
$arguments = @($args)
# herdr_coordination.ps1 prefers "rtk proxy herdr <args>" and falls back to
# "herdr <args>". Both shims land here, so strip any leading proxy/herdr
# tokens and normalise to the bare herdr argument vector.
while ($arguments.Count -gt 0 -and @("proxy", "herdr") -contains $arguments[0]) {
    $arguments = @($arguments[1..($arguments.Count - 1)])
}
Add-Content -LiteralPath $env:HERDR_TEST_CALLS -Value ($arguments -join " ") -Encoding utf8

function Save-State {
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
}

function Get-TabLabel([string]$tabId) {
    switch ($tabId) {
        "w1:t1" { return "Coordination" }
        "w2:t2" { return [string]$state.target_tab_label }
        "w2:t9" { return "STM-T-O1" }
    }
    throw "unknown tab $tabId"
}

function Get-PaneData([string]$paneId) {
    if ($paneId -eq "w1:p1") {
        return [ordered]@{ pane_id="w1:p1"; workspace_id="w1"; tab_id="w1:t1"; terminal_id="term-coord"; revision=3; agent="codex"; agent_status="idle"; cwd="C:\dev\Codex\Herder" }
    }
    if ($paneId -eq "w2:p2") {
        return [ordered]@{ pane_id="w2:p2"; workspace_id="w2"; tab_id="w2:t2"; terminal_id="term-target"; revision=5; agent="codex"; agent_status="idle"; cwd="C:\dev\stmodel"; label=[string]$state.target_pane_label }
    }
    throw "unknown pane $paneId"
}

if ($arguments[0] -eq "workspace" -and $arguments[1] -eq "list") {
    $workspaces = @(
        [ordered]@{ workspace_id="w1"; label="Hdr" },
        [ordered]@{ workspace_id="w2"; label="STM" }
    )
    [ordered]@{ id="test"; result=[ordered]@{ type="workspace_list"; workspaces=$workspaces } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "tab" -and $arguments[1] -eq "list") {
    $workspaceId = $arguments[[Array]::IndexOf($arguments, "--workspace") + 1]
    $tabs = if ($workspaceId -eq "w1") {
        @([ordered]@{ tab_id="w1:t1"; workspace_id="w1"; label="Coordination"; pane_count=1 })
    } else {
        @(
            [ordered]@{ tab_id="w2:t2"; workspace_id="w2"; label=(Get-TabLabel "w2:t2"); pane_count=1 },
            [ordered]@{ tab_id="w2:t9"; workspace_id="w2"; label="STM-T-O1"; pane_count=1 }
        )
    }
    [ordered]@{ id="test"; result=[ordered]@{ type="tab_list"; tabs=$tabs } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "pane" -and $arguments[1] -eq "list") {
    $workspaceId = $arguments[[Array]::IndexOf($arguments, "--workspace") + 1]
    $panes = if ($workspaceId -eq "w1") { @((Get-PaneData "w1:p1")) } else { @((Get-PaneData "w2:p2")) }
    [ordered]@{ id="test"; result=[ordered]@{ type="pane_list"; panes=$panes } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "pane" -and $arguments[1] -eq "get") {
    if ($arguments[2] -eq "w2:p2" -and [string]$state.target_error -eq 'pane_not_found') {
        [ordered]@{ id='test'; error=[ordered]@{ code='pane_not_found'; message='pane w2:p2 not found' } } | ConvertTo-Json -Depth 8 -Compress
        exit 1
    }
    if ($arguments[2] -eq "w2:p2" -and [string]$state.target_error -eq 'generic_failure') {
        [ordered]@{ id='test'; error=[ordered]@{ code='transport_failed'; message='temporary failure' } } | ConvertTo-Json -Depth 8 -Compress
        exit 1
    }
    [ordered]@{ id="test"; result=[ordered]@{ type="pane_info"; pane=(Get-PaneData $arguments[2]) } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "tab" -and $arguments[1] -eq "get") {
    $tabId = $arguments[2]
    $tab = [ordered]@{ tab_id=$tabId; workspace_id=$tabId.Split(":")[0]; label=(Get-TabLabel $tabId); pane_count=1 }
    [ordered]@{ id="test"; result=[ordered]@{ type="tab_info"; tab=$tab } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "agent" -and $arguments[1] -eq "get") {
    $paneId = $arguments[2]
    $agent = Get-PaneData $paneId
    $session = if ($paneId -eq "w1:p1") { "coord-session" } else { $env:HERDR_TEST_TARGET_SESSION }
    if ([string]::IsNullOrWhiteSpace($session)) { $session = "target-session" }
    $agent.agent_session = [ordered]@{ agent="codex"; kind="id"; source="test"; value=$session }
    if ($paneId -eq "w2:p2" -and -not [string]::IsNullOrWhiteSpace([string]$state.target_title)) {
        $agent.title = [string]$state.target_title
        $agent.display_agent = [string]$state.target_display_agent
    }
    [ordered]@{ id="test"; result=[ordered]@{ type="agent_info"; agent=$agent } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "tab" -and $arguments[1] -eq "rename") {
    if ($arguments[2] -ne "w2:t2") { throw "unexpected tab rename target $($arguments[2])" }
    $state.target_tab_label = $arguments[3]
    Save-State
    [ordered]@{ id="test"; result=[ordered]@{ type="tab_renamed"; tab_id=$arguments[2]; label=$arguments[3] } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "pane" -and $arguments[1] -eq "rename") {
    if ($arguments[2] -ne "w2:p2") { throw "unexpected pane rename target $($arguments[2])" }
    $state.target_pane_label = if ($arguments.Count -gt 3 -and $arguments[3] -eq "--clear") { "" } else { [string]$arguments[3] }
    Save-State
    [ordered]@{ id="test"; result=[ordered]@{ type="pane_renamed"; pane_id=$arguments[2]; label=$state.target_pane_label } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "pane" -and $arguments[1] -eq "report-metadata") {
    $titleIndex = [Array]::IndexOf($arguments, "--title")
    if ($titleIndex -ge 0) { $state.target_title = $arguments[$titleIndex + 1] }
    $displayIndex = [Array]::IndexOf($arguments, "--display-agent")
    if ($displayIndex -ge 0) { $state.target_display_agent = $arguments[$displayIndex + 1] }
    Save-State
    [ordered]@{ id="test"; result=[ordered]@{ type="pane_metadata_reported"; pane_id=$arguments[2] } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
throw "unsupported mock herdr command: $($arguments -join ' ')"
'@
    $mockScriptPath = Join-Path $mockBin "mock_herdr.ps1"
    [IO.File]::WriteAllText($mockScriptPath, $mockScript, [Text.UTF8Encoding]::new($false))
    # Shim both command surfaces the helper can reach. On Unix the mock itself
    # is an executable PowerShell script; Windows retains a .cmd launcher for
    # the native command lookup performed by PowerShell 7.
    if ($isWindowsPlatform) {
        $mockCmd = "@echo off`r`npwsh -NoProfile -File `"%~dp0mock_herdr.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
        [IO.File]::WriteAllText((Join-Path $mockBin "herdr.cmd"), $mockCmd, [Text.ASCIIEncoding]::new())
        [IO.File]::WriteAllText((Join-Path $mockBin "rtk.cmd"), $mockCmd, [Text.ASCIIEncoding]::new())
    }
    else {
        $portableMock = "#!/usr/bin/env pwsh`n$mockScript`n"
        foreach ($commandName in @("herdr", "rtk")) {
            $commandPath = Join-Path $mockBin $commandName
            [IO.File]::WriteAllText($commandPath, $portableMock, [Text.UTF8Encoding]::new($false))
            & chmod +x $commandPath
            if ($LASTEXITCODE -ne 0) { throw "Unable to mark the naming mock executable: $commandPath" }
        }
    }

    $pwshDirectory = Split-Path -Parent (Get-Command pwsh -ErrorAction Stop).Source
    $env:PATH = [string]::Join([IO.Path]::PathSeparator, @($mockBin, $pwshDirectory))
    $env:HERDR_TEST_STATE = $statePath
    $env:HERDR_TEST_CALLS = $callsPath

    # -- CASE 1: a read-ACKed naming request with no APPLIED proof is detected --
    Write-Output "CASE: read-ACKed naming request without APPLIED proof is detected"
    Reset-MockState
    $detectLog = Join-Path $testRoot "detect.md"
    $detectRef = "[HR:1111aaaa]"
    New-NamingLog -Path $detectLog -RelayRef $detectRef
    Set-Caller coordinator

    $overdue = Invoke-HelperJson -Arguments @("-Action", "naming-status", "-LogPath", $detectLog, "-NamingDeadlineSeconds", "60")
    Assert-Equal $overdue.examined 1 "Watchdog did not find the naming request"
    Assert-Equal $overdue.requests[0].state "overdue_unapplied" "Read-ACKed request without APPLIED was not flagged overdue"
    Assert-True ([bool]$overdue.overdue) "Watchdog did not raise the overdue flag"
    Assert-Equal $overdue.overdue_count 1 "Overdue count was wrong"
    Assert-Equal $overdue.overdue_relay_refs[0] $detectRef "Overdue relay ref was wrong"
    Assert-True ([bool]$overdue.requests[0].body_read) "Watchdog lost the read-ACK proof"
    Assert-True (-not [bool]$overdue.requests[0].applied) "Watchdog claimed an APPLIED proof that does not exist"
    Assert-Equal $overdue.requests[0].requesting_pane_id $targetPane "Watchdog resolved the wrong requesting pane"
    Assert-True ([int]$overdue.requests[0].overdue_by_seconds -gt 0) "Overdue elapsed time was not reported"

    # The deadline, not the mere absence of a proof, is what raises the alarm.
    $withinDeadline = Invoke-HelperJson -Arguments @("-Action", "naming-status", "-LogPath", $detectLog, "-NamingDeadlineSeconds", "86400")
    Assert-Equal $withinDeadline.requests[0].state "read_acked_unapplied" "Request inside the deadline was misclassified"
    Assert-True (-not [bool]$withinDeadline.overdue) "Request inside the deadline was flagged overdue"

    # A request that was never read-ACKed is a distinct, non-overdue state.
    $unackedLog = Join-Path $testRoot "unacked.md"
    New-NamingLog -Path $unackedLog -RelayRef "[HR:1111bbbb]" -WithReadAck $false
    $unacked = Invoke-HelperJson -Arguments @("-Action", "naming-status", "-LogPath", $unackedLog, "-NamingDeadlineSeconds", "60")
    Assert-Equal $unacked.requests[0].state "awaiting_read_ack" "Unacknowledged request was misclassified"
    Assert-True (-not [bool]$unacked.overdue) "Unacknowledged request was flagged overdue"

    Assert-Equal (Get-MockCalls) "" "Read-only watchdog contacted Herdr"

    # -- CASE 2: one apply proof clears the outstanding request --
    Write-Output "CASE: one coordinator apply proof clears the outstanding request"
    Reset-MockState
    $applyLog = Join-Path $testRoot "apply.md"
    $applyRef = "[HR:2222aaaa]"
    New-NamingLog -Path $applyLog -RelayRef $applyRef
    Set-Caller coordinator

    $consumed = Invoke-HelperJson -Arguments @("-Action", "consume-name-requests", "-LogPath", $applyLog)
    Assert-Equal $consumed.applied_count 1 "Coordinator did not apply the outstanding naming request"
    Assert-Equal $consumed.failed_count 0 "Consumption reported a failure"
    Assert-Equal $consumed.results[0].state "applied" "Consumption did not report an applied state"
    Assert-Equal $consumed.results[0].tab_label $expectedName "Coordinator assigned the wrong canonical name"
    Assert-Equal $consumed.results[0].title $expectedSubtitle "Coordinator assigned the wrong work subtitle"
    Assert-Equal $consumed.results[0].target_pane_id $targetPane "Coordinator named the wrong pane"
    Assert-Equal $consumed.results[0].coordinator_pane_id $coordinatorPane "Applied proof named the wrong coordinator"
    Assert-True ([string]$consumed.results[0].proof.proof_ref -match '^\[HN:[0-9a-f]{8}\]$') "APPLIED proof reference was malformed"

    $applyCalls = Get-MockCalls
    Assert-True ($applyCalls -match "tab rename w2:t2 $([regex]::Escape($expectedName))") "Coordinator did not rename the exact target tab"
    Assert-True ($applyCalls -match "pane rename w2:p2 $([regex]::Escape($expectedName))") "Coordinator did not reconcile the exact visible pane label"
    Assert-True ($applyCalls -match "pane report-metadata w2:p2") "Coordinator did not report the work subtitle"

    $applyLogText = (Get-Content -LiteralPath $applyLog) -join "`n"
    Assert-True ($applyLogText -match "\[APPLIED re $([regex]::Escape($applyRef))\]") "APPLIED proof was not appended to the log"
    Assert-True ($applyLogText -match "\[APPLIED-PANE $([regex]::Escape($targetPane))\]") "APPLIED proof lost the exact target pane"
    Assert-True ($applyLogText -match "\[APPLIED-COORDINATOR $([regex]::Escape($coordinatorPane))\]") "APPLIED proof lost the coordinator identity"

    $cleared = Invoke-HelperJson -Arguments @("-Action", "naming-status", "-LogPath", $applyLog, "-NamingDeadlineSeconds", "60")
    Assert-Equal $cleared.requests[0].state "applied" "APPLIED proof did not clear the outstanding request"
    Assert-True (-not [bool]$cleared.overdue) "Watchdog still flagged a request that carries an APPLIED proof"
    Assert-Equal $cleared.overdue_count 0 "Overdue count survived a valid APPLIED proof"
    Assert-Equal $cleared.applied_count 1 "Applied count was wrong"
    Assert-Equal $cleared.requests[0].applied_canonical_name $expectedName "Watchdog reported the wrong applied name"

    # -- CASE 3: wrong caller or stale target session fails closed --
    Write-Output "CASE: wrong caller and stale target session fail closed"
    Reset-MockState
    $closedLog = Join-Path $testRoot "failclosed.md"
    $closedRef = "[HR:3333aaaa]"
    New-NamingLog -Path $closedLog -RelayRef $closedRef

    Set-Caller target
    $wrongCaller = Invoke-Helper -Arguments @("-Action", "consume-name-requests", "-LogPath", $closedLog)
    Assert-True ($wrongCaller.ExitCode -ne 0) "A non-coordinator pane was allowed to consume naming requests"
    Assert-True ($wrongCaller.Text -match "caller $([regex]::Escape($targetPane)) is not $([regex]::Escape($coordinatorPane))") `
        "Wrong-caller refusal did not name the coordinator: $($wrongCaller.Text)"
    Assert-True ((Get-MockCalls) -notmatch "tab rename|report-metadata") "Wrong-caller attempt mutated pane state"

    Reset-MockState
    Set-Caller coordinator
    $env:HERDR_TEST_TARGET_SESSION = "rotated-session"
    $staleSession = Invoke-Helper -Arguments @(
        "-Action", "apply-name", "-RelayRef", $closedRef, "-LogPath", $closedLog,
        "-ExpectedTargetSession", "target-session")
    Remove-Item Env:HERDR_TEST_TARGET_SESSION -ErrorAction SilentlyContinue
    Assert-True ($staleSession.ExitCode -ne 0) "apply-name accepted a target pane hosting a different session"
    Assert-True ($staleSession.Text -match "no longer hosts the expected native session") `
        "Stale-session refusal used the wrong reason: $($staleSession.Text)"
    Assert-True ((Get-MockCalls) -notmatch "tab rename|report-metadata") "Stale-session attempt mutated pane state"
    Assert-True (((Get-Content -LiteralPath $closedLog) -join "`n") -notmatch "\[HN:") "Failed apply still wrote an APPLIED proof"

    # A request routed to a different Coordination pane is not this coordinator's to apply.
    Reset-MockState
    $foreignLog = Join-Path $testRoot "foreign.md"
    $foreignRef = "[HR:3333bbbb]"
    New-NamingLog -Path $foreignLog -RelayRef $foreignRef -RecipientPane "w2:p2" -RecipientTab "w2:t2" -RecipientSession "target-session"
    $foreign = Invoke-Helper -Arguments @("-Action", "consume-name-requests", "-RelayRef", $foreignRef, "-LogPath", $foreignLog)
    Assert-True ($foreign.ExitCode -ne 0) "Coordinator applied a request routed to another pane"
    Assert-True ((Get-MockCalls) -notmatch "tab rename|report-metadata") "Misrouted request mutated pane state"

    # A forged APPLIED proof cannot be appended through the generic append action.
    $forge = Invoke-Helper -Arguments @(
        "-Action", "append", "-From", $coordinatorPane, "-To", $targetPane, "-LogPath", $foreignLog,
        "-Message", "[HN:deadbeef] [APPLIED re $foreignRef] [APPLIED-PANE w2:p2] [APPLIED-TAB w2:t2] [APPLIED-COORDINATOR w1:p1] applied; canonical_name=STM-T-O9; subtitle_b64=; coordinator_session=x; target_session=y")
    Assert-True ($forge.ExitCode -ne 0) "append fabricated an APPLIED naming proof"

    # -- CASE 4: ordinary sweeps skip terminal work; direct retries are idempotent --
    Write-Output "CASE: terminal requests are skipped by sweeps and direct retries are idempotent"
    $env:HERDR_TEST_CALLS = $callsPath
    [IO.File]::WriteAllText($callsPath, "", [Text.UTF8Encoding]::new($false))
    Set-Caller coordinator
    $again = Invoke-HelperJson -Arguments @("-Action", "consume-name-requests", "-LogPath", $applyLog)
    Assert-Equal $again.applied_count 0 "Duplicate consumption applied the request a second time"
    Assert-Equal $again.examined 0 "Ordinary sweep did not exclude the terminal request"
    Assert-Equal $again.duplicate_count 0 "Ordinary sweep returned a duplicate terminal result"
    Assert-Equal $again.failed_count 0 "Duplicate consumption reported a failure"
    Assert-True ((Get-MockCalls) -notmatch "tab rename|report-metadata") "Duplicate consumption re-mutated pane state"

    $againDirect = Invoke-HelperJson -Arguments @("-Action", "consume-name-requests", "-RelayRef", $applyRef, "-LogPath", $applyLog)
    Assert-Equal $againDirect.duplicate_count 1 "Direct retry was not reported as a duplicate"
    Assert-Equal $againDirect.results[0].state "already_applied" "Direct retry did not short-circuit"
    Assert-Equal $againDirect.results[0].tab_label $expectedName "Direct retry lost the applied canonical name"
    Assert-Equal $againDirect.results[0].title $expectedSubtitle "Direct retry lost the applied subtitle"

    $proofCount = @((Get-Content -LiteralPath $applyLog) | Where-Object { $_ -match "\[HN:" }).Count
    Assert-Equal $proofCount 1 "Duplicate consumption appended a second APPLIED proof"

    # A relay-bound apply-name on an already-proven request is idempotent too.
    [IO.File]::WriteAllText($callsPath, "", [Text.UTF8Encoding]::new($false))
    $repeatApply = Invoke-HelperJson -Arguments @("-Action", "apply-name", "-RelayRef", $applyRef, "-LogPath", $applyLog)
    Assert-True ([bool]$repeatApply.duplicate) "Relay-bound apply-name did not detect the existing proof"
    Assert-True ([bool]$repeatApply.applied) "Relay-bound apply-name lost the applied state"
    Assert-True ((Get-MockCalls) -notmatch "tab rename|report-metadata") "Relay-bound duplicate apply re-mutated pane state"
    Assert-Equal (@((Get-Content -LiteralPath $applyLog) | Where-Object { $_ -match "\[HN:" }).Count) 1 `
        "Relay-bound duplicate apply appended a second APPLIED proof"

    # -- CASE 5: vanished retirement target reaches one non-APPLIED terminal state --
    Write-Output 'CASE: vanished retirement target is disposed once without APPLIED'
    Reset-MockState -TargetError pane_not_found
    $retirementLog = Join-Path $testRoot 'retirement-gone.md'
    $retirementRef = '[HR:5555aaaa]'
    $legacyRetirementPayload = 'PANE NAMING REQUEST: repo=AGT; lane=T; role=B; work=issue; issue=#113; title=retired; ' +
        'previous_name=AGT-T-B1; previous_work=#113 · issue-implementation; ' +
        'coordinator_action=apply-name-and-return-proof; coordinator_command=consume-name-requests; ' +
        'routing_gate=continue-by-stable-pane-id-while-pending'
    New-NamingLog -Path $retirementLog -RelayRef $retirementRef -Payload $legacyRetirementPayload
    Set-Caller coordinator

    $retired = Invoke-HelperJson -Arguments @('-Action', 'consume-name-requests', '-LogPath', $retirementLog)
    Assert-Equal $retired.terminal_count 1 'Consumer did not record one terminal retirement disposition'
    Assert-Equal $retired.failed_count 0 'Terminal retirement disposition still failed the sweep'
    Assert-Equal $retired.results[0].state 'retirement_target_gone' 'Terminal retirement state was wrong'
    Assert-True (-not [bool]$retired.results[0].applied) 'Terminal retirement falsely claimed APPLIED'
    Assert-True ([bool]$retired.results[0].terminal) 'Terminal retirement was not marked terminal'
    $retirementText = (Get-Content -LiteralPath $retirementLog) -join "`n"
    Assert-Equal ([regex]::Matches($retirementText, '\[HD:[0-9a-f]{8}\]').Count) 1 'Disposition proof count was wrong'
    Assert-True ($retirementText -notmatch '\[HN:') 'Missing retirement target gained a false APPLIED proof'
    Assert-True ($retirementText -notmatch '\[HI:') 'Pre-mutation missing target gained an APPLY-STARTED intent'
    # The nested rtk/herdr shims can duplicate a captured native call, but the
    # implementation must show at least the initial resolution and one recheck.
    Assert-True ([regex]::Matches((Get-MockCalls), 'pane get w2:p2').Count -ge 2) 'Missing pane was not rechecked before disposition'

    $retiredStatus = Invoke-HelperJson -Arguments @('-Action', 'naming-status', '-RelayRef', $retirementRef, '-LogPath', $retirementLog)
    Assert-Equal $retiredStatus.requests[0].state 'retirement_target_gone' 'Watchdog lost terminal retirement state'
    Assert-True ([bool]$retiredStatus.requests[0].terminal) 'Watchdog did not mark retirement terminal'
    Assert-True (-not [bool]$retiredStatus.overdue) 'Terminal retirement remained overdue'

    [IO.File]::WriteAllText($callsPath, '', [Text.UTF8Encoding]::new($false))
    $retiredAgain = Invoke-HelperJson -Arguments @('-Action', 'consume-name-requests', '-LogPath', $retirementLog)
    Assert-Equal $retiredAgain.terminal_count 0 'Duplicate retirement appended a second terminal disposition'
    Assert-Equal $retiredAgain.examined 0 'Ordinary sweep did not exclude terminal retirement'
    Assert-Equal $retiredAgain.duplicate_count 0 'Ordinary sweep returned a duplicate retirement result'
    Assert-True ((Get-MockCalls) -notmatch 'pane get w2:p2') 'Duplicate terminal retirement queried the vanished pane again'
    $retiredDirect = Invoke-HelperJson -Arguments @('-Action', 'consume-name-requests', '-RelayRef', $retirementRef, '-LogPath', $retirementLog)
    Assert-Equal $retiredDirect.duplicate_count 1 'Direct retirement retry was not idempotent'
    Assert-Equal $retiredDirect.results[0].state 'retirement_target_gone' 'Direct retirement retry lost its terminal state'
    Assert-Equal ([regex]::Matches(((Get-Content -LiteralPath $retirementLog) -join "`n"), '\[HD:[0-9a-f]{8}\]').Count) 1 'Duplicate retirement appended another disposition'

    Reset-MockState
    [IO.File]::WriteAllText($callsPath, '', [Text.UTF8Encoding]::new($false))
    $legacyReuseLog = Join-Path $testRoot 'legacy-retirement-live-reuse.md'
    $legacyReuseRef = '[HR:5555aaab]'
    New-NamingLog -Path $legacyReuseLog -RelayRef $legacyReuseRef -Payload $legacyRetirementPayload
    $legacyReuse = Invoke-Helper -Arguments @('-Action', 'consume-name-requests', '-LogPath', $legacyReuseLog)
    Assert-True ($legacyReuse.ExitCode -ne 0) 'Legacy retirement mutated a live pane without requester provenance'
    Assert-True ($legacyReuse.Text -match 'without exact requester session, tab, and agent provenance') 'Legacy live-pane retirement refusal was not explained'
    Assert-True ((Get-MockCalls) -notmatch 'tab rename|report-metadata') 'Legacy retirement against a reused live pane performed a mutation'
    Assert-True (((Get-Content -LiteralPath $legacyReuseLog) -join "`n") -notmatch '\[(?:HI|HN|HD):') 'Legacy live-pane retirement created lifecycle evidence'

    # Ordinary or explicitly assignment-scoped requests never terminalize on absence.
    Reset-MockState -TargetError pane_not_found
    $ordinaryMissingLog = Join-Path $testRoot 'ordinary-missing.md'
    New-NamingLog -Path $ordinaryMissingLog -RelayRef '[HR:5555bbbb]'
    $ordinaryMissing = Invoke-Helper -Arguments @('-Action', 'consume-name-requests', '-LogPath', $ordinaryMissingLog)
    Assert-True ($ordinaryMissing.ExitCode -ne 0) 'Ordinary missing target was silently terminalized'
    Assert-True (((Get-Content -LiteralPath $ordinaryMissingLog) -join "`n") -notmatch '\[HD:') 'Ordinary request gained a retirement disposition'

    Reset-MockState -TargetError pane_not_found
    $assignmentRetiredLog = Join-Path $testRoot 'assignment-retired.md'
    $assignmentRetiredPayload = 'PANE NAMING REQUEST: repo=AGT; lifecycle=assignment; requester_pane=w2:p2; requester_tab=w2:t2; ' +
        'requester_agent=codex; requester_session=target-session; lane=T; role=B; work=issue; issue=#113; title=retired; ' +
        'previous_name=AGT-T-B1; previous_work=#113; coordinator_action=apply-name-and-return-proof'
    New-NamingLog -Path $assignmentRetiredLog -RelayRef '[HR:5555cccc]' -Payload $assignmentRetiredPayload
    $assignmentRetired = Invoke-Helper -Arguments @('-Action', 'consume-name-requests', '-LogPath', $assignmentRetiredLog)
    Assert-True ($assignmentRetired.ExitCode -ne 0) 'Assignment titled retired was treated as lifecycle retirement'
    Assert-True (((Get-Content -LiteralPath $assignmentRetiredLog) -join "`n") -notmatch '\[HD:') 'Assignment titled retired gained a disposition'

    Reset-MockState -TargetError generic_failure
    $genericFailureLog = Join-Path $testRoot 'generic-failure.md'
    New-NamingLog -Path $genericFailureLog -RelayRef '[HR:5555dddd]' -Payload $legacyRetirementPayload
    $genericFailure = Invoke-Helper -Arguments @('-Action', 'consume-name-requests', '-LogPath', $genericFailureLog)
    Assert-True ($genericFailure.ExitCode -ne 0) 'Generic transport failure was classified as pane_not_found'
    Assert-True (((Get-Content -LiteralPath $genericFailureLog) -join "`n") -notmatch '\[HD:') 'Generic failure gained a retirement disposition'

    # Terminal evidence is bound to the request lifecycle, read ACK, and
    # requester session. Structurally valid forgeries remain non-terminal.
    Write-Output 'CASE: forged terminal evidence fails closed'
    $sessionPayload = 'PANE NAMING REQUEST: repo=AGT; lifecycle=assignment; requester_pane=w2:p2; requester_tab=w2:t2; ' +
        'requester_agent=codex; requester_session=target-session; lane=T; role=B; work=issue; issue=#113; title=active; ' +
        'coordinator_action=apply-name-and-return-proof; coordinator_command=consume-name-requests'
    $sessionLog = Join-Path $testRoot 'session-proof.md'
    $sessionRef = '[HR:7777aaaa]'
    New-NamingLog -Path $sessionLog -RelayRef $sessionRef -Payload $sessionPayload
    Add-Content -LiteralPath $sessionLog -Encoding utf8 -Value (
        '- [2026-08-14 10:00 -05:00] FROM w1:p1 TO w2:p2: [HN:abcd1234] ' +
        '[APPLIED re [HR:7777aaaa]] [APPLIED-PANE w2:p2] [APPLIED-TAB w2:t2] [APPLIED-COORDINATOR w1:p1] ' +
        'applied; canonical_name=AGT-T-B2; subtitle_b64=; coordinator_session=coord-session; target_session=wrong-session')
    $sessionStatus = Invoke-HelperJson -Arguments @('-Action', 'naming-status', '-RelayRef', $sessionRef, '-LogPath', $sessionLog)
    Assert-True ($sessionStatus.requests[0].state -ne 'applied') 'Mismatched requester/target session APPLIED proof was accepted'

    $forgedDisposition = '[HD:feed1234] [DISPOSED re [HR:7777aaaa]] [DISPOSITION retirement_target_gone] ' +
        '[DISPOSED-PANE w2:p2] [DISPOSED-COORDINATOR w1:p1] disposed; coordinator_session=coord-session; ' +
        'requester_session=target-session; absence=pane_not_found'
    Add-Content -LiteralPath $sessionLog -Encoding utf8 -Value (
        '- [2026-08-14 10:01 -05:00] FROM w1:p1 TO w2:p2: ' + $forgedDisposition)
    $assignmentDispositionStatus = Invoke-HelperJson -Arguments @('-Action', 'naming-status', '-RelayRef', $sessionRef, '-LogPath', $sessionLog)
    Assert-True ($assignmentDispositionStatus.requests[0].state -ne 'retirement_target_gone') 'Assignment request accepted a forged retirement disposition'

    $unackedRetirementLog = Join-Path $testRoot 'unacked-retirement-proof.md'
    $unackedRetirementRef = '[HR:7777bbbb]'
    $explicitRetirementPayload = 'PANE NAMING REQUEST: repo=AGT; lifecycle=retirement; requester_pane=w2:p2; requester_tab=w2:t2; ' +
        'requester_agent=codex; requester_session=target-session; lane=T; role=B; work=issue; issue=#113; title=retired; ' +
        'previous_name=AGT-T-B1; previous_work=#113; coordinator_action=apply-name-and-return-proof'
    New-NamingLog -Path $unackedRetirementLog -RelayRef $unackedRetirementRef -Payload $explicitRetirementPayload -WithReadAck $false
    Add-Content -LiteralPath $unackedRetirementLog -Encoding utf8 -Value (
        '- [2026-08-14 10:01 -05:00] FROM w1:p1 TO w2:p2: [HD:feed5678] [DISPOSED re [HR:7777bbbb]] ' +
        '[DISPOSITION retirement_target_gone] [DISPOSED-PANE w2:p2] [DISPOSED-COORDINATOR w1:p1] disposed; ' +
        'coordinator_session=coord-session; requester_session=target-session; absence=pane_not_found')
    $unackedDispositionStatus = Invoke-HelperJson -Arguments @('-Action', 'naming-status', '-RelayRef', $unackedRetirementRef, '-LogPath', $unackedRetirementLog)
    Assert-True ($unackedDispositionStatus.requests[0].state -ne 'retirement_target_gone') 'Disposition without a valid read ACK was accepted'

    $malformedLog = Join-Path $testRoot 'malformed-legacy.md'
    $malformedRef = '[HR:7777cccc]'
    $malformedPayload = 'PANE NAMING REQUEST: repo=AGT; coordinator_action=apply-name-and-return-proof'
    New-NamingLog -Path $malformedLog -RelayRef $malformedRef -Payload $malformedPayload
    Add-Content -LiteralPath $malformedLog -Encoding utf8 -Value (
        '- [2026-08-14 10:01 -05:00] FROM w1:p1 TO w2:p2: [HI:feed9999] [APPLY-STARTED re [HR:7777cccc]] ' +
        '[APPLY-PANE w2:p2] [APPLY-TAB w2:t2] [APPLY-COORDINATOR w1:p1] started; ' +
        'coordinator_session=coord-session; target_session=target-session')
    $malformedStatus = Invoke-HelperJson -Arguments @('-Action', 'naming-status', '-RelayRef', $malformedRef, '-LogPath', $malformedLog)
    Assert-Equal $malformedStatus.examined 1 'Malformed legacy request crashed the status sweep'

    $incompleteRelayLog = Join-Path $testRoot 'incomplete-legacy-relay.md'
    Set-Content -LiteralPath $incompleteRelayLog -Encoding utf8 -Value @(
        '# Herdr Coordination Log',
        '',
        '- [2026-08-14 10:00 -05:00] FROM w2:p2 TO coordinator: [HR:8888aaaa] [RECIPIENT-PANE w1:p1] ' +
            'PANE NAMING REQUEST: repo=AGT; work=issue; coordinator_action=apply-name-and-return-proof'
    )
    $incompleteStatus = Invoke-HelperJson -Arguments @('-Action', 'naming-status', '-LogPath', $incompleteRelayLog)
    Assert-Equal $incompleteStatus.examined 0 'Incomplete legacy relay was not safely ignored by status'
    [IO.File]::WriteAllText($callsPath, '', [Text.UTF8Encoding]::new($false))
    $incompleteConsume = Invoke-HelperJson -Arguments @('-Action', 'consume-name-requests', '-LogPath', $incompleteRelayLog)
    Assert-Equal $incompleteConsume.examined 0 'Incomplete legacy relay was not safely ignored by consume'
    Assert-True ((Get-MockCalls) -notmatch 'tab rename|report-metadata') 'Incomplete legacy relay performed a mutation'
    Assert-True (((Get-Content -LiteralPath $incompleteRelayLog) -join "`n") -notmatch '\[(?:HI|HN|HD):') 'Incomplete legacy relay created lifecycle evidence'

    # -- CASE 6: unfinished intent is uncertain and cannot be terminalized or retried --
    Write-Output 'CASE: unfinished apply intent fails closed as uncertain_apply'
    Reset-MockState
    $uncertainLog = Join-Path $testRoot 'uncertain.md'
    $uncertainRef = '[HR:6666aaaa]'
    New-NamingLog -Path $uncertainLog -RelayRef $uncertainRef
    Add-Content -LiteralPath $uncertainLog -Encoding utf8 -Value (
        '- [2026-08-14 10:00 -05:00] FROM w1:p1 TO w2:p2: [HI:abcd1234] ' +
        '[APPLY-STARTED re [HR:6666aaaa]] [APPLY-PANE w2:p2] [APPLY-TAB w2:t2] ' +
        '[APPLY-COORDINATOR w1:p1] started; coordinator_session=coord-session; target_session=target-session')
    $uncertainStatus = Invoke-HelperJson -Arguments @('-Action', 'naming-status', '-RelayRef', $uncertainRef, '-LogPath', $uncertainLog)
    Assert-Equal $uncertainStatus.requests[0].state 'uncertain_apply' 'Unfinished intent was not reported uncertain'
    Assert-True ([bool]$uncertainStatus.requests[0].uncertain) 'Uncertain flag was not set'
    [IO.File]::WriteAllText($callsPath, '', [Text.UTF8Encoding]::new($false))
    $uncertainConsume = Invoke-Helper -Arguments @('-Action', 'consume-name-requests', '-LogPath', $uncertainLog)
    Assert-True ($uncertainConsume.ExitCode -ne 0) 'Unfinished intent was retried instead of failing closed'
    Assert-True ($uncertainConsume.Text -match 'uncertain_apply') 'Unfinished intent failure omitted reconciliation state'
    Assert-True ((Get-MockCalls) -notmatch 'pane get w2:p2|tab rename|report-metadata') 'Uncertain intent touched the target pane'

    $forgeDisposition = Invoke-Helper -Arguments @(
        '-Action', 'append', '-From', $coordinatorPane, '-To', $targetPane, '-LogPath', $uncertainLog,
        '-Message', '[HD:deadbeef] [DISPOSED re [HR:6666aaaa]] [DISPOSITION retirement_target_gone]')
    Assert-True ($forgeDisposition.ExitCode -ne 0) 'append fabricated a retirement disposition'
    $forgeIntent = Invoke-Helper -Arguments @(
        '-Action', 'append', '-From', $coordinatorPane, '-To', $targetPane, '-LogPath', $uncertainLog,
        '-Message', '[HI:deadbeef] [APPLY-STARTED re [HR:6666aaaa]]')
    Assert-True ($forgeIntent.ExitCode -ne 0) 'append fabricated an apply intent'

    Write-Output "PASS: herdr-coordination naming lifecycle ($script:Passed assertions)"
}
finally {
    $env:PATH = $oldPath
    foreach ($name in $oldValues.Keys) {
        if ($null -eq $oldValues[$name]) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            [Environment]::SetEnvironmentVariable($name, $oldValues[$name], "Process")
        }
    }
    Remove-Item Env:HERDR_TEST_TARGET_SESSION -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

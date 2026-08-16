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
    param([string]$TargetTabLabel = "shell")
    $state = [ordered]@{
        target_tab_label = $TargetTabLabel
        target_title = ""
        target_display_agent = ""
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
        [string]$RecipientSession = "coord-session"
    )

    $labelB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Coordination"))
    $payloadHash = Get-Sha256Hex -Text $requestPayload
    $requestStamp = Format-Stamp -Value (Get-Date).AddHours(-3)
    $ackStamp = Format-Stamp -Value (Get-Date).AddHours(-2)

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("# Herdr Coordination Log")
    $lines.Add("")
    $lines.Add("## Messages")
    $lines.Add("")
    $lines.Add("- [$requestStamp] FROM $targetPane TO coordinator: $RelayRef " +
        "[RECIPIENT-PANE $RecipientPane] [RECIPIENT-SESSION $RecipientSession] [RECIPIENT-AGENT codex] " +
        "[RECIPIENT-TAB $RecipientTab] [RECIPIENT-LABEL-B64 $labelB64] [PAYLOAD-SHA256 $payloadHash] $requestPayload")
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
        return [ordered]@{ pane_id="w2:p2"; workspace_id="w2"; tab_id="w2:t2"; terminal_id="term-target"; revision=5; agent="codex"; agent_status="idle"; cwd="C:\dev\stmodel" }
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
    # Shim BOTH command surfaces the helper can reach. herdr_coordination.ps1
    # prefers "rtk proxy herdr ..." when rtk is on PATH and only falls back to
    # "herdr ...", so mocking herdr alone would leave the rtk path depending on
    # a real rtk being installed and its proxy being a raw passthrough. Owning
    # both names means no invocation can escape to a live Herdr, whether or not
    # rtk exists on the machine running the test. %* is forwarded verbatim so
    # non-ASCII subtitle text survives the hop.
    $mockCmd = "@echo off`r`npwsh -NoProfile -File `"%~dp0mock_herdr.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
    [IO.File]::WriteAllText((Join-Path $mockBin "herdr.cmd"), $mockCmd, [Text.ASCIIEncoding]::new())
    [IO.File]::WriteAllText((Join-Path $mockBin "rtk.cmd"), $mockCmd, [Text.ASCIIEncoding]::new())

    $env:PATH = "$mockBin;$oldPath"
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

    # -- CASE 4: duplicate processing is idempotent --
    Write-Output "CASE: duplicate consumption of an applied request is idempotent"
    $env:HERDR_TEST_CALLS = $callsPath
    [IO.File]::WriteAllText($callsPath, "", [Text.UTF8Encoding]::new($false))
    Set-Caller coordinator
    $again = Invoke-HelperJson -Arguments @("-Action", "consume-name-requests", "-LogPath", $applyLog)
    Assert-Equal $again.applied_count 0 "Duplicate consumption applied the request a second time"
    Assert-Equal $again.duplicate_count 1 "Duplicate consumption was not reported as a duplicate"
    Assert-Equal $again.failed_count 0 "Duplicate consumption reported a failure"
    Assert-Equal $again.results[0].state "already_applied" "Duplicate consumption did not short-circuit"
    Assert-Equal $again.results[0].tab_label $expectedName "Duplicate consumption lost the applied canonical name"
    Assert-Equal $again.results[0].title $expectedSubtitle "Duplicate consumption lost the applied subtitle"
    Assert-True ((Get-MockCalls) -notmatch "tab rename|report-metadata") "Duplicate consumption re-mutated pane state"

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

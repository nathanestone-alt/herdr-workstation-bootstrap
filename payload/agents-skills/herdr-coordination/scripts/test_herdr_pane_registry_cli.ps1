[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$registryScript = Join-Path $PSScriptRoot "herdr_pane_registry.ps1"
$coordinationScript = Join-Path $PSScriptRoot "herdr_coordination.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-pane-registry-cli-$([Guid]::NewGuid().ToString('N'))"
$mockBin = Join-Path $testRoot "bin"
$null = New-Item -ItemType Directory -Path $mockBin -Force
$registryPath = Join-Path $testRoot "registry.jsonl"
$statePath = Join-Path $testRoot "mock-state.json"
$oldPath = $env:PATH
$oldValues = @{}
foreach ($name in @("HERDR_ENV", "HERDR_WORKSPACE_ID", "HERDR_TAB_ID", "HERDR_PANE_ID", "HERDR_AGENT_SESSION_ID", "CODEX_THREAD_ID", "HERDR_TEST_STATE", "HERDR_TEST_AGENT_PID")) {
    $oldValues[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}
$script:Passed = 0

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

function Assert-Throws {
    param([scriptblock]$Script, [string]$Pattern, [string]$Message)
    try {
        & $Script
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Message (wrong error: $($_.Exception.Message))"
        }
        $script:Passed++
        return
    }
    throw "$Message (no error was thrown)"
}

function Set-Caller {
    param([ValidateSet("coordinator", "target")][string]$Caller)
    $env:HERDR_ENV = "1"
    if ($Caller -eq "coordinator") {
        $env:HERDR_WORKSPACE_ID = "w1"
        $env:HERDR_TAB_ID = "w1:t1"
        $env:HERDR_PANE_ID = "w1:p1"
        $env:HERDR_AGENT_SESSION_ID = "coord-session"
        $env:CODEX_THREAD_ID = "coord-session"
    }
    else {
        $env:HERDR_WORKSPACE_ID = "w2"
        $env:HERDR_TAB_ID = "w2:t1"
        $env:HERDR_PANE_ID = "w2:p1"
        $env:HERDR_AGENT_SESSION_ID = "target-session"
        Remove-Item Env:CODEX_THREAD_ID -ErrorAction SilentlyContinue
    }
}

function Invoke-Registry {
    param([string[]]$Arguments)
    $output = & pwsh -NoProfile -File $registryScript -RegistryPath $registryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 32)
}

try {
    $mockState = [ordered]@{
        target_tab_label = "E1"
        target_title = ""
        target_display_agent = ""
        target_tokens = [ordered]@{}
    }
    [IO.File]::WriteAllText($statePath, ($mockState | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

    $mockScript = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$statePath = $env:HERDR_TEST_STATE
$state = Get-Content -Raw $statePath | ConvertFrom-Json -Depth 16
$arguments = @($args)

function Save-State {
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
}

function Pane-Data([string]$paneId) {
    if ($paneId -eq "w1:p1") {
        return [ordered]@{ pane_id="w1:p1"; workspace_id="w1"; tab_id="w1:t1"; terminal_id="term-coord"; terminal_title="Coordinator"; terminal_title_stripped="Coordinator"; agent="codex"; agent_status="idle"; revision=10; cwd="C:\dev\Codex\Herder" }
    }
    if ($paneId -eq "w2:p1") {
        return [ordered]@{ pane_id="w2:p1"; workspace_id="w2"; tab_id="w2:t1"; terminal_id="term-target"; terminal_title="Target"; terminal_title_stripped="Target"; agent="claude"; agent_status="idle"; revision=20; cwd="C:\dev\stmodel" }
    }
    throw "unknown pane $paneId"
}

if ($arguments[0] -eq "pane" -and $arguments[1] -eq "get") {
    $pane = Pane-Data $arguments[2]
    [ordered]@{ id="test"; result=[ordered]@{ type="pane_info"; pane=$pane } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "tab" -and $arguments[1] -eq "get") {
    $tabId = $arguments[2]
    $tab = if ($tabId -eq "w1:t1") {
        [ordered]@{ tab_id="w1:t1"; workspace_id="w1"; label="Coordination"; pane_count=1; focused=$false; number=1; agent_status="idle" }
    } else {
        [ordered]@{ tab_id="w2:t1"; workspace_id="w2"; label=[string]$state.target_tab_label; pane_count=1; focused=$false; number=1; agent_status="idle" }
    }
    [ordered]@{ id="test"; result=[ordered]@{ type="tab_info"; tab=$tab } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "workspace" -and $arguments[1] -eq "get") {
    $workspaceId = $arguments[2]
    $workspace = if ($workspaceId -eq "w1") {
        [ordered]@{ workspace_id="w1"; label="Hdr"; tab_count=2; pane_count=2; active_tab_id="w1:t1" }
    } else {
        [ordered]@{ workspace_id="w2"; label="STM"; tab_count=1; pane_count=1; active_tab_id="w2:t1" }
    }
    [ordered]@{ id="test"; result=[ordered]@{ type="workspace_info"; workspace=$workspace } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "agent" -and $arguments[1] -eq "get") {
    $pane = Pane-Data $arguments[2]
    $session = if ($pane.agent -eq "codex") { "coord-session" } else { "target-session" }
    $pane.agent_session = [ordered]@{ agent=$pane.agent; kind="id"; source="test"; value=$session }
    [ordered]@{ id="test"; result=[ordered]@{ type="agent_info"; agent=$pane } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "pane" -and $arguments[1] -eq "process-info") {
    $paneId = $arguments[-1]
    $pane = Pane-Data $paneId
    [ordered]@{ id="test"; result=[ordered]@{ type="pane_process_info"; process_info=[ordered]@{ shell_pid=[int]$env:HERDR_TEST_AGENT_PID; foreground_processes=@([ordered]@{ pid=[int]$env:HERDR_TEST_AGENT_PID; name=$pane.agent }) } } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "authorization" -and $arguments[1] -eq "consume") {
    $approvalId = $arguments[2]
    $operation = $arguments[[Array]::IndexOf($arguments, "--operation") + 1]
    $subject = $arguments[[Array]::IndexOf($arguments, "--subject-sha256") + 1]
    [ordered]@{ id="test"; result=[ordered]@{ type="authorization_consumed"; approval=[ordered]@{ consumed=$true; approval_id=$approvalId; operation=$operation; subject_sha256=$subject } } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "tab" -and $arguments[1] -eq "rename") {
    if ($arguments[2] -ne "w2:t1") { throw "unexpected tab rename" }
    $state.target_tab_label = $arguments[3]
    Save-State
    [ordered]@{ id="test"; result=[ordered]@{ type="tab_renamed"; tab_id="w2:t1"; label=$arguments[3] } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
if ($arguments[0] -eq "pane" -and $arguments[1] -eq "report-metadata") {
    $titleIndex = [Array]::IndexOf($arguments, "--title")
    if ($titleIndex -ge 0) { $state.target_title = $arguments[$titleIndex + 1] }
    $displayAgentIndex = [Array]::IndexOf($arguments, "--display-agent")
    if ($displayAgentIndex -ge 0) { $state.target_display_agent = $arguments[$displayAgentIndex + 1] }
    $tokens = [ordered]@{}
    for ($i=0; $i -lt $arguments.Count; $i++) {
        if ($arguments[$i] -eq "--token") {
            $parts = $arguments[$i+1] -split "=", 2
            $tokens[$parts[0]] = $parts[1]
        }
    }
    $state.target_tokens = $tokens
    Save-State
    [ordered]@{ id="test"; result=[ordered]@{ type="pane_metadata_reported"; pane_id="w2:p1" } } | ConvertTo-Json -Depth 16 -Compress
    exit 0
}
throw "unsupported mock herdr command: $($arguments -join ' ')"
'@
    $mockScriptPath = Join-Path $mockBin "mock_herdr.ps1"
    [IO.File]::WriteAllText($mockScriptPath, $mockScript, [Text.UTF8Encoding]::new($false))
    $mockCmd = "@echo off`r`npwsh -NoProfile -File `"%~dp0mock_herdr.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
    [IO.File]::WriteAllText((Join-Path $mockBin "herdr.cmd"), $mockCmd, [Text.ASCIIEncoding]::new())

    $env:PATH = "$mockBin;$oldPath"
    $env:HERDR_TEST_STATE = $statePath
    $env:HERDR_TEST_AGENT_PID = [string]$PID

    Set-Caller coordinator
    $authority = Invoke-Registry @("-Action", "authority-acquire", "-ApprovalId", "approval-test", "-PaneId", "w1:p1")
    Assert-True $authority.acquired "Coordinator authority was not acquired"
    Assert-Equal $authority.authority_epoch 1 "Initial authority epoch was wrong"

    $challenge = Invoke-Registry @("-Action", "challenge", "-PaneId", "w2:p1", "-Repo", "STM", "-Explore", "-Slot", "1", "-WorkKind", "explore", "-Topic", "unassigned")
    Assert-True $challenge.reserved "Explore reservation was not created"
    Assert-Equal $challenge.canonical_name "STM-E1" "Explore canonical name was wrong"
    Assert-Equal $challenge.generation 1 "Initial generation was wrong"

    Set-Caller target
    $claim = Invoke-Registry @("-Action", "claim", "-ReservationId", $challenge.reservation_id, "-Challenge", $challenge.challenge)
    Assert-True $claim.claimed "Target did not create a proof-bound claim"

    Set-Caller coordinator
    $assignment = Invoke-Registry @("-Action", "assign", "-ReservationId", $challenge.reservation_id)
    Assert-True $assignment.prepared "Coordinator did not prepare assignment"
    Assert-Equal $assignment.canonical_name "STM-E1" "Prepared assignment changed canonical name"
    $updatedState = Get-Content -Raw $statePath | ConvertFrom-Json -Depth 16
    Assert-Equal $updatedState.target_tab_label "STM-E1" "Canonical tab rename was not applied"
    Assert-Equal $updatedState.target_title "EXPLORE · unassigned" "Work subname was not applied"
    Assert-Equal $updatedState.target_display_agent "EXPLORE · unassigned" "Sidebar work subtitle was not applied"
    Assert-Equal $updatedState.target_tokens.canonical_name "STM-E1" "Registry metadata token was not applied"

    Assert-Throws {
        Invoke-Registry @("-Action", "resolve", "-Name", "@pane[STM-E1]")
    } "does not resolve" "Unacknowledged reservation became routeable"

    Set-Caller target
    $ack = Invoke-Registry @("-Action", "ack-assignment", "-ReservationId", $challenge.reservation_id, "-AssignmentToken", $assignment.assignment_token)
    Assert-True $ack.acknowledged "Target did not acknowledge prepared assignment"

    Set-Caller coordinator
    $activation = Invoke-Registry @("-Action", "activate", "-ReservationId", $challenge.reservation_id)
    Assert-True $activation.activated "Coordinator did not activate acknowledged assignment"
    Assert-Equal $activation.generation 1 "Activated generation was wrong"

    $resolved = Invoke-Registry @("-Action", "resolve", "-Name", "@pane[STM-E1]")
    Assert-True $resolved.resolved "Active human pane reference did not resolve"
    Assert-Equal $resolved.binding.pane_id "w2:p1" "Human pane reference resolved to wrong pane"
    Assert-Equal $resolved.binding.agent "claude" "Provider was not preserved separately"
    $reverse = Invoke-Registry @("-Action", "resolve-pane", "-PaneId", "w2:p1")
    Assert-Equal $reverse.binding.canonical_name "STM-E1" "Reverse pane lookup lost canonical identity"

    Set-Caller target
    $coordinationLog = Join-Path $testRoot "coordination.md"
    $sendOutput = & pwsh -NoProfile -File $coordinationScript `
        -Action send -To "@pane[STM-E1]" -Message "Registry-routed self-test" `
        -PaneRegistryPath $registryPath -LogPath $coordinationLog 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Registry-addressed coordination send failed: $($sendOutput -join [Environment]::NewLine)"
    }
    $send = ($sendOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 32
    Assert-Equal $send.recipient_pane_id "w2:p1" "Registry-addressed relay targeted the wrong pane"
    Assert-Equal $send.registry_binding.generation 1 "Registry-addressed relay lost generation proof"
    Assert-True ((Get-Content -Raw $coordinationLog) -match '\[REGISTRY-ID reg_') "Durable relay omitted registry identity"
    $relayOutput = & pwsh -NoProfile -File $coordinationScript `
        -Action relay-status -RelayRef $send.relay_ref -LogPath $coordinationLog 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Registry-addressed relay status failed: $($relayOutput -join [Environment]::NewLine)"
    }
    $relayStatus = ($relayOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 32
    Assert-Equal $relayStatus.recipient_pane_id "w2:p1" "Registry-addressed relay status lost the resolved pane"
    Assert-True ((Get-Content -Raw $coordinationLog) -match '\[PAYLOAD-SHA256 [0-9a-f]{64}\]') "Registry envelope omitted durable payload hashing"

    $revalidated = Invoke-Registry @(
        "-Action", "revalidate", "-Name", "STM-E1",
        "-ExpectedRegistryId", $resolved.binding.registry_id,
        "-ExpectedBindingId", $resolved.binding.binding_id,
        "-ExpectedGeneration", [string]$resolved.binding.generation
    )
    Assert-True $revalidated.valid "Resolved generation did not revalidate"
    Assert-Throws {
        Invoke-Registry @(
            "-Action", "revalidate", "-Name", "STM-E1",
            "-ExpectedRegistryId", $resolved.binding.registry_id,
            "-ExpectedBindingId", $resolved.binding.binding_id,
            "-ExpectedGeneration", "2"
        )
    } "changed after resolution" "Stale generation was allowed to revalidate"
    Assert-Throws {
        $staleOutput = & pwsh -NoProfile -File $coordinationScript `
            -Action send -To "w2:p1" -Message "stale generation" `
            -ExpectedRegistryId $resolved.binding.registry_id `
            -ExpectedBindingId $resolved.binding.binding_id `
            -ExpectedRegistryName $resolved.binding.canonical_name `
            -ExpectedGeneration 2 `
            -PaneRegistryPath $registryPath -LogPath $coordinationLog 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($staleOutput -join [Environment]::NewLine) }
    } "does not match|no longer matches|changed" "Stale generation reached coordination transport"

    Set-Caller coordinator
    Assert-Throws {
        Invoke-Registry @("-Action", "challenge", "-PaneId", "w2:p1", "-Repo", "AGT", "-Explore", "-Slot", "1")
    } "must use workspace 'AGT'" "Cross-repository workspace claim was accepted"

    $status = Invoke-Registry @("-Action", "status")
    Assert-Equal $status.active_bindings.Count 1 "Registry status did not expose one active binding"
    Assert-True $status.authority_current "Registry status lost current authority"

    [pscustomobject]@{ passed=$script:Passed; registry_id=$status.registry_id; active_name=$status.active_bindings[0].canonical_name } | ConvertTo-Json -Compress
}
finally {
    $env:PATH = $oldPath
    foreach ($name in $oldValues.Keys) {
        $value = $oldValues[$name]
        if ($null -eq $value) {
            [Environment]::SetEnvironmentVariable($name, $null, "Process")
        }
        else {
            [Environment]::SetEnvironmentVariable($name, [string]$value, "Process")
        }
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

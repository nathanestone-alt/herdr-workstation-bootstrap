[CmdletBinding()]
param(
    [ValidateSet("discover", "init", "append", "deliver", "send", "name-request", "apply-name", "consume-name-requests", "naming-status", "prove-caller", "ack-read", "relay-status", "rename-current", "watch-queued")]
    [string]$Action = "discover",

    [string]$Message,

    [string]$PaneId,

    [string]$Label,

    [ValidateSet("STM", "AGT", "HDR", "BUZ")]
    [string]$RepoCode,

    [ValidatePattern("^[A-Z][A-Z0-9]{0,7}$")]
    [string]$LaneCode,

    [ValidatePattern("^[A-Z]$")]
    [string]$RoleCode,

    [ValidateSet("explore", "issue", "pr", "no-issue")]
    [string]$WorkKind,

    [string]$IssueNumber,

    [string]$WorkTitle,

    [string]$Topic,

    [string]$PreviousName,

    [string]$PreviousWork,

    [ValidateSet('assignment', 'retirement')]
    [string]$NamingLifecycle = 'assignment',

    [string]$CanonicalName,

    [string]$Subtitle,

    [string]$ExpectedCurrentLabel,

    [string]$ExpectedTargetSession,

    # Watchdog deadline for a naming request that was read-ACKed but never
    # APPLIED. Coordination-log stamps have minute resolution, so a deadline
    # below 60 seconds is evaluated against a coarser clock than it implies.
    [ValidateRange(1, 86400)]
    [int]$NamingDeadlineSeconds = 300,

    [ValidateRange(1, 5000)]
    [int]$MaxNamingRequests = 200,

    [string]$To = "ALL",

    [string]$From = $env:HERDR_PANE_ID,

    [string]$TabLabel = "Coordination",

    [string]$Token,

    [string]$RelayRef,

    [string]$WorkflowRef,

    [string]$WorkflowLedgerPath = $(Join-Path ([IO.Path]::GetTempPath()) "herdr-workflow-ledger.jsonl"),

    [string]$ExpectedAgent,

    [string]$ExpectedSession,

    [string]$ExpectedTabLabel,

    [string]$ExpectedTabId,

    [string]$PaneRegistryPath = $(Join-Path ([IO.Path]::GetTempPath()) "herdr-pane-registry.jsonl"),

    [string]$ExpectedRegistryId,

    [string]$ExpectedBindingId,

    [string]$ExpectedRegistryName,

    [long]$ExpectedGeneration = -1,

    [long]$ExpectedRevision = -1,

    [string]$ExpectedTerminalId,

    [int]$ExpectedShellPid,

    [int]$ExpectedAgentPid,

    [ValidateRange(1000, 3600000)]
    [int]$WatchTimeoutMs = 900000,

    [ValidateRange(1000, 3600000)]
    [int]$EarlyAlertMs = 60000,

    [string]$WatchLogPath = $(Join-Path ([IO.Path]::GetTempPath()) "herdr-coordination-watch.md"),

    [string]$LogPath = $(
        if ($env:HERDR_COORDINATION_LOG) {
            $env:HERDR_COORDINATION_LOG
        }
        else {
            (Join-Path ([IO.Path]::GetTempPath()) "herdr-coordination.md")
        }
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$OutputEncoding = $utf8NoBom
$PromptDetectionLineCount = 128
$RelayContinuationInstruction = "After running the ACK command above (ack-read or workflow ACK), immediately execute the instructions in the relay body as your current task; the ACK is a receipt, not completion; do not end your turn after ACKing."
try {
    [Console]::OutputEncoding = $utf8NoBom
}
catch {
    # Hidden watcher processes may not own a console; native-command decoding still uses $OutputEncoding.
}

function Invoke-HerdrText {
    param([Parameter(Mandatory)][string[]]$Arguments)

    if ($env:HERDR_ENV -ne "1") {
        throw "HERDR_ENV=1 is required for Herdr coordination control."
    }

    $rtk = Get-Command rtk -ErrorAction SilentlyContinue
    if ($rtk) {
        $output = & $rtk.Source proxy herdr @Arguments 2>&1
    }
    else {
        $herdr = Get-Command herdr -ErrorAction Stop
        $output = & $herdr.Source @Arguments 2>&1
    }

    if ($LASTEXITCODE -ne 0) {
        $failureText = $output -join [Environment]::NewLine
        if ($failureText -match '(?i)PermissionDenied|Operation not permitted') {
            throw "host_access_unavailable: native Herdr access for 'herdr $($Arguments -join ' ')' returned PermissionDenied/Operation not permitted. HERDR_ENV=1 is not sufficient; obtain host-level execution before issuing any workflow or naming command."
        }
        throw "herdr $($Arguments -join ' ') failed: $failureText"
    }

    return $output -join [Environment]::NewLine
}

function Invoke-HerdrJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $text = Invoke-HerdrText -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    try {
        return $text | ConvertFrom-Json
    }
    catch {
        # RTK proxy output can be hard-wrapped at the terminal width while it is
        # captured by Windows PowerShell, including in the middle of JSON tokens.
        # Herdr emits one compact JSON document, so removing physical line breaks
        # is safe (JSON string newlines remain escaped as "\n").
        $unwrappedText = $text -replace "[`r`n]", ""
        try {
            return $unwrappedText | ConvertFrom-Json
        }
        catch {
            throw "herdr $($Arguments -join ' ') returned invalid JSON: $text"
        }
    }
}

function Get-AgentSessionId {
    param([Parameter(Mandatory)]$AgentRecord)

    $sessionProperty = $AgentRecord.PSObject.Properties["agent_session"]
    if (-not $sessionProperty -or $null -eq $sessionProperty.Value) {
        return $null
    }

    if ($sessionProperty.Value -is [string]) {
        $sessionId = [string]$sessionProperty.Value
    }
    else {
        $valueProperty = $sessionProperty.Value.PSObject.Properties["value"]
        if (-not $valueProperty) {
            return $null
        }
        $sessionId = [string]$valueProperty.Value
    }

    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        return $null
    }
    return $sessionId
}

function Get-AgentSessionAgent {
    param([Parameter(Mandatory)]$AgentRecord)

    $sessionProperty = $AgentRecord.PSObject.Properties["agent_session"]
    if (-not $sessionProperty -or $null -eq $sessionProperty.Value -or $sessionProperty.Value -is [string]) {
        return $null
    }
    $agentProperty = $sessionProperty.Value.PSObject.Properties["agent"]
    if (-not $agentProperty -or [string]::IsNullOrWhiteSpace([string]$agentProperty.Value)) {
        return $null
    }
    return [string]$agentProperty.Value
}

function Get-AgentProcessLease {
    param(
        [Parameter(Mandatory)][string]$TargetPaneId,
        [Parameter(Mandatory)][string]$TargetAgent,
        [Parameter(Mandatory)]$AgentRecord
    )

    $revisionProperty = $AgentRecord.PSObject.Properties["revision"]
    $terminalProperty = $AgentRecord.PSObject.Properties["terminal_id"]
    if ($null -eq $revisionProperty -or
        $null -eq $terminalProperty -or
        [string]::IsNullOrWhiteSpace([string]$terminalProperty.Value)) {
        return $null
    }

    $processResponse = Invoke-HerdrJson -Arguments @("pane", "process-info", "--pane", $TargetPaneId)
    $processInfo = $processResponse.result.process_info
    $shellPid = [int]$processInfo.shell_pid
    if ($shellPid -le 0) {
        return $null
    }

    $namePattern = switch ($TargetAgent) {
        "codex" { "^codex(?:\.exe)?$" }
        "claude" { "^claude(?:\.exe)?$" }
        default { return $null }
    }

    $agentProcesses = @(
        $processInfo.foreground_processes |
            Where-Object { [string]$_.name -match $namePattern }
    )
    if ($agentProcesses.Count -ne 1 -and
        $IsWindows -and
        (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        try {
            $agentProcesses = @(
                Get-CimInstance Win32_Process -Filter "ParentProcessId = $shellPid" -ErrorAction Stop |
                    Where-Object { [string]$_.Name -match $namePattern }
            )
        }
        catch {
            return $null
        }
    }
    if ($agentProcesses.Count -ne 1) {
        return $null
    }
    $pidProperty = $agentProcesses[0].PSObject.Properties["pid"]
    if ($null -eq $pidProperty) {
        $pidProperty = $agentProcesses[0].PSObject.Properties["ProcessId"]
    }
    if ($null -eq $pidProperty -or [int]$pidProperty.Value -le 0) {
        return $null
    }

    return [pscustomobject]@{
        revision = [long]$revisionProperty.Value
        terminal_id = [string]$terminalProperty.Value
        shell_pid = $shellPid
        agent_pid = [int]$pidProperty.Value
    }
}

function Test-AgentProcessLease {
    param(
        [Parameter(Mandatory)][string]$TargetPaneId,
        [Parameter(Mandatory)][string]$TargetAgent,
        [Parameter(Mandatory)]$AgentRecord,
        [Parameter(Mandatory)]$ExpectedLease
    )

    $currentLease = Get-AgentProcessLease `
        -TargetPaneId $TargetPaneId `
        -TargetAgent $TargetAgent `
        -AgentRecord $AgentRecord
    return $null -ne $currentLease -and
        [long]$currentLease.revision -eq [long]$ExpectedLease.revision -and
        [string]$currentLease.terminal_id -eq [string]$ExpectedLease.terminal_id -and
        [int]$currentLease.shell_pid -eq [int]$ExpectedLease.shell_pid -and
        [int]$currentLease.agent_pid -eq [int]$ExpectedLease.agent_pid
}

function Test-CurrentProcessDescendsFrom {
    param([Parameter(Mandatory)][int]$AncestorProcessId)

    if ($AncestorProcessId -le 0) {
        return $false
    }
    $cursor = [int]$PID
    $seen = @{}
    for ($depth = 0; $depth -lt 32 -and $cursor -gt 0; $depth++) {
        if ($cursor -eq $AncestorProcessId) {
            return $true
        }
        if ($seen.ContainsKey($cursor)) {
            return $false
        }
        $seen[$cursor] = $true
        if ($IsWindows) {
            if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
                return $false
            }
            try {
                $process = Get-CimInstance Win32_Process -Filter "ProcessId = $cursor" -ErrorAction Stop
            }
            catch {
                return $false
            }
            if ($null -eq $process) {
                return $false
            }
            $cursor = [int]$process.ParentProcessId
        }
        else {
            $statusPath = Join-Path "/proc" "$cursor/status"
            if (-not (Test-Path -LiteralPath $statusPath)) {
                return $false
            }
            try {
                $status = [IO.File]::ReadAllText($statusPath)
            }
            catch {
                return $false
            }
            $parentMatch = [regex]::Match($status, '(?m)^PPid:\s+(\d+)\s*$')
            if (-not $parentMatch.Success) {
                return $false
            }
            $cursor = [int]$parentMatch.Groups[1].Value
        }
    }
    return $false
}

function Get-TrackedPromptState {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Detection,
        [Parameter(Mandatory)][string]$TrackedToken
    )

    $lines = $Detection -split "\r?\n"
    $tokenVisible = $false
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        if ($lines[$index].Contains($TrackedToken)) {
            $tokenVisible = $true
        }
        if ($lines[$index] -match "^\s*(?:›|❯|>)\s*") {
            # The active composer can wrap a long message across many lines or
            # contain multiple queued HC messages under one prompt marker.
            # Everything after the final prompt marker belongs to that active
            # composer; the token does not have to remain on the marker line.
            if ($tokenVisible) {
                return "active"
            }
            break
        }
    }
    if ($tokenVisible -or $Detection.Contains($TrackedToken)) {
        return "history"
    }
    return "absent"
}

function Test-TokenInActivePrompt {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Detection,
        [Parameter(Mandatory)][string]$TrackedToken
    )
    return (Get-TrackedPromptState -Detection $Detection -TrackedToken $TrackedToken) -eq "active"
}

function Get-CurrentPromptText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Detection)

    $lines = $Detection -split "\r?\n"
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        if ($lines[$index] -match "^\s*(?:›|❯|>)\s*(?<text>.*)$") {
            return ([string]$Matches["text"]).Trim()
        }
    }
    return $null
}

function Test-ReceiptBoundHistoryPromptSafe {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Detection)

    $currentPromptText = Get-CurrentPromptText -Detection $Detection
    if ($null -eq $currentPromptText -or [string]::IsNullOrWhiteSpace($currentPromptText)) {
        return $true
    }

    # Codex renders these rotating suggestions as dim placeholder text inside an
    # otherwise empty composer. Detection text intentionally strips styling, so
    # recognize only the exact built-in placeholders observed in supported builds.
    return $currentPromptText -cin @(
        "Explain this codebase",
        "Improve documentation in @filename",
        "Find and fix a bug in @filename"
    )
}

function Watch-QueuedPaneMessageLegacy {
    param(
        [Parameter(Mandatory)][string]$TargetPaneId,
        [Parameter(Mandatory)][string]$TrackedToken,
        [Parameter(Mandatory)][string]$TargetAgent,
        [Parameter(Mandatory)][string]$TargetSession,
        [Parameter(Mandatory)][int]$TimeoutMs
    )

    $enterSent = $false
    $watchDeadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    try {
        $null = Invoke-HerdrJson -Arguments @(
            "agent", "wait", $TargetPaneId,
            "--until", "idle",
            "--until", "done",
            "--until", "blocked",
            "--timeout", "$TimeoutMs"
        )

        $readyResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
        $ready = $readyResponse.result.agent
        $readySession = Get-AgentSessionId -AgentRecord $ready
        $readySessionAgent = Get-AgentSessionAgent -AgentRecord $ready
        if ([string]$ready.pane_id -ne $TargetPaneId -or
            [string]$ready.agent -ne $TargetAgent -or
            $readySession -ne $TargetSession -or
            $readySessionAgent -ne $TargetAgent) {
            throw "Queued prompt recovery refused because the explicit target agent or native session changed."
        }

        $readySequenceProperty = $ready.PSObject.Properties["state_change_seq"]
        $readySequence = if ($null -ne $readySequenceProperty) {
            [long]$readySequenceProperty.Value
        }
        else {
            $null
        }
        $readyStatus = [string]$ready.agent_status
        $fastPollingDeadline = [DateTime]::UtcNow.AddSeconds(10)
        $promptState = "absent"
        do {
            $observedResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
            $observed = $observedResponse.result.agent
            $observedSession = Get-AgentSessionId -AgentRecord $observed
            $observedSessionAgent = Get-AgentSessionAgent -AgentRecord $observed
            if ([string]$observed.pane_id -ne $TargetPaneId -or
                [string]$observed.agent -ne $TargetAgent -or
                $observedSession -ne $TargetSession -or
                $observedSessionAgent -ne $TargetAgent) {
                throw "Queued prompt recovery refused because target identity changed while awaiting prompt staging."
            }

            $detection = Invoke-HerdrText -Arguments @(
                "agent", "read", $TargetPaneId,
                "--source", "detection",
                "--lines", "$PromptDetectionLineCount",
                "--format", "text"
            )
            $promptState = Get-TrackedPromptState -Detection $detection -TrackedToken $TrackedToken
            if ($promptState -eq "active") {
                break
            }

            $observedSequenceProperty = $observed.PSObject.Properties["state_change_seq"]
            $observedSequence = if ($null -ne $observedSequenceProperty) {
                [long]$observedSequenceProperty.Value
            }
            else {
                $null
            }
            $observedStatus = [string]$observed.agent_status
            $sequenceAdvanced = $null -ne $readySequence -and
                $null -ne $observedSequence -and
                $observedSequence -gt $readySequence
            $activeTransitionObserved = $observedStatus -in @("working", "blocked") -and
                $observedStatus -ne $readyStatus
            if ($promptState -eq "history" -and ($sequenceAdvanced -or $activeTransitionObserved)) {
                return [pscustomobject]@{
                    pane_id = $TargetPaneId
                    agent = $TargetAgent
                    token = $TrackedToken
                    submitted = $true
                    transport = "agent_prompt+queued_watch"
                    delivery_state = "accepted_queued_without_recovery"
                    enter_recovered = $false
                    recovery_key = $null
                    status_after = $observedStatus
                    error = $null
                }
            }

            $pollMilliseconds = if ([DateTime]::UtcNow -lt $fastPollingDeadline) { 250 } else { 1000 }
            Start-Sleep -Milliseconds $pollMilliseconds
        } while ([DateTime]::UtcNow -lt $watchDeadline)

        if ($promptState -eq "history") {
            $debugLines = $detection -split "\r?\n"
            $markerIndexes = @()
            $tokenIndexes = @()
            for ($debugIndex = 0; $debugIndex -lt $debugLines.Count; $debugIndex++) {
                if ($debugLines[$debugIndex] -match "^\s*(?:›|❯|>)\s*") {
                    $markerIndexes += $debugIndex
                }
                if ($debugLines[$debugIndex].Contains($TrackedToken)) {
                    $tokenIndexes += $debugIndex
                }
            }
            $markerShape = if ($markerIndexes.Count) { $markerIndexes -join "," } else { "none" }
            $tokenShape = if ($tokenIndexes.Count) { $tokenIndexes -join "," } else { "none" }
            throw "Queued prompt recovery remained ambiguous: the token was visible only in history and no post-availability lifecycle transition proved delivery before the watcher timeout. Detection shape: marker_lines=$markerShape token_lines=$tokenShape."
        }
        if ($promptState -ne "active") {
            throw "Queued prompt recovery refused because the exact token did not appear in the active prompt box before the watcher timeout."
        }

        $stagedResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
        $staged = $stagedResponse.result.agent
        $stagedSession = Get-AgentSessionId -AgentRecord $staged
        $stagedSessionAgent = Get-AgentSessionAgent -AgentRecord $staged
        if ([string]$staged.pane_id -ne $TargetPaneId -or
            [string]$staged.agent -ne $TargetAgent -or
            $stagedSession -ne $TargetSession -or
            $stagedSessionAgent -ne $TargetAgent) {
            throw "Queued prompt recovery refused because target identity changed during the staging grace period."
        }

        $null = Invoke-HerdrJson -Arguments @("agent", "send-keys", $TargetPaneId, "Enter")
        $enterSent = $true
        $null = Invoke-HerdrJson -Arguments @(
            "agent", "wait", $TargetPaneId,
            "--until", "working",
            "--until", "blocked",
            "--timeout", "7000"
        )

        $afterResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
        $after = $afterResponse.result.agent
        $afterSession = Get-AgentSessionId -AgentRecord $after
        $afterSessionAgent = Get-AgentSessionAgent -AgentRecord $after
        if ([string]$after.pane_id -ne $TargetPaneId -or
            [string]$after.agent -ne $TargetAgent -or
            $afterSession -ne $TargetSession -or
            $afterSessionAgent -ne $TargetAgent -or
            [string]$after.agent_status -notin @("working", "blocked")) {
            throw "Enter was sent, but queued prompt processing could not be revalidated."
        }

        return [pscustomobject]@{
            pane_id = $TargetPaneId
            agent = $TargetAgent
            token = $TrackedToken
            submitted = $true
            transport = "agent_prompt+queued_watch_enter"
            delivery_state = "accepted_after_queued_enter_recovery"
            enter_recovered = $true
            recovery_key = "Enter"
            status_after = [string]$after.agent_status
            error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            pane_id = $TargetPaneId
            agent = $TargetAgent
            token = $TrackedToken
            submitted = $false
            transport = "agent_prompt+queued_watch"
            delivery_state = if ($enterSent) { "recovery_unverified" } else { "queued_recovery_failed" }
            enter_recovered = $enterSent
            recovery_key = if ($enterSent) { "Enter" } else { $null }
            status_after = $null
            error = $_.Exception.Message
        }
    }
}

function Watch-QueuedPaneMessage {
    param(
        [Parameter(Mandatory)][string]$TargetPaneId,
        [Parameter(Mandatory)][string]$TrackedToken,
        [Parameter(Mandatory)][string]$TargetAgent,
        [string]$TargetSession,
        [object]$TargetProcessLease,
        [Parameter(Mandatory)][int]$TimeoutMs,
        [Parameter(Mandatory)][int]$AlertAfterMs
    )

    $enterSent = $false
    $enterAttempts = 0
    $earlyAlertSent = $false
    $earlyAlertError = $null
    $watchDeadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $earlyAlertDeadline = $null
    try {
        $useNativeSession = -not [string]::IsNullOrWhiteSpace($TargetSession)
        $useProcessLease = $null -ne $TargetProcessLease
        if (-not $useNativeSession -and -not $useProcessLease) {
            throw "Queued prompt recovery refused because no native session or stable agent-process lease was available."
        }

        $initialResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
        $initial = $initialResponse.result.agent
        $initialSession = Get-AgentSessionId -AgentRecord $initial
        $initialSessionAgent = Get-AgentSessionAgent -AgentRecord $initial
        if ([string]$initial.pane_id -ne $TargetPaneId -or
            [string]$initial.agent -ne $TargetAgent) {
            throw "Queued prompt recovery refused because the explicit target agent changed."
        }
        if ($useNativeSession -and
            ($initialSession -ne $TargetSession -or $initialSessionAgent -ne $TargetAgent)) {
            throw "Queued prompt recovery refused because the native session changed."
        }
        if ($useProcessLease -and -not (Test-AgentProcessLease `
                -TargetPaneId $TargetPaneId `
                -TargetAgent $TargetAgent `
                -AgentRecord $initial `
                -ExpectedLease $TargetProcessLease)) {
            throw "Queued prompt recovery refused because the stable agent-process lease changed."
        }

        $initialStatus = [string]$initial.agent_status
        $initialSequenceProperty = $initial.PSObject.Properties["state_change_seq"]
        $initialSequence = if ($null -ne $initialSequenceProperty) {
            [long]$initialSequenceProperty.Value
        }
        else {
            $null
        }
        $availabilityObserved = $initialStatus -in @("idle", "done", "blocked")
        $availabilityStatus = if ($availabilityObserved) { $initialStatus } else { $null }
        $availabilitySequence = if ($availabilityObserved) { $initialSequence } else { $null }
        if ($availabilityObserved) {
            $earlyAlertDeadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Min($AlertAfterMs, $TimeoutMs))
        }
        $fastPollingDeadline = [DateTime]::UtcNow.AddSeconds(10)
        $promptState = "absent"

        do {
            $observedResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
            $observed = $observedResponse.result.agent
            $observedSession = Get-AgentSessionId -AgentRecord $observed
            $observedSessionAgent = Get-AgentSessionAgent -AgentRecord $observed
            if ([string]$observed.pane_id -ne $TargetPaneId -or
                [string]$observed.agent -ne $TargetAgent) {
                throw "Queued prompt recovery refused because target identity changed while watching the queued prompt."
            }
            if ($useNativeSession -and
                ($observedSession -ne $TargetSession -or $observedSessionAgent -ne $TargetAgent)) {
                throw "Queued prompt recovery refused because the native session changed while watching the queued prompt."
            }
            if ($useProcessLease) {
                $observedRevision = $observed.PSObject.Properties["revision"]
                $observedTerminal = $observed.PSObject.Properties["terminal_id"]
                if ($null -eq $observedRevision -or
                    $null -eq $observedTerminal -or
                    [long]$observedRevision.Value -ne [long]$TargetProcessLease.revision -or
                    [string]$observedTerminal.Value -ne [string]$TargetProcessLease.terminal_id) {
                    throw "Queued prompt recovery refused because the Herdr agent revision or terminal changed while watching."
                }
            }

            $observedStatus = [string]$observed.agent_status
            $observedSequenceProperty = $observed.PSObject.Properties["state_change_seq"]
            $observedSequence = if ($null -ne $observedSequenceProperty) {
                [long]$observedSequenceProperty.Value
            }
            else {
                $null
            }
            if (-not $availabilityObserved -and $observedStatus -in @("idle", "done", "blocked")) {
                $availabilityObserved = $true
                $availabilityStatus = $observedStatus
                $availabilitySequence = $observedSequence
                $remainingWatchMs = [Math]::Max(0, [int]($watchDeadline - [DateTime]::UtcNow).TotalMilliseconds)
                $earlyAlertDeadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Min($AlertAfterMs, $remainingWatchMs))
            }

            $detection = Invoke-HerdrText -Arguments @(
                "agent", "read", $TargetPaneId,
                "--source", "detection",
                "--lines", "$PromptDetectionLineCount",
                "--format", "text"
            )
            $promptState = Get-TrackedPromptState -Detection $detection -TrackedToken $TrackedToken

            if ($promptState -eq "active") {
                if ($useProcessLease -and -not (Test-AgentProcessLease `
                        -TargetPaneId $TargetPaneId `
                        -TargetAgent $TargetAgent `
                        -AgentRecord $observed `
                        -ExpectedLease $TargetProcessLease)) {
                    throw "Queued prompt recovery refused because the stable agent-process lease changed before Enter."
                }
                $afterPromptState = $promptState
                $afterStatus = $observedStatus
                $afterSequence = $observedSequence
                for ($enterAttempt = 1; $enterAttempt -le 2; $enterAttempt++) {
                    if ($enterAttempt -gt 1) {
                        # A second Enter is permitted only when the first one
                        # left the exact token active in the same composer with
                        # no lifecycle proof. Idle/done must remain unchanged;
                        # an idle-to-working transition is eligible only when
                        # state_change_seq is unchanged, which covers Herdr's
                        # false-positive start signal. This is the bounded
                        # recovery for fresh prompts that need two terminal
                        # submissions; it is not a blind retry.
                        $sequenceUnchanged = $null -ne $preSendSequence -and
                            $null -ne $afterSequence -and
                            $afterSequence -eq $preSendSequence
                        $availableStateUnchanged = $afterStatus -in @("idle", "done") -and
                            $afterStatus -eq $preSendStatus
                        $falsePositiveWorkingState = $afterStatus -eq "working" -and
                            $preSendStatus -in @("idle", "done") -and
                            $sequenceUnchanged
                        if ($afterPromptState -ne "active" -or
                            (-not $availableStateUnchanged -and -not $falsePositiveWorkingState) -or
                            ((($null -ne $preSendSequence) -or ($null -ne $afterSequence)) -and
                                (($null -eq $preSendSequence) -or ($null -eq $afterSequence) -or
                                    $afterSequence -ne $preSendSequence))) {
                            throw "Enter recovery retry refused because the exact active token or available-state proof changed."
                        }
                        if ([DateTime]::UtcNow -ge $watchDeadline) {
                            throw "Enter recovery retry refused because the bounded watcher deadline expired."
                        }
                        Start-Sleep -Milliseconds 250

                        # Re-read the exact target immediately before the retry.
                        # The first verification can become stale while the
                        # user edits the composer or the agent rotates. A
                        # second Enter is never sent from an old snapshot.
                        $retryResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
                        $retryAgent = $retryResponse.result.agent
                        $retrySession = Get-AgentSessionId -AgentRecord $retryAgent
                        $retrySessionAgent = Get-AgentSessionAgent -AgentRecord $retryAgent
                        if ([string]$retryAgent.pane_id -ne $TargetPaneId -or
                            [string]$retryAgent.agent -ne $TargetAgent) {
                            throw "Enter recovery retry refused because target identity changed before the bounded retry."
                        }
                        if ($useNativeSession -and
                            ($retrySession -ne $TargetSession -or $retrySessionAgent -ne $TargetAgent)) {
                            throw "Enter recovery retry refused because the native session changed before the bounded retry."
                        }
                        if ($useProcessLease -and -not (Test-AgentProcessLease `
                                -TargetPaneId $TargetPaneId `
                                -TargetAgent $TargetAgent `
                                -AgentRecord $retryAgent `
                                -ExpectedLease $TargetProcessLease)) {
                            throw "Enter recovery retry refused because the stable agent-process lease changed before the bounded retry."
                        }

                        $retryDetection = Invoke-HerdrText -Arguments @(
                            "agent", "read", $TargetPaneId,
                            "--source", "detection",
                            "--lines", "$PromptDetectionLineCount",
                            "--format", "text"
                        )
                        $retryPromptState = Get-TrackedPromptState -Detection $retryDetection -TrackedToken $TrackedToken
                        $retryStatus = [string]$retryAgent.agent_status
                        $retrySequenceProperty = $retryAgent.PSObject.Properties["state_change_seq"]
                        $retrySequence = if ($null -ne $retrySequenceProperty) {
                            [long]$retrySequenceProperty.Value
                        }
                        else {
                            $null
                        }
                        if ($retryPromptState -ne "active" -or
                            $retryStatus -ne $afterStatus -or
                            ((($null -ne $afterSequence) -or ($null -ne $retrySequence)) -and
                                (($null -eq $afterSequence) -or ($null -eq $retrySequence) -or
                                    $retrySequence -ne $afterSequence))) {
                            throw "Enter recovery retry refused because the exact active token or available-state proof changed before the bounded retry."
                        }
                        $observedStatus = $retryStatus
                        $observedSequence = $retrySequence
                        $afterPromptState = $retryPromptState
                        $afterStatus = $retryStatus
                        $afterSequence = $retrySequence
                    }

                    $preSendStatus = $observedStatus
                    $preSendSequence = $observedSequence
                    $null = Invoke-HerdrJson -Arguments @("agent", "send-keys", $TargetPaneId, "Enter")
                    $enterSent = $true
                    $enterAttempts++

                    $recoveryDeadline = [DateTime]::UtcNow.AddSeconds(7)
                    if ($recoveryDeadline -gt $watchDeadline) {
                        $recoveryDeadline = $watchDeadline
                    }
                    do {
                        Start-Sleep -Milliseconds 200
                        $afterResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
                        $after = $afterResponse.result.agent
                        $afterSession = Get-AgentSessionId -AgentRecord $after
                        $afterSessionAgent = Get-AgentSessionAgent -AgentRecord $after
                        if ([string]$after.pane_id -ne $TargetPaneId -or
                            [string]$after.agent -ne $TargetAgent) {
                            throw "Enter was sent, but target identity changed during queued-prompt verification."
                        }
                        if ($useNativeSession -and
                            ($afterSession -ne $TargetSession -or $afterSessionAgent -ne $TargetAgent)) {
                            throw "Enter was sent, but the native session changed during verification."
                        }
                        if ($useProcessLease -and -not (Test-AgentProcessLease `
                                -TargetPaneId $TargetPaneId `
                                -TargetAgent $TargetAgent `
                                -AgentRecord $after `
                                -ExpectedLease $TargetProcessLease)) {
                            throw "Enter was sent, but the stable agent-process lease changed during verification."
                        }

                        $afterDetection = Invoke-HerdrText -Arguments @(
                            "agent", "read", $TargetPaneId,
                            "--source", "detection",
                            "--lines", "$PromptDetectionLineCount",
                            "--format", "text"
                        )
                        $afterPromptState = Get-TrackedPromptState -Detection $afterDetection -TrackedToken $TrackedToken
                        $afterStatus = [string]$after.agent_status
                        $afterSequenceProperty = $after.PSObject.Properties["state_change_seq"]
                        $afterSequence = if ($null -ne $afterSequenceProperty) {
                            [long]$afterSequenceProperty.Value
                        }
                        else {
                            $null
                        }
                        $sequenceAdvanced = $null -ne $preSendSequence -and
                            $null -ne $afterSequence -and
                            $afterSequence -gt $preSendSequence
                        $statusStarted = $preSendStatus -notin @("working", "blocked") -and
                            $afterStatus -in @("working", "blocked")
                        $queueProof = $afterPromptState -eq "history"
                        $transitionProof = $afterPromptState -ne "active" -and
                            ($sequenceAdvanced -or $statusStarted)
                        if ($queueProof -or $transitionProof) {
                            return [pscustomobject]@{
                                pane_id = $TargetPaneId
                                agent = $TargetAgent
                                token = $TrackedToken
                                submitted = $true
                                transport = "agent_prompt+queued_watch_enter"
                                delivery_state = "accepted_after_queued_enter_recovery"
                                enter_recovered = $true
                                recovery_key = "Enter"
                                recovery_attempts = $enterAttempts
                                early_alert_sent = $earlyAlertSent
                                early_alert_error = $earlyAlertError
                                status_after = $afterStatus
                                error = $null
                            }
                        }
                    } while ([DateTime]::UtcNow -lt $recoveryDeadline)

                    $sequenceUnchanged = $null -ne $preSendSequence -and
                        $null -ne $afterSequence -and
                        $afterSequence -eq $preSendSequence
                    $availableStateUnchanged = $afterStatus -in @("idle", "done") -and
                        $afterStatus -eq $preSendStatus
                    $falsePositiveWorkingState = $afterStatus -eq "working" -and
                        $preSendStatus -in @("idle", "done") -and
                        $sequenceUnchanged
                    if ($enterAttempt -lt 2 -and
                        $afterPromptState -eq "active" -and
                        ($availableStateUnchanged -or $falsePositiveWorkingState)) {
                        continue
                    }
                    throw "Enter was sent, but the exact token remained active or no queue/lifecycle proof appeared."
                }
            }

            if ($promptState -eq "history" -and $availabilityObserved) {
                $sequenceAdvancedAfterAvailability = $null -ne $availabilitySequence -and
                    $null -ne $observedSequence -and
                    $observedSequence -gt $availabilitySequence
                $activeTransitionAfterAvailability = $observedStatus -in @("working", "blocked") -and
                    $observedStatus -ne $availabilityStatus
                if ($sequenceAdvancedAfterAvailability -or $activeTransitionAfterAvailability) {
                    return [pscustomobject]@{
                        pane_id = $TargetPaneId
                        agent = $TargetAgent
                        token = $TrackedToken
                        submitted = $true
                        transport = "agent_prompt+queued_watch"
                        delivery_state = "accepted_queued_without_recovery"
                        enter_recovered = $false
                        recovery_key = $null
                        early_alert_sent = $earlyAlertSent
                        early_alert_error = $earlyAlertError
                        status_after = $observedStatus
                        error = $null
                    }
                }
            }

            if (-not $earlyAlertSent -and $null -ne $earlyAlertDeadline -and [DateTime]::UtcNow -ge $earlyAlertDeadline) {
                try {
                    $alertBody = "$TargetPaneId $TrackedToken still lacks verified submission proof (prompt state: $promptState)."
                    $null = Invoke-HerdrJson -Arguments @(
                        "notification", "show", "Cross-talk delivery stalled",
                        "--body", $alertBody,
                        "--position", "top-right",
                        "--sound", "request"
                    )
                }
                catch {
                    $earlyAlertError = $_.Exception.Message
                }
                $earlyAlertSent = $true
            }

            $pollMilliseconds = if ([DateTime]::UtcNow -lt $fastPollingDeadline) { 250 } else { 1000 }
            Start-Sleep -Milliseconds $pollMilliseconds
        } while ([DateTime]::UtcNow -lt $watchDeadline)

        if ($promptState -eq "history") {
            throw "Queued prompt recovery remained ambiguous: the token was visible only in history and no post-availability lifecycle transition proved delivery before the watcher timeout."
        }
        throw "Queued prompt recovery refused because the exact token never appeared in the active prompt before the watcher timeout."
    }
    catch {
        return [pscustomobject]@{
            pane_id = $TargetPaneId
            agent = $TargetAgent
            token = $TrackedToken
            submitted = $false
            transport = "agent_prompt+queued_watch"
            delivery_state = if ($enterSent) { "recovery_unverified" } else { "queued_recovery_failed" }
            enter_recovered = $enterSent
            recovery_key = if ($enterSent) { "Enter" } else { $null }
            recovery_attempts = $enterAttempts
            early_alert_sent = $earlyAlertSent
            early_alert_error = $earlyAlertError
            status_after = $null
            error = $_.Exception.Message
        }
    }
}

function Start-QueuedPaneWatcher {
    param(
        [Parameter(Mandatory)][string]$TargetPaneId,
        [Parameter(Mandatory)][string]$TrackedToken,
        [Parameter(Mandatory)][string]$TargetAgent,
        [string]$TargetSession,
        [object]$TargetProcessLease,
        [Parameter(Mandatory)][int]$TimeoutMs,
        [Parameter(Mandatory)][int]$AlertAfterMs,
        [Parameter(Mandatory)][string]$ResultLogPath
    )

    if ($env:HERDR_COORDINATION_WATCH_INLINE -eq "1") {
        $inlineResult = Watch-QueuedPaneMessage `
            -TargetPaneId $TargetPaneId `
            -TrackedToken $TrackedToken `
            -TargetAgent $TargetAgent `
            -TargetSession $TargetSession `
            -TargetProcessLease $TargetProcessLease `
            -TimeoutMs $TimeoutMs `
            -AlertAfterMs $AlertAfterMs
        return [pscustomobject]@{
            started = $true
            completed = $true
            process_id = $null
            result = $inlineResult
        }
    }

    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $arguments = @(
        "-NoProfile",
        "-File", "`"$PSCommandPath`"",
        "-Action", "watch-queued",
        "-PaneId", $TargetPaneId,
        "-Token", $TrackedToken,
        "-ExpectedAgent", $TargetAgent,
        "-WatchTimeoutMs", "$TimeoutMs",
        "-EarlyAlertMs", "$AlertAfterMs",
        "-WatchLogPath", "`"$ResultLogPath`""
    )
    if (-not [string]::IsNullOrWhiteSpace($TargetSession)) {
        $arguments += @("-ExpectedSession", $TargetSession)
    }
    elseif ($null -ne $TargetProcessLease) {
        $arguments += @(
            "-ExpectedRevision", "$($TargetProcessLease.revision)",
            "-ExpectedTerminalId", $TargetProcessLease.terminal_id,
            "-ExpectedShellPid", "$($TargetProcessLease.shell_pid)",
            "-ExpectedAgentPid", "$($TargetProcessLease.agent_pid)"
        )
    }
    $streamPathStem = $ResultLogPath
    if (-not [string]::IsNullOrWhiteSpace($TrackedToken)) {
        $safeToken = [regex]::Replace($TrackedToken, '[^A-Za-z0-9_-]', '')
        if (-not [string]::IsNullOrWhiteSpace($safeToken)) {
            $streamPathStem = "$ResultLogPath.$safeToken"
        }
    }
    $startParameters = @{
        FilePath = $pwsh
        ArgumentList = $arguments
        PassThru = $true
        RedirectStandardOutput = "$streamPathStem.stdout"
        RedirectStandardError = "$streamPathStem.stderr"
    }
    if ($IsWindows) {
        $startParameters['WindowStyle'] = 'Hidden'
    }
    $process = Start-Process @startParameters
    return [pscustomobject]@{
        started = $true
        completed = $false
        process_id = $process.Id
        result = $null
    }
}

function Get-PaneRouteDisplay {
    param(
        [Parameter(Mandatory)][string]$RoutePaneId,
        [object]$PaneRecord
    )

    if ($RoutePaneId -notmatch "^w[^:\s]+:p[^\s,]+$") {
        return $RoutePaneId
    }

    try {
        $resolvedPane = $PaneRecord
        if ($null -eq $resolvedPane) {
            $paneResponse = Invoke-HerdrJson -Arguments @("pane", "get", $RoutePaneId)
            $resolvedPane = $paneResponse.result.pane
        }
        if ([string]$resolvedPane.pane_id -ne $RoutePaneId) {
            return $RoutePaneId
        }

        $tabIdProperty = $resolvedPane.PSObject.Properties["tab_id"]
        if ($null -eq $tabIdProperty -or [string]::IsNullOrWhiteSpace([string]$tabIdProperty.Value)) {
            return $RoutePaneId
        }
        $tabResponse = Invoke-HerdrJson -Arguments @("tab", "get", [string]$tabIdProperty.Value)
        $tab = $tabResponse.result.tab
        $labelProperty = $tab.PSObject.Properties["label"]
        if ($null -eq $labelProperty) {
            return $RoutePaneId
        }
        $cleanLabel = ([string]$labelProperty.Value -replace "[\x00-\x1f\x7f]+", " " -replace "\s+", " ").Trim()
        if ([string]::IsNullOrWhiteSpace($cleanLabel)) {
            return $RoutePaneId
        }
        return "$RoutePaneId ($cleanLabel)"
    }
    catch {
        return $RoutePaneId
    }
}

function Assert-PaneTabLabel {
    param(
        [Parameter(Mandatory)][string]$TargetPaneId,
        [Parameter(Mandatory)][object]$PaneRecord,
        [Parameter(Mandatory)][string]$RequiredTabLabel
    )

    if ([string]$PaneRecord.pane_id -ne $TargetPaneId) {
        throw "Target label assertion resolved a different pane than $TargetPaneId."
    }
    $tabIdProperty = $PaneRecord.PSObject.Properties["tab_id"]
    if ($null -eq $tabIdProperty -or
        [string]::IsNullOrWhiteSpace([string]$tabIdProperty.Value)) {
        throw "Target pane $TargetPaneId has no resolvable tab ID for the expected label '$RequiredTabLabel'."
    }

    $tabId = [string]$tabIdProperty.Value
    $tabResponse = Invoke-HerdrJson -Arguments @("tab", "get", $tabId)
    $tab = $tabResponse.result.tab
    if ($null -eq $tab -or [string]$tab.tab_id -ne $tabId) {
        throw "Target pane $TargetPaneId tab resolution was ambiguous or changed."
    }
    $labelProperty = $tab.PSObject.Properties["label"]
    if ($null -eq $labelProperty) {
        throw "Target pane $TargetPaneId tab label could not be resolved."
    }
    $liveLabel = ([string]$labelProperty.Value -replace "[\x00-\x1f\x7f]+", " " -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($liveLabel)) {
        throw "Target pane $TargetPaneId tab label could not be resolved."
    }
    if ($liveLabel -cne $RequiredTabLabel) {
        throw "Target pane $TargetPaneId label mismatch: expected '$RequiredTabLabel', observed '$liveLabel'."
    }

    return [pscustomobject]@{
        pane_id = $TargetPaneId
        tab_id = $tabId
        tab_label = $liveLabel
    }
}

function Add-PaneLabelsToMessage {
    param([Parameter(Mandatory)][string]$Text)

    $cache = @{}
    # Protocol provenance fields are machine-readable; keep them free of the
    # human-facing label enrichment applied to ordinary pane references.
    $panePattern = "(?<!requester_pane=)(?<!\[RECIPIENT-PANE )(?<!\[APPLIED-PANE )(?<!\[APPLIED-COORDINATOR )" +
        "(?<!\[DISPOSED-PANE )(?<!\[DISPOSED-COORDINATOR )" +
        "(?<!\[APPLY-PANE )(?<!\[APPLY-COORDINATOR )\bw[0-9A-Za-z]+:p[0-9A-Za-z]+\b"
    return [regex]::Replace($Text, $panePattern, [Text.RegularExpressions.MatchEvaluator]{
            param($match)

            $after = $Text.Substring($match.Index + $match.Length)
            if ($after -match "^\s*\(") {
                return $match.Value
            }
            if (-not $cache.ContainsKey($match.Value)) {
                $cache[$match.Value] = Get-PaneRouteDisplay -RoutePaneId $match.Value
            }
            return [string]$cache[$match.Value]
        })
}

function Get-CoordinationRecipientDisplay {
    param([Parameter(Mandatory)][string]$Recipient)

    if ($Recipient -match "^w[^:\s]+:p[^\s,]+$") {
        return Get-PaneRouteDisplay -RoutePaneId $Recipient
    }
    if ($Recipient -eq "coordinator") {
        $discovery = Find-Coordinator -Label $TabLabel
        if ($discovery.found -and -not $discovery.ambiguous) {
            return Get-PaneRouteDisplay -RoutePaneId ([string]$discovery.coordinator.pane_id)
        }
    }
    return $Recipient
}

function Add-CoordinationRouteAnnotation {
    param(
        [Parameter(Mandatory)][string]$Sender,
        [Parameter(Mandatory)][string]$Recipient,
        [Parameter(Mandatory)][string]$Body
    )

    $enrichedBody = Add-PaneLabelsToMessage -Text $Body
    if ($enrichedBody -match "\[ROUTE\s+[^\]]+\]") {
        return $enrichedBody
    }
    $senderDisplay = Get-PaneRouteDisplay -RoutePaneId $Sender
    $recipientDisplay = Get-CoordinationRecipientDisplay -Recipient $Recipient
    $route = "[ROUTE $senderDisplay -> $recipientDisplay]"
    if ($enrichedBody -match "^(?<reference>\[(?:HR|HA|HN|HD|HI|HC|WF|WE):[^\]]+\])(?:\s+(?<remainder>.*))?$") {
        $remainder = [string]$Matches["remainder"]
        if ([string]::IsNullOrWhiteSpace($remainder)) {
            return "$($Matches['reference']) $route"
        }
        return "$($Matches['reference']) $route $remainder"
    }
    return "$route $enrichedBody"
}

function Resolve-PaneRegistryReference {
    param([Parameter(Mandatory)][string]$Reference)

    if ($Reference -notmatch '^@pane\[[^\]]+\]$') {
        throw "Pane registry references must have the exact form @pane[NAME]."
    }
    $registryHelper = Join-Path $PSScriptRoot "herdr_pane_registry.ps1"
    $output = & pwsh -NoProfile -File $registryHelper `
        -Action resolve -RegistryPath $PaneRegistryPath -Name $Reference 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Pane registry resolution failed for '$Reference': $($output -join [Environment]::NewLine)"
    }
    $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 32
    if (-not [bool]$result.resolved -or -not [bool]$result.binding.dispatchable) {
        throw "Pane registry reference '$Reference' is not dispatchable."
    }
    return $result.binding
}

function Assert-PaneRegistryReference {
    param([Parameter(Mandatory)]$Binding)

    $registryHelper = Join-Path $PSScriptRoot "herdr_pane_registry.ps1"
    $output = & pwsh -NoProfile -File $registryHelper `
        -Action revalidate -RegistryPath $PaneRegistryPath `
        -Name ([string]$Binding.canonical_name) `
        -ExpectedRegistryId ([string]$Binding.registry_id) `
        -ExpectedBindingId ([string]$Binding.binding_id) `
        -ExpectedGeneration ([long]$Binding.generation) 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Pane registry binding changed before transport: $($output -join [Environment]::NewLine)"
    }
    $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 32
    if (-not [bool]$result.valid) {
        throw "Pane registry binding failed final transport validation."
    }
    return $result.binding
}

function Send-VerifiedPaneMessage {
    param(
        [Parameter(Mandatory)][string]$TargetPaneId,
        [Parameter(Mandatory)][string]$Body,
        [string]$SenderPaneId = "external",
        [string]$RequiredAgent,
        [string]$RequiredSession,
        [string]$RequiredTabLabel,
        [string]$RequiredTabId
    )

    $beforeResponse = Invoke-HerdrJson -Arguments @("pane", "get", $TargetPaneId)
    $before = $beforeResponse.result.pane
    $agentProperty = $before.PSObject.Properties["agent"]
    if (-not $agentProperty -or [string]::IsNullOrWhiteSpace([string]$agentProperty.Value)) {
        throw "Target pane $TargetPaneId does not contain a detected agent."
    }
    if (-not [string]::IsNullOrWhiteSpace($RequiredAgent) -and
        [string]$agentProperty.Value -ne $RequiredAgent) {
        throw "Target pane $TargetPaneId no longer contains the expected $RequiredAgent agent."
    }
    if (-not [string]::IsNullOrWhiteSpace($RequiredTabLabel)) {
        $null = Assert-PaneTabLabel `
            -TargetPaneId $TargetPaneId `
            -PaneRecord $before `
            -RequiredTabLabel $RequiredTabLabel
    }
    if (-not [string]::IsNullOrWhiteSpace($RequiredTabId)) {
        $tabIdProperty = $before.PSObject.Properties["tab_id"]
        if ($null -eq $tabIdProperty -or [string]$tabIdProperty.Value -cne $RequiredTabId) {
            throw "Target pane $TargetPaneId no longer hosts expected tab ID $RequiredTabId."
        }
    }

    $labeledBody = Add-PaneLabelsToMessage -Text (Add-RelayContinuationInstruction -Text $Body)
    $cleanBody = ($labeledBody -replace "[\r\n]+", " ").Trim()
    if (-not $cleanBody) {
        throw "Delivery message cannot be empty."
    }

    $token = "[HC:$([Guid]::NewGuid().ToString('N').Substring(0, 8))]"
    $senderRoute = Get-PaneRouteDisplay -RoutePaneId $SenderPaneId
    $targetRoute = Get-PaneRouteDisplay -RoutePaneId $TargetPaneId -PaneRecord $before
    $payload = "$token [ROUTE $senderRoute -> $targetRoute] $cleanBody"
    $statusBefore = [string]$before.agent_status
    $sequenceBeforeProperty = $before.PSObject.Properties["state_change_seq"]
    $sequenceBefore = if ($null -ne $sequenceBeforeProperty) {
        [long]$sequenceBeforeProperty.Value
    }
    else {
        $null
    }
    $wasWorking = $statusBefore -eq "working"
    $sessionBefore = Get-AgentSessionId -AgentRecord $before
    $sessionAgentBefore = Get-AgentSessionAgent -AgentRecord $before
    $sessionProofAvailable = -not [string]::IsNullOrWhiteSpace($sessionBefore) -and
        $sessionAgentBefore -eq [string]$agentProperty.Value
    if (-not [string]::IsNullOrWhiteSpace($RequiredSession)) {
        if (-not $sessionProofAvailable) {
            throw "Target pane $TargetPaneId lacks matching native agent-session proof required for this delivery."
        }
        if ($sessionBefore -ne $RequiredSession) {
            throw "Target pane $TargetPaneId no longer hosts the expected native agent session."
        }
    }
    $processLeaseBefore = if ($sessionProofAvailable) {
        $null
    }
    else {
        Get-AgentProcessLease `
            -TargetPaneId $TargetPaneId `
            -TargetAgent ([string]$agentProperty.Value) `
            -AgentRecord $before
    }
    $promptArguments = @("agent", "prompt", $TargetPaneId, $payload)
    if (-not $wasWorking) {
        $promptArguments += @(
            "--wait",
            "--until", "working",
            "--until", "blocked",
            "--until", "idle",
            "--until", "done",
            "--timeout", "7000"
        )
    }

    $watch = $null
    $watchError = $null
    if ($env:HERDR_COORDINATION_WATCH_INLINE -ne "1" -and
        ($sessionProofAvailable -or $null -ne $processLeaseBefore)) {
        try {
            # Start the proof-bound watcher before prompt submission so it
            # remains responsible even if agent prompt blocks, falsely reports
            # success while text is still in an idle composer, or the sender exits.
            $watch = Start-QueuedPaneWatcher `
                -TargetPaneId $TargetPaneId `
                -TrackedToken $token `
                -TargetAgent ([string]$agentProperty.Value) `
                -TargetSession $(if ($sessionProofAvailable) { $sessionBefore } else { $null }) `
                -TargetProcessLease $processLeaseBefore `
                -TimeoutMs $WatchTimeoutMs `
                -AlertAfterMs $EarlyAlertMs `
                -ResultLogPath $WatchLogPath
        }
        catch {
            $watchError = $_.Exception.Message
        }
    }

    try {
        $promptResponse = Invoke-HerdrJson -Arguments $promptArguments
        if ($null -eq $promptResponse -or [string]$promptResponse.result.type -ne "agent_prompted") {
            throw "Herdr returned an unexpected response to agent prompt."
        }

        $promptedAgent = $promptResponse.result.agent
        if ([string]$promptedAgent.pane_id -ne $TargetPaneId) {
            throw "Herdr prompted a different pane than the requested target."
        }
        if (-not [string]::IsNullOrWhiteSpace($RequiredTabId) -or
            -not [string]::IsNullOrWhiteSpace($RequiredTabLabel)) {
            $afterResponse = Invoke-HerdrJson -Arguments @("pane", "get", $TargetPaneId)
            $afterPane = $afterResponse.result.pane
            if (-not [string]::IsNullOrWhiteSpace($RequiredTabId)) {
                $afterTabIdProperty = $afterPane.PSObject.Properties["tab_id"]
                if ($null -eq $afterTabIdProperty -or [string]$afterTabIdProperty.Value -cne $RequiredTabId) {
                    throw "Target pane $TargetPaneId changed tabs during delivery; expected tab ID $RequiredTabId."
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($RequiredTabLabel)) {
                $null = Assert-PaneTabLabel `
                    -TargetPaneId $TargetPaneId `
                    -PaneRecord $afterPane `
                    -RequiredTabLabel $RequiredTabLabel
            }
        }

        if (-not $watch) {
            try {
                if (-not $sessionProofAvailable -and $null -eq $processLeaseBefore) {
                    throw "Queued prompt watcher refused because the target had neither matching native session proof nor a stable agent-process lease."
                }
                $watch = Start-QueuedPaneWatcher `
                    -TargetPaneId $TargetPaneId `
                    -TrackedToken $token `
                    -TargetAgent ([string]$agentProperty.Value) `
                    -TargetSession $(if ($sessionProofAvailable) { $sessionBefore } else { $null }) `
                    -TargetProcessLease $processLeaseBefore `
                    -TimeoutMs $WatchTimeoutMs `
                    -AlertAfterMs $EarlyAlertMs `
                    -ResultLogPath $WatchLogPath
            }
            catch {
                $watchError = $_.Exception.Message
            }
        }

        $inlineWatchResult = if ($watch -and $watch.completed) { $watch.result } else { $null }
        $deliveryState = if ($inlineWatchResult) {
            [string]$inlineWatchResult.delivery_state
        }
        elseif ($watch -and $watch.started) {
            if ($wasWorking) {
                "accepted_while_working_watch_started"
            }
            else {
                "accepted_while_available_watch_started"
            }
        }
        else {
            "failed"
        }
        $submitted = if ($inlineWatchResult) {
            [bool]$inlineWatchResult.submitted
        }
        elseif ($watch -and $watch.started) {
            [bool]($watch -and $watch.started)
        }
        else {
            $false
        }

        return [pscustomobject]@{
            pane_id = $TargetPaneId
            agent = [string]$promptedAgent.agent
            token = $token
            submitted = $submitted
            queued = $wasWorking
            transport = if ($inlineWatchResult) { [string]$inlineWatchResult.transport } else { "agent_prompt" }
            delivery_state = $deliveryState
            prompt_waited = -not $wasWorking
            enter_recovered = if ($inlineWatchResult) { [bool]$inlineWatchResult.enter_recovered } else { $false }
            recovery_key = if ($inlineWatchResult) { $inlineWatchResult.recovery_key } else { $null }
            recovery_attempts = if ($inlineWatchResult -and $inlineWatchResult.PSObject.Properties["recovery_attempts"]) { [int]$inlineWatchResult.recovery_attempts } else { 0 }
            watch_started = [bool]($watch -and $watch.started)
            watch_completed = [bool]($watch -and $watch.completed)
            watch_process_id = if ($watch) { $watch.process_id } else { $null }
            early_alert_sent = if ($inlineWatchResult) { [bool]$inlineWatchResult.early_alert_sent } else { $false }
            early_alert_error = if ($inlineWatchResult) { $inlineWatchResult.early_alert_error } else { $null }
            status_before = $statusBefore
            status_after = if ($inlineWatchResult) { [string]$inlineWatchResult.status_after } else { [string]$promptedAgent.agent_status }
            error = if ($inlineWatchResult -and $inlineWatchResult.error) { [string]$inlineWatchResult.error } else { $watchError }
        }
    }
    catch {
        $promptError = $_.Exception.Message
        if ($watch -and $watch.started) {
            return [pscustomobject]@{
                pane_id = $TargetPaneId
                agent = [string]$agentProperty.Value
                token = $token
                submitted = $false
                queued = $wasWorking
                transport = "agent_prompt+prestarted_watch"
                delivery_state = "pending_watch_after_prompt_error"
                prompt_waited = -not $wasWorking
                enter_recovered = $false
                recovery_key = $null
                watch_started = $true
                watch_completed = $false
                watch_process_id = $watch.process_id
                status_before = $statusBefore
                status_after = $statusBefore
                error = $promptError
            }
        }
        if (-not $wasWorking -and $promptError -match "agent_prompt_stalled") {
            $enterSent = $false
            try {
                if (-not $sessionProofAvailable -and $null -eq $processLeaseBefore) {
                    throw "Tracked Enter recovery refused because the target had neither matching native session proof nor a stable agent-process lease."
                }

                $stalledAgentResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
                $stalledAgent = $stalledAgentResponse.result.agent
                if ([string]$stalledAgent.pane_id -ne $TargetPaneId) {
                    throw "Tracked Enter recovery refused because Herdr returned a different pane."
                }
                if ([string]$stalledAgent.agent -ne [string]$agentProperty.Value) {
                    throw "Tracked Enter recovery refused because the detected agent changed."
                }

                $sessionAfterStall = Get-AgentSessionId -AgentRecord $stalledAgent
                $sessionAgentAfterStall = Get-AgentSessionAgent -AgentRecord $stalledAgent
                if ($sessionProofAvailable -and
                    (-not $sessionAfterStall -or $sessionAfterStall -ne $sessionBefore -or
                        $sessionAgentAfterStall -ne [string]$stalledAgent.agent)) {
                    throw "Tracked Enter recovery refused because the native agent session changed or could not be proven."
                }
                if ($null -ne $processLeaseBefore -and -not (Test-AgentProcessLease `
                        -TargetPaneId $TargetPaneId `
                        -TargetAgent ([string]$agentProperty.Value) `
                        -AgentRecord $stalledAgent `
                        -ExpectedLease $processLeaseBefore)) {
                    throw "Tracked Enter recovery refused because the stable agent-process lease changed."
                }

                # agent.prompt can return its stalled receipt a fraction before
                # the composer finishes rendering. During that interval the
                # token can appear in transcript history before the final prompt
                # marker is visible. Poll briefly so that render ordering cannot
                # turn a safely recoverable delivery into a false failure.
                $trackedPromptState = "absent"
                $detection = ""
                $renderDeadline = [DateTime]::UtcNow.AddSeconds(2)
                do {
                    $detection = Invoke-HerdrText -Arguments @(
                        "agent", "read", $TargetPaneId,
                        "--source", "detection",
                        "--lines", "$PromptDetectionLineCount",
                        "--format", "text"
                    )
                    $trackedPromptState = Get-TrackedPromptState -Detection $detection -TrackedToken $token
                    if ($trackedPromptState -eq "active") {
                        break
                    }
                    Start-Sleep -Milliseconds 100
                } while ([DateTime]::UtcNow -lt $renderDeadline)

                $receiptBoundRecovery = $false
                if ($trackedPromptState -eq "active") {
                    # Preferred proof: the exact transport token is visibly active.
                }
                elseif ($trackedPromptState -eq "absent" -and
                    [string]$stalledAgent.agent_status -in @("idle", "done")) {
                    # Some agent UIs suppress the composer while background work
                    # is finishing. In that state agent.prompt can return its
                    # explicit pane-bound stalled receipt even though the pasted
                    # payload (including the HC token) is not rendered. Stable
                    # identity plus that receipt permits one bounded Enter.
                    $receiptBoundRecovery = $true
                }
                elseif ($trackedPromptState -eq "history" -and
                    [string]$stalledAgent.agent_status -in @("idle", "done")) {
                    $stalledSequenceProperty = $stalledAgent.PSObject.Properties["state_change_seq"]
                    $stalledSequence = if ($null -ne $stalledSequenceProperty) {
                        [long]$stalledSequenceProperty.Value
                    }
                    else {
                        $null
                    }
                    $sequenceUnchanged = $null -ne $sequenceBefore -and
                        $null -ne $stalledSequence -and
                        $stalledSequence -eq $sequenceBefore
                    if (-not $sequenceUnchanged) {
                        throw "Tracked Enter recovery refused because the token was in history and lifecycle sequence continuity was unavailable or changed."
                    }
                    if (-not (Test-ReceiptBoundHistoryPromptSafe -Detection $detection)) {
                        throw "Tracked Enter recovery refused because different user-authored text occupied the current prompt after the staged token."
                    }
                    # A fresh HC token can land in detection history while the TUI
                    # still owns it as suppressed composer input. A pane-bound
                    # stalled receipt, unchanged lifecycle sequence, stable identity,
                    # and an empty/known-placeholder current prompt permit one Enter.
                    $receiptBoundRecovery = $true
                }
                else {
                    throw "Tracked Enter recovery refused because the staged prompt was neither exact-token active nor eligible for receipt-bound recovery."
                }

                $null = Invoke-HerdrJson -Arguments @("agent", "send-keys", $TargetPaneId, "Enter")
                $enterSent = $true
                $null = Invoke-HerdrJson -Arguments @(
                    "agent", "wait", $TargetPaneId,
                    "--until", "working",
                    "--until", "blocked",
                    "--timeout", "7000"
                )

                $recoveredAgentResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
                $recoveredAgent = $recoveredAgentResponse.result.agent
                $sessionAfterRecovery = Get-AgentSessionId -AgentRecord $recoveredAgent
                $sessionAgentAfterRecovery = Get-AgentSessionAgent -AgentRecord $recoveredAgent
                if ([string]$recoveredAgent.pane_id -ne $TargetPaneId -or
                    [string]$recoveredAgent.agent -ne [string]$agentProperty.Value) {
                    throw "Enter was sent, but the target agent could not be revalidated afterward."
                }
                if ($sessionProofAvailable -and
                    ($sessionAfterRecovery -ne $sessionBefore -or
                        $sessionAgentAfterRecovery -ne [string]$recoveredAgent.agent)) {
                    throw "Enter was sent, but the target native session could not be revalidated afterward."
                }
                if ($null -ne $processLeaseBefore -and -not (Test-AgentProcessLease `
                        -TargetPaneId $TargetPaneId `
                        -TargetAgent ([string]$agentProperty.Value) `
                        -AgentRecord $recoveredAgent `
                        -ExpectedLease $processLeaseBefore)) {
                    throw "Enter was sent, but the stable agent-process lease could not be revalidated afterward."
                }
                if ([string]$recoveredAgent.agent_status -notin @("working", "blocked")) {
                    throw "Enter was sent, but the target did not begin processing the staged prompt."
                }

                return [pscustomobject]@{
                    pane_id = $TargetPaneId
                    agent = [string]$recoveredAgent.agent
                    token = $token
                    submitted = $true
                    queued = $false
                    transport = if ($receiptBoundRecovery) { "agent_prompt+receipt_enter" } else { "agent_prompt+tracked_enter" }
                    delivery_state = if ($receiptBoundRecovery) { "accepted_after_receipt_enter_recovery" } else { "accepted_after_enter_recovery" }
                    prompt_waited = $true
                    enter_recovered = $true
                    recovery_key = "Enter"
                    status_before = $statusBefore
                    status_after = [string]$recoveredAgent.agent_status
                    error = $null
                }
            }
            catch {
                $recoveryError = $_.Exception.Message
                return [pscustomobject]@{
                    pane_id = $TargetPaneId
                    agent = [string]$agentProperty.Value
                    token = $token
                    submitted = $false
                    queued = $false
                    transport = "agent_prompt"
                    delivery_state = if ($enterSent) { "recovery_unverified" } else { "failed" }
                    prompt_waited = $true
                    enter_recovered = $enterSent
                    recovery_key = if ($enterSent) { "Enter" } else { $null }
                    status_before = $statusBefore
                    status_after = $statusBefore
                    error = "$promptError Recovery check: $recoveryError"
                }
            }
        }

        return [pscustomobject]@{
            pane_id = $TargetPaneId
            agent = [string]$agentProperty.Value
            token = $token
            submitted = $false
            queued = $false
            transport = "agent_prompt"
            delivery_state = "failed"
            prompt_waited = -not $wasWorking
            enter_recovered = $false
            recovery_key = $null
            status_before = $statusBefore
            status_after = $statusBefore
            error = $promptError
        }
    }
}

function Rename-CurrentAgentTab {
    param(
        [Parameter(Mandatory)][string]$RequestedLabel,
        [string]$CallerSession
    )

    $workspaceId = [string]$env:HERDR_WORKSPACE_ID
    $injectedTabId = [string]$env:HERDR_TAB_ID
    $paneId = [string]$env:HERDR_PANE_ID
    if (-not $workspaceId -or -not $paneId) {
        throw "HERDR_WORKSPACE_ID and HERDR_PANE_ID are required."
    }

    $livePaneResponse = Invoke-HerdrJson -Arguments @("pane", "get", $paneId)
    $livePane = $livePaneResponse.result.pane
    if ([string]$livePane.pane_id -ne $paneId) {
        throw "Herdr returned a different pane while resolving the caller."
    }

    $liveWorkspaceId = [string]$livePane.workspace_id
    if ($liveWorkspaceId -ne $workspaceId) {
        throw "The caller's live workspace does not match HERDR_WORKSPACE_ID."
    }

    $tabId = [string]$livePane.tab_id
    if (-not $tabId) {
        throw "The caller's live pane does not report a tab ID."
    }

    $tabResponse = Invoke-HerdrJson -Arguments @("tab", "get", $tabId)
    $tab = $tabResponse.result.tab
    if ([string]$tab.workspace_id -ne $workspaceId) {
        throw "The caller's live tab does not belong to HERDR_WORKSPACE_ID."
    }
    if (([string]$tab.label).Equals("Coordination", [StringComparison]::OrdinalIgnoreCase)) {
        throw "The Coordination tab must keep its stable label."
    }

    $paneResponse = Invoke-HerdrJson -Arguments @("pane", "list", "--workspace", $workspaceId)
    $tabPanes = @($paneResponse.result.panes | Where-Object { [string]$_.tab_id -eq $tabId })
    if ($tabPanes.Count -ne 1 -or [string]$tabPanes[0].pane_id -ne $paneId) {
        throw "Automatic renaming is limited to the caller's own single-pane tab."
    }

    $agentResponse = Invoke-HerdrJson -Arguments @("agent", "get", $paneId)
    $liveAgent = $agentResponse.result.agent
    $agentKind = [string]$liveAgent.agent
    $liveSession = Get-AgentSessionId -AgentRecord $liveAgent
    $liveSessionAgent = Get-AgentSessionAgent -AgentRecord $liveAgent
    if ([string]$liveAgent.pane_id -ne $paneId -or
        [string]$liveAgent.tab_id -ne $tabId -or
        [string]::IsNullOrWhiteSpace($agentKind) -or
        [string]::IsNullOrWhiteSpace($liveSession) -or
        $liveSessionAgent -ne $agentKind) {
        throw "Tab rename refused because the caller's stable agent and native-session proof could not be established."
    }

    $effectiveCallerSession = $CallerSession
    if ([string]::IsNullOrWhiteSpace($effectiveCallerSession) -and
        -not [string]::IsNullOrWhiteSpace([string]$env:HERDR_AGENT_SESSION_ID)) {
        $effectiveCallerSession = [string]$env:HERDR_AGENT_SESSION_ID
    }
    if ([string]::IsNullOrWhiteSpace($effectiveCallerSession) -and
        $agentKind -eq "codex") {
        $effectiveCallerSession = [string]$env:CODEX_THREAD_ID
    }
    if ($agentKind -eq "codex" -and
        ([string]::IsNullOrWhiteSpace($effectiveCallerSession) -or
            $effectiveCallerSession -ne $liveSession)) {
        throw "Tab rename refused because CODEX_THREAD_ID does not match the live Codex agent session."
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveCallerSession) -and
        $effectiveCallerSession -ne $liveSession) {
        throw "Tab rename refused because the caller's native session does not match the live agent session."
    }
    if ($agentKind -ne "codex" -and
        -not [string]::IsNullOrWhiteSpace([string]$env:CODEX_THREAD_ID)) {
        throw "Tab rename refused because a Codex caller cannot rename a non-Codex agent tab."
    }

    $stableLaneKinds = @{
        "Workbook-CC" = "claude"
        "Workbook-Codex" = "codex"
        "Tooling-CC" = "claude"
        "Tooling-Codex" = "codex"
        "MCP-CC" = "claude"
        "MCP-Codex" = "codex"
    }
    $previousLabel = [string]$tab.label
    $stableLaneLabel = @($stableLaneKinds.Keys | Where-Object {
            $_.Equals($previousLabel, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
    if ($stableLaneLabel.Count -eq 1 -and
        [string]$stableLaneKinds[$stableLaneLabel[0]] -ne $agentKind) {
        throw "Stable lane '$previousLabel' does not match the live $agentKind agent."
    }

    $cleanLabel = ($RequestedLabel -replace "[\x00-\x1f\x7f]+", " " -replace "\s+", " ").Trim()
    if (-not $cleanLabel) {
        throw "Tab label cannot be empty."
    }
    if ($cleanLabel.Length -gt 32) {
        $cleanLabel = $cleanLabel.Substring(0, 32).TrimEnd()
    }

    $nameProperty = $liveAgent.PSObject.Properties["name"]
    $previousAgentName = if ($null -ne $nameProperty) { [string]$nameProperty.Value } else { $null }
    $agentNameCleared = $false
    if (-not [string]::IsNullOrWhiteSpace($previousAgentName)) {
        $null = Invoke-HerdrJson -Arguments @("agent", "rename", $paneId, "--clear")
        $agentNameCleared = $true
    }

    $verifiedAgentResponse = Invoke-HerdrJson -Arguments @("agent", "get", $paneId)
    $verifiedAgent = $verifiedAgentResponse.result.agent
    $verifiedSession = Get-AgentSessionId -AgentRecord $verifiedAgent
    $verifiedSessionAgent = Get-AgentSessionAgent -AgentRecord $verifiedAgent
    $verifiedNameProperty = $verifiedAgent.PSObject.Properties["name"]
    $verifiedName = if ($null -ne $verifiedNameProperty) { [string]$verifiedNameProperty.Value } else { $null }
    if ([string]$verifiedAgent.pane_id -ne $paneId -or
        [string]$verifiedAgent.tab_id -ne $tabId -or
        [string]$verifiedAgent.agent -ne $agentKind -or
        $verifiedSession -ne $liveSession -or
        $verifiedSessionAgent -ne $agentKind -or
        -not [string]::IsNullOrWhiteSpace($verifiedName)) {
        throw "Tab rename refused because agent identity changed or a custom task alias remained in the Agents list."
    }

    if ($stableLaneLabel.Count -eq 1) {
        return [pscustomobject]@{
            workspace_id = $workspaceId
            tab_id = $tabId
            injected_tab_id = $injectedTabId
            pane_id = $paneId
            previous_label = $previousLabel
            label = $previousLabel
            requested_label = $cleanLabel
            agent_kind = $agentKind
            previous_agent_name = $previousAgentName
            agent_name_cleared = $agentNameCleared
            renamed = $false
            stable_lane_preserved = $true
        }
    }

    $null = Invoke-HerdrText -Arguments @("tab", "rename", $tabId, $cleanLabel)
    $afterResponse = Invoke-HerdrJson -Arguments @("tab", "get", $tabId)
    $actualLabel = [string]$afterResponse.result.tab.label
    if ($actualLabel -ne $cleanLabel) {
        throw "Tab rename verification failed: expected '$cleanLabel', observed '$actualLabel'."
    }

    return [pscustomobject]@{
        workspace_id = $workspaceId
        tab_id = $tabId
        injected_tab_id = $injectedTabId
        pane_id = $paneId
        previous_label = $previousLabel
        label = $actualLabel
        agent_kind = $agentKind
        previous_agent_name = $previousAgentName
        agent_name_cleared = $agentNameCleared
        renamed = $true
        stable_lane_preserved = $false
    }
}

function Find-Coordinator {
    param([Parameter(Mandatory)][string]$Label)

    $workspaceResponse = Invoke-HerdrJson -Arguments @("workspace", "list")
    $matches = @()

    foreach ($workspace in @($workspaceResponse.result.workspaces)) {
        $workspaceId = [string]$workspace.workspace_id
        $tabResponse = Invoke-HerdrJson -Arguments @("tab", "list", "--workspace", $workspaceId)
        $paneResponse = $null

        foreach ($tab in @($tabResponse.result.tabs)) {
            if (-not ([string]$tab.label).Equals($Label, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            if ($null -eq $paneResponse) {
                $paneResponse = Invoke-HerdrJson -Arguments @("pane", "list", "--workspace", $workspaceId)
            }

            $tabId = [string]$tab.tab_id
            $panes = @($paneResponse.result.panes | Where-Object { [string]$_.tab_id -eq $tabId })
            $matches += [pscustomobject]@{
                workspace_id = $workspaceId
                workspace_label = [string]$workspace.label
                tab_id = $tabId
                tab_label = [string]$tab.label
                panes = $panes
            }
        }
    }

    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            found = $false
            ambiguous = $false
            coordinator = $null
            candidates = @()
        }
    }

    $usable = @()
    foreach ($match in $matches) {
        foreach ($pane in @($match.panes)) {
            $agentProperty = $pane.PSObject.Properties["agent"]
            $statusProperty = $pane.PSObject.Properties["agent_status"]
            $cwdProperty = $pane.PSObject.Properties["cwd"]
            $agent = if ($agentProperty) { [string]$agentProperty.Value } else { "" }
            if ($agent -eq "codex") {
                $usable += [pscustomobject]@{
                    workspace_id = $match.workspace_id
                    workspace_label = $match.workspace_label
                    tab_id = $match.tab_id
                    tab_label = $match.tab_label
                    pane_id = [string]$pane.pane_id
                    agent = $agent
                    agent_status = if ($statusProperty) { [string]$statusProperty.Value } else { "unknown" }
                    cwd = if ($cwdProperty) { [string]$cwdProperty.Value } else { "" }
                }
            }
        }
    }

    if ($matches.Count -eq 1 -and $usable.Count -eq 1 -and @($matches[0].panes).Count -eq 1) {
        return [pscustomobject]@{
            found = $true
            ambiguous = $false
            coordinator = $usable[0]
            candidates = $usable
        }
    }

    return [pscustomobject]@{
        found = $true
        ambiguous = $true
        coordinator = $null
        candidates = $usable
    }
}

function Initialize-CoordinationLog {
    param([Parameter(Mandatory)][string]$Path)

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path) {
        return
    }

    $header = @(
        "# Herdr Coordination Log"
        ""
        "Shared, append-only coordination log for live Herdr sessions."
        ""
        "## Messages"
        ""
    ) -join [Environment]::NewLine

    try {
        $utf8 = [Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText($Path, $header, $utf8)
    }
    catch [IO.IOException] {
        if (-not (Test-Path -LiteralPath $Path)) {
            throw
        }
    }
}

function Add-CoordinationEntry {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sender,
        [Parameter(Mandatory)][string]$Recipient,
        [Parameter(Mandatory)][string]$Body
    )

    $entryMutex = Enter-CoordinationAckMutex -Path $Path
    try {
        Initialize-CoordinationLog -Path $Path
        $routedBody = Add-CoordinationRouteAnnotation `
            -Sender $Sender `
            -Recipient $Recipient `
            -Body $Body
        $cleanBody = ($routedBody -replace "[\r\n]+", " ").Trim()
        if (-not $cleanBody) {
            throw "Message cannot be empty."
        }

        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm zzz"
        $line = "- [$stamp] FROM $Sender TO $Recipient`: $cleanBody"
        $utf8 = [Text.UTF8Encoding]::new($false)

        for ($attempt = 1; $attempt -le 10; $attempt++) {
            try {
                $stream = [IO.File]::Open($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
                try {
                    $writer = [IO.StreamWriter]::new($stream, $utf8)
                    try {
                        $writer.WriteLine($line)
                        $writer.Flush()
                    }
                    finally {
                        $writer.Dispose()
                    }
                }
                finally {
                    if ($stream) {
                        $stream.Dispose()
                    }
                }
                return $line
            }
            catch [IO.IOException] {
                if ($attempt -eq 10) {
                    throw
                }
                Start-Sleep -Milliseconds (40 * $attempt)
            }
        }
    }
    finally {
        Exit-CoordinationAckMutex -Mutex $entryMutex
    }
}

function Assert-RelayReference {
    param([Parameter(Mandatory)][string]$Reference)

    if ($Reference -notmatch '^\[HR:[0-9a-fA-F]{8}\]$') {
        throw "Relay reference must have the exact form [HR:xxxxxxxx]."
    }
}

function Get-CoordinationTextSha256 {
    param([AllowEmptyString()][string]$Text)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function ConvertTo-CoordinationMetadataBase64 {
    param([AllowEmptyString()][string]$Text)

    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Text))
}

function ConvertFrom-CoordinationMetadataBase64 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

function Enter-CoordinationAckMutex {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path).ToLowerInvariant()
    $nameHash = Get-CoordinationTextSha256 -Text $fullPath
    $mutex = [Threading.Mutex]::new($false, "HerdrCoordAck_$nameHash")
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(30000)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Timed out waiting for the coordination read-ACK lock for $Path."
        }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-CoordinationAckMutex {
    param([Threading.Mutex]$Mutex)

    if ($null -eq $Mutex) {
        return
    }
    try {
        $Mutex.ReleaseMutex()
    }
    finally {
        $Mutex.Dispose()
    }
}

function Get-NormalizedRelayBody {
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Reference
    )

    $escapedReference = [regex]::Escape($Reference)
    $normalized = $Body -replace '^\[ROUTE\s+[^\]]+\]\s+', ''
    return $normalized -replace "^($escapedReference)\s+\[ROUTE\s+[^\]]+\]\s+", '$1 '
}

function Get-CoordinationLogRecords {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $recordPattern = '^- \[(?<stamp>[^\]]+)\] FROM (?<from>\S+) TO (?<to>coordinator|ALL|w[0-9A-Za-z]+:p[0-9A-Za-z]+): (?<body>.*)$'
    $records = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ($line -match $recordPattern) {
            $records.Add([pscustomobject]@{
                line = [string]$line
                stamp = [string]$Matches['stamp']
                from = [string]$Matches['from']
                to = [string]$Matches['to']
                body = [string]$Matches['body']
            })
        }
    }
    return @($records)
}

function ConvertFrom-CoordinationStamp {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Stamp)

    $parsed = [DateTimeOffset]::MinValue
    # The [string[]] cast is required: an untyped array binds the single-format
    # overload instead and silently fails to parse every stamp.
    [string[]]$formats = @("yyyy-MM-dd HH:mm zzz", "yyyy-MM-dd HH:mm:ss zzz")
    if ([DateTimeOffset]::TryParseExact(
            $Stamp,
            $formats,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-RelayRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reference,
        [object[]]$Records
    )

    Assert-RelayReference -Reference $Reference
    $escapedReference = [regex]::Escape($Reference)
    $legacyRoutePrefixPattern = '^\[ROUTE\s+[^\]]+\]\s+'
    $candidateRecords = if ($null -ne $Records) { @($Records) } else { @(Get-CoordinationLogRecords -Path $Path) }
    $matches = @(
        $candidateRecords |
            Where-Object {
                $candidateBody = [string]$_.body
                $candidateBody -match "^$escapedReference(?:\s|$)" -or
                    $candidateBody -match "$legacyRoutePrefixPattern$escapedReference(?:\s|$)"
            }
    )
    if ($matches.Count -eq 0) {
        throw "Relay $Reference was not found as the own reference of a coordination-log entry."
    }
    if ($matches.Count -ne 1) {
        throw "Relay $Reference is ambiguous because it appears as the own reference of $($matches.Count) coordination-log entries."
    }

    return ConvertTo-RelayRecord -Record $matches[0] -Reference $Reference
}

function ConvertTo-RelayRecord {
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$Reference
    )

    Assert-RelayReference -Reference $Reference
    $escapedReference = [regex]::Escape($Reference)
    $record = $Record
    $normalizedBody = Get-NormalizedRelayBody `
        -Body ([string]$record.body) `
        -Reference $Reference
    $recipientPane = $null
    $recipientSession = $null
    $recipientAgent = $null
    $recipientTabId = $null
    $recipientTabLabel = $null
    $payloadSha256 = $null
    $payload = $null
    $reissueOf = $null
    $metadataComplete = $false
    $payloadHashValid = $false
    $metadataPattern = "^$escapedReference\s+" +
        '\[RECIPIENT-PANE (?<pane>w[0-9A-Za-z]+:p[0-9A-Za-z]+)\]\s+' +
        '\[RECIPIENT-SESSION (?<session>[^\]\s]+)\]\s+' +
        '\[RECIPIENT-AGENT (?<agent>[A-Za-z0-9_-]+)\]\s+' +
        '\[RECIPIENT-TAB (?<tab>w[0-9A-Za-z]+:t[0-9A-Za-z]+)\]\s+' +
        '\[RECIPIENT-LABEL-B64 (?<label>[A-Za-z0-9+/=]+)\]\s+' +
        '\[PAYLOAD-SHA256 (?<hash>[0-9a-fA-F]{64})\]' +
        '(?:\s+\[REISSUE-OF (?<parent>\[HR:[0-9a-fA-F]{8}\])\])?' +
        '(?:\s+(?<payload>.*))?$'
    if ($normalizedBody -match $metadataPattern) {
        $recipientPane = [string]$Matches['pane']
        $recipientSession = [string]$Matches['session']
        $recipientAgent = [string]$Matches['agent']
        $recipientTabId = [string]$Matches['tab']
        $recipientTabLabel = ConvertFrom-CoordinationMetadataBase64 -Text ([string]$Matches['label'])
        $payloadSha256 = ([string]$Matches['hash']).ToLowerInvariant()
        $payload = [string]$Matches['payload']
        $reissueOf = [string]$Matches['parent']
        $metadataComplete = -not [string]::IsNullOrWhiteSpace($recipientTabLabel)
        $payloadHashValid = (Get-CoordinationTextSha256 -Text $payload) -eq $payloadSha256
    }
    elseif ($normalizedBody -match "^$escapedReference\s+\[RECIPIENT-PANE (?<pane>w[0-9A-Za-z]+:p[0-9A-Za-z]+)\](?:\s|$)") {
        $recipientPane = [string]$Matches['pane']
    }
    elseif ([string]$record.body -match '\[ROUTE\s+.+?\s+->\s+(?<pane>w[0-9A-Za-z]+:p[0-9A-Za-z]+)(?:\s+\([^\]]*\))?\]') {
        # Compatibility for relays created before RECIPIENT-PANE metadata.
        $recipientPane = [string]$Matches['pane']
    }
    if ([string]$record.body -match '\[RECIPIENT-SESSION (?<session>[^\]\s]+)\]') {
        $recipientSession = [string]$Matches['session']
    }

    return [pscustomobject]@{
        relay_ref = $Reference
        sender = [string]$record.from
        recipient = [string]$record.to
        recipient_pane_id = $recipientPane
        recipient_session = $recipientSession
        recipient_agent = $recipientAgent
        recipient_tab_id = $recipientTabId
        recipient_tab_label = $recipientTabLabel
        payload_sha256 = $payloadSha256
        payload = $payload
        payload_hash_valid = $payloadHashValid
        metadata_complete = $metadataComplete
        reissue_of = $reissueOf
        entry = [string]$record.line
        body = [string]$record.body
        stamp = if ($record.PSObject.Properties["stamp"]) { [string]$record.stamp } else { $null }
    }
}

function Get-RelaySuccessors {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reference
    )

    Assert-RelayReference -Reference $Reference
    $escapedParent = [regex]::Escape($Reference)
    $successorPattern = '^(?<reference>\[HR:[0-9a-fA-F]{8}\])\s+' +
        '\[RECIPIENT-PANE w[0-9A-Za-z]+:p[0-9A-Za-z]+\]\s+' +
        '\[RECIPIENT-SESSION [^\]\s]+\]\s+' +
        '\[RECIPIENT-AGENT [A-Za-z0-9_-]+\]\s+' +
        '\[RECIPIENT-TAB w[0-9A-Za-z]+:t[0-9A-Za-z]+\]\s+' +
        '\[RECIPIENT-LABEL-B64 [A-Za-z0-9+/=]+\]\s+' +
        '\[PAYLOAD-SHA256 [0-9a-fA-F]{64}\]\s+' +
        "\[REISSUE-OF $escapedParent\](?:\s|$)"
    $records = @(Get-CoordinationLogRecords -Path $Path)
    $successors = [Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        $candidateBody = [string]$record.body -replace '^\[ROUTE\s+[^\]]+\]\s+', ''
        $candidateBody = $candidateBody -replace '^(?<reference>\[HR:[0-9a-fA-F]{8}\])\s+\[ROUTE\s+[^\]]+\]\s+', '${reference} '
        if ($candidateBody -notmatch $successorPattern) {
            continue
        }
        $candidateReference = [string]$Matches['reference']
        $successors.Add((Get-RelayRecord -Path $Path -Reference $candidateReference -Records $records))
    }
    return @($successors)
}

function Assert-RelaySuccessorContinuity {
    param(
        [Parameter(Mandatory)][object]$Parent,
        [Parameter(Mandatory)][object]$Successor
    )

    if ([string]$Successor.reissue_of -ne [string]$Parent.relay_ref -or
        [string]$Successor.sender -ne [string]$Parent.sender -or
        [string]$Successor.recipient -ne [string]$Parent.recipient -or
        [string]$Successor.recipient_pane_id -ne [string]$Parent.recipient_pane_id -or
        [string]$Successor.recipient_agent -ne [string]$Parent.recipient_agent -or
        [string]$Successor.recipient_tab_id -ne [string]$Parent.recipient_tab_id -or
        [string]$Successor.recipient_tab_label -cne [string]$Parent.recipient_tab_label -or
        [string]$Successor.payload_sha256 -ne [string]$Parent.payload_sha256 -or
        [string]$Successor.payload -cne [string]$Parent.payload -or
        -not [bool]$Successor.metadata_complete -or
        -not [bool]$Successor.payload_hash_valid) {
        throw "Relay $($Successor.relay_ref) is not an exact, provenance-preserving successor of $($Parent.relay_ref)."
    }
}

function Get-RelayLineage {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Relay
    )

    $lineage = @()
    $effectiveRelay = $Relay
    $seen = @{}
    for ($depth = 0; $depth -lt 32; $depth++) {
        if ($seen.ContainsKey([string]$effectiveRelay.relay_ref)) {
            throw "Relay replacement lineage contains a cycle at $($effectiveRelay.relay_ref)."
        }
        $seen[[string]$effectiveRelay.relay_ref] = $true
        $successors = @(Get-RelaySuccessors -Path $Path -Reference ([string]$effectiveRelay.relay_ref))
        if ($successors.Count -eq 0) {
            return [pscustomobject]@{
                effective_relay = $effectiveRelay
                replacements = $lineage
            }
        }
        if ($successors.Count -ne 1) {
            throw "Relay $($effectiveRelay.relay_ref) has $($successors.Count) replacement successors and requires reconciliation."
        }
        $successor = $successors[0]
        Assert-RelaySuccessorContinuity -Parent $effectiveRelay -Successor $successor
        $lineage += $successor
        $effectiveRelay = $successor
    }
    throw "Relay replacement lineage exceeded the maximum safe depth."
}

function New-SessionRotatedRelay {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Relay,
        [Parameter(Mandatory)][object]$Reader
    )

    if (-not [bool]$Relay.metadata_complete -or -not [bool]$Relay.payload_hash_valid) {
        throw "Relay $($Relay.relay_ref) predates rotation-safe metadata or has an invalid payload hash; automatic session rotation is refused."
    }
    if ([string]$Reader.pane_id -ne [string]$Relay.recipient_pane_id -or
        [string]$Reader.agent -ne [string]$Relay.recipient_agent) {
        throw "Relay $($Relay.relay_ref) recipient pane or agent changed; automatic session rotation is refused."
    }

    $paneResponse = Invoke-HerdrJson -Arguments @("pane", "get", [string]$Reader.pane_id)
    $pane = $paneResponse.result.pane
    $labelProof = Assert-PaneTabLabel `
        -TargetPaneId ([string]$Reader.pane_id) `
        -PaneRecord $pane `
        -RequiredTabLabel ([string]$Relay.recipient_tab_label)
    if ([string]$labelProof.tab_id -ne [string]$Relay.recipient_tab_id) {
        throw "Relay $($Relay.relay_ref) recipient tab changed; automatic session rotation is refused."
    }
    if ([string]$Reader.session -eq [string]$Relay.recipient_session) {
        return $Relay
    }

    $relayRef = "[HR:$([Guid]::NewGuid().ToString('N').Substring(0, 8))]"
    $labelBase64 = ConvertTo-CoordinationMetadataBase64 -Text ([string]$Relay.recipient_tab_label)
    $body = "$relayRef [RECIPIENT-PANE $($Relay.recipient_pane_id)] " +
        "[RECIPIENT-SESSION $($Reader.session)] " +
        "[RECIPIENT-AGENT $($Relay.recipient_agent)] " +
        "[RECIPIENT-TAB $($Relay.recipient_tab_id)] " +
        "[RECIPIENT-LABEL-B64 $labelBase64] " +
        "[PAYLOAD-SHA256 $($Relay.payload_sha256)] " +
        "[REISSUE-OF $($Relay.relay_ref)] $($Relay.payload)"
    $null = Add-CoordinationEntry `
        -Path $Path `
        -Sender ([string]$Relay.sender) `
        -Recipient ([string]$Relay.recipient) `
        -Body $body
    $replacement = Get-RelayRecord -Path $Path -Reference $relayRef
    Assert-RelaySuccessorContinuity -Parent $Relay -Successor $replacement
    return $replacement
}

function Get-RelayReadAcks {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reference,
        [object[]]$Records
    )

    Assert-RelayReference -Reference $Reference
    $escapedReference = [regex]::Escape($Reference)
    $ackPattern = "^\[HA:(?<ack>[0-9a-fA-F]{8})\](?:\s+\[ROUTE[^\]]+\])?\s+\[READ-ACK re $escapedReference\]\s+body read; reader_agent=(?<agent>[A-Za-z0-9_-]+); reader_session=(?<session>[^;\s]+)$"
    $acks = @()
    $candidateRecords = if ($null -ne $Records) { @($Records) } else { @(Get-CoordinationLogRecords -Path $Path) }
    foreach ($record in $candidateRecords) {
        if ([string]$record.body -match $ackPattern) {
            $acks += [pscustomobject]@{
                ack_ref = "[HA:$($Matches['ack'])]"
                relay_ref = $Reference
                reader_pane_id = [string]$record.from
                returned_to = [string]$record.to
                reader_agent = [string]$Matches['agent']
                reader_session = [string]$Matches['session']
                entry = [string]$record.line
                stamp = if ($record.PSObject.Properties["stamp"]) { [string]$record.stamp } else { $null }
            }
        }
    }
    return $acks
}

function Get-ValidRelayReadAcks {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Relay,
        [object[]]$Records
    )

    $acks = @(Get-RelayReadAcks -Path $Path -Reference ([string]$Relay.relay_ref) -Records $Records)
    return @(
        $acks | Where-Object {
            Test-RelayReadAck -Relay $Relay -Ack $_
        }
    )
}

function Test-RelayReadAck {
    param(
        [Parameter(Mandatory)][object]$Relay,
        [Parameter(Mandatory)][object]$Ack
    )

    return (
        -not [string]::IsNullOrWhiteSpace([string]$Relay.recipient_pane_id) -and
        [string]$Ack.reader_pane_id -eq [string]$Relay.recipient_pane_id -and
        [string]$Ack.returned_to -eq [string]$Relay.sender -and
        ([string]::IsNullOrWhiteSpace([string]$Relay.recipient_session) -or
            [string]$Ack.reader_session -eq [string]$Relay.recipient_session) -and
        ([string]::IsNullOrWhiteSpace([string]$Relay.recipient_agent) -or
            [string]$Ack.reader_agent -eq [string]$Relay.recipient_agent)
    )
}

function Assert-RelayReadIntegrity {
    param(
        [Parameter(Mandatory)][object]$Relay,
        [Parameter(Mandatory)][object]$Reader
    )

    $hasTrackedHash = -not [string]::IsNullOrWhiteSpace([string]$Relay.payload_sha256)
    if ($hasTrackedHash -and
        (-not [bool]$Relay.metadata_complete -or -not [bool]$Relay.payload_hash_valid)) {
        throw "Relay $($Relay.relay_ref) has incomplete rotation-safe metadata or an invalid payload hash."
    }
    if (-not [bool]$Relay.metadata_complete) {
        # Legacy relays remain same-session acknowledgement compatible, but
        # never gain session-rotation privileges.
        return
    }
    if (-not [bool]$Relay.payload_hash_valid) {
        throw "Relay $($Relay.relay_ref) payload hash is invalid."
    }
    if ([string]$Reader.tab_id -ne [string]$Relay.recipient_tab_id) {
        throw "Relay $($Relay.relay_ref) recipient tab changed; read acknowledgement is refused."
    }
    $paneResponse = Invoke-HerdrJson -Arguments @("pane", "get", [string]$Reader.pane_id)
    $labelProof = Assert-PaneTabLabel `
        -TargetPaneId ([string]$Reader.pane_id) `
        -PaneRecord $paneResponse.result.pane `
        -RequiredTabLabel ([string]$Relay.recipient_tab_label)
    if ([string]$labelProof.tab_id -ne [string]$Relay.recipient_tab_id) {
        throw "Relay $($Relay.relay_ref) recipient tab changed; read acknowledgement is refused."
    }
}

function Get-CurrentRelayReaderProof {
    param(
        [Parameter(Mandatory)][string]$TargetPaneId,
        [string]$CallerSession,
        [switch]$AllowSessionRotation
    )

    $workspaceId = [string]$env:HERDR_WORKSPACE_ID
    $tabId = [string]$env:HERDR_TAB_ID
    $paneId = [string]$env:HERDR_PANE_ID
    if ([string]::IsNullOrWhiteSpace($workspaceId) -or
        [string]::IsNullOrWhiteSpace($tabId) -or
        [string]::IsNullOrWhiteSpace($paneId)) {
        throw "Relay read acknowledgement requires injected HERDR_WORKSPACE_ID, HERDR_TAB_ID, and HERDR_PANE_ID."
    }
    if ($paneId -ne $TargetPaneId) {
        throw "Relay read acknowledgement belongs to $TargetPaneId, not caller pane $paneId."
    }

    $paneResponse = Invoke-HerdrJson -Arguments @("pane", "get", $paneId)
    $pane = $paneResponse.result.pane
    if ([string]$pane.pane_id -ne $paneId -or
        [string]$pane.workspace_id -ne $workspaceId -or
        [string]$pane.tab_id -ne $tabId) {
        throw "Relay read acknowledgement refused because the caller's injected pane identity no longer matches live Herdr state."
    }

    $agentResponse = Invoke-HerdrJson -Arguments @("agent", "get", $paneId)
    $agent = $agentResponse.result.agent
    $agentKind = [string]$agent.agent
    $sessionId = Get-AgentSessionId -AgentRecord $agent
    $sessionAgent = Get-AgentSessionAgent -AgentRecord $agent
    if ([string]$agent.pane_id -ne $paneId -or
        [string]$agent.workspace_id -ne $workspaceId -or
        [string]$agent.tab_id -ne $tabId -or
        [string]::IsNullOrWhiteSpace($agentKind) -or
        [string]::IsNullOrWhiteSpace($sessionId) -or
        $sessionAgent -ne $agentKind) {
        throw "Relay read acknowledgement refused because stable native agent-session proof is unavailable."
    }

    $effectiveCallerSession = $CallerSession
    if ([string]::IsNullOrWhiteSpace($effectiveCallerSession) -and
        -not [string]::IsNullOrWhiteSpace([string]$env:HERDR_AGENT_SESSION_ID)) {
        $effectiveCallerSession = [string]$env:HERDR_AGENT_SESSION_ID
    }
    if ([string]::IsNullOrWhiteSpace($effectiveCallerSession) -and $agentKind -eq "codex") {
        $effectiveCallerSession = [string]$env:CODEX_THREAD_ID
    }
    $sessionHintMatches = -not [string]::IsNullOrWhiteSpace($effectiveCallerSession) -and
        $effectiveCallerSession -eq $sessionId
    $callerProcessLease = Get-AgentProcessLease `
        -TargetPaneId $paneId `
        -TargetAgent $agentKind `
        -AgentRecord $agent
    $callerProcessBound = $null -ne $callerProcessLease -and
        (Test-CurrentProcessDescendsFrom -AncestorProcessId ([int]$callerProcessLease.agent_pid))
    if (-not $callerProcessBound) {
        throw "Relay read acknowledgement refused because the caller is not process-bound to the live pane agent."
    }
    if (-not $sessionHintMatches -and -not $AllowSessionRotation) {
        throw "Relay read acknowledgement refused because the caller's native session does not match the live agent session."
    }
    if ($agentKind -ne "codex" -and
        -not [string]::IsNullOrWhiteSpace([string]$env:CODEX_THREAD_ID)) {
        throw "Relay read acknowledgement refused because a Codex caller cannot acknowledge for a non-Codex agent."
    }

    return [pscustomobject]@{
        workspace_id = $workspaceId
        tab_id = $tabId
        pane_id = $paneId
        agent = $agentKind
        session = $sessionId
        caller_session_hint = $effectiveCallerSession
        session_hint_matches = $sessionHintMatches
        session_rotated = -not $sessionHintMatches
        caller_process_bound = $callerProcessBound
        caller_process_lease = $callerProcessLease
    }
}

# --- Coordinator-owned pane naming lifecycle -------------------------------
# A PANE NAMING REQUEST is only complete when Coordination has (a) read-ACKed
# the relay body and (b) appended an [HN:...] APPLIED proof bound to the same
# relay, the exact target pane, and the coordinator's own pane. A read-ACK
# alone is silence, which is the failure mode this lifecycle exists to remove.

# The subtitle separator is U+00B7 MIDDLE DOT; build it from its code point so
# the canonical form never depends on how this file is decoded.
$NamingSubtitleSeparator = [string][char]0x00B7
$NamingRequestMarker = "PANE NAMING REQUEST: "
$NamingRequestRelayPattern = '^(?:\[ROUTE\s+[^\]]+\]\s+)?(?<relay>\[HR:[0-9a-fA-F]{8}\])(?:\s|$)'
$NamingAppliedBodyPattern =
    '^\[HN:(?<proof>[0-9a-fA-F]{8})\](?:\s+\[ROUTE[^\]]+\])?' +
    '\s+\[APPLIED re (?<relay>\[HR:[0-9a-fA-F]{8}\])\]' +
    '\s+\[APPLIED-PANE (?<pane>w[0-9A-Za-z]+:p[0-9A-Za-z]+)\]' +
    '\s+\[APPLIED-TAB (?<tab>w[0-9A-Za-z]+:t[0-9A-Za-z]+)\]' +
    '\s+\[APPLIED-COORDINATOR (?<coordinator>w[0-9A-Za-z]+:p[0-9A-Za-z]+)\]' +
    '\s+applied; canonical_name=(?<name>[^;\s]+); subtitle_b64=(?<subtitle>[A-Za-z0-9+/=]*);' +
    '(?: pane_label=(?<panelabel>[^;\s]+);)?' +
    ' coordinator_session=(?<coordsession>[^;\s]+); target_session=(?<targetsession>[^;\s]+)$'
$NamingDispositionBodyPattern =
    '^\[HD:(?<proof>[0-9a-fA-F]{8})\](?:\s+\[ROUTE[^\]]+\])?' +
    '\s+\[DISPOSED re (?<relay>\[HR:[0-9a-fA-F]{8}\])\]' +
    '\s+\[DISPOSITION (?<disposition>[a-z0-9_]+)\]' +
    '\s+\[DISPOSED-PANE (?<pane>w[0-9A-Za-z]+:p[0-9A-Za-z]+)\]' +
    '\s+\[DISPOSED-COORDINATOR (?<coordinator>w[0-9A-Za-z]+:p[0-9A-Za-z]+)\]' +
    '\s+disposed; coordinator_session=(?<coordsession>[^;\s]+); requester_session=(?<requestersession>[^;\s]+); absence=(?<absence>[a-z0-9_]+)$'
$NamingApplyIntentBodyPattern =
    '^\[HI:(?<proof>[0-9a-fA-F]{8})\](?:\s+\[ROUTE[^\]]+\])?' +
    '\s+\[APPLY-STARTED re (?<relay>\[HR:[0-9a-fA-F]{8}\])\]' +
    '\s+\[APPLY-PANE (?<pane>w[0-9A-Za-z]+:p[0-9A-Za-z]+)\]' +
    '\s+\[APPLY-TAB (?<tab>w[0-9A-Za-z]+:t[0-9A-Za-z]+)\]' +
    '\s+\[APPLY-COORDINATOR (?<coordinator>w[0-9A-Za-z]+:p[0-9A-Za-z]+)\]' +
    '\s+started; coordinator_session=(?<coordsession>[^;\s]+); target_session=(?<targetsession>[^;\s]+)$'

function Assert-NamingAppliedReference {
    param([Parameter(Mandatory)][string]$Reference)

    if ($Reference -notmatch '^\[HN:[0-9a-fA-F]{8}\]$') {
        throw "Naming applied reference must have the exact form [HN:xxxxxxxx]."
    }
}

function ConvertTo-NamingAppliedProof {
    param([Parameter(Mandatory)][object]$Record)

    if ([string]$Record.body -notmatch $NamingAppliedBodyPattern) {
        return $null
    }
    try {
        $subtitle = ConvertFrom-CoordinationMetadataBase64 -Text ([string]$Matches['subtitle'])
    }
    catch {
        return $null
    }
    return [pscustomobject]@{
        proof_ref = "[HN:$($Matches['proof'])]"
        relay_ref = [string]$Matches['relay']
        target_pane_id = [string]$Matches['pane']
        target_tab_id = [string]$Matches['tab']
        coordinator_pane_id = [string]$Matches['coordinator']
        canonical_name = [string]$Matches['name']
        pane_label = if ($Matches['panelabel']) { [string]$Matches['panelabel'] } else { [string]$Matches['name'] }
        subtitle = $subtitle
        coordinator_session = [string]$Matches['coordsession']
        target_session = [string]$Matches['targetsession']
        writer_pane_id = [string]$Record.from
        returned_to = [string]$Record.to
        entry = [string]$Record.line
        stamp = if ($Record.PSObject.Properties["stamp"]) { [string]$Record.stamp } else { $null }
    }
}

function Get-NamingAppliedProofs {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reference,
        [object[]]$Records
    )

    Assert-RelayReference -Reference $Reference
    $candidateRecords = if ($null -ne $Records) { @($Records) } else { @(Get-CoordinationLogRecords -Path $Path) }
    $proofs = @()
    foreach ($record in $candidateRecords) {
        $proof = ConvertTo-NamingAppliedProof -Record $record
        if ($null -ne $proof -and [string]$proof.relay_ref -eq $Reference) {
            $proofs += $proof
        }
    }
    return $proofs
}

function Test-NamingAppliedProof {
    param(
        [Parameter(Mandatory)][object]$Relay,
        [Parameter(Mandatory)][object]$Proof
    )

    try {
        $fields = Get-NamingRequestFields -Payload ([string]$Relay.payload)
    }
    catch {
        return $false
    }
    $expectedTargetSession = if ($fields.ContainsKey('requester_session')) {
        [string]$fields['requester_session']
    }
    else {
        $null
    }
    $targetSessionMatches = if ([string]::IsNullOrWhiteSpace($expectedTargetSession)) {
        -not [string]::IsNullOrWhiteSpace([string]$Proof.target_session)
    }
    else {
        [string]$Proof.target_session -eq $expectedTargetSession
    }

    # A proof only counts when the coordinator that the request was routed to is
    # both the author and the declared applier, and the pane it named is exactly
    # the pane that asked. Anything else is a forged or misdirected proof.
    return (
        -not [string]::IsNullOrWhiteSpace([string]$Relay.recipient_pane_id) -and
        [string]$Proof.coordinator_pane_id -eq [string]$Relay.recipient_pane_id -and
        [string]$Proof.writer_pane_id -eq [string]$Relay.recipient_pane_id -and
        [string]$Proof.target_pane_id -eq [string]$Relay.sender -and
        [string]$Proof.returned_to -eq [string]$Relay.sender -and
        $targetSessionMatches -and
        ([string]::IsNullOrWhiteSpace([string]$Relay.recipient_session) -or
            [string]$Proof.coordinator_session -eq [string]$Relay.recipient_session)
    )
}

function Get-ValidNamingAppliedProofs {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Relay,
        [object[]]$Records
    )

    $proofs = @(Get-NamingAppliedProofs -Path $Path -Reference ([string]$Relay.relay_ref) -Records $Records)
    return @($proofs | Where-Object { Test-NamingAppliedProof -Relay $Relay -Proof $_ })
}

function ConvertTo-NamingDispositionProof {
    param([Parameter(Mandatory)][object]$Record)

    if ([string]$Record.body -notmatch $NamingDispositionBodyPattern) {
        return $null
    }
    return [pscustomobject]@{
        proof_ref = ('[HD:{0}]' -f $Matches['proof'])
        relay_ref = [string]$Matches['relay']
        disposition = [string]$Matches['disposition']
        target_pane_id = [string]$Matches['pane']
        coordinator_pane_id = [string]$Matches['coordinator']
        coordinator_session = [string]$Matches['coordsession']
        requester_session = [string]$Matches['requestersession']
        absence = [string]$Matches['absence']
        writer_pane_id = [string]$Record.from
        returned_to = [string]$Record.to
        entry = [string]$Record.line
        stamp = if ($Record.PSObject.Properties['stamp']) { [string]$Record.stamp } else { $null }
    }
}

function Get-NamingDispositionProofs {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reference,
        [object[]]$Records
    )

    Assert-RelayReference -Reference $Reference
    $candidateRecords = if ($null -ne $Records) { @($Records) } else { @(Get-CoordinationLogRecords -Path $Path) }
    return @($candidateRecords | ForEach-Object {
            $proof = ConvertTo-NamingDispositionProof -Record $_
            if ($null -ne $proof -and [string]$proof.relay_ref -eq $Reference) { $proof }
        })
}

function Test-NamingDispositionProof {
    param(
        [Parameter(Mandatory)][object]$Relay,
        [Parameter(Mandatory)][object]$Proof
    )

    try {
        $fields = Get-NamingRequestFields -Payload ([string]$Relay.payload)
    }
    catch {
        return $false
    }
    if (-not (Test-NamingRetirementRequest -Fields $fields -Relay $Relay)) {
        return $false
    }
    $expectedRequesterSession = if ($fields.ContainsKey('requester_session')) {
        [string]$fields['requester_session']
    }
    else {
        'legacy-unavailable'
    }
    return (
        [string]$Proof.disposition -eq 'retirement_target_gone' -and
        [string]$Proof.absence -eq 'pane_not_found' -and
        [string]$Proof.coordinator_pane_id -eq [string]$Relay.recipient_pane_id -and
        [string]$Proof.writer_pane_id -eq [string]$Relay.recipient_pane_id -and
        [string]$Proof.target_pane_id -eq [string]$Relay.sender -and
        [string]$Proof.returned_to -eq [string]$Relay.sender -and
        [string]$Proof.requester_session -eq $expectedRequesterSession -and
        -not [string]::IsNullOrWhiteSpace([string]$Proof.coordinator_session) -and
        ([string]::IsNullOrWhiteSpace([string]$Relay.recipient_session) -or
            [string]$Proof.coordinator_session -eq [string]$Relay.recipient_session)
    )
}

function Get-ValidNamingDispositionProofs {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Relay,
        [object[]]$Records
    )

    try {
        $fields = Get-NamingRequestFields -Payload ([string]$Relay.payload)
    }
    catch {
        return @()
    }
    if (-not (Test-NamingRetirementRequest -Fields $fields -Relay $Relay)) {
        return @()
    }
    $validAcks = @(Get-ValidRelayReadAcks -Path $Path -Relay $Relay -Records $Records)
    if ($validAcks.Count -ne 1) {
        return @()
    }
    $proofs = @(Get-NamingDispositionProofs -Path $Path -Reference ([string]$Relay.relay_ref) -Records $Records)
    return @($proofs | Where-Object { Test-NamingDispositionProof -Relay $Relay -Proof $_ })
}

function ConvertTo-NamingApplyIntent {
    param([Parameter(Mandatory)][object]$Record)

    if ([string]$Record.body -notmatch $NamingApplyIntentBodyPattern) {
        return $null
    }
    return [pscustomobject]@{
        proof_ref = ('[HI:{0}]' -f $Matches['proof'])
        relay_ref = [string]$Matches['relay']
        target_pane_id = [string]$Matches['pane']
        target_tab_id = [string]$Matches['tab']
        coordinator_pane_id = [string]$Matches['coordinator']
        coordinator_session = [string]$Matches['coordsession']
        target_session = [string]$Matches['targetsession']
        writer_pane_id = [string]$Record.from
        returned_to = [string]$Record.to
        entry = [string]$Record.line
        stamp = if ($Record.PSObject.Properties['stamp']) { [string]$Record.stamp } else { $null }
    }
}

function Get-ValidNamingApplyIntents {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Relay,
        [object[]]$Records
    )

    $candidateRecords = if ($null -ne $Records) { @($Records) } else { @(Get-CoordinationLogRecords -Path $Path) }
    try {
        $fields = Get-NamingRequestFields -Payload ([string]$Relay.payload)
    }
    catch {
        return @()
    }
    $expectedTargetSession = if ($fields.ContainsKey('requester_session')) { [string]$fields['requester_session'] } else { $null }
    return @($candidateRecords | ForEach-Object {
            $intent = ConvertTo-NamingApplyIntent -Record $_
            if ($null -eq $intent -or [string]$intent.relay_ref -ne [string]$Relay.relay_ref) { return }
            if ([string]$intent.coordinator_pane_id -eq [string]$Relay.recipient_pane_id -and
                [string]$intent.writer_pane_id -eq [string]$Relay.recipient_pane_id -and
                [string]$intent.target_pane_id -eq [string]$Relay.sender -and
                [string]$intent.returned_to -eq [string]$Relay.sender -and
                ([string]::IsNullOrWhiteSpace([string]$Relay.recipient_session) -or
                    [string]$intent.coordinator_session -eq [string]$Relay.recipient_session) -and
                ([string]::IsNullOrWhiteSpace($expectedTargetSession) -or
                    [string]$intent.target_session -eq $expectedTargetSession)) {
                $intent
            }
        })
}

function Test-NamingRequestRelay {
    param([Parameter(Mandatory)][object]$Relay)

    $payload = [string]$Relay.payload
    return -not [string]::IsNullOrWhiteSpace($payload) -and
        $payload.StartsWith($NamingRequestMarker, [StringComparison]::Ordinal) -and
        $payload -match 'coordinator_action=apply-name-and-return-proof'
}

function Get-NamingRequestFields {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Payload)

    if (-not $Payload.StartsWith($NamingRequestMarker, [StringComparison]::Ordinal)) {
        throw "Relay payload is not a PANE NAMING REQUEST."
    }
    $fields = @{}
    foreach ($part in ($Payload.Substring($NamingRequestMarker.Length) -split '; ')) {
        $pair = $part -split '=', 2
        if ($pair.Count -eq 2) {
            $fields[$pair[0].Trim()] = $pair[1].Trim()
        }
    }
    foreach ($required in @("repo", "work")) {
        if (-not $fields.ContainsKey($required) -or [string]::IsNullOrWhiteSpace([string]$fields[$required])) {
            throw "PANE NAMING REQUEST is missing the required '$required' field."
        }
    }
    return $fields
}

function Get-NamingRequestField {
    param(
        [Parameter(Mandatory)][hashtable]$Fields,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Fields.ContainsKey($Name)) {
        return ""
    }
    return [string]$Fields[$Name]
}

function Test-NamingRetirementRequest {
    param(
        [Parameter(Mandatory)][hashtable]$Fields,
        [Parameter(Mandatory)][object]$Relay
    )

    $lifecycle = Get-NamingRequestField -Fields $Fields -Name 'lifecycle'
    if ($lifecycle -eq 'retirement') {
        return (
            (Get-NamingRequestField -Fields $Fields -Name 'requester_pane') -eq [string]$Relay.sender -and
            (Get-NamingRequestField -Fields $Fields -Name 'requester_tab') -match '^w[0-9A-Za-z]+:t[0-9A-Za-z]+$' -and
            -not [string]::IsNullOrWhiteSpace((Get-NamingRequestField -Fields $Fields -Name 'requester_agent')) -and
            -not [string]::IsNullOrWhiteSpace((Get-NamingRequestField -Fields $Fields -Name 'requester_session')) -and
            (Get-NamingRequestField -Fields $Fields -Name 'previous_name') -match '^(?:STM|AGT|Hdr|Buzz)-[A-Z][A-Z0-9]*-[A-Z][0-9]+$' -and
            -not [string]::IsNullOrWhiteSpace((Get-NamingRequestField -Fields $Fields -Name 'previous_work'))
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($lifecycle)) {
        return $false
    }

    # Narrow compatibility for pre-lifecycle retirement requests. Complete,
    # hash-valid relay metadata and explicit previous identity are mandatory.
    return (
        (Get-NamingRequestField -Fields $Fields -Name 'work') -eq 'issue' -and
        (Get-NamingRequestField -Fields $Fields -Name 'title') -ceq 'retired' -and
        (Get-NamingRequestField -Fields $Fields -Name 'previous_name') -match '^(?:STM|AGT|Hdr|Buzz)-[A-Z][A-Z0-9]*-[A-Z][0-9]+$' -and
        -not [string]::IsNullOrWhiteSpace((Get-NamingRequestField -Fields $Fields -Name 'previous_work')) -and
        [bool]$Relay.metadata_complete -and
        [bool]$Relay.payload_hash_valid
    )
}

function Get-NamingRequesterProof {
    param([Parameter(Mandatory)][string]$SenderPaneId)

    $sessionHint = if (-not [string]::IsNullOrWhiteSpace([string]$env:HERDR_AGENT_SESSION_ID)) {
        [string]$env:HERDR_AGENT_SESSION_ID
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$env:CODEX_THREAD_ID)) {
        [string]$env:CODEX_THREAD_ID
    }
    else {
        $null
    }
    # Claude's managed hook may not export HERDR_AGENT_SESSION_ID to the
    # command shell that submits the name request. When there is no explicit
    # hint, use the live pane/session plus the caller-process lease already
    # proven by Get-CurrentRelayReaderProof. This is a fallback to native
    # Herdr identity, not reconstruction from a transcript, cwd, or UI label.
    $allowLiveSessionFallback = [string]::IsNullOrWhiteSpace($sessionHint)
    return Get-CurrentRelayReaderProof `
        -TargetPaneId $SenderPaneId `
        -CallerSession $sessionHint `
        -AllowSessionRotation:$allowLiveSessionFallback
}

function Test-HerdrPaneNotFoundException {
    param(
        [Parameter(Mandatory)][object]$ErrorRecord,
        [Parameter(Mandatory)][string]$TargetPaneId
    )

    $prefix = 'herdr pane get {0} failed: ' -f $TargetPaneId
    $message = [string]$ErrorRecord.Exception.Message
    if (-not $message.StartsWith($prefix, [StringComparison]::Ordinal)) {
        return $false
    }
    $jsonText = $message.Substring($prefix.Length)
    try {
        $errorEnvelope = $jsonText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $false
    }
    return (
        $null -ne $errorEnvelope.error -and
        [string]$errorEnvelope.error.code -ceq 'pane_not_found'
    )
}

function Get-NamingWorkSubtitle {
    param([Parameter(Mandatory)][hashtable]$Fields)

    # Mirrors Get-WorkSubname in herdr_pane_registry.ps1; both entry points must
    # emit byte-identical subtitles or the registry and the tab disagree.
    $kind = Get-NamingRequestField -Fields $Fields -Name "work"
    $issue = Get-NamingRequestField -Fields $Fields -Name "issue"
    $title = Get-NamingRequestField -Fields $Fields -Name "title"
    $topic = Get-NamingRequestField -Fields $Fields -Name "topic"
    $sep = $NamingSubtitleSeparator

    if ($kind -eq "explore") {
        $topicText = if ([string]::IsNullOrWhiteSpace($topic)) { "unassigned" } else { $topic.Trim() }
        return "EXPLORE $sep $topicText"
    }
    if ($kind -eq "issue") {
        if ($issue -notmatch '^#?\d+$' -or [string]::IsNullOrWhiteSpace($title)) {
            throw "Issue naming request requires a numeric issue and short title."
        }
        return "#$($issue.TrimStart('#')) $sep $($title.Trim())"
    }
    if ($kind -eq "pr") {
        if ($issue -notmatch '^(?:PR#?)?\d+$' -or [string]::IsNullOrWhiteSpace($title)) {
            throw "PR naming request requires a numeric PR and short title."
        }
        return "PR#$([regex]::Match($issue, '\d+').Value) $sep $($title.Trim())"
    }
    if ($kind -eq "no-issue") {
        if ([string]::IsNullOrWhiteSpace($title)) {
            throw "No-issue naming request requires a short description."
        }
        return "NO-ISSUE $sep $($title.Trim())"
    }
    throw "Unsupported naming request work kind '$kind'."
}

function Get-NamingCanonicalPrefix {
    param([Parameter(Mandatory)][hashtable]$Fields)

    $repoNames = @{ STM = "STM"; AGT = "AGT"; HDR = "Hdr"; BUZ = "Buzz" }
    $repo = Get-NamingRequestField -Fields $Fields -Name "repo"
    if (-not $repoNames.ContainsKey($repo)) {
        throw "Naming request carries unsupported repo code '$repo'."
    }
    $repoName = [string]$repoNames[$repo]
    if ((Get-NamingRequestField -Fields $Fields -Name "work") -eq "explore") {
        return "$repoName-E"
    }
    $lane = Get-NamingRequestField -Fields $Fields -Name "lane"
    $role = Get-NamingRequestField -Fields $Fields -Name "role"
    if ($lane -notmatch '^[A-Z][A-Z0-9]{0,7}$') {
        throw "Naming request carries unsupported lane code '$lane'."
    }
    if ($role -notmatch '^[A-Z]$') {
        throw "Naming request carries unsupported role code '$role'."
    }
    return "$repoName-$lane-$role"
}

function Get-LiveTabLabels {
    $workspaceResponse = Invoke-HerdrJson -Arguments @("workspace", "list")
    $tabs = [Collections.Generic.List[object]]::new()
    foreach ($workspace in @($workspaceResponse.result.workspaces)) {
        $workspaceId = [string]$workspace.workspace_id
        $tabResponse = Invoke-HerdrJson -Arguments @("tab", "list", "--workspace", $workspaceId)
        foreach ($tab in @($tabResponse.result.tabs)) {
            $tabs.Add([pscustomobject]@{
                tab_id = [string]$tab.tab_id
                label = ([string]$tab.label -replace "[\x00-\x1f\x7f]+", " " -replace "\s+", " ").Trim()
            })
        }
    }
    return @($tabs)
}

function Resolve-NamingCanonicalName {
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentLabel,
        [Parameter(Mandatory)][AllowEmptyString()][string]$TargetTabId,
        [object[]]$LiveTabs
    )

    $escapedPrefix = [regex]::Escape($Prefix)
    # Re-applying an unchanged repo/lane/role keeps the slot the pane already
    # holds, so repeated consumption never churns the canonical name.
    if ($CurrentLabel -cmatch "^$escapedPrefix(?<slot>\d+)$") {
        return "$Prefix$([int]$Matches['slot'])"
    }

    $taken = @{}
    foreach ($tab in @($LiveTabs)) {
        if ([string]$tab.tab_id -eq $TargetTabId) {
            continue
        }
        if ([string]$tab.label -cmatch "^$escapedPrefix(?<slot>\d+)$") {
            $taken[[int]$Matches['slot']] = $true
        }
    }
    for ($slot = 1; $slot -le 999; $slot++) {
        if (-not $taken.ContainsKey($slot)) {
            return "$Prefix$slot"
        }
    }
    throw "No canonical slot is available for prefix '$Prefix'."
}

function Get-CoordinatorPaneId {
    param([Parameter(Mandatory)][string]$Label)

    $discovery = Find-Coordinator -Label $Label
    if (-not $discovery.found -or $discovery.ambiguous) {
        throw "Coordinator-owned naming requires one unambiguous Coordination pane."
    }
    return [string]$discovery.coordinator.pane_id
}

function Add-RelayContinuationInstruction {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ($Text -match '^(?:COORDINATION LOG NOTICE|WORK REQUEST)\b' -and
        $Text -notmatch 'immediately execute the instructions in the relay body') {
        return "$Text $RelayContinuationInstruction"
    }
    return $Text
}

function Normalize-PaneMetadataValue {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return "" }
    $normalized = ($Value -replace "[\x00-\x1f\x7f]+", " ").Trim()
    if ($normalized.Length -gt 80) {
        return $normalized.Substring(0, 80)
    }
    return $normalized
}

function Assert-CoordinatorCaller {
    param([Parameter(Mandatory)][string]$CoordinatorPaneId)

    if ($env:HERDR_PANE_ID -ne $CoordinatorPaneId) {
        throw "Coordinator-owned naming is refused; caller $($env:HERDR_PANE_ID) is not $CoordinatorPaneId."
    }
}

function Get-CoordinatorVisiblePaneLabel {
    param([Parameter(Mandatory)][object]$Pane)

    foreach ($name in @("label", "pane_label")) {
        $property = $Pane.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value -and
            -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return ([string]$property.Value).Trim()
        }
    }
    return ""
}

function Set-AtomicCanonicalPaneAndTabLabel {
    param(
        [Parameter(Mandatory)][string]$PaneId,
        [Parameter(Mandatory)][string]$TabId,
        [Parameter(Mandatory)][string]$CanonicalName,
        [AllowEmptyString()][string]$PreviousPaneLabel = "",
        [AllowEmptyString()][string]$PreviousTabLabel = ""
    )

    $tabChanged = $false
    $paneChanged = $false
    try {
        if ($PreviousTabLabel -cne $CanonicalName) {
            $null = Invoke-HerdrJson -Arguments @("tab", "rename", $TabId, $CanonicalName)
            $tabChanged = $true
        }
        if ($PreviousPaneLabel -cne $CanonicalName) {
            $null = Invoke-HerdrJson -Arguments @("pane", "rename", $PaneId, $CanonicalName)
            $paneChanged = $true
        }

        $afterPane = (Invoke-HerdrJson -Arguments @("pane", "get", $PaneId)).result.pane
        $afterVisibleLabel = Get-CoordinatorVisiblePaneLabel -Pane $afterPane
        $afterTab = (Invoke-HerdrJson -Arguments @("tab", "get", $TabId)).result.tab
        $afterTabLabel = [string]$afterTab.label
        if ($afterVisibleLabel -cne $CanonicalName -or $afterTabLabel -cne $CanonicalName) {
            throw "canonical label verification failed: pane='$afterVisibleLabel', tab='$afterTabLabel', expected='$CanonicalName'."
        }
        return [pscustomobject]@{
            pane = $afterPane
            pane_label = $afterVisibleLabel
            tab = $afterTab
            tab_label = $afterTabLabel
        }
    }
    catch {
        $original = $_.Exception.Message
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        if ($paneChanged) {
            try {
                if ([string]::IsNullOrWhiteSpace($PreviousPaneLabel)) {
                    $null = Invoke-HerdrJson -Arguments @("pane", "rename", $PaneId, "--clear")
                }
                else {
                    $null = Invoke-HerdrJson -Arguments @("pane", "rename", $PaneId, $PreviousPaneLabel)
                }
            }
            catch { $rollbackErrors.Add("pane rollback: $($_.Exception.Message)") }
        }
        if ($tabChanged) {
            try {
                if ([string]::IsNullOrWhiteSpace($PreviousTabLabel)) {
                    $null = Invoke-HerdrJson -Arguments @("tab", "rename", $TabId, "")
                }
                else {
                    $null = Invoke-HerdrJson -Arguments @("tab", "rename", $TabId, $PreviousTabLabel)
                }
            }
            catch { $rollbackErrors.Add("tab rollback: $($_.Exception.Message)") }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "Atomic canonical label reconciliation failed: $original Rollback was not proven: $($rollbackErrors -join '; ')"
        }
        throw "Atomic canonical label reconciliation failed before metadata mutation: $original"
    }
}

function Invoke-CoordinatorApplyName {
    param(
        [Parameter(Mandatory)][string]$CoordinatorPaneId,
        [Parameter(Mandatory)][string]$TargetPaneId,
        [Parameter(Mandatory)][string]$CanonicalName,
        [Parameter(Mandatory)][string]$Subtitle,
        [Parameter(Mandatory)][string]$ExpectedCurrentLabel,
    [string]$RequiredTargetSession
    )

    $effectiveSubtitle = Normalize-PaneMetadataValue -Value $Subtitle
    if ($CanonicalName -notmatch '^(?:Coordination|Fix|(?:STM|AGT|Hdr|Buzz)-(?:E\d+|[A-Z][A-Z0-9]*-[A-Z]\d+))$') {
        throw "apply-name rejected non-canonical pane name '$CanonicalName'."
    }
    foreach ($value in @($CanonicalName, $effectiveSubtitle, $ExpectedCurrentLabel)) {
        if ($value -match '[\r\n]') { throw "apply-name fields cannot contain newlines." }
    }

    $callerAgent = Invoke-HerdrJson -Arguments @("agent", "get", $CoordinatorPaneId)
    $callerSession = Get-AgentSessionId -AgentRecord $callerAgent.result.agent
    if ([string]::IsNullOrWhiteSpace($callerSession)) { throw "Coordinator lacks stable native session proof." }
    $targetPaneResponse = Invoke-HerdrJson -Arguments @("pane", "get", $TargetPaneId)
    $targetPane = $targetPaneResponse.result.pane
    $labelProof = Assert-PaneTabLabel -TargetPaneId $TargetPaneId -PaneRecord $targetPane -RequiredTabLabel $ExpectedCurrentLabel
    $targetAgentResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
    $targetAgent = $targetAgentResponse.result.agent
    $targetSession = Get-AgentSessionId -AgentRecord $targetAgent
    if ([string]::IsNullOrWhiteSpace($targetSession)) { throw "Target pane lacks stable native session proof." }
    # Fail closed before any mutation when the caller named a session that the
    # target pane no longer hosts.
    if (-not [string]::IsNullOrWhiteSpace($RequiredTargetSession) -and
        $targetSession -cne $RequiredTargetSession) {
        throw "Target pane $TargetPaneId no longer hosts the expected native session '$RequiredTargetSession'."
    }
    if ([string]$targetAgent.pane_id -ne $TargetPaneId -or [string]$targetPane.tab_id -ne $labelProof.tab_id) {
        throw "Target pane/session tuple changed before apply-name mutation."
    }
    $previousPaneLabel = Get-CoordinatorVisiblePaneLabel -Pane $targetPane
    $labelReconciliation = Set-AtomicCanonicalPaneAndTabLabel `
        -PaneId $TargetPaneId `
        -TabId $labelProof.tab_id `
        -CanonicalName $CanonicalName `
        -PreviousPaneLabel $previousPaneLabel `
        -PreviousTabLabel ([string]$labelProof.tab_label)
    $null = Invoke-HerdrJson -Arguments @(
        "pane", "report-metadata", $TargetPaneId,
        "--source", "herdr-coordination",
        "--title", $effectiveSubtitle,
        "--display-agent", $effectiveSubtitle,
        "--token", "canonical_name=$CanonicalName",
        "--token", "coordinator_session=$callerSession",
        "--token", "target_session=$targetSession"
    )
    $afterPane = (Invoke-HerdrJson -Arguments @("pane", "get", $TargetPaneId)).result.pane
    $afterLabel = (Invoke-HerdrJson -Arguments @("tab", "get", [string]$afterPane.tab_id)).result.tab.label
    $afterPaneLabel = Get-CoordinatorVisiblePaneLabel -Pane $afterPane
    $afterAgent = (Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)).result.agent
    $afterTitle = if ($afterAgent.PSObject.Properties["title"]) { [string]$afterAgent.title } else { $null }
    $afterDisplay = if ($afterAgent.PSObject.Properties["display_agent"]) { [string]$afterAgent.display_agent } else { $null }
    if ([string]$afterLabel -cne $CanonicalName -or $afterPaneLabel -cne $CanonicalName -or
        $afterTitle -cne $effectiveSubtitle -or $afterDisplay -cne $effectiveSubtitle) {
        throw "apply-name verification failed: pane-label='$afterPaneLabel', label='$afterLabel', title='$afterTitle', display-agent='$afterDisplay'."
    }

    return [pscustomobject]@{
        applied = $true
        coordinator_pane_id = $CoordinatorPaneId
        coordinator_session = $callerSession
        target_pane_id = $TargetPaneId
        target_session = $targetSession
        tab_id = [string]$afterPane.tab_id
        tab_label = [string]$afterLabel
        pane_label = $afterPaneLabel
        title = $afterTitle
        display_agent = $afterDisplay
    }
}

function Add-NamingAppliedProof {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelayRef,
        [Parameter(Mandatory)][object]$Relay,
        [Parameter(Mandatory)][object]$Applied
    )

    Assert-RelayReference -Reference $RelayRef
    $proofRef = "[HN:$([Guid]::NewGuid().ToString('N').Substring(0, 8))]"
    $subtitleB64 = ConvertTo-CoordinationMetadataBase64 -Text ([string]$Applied.title)
    $body = "$proofRef [APPLIED re $RelayRef]" +
        " [APPLIED-PANE $($Applied.target_pane_id)]" +
        " [APPLIED-TAB $($Applied.tab_id)]" +
        " [APPLIED-COORDINATOR $($Applied.coordinator_pane_id)]" +
        " applied; canonical_name=$($Applied.tab_label); subtitle_b64=$subtitleB64;" +
        " pane_label=$($Applied.pane_label); coordinator_session=$($Applied.coordinator_session); target_session=$($Applied.target_session)"
    $entry = Add-CoordinationEntry `
        -Path $Path `
        -Sender ([string]$Applied.coordinator_pane_id) `
        -Recipient ([string]$Relay.sender) `
        -Body $body
    return [pscustomobject]@{
        proof_ref = $proofRef
        relay_ref = $RelayRef
        target_pane_id = [string]$Applied.target_pane_id
        target_tab_id = [string]$Applied.tab_id
        coordinator_pane_id = [string]$Applied.coordinator_pane_id
        canonical_name = [string]$Applied.tab_label
        pane_label = [string]$Applied.pane_label
        subtitle = [string]$Applied.title
        coordinator_session = [string]$Applied.coordinator_session
        target_session = [string]$Applied.target_session
        entry = $entry
    }
}

function Get-CoordinatorNamingSession {
    param(
        [Parameter(Mandatory)][string]$CoordinatorPaneId,
        [Parameter(Mandatory)][object]$Relay
    )

    $agent = (Invoke-HerdrJson -Arguments @('agent', 'get', $CoordinatorPaneId)).result.agent
    $session = Get-AgentSessionId -AgentRecord $agent
    if ([string]$agent.pane_id -ne $CoordinatorPaneId -or [string]::IsNullOrWhiteSpace($session)) {
        throw 'Coordinator lacks stable native session proof for naming lifecycle evidence.'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Relay.recipient_session) -and
        $session -ne [string]$Relay.recipient_session) {
        throw 'Coordinator native session no longer matches the naming relay recipient session.'
    }
    return $session
}

function Add-NamingDispositionProof {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelayRef,
        [Parameter(Mandatory)][object]$Relay,
        [Parameter(Mandatory)][string]$CoordinatorPaneId
    )

    $fields = Get-NamingRequestFields -Payload ([string]$Relay.payload)
    $requesterSession = if ($fields.ContainsKey('requester_session')) {
        [string]$fields['requester_session']
    }
    else {
        'legacy-unavailable'
    }
    $coordinatorSession = Get-CoordinatorNamingSession -CoordinatorPaneId $CoordinatorPaneId -Relay $Relay
    $proofRef = '[HD:{0}]' -f [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $body = $proofRef +
        (' [DISPOSED re {0}]' -f $RelayRef) +
        ' [DISPOSITION retirement_target_gone]' +
        (' [DISPOSED-PANE {0}]' -f [string]$Relay.sender) +
        (' [DISPOSED-COORDINATOR {0}]' -f $CoordinatorPaneId) +
        (' disposed; coordinator_session={0}; requester_session={1}; absence=pane_not_found' -f $coordinatorSession, $requesterSession)
    $entry = Add-CoordinationEntry -Path $Path -Sender $CoordinatorPaneId -Recipient ([string]$Relay.sender) -Body $body
    return [pscustomobject]@{
        proof_ref = $proofRef
        relay_ref = $RelayRef
        disposition = 'retirement_target_gone'
        target_pane_id = [string]$Relay.sender
        coordinator_pane_id = $CoordinatorPaneId
        coordinator_session = $coordinatorSession
        requester_session = $requesterSession
        absence = 'pane_not_found'
        entry = $entry
    }
}

function Add-NamingApplyIntent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelayRef,
        [Parameter(Mandatory)][object]$Relay,
        [Parameter(Mandatory)][string]$CoordinatorPaneId,
        [Parameter(Mandatory)][object]$TargetPane,
        [Parameter(Mandatory)][string]$TargetSession
    )

    $coordinatorSession = Get-CoordinatorNamingSession -CoordinatorPaneId $CoordinatorPaneId -Relay $Relay
    $proofRef = '[HI:{0}]' -f [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $body = $proofRef +
        (' [APPLY-STARTED re {0}]' -f $RelayRef) +
        (' [APPLY-PANE {0}]' -f [string]$Relay.sender) +
        (' [APPLY-TAB {0}]' -f [string]$TargetPane.tab_id) +
        (' [APPLY-COORDINATOR {0}]' -f $CoordinatorPaneId) +
        (' started; coordinator_session={0}; target_session={1}' -f $coordinatorSession, $TargetSession)
    $entry = Add-CoordinationEntry -Path $Path -Sender $CoordinatorPaneId -Recipient ([string]$Relay.sender) -Body $body
    return [pscustomobject]@{
        proof_ref = $proofRef
        relay_ref = $RelayRef
        target_pane_id = [string]$Relay.sender
        target_tab_id = [string]$TargetPane.tab_id
        coordinator_pane_id = $CoordinatorPaneId
        coordinator_session = $coordinatorSession
        target_session = $TargetSession
        entry = $entry
    }
}

function Get-NamingRequestRelays {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [ValidateRange(1, 5000)][int]$MaxRequests = 200
    )

    # One bounded pass: collect candidate naming-request relays newest-first and
    # stop at the cap so a multi-megabyte log cannot make the watchdog unbounded.
    $seen = @{}
    $ambiguous = @{}
    $ordered = [Collections.Generic.List[object]]::new()
    for ($index = $Records.Count - 1; $index -ge 0; $index--) {
        $record = $Records[$index]
        $body = [string]$record.body
        if ($body -notmatch $NamingRequestRelayPattern) {
            continue
        }
        $relayRef = [string]$Matches['relay']
        if ($body -notmatch [regex]::Escape($NamingRequestMarker)) {
            continue
        }
        if ($seen.ContainsKey($relayRef)) {
            $ambiguous[$relayRef] = $true
            continue
        }
        $seen[$relayRef] = $true
        $relay = ConvertTo-RelayRecord -Record $record -Reference $relayRef
        if (-not (Test-NamingRequestRelay -Relay $relay)) {
            continue
        }
        $ordered.Add($relay)
        if ($ordered.Count -ge $MaxRequests) {
            break
        }
    }
    return [pscustomobject]@{
        relays = @($ordered)
        ambiguous_relay_refs = @($ambiguous.Keys)
        truncated = $ordered.Count -ge $MaxRequests
    }
}

function Get-NamingRequestState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Relay,
        [Parameter(Mandatory)][int]$DeadlineSeconds,
        [object[]]$Records
    )

    $validAcks = @(Get-ValidRelayReadAcks -Path $Path -Relay $Relay -Records $Records)
    $validProofs = @(Get-ValidNamingAppliedProofs -Path $Path -Relay $Relay -Records $Records)
    $validDispositions = @(Get-ValidNamingDispositionProofs -Path $Path -Relay $Relay -Records $Records)
    $validIntents = @(Get-ValidNamingApplyIntents -Path $Path -Relay $Relay -Records $Records)
    $ackStamp = if ($validAcks.Count -ge 1) { ConvertFrom-CoordinationStamp -Stamp ([string]$validAcks[0].stamp) } else { $null }
    $overdueSeconds = $null
    $state = "awaiting_read_ack"
    if ($validProofs.Count -gt 1 -or $validDispositions.Count -gt 1 -or
        ($validProofs.Count -ge 1 -and $validDispositions.Count -ge 1)) {
        $state = 'reconciliation_required'
    }
    elseif ($validProofs.Count -eq 1) {
        $state = "applied"
    }
    elseif ($validDispositions.Count -eq 1) {
        $state = 'retirement_target_gone'
    }
    elseif ($validIntents.Count -ge 1) {
        $state = 'uncertain_apply'
    }
    elseif ($validAcks.Count -ge 1) {
        $state = "read_acked_unapplied"
        if ($null -ne $ackStamp) {
            $elapsed = ([DateTimeOffset]::Now - $ackStamp).TotalSeconds
            if ($elapsed -gt $DeadlineSeconds) {
                $state = "overdue_unapplied"
                $overdueSeconds = [int][Math]::Round($elapsed - $DeadlineSeconds)
            }
        }
    }

    $fields = $null
    $requestedName = $null
    try {
        $fields = Get-NamingRequestFields -Payload ([string]$Relay.payload)
        $requestedName = Get-NamingCanonicalPrefix -Fields $fields
    }
    catch {
        $requestedName = $null
    }

    return [pscustomobject]@{
        relay_ref = [string]$Relay.relay_ref
        state = $state
        requesting_pane_id = [string]$Relay.sender
        coordinator_pane_id = [string]$Relay.recipient_pane_id
        requested_prefix = $requestedName
        request_stamp = [string]$Relay.stamp
        body_read = $validAcks.Count -ge 1
        read_ack_ref = if ($validAcks.Count -ge 1) { [string]$validAcks[0].ack_ref } else { $null }
        read_ack_stamp = if ($validAcks.Count -ge 1) { [string]$validAcks[0].stamp } else { $null }
        applied = $validProofs.Count -ge 1
        applied_proof_ref = if ($validProofs.Count -ge 1) { [string]$validProofs[0].proof_ref } else { $null }
        applied_canonical_name = if ($validProofs.Count -ge 1) { [string]$validProofs[0].canonical_name } else { $null }
        applied_proof_count = $validProofs.Count
        terminal = $validDispositions.Count -eq 1 -and $state -eq 'retirement_target_gone'
        disposition_ref = if ($validDispositions.Count -eq 1) { [string]$validDispositions[0].proof_ref } else { $null }
        disposition = if ($validDispositions.Count -eq 1) { [string]$validDispositions[0].disposition } else { $null }
        disposition_count = $validDispositions.Count
        apply_intent_ref = if ($validIntents.Count -ge 1) { [string]$validIntents[0].proof_ref } else { $null }
        apply_intent_count = $validIntents.Count
        uncertain = $state -eq 'uncertain_apply'
        overdue = $state -eq "overdue_unapplied"
        overdue_by_seconds = $overdueSeconds
        deadline_seconds = $DeadlineSeconds
    }
}

function Invoke-NamingRequestConsumption {
    param(
        [Parameter(Mandatory)][string]$RelayRef,
        [Parameter(Mandatory)][string]$CoordinatorPaneId,
        [object]$Relay,
        [object[]]$Records,
        [string]$OverrideCanonicalName,
        [string]$OverrideSubtitle,
        [string]$OverrideExpectedCurrentLabel,
        [string]$RequiredTargetSession
    )

    Assert-RelayReference -Reference $RelayRef
    $relayRecord = if ($null -ne $Relay) { $Relay } else { Get-RelayRecord -Path $LogPath -Reference $RelayRef -Records $Records }
    if (-not (Test-NamingRequestRelay -Relay $relayRecord)) {
        throw "Relay $RelayRef is not a PANE NAMING REQUEST that asks for coordinator application."
    }
    # Fail closed when the request was routed to a different Coordination pane:
    # only the addressed coordinator may apply and prove it.
    if ([string]$relayRecord.recipient_pane_id -ne $CoordinatorPaneId) {
        throw "Relay $RelayRef was routed to $($relayRecord.recipient_pane_id), not to coordinator $CoordinatorPaneId."
    }
    $targetPaneId = [string]$relayRecord.sender
    if ($targetPaneId -notmatch '^w[0-9A-Za-z]+:p[0-9A-Za-z]+$') {
        throw "Relay $RelayRef has no stable requesting-pane identity to name."
    }

    $validProofs = @(Get-ValidNamingAppliedProofs -Path $LogPath -Relay $relayRecord -Records $Records)
    $validDispositions = @(Get-ValidNamingDispositionProofs -Path $LogPath -Relay $relayRecord -Records $Records)
    $validIntents = @(Get-ValidNamingApplyIntents -Path $LogPath -Relay $relayRecord -Records $Records)
    if ($validProofs.Count -gt 1 -or $validDispositions.Count -gt 1 -or
        ($validProofs.Count -ge 1 -and $validDispositions.Count -ge 1)) {
        throw ('Relay {0} has conflicting or duplicate terminal naming evidence and requires reconciliation.' -f $RelayRef)
    }
    if ($validProofs.Count -ge 1) {
        # Idempotent: a request that already carries a valid APPLIED proof is
        # never re-applied and never gains a second proof.
        $existing = $validProofs[0]
        return [pscustomobject]@{
            relay_ref = $RelayRef
            applied = $true
            duplicate = $true
            state = "already_applied"
            proof = $existing
            coordinator_pane_id = [string]$existing.coordinator_pane_id
            coordinator_session = [string]$existing.coordinator_session
            target_pane_id = [string]$existing.target_pane_id
            target_session = [string]$existing.target_session
            tab_id = [string]$existing.target_tab_id
            tab_label = [string]$existing.canonical_name
            pane_label = if ($existing.PSObject.Properties['pane_label']) { [string]$existing.pane_label } else { [string]$existing.canonical_name }
            title = [string]$existing.subtitle
            display_agent = [string]$existing.subtitle
        }
    }
    if ($validDispositions.Count -eq 1) {
        $existingDisposition = $validDispositions[0]
        return [pscustomobject]@{
            relay_ref = $RelayRef
            applied = $false
            terminal = $true
            duplicate = $true
            state = 'retirement_target_gone'
            proof = $existingDisposition
            coordinator_pane_id = [string]$existingDisposition.coordinator_pane_id
            coordinator_session = [string]$existingDisposition.coordinator_session
            target_pane_id = [string]$existingDisposition.target_pane_id
            target_session = [string]$existingDisposition.requester_session
            tab_id = $null
            tab_label = $null
            pane_label = $null
            title = $null
            display_agent = $null
        }
    }
    if ($validIntents.Count -ge 1) {
        throw ('Relay {0} has an unfinished APPLY-STARTED intent; state is uncertain_apply and requires reconciliation.' -f $RelayRef)
    }

    $validAcks = @(Get-ValidRelayReadAcks -Path $LogPath -Relay $relayRecord -Records $Records)
    if ($validAcks.Count -eq 0) {
        return [pscustomobject]@{
            relay_ref = $RelayRef
            applied = $false
            duplicate = $false
            state = "awaiting_read_ack"
            proof = $null
            coordinator_pane_id = $CoordinatorPaneId
            coordinator_session = $null
            target_pane_id = $targetPaneId
            target_session = $null
            tab_id = $null
            tab_label = $null
            pane_label = $null
            title = $null
            display_agent = $null
        }
    }
    if ($validAcks.Count -gt 1) {
        throw "Relay $RelayRef has multiple valid read acknowledgements and requires reconciliation."
    }

    $fields = Get-NamingRequestFields -Payload ([string]$relayRecord.payload)
    $subtitle = if (-not [string]::IsNullOrWhiteSpace($OverrideSubtitle)) {
        $OverrideSubtitle
    }
    else {
        Get-NamingWorkSubtitle -Fields $fields
    }

    $targetPane = $null
    try {
        $targetPane = (Invoke-HerdrJson -Arguments @('pane', 'get', $targetPaneId)).result.pane
    }
    catch {
        if (-not (Test-NamingRetirementRequest -Fields $fields -Relay $relayRecord) -or
            -not (Test-HerdrPaneNotFoundException -ErrorRecord $_ -TargetPaneId $targetPaneId)) {
            throw
        }
        try {
            $targetPane = (Invoke-HerdrJson -Arguments @('pane', 'get', $targetPaneId)).result.pane
        }
        catch {
            if (-not (Test-HerdrPaneNotFoundException -ErrorRecord $_ -TargetPaneId $targetPaneId)) {
                throw
            }
            $disposition = Add-NamingDispositionProof -Path $LogPath -RelayRef $RelayRef -Relay $relayRecord -CoordinatorPaneId $CoordinatorPaneId
            return [pscustomobject]@{
                relay_ref = $RelayRef
                applied = $false
                terminal = $true
                duplicate = $false
                state = 'retirement_target_gone'
                proof = $disposition
                coordinator_pane_id = [string]$disposition.coordinator_pane_id
                coordinator_session = [string]$disposition.coordinator_session
                target_pane_id = $targetPaneId
                target_session = [string]$disposition.requester_session
                tab_id = $null
                tab_label = $null
                pane_label = $null
                title = $null
                display_agent = $null
            }
        }
    }
    if ([string]$targetPane.pane_id -ne $targetPaneId) {
        throw "Requesting pane $targetPaneId could not be resolved for naming."
    }
    $requesterSession = Get-NamingRequestField -Fields $fields -Name 'requester_session'
    $requesterTab = Get-NamingRequestField -Fields $fields -Name 'requester_tab'
    $requesterAgent = Get-NamingRequestField -Fields $fields -Name 'requester_agent'
    if ((Test-NamingRetirementRequest -Fields $fields -Relay $relayRecord) -and
        [string]::IsNullOrWhiteSpace($requesterSession)) {
        throw ('Legacy retirement relay {0} cannot name live pane {1} without exact requester session, tab, and agent provenance.' -f $RelayRef, $targetPaneId)
    }
    if (-not [string]::IsNullOrWhiteSpace($requesterSession)) {
        $liveTargetAgent = (Invoke-HerdrJson -Arguments @('agent', 'get', $targetPaneId)).result.agent
        $liveTargetSession = Get-AgentSessionId -AgentRecord $liveTargetAgent
        if ([string]$targetPane.tab_id -ne $requesterTab -or
            [string]$liveTargetAgent.agent -ne $requesterAgent -or
            $liveTargetSession -ne $requesterSession) {
            throw ('Requesting pane {0} no longer hosts the naming request native session.' -f $targetPaneId)
        }
        if (-not [string]::IsNullOrWhiteSpace($RequiredTargetSession) -and $RequiredTargetSession -ne $requesterSession) {
            throw 'Explicit target session conflicts with the naming request requester session.'
        }
        $RequiredTargetSession = $requesterSession
    }
    $targetTabId = [string]$targetPane.tab_id
    $liveLabel = ([string](Invoke-HerdrJson -Arguments @("tab", "get", $targetTabId)).result.tab.label `
            -replace "[\x00-\x1f\x7f]+", " " -replace "\s+", " ").Trim()
    $expectedCurrentLabel = if (-not [string]::IsNullOrWhiteSpace($OverrideExpectedCurrentLabel)) {
        $OverrideExpectedCurrentLabel
    }
    else {
        $liveLabel
    }

    $canonicalName = if (-not [string]::IsNullOrWhiteSpace($OverrideCanonicalName)) {
        $OverrideCanonicalName
    }
    else {
        Resolve-NamingCanonicalName `
            -Prefix (Get-NamingCanonicalPrefix -Fields $fields) `
            -CurrentLabel $liveLabel `
            -TargetTabId $targetTabId `
            -LiveTabs (Get-LiveTabLabels)
    }

    $intentTargetAgent = (Invoke-HerdrJson -Arguments @('agent', 'get', $targetPaneId)).result.agent
    $intentTargetSession = Get-AgentSessionId -AgentRecord $intentTargetAgent
    if ([string]::IsNullOrWhiteSpace($intentTargetSession)) {
        throw 'Target pane lacks stable native session proof before naming mutation.'
    }
    $null = Add-NamingApplyIntent -Path $LogPath -RelayRef $RelayRef -Relay $relayRecord -CoordinatorPaneId $CoordinatorPaneId -TargetPane $targetPane -TargetSession $intentTargetSession

    $applied = Invoke-CoordinatorApplyName `
        -CoordinatorPaneId $CoordinatorPaneId `
        -TargetPaneId $targetPaneId `
        -CanonicalName $canonicalName `
        -Subtitle $subtitle `
        -ExpectedCurrentLabel $expectedCurrentLabel `
        -RequiredTargetSession $RequiredTargetSession
    $proof = Add-NamingAppliedProof `
        -Path $LogPath `
        -RelayRef $RelayRef `
        -Relay $relayRecord `
        -Applied $applied

    return [pscustomobject]@{
        relay_ref = $RelayRef
        applied = $true
        duplicate = $false
        state = "applied"
        proof = $proof
        coordinator_pane_id = [string]$applied.coordinator_pane_id
        coordinator_session = [string]$applied.coordinator_session
        target_pane_id = [string]$applied.target_pane_id
        target_session = [string]$applied.target_session
        tab_id = [string]$applied.tab_id
        tab_label = [string]$applied.tab_label
        pane_label = [string]$applied.pane_label
        title = [string]$applied.title
        display_agent = [string]$applied.display_agent
    }
}

$sender = if ([string]::IsNullOrWhiteSpace($From)) { "external" } else { $From }

switch ($Action) {
    "discover" {
        $discovery = Find-Coordinator -Label $TabLabel
        [pscustomobject]@{
            action = "discover"
            log_path = $LogPath
            found = $discovery.found
            ambiguous = $discovery.ambiguous
            coordinator = $discovery.coordinator
            candidates = $discovery.candidates
        } | ConvertTo-Json -Depth 10
    }
    "init" {
        $initMutex = Enter-CoordinationAckMutex -Path $LogPath
        try {
            Initialize-CoordinationLog -Path $LogPath
        }
        finally {
            Exit-CoordinationAckMutex -Mutex $initMutex
        }
        [pscustomobject]@{
            action = "init"
            log_path = $LogPath
            exists = Test-Path -LiteralPath $LogPath
        } | ConvertTo-Json -Depth 5
    }
    "append" {
        if ([string]::IsNullOrWhiteSpace($Message)) {
            throw "-Message is required for append."
        }
        $normalizedAppendMessage = ($Message -replace "[\r\n]+", " ").Trim()
        if ($normalizedAppendMessage -match '^\[(?:HA|HN|HD|HI):[0-9a-fA-F]{8}\](?:\s|$)' -or
            $normalizedAppendMessage -match '\[(?:APPLIED|DISPOSED|APPLY-STARTED) re \[HR:[0-9a-fA-F]{8}\]\]' -or
            ($normalizedAppendMessage -match '^\[HR:[0-9a-fA-F]{8}\](?:\s|$)' -and
                $normalizedAppendMessage -match '\[(?:REISSUE-OF|RECIPIENT-SESSION|PAYLOAD-SHA256)\s')) {
            throw "append refuses receipt or lineage-bearing protocol entries; use the proof-bound send, ack-read, or apply-name action."
        }
        $entry = Add-CoordinationEntry -Path $LogPath -Sender $sender -Recipient $To -Body $Message
        [pscustomobject]@{
            action = "append"
            log_path = $LogPath
            entry = $entry
        } | ConvertTo-Json -Depth 5
    }
    "deliver" {
        if ([string]::IsNullOrWhiteSpace($PaneId)) {
            throw "-PaneId is required for deliver."
        }
        if ([string]::IsNullOrWhiteSpace($Message)) {
            throw "-Message is required for deliver."
        }

        $registryBinding = $null
        $deliveryPaneId = $PaneId
        $deliveryAgent = $ExpectedAgent
        $deliverySession = $ExpectedSession
        $deliveryTabLabel = $ExpectedTabLabel
        $deliveryTabId = $ExpectedTabId
        if ($PaneId -match '^@pane\[[^\]]+\]$') {
            $registryBinding = Resolve-PaneRegistryReference -Reference $PaneId
            $deliveryPaneId = [string]$registryBinding.pane_id
            $deliveryAgent = [string]$registryBinding.agent
            $deliverySession = [string]$registryBinding.agent_session
            $deliveryTabLabel = [string]$registryBinding.tab_label
            if ([string]::IsNullOrWhiteSpace($deliveryTabId)) {
                $deliveryTabId = [string]$registryBinding.tab_id
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedRegistryId) -and $ExpectedRegistryId -ne [string]$registryBinding.registry_id) {
                throw "Resolved registry ID does not match -ExpectedRegistryId."
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedBindingId) -and $ExpectedBindingId -ne [string]$registryBinding.binding_id) {
                throw "Resolved binding ID does not match -ExpectedBindingId."
            }
            if ($ExpectedGeneration -ge 1 -and $ExpectedGeneration -ne [long]$registryBinding.generation) {
                throw "Resolved generation does not match -ExpectedGeneration."
            }
            $null = Assert-PaneRegistryReference -Binding $registryBinding
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ExpectedRegistryId) -or
            -not [string]::IsNullOrWhiteSpace($ExpectedBindingId) -or
            -not [string]::IsNullOrWhiteSpace($ExpectedRegistryName) -or
            $ExpectedGeneration -ge 1) {
            if ([string]::IsNullOrWhiteSpace($ExpectedRegistryId) -or
                [string]::IsNullOrWhiteSpace($ExpectedBindingId) -or
                [string]::IsNullOrWhiteSpace($ExpectedRegistryName) -or
                $ExpectedGeneration -lt 1) {
                throw "Explicit registry-bound delivery requires the complete expected registry tuple."
            }
            $registryBinding = Resolve-PaneRegistryReference -Reference "@pane[$ExpectedRegistryName]"
            if ([string]$registryBinding.pane_id -ne $deliveryPaneId -or
                [string]$registryBinding.registry_id -ne $ExpectedRegistryId -or
                [string]$registryBinding.binding_id -ne $ExpectedBindingId -or
                [long]$registryBinding.generation -ne $ExpectedGeneration) {
                throw "Explicit delivery no longer matches the expected registry binding."
            }
            $deliveryAgent = [string]$registryBinding.agent
            $deliverySession = [string]$registryBinding.agent_session
            $deliveryTabLabel = [string]$registryBinding.tab_label
            if ([string]::IsNullOrWhiteSpace($deliveryTabId)) {
                $deliveryTabId = [string]$registryBinding.tab_id
            }
            $null = Assert-PaneRegistryReference -Binding $registryBinding
        }

        $delivery = Send-VerifiedPaneMessage `
            -TargetPaneId $deliveryPaneId `
            -Body $Message `
            -SenderPaneId $sender `
            -RequiredAgent $deliveryAgent `
            -RequiredSession $deliverySession `
            -RequiredTabLabel $deliveryTabLabel `
            -RequiredTabId $deliveryTabId
        [pscustomobject]@{
            action = "deliver"
            registry_binding = $registryBinding
            delivery = $delivery
        } | ConvertTo-Json -Depth 8
    }
    "name-request" {
        if ([string]::IsNullOrWhiteSpace($RepoCode) -or
            [string]::IsNullOrWhiteSpace($LaneCode) -or
            [string]::IsNullOrWhiteSpace($RoleCode) -or
            [string]::IsNullOrWhiteSpace($WorkKind)) {
            throw "name-request requires -RepoCode, -LaneCode, -RoleCode, and -WorkKind."
        }
        if ($RoleCode -notmatch '^[A-Z]$') {
            throw "-RoleCode must be one uppercase role letter (for example O or R)."
        }
        if ($WorkKind -eq "issue" -or $WorkKind -eq "pr") {
            if ([string]::IsNullOrWhiteSpace($IssueNumber) -or
                $IssueNumber -notmatch '^(?:PR#?)?\d+$' -or
                [string]::IsNullOrWhiteSpace($WorkTitle)) {
                throw "Issue/PR name-request requires a numeric -IssueNumber and non-empty -WorkTitle."
            }
        }
        elseif ($WorkKind -eq "no-issue" -and [string]::IsNullOrWhiteSpace($WorkTitle)) {
            throw "No-issue name-request requires -WorkTitle."
        }
        elseif ($WorkKind -eq "explore" -and [string]::IsNullOrWhiteSpace($Topic)) {
            throw "Explore name-request requires -Topic."
        }
        if ($NamingLifecycle -eq 'retirement' -and
            ([string]::IsNullOrWhiteSpace($PreviousName) -or
                $PreviousName -notmatch '^(?:STM|AGT|Hdr|Buzz)-[A-Z][A-Z0-9]*-[A-Z][0-9]+$' -or
                [string]::IsNullOrWhiteSpace($PreviousWork))) {
            throw 'Retirement name-request requires a valid -PreviousName and non-empty -PreviousWork.'
        }

        foreach ($value in @($WorkTitle, $Topic, $PreviousName, $PreviousWork)) {
            if ($null -ne $value -and $value -match '[\r\n]') {
                throw "name-request fields cannot contain newlines."
            }
        }
        $requesterProof = Get-NamingRequesterProof -SenderPaneId $sender
        $requestParts = [Collections.Generic.List[string]]::new()
        $requestParts.Add("PANE NAMING REQUEST: repo=$RepoCode")
        $requestParts.Add('lifecycle={0}' -f $NamingLifecycle)
        $requestParts.Add('requester_pane={0}' -f $requesterProof.pane_id)
        $requestParts.Add('requester_tab={0}' -f $requesterProof.tab_id)
        $requestParts.Add('requester_agent={0}' -f $requesterProof.agent)
        $requestParts.Add('requester_session={0}' -f $requesterProof.session)
        $requestParts.Add("lane=$LaneCode")
        $requestParts.Add("role=$RoleCode")
        $requestParts.Add("work=$WorkKind")
        if (-not [string]::IsNullOrWhiteSpace($IssueNumber)) {
            $normalizedIssue = if ($IssueNumber -match '^PR') { "PR#$([regex]::Match($IssueNumber, '\d+').Value)" } else { "#$($IssueNumber.TrimStart('#'))" }
            $requestParts.Add("issue=$normalizedIssue")
        }
        if (-not [string]::IsNullOrWhiteSpace($WorkTitle)) {
            # Subtitles render as "#<n> · <title>", so a ticket token inside the title doubles
            # ("#883 · #883 - ..."). Strip leading ticket tokens; keep the original if that
            # would empty the title (a token-only title still satisfies the non-empty contract).
            $cleanTitle = $WorkTitle.Trim()
            while ($cleanTitle -match '^(?:PR#?\d+|#\d+)[\s\-·:]+') {
                $cleanTitle = ($cleanTitle -replace '^(?:PR#?\d+|#\d+)[\s\-·:]+', '').Trim()
            }
            if ([string]::IsNullOrWhiteSpace($cleanTitle)) { $cleanTitle = $WorkTitle.Trim() }
            $requestParts.Add("title=$cleanTitle")
        }
        if (-not [string]::IsNullOrWhiteSpace($Topic)) { $requestParts.Add("topic=$($Topic.Trim())") }
        if (-not [string]::IsNullOrWhiteSpace($PreviousName)) { $requestParts.Add("previous_name=$($PreviousName.Trim())") }
        if (-not [string]::IsNullOrWhiteSpace($PreviousWork)) { $requestParts.Add("previous_work=$($PreviousWork.Trim())") }
        $requestParts.Add("coordinator_action=apply-name-and-return-proof")
        $requestParts.Add("coordinator_command=consume-name-requests")
        $requestParts.Add("routing_gate=continue-by-stable-pane-id-while-pending")
        if ($NamingLifecycle -eq 'retirement') {
            $requestParts.Add('close_gate=wait-for-applied-or-retirement_target_gone')
        }
        $requestMessage = $requestParts -join "; "
        $sendOutput = & $PSCommandPath `
            -Action send `
            -From $From `
            -To "coordinator" `
            -Message $requestMessage `
            -TabLabel $TabLabel `
            -ExpectedAgent $ExpectedAgent `
            -ExpectedSession $ExpectedSession `
            -WatchTimeoutMs $WatchTimeoutMs `
            -EarlyAlertMs $EarlyAlertMs `
            -LogPath $LogPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "name-request delivery failed: $($sendOutput -join [Environment]::NewLine)"
        }
        $sendResult = ($sendOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 32
        [pscustomobject]@{
            action = "name-request"
            request = $requestMessage
            relay = $sendResult
        } | ConvertTo-Json -Depth 32
    }
    "apply-name" {
        $coordinatorPaneId = Get-CoordinatorPaneId -Label $TabLabel
        Assert-CoordinatorCaller -CoordinatorPaneId $coordinatorPaneId

        if ([string]::IsNullOrWhiteSpace($RelayRef)) {
            if ([string]::IsNullOrWhiteSpace($PaneId) -or
                [string]::IsNullOrWhiteSpace($CanonicalName) -or
                [string]::IsNullOrWhiteSpace($Subtitle) -or
                [string]::IsNullOrWhiteSpace($ExpectedCurrentLabel)) {
                throw "apply-name requires -PaneId, -CanonicalName, -Subtitle, and -ExpectedCurrentLabel."
            }
            $applied = Invoke-CoordinatorApplyName `
                -CoordinatorPaneId $coordinatorPaneId `
                -TargetPaneId $PaneId `
                -CanonicalName $CanonicalName `
                -Subtitle $Subtitle `
                -ExpectedCurrentLabel $ExpectedCurrentLabel `
                -RequiredTargetSession $ExpectedTargetSession
            [pscustomobject]@{
                action = "apply-name"
                applied = $true
                relay_ref = $null
                duplicate = $false
                proof = $null
                coordinator_pane_id = $applied.coordinator_pane_id
                coordinator_session = $applied.coordinator_session
                target_pane_id = $applied.target_pane_id
                target_session = $applied.target_session
                tab_id = $applied.tab_id
                tab_label = $applied.tab_label
                pane_label = $applied.pane_label
                title = $applied.title
                display_agent = $applied.display_agent
            } | ConvertTo-Json -Depth 16
            break
        }

        # Relay-bound application: the request itself supplies the target pane,
        # and completion is only real once the APPLIED proof is on the log.
        $applyMutex = Enter-CoordinationAckMutex -Path $LogPath
        try {
            $result = Invoke-NamingRequestConsumption `
                -RelayRef $RelayRef `
                -CoordinatorPaneId $coordinatorPaneId `
                -OverrideCanonicalName $CanonicalName `
                -OverrideSubtitle $Subtitle `
                -OverrideExpectedCurrentLabel $ExpectedCurrentLabel `
                -RequiredTargetSession $ExpectedTargetSession
        }
        finally {
            Exit-CoordinationAckMutex -Mutex $applyMutex
        }
        [pscustomobject]@{
            action = "apply-name"
            applied = [bool]$result.applied
            relay_ref = [string]$result.relay_ref
            duplicate = [bool]$result.duplicate
            state = [string]$result.state
            terminal = $result.PSObject.Properties['terminal'] -and [bool]$result.terminal
            proof = $result.proof
            coordinator_pane_id = $result.coordinator_pane_id
            coordinator_session = $result.coordinator_session
            target_pane_id = $result.target_pane_id
            target_session = $result.target_session
            tab_id = $result.tab_id
            tab_label = $result.tab_label
            pane_label = $result.pane_label
            title = $result.title
            display_agent = $result.display_agent
        } | ConvertTo-Json -Depth 16
    }
    "consume-name-requests" {
        $coordinatorPaneId = Get-CoordinatorPaneId -Label $TabLabel
        Assert-CoordinatorCaller -CoordinatorPaneId $coordinatorPaneId

        $consumeMutex = Enter-CoordinationAckMutex -Path $LogPath
        try {
            $records = @(Get-CoordinationLogRecords -Path $LogPath)
            $scan = Get-NamingRequestRelays -Records $records -MaxRequests $MaxNamingRequests
            $candidates = @($scan.relays | Where-Object { [string]$_.recipient_pane_id -eq $coordinatorPaneId })
            if (-not [string]::IsNullOrWhiteSpace($RelayRef)) {
                Assert-RelayReference -Reference $RelayRef
                $candidates = @($candidates | Where-Object { [string]$_.relay_ref -eq $RelayRef })
                if ($candidates.Count -ne 1) {
                    throw "Relay $RelayRef is not an outstanding PANE NAMING REQUEST addressed to $coordinatorPaneId."
                }
            }
            else {
                # Ordinary sweeps only process outstanding work. Terminal
                # records remain addressable explicitly for idempotent retries.
                $candidates = @($candidates | Where-Object {
                        @(Get-ValidNamingAppliedProofs -Path $LogPath -Relay $_ -Records $records).Count -eq 0 -and
                        @(Get-ValidNamingDispositionProofs -Path $LogPath -Relay $_ -Records $records).Count -eq 0
                    })
            }
            # Newest first: a pane may have several redirects queued.  Apply
            # only the newest request for each target; older requests must not
            # overwrite the current subtitle or fail verification after the
            # newer request has established the pane's metadata.
            $candidates = @($candidates | Sort-Object {
                    try { [DateTimeOffset]::Parse([string]$_.stamp) } catch { [DateTimeOffset]::MinValue }
                } -Descending)

            $processed = @()
            $failures = @()
            $seenTargetPanes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($relay in $candidates) {
                try {
                    $targetPaneForOrdering = [string]$relay.sender
                    if (-not $seenTargetPanes.Add($targetPaneForOrdering)) {
                        $processed += [pscustomobject]@{
                            relay_ref = [string]$relay.relay_ref
                            applied = $false
                            duplicate = $true
                            state = "superseded_by_newer_request"
                            proof = $null
                            coordinator_pane_id = $coordinatorPaneId
                            coordinator_session = $null
                            target_pane_id = $targetPaneForOrdering
                            target_session = $null
                            tab_id = $null
                            tab_label = $null
                            title = $null
                            display_agent = $null
                        }
                        continue
                    }
                    $processed += Invoke-NamingRequestConsumption `
                        -RelayRef ([string]$relay.relay_ref) `
                        -CoordinatorPaneId $coordinatorPaneId `
                        -Relay $relay `
                        -Records $records
                }
                catch {
                    if (-not [string]::IsNullOrWhiteSpace($RelayRef)) {
                        throw
                    }
                    $failures += [pscustomobject]@{
                        relay_ref = [string]$relay.relay_ref
                        requesting_pane_id = [string]$relay.sender
                        error = $_.Exception.Message
                    }
                }
            }
        }
        finally {
            Exit-CoordinationAckMutex -Mutex $consumeMutex
        }

        [pscustomobject]@{
            action = "consume-name-requests"
            log_path = $LogPath
            coordinator_pane_id = $coordinatorPaneId
            examined = $candidates.Count
            applied_count = @($processed | Where-Object { [bool]$_.applied -and -not [bool]$_.duplicate }).Count
            terminal_count = @($processed | Where-Object { [string]$_.state -eq 'retirement_target_gone' -and -not [bool]$_.duplicate }).Count
            duplicate_count = @($processed | Where-Object { [bool]$_.duplicate }).Count
            skipped_count = @($processed | Where-Object { -not [bool]$_.applied }).Count
            failed_count = $failures.Count
            truncated = [bool]$scan.truncated
            ambiguous_relay_refs = @($scan.ambiguous_relay_refs)
            results = @($processed)
            failures = @($failures)
        } | ConvertTo-Json -Depth 16
        if ($failures.Count -gt 0) {
            throw "consume-name-requests could not complete $($failures.Count) naming request(s): $(($failures | ForEach-Object { "$($_.relay_ref) $($_.error)" }) -join ' | ')"
        }
    }
    "naming-status" {
        # Read-only watchdog: it never touches Herdr, so any pane can run it and
        # a stalled coordinator cannot suppress the alarm.
        $records = @(Get-CoordinationLogRecords -Path $LogPath)
        $scan = Get-NamingRequestRelays -Records $records -MaxRequests $MaxNamingRequests
        $relays = @($scan.relays)
        if (-not [string]::IsNullOrWhiteSpace($RelayRef)) {
            Assert-RelayReference -Reference $RelayRef
            $relays = @($relays | Where-Object { [string]$_.relay_ref -eq $RelayRef })
            if ($relays.Count -ne 1) {
                throw "Relay $RelayRef was not found as a PANE NAMING REQUEST in $LogPath."
            }
        }
        $requests = @(
            $relays | ForEach-Object {
                Get-NamingRequestState `
                    -Path $LogPath `
                    -Relay $_ `
                    -DeadlineSeconds $NamingDeadlineSeconds `
                    -Records $records
            }
        )
        # A pane can legitimately have several redirects in the append-only
        # log.  Once a newer request for that same pane has an APPLIED proof,
        # older unapplied requests are superseded—not overdue—and must not
        # keep the watchdog red forever.
        $completedByPane = @{}
        foreach ($completedRequest in @($requests | Where-Object { $_.state -in @('applied', 'retirement_target_gone') })) {
            $paneKey = [string]$completedRequest.requesting_pane_id
            if (-not $completedByPane.ContainsKey($paneKey)) {
                $completedByPane[$paneKey] = @()
            }
            $completedByPane[$paneKey] += $completedRequest
        }
        foreach ($request in $requests) {
            if ($request.state -in @('applied', 'retirement_target_gone') -or
                -not $completedByPane.ContainsKey([string]$request.requesting_pane_id)) {
                continue
            }
            $newer = @($completedByPane[[string]$request.requesting_pane_id] | Where-Object {
                    [string]$_.request_stamp -gt [string]$request.request_stamp
                } | Sort-Object request_stamp -Descending | Select-Object -First 1)
            if ($newer.Count -gt 0) {
                $request.state = "superseded"
                $request.overdue = $false
                $request.overdue_by_seconds = $null
                $request | Add-Member -NotePropertyName superseded_by_relay_ref -NotePropertyValue ([string]$newer[0].relay_ref) -Force
            }
        }
        $overdue = @($requests | Where-Object { [bool]$_.overdue })
        [pscustomobject]@{
            action = "naming-status"
            log_path = $LogPath
            deadline_seconds = $NamingDeadlineSeconds
            examined = $requests.Count
            truncated = [bool]$scan.truncated
            ambiguous_relay_refs = @($scan.ambiguous_relay_refs)
            applied_count = @($requests | Where-Object { $_.state -eq "applied" }).Count
            terminal_count = @($requests | Where-Object { $_.state -eq 'retirement_target_gone' }).Count
            uncertain_count = @($requests | Where-Object { $_.state -eq 'uncertain_apply' }).Count
            reconciliation_required_count = @($requests | Where-Object { $_.state -eq 'reconciliation_required' }).Count
            awaiting_read_ack_count = @($requests | Where-Object { $_.state -eq "awaiting_read_ack" }).Count
            read_acked_unapplied_count = @($requests | Where-Object { $_.state -eq "read_acked_unapplied" }).Count
            superseded_count = @($requests | Where-Object { $_.state -eq "superseded" }).Count
            overdue_count = $overdue.Count
            overdue = $overdue.Count -gt 0
            overdue_relay_refs = @($overdue | ForEach-Object { [string]$_.relay_ref })
            requests = $requests
        } | ConvertTo-Json -Depth 16
    }
    "send" {
        if ([string]::IsNullOrWhiteSpace($Message)) {
            throw "-Message is required for send."
        }
        $recipientIsCoordinator = $To -eq "coordinator"
        $recipientIsRegistry = $To -match '^@pane\[[^\]]+\]$'
        $recipientIsPane = $To -match "^w[^:\s]+:p[^\s,]+$"
        if (-not $recipientIsCoordinator -and -not $recipientIsPane -and -not $recipientIsRegistry) {
            throw "send requires -To coordinator, @pane[NAME], or an explicit pane ID; use append for log-only recipients such as ALL."
        }

        $delivered = $false
        $delivery = $null
        $reason = $null
        $paneId = $null
        $coordinatorPaneId = $null
        $requiredTargetLabel = $null
        $recipientSession = $null
        $recipientAgent = $null
        $recipientTabId = $null
        $recipientTabLabel = $null
        $registryBinding = $null
        if ($recipientIsRegistry) {
            $registryBinding = Resolve-PaneRegistryReference -Reference $To
            $paneId = [string]$registryBinding.pane_id
            $requiredTargetLabel = [string]$registryBinding.tab_label
            $recipientTabId = [string]$registryBinding.tab_id
            $recipientTabLabel = [string]$registryBinding.tab_label
            $recipientAgent = [string]$registryBinding.agent
            $recipientSession = [string]$registryBinding.agent_session
            $recipientSessionAgent = $recipientAgent
            if (-not [string]::IsNullOrWhiteSpace($ExpectedRegistryId) -and $ExpectedRegistryId -ne [string]$registryBinding.registry_id) {
                throw "Resolved registry ID does not match -ExpectedRegistryId."
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedBindingId) -and $ExpectedBindingId -ne [string]$registryBinding.binding_id) {
                throw "Resolved binding ID does not match -ExpectedBindingId."
            }
            if ($ExpectedGeneration -ge 1 -and $ExpectedGeneration -ne [long]$registryBinding.generation) {
                throw "Resolved generation does not match -ExpectedGeneration."
            }
        }
        elseif ($recipientIsPane) {
            $paneId = $To
            $hasExpectedRegistryTuple = -not [string]::IsNullOrWhiteSpace($ExpectedRegistryId) -or
                -not [string]::IsNullOrWhiteSpace($ExpectedBindingId) -or
                -not [string]::IsNullOrWhiteSpace($ExpectedRegistryName) -or
                $ExpectedGeneration -ge 1
            if ($hasExpectedRegistryTuple) {
                if ([string]::IsNullOrWhiteSpace($ExpectedRegistryId) -or
                    [string]::IsNullOrWhiteSpace($ExpectedBindingId) -or
                    [string]::IsNullOrWhiteSpace($ExpectedRegistryName) -or
                    $ExpectedGeneration -lt 1) {
                    throw "Explicit registry-bound send requires the complete expected registry tuple."
                }
                $registryBinding = Resolve-PaneRegistryReference -Reference "@pane[$ExpectedRegistryName]"
                if ([string]$registryBinding.pane_id -ne $paneId -or
                    [string]$registryBinding.registry_id -ne $ExpectedRegistryId -or
                    [string]$registryBinding.binding_id -ne $ExpectedBindingId -or
                    [long]$registryBinding.generation -ne $ExpectedGeneration) {
                    throw "Explicit send no longer matches the expected registry binding."
                }
                $ExpectedTabLabel = [string]$registryBinding.tab_label
                $ExpectedAgent = [string]$registryBinding.agent
                $ExpectedSession = [string]$registryBinding.agent_session
            }
            if ([string]::IsNullOrWhiteSpace($ExpectedTabLabel)) {
                throw "-ExpectedTabLabel is required for an explicit-pane send."
            }
            $beforeLabelResponse = Invoke-HerdrJson -Arguments @("pane", "get", $paneId)
            $beforeLabelPane = $beforeLabelResponse.result.pane
            $recipientLabelProof = Assert-PaneTabLabel `
                -TargetPaneId $paneId `
                -PaneRecord $beforeLabelPane `
                -RequiredTabLabel $ExpectedTabLabel
            $requiredTargetLabel = $ExpectedTabLabel
            $recipientTabId = [string]$recipientLabelProof.tab_id
            $recipientTabLabel = [string]$recipientLabelProof.tab_label
            if (-not [string]::IsNullOrWhiteSpace($ExpectedTabId) -and
                $recipientTabId -cne $ExpectedTabId) {
                throw "Explicit send expected tab ID $ExpectedTabId but observed $recipientTabId."
            }
            $recipientAgent = [string]$beforeLabelPane.agent
            $recipientSession = Get-AgentSessionId -AgentRecord $beforeLabelPane
            $recipientSessionAgent = Get-AgentSessionAgent -AgentRecord $beforeLabelPane
        }
        else {
            $discovery = Find-Coordinator -Label $TabLabel
            if (-not $discovery.found) {
                $reason = "coordination tab not found"
            }
            elseif ($discovery.ambiguous) {
                $reason = "coordination tab or pane is ambiguous"
            }
            else {
                $paneId = [string]$discovery.coordinator.pane_id
                $coordinatorPaneId = $paneId
                $requiredTargetLabel = $TabLabel
                $coordinatorPaneResponse = Invoke-HerdrJson -Arguments @("pane", "get", $paneId)
                $coordinatorPane = $coordinatorPaneResponse.result.pane
                $recipientLabelProof = Assert-PaneTabLabel `
                    -TargetPaneId $paneId `
                    -PaneRecord $coordinatorPane `
                    -RequiredTabLabel $TabLabel
                $recipientTabId = [string]$recipientLabelProof.tab_id
                $recipientTabLabel = [string]$recipientLabelProof.tab_label
                $recipientAgent = [string]$coordinatorPane.agent
                $recipientSession = Get-AgentSessionId -AgentRecord $coordinatorPane
                $recipientSessionAgent = Get-AgentSessionAgent -AgentRecord $coordinatorPane
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($paneId)) {
            if ([string]::IsNullOrWhiteSpace($recipientAgent) -or
                [string]::IsNullOrWhiteSpace($recipientSession) -or
                $recipientSessionAgent -ne $recipientAgent) {
                throw "send requires stable native agent-session proof for the exact recipient pane before creating a relay."
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedAgent) -and
                $recipientAgent -ne $ExpectedAgent) {
                throw "Target pane $paneId no longer contains the expected $ExpectedAgent agent."
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedSession) -and
                $recipientSession -ne $ExpectedSession) {
                throw "Target pane $paneId no longer hosts the expected native agent session."
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($WorkflowRef) -and
            $WorkflowRef -notmatch '^\[WF:[0-9a-fA-F]{8}\]$') {
            throw "-WorkflowRef must have the exact form [WF:xxxxxxxx] when supplied to send."
        }

        $relayRef = "[HR:$([Guid]::NewGuid().ToString('N').Substring(0, 8))]"
        $recipientPaneMetadata = if ([string]::IsNullOrWhiteSpace($paneId)) { "unresolved" } else { $paneId }
        $recipientSessionMetadata = if ([string]::IsNullOrWhiteSpace($recipientSession)) { "unresolved" } else { $recipientSession }
        $recipientAgentMetadata = if ([string]::IsNullOrWhiteSpace($recipientAgent)) { "unresolved" } else { $recipientAgent }
        $recipientTabMetadata = if ([string]::IsNullOrWhiteSpace($recipientTabId)) { "unresolved" } else { $recipientTabId }
        $recipientLabelMetadata = if ([string]::IsNullOrWhiteSpace($recipientTabLabel)) {
            ConvertTo-CoordinationMetadataBase64 -Text "unresolved"
        }
        else {
            ConvertTo-CoordinationMetadataBase64 -Text $recipientTabLabel
        }
        $registryEnvelope = if ($null -ne $registryBinding) {
            "[REGISTRY-ID $($registryBinding.registry_id)] [REGISTRY-BINDING $($registryBinding.binding_id)] [REGISTRY-NAME-B64 $(ConvertTo-CoordinationMetadataBase64 -Text ([string]$registryBinding.canonical_name))] [REGISTRY-GENERATION $($registryBinding.generation)] "
        }
        else {
            ""
        }
        $durableMessage = ($registryEnvelope + ((Add-PaneLabelsToMessage -Text $Message) -replace "[\r\n]+", " ").Trim()).Trim()
        if ([string]::IsNullOrWhiteSpace($durableMessage)) {
            throw "Message cannot be empty after durable relay normalization."
        }
        $payloadSha256 = Get-CoordinationTextSha256 -Text $durableMessage
        $logRecipient = if ($recipientIsRegistry) { $paneId } else { $To }
        $entry = Add-CoordinationEntry `
            -Path $LogPath `
            -Sender $sender `
            -Recipient $logRecipient `
            -Body "$relayRef [RECIPIENT-PANE $recipientPaneMetadata] [RECIPIENT-SESSION $recipientSessionMetadata] [RECIPIENT-AGENT $recipientAgentMetadata] [RECIPIENT-TAB $recipientTabMetadata] [RECIPIENT-LABEL-B64 $recipientLabelMetadata] [PAYLOAD-SHA256 $payloadSha256] $durableMessage"
        if (-not [string]::IsNullOrWhiteSpace($WorkflowRef)) {
            $workflowHelperPath = Join-Path $PSScriptRoot "herdr_workflow.ps1"
            $ackCommand = "& '$workflowHelperPath' -Action ack-return -WorkflowRef '$WorkflowRef' -LedgerPath '$WorkflowLedgerPath' -CoordinationLogPath '$LogPath'"
        }
        else {
            $ackCommand = "& '$PSCommandPath' -Action ack-read -RelayRef '$relayRef' -ExpectedSession '$recipientSessionMetadata' -LogPath '$LogPath'"
        }
        if (-not [string]::IsNullOrWhiteSpace($paneId)) {
            if ($paneId -eq $sender) {
                $reason = "sender is the recipient; log entry recorded"
            }
            else {
                if ($null -ne $registryBinding) {
                    $null = Assert-PaneRegistryReference -Binding $registryBinding
                }
                $deliveryText = "COORDINATION LOG NOTICE $relayRef. Read the exact matching entry in $LogPath from $sender to $logRecipient, then prove body consumption with: $ackCommand"
                if ($Message.StartsWith($NamingRequestMarker, [StringComparison]::Ordinal)) {
                    $consumeCommand = "& '$PSCommandPath' -Action consume-name-requests -LogPath '$LogPath'"
                    $deliveryText += " Coordinator action required: after the read-ACK, run exactly: $consumeCommand; do not stop at ACK."
                }
                $delivery = Send-VerifiedPaneMessage `
                    -TargetPaneId $paneId `
                    -Body $deliveryText `
                    -SenderPaneId $sender `
                    -RequiredAgent $(if ($recipientIsPane) { $ExpectedAgent } elseif ($recipientIsRegistry) { $recipientAgent } else { $null }) `
                    -RequiredSession $(if ($recipientIsPane) { $ExpectedSession } elseif ($recipientIsRegistry) { $recipientSession } else { $null }) `
                    -RequiredTabLabel $requiredTargetLabel `
                    -RequiredTabId $recipientTabId
                $delivered = [bool]$delivery.submitted
                if (-not $delivered) {
                    $reason = "agent prompt delivery failed: $($delivery.error)"
                }
            }
        }

        [pscustomobject]@{
            action = "send"
            relay_ref = $relayRef
            log_path = $LogPath
            entry = $entry
            coordinator_pane_id = $coordinatorPaneId
            recipient_pane_id = $paneId
            recipient_session = $recipientSession
            registry_binding = $registryBinding
            recipient_display = if ($paneId) {
                Get-PaneRouteDisplay -RoutePaneId $paneId
            }
            else {
                $To
            }
            delivered = $delivered
            delivery_scope = "pointer_only"
            notice_submitted = $delivered
            body_read = $false
            read_ack_required = $true
            read_ack_ref = $null
            read_ack_command = $ackCommand
            delivery = $delivery
            reason = $reason
        } | ConvertTo-Json -Depth 8
    }
    "relay-status" {
        if ([string]::IsNullOrWhiteSpace($RelayRef)) {
            throw "-RelayRef is required for relay-status."
        }
        $relay = Get-RelayRecord -Path $LogPath -Reference $RelayRef
        $acks = @(Get-RelayReadAcks -Path $LogPath -Reference $RelayRef)
        $validAcks = @(Get-ValidRelayReadAcks -Path $LogPath -Relay $relay)
        $conflictingAcks = @($acks | Where-Object { -not (Test-RelayReadAck -Relay $relay -Ack $_) })
        if ($validAcks.Count -gt 1) {
            throw "Relay $RelayRef has multiple valid read acknowledgements and requires reconciliation."
        }
        $lineage = Get-RelayLineage -Path $LogPath -Relay $relay
        $effectiveRelay = $lineage.effective_relay
        $effectiveAcks = @(Get-RelayReadAcks -Path $LogPath -Reference ([string]$effectiveRelay.relay_ref))
        $validEffectiveAcks = @(Get-ValidRelayReadAcks -Path $LogPath -Relay $effectiveRelay)
        $conflictingEffectiveAcks = @($effectiveAcks | Where-Object { -not (Test-RelayReadAck -Relay $effectiveRelay -Ack $_) })
        if ($validEffectiveAcks.Count -gt 1) {
            throw "Relay $($effectiveRelay.relay_ref) has multiple valid read acknowledgements and requires reconciliation."
        }
        [pscustomobject]@{
            action = "relay-status"
            relay_ref = $RelayRef
            delivery_scope = "pointer_only"
            recipient_pane_id = $relay.recipient_pane_id
            body_read = $validAcks.Count -eq 1
            read_ack = if ($validAcks.Count -eq 1) { $validAcks[0] } else { $null }
            conflicting_ack_count = $conflictingAcks.Count
            superseded = @($lineage.replacements).Count -gt 0
            replacement_relay_refs = @($lineage.replacements | ForEach-Object { $_.relay_ref })
            effective_relay_ref = [string]$effectiveRelay.relay_ref
            effective_body_read = $validEffectiveAcks.Count -eq 1
            effective_read_ack = if ($validEffectiveAcks.Count -eq 1) { $validEffectiveAcks[0] } else { $null }
            effective_conflicting_ack_count = $conflictingEffectiveAcks.Count
            relay = [pscustomobject]@{
                sender = [string]$relay.sender
                recipient = [string]$relay.recipient
                recipient_pane_id = [string]$relay.recipient_pane_id
                recipient_session = [string]$relay.recipient_session
            }
        } | ConvertTo-Json -Depth 8
    }
    "prove-caller" {
        if ([string]::IsNullOrWhiteSpace($PaneId) -or
            [string]::IsNullOrWhiteSpace($ExpectedAgent) -or
            [string]::IsNullOrWhiteSpace($ExpectedSession)) {
            throw "-PaneId, -ExpectedAgent, and -ExpectedSession are required for prove-caller."
        }
        $proof = Get-CurrentRelayReaderProof `
            -TargetPaneId $PaneId `
            -CallerSession $ExpectedSession
        if ([string]$proof.agent -ne $ExpectedAgent -or
            [string]$proof.session -ne $ExpectedSession -or
            -not [bool]$proof.caller_process_bound) {
            throw "Caller proof does not match the expected live agent process and native session."
        }
        [pscustomobject]@{
            action = "prove-caller"
            proven = $true
            caller = $proof
        } | ConvertTo-Json -Depth 8
    }
    "ack-read" {
        if ([string]::IsNullOrWhiteSpace($RelayRef)) {
            throw "-RelayRef is required for ack-read."
        }
        $ackMutex = Enter-CoordinationAckMutex -Path $LogPath
        try {
        $relay = Get-RelayRecord -Path $LogPath -Reference $RelayRef
        if ([string]::IsNullOrWhiteSpace([string]$relay.recipient_pane_id)) {
            throw "Relay $RelayRef has no stable recipient-pane proof and cannot be acknowledged."
        }
        $requestedRelayRef = $RelayRef
        $requestedRelay = $relay
        if (-not [string]::IsNullOrWhiteSpace([string]$requestedRelay.recipient_session) -and
            -not [string]::IsNullOrWhiteSpace($ExpectedSession) -and
            $ExpectedSession -ne [string]$requestedRelay.recipient_session) {
            throw "Relay read acknowledgement expected session does not match the relay's recorded recipient session."
        }
        $reader = Get-CurrentRelayReaderProof `
            -TargetPaneId ([string]$requestedRelay.recipient_pane_id) `
            -AllowSessionRotation
        Assert-RelayReadIntegrity -Relay $requestedRelay -Reader $reader
        if ([string]::IsNullOrWhiteSpace([string]$requestedRelay.recipient_session) -and
            -not [string]::IsNullOrWhiteSpace($ExpectedSession) -and
            [string]$reader.session -ne $ExpectedSession) {
            throw "Relay read acknowledgement expected session does not match the caller's proven native session."
        }

        $lineage = Get-RelayLineage -Path $LogPath -Relay $requestedRelay
        $relay = $lineage.effective_relay
        $replacementCreated = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$relay.recipient_session) -and
            [string]$relay.recipient_session -ne [string]$reader.session) {
            $relay = New-SessionRotatedRelay `
                -Path $LogPath `
                -Relay $relay `
                -Reader $reader
            $replacementCreated = $true
            $lineage = Get-RelayLineage -Path $LogPath -Relay $requestedRelay
            $relay = $lineage.effective_relay
        }
        Assert-RelayReadIntegrity -Relay $relay -Reader $reader
        $sessionRotated = [string]$requestedRelay.recipient_session -ne [string]$reader.session
        $RelayRef = [string]$relay.relay_ref
        $acks = @(Get-RelayReadAcks -Path $LogPath -Reference $RelayRef)
        $validAcks = @(Get-ValidRelayReadAcks -Path $LogPath -Relay $relay)
        $conflictingAcks = @($acks | Where-Object { -not (Test-RelayReadAck -Relay $relay -Ack $_) })
        if ($conflictingAcks.Count -gt 0) {
            throw "Relay $RelayRef has a conflicting read-ack entry and requires reconciliation."
        }
        if ($validAcks.Count -gt 1) {
            throw "Relay $RelayRef has multiple read acknowledgements and requires reconciliation."
        }
        if ($validAcks.Count -eq 1) {
            [pscustomobject]@{
                action = "ack-read"
                relay_ref = $RelayRef
                requested_relay_ref = $requestedRelayRef
                body_read = $true
                duplicate = $true
                session_rotated = $sessionRotated
                replacement_created = $replacementCreated
                replacement_relay_refs = @($lineage.replacements | ForEach-Object { $_.relay_ref })
                read_ack = $validAcks[0]
                reader = $reader
            } | ConvertTo-Json -Depth 8
            break
        }

        $ackRef = "[HA:$([Guid]::NewGuid().ToString('N').Substring(0, 8))]"
        $ackBody = "$ackRef [READ-ACK re $RelayRef] body read; reader_agent=$($reader.agent); reader_session=$($reader.session)"
        $preAppendReader = Get-CurrentRelayReaderProof `
            -TargetPaneId ([string]$relay.recipient_pane_id) `
            -CallerSession ([string]$reader.session)
        if ([string]$preAppendReader.agent -ne [string]$reader.agent -or
            [string]$preAppendReader.session -ne [string]$reader.session) {
            throw "Relay read acknowledgement refused because native agent-session continuity changed before append."
        }
        $ackEntry = Add-CoordinationEntry `
            -Path $LogPath `
            -Sender ([string]$reader.pane_id) `
            -Recipient ([string]$relay.sender) `
            -Body $ackBody

        $postContinuity = $false
        $postContinuityError = $null
        try {
            $postReader = Get-CurrentRelayReaderProof `
                -TargetPaneId ([string]$relay.recipient_pane_id) `
                -CallerSession ([string]$reader.session)
            $postContinuity = [string]$postReader.agent -eq [string]$reader.agent -and
                [string]$postReader.session -eq [string]$reader.session
        }
        catch {
            $postContinuityError = $_.Exception.Message
        }

        $readAck = [pscustomobject]@{
            ack_ref = $ackRef
            relay_ref = $RelayRef
            reader_pane_id = [string]$reader.pane_id
            returned_to = [string]$relay.sender
            reader_agent = [string]$reader.agent
            reader_session = [string]$reader.session
            entry = $ackEntry
        }
        [pscustomobject]@{
            action = "ack-read"
            relay_ref = $RelayRef
            requested_relay_ref = $requestedRelayRef
            body_read = $true
            duplicate = $false
            session_rotated = $sessionRotated
            replacement_created = $replacementCreated
            replacement_relay_refs = @($lineage.replacements | ForEach-Object { $_.relay_ref })
            read_ack = $readAck
            reader = $reader
            post_append_continuity = $postContinuity
            post_append_continuity_error = $postContinuityError
        } | ConvertTo-Json -Depth 8
        }
        finally {
            Exit-CoordinationAckMutex -Mutex $ackMutex
        }
    }
    "watch-queued" {
        if ([string]::IsNullOrWhiteSpace($PaneId) -or
            [string]::IsNullOrWhiteSpace($Token) -or
            [string]::IsNullOrWhiteSpace($ExpectedAgent)) {
            throw "-PaneId, -Token, and -ExpectedAgent are required for watch-queued."
        }
        $expectedProcessLease = $null
        if ([string]::IsNullOrWhiteSpace($ExpectedSession)) {
            if ($ExpectedRevision -lt 0 -or
                [string]::IsNullOrWhiteSpace($ExpectedTerminalId) -or
                $ExpectedShellPid -le 0 -or
                $ExpectedAgentPid -le 0) {
                throw "watch-queued requires either -ExpectedSession or a complete stable agent-process lease."
            }
            $expectedProcessLease = [pscustomobject]@{
                revision = $ExpectedRevision
                terminal_id = $ExpectedTerminalId
                shell_pid = $ExpectedShellPid
                agent_pid = $ExpectedAgentPid
            }
        }

        $watchResult = Watch-QueuedPaneMessage `
            -TargetPaneId $PaneId `
            -TrackedToken $Token `
            -TargetAgent $ExpectedAgent `
            -TargetSession $ExpectedSession `
            -TargetProcessLease $expectedProcessLease `
            -TimeoutMs $WatchTimeoutMs `
            -AlertAfterMs $EarlyAlertMs
        $watchEntry = Add-CoordinationEntry `
            -Path $WatchLogPath `
            -Sender "queued-watcher" `
            -Recipient $PaneId `
            -Body ($watchResult | ConvertTo-Json -Compress -Depth 8)
        [pscustomobject]@{
            action = "watch-queued"
            watch_log_path = $WatchLogPath
            entry = $watchEntry
            result = $watchResult
        } | ConvertTo-Json -Depth 10
    }
    "rename-current" {
        throw "rename-current is disabled: panes must send a tracked PANE NAMING REQUEST to Coordination, which validates the live tuple and applies the canonical name and work subtitle."
    }
}

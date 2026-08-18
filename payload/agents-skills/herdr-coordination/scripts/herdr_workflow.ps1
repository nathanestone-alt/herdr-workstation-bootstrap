[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("preflight", "request", "ack", "complete", "ack-return", "reconcile-return-read", "reconcile-completion", "status", "scan")]
    [string]$Action,

    [string]$TaskId,
    [string]$CandidateId,
    [string]$ReviewType,
    [string]$PaneId,
    [string]$Message,
    [string]$ArtifactPath,
    [string]$ArtifactSha256,
    [string]$WorkflowRef,
    [string]$Outcome,
    [string]$EvidenceRelayRef,
    [string]$EvidenceAckRef,
    [string]$ExpectedSourceSession,
    [string]$ExpectedTargetSession,
    [string]$ExpectedTabLabel,

    # Short work title used when the subtitle-currency check auto-fires a pane
    # naming request for the CALLING pane. Omit to fall back to the review type.
    [string]$SubtitleWorkTitle,

    [ValidateRange(1, 86400)]
    [int]$AckTimeoutSeconds = 120,

    [ValidateRange(60, 604800)]
    [int]$CompletionTimeoutSeconds = 3600,

    [switch]$AllowWorking,
    [switch]$Notify,
    [switch]$NoCoordinatorNotice,

    [datetime]$NowUtc = [DateTime]::UtcNow,

    [string]$LedgerPath = $(Join-Path ([IO.Path]::GetTempPath()) "herdr-workflow-ledger.jsonl"),
    [string]$WatchLogPath = $(Join-Path ([IO.Path]::GetTempPath()) "herdr-coordination-watch.md"),
    [string]$CoordinationLogPath = $(Join-Path ([IO.Path]::GetTempPath()) "herdr-coordination.md"),
    [string]$CoordinationHelperPath = $(Join-Path $PSScriptRoot "herdr_coordination.ps1"),
    [string]$PaneRegistryPath = $(Join-Path ([IO.Path]::GetTempPath()) "herdr-pane-registry.jsonl"),
    [string]$PaneRegistryHelperPath = $(Join-Path $PSScriptRoot "herdr_pane_registry.ps1")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$OutputEncoding = $utf8NoBom
try {
    [Console]::OutputEncoding = $utf8NoBom
}
catch {
    # A detached watchdog may not own a console.
}

function Get-ShortHash {
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$Length = 16
    )

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        $hex = [Convert]::ToHexString($bytes).ToLowerInvariant()
        return $hex.Substring(0, [Math]::Min($Length, $hex.Length))
    }
    finally {
        $sha.Dispose()
    }
}

function Read-WorkflowArtifactSnapshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaximumBytes = 65536
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $stream = [IO.File]::Open(
        $fullPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ($stream.Length -gt $MaximumBytes) {
            throw "Workflow artifact exceeds the $MaximumBytes-byte limit: $fullPath"
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) {
                throw "Workflow artifact ended before its locked snapshot was complete: $fullPath"
            }
            $offset += $read
        }
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $text = $utf8.GetString($bytes)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
        return [pscustomobject]@{
            path = $fullPath
            text = $text
            sha256 = $hash
            length = [long]$bytes.Length
        }
    }
    finally {
        $stream.Dispose()
    }
}

function New-WorkflowId {
    param([Parameter(Mandatory)][string]$Prefix)
    return "[$Prefix`:$([Guid]::NewGuid().ToString('N').Substring(0, 8))]"
}

function Get-JobKey {
    param(
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Type
    )

    $normalized = @($Task, $Candidate, $Type) |
        ForEach-Object {
            (($_ -replace "\s+", " ").Trim().ToLowerInvariant()).Normalize([Text.NormalizationForm]::FormC)
        }
    $serialized = @($normalized | ForEach-Object {
            $byteLength = [Text.Encoding]::UTF8.GetByteCount([string]$_)
            "$byteLength`:$($_)"
        }) -join "|"
    return Get-ShortHash -Text $serialized -Length 24
}

function Get-LedgerMutexName {
    $normalizedPath = [IO.Path]::GetFullPath($LedgerPath).ToLowerInvariant()
    return "Local\HerdrWorkflow-$((Get-ShortHash -Text $normalizedPath -Length 24))"
}

function Invoke-WithLedgerLock {
    param([Parameter(Mandatory)][scriptblock]$Body)

    $mutex = [Threading.Mutex]::new($false, (Get-LedgerMutexName))
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(5000)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Timed out acquiring the workflow-ledger lock."
        }
        return & $Body
    }
    finally {
        if ($acquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Read-LedgerUnlocked {
    if (-not (Test-Path -LiteralPath $LedgerPath)) {
        return @()
    }

    $events = [Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $LedgerPath) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $events.Add(($line | ConvertFrom-Json -Depth 20))
        }
        catch {
            throw "Workflow ledger contains invalid JSON on line $lineNumber."
        }
    }
    return @($events)
}

function Write-LedgerEventUnlocked {
    param([Parameter(Mandatory)]$Event)

    $parent = Split-Path -Parent $LedgerPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $line = $Event | ConvertTo-Json -Compress -Depth 20
    [IO.File]::AppendAllText($LedgerPath, "$line$([Environment]::NewLine)", $utf8NoBom)
}

function New-LedgerEventObject {
    param([Parameter(Mandatory)][hashtable]$Fields)

    $event = [ordered]@{
        schema = 1
        event_id = New-WorkflowId -Prefix "WE"
        timestamp_utc = $NowUtc.ToUniversalTime().ToString("o")
    }
    foreach ($entry in $Fields.GetEnumerator()) {
        $event[$entry.Key] = $entry.Value
    }
    return [pscustomobject]$event
}

function Add-LedgerEvent {
    param([Parameter(Mandatory)][hashtable]$Fields)

    $event = New-LedgerEventObject -Fields $Fields
    Invoke-WithLedgerLock {
        Write-LedgerEventUnlocked -Event $event
    } | Out-Null
    return $event
}

function Get-LedgerEvents {
    return Invoke-WithLedgerLock { Read-LedgerUnlocked }
}

function Invoke-HerdrText {
    param([Parameter(Mandatory)][string[]]$Arguments)

    if ($env:HERDR_ENV -ne "1") {
        throw "HERDR_ENV=1 is required for workflow coordination."
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
        throw "herdr $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    return $output -join [Environment]::NewLine
}

function Invoke-HerdrJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $text = Invoke-HerdrText -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return $text | ConvertFrom-Json -Depth 20
}

function Invoke-CoordinationHelper {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $pwsh = Get-Command pwsh -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh.Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($argument in @("-NoProfile", "-File", $CoordinationHelperPath) + $Arguments) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "pwsh process did not start"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Coordination helper failed: $stderr$stdout"
        }
    }
    finally {
        $process.Dispose()
    }
    return $stdout | ConvertFrom-Json -Depth 20
}

function Invoke-PaneRegistryHelper {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & pwsh -NoProfile -File $PaneRegistryHelperPath `
        -RegistryPath $PaneRegistryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Pane registry helper failed: $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 32
}

function Get-WorkflowRegistryStatus {
    return Invoke-PaneRegistryHelper -Arguments @("-Action", "status")
}

function Resolve-WorkflowRegistryTarget {
    param([Parameter(Mandatory)][string]$Target)

    $status = Get-WorkflowRegistryStatus
    if (-not [bool]$status.initialized) {
        if ($Target -match '^@pane\[') {
            throw "Pane registry is not initialized; human pane references are unavailable."
        }
        return $null
    }
    if ($Target -match '^@pane\[[^\]]+\]$') {
        return (Invoke-PaneRegistryHelper -Arguments @("-Action", "resolve", "-Name", $Target)).binding
    }
    if ($Target -notmatch '^w[^:]+:p[^:]+$') {
        throw "Workflow target must be @pane[NAME] or an explicit pane ID."
    }
    return (Invoke-PaneRegistryHelper -Arguments @("-Action", "resolve-pane", "-PaneId", $Target)).binding
}

function Get-WorkflowRegistryArguments {
    param([object]$Binding)

    if ($null -eq $Binding) {
        return @()
    }
    return @(
        "-PaneRegistryPath", $PaneRegistryPath,
        "-ExpectedRegistryId", [string]$Binding.registry_id,
        "-ExpectedBindingId", [string]$Binding.binding_id,
        "-ExpectedRegistryName", [string]$Binding.canonical_name,
        "-ExpectedGeneration", [string]$Binding.generation
    )
}

function Assert-WorkflowCallerProof {
    param(
        [Parameter(Mandatory)][string]$PaneId,
        [Parameter(Mandatory)][string]$Agent,
        [Parameter(Mandatory)][string]$Session
    )

    $proof = Invoke-CoordinationHelper -Arguments @(
        "-Action", "prove-caller",
        "-PaneId", $PaneId,
        "-ExpectedAgent", $Agent,
        "-ExpectedSession", $Session,
        "-LogPath", $CoordinationLogPath
    )
    if (-not [bool]$proof.proven -or
        [string]$proof.caller.pane_id -ne $PaneId -or
        [string]$proof.caller.agent -ne $Agent -or
        [string]$proof.caller.session -ne $Session -or
        -not [bool]$proof.caller.caller_process_bound) {
        throw "Workflow caller is not bound to the expected live pane agent process and native session."
    }
    return $proof.caller
}

function Get-AgentSessionId {
    param([Parameter(Mandatory)]$Agent)
    $session = $Agent.PSObject.Properties["agent_session"]
    if (-not $session -or $null -eq $session.Value -or $session.Value -is [string]) {
        return $null
    }
    $value = $session.Value.PSObject.Properties["value"]
    if (-not $value -or [string]::IsNullOrWhiteSpace([string]$value.Value)) {
        return $null
    }
    return [string]$value.Value
}

function Get-AgentSessionKind {
    param([Parameter(Mandatory)]$Agent)
    $session = $Agent.PSObject.Properties["agent_session"]
    if (-not $session -or $null -eq $session.Value -or $session.Value -is [string]) {
        return $null
    }
    $kind = $session.Value.PSObject.Properties["agent"]
    if (-not $kind) {
        return $null
    }
    return [string]$kind.Value
}

function Get-AgentWorkSubtitle {
    param([Parameter(Mandatory)]$Agent)

    # Coordination applies the work subtitle to both --title and
    # --display-agent, so either property is an equally valid read.
    foreach ($name in @("display_agent", "title")) {
        $property = $Agent.PSObject.Properties[$name]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    return $null
}

function Get-SubtitleTaskToken {
    param([AllowNull()][AllowEmptyString()][string]$TaskId)

    # Only a leading "#<digits>" is a routable ticket token. Ad-hoc task labels
    # (EXPLORE topics, free text, bare candidate ids) carry no token, so the
    # currency check is skipped silently rather than warning on every call.
    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        return $null
    }
    $match = [regex]::Match($TaskId.Trim(), '^#(?<number>\d+)(?![0-9])')
    if (-not $match.Success) {
        return $null
    }
    return "#$($match.Groups['number'].Value)"
}

function Test-SubtitleCarriesToken {
    param(
        [AllowNull()][AllowEmptyString()][string]$Subtitle,
        [Parameter(Mandatory)][string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Subtitle)) {
        return $false
    }
    # "#88" must not be satisfied by "#883"; a "PR#883" prefix is accepted.
    return [regex]::IsMatch($Subtitle, "$([regex]::Escape($Token))(?![0-9])")
}

function Get-CanonicalNameParts {
    param([AllowNull()][AllowEmptyString()][string]$CanonicalName)

    if ([string]::IsNullOrWhiteSpace($CanonicalName)) {
        return $null
    }
    $match = [regex]::Match(
        $CanonicalName.Trim(),
        '^(?<repo>STM|AGT|Hdr|Buzz)-(?<lane>[A-Z][A-Z0-9]*)-(?<role>[A-Z])(?<slot>\d+)$')
    if (-not $match.Success) {
        return $null
    }
    $repoCodes = @{ STM = "STM"; AGT = "AGT"; Hdr = "HDR"; Buzz = "BUZ" }
    return [pscustomobject]@{
        repo_code = [string]$repoCodes[[string]$match.Groups['repo'].Value]
        lane_code = [string]$match.Groups['lane'].Value
        role_code = [string]$match.Groups['role'].Value
        slot = [string]$match.Groups['slot'].Value
    }
}

function Resolve-PaneCanonicalName {
    param(
        [object]$RegistryBinding,
        [AllowNull()][AllowEmptyString()][string]$TabLabel
    )

    if ($null -ne $RegistryBinding) {
        $name = Get-OptionalPropertyString -Object $RegistryBinding -Name "canonical_name"
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return $name
        }
    }
    # A correctly named pane carries its canonical name as the tab label, so the
    # live label is the fallback when no registry binding exists.
    return [string]$TabLabel
}

function Get-CallerCanonicalName {
    param(
        [Parameter(Mandatory)][string]$PaneId,
        [object]$Agent,
        [AllowNull()][AllowEmptyString()][string]$TabLabel
    )

    try {
        $binding = Resolve-WorkflowRegistryTarget -Target $PaneId
        $label = [string]$TabLabel
        if ([string]::IsNullOrWhiteSpace($label) -and $null -ne $Agent) {
            $tabIdProperty = $Agent.PSObject.Properties["tab_id"]
            if ($null -ne $tabIdProperty -and
                -not [string]::IsNullOrWhiteSpace([string]$tabIdProperty.Value)) {
                $label = [string](Invoke-HerdrJson -Arguments @(
                        "tab", "get", [string]$tabIdProperty.Value)).result.tab.label
            }
        }
        return Resolve-PaneCanonicalName -RegistryBinding $binding -TabLabel $label
    }
    catch {
        # Naming context is advisory; never fail the carrying action over it.
        return [string]$TabLabel
    }
}

function New-SubtitleCurrencyReport {
    param(
        [AllowNull()][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory)][string]$PaneId,
        [AllowNull()][AllowEmptyString()][string]$Subtitle,
        [AllowNull()][AllowEmptyString()][string]$CanonicalName,
        [AllowNull()][AllowEmptyString()][string]$AgentKind,
        [AllowNull()][AllowEmptyString()][string]$SessionId,
        [AllowNull()][AllowEmptyString()][string]$WorkTitle
    )

    # Mechanical replacement for the unenforced end-of-turn naming checklist:
    # request/complete/ack-return all know the TaskId and the calling pane, so
    # the staleness is decided here instead of being left to the agent.
    $report = [ordered]@{
        subtitle_task_token = $null
        subtitle_current = if ([string]::IsNullOrWhiteSpace($Subtitle)) { $null } else { [string]$Subtitle }
        subtitle_stale = $false
        subtitle_hint = $null
        subtitle_request_fired = $false
        subtitle_request_error = $null
    }

    $token = Get-SubtitleTaskToken -TaskId $TaskId
    if ($null -eq $token) {
        return [pscustomobject]$report
    }
    $report.subtitle_task_token = $token
    if (Test-SubtitleCarriesToken -Subtitle $Subtitle -Token $token) {
        return [pscustomobject]$report
    }
    $report.subtitle_stale = $true

    $issueNumber = $token.TrimStart('#')
    $parts = Get-CanonicalNameParts -CanonicalName $CanonicalName
    $effectiveTitle = if ([string]::IsNullOrWhiteSpace($WorkTitle)) {
        $null
    }
    else {
        ($WorkTitle -replace '[\r\n]+', ' ').Trim()
    }

    if ($null -eq $parts -or [string]::IsNullOrWhiteSpace($effectiveTitle)) {
        # Not enough non-interactive material to compose a valid request; warn
        # with the shape the pane must send itself.
        $report.subtitle_hint = "pwsh -NoProfile -File `"$CoordinationHelperPath`" -Action name-request" +
            " -RepoCode <REPO> -LaneCode <LANE> -RoleCode <ROLE> -WorkKind issue" +
            " -IssueNumber $issueNumber -WorkTitle `"<short title>`""
        return [pscustomobject]$report
    }

    $report.subtitle_hint = "pwsh -NoProfile -File `"$CoordinationHelperPath`" -Action name-request" +
        " -RepoCode $($parts.repo_code) -LaneCode $($parts.lane_code) -RoleCode $($parts.role_code)" +
        " -WorkKind issue -IssueNumber $issueNumber -WorkTitle `"$effectiveTitle`""

    if ([string]::IsNullOrWhiteSpace($AgentKind) -or [string]::IsNullOrWhiteSpace($SessionId)) {
        # Fail closed on the auto-fire only. Without live session proof the pane
        # is warned; nothing is ever requested on its behalf.
        return [pscustomobject]$report
    }

    try {
        $arguments = @(
            "-Action", "name-request",
            "-From", $PaneId,
            "-RepoCode", [string]$parts.repo_code,
            "-LaneCode", [string]$parts.lane_code,
            "-RoleCode", [string]$parts.role_code,
            "-WorkKind", "issue",
            "-IssueNumber", $issueNumber,
            "-WorkTitle", $effectiveTitle,
            "-ExpectedAgent", [string]$AgentKind,
            "-ExpectedSession", [string]$SessionId,
            "-LogPath", $CoordinationLogPath
        )
        if (-not [string]::IsNullOrWhiteSpace($CanonicalName)) {
            $arguments += @("-PreviousName", ($CanonicalName -replace '[\r\n]+', ' ').Trim())
        }
        if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
            $arguments += @("-PreviousWork", ($Subtitle -replace '[\r\n]+', ' ').Trim())
        }
        $null = Invoke-CoordinationHelper -Arguments $arguments
        $report.subtitle_request_fired = $true
    }
    catch {
        # Best effort by contract: a naming-request failure must never fail the
        # request/complete/ack-return that carried it.
        $report.subtitle_request_error = $_.Exception.Message
    }
    return [pscustomobject]$report
}

function Get-EffectiveSubtitleWorkTitle {
    param([AllowNull()][AllowEmptyString()][string]$Fallback)

    if (-not [string]::IsNullOrWhiteSpace($SubtitleWorkTitle)) {
        return $SubtitleWorkTitle
    }
    return [string]$Fallback
}

function Get-CurrentInteractiveRegion {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Detection)

    $lines = @($Detection -split "\r?\n")
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        if ($lines[$index] -match "^\s*(?:›|❯|>)\s*") {
            return [pscustomobject]@{
                text = ($lines[$index..($lines.Count - 1)] -join [Environment]::NewLine)
                prompt_marker_found = $true
                prompt_marker_line = $index
            }
        }
    }

    # A suppressed composer or interactive overlay may have no prompt marker.
    # In that state retain the fail-closed behavior and inspect the full buffer.
    return [pscustomobject]@{
        text = $Detection
        prompt_marker_found = $false
        prompt_marker_line = $null
    }
}

function Get-Preflight {
    param(
        [Parameter(Mandatory)][string]$TargetPaneId,
        [string]$RequiredTabLabel,
        [switch]$PermitWorking
    )

    $reasons = [Collections.Generic.List[string]]::new()
    $flags = [Collections.Generic.List[string]]::new()
    $agentResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
    $agent = $agentResponse.result.agent
    if ([string]$agent.pane_id -ne $TargetPaneId) {
        throw "Preflight resolved a different pane than $TargetPaneId."
    }

    $agentKind = [string]$agent.agent
    $status = [string]$agent.agent_status
    $sessionId = Get-AgentSessionId -Agent $agent
    $sessionKind = Get-AgentSessionKind -Agent $agent
    if ([string]::IsNullOrWhiteSpace($agentKind)) {
        $reasons.Add("no detected agent")
    }
    if ([string]::IsNullOrWhiteSpace($sessionId) -or $sessionKind -ne $agentKind) {
        $reasons.Add("matching native-session proof is unavailable")
    }
    if ($status -eq "blocked") {
        $reasons.Add("agent is blocked")
    }
    elseif ($status -eq "working" -and -not $PermitWorking) {
        $reasons.Add("agent is already working")
    }
    elseif ($status -notin @("idle", "done", "working")) {
        $reasons.Add("agent status '$status' is not dispatchable")
    }

    $detection = ""
    try {
        $detection = Invoke-HerdrText -Arguments @(
            "agent", "read", $TargetPaneId,
            "--source", "detection",
            "--lines", "128",
            "--format", "text"
        )
    }
    catch {
        $reasons.Add("detection buffer is unavailable")
    }
    $interactiveRegion = Get-CurrentInteractiveRegion -Detection $detection
    $currentUi = [string]$interactiveRegion.text
    if ($currentUi -match "(?i)waiting for \d+ background agents? to finish") {
        $flags.Add("background_agents")
        $reasons.Add("agent UI is waiting for background agents")
    }
    if ($currentUi -match "(?i)pasted text(?:\s*#?\d+)?") {
        $flags.Add("collapsed_paste")
        $reasons.Add("agent UI contains a collapsed paste")
    }
    if ($currentUi -match "(?i)(permission|approval).*(required|request|allow|deny)") {
        $flags.Add("interactive_block")
        $reasons.Add("agent UI contains an interactive permission or approval")
    }

    $tabLabel = $null
    $tabIdProperty = $agent.PSObject.Properties["tab_id"]
    if ($tabIdProperty -and -not [string]::IsNullOrWhiteSpace([string]$tabIdProperty.Value)) {
        try {
            $tabResponse = Invoke-HerdrJson -Arguments @("tab", "get", [string]$tabIdProperty.Value)
            $tabLabel = [string]$tabResponse.result.tab.label
        }
        catch {
            $flags.Add("tab_label_unavailable")
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($RequiredTabLabel)) {
        if ([string]::IsNullOrWhiteSpace($tabLabel)) {
            $reasons.Add("expected tab label '$RequiredTabLabel' could not be resolved")
        }
        elseif ($tabLabel -cne $RequiredTabLabel) {
            $reasons.Add("tab label mismatch: expected '$RequiredTabLabel', observed '$tabLabel'")
        }
    }

    return [pscustomobject]@{
        ready = $reasons.Count -eq 0
        pane_id = $TargetPaneId
        tab_id = if ($tabIdProperty) { [string]$tabIdProperty.Value } else { $null }
        tab_label = $tabLabel
        agent = $agentKind
        status = $status
        session_id = $sessionId
        session_agent = $sessionKind
        model = Get-OptionalProfileString -Object $agent -Name "model"
        reasoning_effort = Get-OptionalProfileString -Object $agent -Name "reasoning_effort"
        service_tier = Get-OptionalProfileString -Object $agent -Name "service_tier"
        execution_profile_proven = $null -ne (Get-OptionalProfileString -Object $agent -Name "model") -and
            $null -ne (Get-OptionalProfileString -Object $agent -Name "reasoning_effort") -and
            $null -ne (Get-OptionalProfileString -Object $agent -Name "service_tier")
        working_queue = $status -eq "working"
        detection_scope = if ($interactiveRegion.prompt_marker_found) {
            "after_final_prompt_marker"
        }
        else {
            "full_buffer_no_prompt_marker"
        }
        prompt_marker_found = [bool]$interactiveRegion.prompt_marker_found
        flags = @($flags)
        reasons = @($reasons)
    }
}

function Get-TaskViews {
    param([Parameter(Mandatory)][object[]]$Events)

    $views = [Collections.Generic.List[object]]::new()
    $refs = [Collections.Generic.List[string]]::new()
    $jobsByRef = @{}
    foreach ($eventRecord in $Events) {
        $eventRef = [string]$eventRecord.workflow_ref
        if ([string]::IsNullOrWhiteSpace($eventRef)) {
            continue
        }
        if (-not $jobsByRef.ContainsKey($eventRef)) {
            $jobsByRef[$eventRef] = [Collections.Generic.List[object]]::new()
            $refs.Add($eventRef)
        }
        $jobsByRef[$eventRef].Add($eventRecord)
    }
    foreach ($ref in $refs) {
        $job = @($jobsByRef[[string]$ref])
        $reserved = @($job | Where-Object { $_.event -eq "request_reserved" } | Select-Object -Last 1)[0]
        $request = @($job | Where-Object { $_.event -eq "request" } | Select-Object -Last 1)
        $request = if ($request.Count) { $request[0] } else { $null }
        $ack = @($job | Where-Object { $_.event -eq "work_ack" } | Select-Object -Last 1)
        $ack = if ($ack.Count) { $ack[0] } else { $null }
        $complete = @($job | Where-Object {
                $_.event -in @("completed", "completion_reconciled")
            } | Select-Object -Last 1)
        $complete = if ($complete.Count) { $complete[0] } else { $null }
        $completionReturn = @($job | Where-Object {
                $_.event -eq "completion_returned"
            } | Select-Object -Last 1)
        $completionReturn = if ($completionReturn.Count) { $completionReturn[0] } else { $null }
        $completionReturnRead = @($job | Where-Object {
                $_.event -eq "completion_return_read"
            } | Select-Object -Last 1)
        $completionReturnRead = if ($completionReturnRead.Count) { $completionReturnRead[0] } else { $null }
        $completionReturnFailure = @($job | Where-Object {
                $_.event -eq "completion_return_failed"
            } | Select-Object -Last 1)
        $completionReturnFailure = if ($completionReturnFailure.Count) {
            $completionReturnFailure[0]
        }
        else {
            $null
        }
        $requestReissues = @($job | Where-Object {
                $_.event -eq "request_reissued"
            } | Sort-Object timestamp_utc)
        $requestReissue = if ($requestReissues.Count) {
            $requestReissues[-1]
        }
        else {
            $null
        }
        # Keep the workflow identity stable while making the latest
        # proof-bound delivery attempt the effective request.  The original
        # relay remains durable evidence and is explicitly superseded by the
        # request_reissued event; completions still use the same workflow and
        # artifact key, so a rotation cannot create a second review.
        $effectiveRequest = $request
        if ($null -ne $requestReissue -and $null -ne $request) {
            $effectiveRequest = [pscustomobject]@{}
            foreach ($property in $request.PSObject.Properties) {
                $effectiveRequest | Add-Member `
                    -NotePropertyName $property.Name `
                    -NotePropertyValue $property.Value
            }
            foreach ($override in @{
                    relay_ref = [string]$requestReissue.replacement_relay_ref
                    target_session = [string]$requestReissue.target_session
                    target_tab_id = [string]$requestReissue.target_tab_id
                    target_tab_label = [string]$requestReissue.target_tab_label
                    delivery_token = [string]$requestReissue.delivery_token
                    delivery_state = [string]$requestReissue.delivery_state
                    transport_accepted = [bool]$requestReissue.transport_accepted
                    error = $null
                    ack_deadline_utc = [string]$requestReissue.ack_deadline_utc
                    superseded_relay_ref = [string]$requestReissue.superseded_relay_ref
                    target_model = [string]$requestReissue.target_model
                    target_reasoning_effort = [string]$requestReissue.target_reasoning_effort
                    target_service_tier = [string]$requestReissue.target_service_tier
                    target_execution_profile_proven = [bool]$requestReissue.target_execution_profile_proven
                    request_reissued = $requestReissue
                }.GetEnumerator()) {
                if ($effectiveRequest.PSObject.Properties[$override.Key]) {
                    $effectiveRequest.PSObject.Properties[$override.Key].Value = $override.Value
                }
                else {
                    $effectiveRequest | Add-Member `
                        -NotePropertyName $override.Key `
                        -NotePropertyValue $override.Value
                }
            }
        }
        $alerts = @($job | Where-Object { $_.event -eq "alert" })
        $status = if ($complete) {
            "completed"
        }
        elseif ($ack) {
            "work_acknowledged"
        }
        elseif ($effectiveRequest -and -not [bool]$effectiveRequest.transport_accepted) {
            "delivery_failed"
        }
        elseif ($effectiveRequest) {
            "awaiting_ack"
        }
        else {
            "reserved"
        }
        $views.Add([pscustomobject]@{
            workflow_ref = [string]$ref
            job_key = [string]$reserved.job_key
            task_id = [string]$reserved.task_id
            candidate_id = [string]$reserved.candidate_id
            review_type = [string]$reserved.review_type
            source_pane = [string]$reserved.source_pane
            source_agent = Get-OptionalPropertyString -Object $reserved -Name "source_agent"
            source_session = Get-OptionalPropertyString -Object $reserved -Name "source_session"
            source_tab_id = Get-OptionalPropertyString -Object $reserved -Name "source_tab_id"
            source_tab_label = Get-OptionalPropertyString -Object $reserved -Name "source_tab_label"
            target_pane = [string]$reserved.target_pane
            target_tab_label = Get-OptionalPropertyString -Object $reserved -Name "target_tab_label"
            target_tab_id = Get-OptionalPropertyString -Object $reserved -Name "target_tab_id"
            target_agent = Get-OptionalPropertyString -Object $reserved -Name "target_agent"
            target_model = Get-OptionalProfileString -Object $reserved -Name "target_model"
            target_reasoning_effort = Get-OptionalProfileString -Object $reserved -Name "target_reasoning_effort"
            target_service_tier = Get-OptionalProfileString -Object $reserved -Name "target_service_tier"
            target_execution_profile_proven = (Get-OptionalPropertyString -Object $reserved -Name "target_execution_profile_proven") -eq "True"
            status = $status
            request = $effectiveRequest
            request_original = $request
            request_reissued = $requestReissue
            request_reissue_history = @($requestReissues)
            superseded = $null -ne $requestReissue
            ack = $ack
            completion = $complete
            completion_return = $completionReturn
            completion_return_read = $completionReturnRead
            completion_return_failure = $completionReturnFailure
            alerts = $alerts
        })
    }
    return @($views)
}

function Get-WorkflowByRef {
    param(
        [Parameter(Mandatory)][object[]]$Events,
        [Parameter(Mandatory)][string]$Ref
    )
    $view = @(Get-TaskViews -Events $Events | Where-Object { $_.workflow_ref -eq $Ref })
    if ($view.Count -ne 1) {
        throw "Workflow reference $Ref was not found or is ambiguous."
    }
    return $view[0]
}

function Get-WorkflowTargetProof {
    param(
        [Parameter(Mandatory)][string]$TargetPaneId
    )

    $agentResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
    $agent = $agentResponse.result.agent
    if ([string]$agent.pane_id -ne $TargetPaneId) {
        throw "Workflow target proof resolved a different pane than $TargetPaneId."
    }
    $tabId = Get-OptionalPropertyString -Object $agent -Name "tab_id"
    if ([string]::IsNullOrWhiteSpace($tabId)) {
        throw "Workflow target pane $TargetPaneId lacks a resolvable tab ID."
    }
    $tabResponse = Invoke-HerdrJson -Arguments @("tab", "get", $tabId)
    $tab = $tabResponse.result.tab
    if ($null -eq $tab -or [string]$tab.tab_id -ne $tabId -or
        [string]::IsNullOrWhiteSpace([string]$tab.label)) {
        throw "Workflow target pane $TargetPaneId lacks a resolvable stable tab label."
    }
    $agentKind = [string]$agent.agent
    $session = Get-AgentSessionId -Agent $agent
    $sessionKind = Get-AgentSessionKind -Agent $agent
    if ([string]::IsNullOrWhiteSpace($agentKind) -or
        [string]::IsNullOrWhiteSpace($session) -or
        $sessionKind -ne $agentKind) {
        throw "Workflow target pane $TargetPaneId lacks matching native agent-session proof."
    }
    return [pscustomobject]@{
        pane_id = $TargetPaneId
        agent = $agentKind
        session_id = $session
        session_agent = $sessionKind
        tab_id = $tabId
        tab_label = [string]$tab.label
        revision = [long]$agent.revision
        state_change_seq = [long]$agent.state_change_seq
        status = [string]$agent.agent_status
        model = Get-OptionalProfileString -Object $agent -Name "model"
        reasoning_effort = Get-OptionalProfileString -Object $agent -Name "reasoning_effort"
        service_tier = Get-OptionalProfileString -Object $agent -Name "service_tier"
        execution_profile_proven = $null -ne (Get-OptionalProfileString -Object $agent -Name "model") -and
            $null -ne (Get-OptionalProfileString -Object $agent -Name "reasoning_effort") -and
            $null -ne (Get-OptionalProfileString -Object $agent -Name "service_tier")
    }
}

function Get-WorkflowReissueState {
    param(
        [Parameter(Mandatory)][object[]]$Events,
        [Parameter(Mandatory)][string]$WorkflowReference,
        [Parameter(Mandatory)][datetime]$NowUtc
    )

    $reissued = @($Events | Where-Object {
            $_.event -eq "request_reissued" -and
            [string]$_.workflow_ref -eq $WorkflowReference
        } | Sort-Object timestamp_utc)
    if ($reissued.Count) {
        return [pscustomobject]@{
            state = "reissued"
            event = $reissued[-1]
            history = $reissued
        }
    }

    $reservations = @($Events | Where-Object {
            $_.event -eq "request_reissue_reserved" -and
            [string]$_.workflow_ref -eq $WorkflowReference
        } | Sort-Object timestamp_utc -Descending)
    if ($reservations.Count) {
        $reservation = $reservations[0]
        $attemptId = Get-OptionalPropertyString -Object $reservation -Name "reissue_attempt_id"
        $terminal = @($Events | Where-Object {
                $_.event -in @("request_reissued", "request_reissue_failed") -and
                (Get-OptionalPropertyString -Object $_ -Name "reissue_attempt_id") -eq $attemptId
            } | Select-Object -Last 1)
        if (-not $terminal.Count) {
            # Reissue reservations are fencing tokens. An expired or malformed
            # lease cannot prove that the previous process stopped before its
            # prompt transport ran, so no second replacement is ever inferred.
            return [pscustomobject]@{
                state = "in_progress"
                event = $reservation
                history = @()
            }
        }
    }
    return [pscustomobject]@{
        state = "none"
        event = $null
        history = @()
    }
}

function Reserve-WorkflowRequestReissue {
    param(
        [Parameter(Mandatory)]$Workflow,
        [Parameter(Mandatory)]$LiveProof,
        [Parameter(Mandatory)][datetime]$NowUtc
    )

    return Invoke-WithLedgerLock {
        $events = Read-LedgerUnlocked
        $current = Get-WorkflowByRef -Events $events -Ref ([string]$Workflow.workflow_ref)
        if ($current.ack -or $current.completion) {
            throw "Workflow $($Workflow.workflow_ref) already has a durable ACK or completion; session rotation cannot reissue it."
        }
        $reissueState = Get-WorkflowReissueState `
            -Events $events `
            -WorkflowReference ([string]$Workflow.workflow_ref) `
            -NowUtc $NowUtc
        if ($reissueState.state -eq "reissued") {
            if ([string]$reissueState.event.target_session -ne [string]$LiveProof.session_id) {
                throw "Workflow $($Workflow.workflow_ref) already has a replacement bound to a different native session."
            }
            return [pscustomobject]@{
                reserved = $false
                duplicate = $true
                state = "reissued"
                event = $reissueState.event
            }
        }
        if ($reissueState.state -eq "in_progress") {
            if ([string]$reissueState.event.target_session -ne [string]$LiveProof.session_id) {
                throw "Workflow $($Workflow.workflow_ref) has an in-progress replacement for a different native session."
            }
            return [pscustomobject]@{
                reserved = $false
                duplicate = $false
                state = "in_progress"
                event = $reissueState.event
            }
        }

        $request = $current.request
        $oldSession = Get-OptionalPropertyString -Object $request -Name "target_session"
        $oldRelay = Get-OptionalPropertyString -Object $request -Name "relay_ref"
        $targetTabId = Get-OptionalPropertyString -Object $request -Name "target_tab_id"
        $message = Get-OptionalPropertyString -Object $request -Name "message"
        $ackDeadlineText = Get-OptionalPropertyString -Object $request -Name "ack_deadline_utc"
        if ([string]::IsNullOrWhiteSpace($oldSession) -or
            [string]::IsNullOrWhiteSpace($oldRelay) -or
            [string]::IsNullOrWhiteSpace($targetTabId) -or
            [string]::IsNullOrWhiteSpace($message)) {
            throw "Workflow $($Workflow.workflow_ref) lacks rotation-safe target tab, relay, or message provenance; reissue is refused."
        }
        $expectedModel = Get-OptionalPropertyString -Object $Workflow -Name "target_model"
        $expectedEffort = Get-OptionalPropertyString -Object $Workflow -Name "target_reasoning_effort"
        $expectedTier = Get-OptionalPropertyString -Object $Workflow -Name "target_service_tier"
        $profileProven = (Get-OptionalPropertyString -Object $Workflow -Name "target_execution_profile_proven") -eq "True"
        if (-not $profileProven -or
            [string]::IsNullOrWhiteSpace($expectedModel) -or
            [string]::IsNullOrWhiteSpace($expectedEffort) -or
            [string]::IsNullOrWhiteSpace($expectedTier) -or
            -not [bool]$LiveProof.execution_profile_proven) {
            throw "Workflow $($Workflow.workflow_ref) cannot safely rebind a rotated session because model, reasoning effort, and service tier continuity are not natively proven; restore the user-selected profile and retry."
        }
        if ([string]$LiveProof.model -cne $expectedModel -or
            [string]$LiveProof.reasoning_effort -cne $expectedEffort -or
            [string]$LiveProof.service_tier -cne $expectedTier) {
            throw "Workflow $($Workflow.workflow_ref) target model, reasoning effort, or service tier changed during session rotation; user action is required and no replacement was sent."
        }
        if ([string]$LiveProof.agent -ne [string]$current.target_agent -or
            [string]$LiveProof.tab_id -ne $targetTabId -or
            [string]$LiveProof.tab_label -cne [string]$request.target_tab_label) {
            throw "Workflow $($Workflow.workflow_ref) target pane, agent, tab, or stable label changed; session rotation is refused."
        }
        if ([string]$LiveProof.session_id -eq $oldSession) {
            throw "Workflow $($Workflow.workflow_ref) does not have a native-session rotation to reissue."
        }
        $ackDeadline = Get-OptionalPropertyDateTimeUtc -Object $request -Name "ack_deadline_utc"
        if ($null -eq $ackDeadline) {
            throw "Workflow $($Workflow.workflow_ref) lacks a valid original ACK deadline; rotation reissue is refused."
        }
        if ($NowUtc.ToUniversalTime() -ge $ackDeadline) {
            throw "Workflow $($Workflow.workflow_ref) exceeded its original ACK deadline; rotation reissue cannot extend the hard budget."
        }

        $attempt = New-LedgerEventObject -Fields @{
            event = "request_reissue_reserved"
            workflow_ref = [string]$Workflow.workflow_ref
            job_key = [string]$Workflow.job_key
            reissue_attempt_id = New-WorkflowId -Prefix "WR"
            superseded_relay_ref = $oldRelay
            original_target_session = $oldSession
            target_pane = [string]$LiveProof.pane_id
            target_agent = [string]$LiveProof.agent
            target_session = [string]$LiveProof.session_id
            target_tab_id = [string]$LiveProof.tab_id
            target_tab_label = [string]$LiveProof.tab_label
            target_model = $expectedModel
            target_reasoning_effort = $expectedEffort
            target_service_tier = $expectedTier
            target_execution_profile_proven = $true
            message_sha256 = Get-ShortHash -Text $message -Length 64
            artifact_path = Get-OptionalPropertyString -Object $request -Name "artifact_path"
            ack_deadline_utc = $ackDeadline.ToUniversalTime().ToString("o")
            lease_expires_utc = $NowUtc.ToUniversalTime().AddMinutes(2).ToString("o")
        }
        Write-LedgerEventUnlocked -Event $attempt
        return [pscustomobject]@{
            reserved = $true
            duplicate = $false
            state = "reserved"
            event = $attempt
        }
    }
}

function Complete-WorkflowRequestReissue {
    param(
        [Parameter(Mandatory)]$Reservation,
        [Parameter(Mandatory)][bool]$Succeeded,
        [string]$ReplacementRelayRef,
        [object]$Delivery,
        [string]$ErrorMessage
    )

    return Invoke-WithLedgerLock {
        $events = Read-LedgerUnlocked
        $attemptId = Get-OptionalPropertyString -Object $Reservation -Name "reissue_attempt_id"
        $existing = @($events | Where-Object {
                $_.event -in @("request_reissued", "request_reissue_failed") -and
                (Get-OptionalPropertyString -Object $_ -Name "reissue_attempt_id") -eq $attemptId
            } | Select-Object -Last 1)
        if ($existing.Count) {
            return [pscustomobject]@{
                duplicate = $true
                event = $existing[0]
            }
        }
        $fields = @{
            event = if ($Succeeded) { "request_reissued" } else { "request_reissue_failed" }
            workflow_ref = [string]$Reservation.workflow_ref
            job_key = [string]$Reservation.job_key
            reissue_attempt_id = $attemptId
            superseded_relay_ref = [string]$Reservation.superseded_relay_ref
            original_target_session = [string]$Reservation.original_target_session
            target_pane = [string]$Reservation.target_pane
            target_agent = [string]$Reservation.target_agent
            target_session = [string]$Reservation.target_session
            target_tab_id = [string]$Reservation.target_tab_id
            target_tab_label = [string]$Reservation.target_tab_label
            target_model = [string]$Reservation.target_model
            target_reasoning_effort = [string]$Reservation.target_reasoning_effort
            target_service_tier = [string]$Reservation.target_service_tier
            target_execution_profile_proven = [bool]$Reservation.target_execution_profile_proven
            replacement_relay_ref = if ($Succeeded) { $ReplacementRelayRef } else { $null }
            delivery_token = if ($Delivery) { Get-OptionalPropertyString -Object $Delivery -Name "token" } else { $null }
            delivery_state = if ($Delivery) { Get-OptionalPropertyString -Object $Delivery -Name "delivery_state" } else { "failed" }
            transport_accepted = if ($Delivery) { [bool]$Delivery.submitted } else { $false }
            artifact_path = [string]$Reservation.artifact_path
            ack_deadline_utc = [string]$Reservation.ack_deadline_utc
            superseded = $true
            error = $ErrorMessage
        }
        $event = New-LedgerEventObject -Fields $fields
        Write-LedgerEventUnlocked -Event $event
        return [pscustomobject]@{
            duplicate = $false
            event = $event
        }
    }
}

function Invoke-WorkflowRequestReissueDelivery {
    param(
        [Parameter(Mandatory)]$Workflow,
        [Parameter(Mandatory)]$Reservation,
        [Parameter(Mandatory)]$LiveProof
    )

    $request = $Workflow.request
    $replacementRelayRef = New-WorkflowId -Prefix "HR"
    $oldRelay = [string]$Reservation.superseded_relay_ref
    $workflowRef = [string]$Workflow.workflow_ref
    $artifact = Get-OptionalPropertyString -Object $request -Name "artifact_path"
    $message = Get-OptionalPropertyString -Object $request -Name "message"
    $body = "$replacementRelayRef $workflowRef TASK $($Workflow.task_id); CANDIDATE $($Workflow.candidate_id); TYPE $($Workflow.review_type). REISSUE-OF $oldRelay because the target native session rotated before its work ACK. $message"
    if (-not [string]::IsNullOrWhiteSpace($artifact)) {
        $body += " ARTIFACT $artifact"
    }

    $coordination = $null
    $delivery = $null
    try {
        $coordination = Invoke-CoordinationHelper -Arguments @(
            "-Action", "append",
            "-To", [string]$LiveProof.pane_id,
            "-Message", $body,
            "-LogPath", $CoordinationLogPath
        )
        $notice = "WORK REQUEST $workflowRef $replacementRelayRef REISSUED FROM $oldRelay after a verified native-session rotation. Read the exact matching coordination entry in $CoordinationLogPath. ACK immediately with herdr_workflow.ps1 -Action ack -WorkflowRef $workflowRef. The original delivery attempt is superseded; do not execute it separately. After running the workflow ACK command above, immediately execute the instructions in the replacement relay body as your current task; the ACK is a receipt, not completion; do not end your turn after ACKing."
        $deliveryResponse = Invoke-CoordinationHelper -Arguments @(
            "-Action", "deliver",
            "-PaneId", [string]$LiveProof.pane_id,
            "-Message", $notice,
            "-ExpectedAgent", [string]$LiveProof.agent,
            "-ExpectedSession", [string]$LiveProof.session_id,
            "-ExpectedTabLabel", [string]$LiveProof.tab_label,
            "-ExpectedTabId", [string]$LiveProof.tab_id,
            "-LogPath", $CoordinationLogPath
        )
        $delivery = $deliveryResponse.delivery
        if ($null -eq $delivery -or -not [bool]$delivery.submitted) {
            $errorText = if ($delivery) {
                Get-OptionalPropertyString -Object $delivery -Name "error"
            }
            else {
                "Coordination helper returned no delivery result."
            }
            throw "Workflow replacement delivery failed: $errorText"
        }
        return [pscustomobject]@{
            succeeded = $true
            replacement_relay_ref = $replacementRelayRef
            coordination = $coordination
            delivery = $delivery
            error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            succeeded = $false
            replacement_relay_ref = $replacementRelayRef
            coordination = $coordination
            delivery = $delivery
            error = $_.Exception.Message
        }
    }
}

function Get-OptionalPropertyString {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) {
        return $null
    }
    return [string]$property.Value
}

function Get-OptionalPropertyDateTimeUtc {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value) {
        return $null
    }
    $value = $property.Value
    if ($value -is [datetimeoffset]) {
        return $value.UtcDateTime
    }
    if ($value -is [datetime]) {
        return $value.ToUniversalTime()
    }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse(
            [string]$value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

function Get-OptionalProfileString {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property -or $null -eq $property.Value -or $property.Value -isnot [string]) {
        return $null
    }
    $value = ([string]$property.Value).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }
    return $value
}

function Test-ContainsOrdinalIgnoreCase {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Value
    )
    return $Text.IndexOf($Value, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-OutcomeToken {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ExpectedOutcome
    )
    $pattern = "(?i)(?<![A-Za-z0-9])$([regex]::Escape($ExpectedOutcome))(?![A-Za-z0-9])"
    return [regex]::IsMatch($Text, $pattern)
}

function Test-ContainsRelayReference {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ExpectedRelayRef
    )
    $relayMatch = [regex]::Match(
        $ExpectedRelayRef,
        "^\[HR:(?<id>[0-9a-fA-F]{8})\]$",
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $relayMatch.Success) {
        return $false
    }
    $relayId = [regex]::Escape($relayMatch.Groups["id"].Value)
    return [regex]::IsMatch(
        $Text,
        "(?i)\[(?:re\s+)?HR:$relayId\]"
    )
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        return [Convert]::ToHexString($bytes).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Test-ReconciledCompletionEquivalent {
    param(
        [Parameter(Mandatory)]$Completion,
        [Parameter(Mandatory)][string]$ExpectedOutcome,
        [Parameter(Mandatory)][string]$ExpectedArtifactPath,
        [Parameter(Mandatory)][string]$ExpectedArtifactSha256,
        [Parameter(Mandatory)][string]$ExpectedEvidenceRelayRef
    )

    if ([string]$Completion.outcome -ine $ExpectedOutcome) {
        return $false
    }
    $existingArtifact = Get-OptionalPropertyString -Object $Completion -Name "artifact_path"
    if ([string]::IsNullOrWhiteSpace($existingArtifact) -or
        [IO.Path]::GetFullPath($existingArtifact) -ine $ExpectedArtifactPath) {
        return $false
    }

    if ([string]$Completion.event -eq "completion_reconciled") {
        return (Get-OptionalPropertyString -Object $Completion -Name "artifact_sha256") -ieq $ExpectedArtifactSha256 -and
            (Get-OptionalPropertyString -Object $Completion -Name "evidence_relay_ref") -eq $ExpectedEvidenceRelayRef
    }
    return $true
}

function Get-VerifiedCoordinatorCaller {
    $callerPane = [string]$env:HERDR_PANE_ID
    if ([string]::IsNullOrWhiteSpace($callerPane)) {
        throw "Completion reconciliation requires a stable caller pane ID."
    }
    $discovery = Invoke-CoordinationHelper -Arguments @(
        "-Action", "discover",
        "-LogPath", $CoordinationLogPath
    )
    if (-not [bool]$discovery.found -or [bool]$discovery.ambiguous) {
        throw "Completion reconciliation requires one unambiguous Coordination pane."
    }
    if ($callerPane -ne [string]$discovery.coordinator.pane_id) {
        throw "Completion reconciliation is coordinator-only; caller pane $callerPane is not $($discovery.coordinator.pane_id)."
    }

    $agentResponse = Invoke-HerdrJson -Arguments @("agent", "get", $callerPane)
    $agent = $agentResponse.result.agent
    $session = Get-AgentSessionId -Agent $agent
    if ([string]::IsNullOrWhiteSpace($session) -or
        (Get-AgentSessionKind -Agent $agent) -ne [string]$agent.agent) {
        throw "Completion reconciliation requires matching native-session proof for the coordinator."
    }
    $null = Assert-WorkflowCallerProof `
        -PaneId $callerPane `
        -Agent ([string]$agent.agent) `
        -Session $session
    return [pscustomobject]@{
        pane_id = $callerPane
        agent = [string]$agent.agent
        session = $session
    }
}

function Get-CompletionReconciliationProof {
    param(
        [Parameter(Mandatory)]$Workflow,
        [Parameter(Mandatory)][string]$TargetPaneId,
        [Parameter(Mandatory)][string]$TargetSessionId,
        [Parameter(Mandatory)][string]$ExpectedCandidateId,
        [Parameter(Mandatory)][string]$ExpectedOutcome,
        [Parameter(Mandatory)][string]$ExpectedArtifactPath,
        [Parameter(Mandatory)][string]$ExpectedArtifactSha256,
        [Parameter(Mandatory)][string]$RelayRef
    )

    if (-not $Workflow.ack) {
        throw "Completion reconciliation requires a proven work ACK."
    }
    if ($TargetPaneId -ne [string]$Workflow.target_pane -or
        $TargetPaneId -ne [string]$Workflow.request.target_pane -or
        $TargetPaneId -ne [string]$Workflow.ack.actor_pane) {
        throw "Completion reconciliation target pane does not match the request and work ACK."
    }
    if ($TargetSessionId -ne [string]$Workflow.request.target_session -or
        $TargetSessionId -ne [string]$Workflow.ack.actor_session) {
        throw "Completion reconciliation target session does not match the request and work ACK."
    }
    if ($ExpectedCandidateId -cne [string]$Workflow.candidate_id) {
        throw "Completion reconciliation candidate does not match the reserved workflow candidate."
    }

    $requestArtifact = [string]$Workflow.request.artifact_path
    if ([string]::IsNullOrWhiteSpace($requestArtifact) -or
        [IO.Path]::GetFullPath($requestArtifact) -ine $ExpectedArtifactPath) {
        throw "Completion reconciliation artifact path does not match the requested workflow artifact."
    }
    if (-not (Test-Path -LiteralPath $ExpectedArtifactPath -PathType Leaf)) {
        throw "Completion reconciliation artifact does not exist: $ExpectedArtifactPath"
    }

    $targetResponse = Invoke-HerdrJson -Arguments @("agent", "get", $TargetPaneId)
    $targetAgent = $targetResponse.result.agent
    $liveTargetSession = Get-AgentSessionId -Agent $targetAgent
    if ([string]$targetAgent.pane_id -ne $TargetPaneId -or
        [string]$targetAgent.agent -ne [string]$Workflow.request.target_agent -or
        (Get-AgentSessionKind -Agent $targetAgent) -ne [string]$targetAgent.agent -or
        $liveTargetSession -ne $TargetSessionId) {
        throw "Completion reconciliation requires the original target's restored live native-session proof."
    }
    if ([string]$targetAgent.agent_status -notin @("idle", "done")) {
        throw "Completion reconciliation requires the original target session to be idle or done."
    }

    if (-not (Test-Path -LiteralPath $CoordinationLogPath -PathType Leaf)) {
        throw "Completion reconciliation log does not exist: $CoordinationLogPath"
    }
    $matches = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $CoordinationLogPath) {
        $ownRelayMatch = [regex]::Match(
            $line,
            "^\s*-\s*\[[^\]\r\n]+\]\s+FROM\s+\S+\s+TO\s+[^:]+:\s*(?<relay>\[HR:[0-9a-fA-F]{8}\])(?:\s|$)",
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($ownRelayMatch.Success -and
            $ownRelayMatch.Groups["relay"].Value -eq $RelayRef) {
            $matches.Add([string]$line)
        }
    }
    if ($matches.Count -ne 1) {
        throw "Completion reconciliation requires exactly one durable evidence entry for $RelayRef."
    }
    $evidenceLine = [string]$matches[0]
    $routeMatch = [regex]::Match(
        $evidenceLine,
        "^\s*-\s*\[[^\]\r\n]+\]\s+FROM\s+(?<from>\S+)\s+TO\s+(?<to>[^:]+):\s+(?<body>.*)$",
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $routeMatch.Success -or
        $routeMatch.Groups["from"].Value -ne $TargetPaneId -or
        $routeMatch.Groups["to"].Value.Trim() -ine "coordinator") {
        throw "Completion reconciliation evidence must be a durable FROM-target TO-coordinator entry."
    }
    $evidenceBody = $routeMatch.Groups["body"].Value
    foreach ($requiredText in @(
            $RelayRef,
            [string]$Workflow.workflow_ref,
            $ExpectedArtifactPath
        )) {
        if (-not (Test-ContainsOrdinalIgnoreCase -Text $evidenceBody -Value $requiredText)) {
            throw "Completion reconciliation evidence is missing required text: $requiredText"
        }
    }
    if (-not (Test-ContainsRelayReference `
            -Text $evidenceBody `
            -ExpectedRelayRef ([string]$Workflow.request.relay_ref))) {
        throw "Completion reconciliation evidence does not reference the exact request relay."
    }
    $candidateParts = @($ExpectedCandidateId -split "\+" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        })
    foreach ($candidatePart in $candidateParts) {
        if (-not (Test-ContainsOrdinalIgnoreCase -Text $evidenceBody -Value $candidatePart.Trim())) {
            throw "Completion reconciliation evidence does not contain the exact workflow candidate."
        }
    }
    if (-not (Test-OutcomeToken -Text $evidenceBody -ExpectedOutcome $ExpectedOutcome)) {
        throw "Completion reconciliation evidence does not contain the exact outcome."
    }

    $artifactSnapshot = Read-WorkflowArtifactSnapshot -Path $ExpectedArtifactPath
    $artifactText = [string]$artifactSnapshot.text
    foreach ($requiredText in @([string]$Workflow.workflow_ref)) {
        if (-not (Test-ContainsOrdinalIgnoreCase -Text $artifactText -Value $requiredText)) {
            throw "Completion reconciliation artifact is missing required text: $requiredText"
        }
    }
    if (-not (Test-ContainsRelayReference `
            -Text $artifactText `
            -ExpectedRelayRef ([string]$Workflow.request.relay_ref))) {
        throw "Completion reconciliation artifact does not reference the exact request relay."
    }
    foreach ($candidatePart in $candidateParts) {
        if (-not (Test-ContainsOrdinalIgnoreCase -Text $artifactText -Value $candidatePart.Trim())) {
            throw "Completion reconciliation artifact does not contain the exact workflow candidate."
        }
    }
    if (-not (Test-OutcomeToken -Text $artifactText -ExpectedOutcome $ExpectedOutcome)) {
        throw "Completion reconciliation artifact does not contain the exact outcome."
    }

    $observedHash = [string]$artifactSnapshot.sha256
    if ($observedHash -ne $ExpectedArtifactSha256) {
        throw "Completion reconciliation artifact hash does not match -ArtifactSha256."
    }
    return [pscustomobject]@{
        target_agent = [string]$targetAgent.agent
        target_session = $liveTargetSession
        target_revision = [long]$targetAgent.revision
        target_state_change_seq = [long]$targetAgent.state_change_seq
        evidence_line = $evidenceLine
        evidence_line_sha256 = Get-TextSha256 -Text $evidenceLine
        artifact_path = $ExpectedArtifactPath
        artifact_sha256 = $observedHash
        artifact_length = [long]$artifactSnapshot.length
    }
}

function Get-WorkflowSourceProof {
    param([string]$SourcePaneId = [string]$env:HERDR_PANE_ID)

    if ([string]::IsNullOrWhiteSpace($SourcePaneId)) {
        throw "Workflow request source pane is unavailable."
    }
    $response = Invoke-HerdrJson -Arguments @("agent", "get", $SourcePaneId)
    $agent = $response.result.agent
    if ([string]$agent.pane_id -ne $SourcePaneId) {
        throw "Workflow request source proof resolved a different pane."
    }
    $agentKind = [string]$agent.agent
    if ([string]::IsNullOrWhiteSpace($agentKind)) {
        throw "Workflow request source pane $SourcePaneId does not contain a detected agent."
    }
    $session = Get-AgentSessionId -Agent $agent
    $sessionAgent = Get-AgentSessionKind -Agent $agent
    if ([string]::IsNullOrWhiteSpace($session) -or $sessionAgent -ne $agentKind) {
        throw "Workflow request source pane $SourcePaneId lacks matching native agent-session proof."
    }
    $tabIdProperty = $agent.PSObject.Properties["tab_id"]
    if ($null -eq $tabIdProperty -or
        [string]::IsNullOrWhiteSpace([string]$tabIdProperty.Value)) {
        throw "Workflow request source pane $SourcePaneId lacks a resolvable tab ID."
    }
    $tabId = [string]$tabIdProperty.Value
    $tabResponse = Invoke-HerdrJson -Arguments @("tab", "get", $tabId)
    $tab = $tabResponse.result.tab
    if ($null -eq $tab -or [string]$tab.tab_id -ne $tabId -or
        [string]::IsNullOrWhiteSpace([string]$tab.label)) {
        throw "Workflow request source pane $SourcePaneId lacks a resolvable stable tab label."
    }
    return [pscustomobject]@{
        pane_id = $SourcePaneId
        agent = $agentKind
        session_id = $session
        revision = [long]$agent.revision
        state_change_seq = [long]$agent.state_change_seq
        tab_id = $tabId
        tab_label = [string]$tab.label
        model = Get-OptionalProfileString -Object $agent -Name "model"
        reasoning_effort = Get-OptionalProfileString -Object $agent -Name "reasoning_effort"
        service_tier = Get-OptionalProfileString -Object $agent -Name "service_tier"
        execution_profile_proven = $null -ne (Get-OptionalProfileString -Object $agent -Name "model") -and
            $null -ne (Get-OptionalProfileString -Object $agent -Name "reasoning_effort") -and
            $null -ne (Get-OptionalProfileString -Object $agent -Name "service_tier")
        subtitle = Get-AgentWorkSubtitle -Agent $agent
    }
}

function Reserve-WorkflowRequest {
    param(
        [Parameter(Mandatory)][string]$JobKey,
        [Parameter(Mandatory)]$Preflight,
        [Parameter(Mandatory)]$SourceProof,
        [Parameter(Mandatory)][int]$AckTimeoutSeconds,
        [Parameter(Mandatory)][int]$CompletionTimeoutSeconds,
        [object]$SourceRegistryBinding,
        [object]$TargetRegistryBinding
    )

    return Invoke-WithLedgerLock {
        $events = Read-LedgerUnlocked
        $existing = @($events | Where-Object {
                $_.event -eq "request_reserved" -and [string]$_.job_key -eq $JobKey
            } | Select-Object -Last 1)
        if ($existing.Count) {
            $existingSourceAgent = Get-OptionalPropertyString -Object $existing[0] -Name "source_agent"
            $existingSourceSession = Get-OptionalPropertyString -Object $existing[0] -Name "source_session"
            if ([string]$existing[0].source_pane -ne [string]$SourceProof.pane_id -or
                $existingSourceAgent -ne [string]$SourceProof.agent -or
                $existingSourceSession -ne [string]$SourceProof.session_id) {
                throw "Duplicate workflow request refused because the originating pane or native session differs."
            }
            foreach ($registryField in @(
                    @{ Event = "source_registry_id"; Binding = "registry_id"; Value = $SourceRegistryBinding },
                    @{ Event = "source_registry_binding_id"; Binding = "binding_id"; Value = $SourceRegistryBinding },
                    @{ Event = "source_registry_name"; Binding = "canonical_name"; Value = $SourceRegistryBinding },
                    @{ Event = "source_registry_generation"; Binding = "generation"; Value = $SourceRegistryBinding },
                    @{ Event = "target_registry_id"; Binding = "registry_id"; Value = $TargetRegistryBinding },
                    @{ Event = "target_registry_binding_id"; Binding = "binding_id"; Value = $TargetRegistryBinding },
                    @{ Event = "target_registry_name"; Binding = "canonical_name"; Value = $TargetRegistryBinding },
                    @{ Event = "target_registry_generation"; Binding = "generation"; Value = $TargetRegistryBinding }
                )) {
                if ($null -eq $registryField.Value) {
                    $existingValue = Get-OptionalPropertyString -Object $existing[0] -Name $registryField.Event
                    if ($registryField.Event -match '_generation$') {
                        if ([string]::IsNullOrWhiteSpace($existingValue) -or $existingValue -eq "0") {
                            continue
                        }
                    }
                    elseif ([string]::IsNullOrWhiteSpace($existingValue)) {
                        continue
                    }
                    throw "Duplicate workflow request refused because registry provenance changed."
                }
                $expectedValue = if ($null -ne $registryField.Value) {
                    [string]$registryField.Value.PSObject.Properties[[string]$registryField.Binding].Value
                }
                else { "" }
                $existingValue = Get-OptionalPropertyString -Object $existing[0] -Name $registryField.Event
                if ($existingValue -ne $expectedValue -and -not ([string]::IsNullOrWhiteSpace($existingValue) -and [string]::IsNullOrWhiteSpace($expectedValue))) {
                    throw "Duplicate workflow request refused because registry provenance changed."
                }
            }
            $existingWorkflowRef = [string]$existing[0].workflow_ref
            $requestAlreadyRecorded = @($events | Where-Object {
                    $_.event -eq "request" -and
                    [string]$_.workflow_ref -eq $existingWorkflowRef
                }).Count -gt 0
            if ($requestAlreadyRecorded) {
                return [pscustomobject]@{
                    duplicate = $true
                    delivery_claimed = $false
                    reservation = $existing[0]
                }
            }
            $storedMessage = Get-OptionalPropertyString -Object $existing[0] -Name "message"
            $storedArtifact = Get-OptionalPropertyString -Object $existing[0] -Name "artifact_path"
            if ([string]::IsNullOrWhiteSpace($storedMessage) -or
                $storedMessage -cne [string]$Message -or
                $storedArtifact -cne [string]$ArtifactPath) {
                throw "Duplicate workflow request refused because its message or artifact differs from the original reservation."
            }
            $storedAckDeadline = Get-OptionalPropertyDateTimeUtc -Object $existing[0] -Name "ack_deadline_utc"
            if ($null -eq $storedAckDeadline) {
                throw "Reserved workflow predates the original ACK deadline metadata and cannot be resumed safely."
            }
            $storedCompletionTimeout = Get-OptionalPropertyString -Object $existing[0] -Name "completion_timeout_seconds"
            if ([string]::IsNullOrWhiteSpace($storedCompletionTimeout) -or
                [int]$storedCompletionTimeout -ne $CompletionTimeoutSeconds) {
                throw "Duplicate workflow request refused because its completion timeout differs from the original reservation."
            }
            if ([string]$existing[0].target_tab_id -ne [string]$Preflight.tab_id -or
                [string]$existing[0].target_model -cne [string]$Preflight.model -or
                [string]$existing[0].target_reasoning_effort -cne [string]$Preflight.reasoning_effort -or
                [string]$existing[0].target_service_tier -cne [string]$Preflight.service_tier -or
                [bool]$existing[0].target_execution_profile_proven -ne [bool]$Preflight.execution_profile_proven) {
                throw "Duplicate workflow request refused because target tab or execution profile provenance changed."
            }
            $activeClaim = @($events | Where-Object {
                    $_.event -eq "request_delivery_reserved" -and
                    [string]$_.workflow_ref -eq $existingWorkflowRef
                } | Sort-Object timestamp_utc -Descending | Select-Object -First 1)
            # A delivery claim is a fencing token, not a reclaimable timer.
            # An expired or malformed lease cannot prove that its owner stopped
            # before the external prompt transport ran, so fail closed until a
            # durable terminal request event exists.
            if (-not $activeClaim.Count) {
                $claimEvent = New-LedgerEventObject -Fields @{
                    event = "request_delivery_reserved"
                    workflow_ref = $existingWorkflowRef
                    job_key = [string]$existing[0].job_key
                    relay_ref = Get-OptionalPropertyString -Object $existing[0] -Name "relay_ref"
                    delivery_attempt_id = New-WorkflowId -Prefix "WD"
                    claimant_pane = [string]$SourceProof.pane_id
                    claimant_agent = [string]$SourceProof.agent
                    claimant_session = [string]$SourceProof.session_id
                    lease_expires_utc = $NowUtc.ToUniversalTime().AddMinutes(2).ToString("o")
                }
                Write-LedgerEventUnlocked -Event $claimEvent
                return [pscustomobject]@{
                    duplicate = $true
                    delivery_claimed = $true
                    resumed = $true
                    delivery_claim = $claimEvent
                    reservation = $existing[0]
                }
            }
            return [pscustomobject]@{
                duplicate = $true
                delivery_claimed = $false
                delivery_claim = if ($activeClaim.Count) { $activeClaim[0] } else { $null }
                reservation = $existing[0]
            }
        }

        $ref = New-WorkflowId -Prefix "WF"
        $relayRef = New-WorkflowId -Prefix "HR"
        $reservation = [ordered]@{
            schema = 1
            event_id = New-WorkflowId -Prefix "WE"
            timestamp_utc = $NowUtc.ToUniversalTime().ToString("o")
            event = "request_reserved"
            workflow_ref = $ref
            relay_ref = $relayRef
            job_key = $JobKey
            task_id = $TaskId.Trim()
            candidate_id = $CandidateId.Trim()
            review_type = $ReviewType.Trim()
            source_pane = [string]$SourceProof.pane_id
            source_agent = [string]$SourceProof.agent
            source_session = [string]$SourceProof.session_id
            source_tab_id = [string]$SourceProof.tab_id
            source_tab_label = [string]$SourceProof.tab_label
            target_pane = [string]$Preflight.pane_id
            target_agent = [string]$Preflight.agent
            target_session = [string]$Preflight.session_id
            target_tab_id = [string]$Preflight.tab_id
            target_tab_label = [string]$Preflight.tab_label
            target_model = [string]$Preflight.model
            target_reasoning_effort = [string]$Preflight.reasoning_effort
            target_service_tier = [string]$Preflight.service_tier
            target_execution_profile_proven = [bool]$Preflight.execution_profile_proven
            message = $Message
            artifact_path = $ArtifactPath
            ack_deadline_utc = $NowUtc.ToUniversalTime().AddSeconds($AckTimeoutSeconds).ToString("o")
            completion_timeout_seconds = $CompletionTimeoutSeconds
            source_registry_id = if ($SourceRegistryBinding) { [string]$SourceRegistryBinding.registry_id } else { $null }
            source_registry_binding_id = if ($SourceRegistryBinding) { [string]$SourceRegistryBinding.binding_id } else { $null }
            source_registry_name = if ($SourceRegistryBinding) { [string]$SourceRegistryBinding.canonical_name } else { $null }
            source_registry_generation = if ($SourceRegistryBinding) { [long]$SourceRegistryBinding.generation } else { 0 }
            target_registry_id = if ($TargetRegistryBinding) { [string]$TargetRegistryBinding.registry_id } else { $null }
            target_registry_binding_id = if ($TargetRegistryBinding) { [string]$TargetRegistryBinding.binding_id } else { $null }
            target_registry_name = if ($TargetRegistryBinding) { [string]$TargetRegistryBinding.canonical_name } else { $null }
            target_registry_generation = if ($TargetRegistryBinding) { [long]$TargetRegistryBinding.generation } else { 0 }
        }
        Write-LedgerEventUnlocked -Event $reservation
        $claimEvent = New-LedgerEventObject -Fields @{
            event = "request_delivery_reserved"
            workflow_ref = $ref
            job_key = $JobKey
            relay_ref = $relayRef
            delivery_attempt_id = New-WorkflowId -Prefix "WD"
            claimant_pane = [string]$SourceProof.pane_id
            claimant_agent = [string]$SourceProof.agent
            claimant_session = [string]$SourceProof.session_id
            lease_expires_utc = $NowUtc.ToUniversalTime().AddMinutes(2).ToString("o")
        }
        Write-LedgerEventUnlocked -Event $claimEvent
        return [pscustomobject]@{
            duplicate = $false
            delivery_claimed = $true
            delivery_claim = $claimEvent
            reservation = [pscustomobject]$reservation
        }
    }
}

function Send-CoordinatorNotice {
    param([Parameter(Mandatory)][string]$Body)
    if ($NoCoordinatorNotice) {
        return $null
    }
    return Invoke-CoordinationHelper -Arguments @(
        "-Action", "send",
        "-To", "coordinator",
        "-Message", $Body,
        "-LogPath", $CoordinationLogPath
    )
}

function Assert-WorkflowDeliveryClaim {
    param(
        [Parameter(Mandatory)][string]$WorkflowReference,
        [Parameter(Mandatory)][string]$DeliveryAttemptId,
        [Parameter(Mandatory)]$SourceProof
    )

    return Invoke-WithLedgerLock {
        $events = Read-LedgerUnlocked
        $workflow = Get-WorkflowByRef -Events $events -Ref $WorkflowReference
        if ($workflow.request) {
            throw "Workflow $WorkflowReference already has a terminal delivery event; the delivery claim is fenced."
        }
        $claim = @($events | Where-Object {
                $_.event -eq "request_delivery_reserved" -and
                [string]$_.workflow_ref -eq $WorkflowReference
            } | Sort-Object timestamp_utc -Descending | Select-Object -First 1)
        if (-not $claim.Count -or
            [string]$claim[0].delivery_attempt_id -cne $DeliveryAttemptId) {
            throw "Workflow $WorkflowReference delivery claim was superseded or is unavailable; no duplicate transport is allowed."
        }
        if ([string]$claim[0].claimant_pane -cne [string]$SourceProof.pane_id -or
            [string]$claim[0].claimant_agent -cne [string]$SourceProof.agent -or
            [string]$claim[0].claimant_session -cne [string]$SourceProof.session_id) {
            throw "Workflow $WorkflowReference delivery claim is bound to a different source pane or native session."
        }
        return $claim[0]
    }
}

function Get-WatcherResultForToken {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token) -or -not (Test-Path -LiteralPath $WatchLogPath)) {
        return $null
    }
    $result = $null
    foreach ($line in Get-Content -LiteralPath $WatchLogPath) {
        $jsonStart = $line.IndexOf("{")
        if ($jsonStart -lt 0) {
            continue
        }
        try {
            $candidate = $line.Substring($jsonStart) | ConvertFrom-Json -Depth 20
            $candidateToken = Get-OptionalPropertyString -Object $candidate -Name "token"
            if ($candidateToken -ceq $Token) {
                $result = $candidate
            }
        }
        catch {
            continue
        }
    }
    return $result
}

function Get-CompletionReturnStateUnlocked {
    param(
        [Parameter(Mandatory)][object[]]$Events,
        [Parameter(Mandatory)][string]$WorkflowReference,
        [Parameter(Mandatory)][string]$CompletionEventId
    )

    $read = @($Events | Where-Object {
            $_.event -eq "completion_return_read" -and
            [string]$_.workflow_ref -eq $WorkflowReference -and
            (Get-OptionalPropertyString -Object $_ -Name "completion_event_id") -eq $CompletionEventId
        } | Select-Object -Last 1)
    if ($read.Count) {
        return [pscustomobject]@{
            state = "succeeded"
            event = $read[0]
            watcher = $null
        }
    }

    $returned = @($Events | Where-Object {
            $_.event -eq "completion_returned" -and
            [string]$_.workflow_ref -eq $WorkflowReference -and
            (Get-OptionalPropertyString -Object $_ -Name "completion_event_id") -eq $CompletionEventId
        } | Select-Object -Last 1)
    if ($returned.Count) {
        $returnEvent = $returned[0]
        $watchProperty = $returnEvent.PSObject.Properties["watch_started"]
        $watchStarted = $watchProperty -and [bool]$watchProperty.Value
        if ($watchStarted) {
            $watchResult = Get-WatcherResultForToken `
                -Token (Get-OptionalPropertyString -Object $returnEvent -Name "delivery_token")
            if ($watchResult) {
                if ([bool]$watchResult.submitted) {
                    return [pscustomobject]@{
                        state = "pending"
                        event = $returnEvent
                        watcher = $watchResult
                    }
                }
                return [pscustomobject]@{
                    state = "failed"
                    event = $returnEvent
                    watcher = $watchResult
                }
            }
            return [pscustomobject]@{
                state = "pending"
                event = $returnEvent
                watcher = $null
            }
        }
        return [pscustomobject]@{
            state = "pending"
            event = $returnEvent
            watcher = $null
        }
    }
    return [pscustomobject]@{
        state = "none"
        event = $null
        watcher = $null
    }
}

function Reserve-CompletionReturnAttempt {
    param(
        [Parameter(Mandatory)]$Workflow,
        [Parameter(Mandatory)]$Completion
    )

    return Invoke-WithLedgerLock {
        $events = Read-LedgerUnlocked
        $state = Get-CompletionReturnStateUnlocked `
            -Events $events `
            -WorkflowReference ([string]$Workflow.workflow_ref) `
            -CompletionEventId ([string]$Completion.event_id)
        if ($state.state -in @("succeeded", "pending")) {
            return [pscustomobject]@{
                reserved = $false
                state = $state.state
                event = $state.event
                watcher = $state.watcher
            }
        }

        $reservations = @($events | Where-Object {
                $_.event -eq "completion_return_reserved" -and
                [string]$_.workflow_ref -eq [string]$Workflow.workflow_ref -and
                (Get-OptionalPropertyString -Object $_ -Name "completion_event_id") -eq [string]$Completion.event_id
            })
        foreach ($reservation in ($reservations | Sort-Object timestamp_utc -Descending)) {
            $attemptId = Get-OptionalPropertyString -Object $reservation -Name "return_attempt_id"
            $terminal = @($events | Where-Object {
                    $_.event -in @("completion_returned", "completion_return_failed") -and
                    (Get-OptionalPropertyString -Object $_ -Name "return_attempt_id") -eq $attemptId
                }).Count -gt 0
            if ($terminal) {
                continue
            }
            $leaseText = Get-OptionalPropertyString -Object $reservation -Name "lease_expires_utc"
            $leaseExpires = [datetime]::MinValue
            if ([datetime]::TryParse($leaseText, [ref]$leaseExpires) -and
                $NowUtc.ToUniversalTime() -lt $leaseExpires.ToUniversalTime()) {
                return [pscustomobject]@{
                    reserved = $false
                    state = "in_progress"
                    event = $reservation
                    watcher = $null
                }
            }
            break
        }

        $attempt = [ordered]@{
            schema = 1
            event_id = New-WorkflowId -Prefix "WE"
            timestamp_utc = $NowUtc.ToUniversalTime().ToString("o")
            event = "completion_return_reserved"
            workflow_ref = [string]$Workflow.workflow_ref
            job_key = [string]$Workflow.job_key
            completion_event_id = [string]$Completion.event_id
            return_attempt_id = New-WorkflowId -Prefix "WR"
            source_pane = [string]$Workflow.source_pane
            source_agent = [string]$Workflow.source_agent
            source_session = [string]$Workflow.source_session
            lease_expires_utc = $NowUtc.ToUniversalTime().AddMinutes(2).ToString("o")
        }
        Write-LedgerEventUnlocked -Event $attempt
        return [pscustomobject]@{
            reserved = $true
            state = "reserved"
            event = [pscustomobject]$attempt
            watcher = $null
        }
    }
}

function Get-CompletionReturnEvidence {
    param([Parameter(Mandatory)]$Completion)

    $message = Get-OptionalPropertyString -Object $Completion -Name "message"
    $artifactPath = Get-OptionalPropertyString -Object $Completion -Name "artifact_path"
    $artifactText = $null
    $artifactSha256 = $null
    if (-not [string]::IsNullOrWhiteSpace($artifactPath) -and
        (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        try {
            $snapshot = Read-WorkflowArtifactSnapshot -Path $artifactPath
            $artifactText = [string]$snapshot.text
            $artifactSha256 = [string]$snapshot.sha256
            $recordedHash = Get-OptionalPropertyString -Object $Completion -Name "artifact_sha256"
            if (-not [string]::IsNullOrWhiteSpace($recordedHash) -and
                $artifactSha256 -ne $recordedHash) {
                throw "Completion artifact changed after its durable completion event."
            }
        }
        catch {
            if ($_.Exception.Message -match 'changed after its durable completion event') {
                throw
            }
            $artifactText = $null
            $artifactSha256 = $null
        }
    }

    $evidenceText = if (-not [string]::IsNullOrWhiteSpace($artifactText)) {
        $artifactText
    }
    elseif (-not [string]::IsNullOrWhiteSpace($message)) {
        $message
    }
    else {
        throw "Completion return requires either a readable UTF-8 artifact of at most 64 KiB or a self-contained -Message."
    }

    return [pscustomobject]@{
        text = ($evidenceText -replace "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]+", " ").Trim()
        source = if (-not [string]::IsNullOrWhiteSpace($artifactText)) { "artifact" } else { "message" }
        artifact_sha256 = $artifactSha256
    }
}

function Invoke-CompletionReturn {
    param(
        [Parameter(Mandatory)]$Workflow,
        [Parameter(Mandatory)]$Completion
    )

    $reservation = Reserve-CompletionReturnAttempt -Workflow $Workflow -Completion $Completion
    if (-not [bool]$reservation.reserved) {
        return [pscustomobject]@{
            returned = $reservation.state -eq "succeeded"
            duplicate = $reservation.state -eq "succeeded"
            pending = $reservation.state -in @("pending", "in_progress")
            state = [string]$reservation.state
            event = $reservation.event
            delivery = $null
            error = if ($reservation.state -eq "failed" -and $reservation.watcher) {
                [string]$reservation.watcher.error
            }
            else {
                $null
            }
        }
    }

    $attempt = $reservation.event
    $delivery = $null
    try {
        $expectedAgent = [string]$Workflow.source_agent
        $expectedSession = [string]$Workflow.source_session
        $expectedSourceTabId = Get-OptionalPropertyString -Object $Workflow -Name "source_tab_id"
        $expectedSourceTabLabel = Get-OptionalPropertyString -Object $Workflow -Name "source_tab_label"
        if ([string]::IsNullOrWhiteSpace($expectedAgent) -or
            [string]::IsNullOrWhiteSpace($expectedSession) -or
            [string]::IsNullOrWhiteSpace($expectedSourceTabId) -or
            [string]::IsNullOrWhiteSpace($expectedSourceTabLabel)) {
            throw "Workflow request lacks exact originating agent-session, tab, and stable-label proof; completion return is fail-closed."
        }
        $sourceProof = Get-WorkflowSourceProof -SourcePaneId ([string]$Workflow.source_pane)
        if ([string]$sourceProof.agent -ne $expectedAgent -or
            [string]$sourceProof.session_id -ne $expectedSession -or
            [string]$sourceProof.tab_id -ne $expectedSourceTabId -or
            [string]$sourceProof.tab_label -cne $expectedSourceTabLabel) {
            throw "Originating builder pane no longer hosts the exact native session, tab, and stable label recorded by the request."
        }
        $sourceRegistryBinding = $null
        $sourceRegistryId = Get-OptionalPropertyString -Object $Workflow -Name "source_registry_id"
        if (-not [string]::IsNullOrWhiteSpace($sourceRegistryId)) {
            $sourceRegistryBinding = [pscustomobject]@{
                registry_id = $sourceRegistryId
                binding_id = Get-OptionalPropertyString -Object $Workflow -Name "source_registry_binding_id"
                canonical_name = Get-OptionalPropertyString -Object $Workflow -Name "source_registry_name"
                generation = [long](Get-OptionalPropertyString -Object $Workflow -Name "source_registry_generation")
            }
            if ([string]::IsNullOrWhiteSpace([string]$sourceRegistryBinding.binding_id) -or
                [string]::IsNullOrWhiteSpace([string]$sourceRegistryBinding.canonical_name) -or
                [long]$sourceRegistryBinding.generation -lt 1) {
                throw "Workflow source registry provenance is incomplete."
            }
        }

        $artifact = if ([string]::IsNullOrWhiteSpace([string]$Completion.artifact_path)) {
            "(none)"
        }
        else {
            [string]$Completion.artifact_path
        }
        $reviewerPane = if (-not [string]::IsNullOrWhiteSpace(
                (Get-OptionalPropertyString -Object $Completion -Name "actor_pane"))) {
            Get-OptionalPropertyString -Object $Completion -Name "actor_pane"
        }
        else {
            Get-OptionalPropertyString -Object $Completion -Name "target_pane"
        }
        $evidence = Get-CompletionReturnEvidence -Completion $Completion
        $body = "WORKFLOW COMPLETE RETURN $($Workflow.workflow_ref); TASK $($Workflow.task_id); " +
            "CANDIDATE $($Workflow.candidate_id); TYPE $($Workflow.review_type); " +
            "OUTCOME $($Completion.outcome); REVIEWER $reviewerPane; ARTIFACT $artifact. " +
            "ARTIFACT-SHA256 $($evidence.artifact_sha256); EVIDENCE-SOURCE $($evidence.source); " +
            "VERDICT BODY: $($evidence.text) Completion $($Completion.event_id) is durable. " +
            "Read this complete verdict body, then run the exact ack-return command in the pointer notice. " +
            "If this exact workflow/candidate/outcome " +
            "was already handled, acknowledge it without repeating work."
        $deliveryArguments = @(
            "-Action", "send",
            "-From", $reviewerPane,
            "-To", [string]$Workflow.source_pane,
            "-WorkflowRef", [string]$Workflow.workflow_ref,
            "-WorkflowLedgerPath", $LedgerPath,
            "-Message", $body,
            "-ExpectedAgent", $expectedAgent,
            "-ExpectedSession", $expectedSession,
            "-ExpectedTabLabel", $expectedSourceTabLabel,
            "-ExpectedTabId", $expectedSourceTabId,
            "-LogPath", $CoordinationLogPath
        ) + @(Get-WorkflowRegistryArguments -Binding $sourceRegistryBinding)
        $deliveryResponse = Invoke-CoordinationHelper -Arguments $deliveryArguments
        $delivery = $deliveryResponse.delivery
        $returnRelayRef = Get-OptionalPropertyString -Object $deliveryResponse -Name "relay_ref"
        if ($null -eq $delivery -or -not [bool]$delivery.submitted) {
            $deliveryError = if ($delivery) {
                Get-OptionalPropertyString -Object $delivery -Name "error"
            }
            else {
                "Coordination helper returned no delivery result."
            }
            throw "Origin completion return was not accepted: $deliveryError"
        }

        $postProof = Get-WorkflowSourceProof -SourcePaneId ([string]$Workflow.source_pane)
        if ([string]$postProof.agent -ne $expectedAgent -or
            [string]$postProof.session_id -ne $expectedSession -or
            [string]$postProof.tab_id -ne $expectedSourceTabId -or
            [string]$postProof.tab_label -cne $expectedSourceTabLabel) {
            throw "Originating builder native-session, tab, or stable-label proof changed during completion return."
        }
        $watchProperty = $delivery.PSObject.Properties["watch_started"]
        $returnEvent = Add-LedgerEvent -Fields @{
            event = "completion_returned"
            workflow_ref = [string]$Workflow.workflow_ref
            job_key = [string]$Workflow.job_key
            completion_event_id = [string]$Completion.event_id
            return_attempt_id = [string]$attempt.return_attempt_id
            source_pane = [string]$Workflow.source_pane
            source_agent = $expectedAgent
            source_session = $expectedSession
            source_revision = [long]$postProof.revision
            source_state_change_seq = [long]$postProof.state_change_seq
            reviewer_pane = $reviewerPane
            outcome = [string]$Completion.outcome
            artifact_path = [string]$Completion.artifact_path
            artifact_sha256 = $evidence.artifact_sha256
            evidence_source = $evidence.source
            return_relay_ref = $returnRelayRef
            notice_submitted = $true
            body_read = $false
            read_ack_deadline_utc = $NowUtc.AddSeconds($AckTimeoutSeconds).ToString("o")
            delivery_token = Get-OptionalPropertyString -Object $delivery -Name "token"
            delivery_state = Get-OptionalPropertyString -Object $delivery -Name "delivery_state"
            transport = Get-OptionalPropertyString -Object $delivery -Name "transport"
            queued = if ($delivery.PSObject.Properties["queued"]) { [bool]$delivery.queued } else { $false }
            watch_started = if ($watchProperty) { [bool]$watchProperty.Value } else { $false }
        }
        return [pscustomobject]@{
            returned = $false
            duplicate = $false
            pending = $true
            state = "awaiting_read_ack"
            event = $returnEvent
            delivery = $delivery
            error = $null
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        $failureEvent = Add-LedgerEvent -Fields @{
            event = "completion_return_failed"
            workflow_ref = [string]$Workflow.workflow_ref
            job_key = [string]$Workflow.job_key
            completion_event_id = [string]$Completion.event_id
            return_attempt_id = [string]$attempt.return_attempt_id
            source_pane = [string]$Workflow.source_pane
            source_agent = [string]$Workflow.source_agent
            source_session = [string]$Workflow.source_session
            outcome = [string]$Completion.outcome
            artifact_path = [string]$Completion.artifact_path
            delivery_token = if ($delivery) {
                Get-OptionalPropertyString -Object $delivery -Name "token"
            }
            else {
                $null
            }
            delivery_state = if ($delivery) {
                Get-OptionalPropertyString -Object $delivery -Name "delivery_state"
            }
            else {
                "failed"
            }
            error = $errorMessage
        }
        return [pscustomobject]@{
            returned = $false
            duplicate = $false
            pending = $false
            state = "failed"
            event = $failureEvent
            delivery = $delivery
            error = $errorMessage
        }
    }
}

$NowUtc = $NowUtc.ToUniversalTime()

switch ($Action) {
    "preflight" {
        if ([string]::IsNullOrWhiteSpace($PaneId)) {
            throw "-PaneId is required for preflight."
        }
        $preflightRegistryBinding = Resolve-WorkflowRegistryTarget -Target $PaneId
        if ($preflightRegistryBinding) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedTabLabel) -and
                $ExpectedTabLabel -cne [string]$preflightRegistryBinding.tab_label) {
                throw "Expected tab label does not match the resolved registry binding."
            }
            $PaneId = [string]$preflightRegistryBinding.pane_id
            $ExpectedTabLabel = [string]$preflightRegistryBinding.tab_label
        }
        [pscustomobject]@{
            action = "preflight"
            registry_binding = $preflightRegistryBinding
            preflight = Get-Preflight `
                -TargetPaneId $PaneId `
                -RequiredTabLabel $ExpectedTabLabel `
                -PermitWorking:$AllowWorking
        } | ConvertTo-Json -Depth 10
    }
    "request" {
        if ([string]::IsNullOrWhiteSpace($PaneId)) {
            throw "-PaneId is required for request."
        }
        $targetRegistryBinding = Resolve-WorkflowRegistryTarget -Target $PaneId
        if ($targetRegistryBinding) {
            if (-not [string]::IsNullOrWhiteSpace($ExpectedTabLabel) -and
                $ExpectedTabLabel -cne [string]$targetRegistryBinding.tab_label) {
                throw "Expected tab label does not match the resolved registry binding."
            }
            $PaneId = [string]$targetRegistryBinding.pane_id
            $ExpectedTabLabel = [string]$targetRegistryBinding.tab_label
        }
        foreach ($required in @(
                @{ Name = "TaskId"; Value = $TaskId },
                @{ Name = "CandidateId"; Value = $CandidateId },
                @{ Name = "ReviewType"; Value = $ReviewType },
                @{ Name = "PaneId"; Value = $PaneId },
                @{ Name = "ExpectedTabLabel"; Value = $ExpectedTabLabel },
                @{ Name = "Message"; Value = $Message }
            )) {
            if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
                throw "-$($required.Name) is required for request."
            }
        }

        $preflight = Get-Preflight `
            -TargetPaneId $PaneId `
            -RequiredTabLabel $ExpectedTabLabel `
            -PermitWorking:$AllowWorking
        if (-not $preflight.ready) {
            [pscustomobject]@{
                action = "request"
                created = $false
                duplicate = $false
                preflight = $preflight
                error = "Reviewer preflight failed: $($preflight.reasons -join '; ')."
            } | ConvertTo-Json -Depth 10
            break
        }

        $jobKey = Get-JobKey -Task $TaskId -Candidate $CandidateId -Type $ReviewType
        $sourceProof = Get-WorkflowSourceProof
        $null = Assert-WorkflowCallerProof `
            -PaneId ([string]$sourceProof.pane_id) `
            -Agent ([string]$sourceProof.agent) `
            -Session ([string]$sourceProof.session_id)
        $sourceRegistryBinding = Resolve-WorkflowRegistryTarget -Target ([string]$sourceProof.pane_id)
        $subtitleCurrency = New-SubtitleCurrencyReport `
            -TaskId $TaskId `
            -PaneId ([string]$sourceProof.pane_id) `
            -Subtitle ([string]$sourceProof.subtitle) `
            -CanonicalName (Resolve-PaneCanonicalName `
                -RegistryBinding $sourceRegistryBinding `
                -TabLabel ([string]$sourceProof.tab_label)) `
            -AgentKind ([string]$sourceProof.agent) `
            -SessionId ([string]$sourceProof.session_id) `
            -WorkTitle (Get-EffectiveSubtitleWorkTitle -Fallback $ReviewType)
        $reservationResult = Reserve-WorkflowRequest `
            -JobKey $jobKey `
            -Preflight $preflight `
            -SourceProof $sourceProof `
            -AckTimeoutSeconds $AckTimeoutSeconds `
            -CompletionTimeoutSeconds $CompletionTimeoutSeconds `
            -SourceRegistryBinding $sourceRegistryBinding `
            -TargetRegistryBinding $targetRegistryBinding
        $resumedReservation = $false
        if ($reservationResult.duplicate) {
            $events = Get-LedgerEvents
            $existing = Get-WorkflowByRef -Events $events -Ref ([string]$reservationResult.reservation.workflow_ref)
            if ([string]$existing.status -ne "reserved") {
                [pscustomobject]@{
                    action = "request"
                    created = $false
                    duplicate = $true
                    resumed = $false
                    workflow = $existing
                    preflight = $preflight
                    subtitle_task_token = $subtitleCurrency.subtitle_task_token
                    subtitle_current = $subtitleCurrency.subtitle_current
                    subtitle_stale = [bool]$subtitleCurrency.subtitle_stale
                    subtitle_hint = $subtitleCurrency.subtitle_hint
                    subtitle_request_fired = [bool]$subtitleCurrency.subtitle_request_fired
                    subtitle_request_error = $subtitleCurrency.subtitle_request_error
                    error = $null
                } | ConvertTo-Json -Depth 15
                break
            }
            $reservedRelayRef = Get-OptionalPropertyString -Object $reservationResult.reservation -Name "relay_ref"
            if ([string]::IsNullOrWhiteSpace($reservedRelayRef)) {
                throw "Reserved workflow predates crash-safe relay identity and cannot be resumed automatically."
            }
            if ([string]$reservationResult.reservation.target_pane -ne [string]$preflight.pane_id -or
                [string]$reservationResult.reservation.target_agent -ne [string]$preflight.agent -or
                [string]$reservationResult.reservation.target_session -ne [string]$preflight.session_id -or
                [string]$reservationResult.reservation.target_tab_label -cne [string]$preflight.tab_label) {
                throw "Reserved workflow target provenance changed; crash recovery is refused."
            }
            if (-not [bool]$reservationResult.delivery_claimed) {
                [pscustomobject]@{
                    action = "request"
                    created = $false
                    duplicate = $true
                    resumed = $false
                    delivery_in_progress = $true
                    workflow = $existing
                    preflight = $preflight
                    subtitle_task_token = $subtitleCurrency.subtitle_task_token
                    subtitle_current = $subtitleCurrency.subtitle_current
                    subtitle_stale = [bool]$subtitleCurrency.subtitle_stale
                    subtitle_hint = $subtitleCurrency.subtitle_hint
                    subtitle_request_fired = [bool]$subtitleCurrency.subtitle_request_fired
                    subtitle_request_error = [string]$subtitleCurrency.subtitle_request_error
                    error = "An equivalent workflow delivery is already in progress; no duplicate notice was sent."
                } | ConvertTo-Json -Depth 15
                break
            }
            $resumedReservation = $true
        }

        $workflowRefValue = [string]$reservationResult.reservation.workflow_ref
        $relayRef = [string]$reservationResult.reservation.relay_ref
        $deliveryClaim = $reservationResult.delivery_claim
        $deliveryAttemptId = Get-OptionalPropertyString -Object $deliveryClaim -Name "delivery_attempt_id"
        if ([string]::IsNullOrWhiteSpace($deliveryAttemptId)) {
            throw "Workflow $workflowRefValue has no durable delivery fencing claim."
        }
        $requestTaskId = Get-OptionalPropertyString -Object $reservationResult.reservation -Name "task_id"
        $requestCandidateId = Get-OptionalPropertyString -Object $reservationResult.reservation -Name "candidate_id"
        $requestReviewType = Get-OptionalPropertyString -Object $reservationResult.reservation -Name "review_type"
        $requestMessage = Get-OptionalPropertyString -Object $reservationResult.reservation -Name "message"
        $requestArtifactPath = Get-OptionalPropertyString -Object $reservationResult.reservation -Name "artifact_path"
        $requestAckDeadline = Get-OptionalPropertyDateTimeUtc -Object $reservationResult.reservation -Name "ack_deadline_utc"
        $requestCompletionTimeout = Get-OptionalPropertyString -Object $reservationResult.reservation -Name "completion_timeout_seconds"
        if ([string]::IsNullOrWhiteSpace($requestTaskId) -or
            [string]::IsNullOrWhiteSpace($requestCandidateId) -or
            [string]::IsNullOrWhiteSpace($requestReviewType) -or
            [string]::IsNullOrWhiteSpace($requestMessage) -or
            $null -eq $requestAckDeadline -or
            [string]::IsNullOrWhiteSpace($requestCompletionTimeout)) {
            throw "Workflow $workflowRefValue lacks complete immutable request metadata; delivery is refused."
        }
        $body = "$relayRef $workflowRefValue TASK $requestTaskId; CANDIDATE $requestCandidateId; TYPE $requestReviewType. $requestMessage"
        if (-not [string]::IsNullOrWhiteSpace($requestArtifactPath)) {
            $body += " ARTIFACT $requestArtifactPath"
        }

        $null = Assert-WorkflowDeliveryClaim `
            -WorkflowReference $workflowRefValue `
            -DeliveryAttemptId $deliveryAttemptId `
            -SourceProof $sourceProof

        $coordination = $null
        $delivery = $null
        $requestError = $null
        try {
            $coordination = Invoke-CoordinationHelper -Arguments @(
                "-Action", "append",
                "-To", $PaneId,
                "-Message", $body,
                "-LogPath", $CoordinationLogPath
            )
            $notice = "WORK REQUEST $workflowRefValue $relayRef. Read the exact matching coordination entry in $CoordinationLogPath. ACK immediately with herdr_workflow.ps1 -Action ack -WorkflowRef $workflowRefValue. After running the workflow ACK command above, immediately execute the instructions in the relay body as your current task; the ACK is a receipt, not completion; do not end your turn after ACKing."
            $deliveryArguments = @(
                "-Action", "deliver",
                "-PaneId", $PaneId,
                "-Message", $notice,
                "-ExpectedAgent", [string]$preflight.agent,
                "-ExpectedSession", [string]$preflight.session_id,
                "-ExpectedTabLabel", $ExpectedTabLabel,
                "-ExpectedTabId", [string]$preflight.tab_id,
                "-LogPath", $CoordinationLogPath
            ) + @(Get-WorkflowRegistryArguments -Binding $targetRegistryBinding)
            $deliveryResponse = Invoke-CoordinationHelper -Arguments $deliveryArguments
            $delivery = $deliveryResponse.delivery
            $null = Assert-WorkflowDeliveryClaim `
                -WorkflowReference $workflowRefValue `
                -DeliveryAttemptId $deliveryAttemptId `
                -SourceProof $sourceProof
        }
        catch {
            $requestError = $_.Exception.Message
        }

        $transportAccepted = $null -ne $delivery -and [bool]$delivery.submitted -and [string]::IsNullOrWhiteSpace($requestError)
        $requestEvent = Add-LedgerEvent -Fields @{
            event = "request"
            workflow_ref = $workflowRefValue
            job_key = $jobKey
            relay_ref = $relayRef
            source_pane = [string]$sourceProof.pane_id
            source_agent = [string]$sourceProof.agent
            source_session = [string]$sourceProof.session_id
            source_tab_id = [string]$sourceProof.tab_id
            source_tab_label = [string]$sourceProof.tab_label
            target_pane = $PaneId
            target_agent = Get-OptionalPropertyString -Object $reservationResult.reservation -Name "target_agent"
            target_session = Get-OptionalPropertyString -Object $reservationResult.reservation -Name "target_session"
            target_tab_id = Get-OptionalPropertyString -Object $reservationResult.reservation -Name "target_tab_id"
            target_tab_label = Get-OptionalPropertyString -Object $reservationResult.reservation -Name "target_tab_label"
            target_model = Get-OptionalProfileString -Object $reservationResult.reservation -Name "target_model"
            target_reasoning_effort = Get-OptionalProfileString -Object $reservationResult.reservation -Name "target_reasoning_effort"
            target_service_tier = Get-OptionalProfileString -Object $reservationResult.reservation -Name "target_service_tier"
            target_execution_profile_proven = [bool]$reservationResult.reservation.target_execution_profile_proven
            delivery_attempt_id = $deliveryAttemptId
            source_registry_id = if ($sourceRegistryBinding) { [string]$sourceRegistryBinding.registry_id } else { $null }
            source_registry_binding_id = if ($sourceRegistryBinding) { [string]$sourceRegistryBinding.binding_id } else { $null }
            source_registry_name = if ($sourceRegistryBinding) { [string]$sourceRegistryBinding.canonical_name } else { $null }
            source_registry_generation = if ($sourceRegistryBinding) { [long]$sourceRegistryBinding.generation } else { 0 }
            target_registry_id = if ($targetRegistryBinding) { [string]$targetRegistryBinding.registry_id } else { $null }
            target_registry_binding_id = if ($targetRegistryBinding) { [string]$targetRegistryBinding.binding_id } else { $null }
            target_registry_name = if ($targetRegistryBinding) { [string]$targetRegistryBinding.canonical_name } else { $null }
            target_registry_generation = if ($targetRegistryBinding) { [long]$targetRegistryBinding.generation } else { 0 }
            transport_accepted = $transportAccepted
            delivery_token = if ($delivery) { [string]$delivery.token } else { $null }
            delivery_state = if ($delivery) { [string]$delivery.delivery_state } else { "failed" }
            ack_deadline_utc = $requestAckDeadline.ToString("o")
            completion_timeout_seconds = [int]$requestCompletionTimeout
            artifact_path = $requestArtifactPath
            message = $requestMessage
            error = if ($requestError) { $requestError } elseif ($delivery -and $delivery.error) { [string]$delivery.error } else { $null }
        }
        [pscustomobject]@{
            action = "request"
            created = $true
            duplicate = $false
            resumed = $resumedReservation
            workflow_ref = $workflowRefValue
            relay_ref = $relayRef
            job_key = $jobKey
            preflight = $preflight
            request = $requestEvent
            coordination = $coordination
            delivery = $delivery
            subtitle_task_token = $subtitleCurrency.subtitle_task_token
            subtitle_current = $subtitleCurrency.subtitle_current
            subtitle_stale = [bool]$subtitleCurrency.subtitle_stale
            subtitle_hint = $subtitleCurrency.subtitle_hint
            subtitle_request_fired = [bool]$subtitleCurrency.subtitle_request_fired
            subtitle_request_error = $subtitleCurrency.subtitle_request_error
            error = $requestEvent.error
        } | ConvertTo-Json -Depth 15
    }
    "ack" {
        if ([string]::IsNullOrWhiteSpace($WorkflowRef)) {
            throw "-WorkflowRef is required for ack."
        }
        $events = Get-LedgerEvents
        $workflow = Get-WorkflowByRef -Events $events -Ref $WorkflowRef
        $callerPane = [string]$env:HERDR_PANE_ID
        if ($callerPane -ne [string]$workflow.target_pane) {
            throw "ACK refused because caller pane $callerPane is not target pane $($workflow.target_pane)."
        }
        $targetProof = Get-WorkflowTargetProof -TargetPaneId $callerPane
        $agentResponse = Invoke-HerdrJson -Arguments @("agent", "get", $callerPane)
        $agent = $agentResponse.result.agent
        $session = [string]$targetProof.session_id
        $null = Assert-WorkflowCallerProof `
            -PaneId $callerPane `
            -Agent ([string]$agent.agent) `
            -Session $session

        $sessionRotated = $session -ne [string]$workflow.request.target_session
        if ($sessionRotated) {
            $reissueReservation = Reserve-WorkflowRequestReissue `
                -Workflow $workflow `
                -LiveProof $targetProof `
                -NowUtc $NowUtc
            if ([string]$reissueReservation.state -eq "in_progress") {
                throw "Workflow $WorkflowRef has a replacement delivery already in progress; no duplicate replacement will be sent. Retry after the recorded reissue lease or inspect its durable terminal event."
            }
            $reissueDelivery = $null
            $reissueFinalize = $null
            if ([bool]$reissueReservation.reserved) {
                $reissueDelivery = Invoke-WorkflowRequestReissueDelivery `
                    -Workflow $workflow `
                    -Reservation $reissueReservation.event `
                    -LiveProof $targetProof
                $reissueFinalize = Complete-WorkflowRequestReissue `
                    -Reservation $reissueReservation.event `
                    -Succeeded ([bool]$reissueDelivery.succeeded) `
                    -ReplacementRelayRef ([string]$reissueDelivery.replacement_relay_ref) `
                    -Delivery $reissueDelivery.delivery `
                    -ErrorMessage ([string]$reissueDelivery.error)
                if (-not [bool]$reissueDelivery.succeeded) {
                    throw [string]$reissueDelivery.error
                }
            }
            $reissueEvent = if ($reissueFinalize) {
                $reissueFinalize.event
            }
            else {
                $reissueReservation.event
            }
            $replacementRelayRef = Get-OptionalPropertyString `
                -Object $reissueEvent `
                -Name "replacement_relay_ref"
            $reissueNotice = Send-CoordinatorNotice `
                -Body "WORKFLOW REQUEST REISSUED $WorkflowRef from ${callerPane}: native session rotated from $($workflow.request.target_session) to $session; original relay $($workflow.request.relay_ref) superseded by $replacementRelayRef. Original ACK deadline remains $($workflow.request.ack_deadline_utc)."
            [pscustomobject]@{
                action = "ack"
                duplicate = $false
                session_rotated = $true
                reissued = $true
                reissue_state = [string]$reissueReservation.state
                workflow_ref = $WorkflowRef
                actor_pane = $callerPane
                actor_agent = [string]$agent.agent
                actor_session = $session
                original_target_session = [string]$workflow.request.target_session
                replacement_target_session = $session
                superseded_relay_ref = [string]$workflow.request.relay_ref
                replacement_relay_ref = $replacementRelayRef
                ack_deadline_utc = [string]$workflow.request.ack_deadline_utc
                coordinator_notice = $reissueNotice
                error = $null
            } | ConvertTo-Json -Depth 15
            break
        }

        # The work ACK runs from the assigned pane's OWN session, so this is the
        # moment the builder/reviewer can request its own name for the ticket it
        # just picked up - no reliance on the dispatch brief telling it to.
        $subtitleCurrency = New-SubtitleCurrencyReport `
            -TaskId ([string]$workflow.task_id) `
            -PaneId $callerPane `
            -Subtitle ([string](Get-AgentWorkSubtitle -Agent $agent)) `
            -CanonicalName (Get-CallerCanonicalName -PaneId $callerPane -Agent $agent) `
            -AgentKind ([string]$agent.agent) `
            -SessionId $session `
            -WorkTitle (Get-EffectiveSubtitleWorkTitle -Fallback ([string]$workflow.review_type))

        $ackTransaction = Invoke-WithLedgerLock {
            $currentWorkflow = Get-WorkflowByRef -Events (Read-LedgerUnlocked) -Ref $WorkflowRef
            if ($currentWorkflow.ack) {
                return [pscustomobject]@{
                    duplicate = $true
                    workflow = $currentWorkflow
                    event = $currentWorkflow.ack
                }
            }
            $currentTargetProof = Get-WorkflowTargetProof -TargetPaneId $callerPane
            if ($callerPane -ne [string]$currentWorkflow.target_pane -or
                [string]$currentTargetProof.agent -ne [string]$currentWorkflow.target_agent -or
                [string]$currentTargetProof.session_id -ne [string]$currentWorkflow.request.target_session -or
                [string]$currentTargetProof.tab_id -ne [string]$currentWorkflow.request.target_tab_id -or
                [string]$currentTargetProof.tab_label -cne [string]$currentWorkflow.request.target_tab_label) {
                throw "ACK refused because workflow provenance changed before the atomic ledger append."
            }
            $newAck = New-LedgerEventObject -Fields @{
                event = "work_ack"
                workflow_ref = $WorkflowRef
                job_key = [string]$currentWorkflow.job_key
                actor_pane = $callerPane
                actor_agent = [string]$agent.agent
                actor_session = $session
                message = if ($Message) { $Message } else { "STARTED" }
                completion_deadline_utc = $NowUtc.AddSeconds([int]$currentWorkflow.request.completion_timeout_seconds).ToString("o")
            }
            Write-LedgerEventUnlocked -Event $newAck
            return [pscustomobject]@{
                duplicate = $false
                workflow = $currentWorkflow
                event = $newAck
            }
        }
        if ([bool]$ackTransaction.duplicate) {
            [pscustomobject]@{
                action = "ack"
                duplicate = $true
                workflow = $ackTransaction.workflow
                subtitle_task_token = $subtitleCurrency.subtitle_task_token
                subtitle_current = $subtitleCurrency.subtitle_current
                subtitle_stale = [bool]$subtitleCurrency.subtitle_stale
                subtitle_hint = $subtitleCurrency.subtitle_hint
                subtitle_request_fired = [bool]$subtitleCurrency.subtitle_request_fired
                subtitle_request_error = $subtitleCurrency.subtitle_request_error
            } | ConvertTo-Json -Depth 15
            break
        }
        $ackEvent = $ackTransaction.event
        $notice = Send-CoordinatorNotice -Body "WORK ACK $WorkflowRef from ${callerPane}: $($ackEvent.message)."
        [pscustomobject]@{
            action = "ack"
            duplicate = $false
            ack = $ackEvent
            coordinator_notice = $notice
            subtitle_task_token = $subtitleCurrency.subtitle_task_token
            subtitle_current = $subtitleCurrency.subtitle_current
            subtitle_stale = [bool]$subtitleCurrency.subtitle_stale
            subtitle_hint = $subtitleCurrency.subtitle_hint
            subtitle_request_fired = [bool]$subtitleCurrency.subtitle_request_fired
            subtitle_request_error = $subtitleCurrency.subtitle_request_error
        } | ConvertTo-Json -Depth 15
    }
    "complete" {
        if ([string]::IsNullOrWhiteSpace($WorkflowRef) -or [string]::IsNullOrWhiteSpace($Outcome)) {
            throw "-WorkflowRef and -Outcome are required for complete."
        }
        $events = Get-LedgerEvents
        $workflow = Get-WorkflowByRef -Events $events -Ref $WorkflowRef
        $callerPane = [string]$env:HERDR_PANE_ID
        if ($callerPane -ne [string]$workflow.target_pane) {
            throw "Completion refused because caller pane $callerPane is not target pane $($workflow.target_pane)."
        }
        $agentResponse = Invoke-HerdrJson -Arguments @("agent", "get", $callerPane)
        $agent = $agentResponse.result.agent
        $session = Get-AgentSessionId -Agent $agent
        if ($session -ne [string]$workflow.request.target_session) {
            throw "Completion refused because the target native session does not match the request."
        }
        $null = Assert-WorkflowCallerProof `
            -PaneId $callerPane `
            -Agent ([string]$agent.agent) `
            -Session $session

        $subtitleCurrency = New-SubtitleCurrencyReport `
            -TaskId ([string]$workflow.task_id) `
            -PaneId $callerPane `
            -Subtitle ([string](Get-AgentWorkSubtitle -Agent $agent)) `
            -CanonicalName (Get-CallerCanonicalName -PaneId $callerPane -Agent $agent) `
            -AgentKind ([string]$agent.agent) `
            -SessionId $session `
            -WorkTitle (Get-EffectiveSubtitleWorkTitle -Fallback ([string]$workflow.review_type))

        $completionArtifactSnapshot = $null
        if (-not [string]::IsNullOrWhiteSpace($ArtifactPath)) {
            if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
                throw "Completion artifact does not exist: $ArtifactPath"
            }
            $completionArtifactSnapshot = Read-WorkflowArtifactSnapshot -Path $ArtifactPath
        }

        $coordinatorNotice = $null
        $completionTransaction = Invoke-WithLedgerLock {
            $currentWorkflow = Get-WorkflowByRef -Events (Read-LedgerUnlocked) -Ref $WorkflowRef
            if ($callerPane -ne [string]$currentWorkflow.target_pane -or
                $session -ne [string]$currentWorkflow.request.target_session) {
                throw "Completion refused because workflow provenance changed before the atomic ledger append."
            }
            if ($null -eq $currentWorkflow.ack) {
                throw "Completion refused because the workflow has no durable work ACK."
            }
            if ($currentWorkflow.completion) {
                $existingCompletion = $currentWorkflow.completion
                if ([string]$existingCompletion.outcome -ne $Outcome) {
                    throw "Duplicate completion conflicts with the existing outcome."
                }
                if (-not [string]::IsNullOrWhiteSpace($ArtifactPath)) {
                    if ([string]::IsNullOrWhiteSpace([string]$existingCompletion.artifact_path) -or
                        [IO.Path]::GetFullPath([string]$existingCompletion.artifact_path) -ne
                        [IO.Path]::GetFullPath($ArtifactPath)) {
                        throw "Duplicate completion conflicts with the existing artifact path."
                    }
                    $recordedArtifactHash = Get-OptionalPropertyString -Object $existingCompletion -Name "artifact_sha256"
                    if ([string]::IsNullOrWhiteSpace($recordedArtifactHash) -or
                        $null -eq $completionArtifactSnapshot -or
                        [string]$completionArtifactSnapshot.sha256 -ne $recordedArtifactHash) {
                        throw "Duplicate completion conflicts because the artifact content changed."
                    }
                }
                return [pscustomobject]@{
                    duplicate = $true
                    workflow = $currentWorkflow
                    event = $existingCompletion
                }
            }
            $newCompletion = New-LedgerEventObject -Fields @{
                event = "completed"
                workflow_ref = $WorkflowRef
                job_key = [string]$currentWorkflow.job_key
                actor_pane = $callerPane
                actor_agent = [string]$agent.agent
                actor_session = $session
                outcome = $Outcome
                artifact_path = $ArtifactPath
                artifact_sha256 = if ($completionArtifactSnapshot) { [string]$completionArtifactSnapshot.sha256 } else { $null }
                artifact_length = if ($completionArtifactSnapshot) { [long]$completionArtifactSnapshot.length } else { $null }
                message = $Message
            }
            Write-LedgerEventUnlocked -Event $newCompletion
            return [pscustomobject]@{
                duplicate = $false
                workflow = $currentWorkflow
                event = $newCompletion
            }
        }
        $isDuplicate = [bool]$completionTransaction.duplicate
        $workflow = $completionTransaction.workflow
        $completionEvent = $completionTransaction.event

        $originReturn = Invoke-CompletionReturn -Workflow $workflow -Completion $completionEvent
        if (-not $isDuplicate) {
            $returnSummary = if ([bool]$originReturn.returned) {
                "accepted by origin $($workflow.source_pane)"
            }
            elseif ([bool]$originReturn.pending) {
                "pending for origin $($workflow.source_pane)"
            }
            else {
                "FAILED for origin $($workflow.source_pane): $($originReturn.error)"
            }
            $coordinatorNotice = Send-CoordinatorNotice `
                -Body "WORK COMPLETE $WorkflowRef from ${callerPane}: $Outcome. Artifact: $ArtifactPath. Origin return $returnSummary."
        }
        elseif ([bool]$originReturn.returned -and -not [bool]$originReturn.duplicate) {
            $coordinatorNotice = Send-CoordinatorNotice `
                -Body "WORKFLOW RETURN RECOVERED $WorkflowRef to origin $($workflow.source_pane)."
        }
        [pscustomobject]@{
            action = "complete"
            duplicate = $isDuplicate
            completion = $completionEvent
            origin_return = $originReturn
            coordinator_notice = $coordinatorNotice
            subtitle_task_token = $subtitleCurrency.subtitle_task_token
            subtitle_current = $subtitleCurrency.subtitle_current
            subtitle_stale = [bool]$subtitleCurrency.subtitle_stale
            subtitle_hint = $subtitleCurrency.subtitle_hint
            subtitle_request_fired = [bool]$subtitleCurrency.subtitle_request_fired
            subtitle_request_error = $subtitleCurrency.subtitle_request_error
        } | ConvertTo-Json -Depth 20
    }
    "ack-return" {
        if ([string]::IsNullOrWhiteSpace($WorkflowRef)) {
            throw "-WorkflowRef is required for ack-return."
        }
        $events = Get-LedgerEvents
        $workflow = Get-WorkflowByRef -Events $events -Ref $WorkflowRef
        if ($null -eq $workflow.completion -or $null -eq $workflow.completion_return) {
            throw "Workflow $WorkflowRef has no submitted completion return to acknowledge."
        }
        $callerPane = [string]$env:HERDR_PANE_ID
        if ($callerPane -ne [string]$workflow.source_pane) {
            throw "Completion-return ACK refused because caller pane $callerPane is not origin pane $($workflow.source_pane)."
        }
        $sourceProof = Get-WorkflowSourceProof -SourcePaneId $callerPane
        if ([string]$sourceProof.agent -ne [string]$workflow.source_agent -or
            [string]::IsNullOrWhiteSpace([string]$workflow.source_tab_id) -or
            [string]$sourceProof.tab_id -ne [string]$workflow.source_tab_id -or
            [string]$sourceProof.tab_label -cne [string]$workflow.source_tab_label) {
            throw "Completion-return ACK refused because the originating pane's agent type, tab, or stable label changed."
        }
        $null = Assert-WorkflowCallerProof `
            -PaneId $callerPane `
            -Agent ([string]$sourceProof.agent) `
            -Session ([string]$sourceProof.session_id)
        $sourceSessionRotated = [string]$sourceProof.session_id -ne [string]$workflow.source_session

        $subtitleCurrency = New-SubtitleCurrencyReport `
            -TaskId ([string]$workflow.task_id) `
            -PaneId $callerPane `
            -Subtitle ([string]$sourceProof.subtitle) `
            -CanonicalName (Get-CallerCanonicalName `
                -PaneId $callerPane `
                -TabLabel ([string]$sourceProof.tab_label)) `
            -AgentKind ([string]$sourceProof.agent) `
            -SessionId ([string]$sourceProof.session_id) `
            -WorkTitle (Get-EffectiveSubtitleWorkTitle -Fallback ([string]$workflow.review_type))

        if ($workflow.completion_return_read) {
            [pscustomobject]@{
                action = "ack-return"
                duplicate = $true
                body_read = $true
                return_read = $workflow.completion_return_read
                subtitle_task_token = $subtitleCurrency.subtitle_task_token
                subtitle_current = $subtitleCurrency.subtitle_current
                subtitle_stale = [bool]$subtitleCurrency.subtitle_stale
                subtitle_hint = $subtitleCurrency.subtitle_hint
                subtitle_request_fired = [bool]$subtitleCurrency.subtitle_request_fired
                subtitle_request_error = $subtitleCurrency.subtitle_request_error
            } | ConvertTo-Json -Depth 20
            break
        }

        $returnRelayRef = Get-OptionalPropertyString `
            -Object $workflow.completion_return `
            -Name "return_relay_ref"
        if ($returnRelayRef -notmatch '^\[HR:[0-9a-fA-F]{8}\]$') {
            throw "Completion-return ACK refused because the return relay reference is missing or invalid."
        }
        $ackResponse = Invoke-CoordinationHelper -Arguments @(
            "-Action", "ack-read",
            "-RelayRef", $returnRelayRef,
            "-ExpectedSession", [string]$workflow.source_session,
            "-LogPath", $CoordinationLogPath
        )
        if (-not [bool]$ackResponse.body_read) {
            throw "Coordination helper did not prove completion-return body consumption."
        }
        $ackSessionRotated = Get-OptionalPropertyString -Object $ackResponse -Name "session_rotated"
        if ($sourceSessionRotated -and $ackSessionRotated -ne "True") {
            throw "Coordination helper did not prove a lineage-bound replacement for the rotated originating session."
        }

        $returnRead = Invoke-WithLedgerLock {
            $lockedEvents = Read-LedgerUnlocked
            $existing = @($lockedEvents | Where-Object {
                    $_.event -eq "completion_return_read" -and
                    [string]$_.workflow_ref -eq $WorkflowRef -and
                    (Get-OptionalPropertyString -Object $_ -Name "completion_event_id") -eq
                        [string]$workflow.completion.event_id
                } | Select-Object -Last 1)
            if ($existing.Count) {
                return $existing[0]
            }
            $event = [ordered]@{
                schema = 1
                event_id = New-WorkflowId -Prefix "WE"
                timestamp_utc = $NowUtc.ToUniversalTime().ToString("o")
                event = "completion_return_read"
                workflow_ref = $WorkflowRef
                job_key = [string]$workflow.job_key
                completion_event_id = [string]$workflow.completion.event_id
                completion_return_event_id = [string]$workflow.completion_return.event_id
                return_relay_ref = $returnRelayRef
                effective_return_relay_ref = Get-OptionalPropertyString -Object $ackResponse -Name "relay_ref"
                read_ack_ref = Get-OptionalPropertyString -Object $ackResponse.read_ack -Name "ack_ref"
                actor_pane = [string]$sourceProof.pane_id
                actor_agent = [string]$sourceProof.agent
                actor_session = [string]$sourceProof.session_id
                actor_tab_label = [string]$sourceProof.tab_label
                source_session_rotated = $sourceSessionRotated
                source_session_rotated_from = if ($sourceSessionRotated) { [string]$workflow.source_session } else { $null }
                body_read = $true
            }
            Write-LedgerEventUnlocked -Event $event
            return [pscustomobject]$event
        }
        [pscustomobject]@{
            action = "ack-return"
            duplicate = $false
            body_read = $true
            relay_ack = $ackResponse
            return_read = $returnRead
            subtitle_task_token = $subtitleCurrency.subtitle_task_token
            subtitle_current = $subtitleCurrency.subtitle_current
            subtitle_stale = [bool]$subtitleCurrency.subtitle_stale
            subtitle_hint = $subtitleCurrency.subtitle_hint
            subtitle_request_fired = [bool]$subtitleCurrency.subtitle_request_fired
            subtitle_request_error = $subtitleCurrency.subtitle_request_error
        } | ConvertTo-Json -Depth 20
    }
    "reconcile-return-read" {
        foreach ($required in @(
                @{ Name = "WorkflowRef"; Value = $WorkflowRef },
                @{ Name = "EvidenceRelayRef"; Value = $EvidenceRelayRef },
                @{ Name = "EvidenceAckRef"; Value = $EvidenceAckRef },
                @{ Name = "ExpectedSourceSession"; Value = $ExpectedSourceSession }
            )) {
            if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
                throw "-$($required.Name) is required for reconcile-return-read."
            }
        }

        $coordinator = Get-VerifiedCoordinatorCaller
        $events = Get-LedgerEvents
        $workflow = Get-WorkflowByRef -Events $events -Ref $WorkflowRef
        if ($null -eq $workflow.completion -or $null -eq $workflow.completion_return) {
            throw "Workflow $WorkflowRef has no submitted completion return to reconcile."
        }
        if ($ExpectedSourceSession -ne [string]$workflow.source_session) {
            throw "Return-read reconciliation source session does not match the workflow origin session."
        }

        $returnRelayRef = Get-OptionalPropertyString `
            -Object $workflow.completion_return `
            -Name "return_relay_ref"
        if ($EvidenceRelayRef -ne $returnRelayRef) {
            throw "Return-read reconciliation evidence relay does not match the recorded completion return."
        }

        if ($workflow.completion_return_read) {
            $existingAckRef = Get-OptionalPropertyString `
                -Object $workflow.completion_return_read `
                -Name "read_ack_ref"
            if ($existingAckRef -ne $EvidenceAckRef) {
                throw "Workflow $WorkflowRef already has a different completion-return read proof."
            }
            [pscustomobject]@{
                action = "reconcile-return-read"
                duplicate = $true
                body_read = $true
                return_read = $workflow.completion_return_read
            } | ConvertTo-Json -Depth 20
            break
        }

        $relayStatus = Invoke-CoordinationHelper -Arguments @(
            "-Action", "relay-status",
            "-RelayRef", $EvidenceRelayRef,
            "-LogPath", $CoordinationLogPath
        )
        if (-not [bool]$relayStatus.body_read -or
            [int]$relayStatus.conflicting_ack_count -ne 0 -or
            [bool]$relayStatus.superseded -or
            [string]$relayStatus.effective_relay_ref -ne $EvidenceRelayRef) {
            throw "Return-read reconciliation requires one unambiguous, unsuperseded durable read proof."
        }

        $readAck = $relayStatus.read_ack
        if ($null -eq $readAck -or
            (Get-OptionalPropertyString -Object $readAck -Name "ack_ref") -ne $EvidenceAckRef -or
            (Get-OptionalPropertyString -Object $readAck -Name "relay_ref") -ne $EvidenceRelayRef -or
            (Get-OptionalPropertyString -Object $readAck -Name "reader_pane_id") -ne [string]$workflow.source_pane -or
            (Get-OptionalPropertyString -Object $readAck -Name "reader_agent") -ne [string]$workflow.source_agent -or
            (Get-OptionalPropertyString -Object $readAck -Name "reader_session") -ne $ExpectedSourceSession -or
            (Get-OptionalPropertyString -Object $readAck -Name "returned_to") -ne [string]$workflow.target_pane) {
            throw "Return-read reconciliation proof does not match the workflow origin identity and return route."
        }
        if ((Get-OptionalPropertyString -Object $relayStatus.relay -Name "sender") -ne [string]$workflow.target_pane -or
            (Get-OptionalPropertyString -Object $relayStatus.relay -Name "recipient") -ne [string]$workflow.source_pane -or
            (Get-OptionalPropertyString -Object $relayStatus.relay -Name "recipient_session") -ne $ExpectedSourceSession) {
            throw "Return-read reconciliation relay route does not match the recorded workflow return."
        }

        $result = Invoke-WithLedgerLock {
            $lockedEvents = Read-LedgerUnlocked
            $existing = @($lockedEvents | Where-Object {
                    $_.event -eq "completion_return_read" -and
                    [string]$_.workflow_ref -eq $WorkflowRef -and
                    (Get-OptionalPropertyString -Object $_ -Name "completion_event_id") -eq
                        [string]$workflow.completion.event_id
                } | Select-Object -Last 1)
            if ($existing.Count) {
                $existingAckRef = Get-OptionalPropertyString -Object $existing[0] -Name "read_ack_ref"
                if ($existingAckRef -ne $EvidenceAckRef) {
                    throw "Workflow $WorkflowRef acquired a conflicting completion-return read proof during reconciliation."
                }
                return [pscustomobject]@{ duplicate = $true; event = $existing[0] }
            }

            $event = [ordered]@{
                schema = 1
                event_id = New-WorkflowId -Prefix "WE"
                timestamp_utc = $NowUtc.ToUniversalTime().ToString("o")
                event = "completion_return_read"
                workflow_ref = $WorkflowRef
                job_key = [string]$workflow.job_key
                completion_event_id = [string]$workflow.completion.event_id
                completion_return_event_id = [string]$workflow.completion_return.event_id
                return_relay_ref = $EvidenceRelayRef
                effective_return_relay_ref = [string]$relayStatus.effective_relay_ref
                read_ack_ref = $EvidenceAckRef
                actor_pane = [string]$workflow.source_pane
                actor_agent = [string]$workflow.source_agent
                actor_session = $ExpectedSourceSession
                actor_tab_label = [string]$workflow.source_tab_label
                source_session_rotated = $false
                source_session_rotated_from = $null
                body_read = $true
                reconciliation_policy = "coordinator_durable_return_read_v1"
                reconciled_by_pane = [string]$coordinator.pane_id
                reconciled_by_agent = [string]$coordinator.agent
                reconciled_by_session = [string]$coordinator.session
                reconciliation_evidence_relay_ref = $EvidenceRelayRef
                reconciliation_evidence_ack_ref = $EvidenceAckRef
            }
            Write-LedgerEventUnlocked -Event $event
            return [pscustomobject]@{ duplicate = $false; event = [pscustomobject]$event }
        }
        [pscustomobject]@{
            action = "reconcile-return-read"
            duplicate = [bool]$result.duplicate
            body_read = $true
            return_read = $result.event
        } | ConvertTo-Json -Depth 20
    }
    "reconcile-completion" {
        foreach ($required in @(
                @{ Name = "WorkflowRef"; Value = $WorkflowRef },
                @{ Name = "PaneId"; Value = $PaneId },
                @{ Name = "ExpectedTargetSession"; Value = $ExpectedTargetSession },
                @{ Name = "CandidateId"; Value = $CandidateId },
                @{ Name = "Outcome"; Value = $Outcome },
                @{ Name = "ArtifactPath"; Value = $ArtifactPath },
                @{ Name = "ArtifactSha256"; Value = $ArtifactSha256 },
                @{ Name = "EvidenceRelayRef"; Value = $EvidenceRelayRef }
            )) {
            if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
                throw "-$($required.Name) is required for reconcile-completion."
            }
        }
        if ($ArtifactSha256 -notmatch "^[0-9a-fA-F]{64}$") {
            throw "-ArtifactSha256 must be an exact 64-character SHA-256."
        }
        if ($EvidenceRelayRef -notmatch "^\[HR:[0-9a-fA-F]{8}\]$") {
            throw "-EvidenceRelayRef must be an exact [HR:xxxxxxxx] reference."
        }

        $normalizedArtifactPath = [IO.Path]::GetFullPath($ArtifactPath)
        $normalizedArtifactSha256 = $ArtifactSha256.ToLowerInvariant()
        $coordinator = Get-VerifiedCoordinatorCaller
        $result = Invoke-WithLedgerLock {
            $lockedEvents = Read-LedgerUnlocked
            $lockedWorkflow = Get-WorkflowByRef -Events $lockedEvents -Ref $WorkflowRef
            if ($lockedWorkflow.completion) {
                if (-not (Test-ReconciledCompletionEquivalent `
                        -Completion $lockedWorkflow.completion `
                        -ExpectedOutcome $Outcome `
                        -ExpectedArtifactPath $normalizedArtifactPath `
                        -ExpectedArtifactSha256 $normalizedArtifactSha256 `
                        -ExpectedEvidenceRelayRef $EvidenceRelayRef)) {
                    throw "Completion reconciliation conflicts with the existing workflow completion."
                }
                $proof = Get-CompletionReconciliationProof `
                    -Workflow $lockedWorkflow `
                    -TargetPaneId $PaneId `
                    -TargetSessionId $ExpectedTargetSession `
                    -ExpectedCandidateId $CandidateId `
                    -ExpectedOutcome $Outcome `
                    -ExpectedArtifactPath $normalizedArtifactPath `
                    -ExpectedArtifactSha256 $normalizedArtifactSha256 `
                    -RelayRef $EvidenceRelayRef
                return [pscustomobject]@{
                    duplicate = $true
                    completion = $lockedWorkflow.completion
                    proof = $proof
                }
            }

            $proof = Get-CompletionReconciliationProof `
                -Workflow $lockedWorkflow `
                -TargetPaneId $PaneId `
                -TargetSessionId $ExpectedTargetSession `
                -ExpectedCandidateId $CandidateId `
                -ExpectedOutcome $Outcome `
                -ExpectedArtifactPath $normalizedArtifactPath `
                -ExpectedArtifactSha256 $normalizedArtifactSha256 `
                -RelayRef $EvidenceRelayRef

            $event = [ordered]@{
                schema = 1
                event_id = New-WorkflowId -Prefix "WE"
                timestamp_utc = $NowUtc.ToUniversalTime().ToString("o")
                event = "completion_reconciled"
                workflow_ref = $WorkflowRef
                job_key = [string]$lockedWorkflow.job_key
                candidate_id = [string]$lockedWorkflow.candidate_id
                outcome = $Outcome
                artifact_path = $proof.artifact_path
                artifact_sha256 = $proof.artifact_sha256
                artifact_length = $proof.artifact_length
                evidence_relay_ref = $EvidenceRelayRef
                evidence_line_sha256 = $proof.evidence_line_sha256
                request_relay_ref = [string]$lockedWorkflow.request.relay_ref
                target_pane = $PaneId
                target_agent = $proof.target_agent
                target_session = $proof.target_session
                target_revision = $proof.target_revision
                target_state_change_seq = $proof.target_state_change_seq
                ack_event_id = [string]$lockedWorkflow.ack.event_id
                actor_pane = $coordinator.pane_id
                actor_agent = $coordinator.agent
                actor_session = $coordinator.session
                proof_policy = "coordinator+request_ack+restored_target_session+durable_relay+artifact_hash"
                message = $Message
            }
            Write-LedgerEventUnlocked -Event $event
            return [pscustomobject]@{
                duplicate = $false
                completion = [pscustomobject]$event
                proof = $proof
            }
        }
        $returnWorkflow = Get-WorkflowByRef -Events (Get-LedgerEvents) -Ref $WorkflowRef
        $originReturn = Invoke-CompletionReturn `
            -Workflow $returnWorkflow `
            -Completion $result.completion
        [pscustomobject]@{
            action = "reconcile-completion"
            duplicate = [bool]$result.duplicate
            completion = $result.completion
            origin_return = $originReturn
            proof = [pscustomobject]@{
                target_pane = $PaneId
                target_agent = $result.proof.target_agent
                target_session = $result.proof.target_session
                evidence_relay_ref = $EvidenceRelayRef
                evidence_line_sha256 = $result.proof.evidence_line_sha256
                artifact_path = $result.proof.artifact_path
                artifact_sha256 = $result.proof.artifact_sha256
                artifact_length = $result.proof.artifact_length
            }
        } | ConvertTo-Json -Depth 20
    }
    "status" {
        $events = Get-LedgerEvents
        $views = Get-TaskViews -Events $events
        if (-not [string]::IsNullOrWhiteSpace($WorkflowRef)) {
            $views = @($views | Where-Object { $_.workflow_ref -eq $WorkflowRef })
        }
        [pscustomobject]@{
            action = "status"
            ledger_path = $LedgerPath
            workflows = @($views)
        } | ConvertTo-Json -Depth 20
    }
    "scan" {
        $events = Get-LedgerEvents
        $views = Get-TaskViews -Events $events
        $newAlerts = [Collections.Generic.List[object]]::new()
        foreach ($workflow in $views) {
            $alertKind = $null
            $details = $null
            if ($workflow.status -eq "awaiting_ack") {
                $watchResult = Get-WatcherResultForToken -Token ([string]$workflow.request.delivery_token)
                if ($watchResult -and -not [bool]$watchResult.submitted) {
                    $alertKind = "transport_failed"
                    $details = [string]$watchResult.error
                }
                elseif ($NowUtc -ge [datetime]$workflow.request.ack_deadline_utc) {
                    $alertKind = "ack_timeout"
                    $details = "No work ACK arrived by $($workflow.request.ack_deadline_utc)."
                }
            }
            elseif ($workflow.status -eq "work_acknowledged" -and
                $NowUtc -ge [datetime]$workflow.ack.completion_deadline_utc) {
                $alertKind = "completion_timeout"
                $details = "No completion arrived by $($workflow.ack.completion_deadline_utc)."
            }
            elseif ($workflow.status -eq "completed") {
                if ($workflow.completion_return) {
                    $watchProperty = $workflow.completion_return.PSObject.Properties["watch_started"]
                    if ($watchProperty -and [bool]$watchProperty.Value) {
                        $watchResult = Get-WatcherResultForToken `
                            -Token (Get-OptionalPropertyString `
                                -Object $workflow.completion_return `
                                -Name "delivery_token")
                        if ($watchResult -and -not [bool]$watchResult.submitted) {
                            $alertKind = "completion_return_transport_failed"
                            $details = [string]$watchResult.error
                        }
                    }
                    if (-not $alertKind -and -not $workflow.completion_return_read) {
                        $readDeadlineText = Get-OptionalPropertyString `
                            -Object $workflow.completion_return `
                            -Name "read_ack_deadline_utc"
                        $readDeadline = [datetime]::MinValue
                        if ([datetime]::TryParse($readDeadlineText, [ref]$readDeadline) -and
                            $NowUtc -ge $readDeadline.ToUniversalTime()) {
                            $alertKind = "completion_return_read_timeout"
                            $details = "Origin received the completion pointer but did not prove reading the durable verdict body by $readDeadlineText."
                        }
                    }
                }
                elseif ($workflow.completion_return_failure) {
                    $alertKind = "completion_return_failed"
                    $details = Get-OptionalPropertyString `
                        -Object $workflow.completion_return_failure `
                        -Name "error"
                }
            }

            if (-not $alertKind) {
                continue
            }
            $alreadyAlerted = @($workflow.alerts | Where-Object { $_.alert_kind -eq $alertKind }).Count -gt 0
            if ($alreadyAlerted) {
                continue
            }
            $alertTargetPane = if ($alertKind -like "completion_return*") {
                [string]$workflow.source_pane
            }
            else {
                [string]$workflow.target_pane
            }
            $alert = Add-LedgerEvent -Fields @{
                event = "alert"
                workflow_ref = [string]$workflow.workflow_ref
                job_key = [string]$workflow.job_key
                alert_kind = $alertKind
                target_pane = $alertTargetPane
                details = $details
            }
            $newAlerts.Add($alert)
            if ($Notify) {
                try {
                    $null = Invoke-HerdrJson -Arguments @(
                        "notification", "show", "Herdr workflow alert",
                        "--body", "$($workflow.workflow_ref) $alertKind on ${alertTargetPane}: $details",
                        "--position", "top-right",
                        "--sound", "request"
                    )
                }
                catch {
                    # The ledger alert is authoritative even if UI notification fails.
                }
            }
        }
        [pscustomobject]@{
            action = "scan"
            scanned = $views.Count
            new_alerts = @($newAlerts)
            workflows = @($views)
        } | ConvertTo-Json -Depth 20
    }
}

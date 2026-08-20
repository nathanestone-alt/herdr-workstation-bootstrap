[CmdletBinding()]
param(
    [ValidateSet("status", "authority-acquire", "authority-renew", "challenge", "claim", "assign", "ack-assignment", "activate", "resolve", "resolve-pane", "revalidate")]
    [string]$Action = "status",

    [string]$RegistryPath = $(Join-Path ([IO.Path]::GetTempPath()) "herdr-pane-registry.jsonl"),
    [string]$ReceiptPath,
    [string]$PaneId,
    [string]$Name,
    [string]$Repo,
    [string]$Lane,
    [string]$Role,
    [ValidateRange(1, 999)][int]$Slot = 1,
    [switch]$Explore,
    [switch]$Coordination,
    [switch]$Fix,
    [string]$WorkKind = "explore",
    [string]$GitHubRepo,
    [string]$Issue,
    [string]$Title,
    [string]$Topic,
    [string]$ReservationId,
    [string]$Challenge,
    [string]$AssignmentToken,
    [string]$ApprovalId,
    [string]$ExpectedRegistryId,
    [string]$ExpectedBindingId,
    [long]$ExpectedGeneration = -1,
    [ValidateRange(60000, 3600000)][int]$AuthorityLeaseMs = 900000,
    [ValidateRange(30000, 900000)][int]$ReservationLeaseMs = 300000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8NoBom = [Text.UTF8Encoding]::new($false, $true)

if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $ReceiptPath = "$RegistryPath.receipts.jsonl"
}
$modulePath = Join-Path $PSScriptRoot "HerdrPaneRegistry.psm1"
$coordinationHelper = Join-Path $PSScriptRoot "herdr_coordination.ps1"
Import-Module $modulePath -Force

function Invoke-HerdrRegistryJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & rtk proxy herdr @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "herdr $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    $text = ($output -join [Environment]::NewLine).Trim()
    try {
        return $text | ConvertFrom-Json -Depth 32
    }
    catch {
        throw "herdr $($Arguments -join ' ') returned invalid JSON: $text"
    }
}

function Get-AgentSessionValue {
    param($Agent)

    if ($null -eq $Agent.PSObject.Properties["agent_session"] -or $null -eq $Agent.agent_session) {
        return $null
    }
    if ($Agent.agent_session -is [string]) {
        return [string]$Agent.agent_session
    }
    if ($null -ne $Agent.agent_session.PSObject.Properties["value"]) {
        return [string]$Agent.agent_session.value
    }
    return $null
}

function Get-LivePaneTuple {
    param([Parameter(Mandatory)][string]$TargetPaneId)

    if ($TargetPaneId -notmatch '^w[^:]+:p[^:]+$') {
        throw "Invalid explicit pane ID '$TargetPaneId'."
    }
    $pane = (Invoke-HerdrRegistryJson -Arguments @("pane", "get", $TargetPaneId)).result.pane
    if ([string]$pane.pane_id -ne $TargetPaneId) {
        throw "Pane lookup returned a different pane."
    }
    $tab = (Invoke-HerdrRegistryJson -Arguments @("tab", "get", [string]$pane.tab_id)).result.tab
    $workspace = (Invoke-HerdrRegistryJson -Arguments @("workspace", "get", [string]$pane.workspace_id)).result.workspace
    $agent = (Invoke-HerdrRegistryJson -Arguments @("agent", "get", $TargetPaneId)).result.agent
    $session = Get-AgentSessionValue -Agent $agent
    if ([string]::IsNullOrWhiteSpace($session)) {
        throw "Pane $TargetPaneId has no stable native agent-session proof."
    }
    if ([string]$agent.pane_id -ne $TargetPaneId -or
        [string]$agent.tab_id -ne [string]$pane.tab_id -or
        [string]$agent.workspace_id -ne [string]$pane.workspace_id -or
        [string]$agent.terminal_id -ne [string]$pane.terminal_id) {
        throw "Pane and agent identity disagree for $TargetPaneId."
    }
    if ([int]$tab.pane_count -ne 1) {
        throw "Registry requires a one-pane tab; $($tab.tab_id) has $($tab.pane_count) panes."
    }
    return [pscustomobject]@{
        workspace_id = [string]$pane.workspace_id
        workspace_label = [string]$workspace.label
        tab_id = [string]$pane.tab_id
        tab_label = [string]$tab.label
        pane_id = [string]$pane.pane_id
        pane_label = [string]$pane.terminal_title_stripped
        terminal_id = [string]$pane.terminal_id
        agent = [string]$agent.agent
        agent_session = $session
        agent_revision = [long]$agent.revision
        agent_status = [string]$agent.agent_status
    }
}

function Assert-ProvenCaller {
    param([Parameter(Mandatory)]$Tuple)

    if ($env:HERDR_ENV -ne "1" -or
        [string]::IsNullOrWhiteSpace($env:HERDR_WORKSPACE_ID) -or
        [string]::IsNullOrWhiteSpace($env:HERDR_TAB_ID) -or
        [string]::IsNullOrWhiteSpace($env:HERDR_PANE_ID)) {
        throw "Caller lacks complete native Herdr identity."
    }
    if ($env:HERDR_WORKSPACE_ID -ne [string]$Tuple.workspace_id -or
        $env:HERDR_TAB_ID -ne [string]$Tuple.tab_id -or
        $env:HERDR_PANE_ID -ne [string]$Tuple.pane_id) {
        throw "Caller identity does not match the explicit pane tuple."
    }
    $proofOutput = & pwsh -NoProfile -File $coordinationHelper `
        -Action prove-caller -PaneId ([string]$Tuple.pane_id) `
        -ExpectedAgent ([string]$Tuple.agent) -ExpectedSession ([string]$Tuple.agent_session) 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Caller process/session proof failed: $($proofOutput -join [Environment]::NewLine)"
    }
    $proof = ($proofOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 32
    if (-not [bool]$proof.proven) {
        throw "Caller process/session proof was not affirmative."
    }
}

function Assert-LiveTupleMatchesEvent {
    param(
        [Parameter(Mandatory)]$Tuple,
        [Parameter(Mandatory)]$Event,
        [switch]$RequireCanonicalLabel
    )

    foreach ($field in @("workspace_id", "tab_id", "pane_id", "terminal_id", "agent")) {
        if ([string]$Tuple.$field -ne [string]$Event.$field) {
            throw "Live $field changed for registry binding '$($Event.binding_id)'."
        }
    }
    if ([string]$Tuple.agent_session -ne [string]$Event.agent_session) {
        throw "Live native session changed for registry binding '$($Event.binding_id)'."
    }
    if ([string]$Tuple.workspace_label -cne [string]$Event.canonical_workspace) {
        throw "Live workspace label changed for registry binding '$($Event.binding_id)'."
    }
    if ($RequireCanonicalLabel -and [string]$Tuple.tab_label -cne [string]$Event.canonical_name) {
        throw "Live tab label changed for registry binding '$($Event.binding_id)'."
    }
}

function Assert-AuthorityHolder {
    param([Parameter(Mandatory)]$State)

    if (-not (Test-HerdrRegistryAuthorityCurrent -State $State)) {
        throw "Pane registry authority is absent or expired."
    }
    $tuple = Get-LivePaneTuple -TargetPaneId ([string]$State.authority.coordinator_pane_id)
    Assert-ProvenCaller -Tuple $tuple
    if ([string]$tuple.pane_id -ne [string]$State.authority.coordinator_pane_id -or
        [string]$tuple.agent_session -ne [string]$State.authority.coordinator_session -or
        [string]$tuple.tab_label -cne "Coordination" -or
        [string]$tuple.workspace_label -cne "Hdr") {
        throw "Caller is not the current proven Hdr/Coordination authority holder."
    }
    return $tuple
}

function Get-WorkSubname {
    param([string]$Kind, [string]$IssueValue, [string]$TitleValue, [string]$TopicValue)

    if ($Kind -eq "explore") {
        $topicText = if ([string]::IsNullOrWhiteSpace($TopicValue)) { "unassigned" } else { $TopicValue.Trim() }
        return "EXPLORE · $topicText"
    }
    if ($Kind -eq "issue") {
        if ($IssueValue -notmatch '^#?\d+$' -or [string]::IsNullOrWhiteSpace($TitleValue)) {
            throw "Issue work requires a numeric issue and short title."
        }
        return "#$($IssueValue.TrimStart('#')) · $($TitleValue.Trim())"
    }
    if ($Kind -eq "pr") {
        if ($IssueValue -notmatch '^(?:PR#?)?\d+$' -or [string]::IsNullOrWhiteSpace($TitleValue)) {
            throw "PR work requires a numeric PR and short title."
        }
        $number = [regex]::Match($IssueValue, '\d+').Value
        return "PR#$number · $($TitleValue.Trim())"
    }
    if ($Kind -eq "no-issue") {
        if ([string]::IsNullOrWhiteSpace($TitleValue)) {
            throw "No-issue work requires a short description."
        }
        return "NO-ISSUE · $($TitleValue.Trim())"
    }
    throw "Unsupported work kind '$Kind'."
}

function Get-ReservationEvent {
    param($State, [string]$Id)
    $matches = @($State.events | Where-Object { [string]$_.reservation_id -eq $Id })
    if ($matches.Count -eq 0) {
        throw "Reservation '$Id' does not exist."
    }
    return $matches[-1]
}

function Get-ReservationBaseEvent {
    param($State, [string]$Id)
    $matches = @($State.events | Where-Object {
        [string]$_.reservation_id -eq $Id -and [string]$_.action -eq "reserve"
    })
    if ($matches.Count -ne 1) {
        throw "Reservation '$Id' has no unique reserve event."
    }
    return $matches[0]
}

function Get-ReservationSidecarPath {
    param([string]$Kind, [string]$Id)
    $directory = "$RegistryPath.$Kind"
    return Join-Path $directory "$Id.json"
}

function Get-SidecarRecordHash {
    param([Parameter(Mandatory)]$Record)

    $normalized = ($Record | ConvertTo-Json -Depth 32 -Compress) | ConvertFrom-Json -Depth 32
    $copy = [ordered]@{}
    foreach ($property in $normalized.PSObject.Properties) {
        if ($property.Name -ne "record_hash") {
            $copy[$property.Name] = $property.Value
        }
    }
    return Get-HerdrRegistrySha256 -Text ($copy | ConvertTo-Json -Depth 32 -Compress)
}

function Write-ExclusiveSidecar {
    param([string]$Path, [Collections.IDictionary]$Fields)

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $record = [ordered]@{}
    foreach ($key in $Fields.Keys) {
        $record[[string]$key] = $Fields[$key]
    }
    $record.record_hash = Get-SidecarRecordHash -Record ([pscustomobject]$record)
    $line = ($record | ConvertTo-Json -Depth 32 -Compress) + "`n"
    $bytes = $utf8NoBom.GetBytes($line)

    try {
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
    }
    catch [IO.IOException] {
        $existing = Read-Sidecar -Path $Path
        if ([string]$existing.record_hash -ne [string]$record.record_hash) {
            throw "Sidecar '$Path' already exists with different content."
        }
    }
    return [pscustomobject]$record
}

function Read-Sidecar {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required sidecar '$Path' does not exist."
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0 -or $bytes[-1] -ne 10) {
        throw "Sidecar '$Path' is truncated."
    }
    $record = $utf8NoBom.GetString($bytes).TrimEnd("`r", "`n") | ConvertFrom-Json -Depth 32
    $calculated = Get-SidecarRecordHash -Record $record
    if ([string]$record.record_hash -ne $calculated) {
        throw "Sidecar '$Path' hash mismatch."
    }
    return $record
}

function Copy-ReservationFields {
    param($Reserve, [string]$EventAction, [string]$Phase, [Collections.IDictionary]$Extra)

    $fields = [ordered]@{
        action = $EventAction
        binding_id = [string]$Reserve.binding_id
        canonical_name = [string]$Reserve.canonical_name
        generation = [long]$Reserve.generation
        aliases = $Reserve.aliases
        canonical_workspace = [string]$Reserve.canonical_workspace
        workspace_id = [string]$Reserve.workspace_id
        tab_id = [string]$Reserve.tab_id
        pane_id = [string]$Reserve.pane_id
        terminal_id = [string]$Reserve.terminal_id
        tab_label = [string]$Reserve.tab_label
        pane_label = [string]$Reserve.pane_label
        agent = [string]$Reserve.agent
        agent_session = [string]$Reserve.agent_session
        repo = [string]$Reserve.repo
        lane = [string]$Reserve.lane
        role = [string]$Reserve.role
        slot = [long]$Reserve.slot
        work_kind = [string]$Reserve.work_kind
        github_repo = [string]$Reserve.github_repo
        issue = [string]$Reserve.issue
        title = [string]$Reserve.title
        work_subname = [string]$Reserve.work_subname
        predecessor_event = [string]$Reserve.event_id
        authority_epoch = [long]$Reserve.authority_epoch
        authority_lease_id = [string]$Reserve.authority_lease_id
        coordinator_pane_id = [string]$Reserve.coordinator_pane_id
        coordinator_session = [string]$Reserve.coordinator_session
        reservation_id = [string]$Reserve.reservation_id
        reservation_expires_utc = [string]$Reserve.reservation_expires_utc
        claimant_challenge_hash = [string]$Reserve.claimant_challenge_hash
        transaction_phase = $Phase
    }
    if ($null -ne $Extra) {
        foreach ($key in $Extra.Keys) {
            $fields[[string]$key] = $Extra[$key]
        }
    }
    return $fields
}

switch ($Action) {
    "status" {
        $state = Get-HerdrPaneRegistryState -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath
        [pscustomobject]@{
            action = "status"
            initialized = $state.event_count -gt 0
            registry_id = $state.registry_id
            event_count = $state.event_count
            head_hash = $state.head_hash
            authority_current = if ($state.event_count -gt 0) { Test-HerdrRegistryAuthorityCurrent -State $state } else { $false }
            authority = $state.authority
            active_bindings = @(Get-HerdrRegistryActiveBindings -State $state)
        } | ConvertTo-Json -Depth 32
    }
    "authority-acquire" {
        if ([string]::IsNullOrWhiteSpace($ApprovalId)) {
            throw "authority-acquire requires -ApprovalId from Herdr's interactive control plane."
        }
        $callerPane = if ([string]::IsNullOrWhiteSpace($PaneId)) { $env:HERDR_PANE_ID } else { $PaneId }
        if ([string]::IsNullOrWhiteSpace($callerPane)) {
            throw "authority-acquire requires an explicit native caller pane."
        }
        $tuple = Get-LivePaneTuple -TargetPaneId $callerPane
        Assert-ProvenCaller -Tuple $tuple
        if ($tuple.workspace_label -cne "Hdr" -or $tuple.tab_label -cne "Coordination" -or $tuple.agent -ne "codex") {
            throw "Initial authority requires the exact Hdr/Coordination Codex pane."
        }
        $absentState = Get-HerdrPaneRegistryState -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath
        if ($absentState.event_count -ne 0) {
            throw "Initial authority requires an absent registry."
        }
        $registryId = "reg_$([Guid]::NewGuid().ToString('N'))"
        $leaseId = "lease_$([Guid]::NewGuid().ToString('N'))"
        $expiry = [DateTimeOffset]::UtcNow.AddMilliseconds($AuthorityLeaseMs)
        $subject = [ordered]@{
            operation = "pane-registry-authority-acquire"
            expected_registry = "absent"
            registry_id = $registryId
            authority_epoch = 1
            coordinator_workspace_id = $tuple.workspace_id
            coordinator_tab_id = $tuple.tab_id
            coordinator_pane_id = $tuple.pane_id
            coordinator_terminal_id = $tuple.terminal_id
            coordinator_agent = $tuple.agent
            coordinator_session = $tuple.agent_session
        }
        $subjectHash = Get-HerdrRegistrySha256 -Text ($subject | ConvertTo-Json -Depth 16 -Compress)
        $approval = (Invoke-HerdrRegistryJson -Arguments @(
            "authorization", "consume", $ApprovalId,
            "--operation", "pane-registry-authority-acquire",
            "--subject-sha256", $subjectHash
        )).result.approval
        if (-not [bool]$approval.consumed -or
            [string]$approval.approval_id -ne $ApprovalId -or
            [string]$approval.operation -ne "pane-registry-authority-acquire" -or
            [string]$approval.subject_sha256 -ne $subjectHash) {
            throw "Herdr control-plane approval did not match the authority bootstrap subject."
        }
        Add-HerdrPaneRegistryEvent -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath -ExpectAbsent -Fields ([ordered]@{
            action = "authorization-consumed"
            registry_id = $registryId
            authority_epoch = 1
            authority_lease_id = $leaseId
            coordinator_pane_id = $tuple.pane_id
            coordinator_session = $tuple.agent_session
            metadata = [ordered]@{ approval_id = $ApprovalId; operation = $approval.operation; subject_sha256 = $subjectHash }
            reason = "interactive control-plane approval consumed"
        }) | Out-Null
        $event = Add-HerdrPaneRegistryEvent -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath -Fields ([ordered]@{
            action = "authority-acquire"
            authority_epoch = 1
            authority_lease_id = $leaseId
            authority_expires_utc = $expiry.ToString("o")
            canonical_workspace = "Hdr"
            workspace_id = $tuple.workspace_id
            tab_id = $tuple.tab_id
            pane_id = $tuple.pane_id
            terminal_id = $tuple.terminal_id
            tab_label = "Coordination"
            pane_label = $tuple.pane_label
            agent = $tuple.agent
            agent_session = $tuple.agent_session
            coordinator_pane_id = $tuple.pane_id
            coordinator_session = $tuple.agent_session
            reason = "initial coordinator authority"
        })
        [pscustomobject]@{ action = "authority-acquire"; acquired = $true; registry_id = $registryId; authority_epoch = 1; lease_id = $leaseId; expires_utc = $expiry.ToString("o"); event = $event } | ConvertTo-Json -Depth 32
    }
    "authority-renew" {
        $state = Get-HerdrPaneRegistryState -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath
        $tuple = Assert-AuthorityHolder -State $state
        $expiry = [DateTimeOffset]::UtcNow.AddMilliseconds($AuthorityLeaseMs)
        $event = Add-HerdrPaneRegistryEvent -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath -ExpectedHeadHash $state.head_hash -Fields ([ordered]@{
            action = "authority-renew"
            authority_epoch = [long]$state.authority.authority_epoch
            authority_lease_id = [string]$state.authority.authority_lease_id
            authority_expires_utc = $expiry.ToString("o")
            canonical_workspace = "Hdr"
            workspace_id = $tuple.workspace_id
            tab_id = $tuple.tab_id
            pane_id = $tuple.pane_id
            terminal_id = $tuple.terminal_id
            tab_label = "Coordination"
            pane_label = $tuple.pane_label
            agent = $tuple.agent
            agent_session = $tuple.agent_session
            coordinator_pane_id = $tuple.pane_id
            coordinator_session = $tuple.agent_session
            predecessor_event = [string]$state.authority.event_id
            reason = "coordinator authority renewal"
        })
        [pscustomobject]@{ action = "authority-renew"; renewed = $true; expires_utc = $expiry.ToString("o"); event = $event } | ConvertTo-Json -Depth 32
    }
    "challenge" {
        if ([string]::IsNullOrWhiteSpace($PaneId) -or [string]::IsNullOrWhiteSpace($Repo)) {
            throw "challenge requires -PaneId and -Repo."
        }
        $state = Get-HerdrPaneRegistryState -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath
        $coordinator = Assert-AuthorityHolder -State $state
        $target = Get-LivePaneTuple -TargetPaneId $PaneId
        $workspace = Assert-HerdrCanonicalWorkspaceBinding -Repo $Repo -WorkspaceLabel $target.workspace_label
        $canonical = if (-not [string]::IsNullOrWhiteSpace($Name)) {
            $Name.Trim()
        }
        else {
            Get-HerdrCanonicalPaneName -Repo $Repo -Lane $Lane -Role $Role -Slot $Slot -Explore:$Explore -Coordination:$Coordination -Fix:$Fix
        }
        $expectedCanonical = Get-HerdrCanonicalPaneName -Repo $Repo -Lane $Lane -Role $Role -Slot $Slot -Explore:$Explore -Coordination:$Coordination -Fix:$Fix
        if ($canonical -cne $expectedCanonical) {
            throw "Requested name '$canonical' does not match canonical name '$expectedCanonical'."
        }
        $activeForPane = @(Get-HerdrRegistryActiveBindings -State $state | Where-Object { [string]$_.pane_id -eq $PaneId })
        if ($activeForPane.Count -gt 1) {
            throw "Pane $PaneId has ambiguous active registry bindings."
        }
        if ($activeForPane.Count -eq 1 -and [string]$activeForPane[0].canonical_name -ceq $canonical) {
            [pscustomobject]@{ action = "challenge"; already_active = $true; binding = $activeForPane[0] } | ConvertTo-Json -Depth 32
            break
        }
        if (@(Get-HerdrRegistryActiveBindings -State $state | Where-Object { [string]$_.canonical_name -ceq $canonical }).Count -ne 0) {
            throw "Canonical pane name '$canonical' is already active."
        }
        $generation = if ($state.generation_high_water.Contains($canonical)) { [long]$state.generation_high_water[$canonical] + 1 } else { 1 }
        $bindingId = if ($activeForPane.Count -eq 1) { [string]$activeForPane[0].binding_id } else { "bind_$([Guid]::NewGuid().ToString('N'))" }
        $reservation = "res_$([Guid]::NewGuid().ToString('N'))"
        $challengeValue = "challenge_$([Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant())"
        $expiry = [DateTimeOffset]::UtcNow.AddMilliseconds($ReservationLeaseMs)
        $workSubname = Get-WorkSubname -Kind $WorkKind -IssueValue $Issue -TitleValue $Title -TopicValue $Topic
        $event = Add-HerdrPaneRegistryEvent -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath -ExpectedHeadHash $state.head_hash -Fields ([ordered]@{
            action = "reserve"
            binding_id = $bindingId
            canonical_name = $canonical
            generation = $generation
            aliases = if ($activeForPane.Count -eq 1) { @([string]$activeForPane[0].canonical_name) } else { @() }
            canonical_workspace = $workspace
            workspace_id = $target.workspace_id
            tab_id = $target.tab_id
            pane_id = $target.pane_id
            terminal_id = $target.terminal_id
            tab_label = $target.tab_label
            pane_label = $target.pane_label
            agent = $target.agent
            agent_session = $target.agent_session
            repo = $Repo.ToUpperInvariant()
            lane = if ($Explore -or $Coordination -or $Fix) { $null } else { $Lane.ToUpperInvariant() }
            role = if ($Explore -or $Coordination -or $Fix) { $null } else { $Role.ToUpperInvariant() }
            slot = $Slot
            work_kind = $WorkKind
            github_repo = $GitHubRepo
            issue = $Issue
            title = $Title
            work_subname = $workSubname
            predecessor_event = if ($activeForPane.Count -eq 1) { [string]$activeForPane[0].event_id } else { $null }
            authority_epoch = [long]$state.authority.authority_epoch
            authority_lease_id = [string]$state.authority.authority_lease_id
            coordinator_pane_id = $coordinator.pane_id
            coordinator_session = $coordinator.agent_session
            reservation_id = $reservation
            reservation_expires_utc = $expiry.ToString("o")
            claimant_challenge_hash = Get-HerdrRegistrySha256 -Text $challengeValue
            transaction_phase = "reserved"
            reason = "coordinator-issued naming challenge"
        })
        [pscustomobject]@{ action = "challenge"; reserved = $true; registry_id = $state.registry_id; reservation_id = $reservation; binding_id = $bindingId; canonical_name = $canonical; generation = $generation; challenge = $challengeValue; expires_utc = $expiry.ToString("o"); claimant = $target; event = $event } | ConvertTo-Json -Depth 32
    }
    "claim" {
        if ([string]::IsNullOrWhiteSpace($ReservationId) -or [string]::IsNullOrWhiteSpace($Challenge)) {
            throw "claim requires -ReservationId and -Challenge."
        }
        $state = Get-HerdrPaneRegistryState -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath
        $reserve = Get-ReservationBaseEvent -State $state -Id $ReservationId
        if ([DateTimeOffset]::Parse([string]$reserve.reservation_expires_utc) -le [DateTimeOffset]::UtcNow) {
            throw "Reservation '$ReservationId' is expired."
        }
        if ((Get-HerdrRegistrySha256 -Text $Challenge) -ne [string]$reserve.claimant_challenge_hash) {
            throw "Reservation challenge does not match."
        }
        $tuple = Get-LivePaneTuple -TargetPaneId ([string]$reserve.pane_id)
        Assert-ProvenCaller -Tuple $tuple
        Assert-LiveTupleMatchesEvent -Tuple $tuple -Event $reserve
        $claimPath = Get-ReservationSidecarPath -Kind "claims" -Id $ReservationId
        $claim = Write-ExclusiveSidecar -Path $claimPath -Fields ([ordered]@{
            schema_version = 1
            kind = "claim"
            registry_id = $state.registry_id
            reservation_id = $ReservationId
            binding_id = $reserve.binding_id
            canonical_name = $reserve.canonical_name
            generation = $reserve.generation
            challenge_hash = $reserve.claimant_challenge_hash
            workspace_id = $tuple.workspace_id
            tab_id = $tuple.tab_id
            pane_id = $tuple.pane_id
            terminal_id = $tuple.terminal_id
            agent = $tuple.agent
            agent_session = $tuple.agent_session
            authority_epoch = $reserve.authority_epoch
            claimed_utc = [DateTimeOffset]::UtcNow.ToString("o")
        })
        [pscustomobject]@{ action = "claim"; claimed = $true; reservation_id = $ReservationId; claim_path = $claimPath; claim_hash = $claim.record_hash } | ConvertTo-Json -Depth 16
    }
    "assign" {
        if ([string]::IsNullOrWhiteSpace($ReservationId)) {
            throw "assign requires -ReservationId."
        }
        $state = Get-HerdrPaneRegistryState -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath
        $coordinator = Assert-AuthorityHolder -State $state
        $reserve = Get-ReservationBaseEvent -State $state -Id $ReservationId
        $latest = Get-ReservationEvent -State $state -Id $ReservationId
        if ([string]$latest.transaction_phase -notin @("reserved", "renamed", "metadata-set")) {
            throw "Reservation '$ReservationId' cannot be assigned from phase '$($latest.transaction_phase)'."
        }
        if ([long]$reserve.authority_epoch -ne [long]$state.authority.authority_epoch -or
            [string]$reserve.authority_lease_id -ne [string]$state.authority.authority_lease_id) {
            throw "Reservation belongs to a stale coordinator authority epoch."
        }
        if ([DateTimeOffset]::Parse([string]$reserve.reservation_expires_utc) -le [DateTimeOffset]::UtcNow) {
            throw "Reservation '$ReservationId' is expired."
        }
        $claim = Read-Sidecar -Path (Get-ReservationSidecarPath -Kind "claims" -Id $ReservationId)
        foreach ($field in @("registry_id", "reservation_id", "binding_id", "canonical_name", "generation", "workspace_id", "tab_id", "pane_id", "terminal_id", "agent", "agent_session", "authority_epoch")) {
            if ([string]$claim.$field -ne [string]$reserve.$field) {
                throw "Claim field '$field' does not match the reservation."
            }
        }
        $target = Get-LivePaneTuple -TargetPaneId ([string]$reserve.pane_id)
        Assert-LiveTupleMatchesEvent -Tuple $target -Event $reserve
        if ([string]$latest.transaction_phase -eq "reserved") {
            $null = Invoke-HerdrRegistryJson -Arguments @("tab", "rename", [string]$reserve.tab_id, [string]$reserve.canonical_name)
            $renamed = Get-LivePaneTuple -TargetPaneId ([string]$reserve.pane_id)
            Assert-LiveTupleMatchesEvent -Tuple $renamed -Event $reserve
            if ([string]$renamed.tab_label -cne [string]$reserve.canonical_name) {
                throw "Tab rename verification failed."
            }
            Add-HerdrPaneRegistryEvent -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath -Fields (Copy-ReservationFields -Reserve $reserve -EventAction "renamed" -Phase "renamed" -Extra ([ordered]@{
                tab_label = [string]$reserve.canonical_name
                predecessor_event = [string]$latest.event_id
                coordinator_pane_id = $coordinator.pane_id
                coordinator_session = $coordinator.agent_session
                reason = "canonical tab label applied"
            })) | Out-Null
            $state = Get-HerdrPaneRegistryState -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath
            $latest = Get-ReservationEvent -State $state -Id $ReservationId
        }
        if ([string]$latest.transaction_phase -eq "renamed") {
            $metadataResult = Invoke-HerdrRegistryJson -Arguments @(
                "pane", "report-metadata", [string]$reserve.pane_id,
                "--source", "herdr-registry",
                "--title", [string]$reserve.work_subname,
                "--display-agent", [string]$reserve.work_subname,
                "--token", "registry_id=$($state.registry_id)",
                "--token", "binding_id=$($reserve.binding_id)",
                "--token", "canonical_name=$($reserve.canonical_name)",
                "--token", "generation=$($reserve.generation)"
            )
            $assignment = "assignment_$([Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant())"
            $metadataEvent = Add-HerdrPaneRegistryEvent -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath -Fields (Copy-ReservationFields -Reserve $reserve -EventAction "metadata-update" -Phase "metadata-set" -Extra ([ordered]@{
                tab_label = [string]$reserve.canonical_name
                predecessor_event = [string]$latest.event_id
                coordinator_pane_id = $coordinator.pane_id
                coordinator_session = $coordinator.agent_session
                metadata = [ordered]@{
                    source = "herdr-registry"
                    assignment_token_hash = Get-HerdrRegistrySha256 -Text $assignment
                    command_result_type = [string]$metadataResult.result.type
                }
                reason = "work subname and registry tokens applied"
            }))
            [pscustomobject]@{ action = "assign"; prepared = $true; reservation_id = $ReservationId; assignment_token = $assignment; canonical_name = $reserve.canonical_name; generation = $reserve.generation; event = $metadataEvent } | ConvertTo-Json -Depth 32
            break
        }
        throw "Reservation '$ReservationId' was already prepared; issue a new challenge if its assignment token was lost."
    }
    "ack-assignment" {
        if ([string]::IsNullOrWhiteSpace($ReservationId) -or [string]::IsNullOrWhiteSpace($AssignmentToken)) {
            throw "ack-assignment requires -ReservationId and -AssignmentToken."
        }
        $state = Get-HerdrPaneRegistryState -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath
        $reserve = Get-ReservationBaseEvent -State $state -Id $ReservationId
        $latest = Get-ReservationEvent -State $state -Id $ReservationId
        if ([string]$latest.transaction_phase -ne "metadata-set") {
            throw "Reservation '$ReservationId' is not awaiting assignment acknowledgment."
        }
        if ((Get-HerdrRegistrySha256 -Text $AssignmentToken) -ne [string]$latest.metadata.assignment_token_hash) {
            throw "Assignment token does not match."
        }
        $tuple = Get-LivePaneTuple -TargetPaneId ([string]$reserve.pane_id)
        Assert-ProvenCaller -Tuple $tuple
        Assert-LiveTupleMatchesEvent -Tuple $tuple -Event $reserve -RequireCanonicalLabel
        $ackPath = Get-ReservationSidecarPath -Kind "assignment-acks" -Id $ReservationId
        $ack = Write-ExclusiveSidecar -Path $ackPath -Fields ([ordered]@{
            schema_version = 1
            kind = "assignment-ack"
            registry_id = $state.registry_id
            reservation_id = $ReservationId
            binding_id = $reserve.binding_id
            canonical_name = $reserve.canonical_name
            generation = $reserve.generation
            assignment_token_hash = $latest.metadata.assignment_token_hash
            workspace_id = $tuple.workspace_id
            tab_id = $tuple.tab_id
            pane_id = $tuple.pane_id
            terminal_id = $tuple.terminal_id
            agent = $tuple.agent
            agent_session = $tuple.agent_session
            authority_epoch = $reserve.authority_epoch
            acknowledged_utc = [DateTimeOffset]::UtcNow.ToString("o")
        })
        [pscustomobject]@{ action = "ack-assignment"; acknowledged = $true; reservation_id = $ReservationId; ack_path = $ackPath; ack_hash = $ack.record_hash } | ConvertTo-Json -Depth 16
    }
    "activate" {
        if ([string]::IsNullOrWhiteSpace($ReservationId)) {
            throw "activate requires -ReservationId."
        }
        $state = Get-HerdrPaneRegistryState -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath
        $coordinator = Assert-AuthorityHolder -State $state
        $reserve = Get-ReservationBaseEvent -State $state -Id $ReservationId
        $latest = Get-ReservationEvent -State $state -Id $ReservationId
        if ([string]$latest.transaction_phase -eq "active") {
            [pscustomobject]@{ action = "activate"; already_active = $true; binding = $latest } | ConvertTo-Json -Depth 32
            break
        }
        if ([string]$latest.transaction_phase -ne "metadata-set") {
            throw "Reservation '$ReservationId' cannot activate from phase '$($latest.transaction_phase)'."
        }
        if ([long]$reserve.authority_epoch -ne [long]$state.authority.authority_epoch -or
            [string]$reserve.authority_lease_id -ne [string]$state.authority.authority_lease_id) {
            throw "Reservation belongs to a stale coordinator authority epoch."
        }
        $ack = Read-Sidecar -Path (Get-ReservationSidecarPath -Kind "assignment-acks" -Id $ReservationId)
        foreach ($field in @("registry_id", "reservation_id", "binding_id", "canonical_name", "generation", "workspace_id", "tab_id", "pane_id", "terminal_id", "agent", "agent_session", "authority_epoch")) {
            if ([string]$ack.$field -ne [string]$reserve.$field) {
                throw "Assignment ACK field '$field' does not match the reservation."
            }
        }
        if ([string]$ack.assignment_token_hash -ne [string]$latest.metadata.assignment_token_hash) {
            throw "Assignment ACK token hash does not match the prepared assignment."
        }
        $target = Get-LivePaneTuple -TargetPaneId ([string]$reserve.pane_id)
        Assert-LiveTupleMatchesEvent -Tuple $target -Event $reserve -RequireCanonicalLabel
        $ackEvent = Add-HerdrPaneRegistryEvent -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath -Fields (Copy-ReservationFields -Reserve $reserve -EventAction "assignment-ack" -Phase "assignment-ack" -Extra ([ordered]@{
            tab_label = [string]$reserve.canonical_name
            predecessor_event = [string]$latest.event_id
            coordinator_pane_id = $coordinator.pane_id
            coordinator_session = $coordinator.agent_session
            metadata = [ordered]@{ sidecar_hash = [string]$ack.record_hash; assignment_token_hash = [string]$ack.assignment_token_hash }
            reason = "claimant acknowledged canonical assignment"
        }))
        $activeEvent = Add-HerdrPaneRegistryEvent -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath -ExpectedHeadHash $ackEvent.record_hash -Fields (Copy-ReservationFields -Reserve $reserve -EventAction "active" -Phase "active" -Extra ([ordered]@{
            tab_label = [string]$reserve.canonical_name
            predecessor_event = [string]$ackEvent.event_id
            coordinator_pane_id = $coordinator.pane_id
            coordinator_session = $coordinator.agent_session
            reason = "assignment activated"
        }))
        [pscustomobject]@{ action = "activate"; activated = $true; registry_id = $state.registry_id; binding_id = $reserve.binding_id; canonical_name = $reserve.canonical_name; generation = $reserve.generation; event = $activeEvent } | ConvertTo-Json -Depth 32
    }
    "resolve" {
        if ([string]::IsNullOrWhiteSpace($Name)) {
            throw "resolve requires -Name."
        }
        $resolved = Resolve-HerdrPaneRegistryName -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath -Name $Name -ForDispatch
        $live = Get-LivePaneTuple -TargetPaneId $resolved.pane_id
        Assert-LiveTupleMatchesEvent -Tuple $live -Event $resolved -RequireCanonicalLabel
        [pscustomobject]@{ action = "resolve"; resolved = $true; binding = $resolved; live = $live } | ConvertTo-Json -Depth 32
    }
    "resolve-pane" {
        if ([string]::IsNullOrWhiteSpace($PaneId)) {
            throw "resolve-pane requires -PaneId."
        }
        $resolved = Resolve-HerdrPaneRegistryPane -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath -PaneId $PaneId -ForDispatch
        $live = Get-LivePaneTuple -TargetPaneId $resolved.pane_id
        Assert-LiveTupleMatchesEvent -Tuple $live -Event $resolved -RequireCanonicalLabel
        [pscustomobject]@{ action = "resolve-pane"; resolved = $true; binding = $resolved; live = $live } | ConvertTo-Json -Depth 32
    }
    "revalidate" {
        if ([string]::IsNullOrWhiteSpace($Name) -or
            [string]::IsNullOrWhiteSpace($ExpectedRegistryId) -or
            [string]::IsNullOrWhiteSpace($ExpectedBindingId) -or
            $ExpectedGeneration -lt 1) {
            throw "revalidate requires -Name, -ExpectedRegistryId, -ExpectedBindingId, and -ExpectedGeneration."
        }
        $resolved = Resolve-HerdrPaneRegistryName -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath -Name $Name -ForDispatch
        if ($resolved.registry_id -ne $ExpectedRegistryId -or
            $resolved.binding_id -ne $ExpectedBindingId -or
            $resolved.generation -ne $ExpectedGeneration) {
            throw "Registry binding changed after resolution; delivery is fenced."
        }
        $live = Get-LivePaneTuple -TargetPaneId $resolved.pane_id
        Assert-LiveTupleMatchesEvent -Tuple $live -Event $resolved -RequireCanonicalLabel
        [pscustomobject]@{ action = "revalidate"; valid = $true; binding = $resolved; live = $live } | ConvertTo-Json -Depth 32
    }
}

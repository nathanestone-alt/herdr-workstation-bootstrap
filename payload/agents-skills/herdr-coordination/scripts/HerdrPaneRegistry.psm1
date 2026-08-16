Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:RegistrySchemaVersion = 1
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false, $true)
$script:CanonicalWorkspaces = [ordered]@{
    STM = "STM"
    AGT = "AGT"
    HDR = "Hdr"
    BUZ = "Buzz"
}
$script:CanonicalLanes = @("T", "M", "LSP", "WB", "MCP", "OPS", "RES")
$script:CanonicalRoles = @("O", "B", "R", "C")

function Get-HerdrRegistrySha256 {
    param([Parameter(Mandatory)][string]$Text)

    $bytes = $script:Utf8NoBom.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return ([Convert]::ToHexString($hash)).ToLowerInvariant()
}

function ConvertTo-HerdrRegistryJson {
    param([Parameter(Mandatory)]$Value)

    return ($Value | ConvertTo-Json -Depth 32 -Compress)
}

function ConvertTo-HerdrRegistryHashInput {
    param([Parameter(Mandatory)]$Record)

    $normalized = (ConvertTo-HerdrRegistryJson -Value $Record) | ConvertFrom-Json -Depth 32
    $copy = [ordered]@{}
    foreach ($property in $normalized.PSObject.Properties) {
        if ($property.Name -notin @("record_hash", "receipt_hash")) {
            $copy[$property.Name] = $property.Value
        }
    }
    return ConvertTo-HerdrRegistryJson -Value $copy
}

function Get-HerdrRegistryRecordHash {
    param([Parameter(Mandatory)]$Record)

    return Get-HerdrRegistrySha256 -Text (ConvertTo-HerdrRegistryHashInput -Record $Record)
}

function Write-HerdrRegistryDurableLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Line
    )

    $parent = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($parent)) {
        $parent = (Get-Location).Path
    }
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }

    $payload = $script:Utf8NoBom.GetBytes($Line + "`n")
    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::Append,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read,
        4096,
        [IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($payload, 0, $payload.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-HerdrRegistryLockName {
    param([Parameter(Mandatory)][string]$RegistryPath)

    $absolute = [IO.Path]::GetFullPath($RegistryPath).ToLowerInvariant()
    return "Local\HerdrPaneRegistry_$(Get-HerdrRegistrySha256 -Text $absolute)"
}

function Enter-HerdrRegistryLock {
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [int]$TimeoutMs = 15000
    )

    $mutex = [Threading.Mutex]::new($false, (Get-HerdrRegistryLockName -RegistryPath $RegistryPath))
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne($TimeoutMs)
    }
    catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (-not $acquired) {
        $mutex.Dispose()
        throw "Timed out waiting for the pane-registry lock."
    }
    return $mutex
}

function Exit-HerdrRegistryLock {
    param($Mutex)

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

function Read-HerdrRegistryJsonLines {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Kind = "registry"
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) {
        return @()
    }
    if ($bytes[-1] -ne 10) {
        throw "$Kind file has a truncated non-newline-terminated tail."
    }
    try {
        $text = $script:Utf8NoBom.GetString($bytes)
    }
    catch {
        throw "$Kind file is not strict UTF-8: $($_.Exception.Message)"
    }

    $records = [Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($line in ($text -split "`n")) {
        $lineNumber++
        $trimmed = $line.TrimEnd("`r")
        if ([string]::IsNullOrEmpty($trimmed)) {
            continue
        }
        try {
            $records.Add(($trimmed | ConvertFrom-Json -Depth 32))
        }
        catch {
            throw "$kind line $lineNumber is invalid JSON: $($_.Exception.Message)"
        }
    }
    return @($records)
}

function Copy-HerdrGenerationHighWater {
    param([Collections.IDictionary]$HighWater)

    $copy = [ordered]@{}
    foreach ($name in @($HighWater.Keys | Sort-Object)) {
        $copy[[string]$name] = [long]$HighWater[$name]
    }
    return $copy
}

function Get-HerdrPaneRegistryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [string]$ReceiptPath = "$RegistryPath.receipts.jsonl"
    )

    $events = @(Read-HerdrRegistryJsonLines -Path $RegistryPath -Kind "registry")
    $receipts = @(Read-HerdrRegistryJsonLines -Path $ReceiptPath -Kind "registry receipt")
    if ($events.Count -ne $receipts.Count) {
        throw "Registry event/receipt count mismatch ($($events.Count) events, $($receipts.Count) receipts)."
    }

    $eventIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $highWater = [ordered]@{}
    $bindings = [ordered]@{}
    $previousHash = $null
    $registryId = $null
    $authority = $null

    for ($i = 0; $i -lt $events.Count; $i++) {
        $event = $events[$i]
        $receipt = $receipts[$i]
        $sequence = $i + 1

        if ([int]$event.schema_version -ne $script:RegistrySchemaVersion) {
            throw "Registry event $sequence uses unsupported schema version '$($event.schema_version)'."
        }
        if ([long]$event.event_seq -ne $sequence) {
            throw "Registry event sequence is not contiguous at event $sequence."
        }
        if (-not $eventIds.Add([string]$event.event_id)) {
            throw "Registry contains duplicate event ID '$($event.event_id)'."
        }
        if ($sequence -eq 1) {
            if ($null -ne $event.previous_hash -and -not [string]::IsNullOrWhiteSpace([string]$event.previous_hash)) {
                throw "The first registry event has a predecessor hash."
            }
            $registryId = [string]$event.registry_id
            if ([string]::IsNullOrWhiteSpace($registryId)) {
                throw "The first registry event has no registry ID."
            }
        }
        else {
            if ([string]$event.registry_id -ne $registryId) {
                throw "Registry ID changed at event $sequence."
            }
            if ([string]$event.previous_hash -ne $previousHash) {
                throw "Registry predecessor hash mismatch at event $sequence."
            }
        }

        $calculatedHash = Get-HerdrRegistryRecordHash -Record $event
        if ([string]$event.record_hash -ne $calculatedHash) {
            throw "Registry record hash mismatch at event $sequence."
        }
        $previousHash = $calculatedHash

        if (-not [string]::IsNullOrWhiteSpace([string]$event.canonical_name) -and [long]$event.generation -gt 0) {
            $name = [string]$event.canonical_name
            $generation = [long]$event.generation
            if (-not $highWater.Contains($name) -or [long]$highWater[$name] -lt $generation) {
                $highWater[$name] = $generation
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$event.binding_id)) {
            $bindings[[string]$event.binding_id] = $event
        }
        if ([string]$event.action -in @("authority-acquire", "authority-renew", "authority-revoke")) {
            $authority = $event
        }

        if ([int]$receipt.schema_version -ne $script:RegistrySchemaVersion -or
            [long]$receipt.event_seq -ne $sequence -or
            [string]$receipt.registry_id -ne $registryId -or
            [string]$receipt.event_id -ne [string]$event.event_id -or
            [string]$receipt.head_hash -ne $calculatedHash) {
            throw "Registry commit receipt mismatch at event $sequence."
        }
        $receiptHash = Get-HerdrRegistryRecordHash -Record $receipt
        if ([string]$receipt.receipt_hash -ne $receiptHash) {
            throw "Registry receipt hash mismatch at event $sequence."
        }
        $expectedHighWater = ConvertTo-HerdrRegistryJson -Value (Copy-HerdrGenerationHighWater -HighWater $highWater)
        $actualHighWater = ConvertTo-HerdrRegistryJson -Value $receipt.generation_high_water
        if ($expectedHighWater -ne $actualHighWater) {
            throw "Registry generation high-water mismatch at event $sequence."
        }
    }

    return [pscustomobject]@{
        schema_version = $script:RegistrySchemaVersion
        registry_id = $registryId
        event_count = $events.Count
        head_hash = $previousHash
        events = $events
        receipts = $receipts
        bindings = $bindings
        generation_high_water = $highWater
        authority = $authority
    }
}

function Add-HerdrPaneRegistryEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [string]$ReceiptPath = "$RegistryPath.receipts.jsonl",
        [Parameter(Mandatory)][Collections.IDictionary]$Fields,
        [string]$ExpectedHeadHash,
        [switch]$ExpectAbsent
    )

    $mutex = Enter-HerdrRegistryLock -RegistryPath $RegistryPath
    try {
        $state = Get-HerdrPaneRegistryState -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath
        if ($ExpectAbsent -and $state.event_count -ne 0) {
            throw "Registry bootstrap requires an absent registry."
        }
        if ($PSBoundParameters.ContainsKey("ExpectedHeadHash") -and [string]$state.head_hash -ne $ExpectedHeadHash) {
            throw "Registry head changed before append."
        }

        $requestedEventId = if ($Fields.Contains("event_id")) { [string]$Fields.event_id } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($requestedEventId) -and
            @($state.events | Where-Object { [string]$_.event_id -eq $requestedEventId }).Count -ne 0) {
            throw "Registry event ID '$requestedEventId' already exists."
        }
        if ([string]$Fields.action -eq "active") {
            $activeBindings = @(Get-HerdrRegistryActiveBindings -State $state)
            $nameConflicts = @($activeBindings | Where-Object {
                [string]$_.canonical_name -ceq [string]$Fields.canonical_name -and
                [string]$_.binding_id -ne [string]$Fields.binding_id
            })
            if ($nameConflicts.Count -ne 0) {
                throw "Canonical pane name '$($Fields.canonical_name)' already has an active binding."
            }
            $sessionConflicts = @($activeBindings | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$Fields.agent_session) -and
                [string]$_.agent_session -eq [string]$Fields.agent_session -and
                [string]$_.binding_id -ne [string]$Fields.binding_id
            })
            if ($sessionConflicts.Count -ne 0) {
                throw "Native agent session '$($Fields.agent_session)' is already bound to another active pane."
            }
        }

        $registryId = if ($state.event_count -eq 0) {
            if (-not $Fields.Contains("registry_id") -or [string]::IsNullOrWhiteSpace([string]$Fields.registry_id)) {
                throw "The first registry event requires registry_id."
            }
            [string]$Fields.registry_id
        }
        else {
            [string]$state.registry_id
        }
        if ($Fields.Contains("registry_id") -and [string]$Fields.registry_id -ne $registryId) {
            throw "Event registry_id does not match the durable registry."
        }

        $record = [ordered]@{
            schema_version = $script:RegistrySchemaVersion
            event_id = if ($Fields.Contains("event_id")) { [string]$Fields.event_id } else { "evt_$([Guid]::NewGuid().ToString('N'))" }
            event_seq = [long]$state.event_count + 1
            timestamp_utc = if ($Fields.Contains("timestamp_utc")) { [string]$Fields.timestamp_utc } else { [DateTimeOffset]::UtcNow.ToString("o") }
            action = [string]$Fields.action
            registry_id = $registryId
            binding_id = if ($Fields.Contains("binding_id")) { $Fields.binding_id } else { $null }
            canonical_name = if ($Fields.Contains("canonical_name")) { $Fields.canonical_name } else { $null }
            generation = if ($Fields.Contains("generation")) { [long]$Fields.generation } else { 0 }
            aliases = if ($Fields.Contains("aliases") -and @($Fields.aliases).Count -gt 0) { @($Fields.aliases) } else { $null }
            canonical_workspace = if ($Fields.Contains("canonical_workspace")) { $Fields.canonical_workspace } else { $null }
            workspace_id = if ($Fields.Contains("workspace_id")) { $Fields.workspace_id } else { $null }
            tab_id = if ($Fields.Contains("tab_id")) { $Fields.tab_id } else { $null }
            pane_id = if ($Fields.Contains("pane_id")) { $Fields.pane_id } else { $null }
            terminal_id = if ($Fields.Contains("terminal_id")) { $Fields.terminal_id } else { $null }
            tab_label = if ($Fields.Contains("tab_label")) { $Fields.tab_label } else { $null }
            pane_label = if ($Fields.Contains("pane_label")) { $Fields.pane_label } else { $null }
            agent = if ($Fields.Contains("agent")) { $Fields.agent } else { $null }
            agent_session = if ($Fields.Contains("agent_session")) { $Fields.agent_session } else { $null }
            repo = if ($Fields.Contains("repo")) { $Fields.repo } else { $null }
            lane = if ($Fields.Contains("lane")) { $Fields.lane } else { $null }
            role = if ($Fields.Contains("role")) { $Fields.role } else { $null }
            slot = if ($Fields.Contains("slot")) { [long]$Fields.slot } else { 0 }
            work_kind = if ($Fields.Contains("work_kind")) { $Fields.work_kind } else { $null }
            github_repo = if ($Fields.Contains("github_repo")) { $Fields.github_repo } else { $null }
            issue = if ($Fields.Contains("issue")) { $Fields.issue } else { $null }
            title = if ($Fields.Contains("title")) { $Fields.title } else { $null }
            work_subname = if ($Fields.Contains("work_subname")) { $Fields.work_subname } else { $null }
            predecessor_event = if ($Fields.Contains("predecessor_event")) { $Fields.predecessor_event } else { $null }
            reason = if ($Fields.Contains("reason")) { $Fields.reason } else { $null }
            authority_epoch = if ($Fields.Contains("authority_epoch")) { [long]$Fields.authority_epoch } else { 0 }
            authority_lease_id = if ($Fields.Contains("authority_lease_id")) { $Fields.authority_lease_id } else { $null }
            authority_expires_utc = if ($Fields.Contains("authority_expires_utc")) { $Fields.authority_expires_utc } else { $null }
            coordinator_pane_id = if ($Fields.Contains("coordinator_pane_id")) { $Fields.coordinator_pane_id } else { $null }
            coordinator_session = if ($Fields.Contains("coordinator_session")) { $Fields.coordinator_session } else { $null }
            reservation_id = if ($Fields.Contains("reservation_id")) { $Fields.reservation_id } else { $null }
            reservation_expires_utc = if ($Fields.Contains("reservation_expires_utc")) { $Fields.reservation_expires_utc } else { $null }
            claimant_challenge_hash = if ($Fields.Contains("claimant_challenge_hash")) { $Fields.claimant_challenge_hash } else { $null }
            transaction_phase = if ($Fields.Contains("transaction_phase")) { $Fields.transaction_phase } else { $null }
            metadata = if ($Fields.Contains("metadata")) { $Fields.metadata } else { $null }
            previous_hash = $state.head_hash
        }
        if ([string]::IsNullOrWhiteSpace([string]$record.action)) {
            throw "Registry event action is required."
        }
        $record.record_hash = Get-HerdrRegistryRecordHash -Record ([pscustomobject]$record)
        Write-HerdrRegistryDurableLine -Path $RegistryPath -Line (ConvertTo-HerdrRegistryJson -Value $record)

        $newHighWater = [ordered]@{}
        foreach ($name in $state.generation_high_water.Keys) {
            $newHighWater[[string]$name] = [long]$state.generation_high_water[$name]
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$record.canonical_name) -and $record.generation -gt 0) {
            if (-not $newHighWater.Contains([string]$record.canonical_name) -or
                [long]$newHighWater[[string]$record.canonical_name] -lt $record.generation) {
                $newHighWater[[string]$record.canonical_name] = $record.generation
            }
        }
        $receipt = [ordered]@{
            schema_version = $script:RegistrySchemaVersion
            registry_id = $registryId
            event_id = $record.event_id
            event_seq = $record.event_seq
            head_hash = $record.record_hash
            generation_high_water = Copy-HerdrGenerationHighWater -HighWater $newHighWater
            committed_utc = [DateTimeOffset]::UtcNow.ToString("o")
        }
        $receipt.receipt_hash = Get-HerdrRegistryRecordHash -Record ([pscustomobject]$receipt)
        Write-HerdrRegistryDurableLine -Path $ReceiptPath -Line (ConvertTo-HerdrRegistryJson -Value $receipt)
        return [pscustomobject]$record
    }
    finally {
        Exit-HerdrRegistryLock -Mutex $mutex
    }
}

function Get-HerdrCanonicalWorkspace {
    param([Parameter(Mandatory)][string]$Repo)

    $code = $Repo.Trim().ToUpperInvariant()
    if (-not $script:CanonicalWorkspaces.Contains($code)) {
        throw "Unsupported repository code '$Repo'."
    }
    return [string]$script:CanonicalWorkspaces[$code]
}

function Get-HerdrCanonicalPaneName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$Lane,
        [string]$Role,
        [ValidateRange(1, 999)][int]$Slot = 1,
        [switch]$Explore,
        [switch]$Coordination,
        [switch]$Fix
    )

    $code = $Repo.Trim().ToUpperInvariant()
    $workspace = Get-HerdrCanonicalWorkspace -Repo $code
    if ($Coordination -or $Fix) {
        if ($code -ne "HDR" -or $workspace -ne "Hdr") {
            throw "Coordination and Fix are reserved to the Hdr workspace."
        }
        if ($Coordination -and $Fix) {
            throw "A pane cannot be both Coordination and Fix."
        }
        return $(if ($Coordination) { "Coordination" } else { "Fix" })
    }
    if ($Explore) {
        return "$code-E$Slot"
    }
    $canonicalLane = $Lane.Trim().ToUpperInvariant()
    $canonicalRole = $Role.Trim().ToUpperInvariant()
    if ($canonicalLane -notin $script:CanonicalLanes) {
        throw "Unsupported lane '$Lane'."
    }
    if ($canonicalRole -notin $script:CanonicalRoles) {
        throw "Unsupported role '$Role'."
    }
    return "$code-$canonicalLane-$canonicalRole$Slot"
}

function Assert-HerdrCanonicalWorkspaceBinding {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$WorkspaceLabel
    )

    $expected = Get-HerdrCanonicalWorkspace -Repo $Repo
    if ($WorkspaceLabel -cne $expected) {
        throw "Repository $($Repo.ToUpperInvariant()) must use workspace '$expected'; observed '$WorkspaceLabel'."
    }
    return $expected
}

function Test-HerdrRegistryAuthorityCurrent {
    param(
        [Parameter(Mandatory)]$State,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    if ($null -eq $State.authority -or [string]$State.authority.action -eq "authority-revoke") {
        return $false
    }
    $expiry = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$State.authority.authority_expires_utc, [ref]$expiry)) {
        return $false
    }
    return $expiry -gt $Now
}

function Get-HerdrRegistryActiveBindings {
    param([Parameter(Mandatory)]$State)

    $active = [Collections.Generic.List[object]]::new()
    foreach ($entry in $State.bindings.GetEnumerator()) {
        $event = $entry.Value
        if ([string]$event.action -eq "active") {
            $active.Add($event)
        }
    }
    return @($active)
}

function Resolve-HerdrPaneRegistryName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [string]$ReceiptPath = "$RegistryPath.receipts.jsonl",
        [Parameter(Mandatory)][string]$Name,
        [switch]$ForDispatch,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    $canonical = $Name.Trim()
    if ($canonical -match '^@pane\[(?<name>[^\]]+)\]$') {
        $canonical = $Matches.name
    }
    $state = Get-HerdrPaneRegistryState -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath
    if ($state.event_count -eq 0) {
        throw "Pane registry is not initialized."
    }
    $matches = @(Get-HerdrRegistryActiveBindings -State $state | Where-Object {
        [string]$_.canonical_name -ceq $canonical
    })
    if ($matches.Count -ne 1) {
        throw "Pane name '$canonical' does not resolve to exactly one active registry binding."
    }
    $binding = $matches[0]
    $dispatchable = Test-HerdrRegistryAuthorityCurrent -State $state -Now $Now
    if ($ForDispatch -and -not $dispatchable) {
        throw "Pane registry authority is absent or expired; '$canonical' is NON-DISPATCHABLE."
    }
    return [pscustomobject]@{
        registry_id = [string]$state.registry_id
        binding_id = [string]$binding.binding_id
        canonical_name = [string]$binding.canonical_name
        generation = [long]$binding.generation
        canonical_workspace = [string]$binding.canonical_workspace
        workspace_id = [string]$binding.workspace_id
        tab_id = [string]$binding.tab_id
        pane_id = [string]$binding.pane_id
        terminal_id = [string]$binding.terminal_id
        tab_label = [string]$binding.tab_label
        agent = [string]$binding.agent
        agent_session = [string]$binding.agent_session
        work_subname = [string]$binding.work_subname
        dispatchable = $dispatchable
        authority_epoch = if ($null -ne $state.authority) { [long]$state.authority.authority_epoch } else { 0 }
        head_hash = [string]$state.head_hash
    }
}

function Resolve-HerdrPaneRegistryPane {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [string]$ReceiptPath = "$RegistryPath.receipts.jsonl",
        [Parameter(Mandatory)][string]$PaneId,
        [switch]$ForDispatch,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    if ($PaneId -notmatch '^w[^:]+:p[^:]+$') {
        throw "Invalid explicit pane ID '$PaneId'."
    }
    $state = Get-HerdrPaneRegistryState -RegistryPath $RegistryPath -ReceiptPath $ReceiptPath
    if ($state.event_count -eq 0) {
        throw "Pane registry is not initialized."
    }
    $matches = @(Get-HerdrRegistryActiveBindings -State $state | Where-Object {
        [string]$_.pane_id -eq $PaneId
    })
    if ($matches.Count -ne 1) {
        throw "Pane '$PaneId' does not resolve to exactly one active registry binding."
    }
    return Resolve-HerdrPaneRegistryName `
        -RegistryPath $RegistryPath `
        -ReceiptPath $ReceiptPath `
        -Name ([string]$matches[0].canonical_name) `
        -ForDispatch:$ForDispatch `
        -Now $Now
}

Export-ModuleMember -Function @(
    "Get-HerdrRegistrySha256",
    "Get-HerdrPaneRegistryState",
    "Add-HerdrPaneRegistryEvent",
    "Get-HerdrCanonicalWorkspace",
    "Get-HerdrCanonicalPaneName",
    "Assert-HerdrCanonicalWorkspaceBinding",
    "Test-HerdrRegistryAuthorityCurrent",
    "Get-HerdrRegistryActiveBindings",
    "Resolve-HerdrPaneRegistryName",
    "Resolve-HerdrPaneRegistryPane"
)

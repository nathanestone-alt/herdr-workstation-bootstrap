[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "HerdrPaneRegistry.psm1"
Import-Module $modulePath -Force

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-pane-registry-tests-$([Guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $testRoot -Force
$script:Passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
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
    $threw = $false
    try {
        & $Script
    }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Message (wrong error: $($_.Exception.Message))"
        }
    }
    if (-not $threw) {
        throw "$Message (no error was thrown)"
    }
    $script:Passed++
}

function New-Fixture {
    param([string]$Name)
    $dir = Join-Path $testRoot $Name
    $null = New-Item -ItemType Directory -Path $dir -Force
    return [pscustomobject]@{
        Registry = Join-Path $dir "registry.jsonl"
        Receipts = Join-Path $dir "registry.receipts.jsonl"
    }
}

function Add-Authority {
    param($Fixture, [DateTimeOffset]$Expiry = [DateTimeOffset]::UtcNow.AddMinutes(10))
    return Add-HerdrPaneRegistryEvent -RegistryPath $Fixture.Registry -ReceiptPath $Fixture.Receipts -ExpectAbsent -Fields ([ordered]@{
        action = "authority-acquire"
        registry_id = "reg_$([Guid]::NewGuid().ToString('N'))"
        authority_epoch = 1
        authority_lease_id = "lease_$([Guid]::NewGuid().ToString('N'))"
        authority_expires_utc = $Expiry.ToString("o")
        canonical_workspace = "Hdr"
        workspace_id = "w1"
        tab_id = "w1:t1"
        pane_id = "w1:p1"
        terminal_id = "term_coord"
        tab_label = "Coordination"
        agent = "codex"
        agent_session = "session-coordinator"
        coordinator_pane_id = "w1:p1"
        coordinator_session = "session-coordinator"
        reason = "test bootstrap"
    })
}

function Add-ActiveBinding {
    param(
        $Fixture,
        [string]$BindingId,
        [string]$Name,
        [long]$Generation,
        [string]$PaneId,
        [string]$Session,
        [string]$Repo = "STM",
        [string]$Workspace = "STM"
    )
    return Add-HerdrPaneRegistryEvent -RegistryPath $Fixture.Registry -ReceiptPath $Fixture.Receipts -Fields ([ordered]@{
        action = "active"
        binding_id = $BindingId
        canonical_name = $Name
        generation = $Generation
        canonical_workspace = $Workspace
        workspace_id = "w2"
        tab_id = "w2:t$Generation"
        pane_id = $PaneId
        terminal_id = "term_$BindingId"
        tab_label = $Name
        agent = "claude"
        agent_session = $Session
        repo = $Repo
        lane = if ($Name -match "-E\d+$") { $null } else { "T" }
        role = if ($Name -match "-E\d+$") { $null } else { "R" }
        slot = 1
        work_kind = "explore"
        work_subname = "EXPLORE · unassigned"
        authority_epoch = 1
        authority_lease_id = "lease-test"
        coordinator_pane_id = "w1:p1"
        coordinator_session = "session-coordinator"
        transaction_phase = "active"
    })
}

try {
    Assert-Equal (Get-HerdrCanonicalPaneName -Repo STM -Explore -Slot 1) "STM-E1" "Explore naming failed"
    Assert-Equal (Get-HerdrCanonicalPaneName -Repo AGT -Lane LSP -Role R -Slot 2) "AGT-LSP-R2" "Assigned naming failed"
    Assert-Equal (Get-HerdrCanonicalPaneName -Repo HDR -Coordination) "Coordination" "Reserved Coordination naming failed"
    Assert-Equal (Get-HerdrCanonicalPaneName -Repo HDR -Fix) "Fix" "Reserved Fix naming failed"
    Assert-Throws { Get-HerdrCanonicalPaneName -Repo STModel -Explore } "Unsupported repository" "Alternate repository spelling was accepted"
    Assert-Throws { Get-HerdrCanonicalPaneName -Repo STM -Lane Tooling -Role R } "Unsupported lane" "Malformed lane was accepted"
    Assert-Throws { Get-HerdrCanonicalPaneName -Repo STM -Lane T -Role Reviewer } "Unsupported role" "Malformed role was accepted"
    Assert-Throws { Assert-HerdrCanonicalWorkspaceBinding -Repo STM -WorkspaceLabel master } "must use workspace 'STM'" "Cross-workspace binding was accepted"

    $basic = New-Fixture "basic"
    $authority = Add-Authority $basic
    Add-ActiveBinding $basic "bind-1" "STM-E1" 1 "w2:p1" "session-one" | Out-Null
    $state = Get-HerdrPaneRegistryState -RegistryPath $basic.Registry -ReceiptPath $basic.Receipts
    Assert-Equal $state.event_count 2 "Event count was not reconstructed"
    Assert-Equal $state.head_hash $state.receipts[-1].head_hash "Head receipt was not reconstructed"
    Assert-Equal $state.generation_high_water["STM-E1"] 1 "Generation high-water was not reconstructed"
    $resolved = Resolve-HerdrPaneRegistryName -RegistryPath $basic.Registry -ReceiptPath $basic.Receipts -Name "@pane[STM-E1]" -ForDispatch
    Assert-Equal $resolved.pane_id "w2:p1" "Human pane reference resolved to the wrong pane"
    Assert-True $resolved.dispatchable "Current-authority binding was not dispatchable"
    Assert-Equal $resolved.registry_id $authority.registry_id "Resolution lost registry identity"

    Assert-Throws {
        Add-ActiveBinding $basic "bind-2" "STM-E1" 2 "w2:p2" "session-two"
    } "already has an active binding" "Duplicate active canonical name was accepted"
    Assert-Throws {
        Add-ActiveBinding $basic "bind-2" "STM-E2" 1 "w2:p2" "session-one"
    } "already bound" "Duplicate native session was accepted"
    Assert-Throws {
        Add-HerdrPaneRegistryEvent -RegistryPath $basic.Registry -ReceiptPath $basic.Receipts -Fields ([ordered]@{
            action = "metadata-update"; event_id = $authority.event_id
        })
    } "already exists" "Duplicate event ID was accepted"

    Add-HerdrPaneRegistryEvent -RegistryPath $basic.Registry -ReceiptPath $basic.Receipts -Fields ([ordered]@{
        action = "retired"
        binding_id = "bind-1"
        canonical_name = "STM-E1"
        generation = 1
        authority_epoch = 1
        authority_lease_id = "lease-test"
        transaction_phase = "retired"
    }) | Out-Null
    Assert-Throws {
        Resolve-HerdrPaneRegistryName -RegistryPath $basic.Registry -ReceiptPath $basic.Receipts -Name "STM-E1"
    } "does not resolve" "Retired binding remained routeable"
    Add-ActiveBinding $basic "bind-2" "STM-E1" 2 "w2:p2" "session-two" | Out-Null
    $reused = Resolve-HerdrPaneRegistryName -RegistryPath $basic.Registry -ReceiptPath $basic.Receipts -Name "STM-E1" -ForDispatch
    Assert-Equal $reused.generation 2 "Reused name did not advance generation"
    Assert-Equal $reused.pane_id "w2:p2" "Reused name routed to the retired pane"

    $expired = New-Fixture "expired"
    Add-Authority $expired ([DateTimeOffset]::UtcNow.AddMinutes(-1)) | Out-Null
    Add-ActiveBinding $expired "bind-expired" "AGT-E1" 1 "w3:p1" "session-expired" "AGT" "AGT" | Out-Null
    $displayOnly = Resolve-HerdrPaneRegistryName -RegistryPath $expired.Registry -ReceiptPath $expired.Receipts -Name "AGT-E1"
    Assert-True (-not $displayOnly.dispatchable) "Expired authority was reported as dispatchable"
    Assert-Throws {
        Resolve-HerdrPaneRegistryName -RegistryPath $expired.Registry -ReceiptPath $expired.Receipts -Name "AGT-E1" -ForDispatch
    } "NON-DISPATCHABLE" "Dispatch was allowed through expired authority"

    $torn = New-Fixture "torn"
    Add-Authority $torn | Out-Null
    [IO.File]::AppendAllText($torn.Registry, '{"schema_version":1', [Text.UTF8Encoding]::new($false))
    Assert-Throws {
        Get-HerdrPaneRegistryState -RegistryPath $torn.Registry -ReceiptPath $torn.Receipts
    } "truncated" "Torn registry tail was accepted"

    $missingReceipt = New-Fixture "missing-receipt"
    Add-Authority $missingReceipt | Out-Null
    [IO.File]::WriteAllText($missingReceipt.Receipts, "", [Text.UTF8Encoding]::new($false))
    Assert-Throws {
        Get-HerdrPaneRegistryState -RegistryPath $missingReceipt.Registry -ReceiptPath $missingReceipt.Receipts
    } "count mismatch" "Missing commit receipt was accepted"

    $corrupt = New-Fixture "corrupt"
    Add-Authority $corrupt | Out-Null
    $raw = [IO.File]::ReadAllText($corrupt.Registry)
    $raw = $raw.Replace('"reason":"test bootstrap"', '"reason":"tampered"')
    [IO.File]::WriteAllText($corrupt.Registry, $raw, [Text.UTF8Encoding]::new($false))
    Assert-Throws {
        Get-HerdrPaneRegistryState -RegistryPath $corrupt.Registry -ReceiptPath $corrupt.Receipts
    } "hash mismatch" "Tampered registry record was accepted"

    $race = New-Fixture "concurrency"
    Add-Authority $race | Out-Null
    $commands = for ($i = 1; $i -le 8; $i++) {
        $command = @"
Import-Module '$modulePath' -Force
Add-HerdrPaneRegistryEvent -RegistryPath '$($race.Registry)' -ReceiptPath '$($race.Receipts)' -Fields ([ordered]@{ action='metadata-update'; reason='concurrent-$i' }) | Out-Null
"@
        Start-Process pwsh -ArgumentList @("-NoProfile", "-Command", $command) -PassThru -WindowStyle Hidden
    }
    $commands | Wait-Process
    foreach ($process in $commands) {
        Assert-Equal $process.ExitCode 0 "Concurrent registry writer failed"
    }
    $raceState = Get-HerdrPaneRegistryState -RegistryPath $race.Registry -ReceiptPath $race.Receipts
    Assert-Equal $raceState.event_count 9 "Concurrent registry writes were lost or duplicated"

    [pscustomobject]@{
        passed = $script:Passed
        test_root = $testRoot
    } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$reviewedVersion = "0.8.0-preview.2026-08-04-d78e3d3b5126"
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([Parameter(Mandatory)][string]$Message)
    $failures.Add($Message)
}

if ($env:HERDR_ENV -ne "1") {
    Add-Failure "HERDR_ENV is not 1; compatibility must be checked from a Herdr-managed pane."
}

$currentVersionText = (& herdr --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    Add-Failure "herdr --version failed: $currentVersionText"
}

$currentVersion = $currentVersionText -replace "^herdr\s+", ""
if ($currentVersion -ne $reviewedVersion) {
    Add-Failure "Herdr version $currentVersion has not been reviewed; expected $reviewedVersion."
}

$builtinSkill = (& herdr --skill 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
    Add-Failure "herdr --skill failed."
}

$requiredBuiltinPatterns = @(
    "herdr agent prompt reviewer",
    "herdr agent wait reviewer",
    "herdr pane wait-output <returned-pane-id>"
)
foreach ($pattern in $requiredBuiltinPatterns) {
    if ($builtinSkill -notlike "*$pattern*") {
        Add-Failure "Bundled Herdr skill is missing expected command form: $pattern"
    }
}

$agentPromptHelp = (& herdr agent prompt --help 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $agentPromptHelp -notmatch 'agent_prompt_stalled' -or
    $agentPromptHelp -notmatch 'observed state change within 5000ms') {
    Add-Failure "Herdr agent prompt no longer exposes the reviewed stalled-submission proof contract."
}

$agentWaitHelp = (& herdr agent wait --help 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $agentWaitHelp -notmatch 'idle, working, blocked, done, unknown') {
    Add-Failure "Herdr agent wait no longer exposes the reviewed lifecycle states."
}

$paneHelp = (& herdr pane --help 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
    Add-Failure "herdr pane --help failed."
}
foreach ($paneCommand in @("report-agent-session", "report-metadata", "wait-output")) {
    if ($paneHelp -notmatch "(?m)^\s+$([regex]::Escape($paneCommand))\s") {
        Add-Failure "Herdr pane command surface is missing $paneCommand."
    }
}

$homePath = [Environment]::GetFolderPath("UserProfile")
$skillPaths = @(
    (Join-Path $homePath ".agents\skills\herdr\SKILL.md"),
    (Join-Path $homePath ".claude\skills\herdr\SKILL.md"),
    (Join-Path $homePath ".agents\skills\herdr-coordination\SKILL.md")
)
$reviewMarker = "Compatibility reviewed for Herdr " + [char]96 + $reviewedVersion + [char]96

foreach ($skillPath in $skillPaths) {
    if (-not (Test-Path -LiteralPath $skillPath)) {
        Add-Failure "Missing Herdr-related skill: $skillPath"
        continue
    }

    $content = Get-Content -Raw -LiteralPath $skillPath
    if ($content -notmatch [regex]::Escape($reviewMarker)) {
        Add-Failure "Skill is not pinned to the reviewed Herdr version: $skillPath"
    }
}

$controlSkillPaths = $skillPaths[0..1]
foreach ($skillPath in $controlSkillPaths) {
    $content = Get-Content -Raw -LiteralPath $skillPath
    if ($content -match "(?m)^\s*herdr wait(?:\s|$)") {
        Add-Failure "Obsolete top-level herdr wait syntax remains in $skillPath"
    }
    foreach ($pattern in @(
        "herdr agent prompt reviewer",
        "herdr agent wait reviewer",
        "herdr pane wait-output <returned-pane-id>"
    )) {
        if ($content -notlike "*$pattern*") {
            Add-Failure "Current command form '$pattern' is missing from $skillPath"
        }
    }
    if ($content -notlike "*herdr_coordination.ps1*") {
        Add-Failure "Tracked coordination overlay is missing from $skillPath"
    }
    if ($content -notmatch 'agent_prompted.+proves only.+terminal transport' -or
        $content -notmatch 'require `state_change_seq` to advance') {
        Add-Failure "No-wait agent_prompted false-success containment is missing from $skillPath"
    }
    if ($content -notmatch "native host-shell tool" -or
        $content -notmatch "missing value inside such a subprocess is not evidence") {
        Add-Failure "Sandboxed HERDR_ENV false-negative containment is missing from $skillPath"
    }
    if ($content -notmatch '`--current` still falls back to the UI-focused pane' -or
        $content -notmatch 'Never invoke `--current` as a recovery path') {
        Add-Failure "Caller-less --current UI-focus fallback containment is missing from $skillPath"
    }
}

$coordinationSkillContent = Get-Content -Raw -LiteralPath $skillPaths[2]
if ($coordinationSkillContent -notmatch 'Omitting `--wait` still returns only the unproven `agent_prompted` transport receipt' -or
    $coordinationSkillContent -notmatch 'proof-bound Enter recovery') {
    Add-Failure "Coordination skill is missing no-wait false-success containment."
}
if ($coordinationSkillContent -notmatch "native host-shell tool" -or
    $coordinationSkillContent -notmatch "subprocesses may strip pane-scoped") {
    Add-Failure "Coordination skill is missing sandboxed HERDR_ENV false-negative containment."
}
if ($coordinationSkillContent -notmatch '`--current` fall back to UI focus' -or
    $coordinationSkillContent -notmatch 'never use `--current` as identity recovery') {
    Add-Failure "Coordination skill is missing caller-less --current UI-focus fallback containment."
}
if ($coordinationSkillContent -notmatch 'REISSUE-OF' -or
    $coordinationSkillContent -notmatch 'effective_body_read' -or
    $coordinationSkillContent -notmatch 'payload SHA-256') {
    Add-Failure "Coordination skill is missing native-session rotation and exact-payload relay lineage guidance."
}
if ($coordinationSkillContent -notmatch 'Never replay the newest or most recent `%TEMP%` hook payload' -or
    $coordinationSkillContent -notmatch 'top-level `session_id` exactly matches') {
    Add-Failure "Coordination skill does not prohibit cross-pane temporary hook-payload replay."
}
if ($coordinationSkillContent -notmatch 'PANE NAMING REQUEST' -or
    $coordinationSkillContent -notmatch '`--display-agent`' -or
    $coordinationSkillContent -notmatch '@pane\[STM-WB-O1\]' -or
    $coordinationSkillContent -notmatch 'A pane requests naming changes; it does not rename itself') {
    Add-Failure "Coordination skill is missing coordinator-owned canonical naming and work-subtitle guidance."
}
$coordinationHelperContent = Get-Content -Raw -LiteralPath (Join-Path (Split-Path $skillPaths[2]) "scripts\herdr_coordination.ps1")
$workflowHelperContent = Get-Content -Raw -LiteralPath (Join-Path (Split-Path $skillPaths[2]) "scripts\herdr_workflow.ps1")
$registryHelperPath = Join-Path (Split-Path $skillPaths[2]) "scripts\herdr_pane_registry.ps1"
$registryModulePath = Join-Path (Split-Path $skillPaths[2]) "scripts\HerdrPaneRegistry.psm1"
if (-not (Test-Path -LiteralPath $registryHelperPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $registryModulePath -PathType Leaf)) {
    Add-Failure "Coordination skill is missing the durable pane-registry helper or module."
}
else {
    $registryHelperContent = Get-Content -Raw -LiteralPath $registryHelperPath
    $registryModuleContent = Get-Content -Raw -LiteralPath $registryModulePath
    if ($registryHelperContent -notmatch 'authority-acquire' -or
        $registryHelperContent -notmatch 'ack-assignment' -or
        $registryHelperContent -notmatch 'revalidate' -or
        $registryModuleContent -notmatch 'generation_high_water' -or
        $registryModuleContent -notmatch 'Get-HerdrRegistryActiveBindings') {
        Add-Failure "Pane registry is missing authority, claimant ACK, generation, or revalidation controls."
    }
}
if ($coordinationHelperContent -notmatch 'New-SessionRotatedRelay' -or
    $coordinationHelperContent -notmatch 'PAYLOAD-SHA256' -or
    $coordinationHelperContent -notmatch 'REISSUE-OF' -or
    $coordinationHelperContent -notmatch 'Test-CurrentProcessDescendsFrom') {
    Add-Failure "Coordination helper is missing rotation-safe relay metadata or successor creation."
}
if ($workflowHelperContent -notmatch 'source_session_rotated_from' -or
    $workflowHelperContent -notmatch 'effective_return_relay_ref') {
    Add-Failure "Workflow helper is missing completion-return session-rotation lineage."
}
if ($workflowHelperContent -notmatch 'request_reissue_reserved' -or
    $workflowHelperContent -notmatch 'target_reasoning_effort' -or
    $workflowHelperContent -notmatch 'service tier continuity' -or
    $workflowHelperContent -notmatch 'request_delivery_reserved' -or
    $workflowHelperContent -notmatch 'delivery_attempt_id' -or
    $workflowHelperContent -notmatch 'Get-OptionalPropertyDateTimeUtc' -or
    $coordinationHelperContent -notmatch 'ExpectedTabId' -or
    $coordinationSkillContent -notmatch 'Coordination never infers, repairs, downshifts, or' -or
    $coordinationSkillContent -notmatch 'fencing claim') {
    Add-Failure "Workflow rotation reissue is missing model-profile continuity and fail-closed guidance."
}
if ($coordinationHelperContent -notmatch 'prove-caller' -or
    $coordinationHelperContent -notmatch 'Assert-RelayReadIntegrity' -or
    $coordinationHelperContent -notmatch 'pending_watch_after_prompt_error' -or
    $coordinationHelperContent -notmatch 'append refuses receipt or lineage-bearing protocol entries') {
    Add-Failure "Coordination helper is missing process-bound caller proof, relay-integrity validation, or fail-closed prompt semantics."
}
if ($workflowHelperContent -notmatch 'Assert-WorkflowCallerProof' -or
    $workflowHelperContent -notmatch 'source_tab_id' -or
    $workflowHelperContent -notmatch 'no durable work ACK' -or
    $workflowHelperContent -notmatch 'Read-WorkflowArtifactSnapshot' -or
    $workflowHelperContent -notmatch 'request_reserved') {
    Add-Failure "Workflow helper is missing caller-process proof, tab continuity, atomic ACK/completion gating, artifact snapshots, or reservation recovery."
}

$contextModeVersions = Join-Path $homePath ".codex\plugins\cache\context-mode\context-mode"
$contextModeSkill = Get-ChildItem -LiteralPath $contextModeVersions -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    ForEach-Object { Join-Path $_.FullName "skills\context-mode\SKILL.md" } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $contextModeSkill) {
    Add-Failure "Installed context-mode skill was not found for Herdr compatibility review."
}
else {
    $contextModeContent = Get-Content -Raw -LiteralPath $contextModeSkill
    if ($contextModeContent -notmatch "native host-shell tool" -or
        $contextModeContent -notmatch "initial inside/outside-Herdr safety decision") {
        Add-Failure "Context-mode skill does not preserve native Herdr environment authority: $contextModeSkill"
    }
}

$integrationStatus = (& herdr integration status 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) {
    Add-Failure "herdr integration status failed."
}
foreach ($agentKind in @("claude", "codex")) {
    if ($integrationStatus -notmatch "(?m)^$agentKind`: current \(v7\)") {
        Add-Failure "$agentKind integration is not current at the reviewed v7 schema."
    }
}

$claudeWrapper = Join-Path $homePath ".claude\hooks\herdr-agent-state-async.mjs"
if (-not (Test-Path -LiteralPath $claudeWrapper -PathType Leaf)) {
    Add-Failure "Missing Claude session-refresh wrapper: $claudeWrapper"
}
else {
    $claudeWrapperContent = Get-Content -Raw -LiteralPath $claudeWrapper
    if ($claudeWrapperContent -notmatch 'spawnSync\(' -or
        $claudeWrapperContent -notmatch 'report-agent-session') {
        Add-Failure "Claude refresh wrapper does not use the bounded direct reporter."
    }
    if ($claudeWrapperContent -match 'detached\s*:\s*true') {
        Add-Failure "Claude refresh wrapper still uses the lossy detached reporter path."
    }
}

$codexRefresh = Join-Path $homePath ".codex\herdr-agent-session-refresh.ps1"
if (-not (Test-Path -LiteralPath $codexRefresh -PathType Leaf)) {
    Add-Failure "Missing Codex session-refresh hook: $codexRefresh"
}
else {
    $codexRefreshContent = Get-Content -Raw -LiteralPath $codexRefresh
    if ($codexRefreshContent -notmatch 'transcript_path') {
        Add-Failure "Codex refresh hook does not forward the transcript path required by integration v7."
    }
}

foreach ($testName in @("test_codex_session_refresh.ps1", "test_claude_session_refresh.ps1")) {
    $testPath = Join-Path $PSScriptRoot $testName
    if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
        Add-Failure "Missing session-refresh regression: $testPath"
    }
}

foreach ($registryTestName in @("test_herdr_pane_registry.ps1", "test_herdr_pane_registry_cli.ps1")) {
    $registryTestPath = Join-Path $PSScriptRoot $registryTestName
    if (-not (Test-Path -LiteralPath $registryTestPath -PathType Leaf)) {
        Add-Failure "Missing pane-registry regression: $registryTestPath"
    }
}

$coordinationScript = Join-Path $homePath ".agents\skills\herdr-coordination\scripts\herdr_coordination.ps1"
if (-not (Test-Path -LiteralPath $coordinationScript)) {
    Add-Failure "Missing coordination transport: $coordinationScript"
} else {
    $coordinationContent = Get-Content -Raw -LiteralPath $coordinationScript
    if ($coordinationContent -notmatch '"agent",\s*"prompt"') {
        Add-Failure "Coordination transport does not use herdr agent prompt."
    }
    if ($coordinationContent -notmatch '"agent",\s*"wait"') {
        Add-Failure "Coordination transport does not use herdr agent wait."
    }
    if ($coordinationContent -match '"wait",\s*"agent-status"') {
        Add-Failure "Coordination transport still contains obsolete wait agent-status syntax."
    }
}

if ($failures.Count -gt 0) {
    Write-Output "HERDR SKILL COMPATIBILITY: FAIL"
    foreach ($failure in $failures) {
        Write-Output "- $failure"
    }
    exit 1
}

Write-Output "HERDR SKILL COMPATIBILITY: PASS"
Write-Output "- reviewed version: $reviewedVersion"
Write-Output "- bundled skill command surface: agent prompt/agent wait/pane wait-output"
Write-Output "- 0.8 proof surface: stalled prompt detection, session reporting, display metadata"
Write-Output "- control skills: shared Codex/Claude copies"
Write-Output "- coordination transport: current agent facade"
Write-Output "- session provenance: Claude direct reporter and Codex v7 refresh"
Write-Output "- pane naming: coordinator-owned canonical names, work subtitles, and generation-fenced registry routing"
Write-Output "- environment authority: native host shell; sandbox false negatives rejected"
Write-Output "- caller identity: explicit stable pane IDs; caller-less --current focus fallback contained"
Write-Output "- session rotation: exact-payload successor relays; old receipts remain immutable"

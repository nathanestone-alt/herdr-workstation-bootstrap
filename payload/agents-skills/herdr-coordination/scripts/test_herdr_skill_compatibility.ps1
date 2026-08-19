[CmdletBinding()]
param(
    [string]$HomePath,
    [switch]$SkipLiveChecks
)

$ErrorActionPreference = "Stop"
$reviewedVersion = "0.8.0"
$reviewedSkillVersion = "0.8.0-preview.2026-08-04-d78e3d3b5126"
$failures = [System.Collections.Generic.List[string]]::new()
$blockers = [System.Collections.Generic.List[string]]::new()
$isWindowsPlatform = [IO.Path]::DirectorySeparatorChar -eq [char]92
$builtinSkill = ""

function Add-Failure {
    param([Parameter(Mandatory)][string]$Message)
    $null = $failures.Add($Message)
}

function Add-Blocker {
    param([Parameter(Mandatory)][string]$Message)
    $null = $blockers.Add($Message)
}

function Resolve-HomeDirectory {
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        try {
            $explicitFullPath = [IO.Path]::GetFullPath($ExplicitPath)
        }
        catch {
            throw "Explicit home path is invalid: $ExplicitPath"
        }
        if (-not (Test-Path -LiteralPath $explicitFullPath -PathType Container)) {
            throw "Explicit home path is not a directory: $explicitFullPath"
        }
        return $explicitFullPath
    }

    foreach ($candidate in @($env:HOME, $env:USERPROFILE, [Environment]::GetFolderPath("UserProfile"))) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }
        try {
            $fullCandidate = [IO.Path]::GetFullPath([string]$candidate)
        }
        catch {
            continue
        }
        if (Test-Path -LiteralPath $fullCandidate -PathType Container) {
            return $fullCandidate
        }
    }

    throw "Unable to resolve a usable user home directory. Set HOME or USERPROFILE, or pass -HomePath explicitly."
}

function Get-JsonStringValues {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return
    }
    if ($Value -is [string]) {
        Write-Output ([string]$Value)
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) {
            Get-JsonStringValues -Value $entry.Value
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) {
            Get-JsonStringValues -Value $item
        }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        Get-JsonStringValues -Value $property.Value
    }
}

function Convert-HookPath {
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$HomeDirectory,
        [Parameter(Mandatory)][string]$ConfigurationPath
    )

    $path = $Candidate.Trim()
    $path = $path.Replace('$HOME', $HomeDirectory)
    $path = $path.Replace('%USERPROFILE%', $HomeDirectory)
    if ($isWindowsPlatform) {
        $path = $path.Replace('/', '\')
    }

    try {
        if ([IO.Path]::IsPathRooted($path)) {
            return [IO.Path]::GetFullPath($path)
        }
        return [IO.Path]::GetFullPath((Join-Path -Path (Split-Path -Parent $ConfigurationPath) -ChildPath $path))
    }
    catch {
        return $null
    }
}

function Get-ConfiguredHerdrHookPaths {
    param(
        [Parameter(Mandatory)][ValidateSet("claude", "codex")][string]$Agent,
        [Parameter(Mandatory)][string]$HomeDirectory
    )

    $configPaths = if ($Agent -eq "claude") {
        @(
            (Join-Path -Path (Join-Path -Path $HomeDirectory -ChildPath ".claude") -ChildPath "settings.json"),
            (Join-Path -Path (Join-Path -Path $HomeDirectory -ChildPath ".claude") -ChildPath "settings.local.json")
        )
    }
    else {
        @(
            (Join-Path -Path (Join-Path -Path $HomeDirectory -ChildPath ".codex") -ChildPath "hooks.json"),
            (Join-Path -Path (Join-Path -Path $HomeDirectory -ChildPath ".codex") -ChildPath "config.json")
        )
    }

    $pathPattern = '(?i)(?:"(?<double>[^"]*herdr[^"\r\n]+\.(?:sh|ps1|mjs|cmd|bat))"|''(?<single>[^''\r\n]*herdr[^''\r\n]+\.(?:sh|ps1|mjs|cmd|bat))''|(?<bare>[^\s"'']+herdr[^\s"'']+\.(?:sh|ps1|mjs|cmd|bat)))'
    foreach ($configurationPath in $configPaths) {
        if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
            continue
        }

        try {
            $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json
        }
        catch {
            Add-Blocker "Unable to parse installed $Agent hook configuration: $configurationPath ($($_.Exception.Message))"
            continue
        }

        foreach ($value in @(Get-JsonStringValues -Value $configuration)) {
            foreach ($match in [regex]::Matches([string]$value, $pathPattern)) {
                $rawPath = $null
                foreach ($groupName in @("double", "single", "bare")) {
                    if ($match.Groups[$groupName].Success) {
                        $rawPath = $match.Groups[$groupName].Value
                        break
                    }
                }
                if ([string]::IsNullOrWhiteSpace($rawPath)) {
                    continue
                }
                $resolvedPath = Convert-HookPath -Candidate $rawPath -HomeDirectory $HomeDirectory -ConfigurationPath $configurationPath
                if ($resolvedPath -and (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                    Write-Output $resolvedPath
                }
            }
        }
    }
}

function Get-InstalledHerdrHookPaths {
    param(
        [Parameter(Mandatory)][ValidateSet("claude", "codex")][string]$Agent,
        [Parameter(Mandatory)][string]$HomeDirectory
    )

    $roots = if ($Agent -eq "claude") {
        @(
            (Join-Path -Path (Join-Path -Path $HomeDirectory -ChildPath ".claude") -ChildPath "hooks"),
            (Join-Path -Path $HomeDirectory -ChildPath ".claude")
        )
    }
    else {
        @(
            (Join-Path -Path (Join-Path -Path $HomeDirectory -ChildPath ".codex") -ChildPath "hooks"),
            (Join-Path -Path $HomeDirectory -ChildPath ".codex")
        )
    }

    $allCandidates = @(
        Get-ConfiguredHerdrHookPaths -Agent $Agent -HomeDirectory $HomeDirectory
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        $allCandidates += @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)herdr-agent-(?:state|session)' } |
            Select-Object -ExpandProperty FullName)
    }

    $seen = @{}
    foreach ($candidate in $allCandidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate) -or
            -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $fullCandidate = [IO.Path]::GetFullPath([string]$candidate)
        $key = if ($isWindowsPlatform) { $fullCandidate.ToLowerInvariant() } else { $fullCandidate }
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            Write-Output $fullCandidate
        }
    }
}

function Select-HerdrHookPath {
    param(
        [Parameter(Mandatory)][string[]]$Candidates,
        [Parameter(Mandatory)][string]$Agent
    )

    $preferredName = if ($Agent -eq "claude") { "state-async|state" } else { "session-refresh|state" }
    $preferred = @($Candidates | Where-Object { (Split-Path -Leaf $_) -match "(?i)herdr-agent-($preferredName)" })
    if ($preferred.Count -gt 0) {
        return $preferred[0]
    }
    return $Candidates[0]
}

function Test-ManagedHookContract {
    param(
        [Parameter(Mandatory)][string]$HookPath,
        [Parameter(Mandatory)][ValidateSet("claude", "codex")][string]$Agent
    )

    $content = Get-Content -Raw -LiteralPath $HookPath
    $isManaged = $content -match '(?i)installed by herdr|managed by herdr|HERDR_INTEGRATION_ID='
    if ($isManaged) {
        if ($content -notmatch "HERDR_INTEGRATION_ID=$Agent" -or
            $content -notmatch 'HERDR_INTEGRATION_VERSION=7') {
            Add-Failure "Installed $Agent hook is not marked as the reviewed Herdr v7 integration: $HookPath"
        }
        if ($content -notmatch 'report_agent_session|report-agent-session' -or
            $content -notmatch 'session_id|agent_session_id' -or
            $content -notmatch 'transcript_path') {
            Add-Failure "Installed $Agent hook does not preserve native session/transcript provenance: $HookPath"
        }
    }
    elseif ($Agent -eq "claude") {
        if ($content -notmatch 'spawnSync\(' -or $content -notmatch 'report-agent-session') {
            Add-Failure "Claude refresh wrapper does not use the bounded direct reporter: $HookPath"
        }
        if ($content -match 'detached\s*:\s*true') {
            Add-Failure "Claude refresh wrapper still uses the lossy detached reporter path: $HookPath"
        }
    }
    elseif ($content -notmatch 'transcript_path') {
        Add-Failure "Codex refresh hook does not forward the transcript path required by integration v7: $HookPath"
    }
}

if (-not $SkipLiveChecks) {
if ($env:HERDR_ENV -ne "1") {
    Add-Failure "HERDR_ENV is not 1; compatibility must be checked from a Herdr-managed pane."
}

$currentVersionText = (& herdr --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) {
    Add-Failure "herdr --version failed: $currentVersionText"
}

$currentVersion = $currentVersionText -replace "^herdr\s+", ""
$reviewedRuntimeVersions = @(
    $reviewedVersion,
    "$reviewedVersion-preview.2026-08-04-d78e3d3b5126"
)
if ($reviewedRuntimeVersions -notcontains $currentVersion) {
    Add-Failure "Herdr version $currentVersion has not been reviewed; expected one of $($reviewedRuntimeVersions -join ', ')."
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
}

try {
    $homePath = Resolve-HomeDirectory -ExplicitPath $HomePath
}
catch {
    Write-Output "HERDR SKILL COMPATIBILITY: BLOCK"
    Write-Output "- $($_.Exception.Message)"
    exit 2
}

$agentsRoot = Join-Path -Path $homePath -ChildPath ".agents"
$agentsSkillsRoot = Join-Path -Path $agentsRoot -ChildPath "skills"
$claudeRoot = Join-Path -Path $homePath -ChildPath ".claude"
$claudeSkillsRoot = Join-Path -Path $claudeRoot -ChildPath "skills"
$skillPaths = @(
    (Join-Path -Path (Join-Path -Path $agentsSkillsRoot -ChildPath "herdr") -ChildPath "SKILL.md"),
    (Join-Path -Path (Join-Path -Path $claudeSkillsRoot -ChildPath "herdr") -ChildPath "SKILL.md"),
    (Join-Path -Path (Join-Path -Path $agentsSkillsRoot -ChildPath "herdr-coordination") -ChildPath "SKILL.md")
)
$reviewMarker = "Compatibility reviewed for Herdr " + [char]96 + $reviewedSkillVersion + [char]96
$controlSkillSources = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $skillPaths.Count; $index++) {
    $skillPath = $skillPaths[$index]
    if (Test-Path -LiteralPath $skillPath -PathType Leaf) {
        $content = Get-Content -Raw -LiteralPath $skillPath
        if ($index -eq 2 -and $content -notmatch [regex]::Escape($reviewMarker)) {
            Add-Failure "Skill is not pinned to the reviewed Herdr version: $skillPath"
        }
        if ($index -lt 2) {
            $controlSkillSources.Add([pscustomobject]@{
                    Path = $skillPath
                    Content = $content
                    Bundled = $false
                })
        }
        continue
    }

    if ($index -lt 2 -and -not [string]::IsNullOrWhiteSpace($builtinSkill)) {
        $controlSkillSources.Add([pscustomobject]@{
                Path = "herdr --skill (bundled runtime)"
                Content = $builtinSkill
                Bundled = $true
            })
        continue
    }

    Add-Failure "Missing Herdr-related skill: $skillPath"
}

foreach ($source in $controlSkillSources) {
    $skillPath = [string]$source.Path
    $content = [string]$source.Content
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
    if (-not [bool]$source.Bundled) {
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
}

$coordinationSkillContent = ""
if (Test-Path -LiteralPath $skillPaths[2] -PathType Leaf) {
    $coordinationSkillContent = Get-Content -Raw -LiteralPath $skillPaths[2]
}
if ($coordinationSkillContent -notmatch 'Omitting `--wait` still returns only the unproven `agent_prompted` transport receipt' -or
    $coordinationSkillContent -notmatch 'proof-bound Enter recovery') {
    Add-Failure "Coordination skill is missing no-wait false-success containment."
}
if ($coordinationSkillContent -notmatch "native host-shell tool" -or
    $coordinationSkillContent -notmatch "subprocesses may strip pane-scoped" -or
    $coordinationSkillContent -notmatch "host-access preflight" -or
    $coordinationSkillContent -notmatch "PermissionDenied" -or
    $coordinationSkillContent -notmatch "do not issue or retry registration from the same sandbox") {
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
$coordinationSkillRoot = Split-Path -Parent $skillPaths[2]
$coordinationScriptsRoot = Join-Path -Path $coordinationSkillRoot -ChildPath "scripts"
$coordinationHelperContent = Get-Content -Raw -LiteralPath (Join-Path -Path $coordinationScriptsRoot -ChildPath "herdr_coordination.ps1")
$workflowHelperContent = Get-Content -Raw -LiteralPath (Join-Path -Path $coordinationScriptsRoot -ChildPath "herdr_workflow.ps1")
$registryHelperPath = Join-Path -Path $coordinationScriptsRoot -ChildPath "herdr_pane_registry.ps1"
$registryModulePath = Join-Path -Path $coordinationScriptsRoot -ChildPath "HerdrPaneRegistry.psm1"
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

$codexRoot = Join-Path -Path $homePath -ChildPath ".codex"
$contextModeRoot = Join-Path -Path (Join-Path -Path $codexRoot -ChildPath "plugins") -ChildPath "cache"
$contextModeRoot = Join-Path -Path $contextModeRoot -ChildPath "context-mode"
$contextModeVersions = Join-Path -Path $contextModeRoot -ChildPath "context-mode"
$contextModeSkill = Get-ChildItem -LiteralPath $contextModeVersions -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    ForEach-Object {
        $versionSkills = Join-Path -Path $_.FullName -ChildPath "skills"
        $versionContextMode = Join-Path -Path $versionSkills -ChildPath "context-mode"
        Join-Path -Path $versionContextMode -ChildPath "SKILL.md"
    } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $contextModeSkill) {
    Add-Failure "Installed context-mode skill was not found for Herdr compatibility review."
}
else {
    $contextModeContent = Get-Content -Raw -LiteralPath $contextModeSkill
    if ($contextModeContent -match '(?i)\bherdr\b' -and
        ($contextModeContent -notmatch "native host-shell tool" -or
         $contextModeContent -notmatch "initial inside/outside-Herdr safety decision")) {
        Add-Failure "Context-mode skill does not preserve native Herdr environment authority: $contextModeSkill"
    }
}

$integrationStatus = $null
if (-not $SkipLiveChecks) {
    $integrationStatus = (& herdr integration status 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        Add-Failure "herdr integration status failed."
    }
    foreach ($agentKind in @("claude", "codex")) {
        if ($integrationStatus -notmatch "(?m)^$agentKind`: current \(v7\)") {
            Add-Failure "$agentKind integration is not current at the reviewed v7 schema."
        }
    }
}

$claudeHookCandidates = @(Get-InstalledHerdrHookPaths -Agent "claude" -HomeDirectory $homePath)
if ($claudeHookCandidates.Count -eq 0) {
    Add-Blocker "Unable to resolve the installed Claude Herdr hook from the platform integration configuration or managed hook directory under $claudeRoot."
}
else {
    $claudeWrapper = Select-HerdrHookPath -Candidates $claudeHookCandidates -Agent "claude"
    Test-ManagedHookContract -HookPath $claudeWrapper -Agent "claude"
}

$codexHookCandidates = @(Get-InstalledHerdrHookPaths -Agent "codex" -HomeDirectory $homePath)
if ($codexHookCandidates.Count -eq 0) {
    Add-Blocker "Unable to resolve the installed Codex Herdr hook from the platform integration configuration or managed hook directory under $codexRoot."
}
else {
    $codexRefresh = Select-HerdrHookPath -Candidates $codexHookCandidates -Agent "codex"
    Test-ManagedHookContract -HookPath $codexRefresh -Agent "codex"
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

$coordinationScript = Join-Path -Path $coordinationScriptsRoot -ChildPath "herdr_coordination.ps1"
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

if ($blockers.Count -gt 0) {
    Write-Output "HERDR SKILL COMPATIBILITY: BLOCK"
    foreach ($blocker in $blockers) {
        Write-Output "- $blocker"
    }
    exit 2
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

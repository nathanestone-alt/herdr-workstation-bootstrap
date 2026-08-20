[CmdletBinding()]
param(
    [string]$HomePath,
    [string]$HookPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$isWindowsPlatform = [IO.Path]::DirectorySeparatorChar -eq [char]92

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Resolve-HomeDirectory {
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        try { $fullPath = [IO.Path]::GetFullPath($ExplicitPath) }
        catch { throw "BLOCK: explicit home path is invalid: $ExplicitPath" }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
            throw "BLOCK: explicit home path is not a directory: $fullPath"
        }
        return $fullPath
    }

    foreach ($candidate in @($env:HOME, $env:USERPROFILE, [Environment]::GetFolderPath("UserProfile"))) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try { $fullCandidate = [IO.Path]::GetFullPath([string]$candidate) }
        catch { continue }
        if (Test-Path -LiteralPath $fullCandidate -PathType Container) {
            return $fullCandidate
        }
    }

    throw "BLOCK: unable to resolve a usable user home directory. Set HOME or USERPROFILE, or pass -HomePath explicitly."
}

function Get-JsonStringValues {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return }
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

    $path = $Candidate.Trim().Replace('$HOME', $HomeDirectory).Replace('%USERPROFILE%', $HomeDirectory)
    if ($isWindowsPlatform) { $path = $path.Replace('/', '\') }
    try {
        if ([IO.Path]::IsPathRooted($path)) { return [IO.Path]::GetFullPath($path) }
        return [IO.Path]::GetFullPath((Join-Path -Path (Split-Path -Parent $ConfigurationPath) -ChildPath $path))
    }
    catch { return $null }
}

function Get-ConfiguredHerdrHookPaths {
    param([Parameter(Mandatory)][string]$HomeDirectory)

    $claudeRoot = Join-Path -Path $HomeDirectory -ChildPath ".claude"
    $configPaths = @(
        (Join-Path -Path $claudeRoot -ChildPath "settings.json"),
        (Join-Path -Path $claudeRoot -ChildPath "settings.local.json")
    )
    $pathPattern = '(?i)(?:"(?<double>[^"]*herdr[^"\r\n]+\.(?:sh|ps1|mjs|cmd|bat))"|''(?<single>[^''\r\n]*herdr[^''\r\n]+\.(?:sh|ps1|mjs|cmd|bat))''|(?<bare>[^\s"'']+herdr[^\s"'']+\.(?:sh|ps1|mjs|cmd|bat)))'

    foreach ($configurationPath in $configPaths) {
        if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { continue }
        try { $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json }
        catch { throw "BLOCK: unable to parse Claude hook configuration: $configurationPath ($($_.Exception.Message))" }

        foreach ($value in @(Get-JsonStringValues -Value $configuration)) {
            foreach ($match in [regex]::Matches([string]$value, $pathPattern)) {
                $rawPath = $null
                foreach ($groupName in @("double", "single", "bare")) {
                    if ($match.Groups[$groupName].Success) {
                        $rawPath = $match.Groups[$groupName].Value
                        break
                    }
                }
                if ([string]::IsNullOrWhiteSpace($rawPath)) { continue }
                $resolvedPath = Convert-HookPath -Candidate $rawPath -HomeDirectory $HomeDirectory -ConfigurationPath $configurationPath
                if ($resolvedPath -and (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                    Write-Output $resolvedPath
                }
            }
        }
    }
}

function Get-InstalledHerdrHookPaths {
    param([Parameter(Mandatory)][string]$HomeDirectory)

    $claudeRoot = Join-Path -Path $HomeDirectory -ChildPath ".claude"
    $roots = @(
        (Join-Path -Path $claudeRoot -ChildPath "hooks"),
        $claudeRoot
    )
    $allCandidates = @(
        Get-ConfiguredHerdrHookPaths -HomeDirectory $HomeDirectory
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $allCandidates += @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)herdr-agent-(?:state|session)' } |
            Select-Object -ExpandProperty FullName)
    }

    $seen = @{}
    foreach ($candidate in $allCandidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate) -or
            -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $fullCandidate = [IO.Path]::GetFullPath([string]$candidate)
        $key = if ($isWindowsPlatform) { $fullCandidate.ToLowerInvariant() } else { $fullCandidate }
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            Write-Output $fullCandidate
        }
    }
}

function Resolve-HerdrHook {
    param(
        [string]$ExplicitPath,
        [Parameter(Mandatory)][string]$HomeDirectory
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        try { $fullPath = [IO.Path]::GetFullPath($ExplicitPath) }
        catch { throw "BLOCK: explicit Claude hook path is invalid: $ExplicitPath" }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "BLOCK: explicit Claude hook path does not exist: $fullPath"
        }
        return $fullPath
    }

    $candidates = @(Get-InstalledHerdrHookPaths -HomeDirectory $HomeDirectory)
    if ($candidates.Count -eq 0) {
        throw "BLOCK: unable to resolve the installed Claude Herdr hook from .claude/settings.json or the managed .claude/hooks directory under $HomeDirectory."
    }

    foreach ($pattern in @('(?i)herdr-agent-state-async', '(?i)herdr-agent-state')) {
        $match = @($candidates | Where-Object { (Split-Path -Leaf $_) -match $pattern })
        if ($match.Count -gt 0) { return $match[0] }
    }
    return $candidates[0]
}

function Get-ExecutablePath {
    param([Parameter(Mandatory)][string[]]$Names)

    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandType -in @("Application", "ExternalScript") } |
            Select-Object -First 1
        if ($command) {
            if ($command.Path) { return $command.Path }
            if ($command.Source) { return $command.Source }
        }
    }
    return $null
}

function Write-FixtureText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function New-PosixPythonBridge {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$LogPath
    )

    $realPython = Get-ExecutablePath -Names @("python3", "python")
    if (-not $realPython) { throw "BLOCK: installed POSIX Herdr hook requires python3, but no Python runner is available." }

    $socketModule = Join-Path -Path $Root -ChildPath "herdr_fixture_socket.py"
    Write-FixtureText -Path $socketModule -Content @'
import os

AF_UNIX = 1
SOCK_STREAM = 1

class socket:
    def __init__(self, *_args):
        pass

    def settimeout(self, _timeout):
        pass

    def connect(self, _path):
        pass

    def sendall(self, data):
        with open(os.environ["HERDR_REFRESH_TEST_LOG"], "a", encoding="utf-8") as handle:
            handle.write(data.decode("utf-8").strip())
            handle.write("\n")

    def recv(self, _size):
        return b"{}"

    def close(self):
        pass
'@

    $pythonRunner = Join-Path -Path $Root -ChildPath "herdr_python_runner.py"
    Write-FixtureText -Path $pythonRunner -Content @'
import sys

source = sys.stdin.read().replace("import socket", "import herdr_fixture_socket as socket", 1)
namespace = {"__name__": "__main__", "__file__": "<installed-herdr-hook>"}
exec(compile(source, "<installed-herdr-hook>", "exec"), namespace, namespace)
'@

    $pythonShim = Join-Path -Path $Root -ChildPath "python3"
    Write-FixtureText -Path $pythonShim -Content @'
#!/bin/sh
exec "$HERDR_FIXTURE_REAL_PYTHON" "$HERDR_FIXTURE_RUNNER"
'@
    $chmod = Get-ExecutablePath -Names @("chmod")
    if (-not $chmod) { throw "BLOCK: POSIX hook fixture requires chmod to make its temporary Python runner executable." }
    & $chmod +x $pythonShim
    if ($LASTEXITCODE -ne 0) { throw "BLOCK: unable to make the temporary Python runner executable: $pythonShim" }
    return @{
        RealPython = $realPython
        Runner = $pythonRunner
        SocketModule = $socketModule
        LogPath = $LogPath
    }
}

function Invoke-NodeHook {
    param(
        [Parameter(Mandatory)][string]$NodeRunner,
        [Parameter(Mandatory)][string]$Hook,
        [Parameter(Mandatory)][hashtable]$Payload
    )
    $json = $Payload | ConvertTo-Json -Compress
    $json | & $NodeRunner $Hook
    if ($LASTEXITCODE -ne 0) { throw "Claude refresh hook process failed with exit code ${LASTEXITCODE}: $Hook" }
}

function Invoke-PosixHook {
    param(
        [Parameter(Mandatory)][string]$Runner,
        [Parameter(Mandatory)][string]$Hook,
        [Parameter(Mandatory)][hashtable]$Payload
    )
    $Payload | ConvertTo-Json -Compress |
        & $Runner $Hook session
    if ($LASTEXITCODE -ne 0) { throw "Claude managed hook process failed with exit code ${LASTEXITCODE}: $Hook" }
}

function Assert-ArgumentPair {
    param(
        [Parameter(Mandatory)][object[]]$Arguments,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Message
    )
    $index = [Array]::IndexOf($Arguments, $Name)
    Assert-True -Condition ($index -ge 0 -and $index + 1 -lt $Arguments.Count -and [string]$Arguments[$index + 1] -eq $Value) -Message $Message
}

try {
    $homePath = Resolve-HomeDirectory -ExplicitPath $HomePath
    $wrapperPath = Resolve-HerdrHook -ExplicitPath $HookPath -HomeDirectory $homePath
}
catch {
    Write-Output $_.Exception.Message
    exit 2
}

$tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "herdr-claude-refresh-test-$([Guid]::NewGuid().ToString('N'))"
$reporterPath = Join-Path -Path $tempRoot -ChildPath "reporter.mjs"
$callLogPath = Join-Path -Path $tempRoot -ChildPath "calls.jsonl"
$failureDir = Join-Path -Path $tempRoot -ChildPath "failures"
New-Item -ItemType Directory -Path $tempRoot | Out-Null
New-Item -ItemType File -Path $callLogPath | Out-Null

try {
    $extension = [IO.Path]::GetExtension($wrapperPath).ToLowerInvariant()
    if ($extension -eq ".mjs" -or $extension -eq ".js") {
        $nodeRunner = Get-ExecutablePath -Names @("node")
        if (-not $nodeRunner) { throw "BLOCK: Claude Node hook requires node, but no supported runner is available." }
        $reporterContent = @'
import { appendFileSync } from "node:fs";
const record = { args: process.argv.slice(2), pane: process.env.HERDR_PANE_ID };
appendFileSync(process.env.HERDR_SESSION_REPORT_TEST_LOG, JSON.stringify(record) + "\n", "utf8");
process.exit(Number(process.env.HERDR_SESSION_REPORT_TEST_EXIT || "0"));
'@
        Write-FixtureText -Path $reporterPath -Content $reporterContent

        $saved = @{}
        foreach ($name in @(
                "HERDR_ENV", "HERDR_PANE_ID", "HERDR_SESSION_REPORTER_EXE",
                "HERDR_SESSION_REPORTER_PREFIX_JSON", "HERDR_SESSION_REPORT_TEST_LOG",
                "HERDR_SESSION_REPORT_TEST_EXIT", "HERDR_SESSION_REPORT_FAILURE_DIR"
            )) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }

        try {
            $env:HERDR_ENV = "1"
            $env:HERDR_PANE_ID = "w9:p9"
            $env:HERDR_SESSION_REPORTER_EXE = $nodeRunner
            $env:HERDR_SESSION_REPORTER_PREFIX_JSON = ConvertTo-Json -InputObject @($reporterPath) -Compress
            $env:HERDR_SESSION_REPORT_TEST_LOG = $callLogPath
            $env:HERDR_SESSION_REPORT_TEST_EXIT = "0"
            $env:HERDR_SESSION_REPORT_FAILURE_DIR = $failureDir

            $transcriptStart = Join-Path -Path $tempRoot -ChildPath "claude-session.jsonl"
            $transcriptRefresh = Join-Path -Path $tempRoot -ChildPath "claude-refresh.jsonl"
            Write-Output "CASE: top-level SessionStart reports exact native provenance"
            Invoke-NodeHook -NodeRunner $nodeRunner -Hook $wrapperPath -Payload @{
                hook_event_name = "SessionStart"
                session_id = "11111111-2222-3333-4444-555555555555"
                transcript_path = $transcriptStart
                source = "startup"
            }
            $calls = @(Get-Content -LiteralPath $callLogPath | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-True -Condition ($calls.Count -eq 1) -Message "SessionStart did not invoke exactly one reporter."
            $args = @($calls[0].args)
            Assert-True -Condition ([string]$args[0] -eq "pane" -and [string]$args[1] -eq "report-agent-session" -and [string]$args[2] -eq "w9:p9") -Message "Reporter targeted the wrong pane."
            Assert-ArgumentPair -Arguments $args -Name "--agent" -Value "claude" -Message "Reporter lost the Claude agent kind."
            Assert-ArgumentPair -Arguments $args -Name "--agent-session-id" -Value "11111111-2222-3333-4444-555555555555" -Message "Reporter lost the native session ID."
            Assert-ArgumentPair -Arguments $args -Name "--agent-session-path" -Value $transcriptStart -Message "Reporter lost the transcript path."
            Assert-ArgumentPair -Arguments $args -Name "--session-start-source" -Value "startup" -Message "Reporter lost the startup source."

            Write-Output "CASE: UserPromptSubmit refreshes provenance"
            Invoke-NodeHook -NodeRunner $nodeRunner -Hook $wrapperPath -Payload @{
                hook_event_name = "UserPromptSubmit"
                session_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                transcript_path = $transcriptRefresh
            }
            $calls = @(Get-Content -LiteralPath $callLogPath | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-True -Condition ($calls.Count -eq 2) -Message "UserPromptSubmit did not invoke the reporter."
            $refreshArgs = @($calls[1].args)
            Assert-ArgumentPair -Arguments $refreshArgs -Name "--agent-session-id" -Value "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" -Message "Refresh lost the native session ID."
            Assert-ArgumentPair -Arguments $refreshArgs -Name "--agent-session-path" -Value $transcriptRefresh -Message "Refresh lost the transcript path."
            Assert-True -Condition (-not ([bool]($refreshArgs -contains "--session-start-source"))) -Message "Refresh fabricated a SessionStart source."

            Write-Output "CASE: nested agent and unmanaged environment are ignored"
            Invoke-NodeHook -NodeRunner $nodeRunner -Hook $wrapperPath -Payload @{
                hook_event_name = "UserPromptSubmit"
                session_id = "99999999-8888-7777-6666-555555555555"
                agent_id = "nested-agent"
            }
            $env:HERDR_ENV = "0"
            Invoke-NodeHook -NodeRunner $nodeRunner -Hook $wrapperPath -Payload @{
                hook_event_name = "UserPromptSubmit"
                session_id = "99999999-8888-7777-6666-555555555555"
            }
            $env:HERDR_ENV = "1"
            $calls = @(Get-Content -LiteralPath $callLogPath | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-True -Condition ($calls.Count -eq 2) -Message "An untrusted nested or unmanaged event reached the reporter."

            Write-Output "CASE: reporter failure preserves native payload evidence"
            $env:HERDR_SESSION_REPORT_TEST_EXIT = "7"
            Invoke-NodeHook -NodeRunner $nodeRunner -Hook $wrapperPath -Payload @{
                hook_event_name = "Stop"
                session_id = "12345678-1234-1234-1234-123456789abc"
            }
            $failurePayloads = @(Get-ChildItem -LiteralPath $failureDir -Filter "payload-*.json")
            Assert-True -Condition ($failurePayloads.Count -eq 1) -Message "Reporter failure did not preserve one native payload."
            $failure = Get-Content -LiteralPath $failurePayloads[0].FullName -Raw | ConvertFrom-Json
            Assert-True -Condition ([string]$failure.session_id -eq "12345678-1234-1234-1234-123456789abc") -Message "Failure evidence lost the native session ID."
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path -Path $failureDir -ChildPath "failures.log")) -Message "Reporter failure did not create a diagnostic log."
            Write-Output "PASS: Claude native-session refresh hook ($wrapperPath)"
        }
        finally {
            foreach ($name in $saved.Keys) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }
    }
    elseif ($extension -eq ".sh") {
        if ($isWindowsPlatform) { throw "BLOCK: a POSIX Claude hook was installed on Windows, but no POSIX runner contract is available." }
        $posixRunner = Get-ExecutablePath -Names @("bash", "sh")
        if (-not $posixRunner) { throw "BLOCK: Claude POSIX hook requires bash or sh, but no supported runner is available." }
        $bridge = New-PosixPythonBridge -Root $tempRoot -LogPath $callLogPath
        $hookContent = Get-Content -Raw -LiteralPath $wrapperPath
        Assert-True -Condition ($hookContent -match 'HERDR_INTEGRATION_ID=claude' -and $hookContent -match 'HERDR_INTEGRATION_VERSION=7') -Message "Claude POSIX hook is not the managed Herdr v7 integration: $wrapperPath"
        Assert-True -Condition ($hookContent -match 'transcript_path' -and $hookContent -match 'agent_session_id') -Message "Claude POSIX hook does not preserve native transcript/session provenance: $wrapperPath"

        $saved = @{}
        foreach ($name in @("PATH", "HERDR_ENV", "HERDR_SOCKET_PATH", "HERDR_PANE_ID", "HERDR_REFRESH_TEST_LOG", "HERDR_FIXTURE_REAL_PYTHON", "HERDR_FIXTURE_RUNNER")) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        try {
            $pathSeparator = [IO.Path]::PathSeparator
            $env:PATH = "$tempRoot$pathSeparator$($saved["PATH"] )"
            $env:HERDR_ENV = "1"
            $env:HERDR_SOCKET_PATH = Join-Path -Path $tempRoot -ChildPath "fixture.sock"
            $env:HERDR_PANE_ID = "w9:p9"
            $env:HERDR_REFRESH_TEST_LOG = $callLogPath
            $env:HERDR_FIXTURE_REAL_PYTHON = $bridge.RealPython
            $env:HERDR_FIXTURE_RUNNER = $bridge.Runner

            $transcriptStart = Join-Path -Path $tempRoot -ChildPath "claude-session.jsonl"
            $transcriptRefresh = Join-Path -Path $tempRoot -ChildPath "claude-refresh.jsonl"
            Invoke-PosixHook -Runner $posixRunner -Hook $wrapperPath -Payload @{
                hook_event_name = "SessionStart"
                session_id = "11111111-2222-3333-4444-555555555555"
                transcript_path = $transcriptStart
                source = "startup"
            }
            Invoke-PosixHook -Runner $posixRunner -Hook $wrapperPath -Payload @{
                hook_event_name = "UserPromptSubmit"
                session_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                transcript_path = $transcriptRefresh
            }
            Invoke-PosixHook -Runner $posixRunner -Hook $wrapperPath -Payload @{
                hook_event_name = "UserPromptSubmit"
                session_id = "99999999-8888-7777-6666-555555555555"
                agent_id = "nested-agent"
            }
            $env:HERDR_ENV = "0"
            Invoke-PosixHook -Runner $posixRunner -Hook $wrapperPath -Payload @{
                hook_event_name = "UserPromptSubmit"
                session_id = "99999999-8888-7777-6666-555555555555"
            }
            $env:HERDR_ENV = "1"

            $requests = @(Get-Content -LiteralPath $callLogPath | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-True -Condition ($requests.Count -eq 2) -Message "Expected exactly two managed Claude session reports; requests: $($requests | ConvertTo-Json -Compress)"
            Assert-True -Condition ([string]$requests[0].method -eq "pane.report_agent_session" -and [string]$requests[1].method -eq "pane.report_agent_session") -Message "Managed Claude hook used the wrong Herdr method."
            Assert-True -Condition ([string]$requests[0].params.agent -eq "claude" -and [string]$requests[1].params.agent -eq "claude") -Message "Managed Claude hook lost the native agent kind."
            Assert-True -Condition ([string]$requests[0].params.agent_session_id -eq "11111111-2222-3333-4444-555555555555") -Message "Claude SessionStart lost the native session ID."
            Assert-True -Condition ([string]$requests[0].params.agent_session_path -eq $transcriptStart) -Message "Claude SessionStart lost the transcript path."
            Assert-True -Condition ([string]$requests[0].params.session_start_source -eq "startup") -Message "Claude SessionStart lost the startup source."
            Assert-True -Condition ([string]$requests[1].params.agent_session_id -eq "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee") -Message "Claude refresh lost the native session ID."
            Assert-True -Condition ([string]$requests[1].params.agent_session_path -eq $transcriptRefresh) -Message "Claude refresh lost the transcript path."
            Assert-True -Condition (-not ($requests[1].params.PSObject.Properties.Name -contains "session_start_source")) -Message "Claude refresh fabricated a SessionStart source."
            Write-Output "PASS: Claude managed native-session hook ($wrapperPath)"
        }
        finally {
            foreach ($name in $saved.Keys) {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }
    }
    else {
        throw "BLOCK: unsupported installed Claude hook type '$extension': $wrapperPath"
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

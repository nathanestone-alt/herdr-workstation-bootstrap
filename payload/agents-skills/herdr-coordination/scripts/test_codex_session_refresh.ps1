[CmdletBinding()]
param(
    [string]$HomePath,
    [string]$HookPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$isWindowsPlatform = [IO.Path]::DirectorySeparatorChar -eq [char]92

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
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

    $codexRoot = Join-Path -Path $HomeDirectory -ChildPath ".codex"
    $configPaths = @(
        (Join-Path -Path $codexRoot -ChildPath "hooks.json"),
        (Join-Path -Path $codexRoot -ChildPath "config.json")
    )
    $pathPattern = '(?i)(?:"(?<double>[^"]*herdr[^"\r\n]+\.(?:sh|ps1|mjs|cmd|bat))"|''(?<single>[^''\r\n]*herdr[^''\r\n]+\.(?:sh|ps1|mjs|cmd|bat))''|(?<bare>[^\s"'']+herdr[^\s"'']+\.(?:sh|ps1|mjs|cmd|bat)))'

    foreach ($configurationPath in $configPaths) {
        if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) { continue }
        try { $configuration = Get-Content -Raw -LiteralPath $configurationPath | ConvertFrom-Json }
        catch { throw "BLOCK: unable to parse Codex hook configuration: $configurationPath ($($_.Exception.Message))" }

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

    $codexRoot = Join-Path -Path $HomeDirectory -ChildPath ".codex"
    $roots = @(
        (Join-Path -Path $codexRoot -ChildPath "hooks"),
        $codexRoot
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
        catch { throw "BLOCK: explicit Codex hook path is invalid: $ExplicitPath" }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "BLOCK: explicit Codex hook path does not exist: $fullPath"
        }
        return $fullPath
    }

    $candidates = @(Get-InstalledHerdrHookPaths -HomeDirectory $HomeDirectory)
    if ($candidates.Count -eq 0) {
        throw "BLOCK: unable to resolve the installed Codex Herdr hook from .codex/hooks.json or the managed .codex hook directory under $HomeDirectory."
    }

    foreach ($pattern in @('(?i)herdr-agent-session-refresh', '(?i)herdr-agent-state')) {
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

function New-FakeHerdrCommand {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$LogPath
    )

    if ($isWindowsPlatform) {
        $fakeHerdr = Join-Path -Path $Root -ChildPath "herdr.cmd"
        Write-FixtureText -Path $fakeHerdr -Content @'
@echo off
echo %*>>"%HERDR_REFRESH_TEST_LOG%"
if /I "%~1"=="pane" if /I "%~2"=="get" (
  echo {"id":"test:pane:get","result":{"type":"pane_info","pane":{"pane_id":"w1:pG","agent":"codex","agent_status":"idle"}}}
  exit /b 0
)
if /I "%~1"=="pane" if /I "%~2"=="process-info" (
  echo {"id":"test:pane:process-info","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:pG","shell_pid":0,"foreground_processes":[]}}}
  exit /b 0
)
if /I "%~1"=="pane" if /I "%~2"=="report-agent-session" (
  echo {"id":"test:pane:report-agent-session","result":{"type":"agent_session_reported"}}
  exit /b 0
)
echo unexpected fake herdr invocation: %* 1>&2
exit /b 2
'@
        return $fakeHerdr
    }

    $fakeHerdr = Join-Path -Path $Root -ChildPath "herdr"
    Write-FixtureText -Path $fakeHerdr -Content @'
#!/bin/sh
printf '%s\n' "$*" >> "$HERDR_REFRESH_TEST_LOG"
if [ "$1" = "pane" ] && [ "$2" = "get" ]; then
  printf '%s\n' '{"id":"test:pane:get","result":{"type":"pane_info","pane":{"pane_id":"w1:pG","agent":"codex","agent_status":"idle"}}}'
  exit 0
fi
if [ "$1" = "pane" ] && [ "$2" = "process-info" ]; then
  printf '%s\n' '{"id":"test:pane:process-info","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:pG","shell_pid":0,"foreground_processes":[]}}}'
  exit 0
fi
if [ "$1" = "pane" ] && [ "$2" = "report-agent-session" ]; then
  printf '%s\n' '{"id":"test:pane:report-agent-session","result":{"type":"agent_session_reported"}}'
  exit 0
fi
printf '%s\n' "unexpected fake herdr invocation: $*" >&2
exit 2
'@
    $chmod = Get-ExecutablePath -Names @("chmod")
    if (-not $chmod) { throw "BLOCK: POSIX hook fixture requires chmod to make its temporary executable runnable." }
    & $chmod +x $fakeHerdr
    if ($LASTEXITCODE -ne 0) { throw "BLOCK: unable to make the temporary Herdr fixture executable: $fakeHerdr" }
    return $fakeHerdr
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
        Shim = $pythonShim
        Runner = $pythonRunner
        SocketModule = $socketModule
        LogPath = $LogPath
    }
}

function Invoke-PowerShellHook {
    param(
        [Parameter(Mandatory)][string]$Runner,
        [Parameter(Mandatory)][string]$Hook,
        [Parameter(Mandatory)][hashtable]$Payload
    )
    $Payload | ConvertTo-Json -Compress |
        & $Runner -NoProfile -ExecutionPolicy Bypass -File $Hook
    if ($LASTEXITCODE -ne 0) { throw "Codex refresh hook process failed with exit code ${LASTEXITCODE}: $Hook" }
}

function Invoke-PosixHook {
    param(
        [Parameter(Mandatory)][string]$Runner,
        [Parameter(Mandatory)][string]$Hook,
        [Parameter(Mandatory)][hashtable]$Payload
    )
    $Payload | ConvertTo-Json -Compress |
        & $Runner $Hook session
    if ($LASTEXITCODE -ne 0) { throw "Codex managed hook process failed with exit code ${LASTEXITCODE}: $Hook" }
}

try {
    $homePath = Resolve-HomeDirectory -ExplicitPath $HomePath
    $refreshHook = Resolve-HerdrHook -ExplicitPath $HookPath -HomeDirectory $homePath
}
catch {
    Write-Output $_.Exception.Message
    exit 2
}

$tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "herdr-codex-refresh-test-$([Guid]::NewGuid().ToString('N'))"
$callLog = Join-Path -Path $tempRoot -ChildPath "calls.log"
New-Item -ItemType Directory -Path $tempRoot | Out-Null
New-Item -ItemType File -Path $callLog | Out-Null

try {
    $extension = [IO.Path]::GetExtension($refreshHook).ToLowerInvariant()
    if ($extension -eq ".ps1") {
        $powershellRunner = Get-ExecutablePath -Names @("pwsh", "powershell")
        if (-not $powershellRunner) { throw "BLOCK: Codex PowerShell hook requires pwsh or powershell, but no supported runner is available." }
        $null = New-FakeHerdrCommand -Root $tempRoot -LogPath $callLog

        $originalEnvironment = @{}
        foreach ($name in @("PATH", "HERDR_ENV", "HERDR_PANE_ID", "HERDR_REFRESH_TEST_LOG", "CODEX_THREAD_ID")) {
            $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        try {
            $pathSeparator = [IO.Path]::PathSeparator
            $env:PATH = "$tempRoot$pathSeparator$($originalEnvironment["PATH"] )"
            $env:HERDR_ENV = "1"
            $env:HERDR_PANE_ID = "w1:pG"
            $env:HERDR_REFRESH_TEST_LOG = $callLog
            $env:CODEX_THREAD_ID = ""

            $transcriptPrompt = Join-Path -Path $tempRoot -ChildPath "session-prompt.jsonl"
            $transcriptStop = Join-Path -Path $tempRoot -ChildPath "session-stop.jsonl"
            Invoke-PowerShellHook -Runner $powershellRunner -Hook $refreshHook -Payload @{
                hook_event_name = "UserPromptSubmit"
                session_id = "session-prompt"
                transcript_path = $transcriptPrompt
            }
            Invoke-PowerShellHook -Runner $powershellRunner -Hook $refreshHook -Payload @{
                hook_event_name = "Stop"
                session_id = "session-stop"
                transcript_path = $transcriptStop
            }
            Invoke-PowerShellHook -Runner $powershellRunner -Hook $refreshHook -Payload @{
                hook_event_name = "PreToolUse"
                session_id = "session-wrong-event"
                transcript_path = (Join-Path -Path $tempRoot -ChildPath "session-wrong-event.jsonl")
            }
            Invoke-PowerShellHook -Runner $powershellRunner -Hook $refreshHook -Payload @{
                hook_event_name = "Stop"
                session_id = "session-subagent"
                transcript_path = (Join-Path -Path $tempRoot -ChildPath "session-subagent.jsonl")
                agent_id = "subagent-1"
            }
            Invoke-PowerShellHook -Runner $powershellRunner -Hook $refreshHook -Payload @{
                hook_event_name = "Stop"
                session_id = "session-missing-transcript"
            }

            $calls = @(Get-Content -LiteralPath $callLog)
            $reports = @($calls | Where-Object { $_ -match '^pane report-agent-session ' })
            Assert-True -Condition ($reports.Count -eq 2) -Message "Expected exactly two native-session reports; calls: $($calls -join '; ')"
            Assert-True -Condition ([bool]($reports -match '--source herdr:codex --agent codex .+--agent-session-id session-prompt')) -Message "UserPromptSubmit did not refresh the exact native session."
            Assert-True -Condition ([bool]($reports -match '--source herdr:codex --agent codex .+--agent-session-id session-stop')) -Message "Stop did not refresh the exact native session."
            Assert-True -Condition (-not [bool]($calls -match 'session-wrong-event|session-subagent')) -Message "Rejected event or subagent provenance reached Herdr."
            Write-Output "PASS: Codex native-session refresh hook ($refreshHook)"
        }
        finally {
            foreach ($name in $originalEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
            }
        }
    }
    elseif ($extension -eq ".sh") {
        if ($isWindowsPlatform) { throw "BLOCK: a POSIX Codex hook was installed on Windows, but no POSIX runner contract is available." }
        $posixRunner = Get-ExecutablePath -Names @("bash", "sh")
        if (-not $posixRunner) { throw "BLOCK: Codex POSIX hook requires bash or sh, but no supported runner is available." }
        $bridge = New-PosixPythonBridge -Root $tempRoot -LogPath $callLog
        $hookContent = Get-Content -Raw -LiteralPath $refreshHook
        Assert-True -Condition ($hookContent -match 'HERDR_INTEGRATION_ID=codex' -and $hookContent -match 'HERDR_INTEGRATION_VERSION=7') -Message "Codex POSIX hook is not the managed Herdr v7 integration: $refreshHook"
        Assert-True -Condition ($hookContent -match 'transcript_path' -and $hookContent -match 'agent_session_id') -Message "Codex POSIX hook does not preserve native transcript/session provenance: $refreshHook"

        $originalEnvironment = @{}
        foreach ($name in @("PATH", "HERDR_ENV", "HERDR_SOCKET_PATH", "HERDR_PANE_ID", "HERDR_REFRESH_TEST_LOG", "CODEX_THREAD_ID", "HERDR_FIXTURE_REAL_PYTHON", "HERDR_FIXTURE_RUNNER")) {
            $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        try {
            $pathSeparator = [IO.Path]::PathSeparator
            $env:PATH = "$tempRoot$pathSeparator$($originalEnvironment["PATH"] )"
            $env:HERDR_ENV = "1"
            $env:HERDR_SOCKET_PATH = Join-Path -Path $tempRoot -ChildPath "fixture.sock"
            $env:HERDR_PANE_ID = "w1:pG"
            $env:HERDR_REFRESH_TEST_LOG = $callLog
            $env:HERDR_FIXTURE_REAL_PYTHON = $bridge.RealPython
            $env:HERDR_FIXTURE_RUNNER = $bridge.Runner
            $env:CODEX_THREAD_ID = ""

            $transcript = Join-Path -Path $tempRoot -ChildPath "session-start.jsonl"
            Invoke-PosixHook -Runner $posixRunner -Hook $refreshHook -Payload @{
                hook_event_name = "SessionStart"
                session_id = "session-start"
                transcript_path = $transcript
                source = "startup"
            }
            Invoke-PosixHook -Runner $posixRunner -Hook $refreshHook -Payload @{
                hook_event_name = "UserPromptSubmit"
                session_id = "session-wrong-event"
                transcript_path = (Join-Path -Path $tempRoot -ChildPath "wrong-event.jsonl")
            }
            Invoke-PosixHook -Runner $posixRunner -Hook $refreshHook -Payload @{
                hook_event_name = "SessionStart"
                session_id = "session-missing-transcript"
            }
            $env:CODEX_THREAD_ID = "different-native-session"
            Invoke-PosixHook -Runner $posixRunner -Hook $refreshHook -Payload @{
                hook_event_name = "SessionStart"
                session_id = "session-inherited-mismatch"
                transcript_path = (Join-Path -Path $tempRoot -ChildPath "mismatch.jsonl")
            }

            $requests = @(Get-Content -LiteralPath $callLog | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-True -Condition ($requests.Count -eq 1) -Message "Expected exactly one managed Codex session report; requests: $($requests | ConvertTo-Json -Compress)"
            Assert-True -Condition ([string]$requests[0].method -eq "pane.report_agent_session") -Message "Managed Codex hook used the wrong Herdr method."
            Assert-True -Condition ([string]$requests[0].params.agent -eq "codex") -Message "Managed Codex hook lost the native agent kind."
            Assert-True -Condition ([string]$requests[0].params.source -eq "herdr:codex") -Message "Managed Codex hook lost the native source."
            Assert-True -Condition ([string]$requests[0].params.agent_session_id -eq "session-start") -Message "Managed Codex hook lost the native session ID."
            Write-Output "PASS: Codex managed native-session hook ($refreshHook)"
        }
        finally {
            foreach ($name in $originalEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
            }
        }
    }
    else {
        throw "BLOCK: unsupported installed Codex hook type '$extension': $refreshHook"
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

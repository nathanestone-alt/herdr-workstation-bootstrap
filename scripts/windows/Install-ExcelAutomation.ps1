#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ToolRoot = 'C:\HerdrTools\excel-automation'
$Venv = Join-Path $ToolRoot '.venv'
$Requirements = Join-Path $RepoRoot 'requirements\windows-excel.txt'
$SmokeTest = Join-Path $RepoRoot 'scripts\windows\Test-ExcelCom.py'

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    throw 'uv is unavailable. Run bootstrap.ps1 -Stage WindowsBase, open a new PowerShell 7 window, and retry.'
}
New-Item -ItemType Directory -Path $ToolRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $Venv)) {
    uv venv $Venv --python 3.13
}
uv pip install --python (Join-Path $Venv 'Scripts\python.exe') --requirement $Requirements

foreach ($directory in @('C:\HerdrExchange\in', 'C:\HerdrExchange\out', 'C:\HerdrExchange\logs', 'C:\HerdrExchange\scripts')) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

& (Join-Path $Venv 'Scripts\python.exe') $SmokeTest
if ($LASTEXITCODE -ne 0) { throw "Excel COM smoke test failed with exit code $LASTEXITCODE" }
Write-Host "Excel automation environment ready: $Venv"


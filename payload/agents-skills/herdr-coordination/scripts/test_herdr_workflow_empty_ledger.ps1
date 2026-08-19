[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$workflowPath = Join-Path $PSScriptRoot "herdr_workflow.ps1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-workflow-empty-ledger-$([Guid]::NewGuid().ToString('N'))"
$watchLogPath = Join-Path $tempRoot "watch.md"
$coordinationLogPath = Join-Path $tempRoot "coordination.md"
$registryPath = Join-Path $tempRoot "pane-registry.jsonl"
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [Parameter(Mandatory)][string]$Message
    )
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', observed '$Actual'."
    }
}

function Get-PropertyNames {
    param([Parameter(Mandatory)]$Object)
    return (($Object.PSObject.Properties.Name | Sort-Object) -join ",")
}

function Invoke-WorkflowRaw {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$LedgerPath
    )

    $output = & pwsh -NoProfile -File $workflowPath `
        -Action $Action `
        -LedgerPath $LedgerPath `
        -WatchLogPath $watchLogPath `
        -CoordinationLogPath $coordinationLogPath `
        -PaneRegistryPath $registryPath 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $output -join [Environment]::NewLine
    }
}

function Invoke-WorkflowJson {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$LedgerPath
    )

    $result = Invoke-WorkflowRaw -Action $Action -LedgerPath $LedgerPath
    Assert-Equal -Actual $result.ExitCode -Expected 0 -Message "$Action failed for '$LedgerPath': $($result.Text)"
    try {
        return $result.Text | ConvertFrom-Json -Depth 20
    }
    catch {
        throw "$Action returned invalid JSON for '$LedgerPath': $($result.Text)"
    }
}

function Assert-EmptyStatus {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$LedgerPath
    )

    Assert-Equal -Actual (Get-PropertyNames -Object $Result) -Expected "action,ledger_path,workflows" -Message "Status result shape was not exact."
    Assert-Equal -Actual $Result.action -Expected "status" -Message "Status action was not reported."
    Assert-Equal -Actual $Result.ledger_path -Expected $LedgerPath -Message "Status returned the wrong ledger path."
    Assert-Equal -Actual @($Result.workflows).Count -Expected 0 -Message "Status returned non-empty workflows."
}

function Assert-EmptyScan {
    param([Parameter(Mandatory)]$Result)

    Assert-Equal -Actual (Get-PropertyNames -Object $Result) -Expected "action,new_alerts,scanned,workflows" -Message "Scan result shape was not exact."
    Assert-Equal -Actual $Result.action -Expected "scan" -Message "Scan action was not reported."
    Assert-Equal -Actual $Result.scanned -Expected 0 -Message "Scan reported a nonzero workflow count."
    Assert-Equal -Actual @($Result.new_alerts).Count -Expected 0 -Message "Scan returned non-empty alerts."
    Assert-Equal -Actual @($Result.workflows).Count -Expected 0 -Message "Scan returned non-empty workflows."
}

function Assert-LedgerExistsAsExpected {
    param(
        [Parameter(Mandatory)][string]$LedgerPath,
        [Parameter(Mandatory)][bool]$ExpectedExists,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedContent,
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$Action
    )

    Assert-Equal `
        -Actual (Test-Path -LiteralPath $LedgerPath -PathType Leaf) `
        -Expected $ExpectedExists `
        -Message "$CaseName/$Action changed ledger existence."
    if ($ExpectedExists) {
        Assert-Equal `
            -Actual ([IO.File]::ReadAllText($LedgerPath)) `
            -Expected $ExpectedContent `
            -Message "$CaseName/$Action changed ledger contents."
    }
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $emptyCases = @(
        [pscustomobject]@{
            Name = "missing"
            Content = $null
            Exists = $false
        },
        [pscustomobject]@{
            Name = "zero-byte"
            Content = ""
            Exists = $true
        },
        [pscustomobject]@{
            Name = "whitespace-only"
            Content = " `n`t`r`n"
            Exists = $true
        }
    )

    foreach ($emptyCase in $emptyCases) {
        $ledgerPath = Join-Path $tempRoot "$($emptyCase.Name)-ledger.jsonl"
        if ($emptyCase.Exists) {
            [IO.File]::WriteAllText($ledgerPath, [string]$emptyCase.Content, $utf8NoBom)
        }

        foreach ($action in @("status", "scan")) {
            Write-Output "CASE: $($emptyCase.Name) $action"
            $result = Invoke-WorkflowJson -Action $action -LedgerPath $ledgerPath
            if ($action -eq "status") {
                Assert-EmptyStatus -Result $result -LedgerPath $ledgerPath
            }
            else {
                Assert-EmptyScan -Result $result
            }
            Assert-LedgerExistsAsExpected `
                -LedgerPath $ledgerPath `
                -ExpectedExists $emptyCase.Exists `
                -ExpectedContent ([string]$emptyCase.Content) `
                -CaseName $emptyCase.Name `
                -Action $action
        }
    }

    $malformedCases = @(
        [pscustomobject]@{
            Name = "malformed-line-1"
            Content = "not-json`n"
            Line = 1
        },
        [pscustomobject]@{
            Name = "malformed-line-3"
            Content = "`n `nnot-json`n"
            Line = 3
        }
    )

    foreach ($malformedCase in $malformedCases) {
        $ledgerPath = Join-Path $tempRoot "$($malformedCase.Name)-ledger.jsonl"
        [IO.File]::WriteAllText($ledgerPath, $malformedCase.Content, $utf8NoBom)
        foreach ($action in @("status", "scan")) {
            Write-Output "CASE: $($malformedCase.Name) $action"
            $result = Invoke-WorkflowRaw -Action $action -LedgerPath $ledgerPath
            Assert-True -Condition ($result.ExitCode -ne 0) -Message "$action accepted malformed JSON on line $($malformedCase.Line)."
            Assert-True `
                -Condition ($result.Text -match [regex]::Escape("Workflow ledger contains invalid JSON on line $($malformedCase.Line).")) `
                -Message "$action did not report the malformed JSON line number for $($malformedCase.Name): $($result.Text)"
            Assert-True `
                -Condition ($result.Text -notmatch "Cannot bind argument to parameter 'Events'") `
                -Message "$action treated malformed JSON as an empty ledger for $($malformedCase.Name)."
            Assert-LedgerExistsAsExpected `
                -LedgerPath $ledgerPath `
                -ExpectedExists $true `
                -ExpectedContent $malformedCase.Content `
                -CaseName $malformedCase.Name `
                -Action $action
        }
    }

    Write-Output "PASS: empty, whitespace-only, and malformed workflow ledgers"
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

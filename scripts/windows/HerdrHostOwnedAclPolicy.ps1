function Protect-HostOwnedTree([string]$TargetPath, [Security.Principal.SecurityIdentifier]$OperatorSid) {
    New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null

    # Snapshot descendants before protecting the root. The root is converged
    # first, so anything created after the snapshot inherits the restricted ACL.
    $rootItem = Get-Item -LiteralPath $TargetPath
    $items = @($rootItem) + @(Get-ChildItem -LiteralPath $TargetPath -Force -Recurse)
    $allowedSids = @('S-1-5-18', 'S-1-5-32-544', $OperatorSid.Value)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'

    foreach ($item in $items) {
        $grantRules = if ($item.PSIsContainer) {
            @($allowedSids | ForEach-Object { "*${_}:(OI)(CI)F" })
        }
        else {
            @($allowedSids | ForEach-Object { "*${_}:F" })
        }
        $arguments = @($item.FullName, '/inheritance:r', '/grant:r') + $grantRules
        & $icacls @arguments | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to protect host-owned path '$($item.FullName)' (icacls exit $LASTEXITCODE)."
        }

        $unexpectedSids = @(Get-Acl -LiteralPath $item.FullName | Select-Object -ExpandProperty Access | ForEach-Object {
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        } | Where-Object { $_ -notin $allowedSids } | Select-Object -Unique)
        foreach ($unexpectedSid in $unexpectedSids) {
            & $icacls $item.FullName '/remove' "*$unexpectedSid" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to remove unexpected SID '$unexpectedSid' from '$($item.FullName)' (icacls exit $LASTEXITCODE)."
            }
        }
    }

    foreach ($item in $items) {
        $acl = Get-Acl -LiteralPath $item.FullName
        if (-not $acl.AreAccessRulesProtected) {
            throw "Host-owned path '$($item.FullName)' still inherits access rules."
        }
        foreach ($accessRule in @($acl.Access)) {
            try {
                $sid = $accessRule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            }
            catch {
                throw "Could not resolve ACL identity '$($accessRule.IdentityReference)' on '$($item.FullName)'."
            }
            if ($sid -notin $allowedSids -or $accessRule.AccessControlType -ne $allow -or
                ($accessRule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
                    [Security.AccessControl.FileSystemRights]::FullControl) {
                throw "Unexpected ACL entry '$($accessRule.IdentityReference):$($accessRule.FileSystemRights)' on '$($item.FullName)'."
            }
        }
    }
}

function Protect-HostOwnedReadOnlyTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier]$ReaderSid
    )

    if (-not $IsWindows) { throw 'Host-owned read-only ACLs require Windows.' }
    if (-not (Test-Path -LiteralPath $TargetPath -PathType Container)) {
        throw "Host-owned read-only path is not an existing directory: '$TargetPath'."
    }
    $rootItem = Get-Item -LiteralPath $TargetPath -Force
    $items = @($rootItem) + @(Get-ChildItem -LiteralPath $TargetPath -Force -Recurse)
    $fullControlSids = @('S-1-5-18', 'S-1-5-32-544')
    $allowedSids = @($fullControlSids) + @($ReaderSid.Value)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'

    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Host-owned read-only tree contains a reparse point: '$($item.FullName)'."
        }
        $grantRules = @($fullControlSids | ForEach-Object {
            if ($item.PSIsContainer) { "*${_}:(OI)(CI)F" } else { "*${_}:F" }
        })
        $grantRules += if ($item.PSIsContainer) {
            "*$($ReaderSid.Value):(OI)(CI)(RX)"
        }
        else {
            "*$($ReaderSid.Value):(RX)"
        }
        & $icacls $item.FullName '/inheritance:r' '/grant:r' @grantRules '/setowner' '*S-1-5-32-544' | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to protect read-only host path '$($item.FullName)' (icacls exit $LASTEXITCODE)."
        }
        $unexpectedSids = @(Get-Acl -LiteralPath $item.FullName | Select-Object -ExpandProperty Access | ForEach-Object {
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        } | Where-Object { $_ -notin $allowedSids } | Select-Object -Unique)
        foreach ($unexpectedSid in $unexpectedSids) {
            & $icacls $item.FullName '/remove' "*$unexpectedSid" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to remove unexpected SID '$unexpectedSid' from '$($item.FullName)' (icacls exit $LASTEXITCODE)."
            }
        }
    }

    Assert-HostOwnedReadOnlyTree -TargetPath $TargetPath -ReaderSid $ReaderSid
}

function Assert-HostOwnedReadOnlyTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier]$ReaderSid
    )

    if (-not $IsWindows) { throw 'Host-owned read-only ACLs require Windows.' }
    $rootItem = Get-Item -LiteralPath $TargetPath -Force
    $items = @($rootItem) + @(Get-ChildItem -LiteralPath $TargetPath -Force -Recurse)
    $fullControlSids = @('S-1-5-18', 'S-1-5-32-544')
    $allowedSids = @($fullControlSids) + @($ReaderSid.Value)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Host-owned read-only tree contains a reparse point: '$($item.FullName)'."
        }
        $acl = Get-Acl -LiteralPath $item.FullName
        if (-not $acl.AreAccessRulesProtected) {
            throw "Host-owned read-only path '$($item.FullName)' still inherits access rules."
        }
        $ownerSid = ([Security.Principal.NTAccount]::new([string]$acl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value
        if ($ownerSid -cne 'S-1-5-32-544') { throw "Host-owned read-only path '$($item.FullName)' is not owned by built-in Administrators." }
        $rightsBySid = @{}
        foreach ($accessRule in @($acl.Access)) {
            $sid = $accessRule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            if ($sid -notin $allowedSids -or $accessRule.AccessControlType -ne $allow) {
                throw "Unexpected ACL entry '$($accessRule.IdentityReference):$($accessRule.FileSystemRights)' on '$($item.FullName)'."
            }
            $rights = $accessRule.FileSystemRights
            if (-not $rightsBySid.ContainsKey($sid)) { $rightsBySid[$sid] = [Security.AccessControl.FileSystemRights]0 }
            $rightsBySid[$sid] = $rightsBySid[$sid] -bor $rights
            if ($sid -eq $ReaderSid.Value) {
                $writeMask = [Security.AccessControl.FileSystemRights]0x000D0156
                if (($rights -band $writeMask) -ne 0) {
                    throw "Reader SID '$sid' has rights other than read/execute on '$($item.FullName)': $rights."
                }
            }
        }
        foreach ($sid in $fullControlSids) {
            if (-not $rightsBySid.ContainsKey($sid) -or
                ($rightsBySid[$sid] -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
                    [Security.AccessControl.FileSystemRights]::FullControl) { throw "Host-owner SID '$sid' lacks FullControl on '$($item.FullName)'." }
        }
        if (-not $rightsBySid.ContainsKey($ReaderSid.Value) -or
            ($rightsBySid[$ReaderSid.Value] -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne
                [Security.AccessControl.FileSystemRights]::ReadAndExecute) {
            throw "Reader SID '$($ReaderSid.Value)' lacks read/execute on '$($item.FullName)'."
        }
    }
}

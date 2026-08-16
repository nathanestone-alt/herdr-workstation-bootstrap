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

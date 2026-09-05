Set-StrictMode -Version Latest

$script:WindowsReceiptAuthorityId = '#961-installation-authority-v1'
$script:WindowsReceiptAuthorityPath = 'C:\ProgramData\STModel\Issue961\receipt-authority.json'
$script:WindowsReceiptPath = 'C:\ProgramData\STModel\Issue961\bootstrap-receipt.json'
$script:WindowsRuntimeAccount = 'HERDR-WIN\rdp-natha'

function Get-HerdrAuthoritySha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-HerdrCanonicalValue {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or
        $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or
        $Value -is [double] -or $Value -is [decimal]) {
        return $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
            $ordered[$key] = ConvertTo-HerdrCanonicalValue -Value $Value[$key]
        }
        return $ordered
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-HerdrCanonicalValue -Value $_ })
    }
    $properties = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)) {
        $properties[$property] = ConvertTo-HerdrCanonicalValue -Value $Value.$property
    }
    return $properties
}

function ConvertTo-HerdrCanonicalJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object]$Value)

    return (ConvertTo-HerdrCanonicalValue -Value $Value | ConvertTo-Json -Depth 32 -Compress)
}

function Get-HerdrStringSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Value)))).Replace('-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Assert-HerdrAuthorityHex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][ValidateSet(40, 64)][int]$Length, [Parameter(Mandatory)][string]$Label)

    if ($Value -cnotmatch "^[0-9a-f]{$Length}$") { throw "$Label must be exactly $Length lowercase hexadecimal characters." }
}

function Assert-HerdrAuthoritySafePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [switch]$AllowMissingLeaf)

    $canonical = Get-HerdrCanonicalPath -Path $Path
    if ($IsWindows) {
        $root = [IO.Path]::GetPathRoot($canonical)
        if ($root -notmatch '^[A-Za-z]:\\$' -or ([IO.DriveInfo]::new($root)).DriveType -ne [IO.DriveType]::Fixed) {
            throw "Authority path must be on a fixed local drive: '$canonical'."
        }
    }
    Get-HerdrPhysicalPathProof -Path $canonical -AllowMissingLeaf:$AllowMissingLeaf | Out-Null
    return $canonical
}

function Get-HerdrAuthorityCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Name, [Parameter(Mandatory)][string]$Label, [switch]$AllowReparseLeaf)

    $command = $null
    foreach ($candidate in $Name) {
        $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { break }
    }
    if (-not $command) { throw "$Label executable is unavailable." }
    $path = Get-HerdrCanonicalPath -Path $command.Source
    $item = Get-Item -LiteralPath $path -Force
    $isReparse = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    if ($isReparse -and -not $AllowReparseLeaf) { throw "$Label executable is a reparse point: '$path'." }
    if (-not $isReparse) { Assert-HerdrAuthoritySafePath -Path $path | Out-Null }
    return [pscustomobject][ordered]@{ Path = $path; Item = $item; IsReparse = $isReparse }
}

function Resolve-HerdrAuthorityReparseTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Command, [Parameter(Mandatory)][string]$Label)

    if (-not $Command.IsReparse) { return [string]$Command.Path }
    $targets = @($Command.Item.Target)
    if ($targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$targets[0])) {
        throw "$Label reparse point must expose exactly one target: '$($Command.Path)'."
    }
    $target = [string]$targets[0]
    if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $Command.Path) $target }
    $canonicalTarget = Get-HerdrCanonicalPath -Path $target
    Assert-HerdrAuthoritySafePath -Path $canonicalTarget | Out-Null
    $targetItem = Get-Item -LiteralPath $canonicalTarget -Force
    if (($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $targetItem.PSIsContainer -or -not [IO.File]::Exists($canonicalTarget)) {
        throw "$Label resolved target is not a non-reparse regular file: '$canonicalTarget'."
    }
    return $canonicalTarget
}

function Invoke-HerdrAuthorityCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$ArgumentList, [Parameter(Mandatory)][string]$Label)

    $output = @(& $Path @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code ${LASTEXITCODE}: $($output -join ' ')" }
    return ($output -join "`n").Trim()
}

function Get-HerdrRuntimeProfilePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.Principal.SecurityIdentifier]$RuntimeSid)

    if (-not $IsWindows) { throw 'Runtime profile resolution requires Windows.' }
    $profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($RuntimeSid.Value)"
    $profileValue = [string](Get-ItemPropertyValue -LiteralPath $profileKey -Name ProfileImagePath -ErrorAction Stop)
    if ([string]::IsNullOrWhiteSpace($profileValue)) { throw "Runtime profile path is missing for SID '$($RuntimeSid.Value)'." }
    $expanded = [Environment]::ExpandEnvironmentVariables($profileValue)
    return Assert-HerdrAuthoritySafePath -Path $expanded
}

function Test-HerdrPayloadManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PayloadRoot, [Parameter(Mandatory)][string]$ManifestPath)

    $seen = @{}
    foreach ($line in [IO.File]::ReadAllLines($ManifestPath, [Text.UTF8Encoding]::new($false))) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        if ($line -cnotmatch '^([0-9a-f]{64})  ([A-Za-z0-9._/-]+)$') { throw "Payload manifest has an invalid line: '$line'." }
        $expected = $Matches[1]
        $relative = $Matches[2]
        if ($relative.Contains('..') -or $relative.StartsWith('/') -or $seen.ContainsKey($relative)) {
            throw "Payload manifest has an unsafe or duplicate path: '$relative'."
        }
        $seen[$relative] = $true
        $path = Join-Path $PayloadRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        Assert-HerdrAuthoritySafePath -Path $path | Out-Null
        if ((Get-HerdrAuthoritySha256 -Path $path) -cne $expected) { throw "Payload file hash differs from manifest: '$relative'." }
    }
    if ($seen.Count -eq 0) { throw 'Payload manifest is empty.' }
}

function Get-HerdrRoleDefinitions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AllowlistPath)

    $definitions = @{}
    foreach ($line in [IO.File]::ReadAllLines($AllowlistPath, [Text.UTF8Encoding]::new($false))) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        $parts = @($line.Split('|'))
        if ($parts.Count -ne 5 -or $definitions.ContainsKey($parts[0])) { throw "Role allowlist has an invalid or duplicate entry: '$line'." }
        $definitions[$parts[0]] = [ordered]@{
            registry_id = $parts[1]
            names = @($parts[2].Split(','))
            version_argv = @($parts[3].Split(','))
            implementation = $parts[4]
        }
    }
    return $definitions
}

function Get-HerdrRoleManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Definitions, [Parameter(Mandatory)][string[]]$RequiredRole, [Parameter(Mandatory)][string]$SourceCommit)

    $manifest = [ordered]@{}
    foreach ($role in @($RequiredRole | Sort-Object -CaseSensitive -Unique)) {
        if (-not $Definitions.ContainsKey($role)) { throw "Role '$role' is not in the reviewed #961 allowlist." }
        $definition = $Definitions[$role]
        $command = Get-HerdrAuthorityCommand -Name $definition.names -Label $role
        $versionOutput = Invoke-HerdrAuthorityCommand -Path $command.Path -ArgumentList $definition.version_argv -Label "$role version probe"
        $sha256 = Get-HerdrAuthoritySha256 -Path $command.Path
        $manifest[$role] = [ordered]@{
            executable = $command.Path
            sha256 = $sha256
            registry_id = $definition.registry_id
            source_commit_sha = $SourceCommit
            source_attestation = [ordered]@{ kind = '#961-role-manifest-v1'; canonical_path = $command.Path; file_sha256 = $sha256 }
            version = (($versionOutput -split "`r?`n")[0]).Trim()
            version_argv = @($definition.version_argv)
            version_output_sha256 = Get-HerdrStringSha256 -Value $versionOutput
            implementation = $definition.implementation
        }
    }
    return $manifest
}

function Get-HerdrPython313Identity {
    [CmdletBinding()]
    param()

    $launcher = Get-HerdrAuthorityCommand -Name @('py.exe', 'py') -Label 'Windows py launcher'
    $probe = 'import json,platform,sys;print(json.dumps({"executable":sys.executable,"version":platform.python_version(),"version_info":list(sys.version_info[:5]),"implementation":platform.python_implementation()},sort_keys=True,separators=(",",":")))'
    $value = Invoke-HerdrAuthorityCommand -Path $launcher.Path -ArgumentList @('-3.13', '-I', '-S', '-c', $probe) -Label 'CPython 3.13 identity probe' | ConvertFrom-Json -AsHashtable
    if (@($value.version_info)[0..1] -join '.' -cne '3.13' -or $value.implementation -cne 'CPython') {
        throw 'The Windows py launcher did not resolve CPython 3.13.'
    }
    $pythonPath = Assert-HerdrAuthoritySafePath -Path ([string]$value.executable)
    return [ordered]@{
        executable = $pythonPath
        sha256 = Get-HerdrAuthoritySha256 -Path $pythonPath
        version = [string]$value.version
        version_info = @($value.version_info)
        implementation = [string]$value.implementation
        launcher = [ordered]@{ executable = $launcher.Path; sha256 = Get-HerdrAuthoritySha256 -Path $launcher.Path }
    }
}

function Get-HerdrUvIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuntimeProfilePath,
        [Parameter(Mandatory)][string]$ExpectedTargetSha256
    )

    Assert-HerdrAuthorityHex -Value $ExpectedTargetSha256 -Length 64 -Label 'ExpectedUvTargetSha256'
    $profile = Assert-HerdrAuthoritySafePath -Path $RuntimeProfilePath
    $linkPath = Get-HerdrCanonicalPath -Path (Join-Path $profile 'AppData\Local\Microsoft\WinGet\Links\uv.exe')
    Assert-HerdrAuthoritySafePath -Path (Split-Path -Parent $linkPath) | Out-Null
    if (-not [IO.File]::Exists($linkPath)) { throw "The approved WinGet uv command link is missing: '$linkPath'." }
    $linkItem = Get-Item -LiteralPath $linkPath -Force -ErrorAction Stop
    $isReparse = ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    if (-not $isReparse -or $linkItem.PSIsContainer) {
        throw "The approved WinGet uv command leaf is not a reparse link: '$linkPath'."
    }
    $command = [pscustomobject][ordered]@{ Path = $linkPath; Item = $linkItem; IsReparse = $true }
    $target = Resolve-HerdrAuthorityReparseTarget -Command $command -Label 'uv'
    $packageRoot = Assert-HerdrAuthoritySafePath -Path (Join-Path $profile 'AppData\Local\Microsoft\WinGet\Packages')
    if (-not (Test-HerdrPathSameOrDescendant -Candidate $target -Ancestor $packageRoot)) {
        throw "The WinGet uv link target is outside the approved package root: '$target'."
    }
    $relativeTarget = [IO.Path]::GetRelativePath($packageRoot, $target)
    if ($relativeTarget -notmatch '(?i)^astral-sh[.]uv_Microsoft[.]Winget[.]Source_[A-Za-z0-9]+\\(?:[^\\]+\\)*uv[.]exe$') {
        throw "The WinGet uv link target has an unexpected package topology: '$target'."
    }
    $targetSha256 = Get-HerdrAuthoritySha256 -Path $target
    if ($targetSha256 -cne $ExpectedTargetSha256) {
        throw "The WinGet uv target bytes differ from the independently commissioned SHA-256: '$target'."
    }
    $version = Invoke-HerdrAuthorityCommand -Path $target -ArgumentList @('--version') -Label 'uv version probe'
    return [ordered]@{
        command_path = $command.Path
        command_path_is_reparse = $true
        executable = $target
        sha256 = $targetSha256
        version = (($version -split "`r?`n")[0]).Trim()
        version_output_sha256 = Get-HerdrStringSha256 -Value $version
    }
}

function New-HerdrWindowsReceiptValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$SourceCommit,
        [Parameter(Mandatory)][string]$PayloadManifestSha256,
        [Parameter(Mandatory)][string]$BridgeAllowlistSha256,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][string]$RuntimeAccount,
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier]$RuntimeSid,
        [Parameter(Mandatory)][Collections.IDictionary]$Python313,
        [Parameter(Mandatory)][Collections.IDictionary]$Uv,
        [Parameter(Mandatory)][Collections.IDictionary]$RoleIdentities,
        [Parameter(Mandatory)][string]$ProducerScriptSha256,
        [datetime]$Now = [DateTime]::UtcNow
    )

    $issued = $Now.ToUniversalTime()
    $receiptId = 'issue-961-windows-{0}-{1}' -f $SourceCommit.Substring(0, 12), $issued.ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture)
    $roleManifestJson = ConvertTo-HerdrCanonicalJson -Value $RoleIdentities
    $receipt = [ordered]@{
        schema_version = 1
        receipt_id = $receiptId
        verification_status = 'verified'
        source_commit_sha = $SourceCommit
        clean = $true
        python313_lock_verified = $true
        payload_manifest_sha256 = $PayloadManifestSha256
        bridge_allowlist_sha256 = $BridgeAllowlistSha256
        platform = 'Windows'
        architecture = 'x86_64'
        issued_at_utc = $issued.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        expires_at_utc = $issued.AddDays(30).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        python313 = $Python313
        uv = $Uv
        role_identities = $RoleIdentities
        role_manifest_sha256 = Get-HerdrStringSha256 -Value $roleManifestJson
        runtime_identity = [ordered]@{ account = $RuntimeAccount; sid = $RuntimeSid.Value }
        provenance = [ordered]@{
            authority_id = $script:WindowsReceiptAuthorityId
            producer = 'herdr-workstation-bootstrap'
            source_root = $SourceRoot
            source_commit_sha = $SourceCommit
            receipt_authority_script_sha256 = $ProducerScriptSha256
            authority_mode = 'authoritative'
            secrets_excluded = $true
        }
    }
    return $receipt
}

function New-HerdrWindowsAuthorityValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Receipt,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][string]$ReceiptSha256
    )

    return [ordered]@{
        schema_version = 1
        authority_id = $script:WindowsReceiptAuthorityId
        receipt_path = $ReceiptPath
        receipt_sha256 = $ReceiptSha256
        receipt_id = $Receipt.receipt_id
        verification_status = $Receipt.verification_status
        source_commit_sha = $Receipt.source_commit_sha
        payload_manifest_sha256 = $Receipt.payload_manifest_sha256
        bridge_allowlist_sha256 = $Receipt.bridge_allowlist_sha256
        platform = $Receipt.platform
        architecture = $Receipt.architecture
        python313 = $Receipt.python313
        uv = $Receipt.uv
        role_manifest_sha256 = $Receipt.role_manifest_sha256
        runtime_identity = $Receipt.runtime_identity
        provenance = $Receipt.provenance
    }
}

function Write-HerdrAuthorityStagedFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Publish-HerdrAuthorityFirstInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AuthorityPath,
        [Parameter(Mandatory)][string]$AuthorityContent,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][string]$ReceiptContent,
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier]$RuntimeSid,
        [Parameter(Mandatory)][object]$RuntimeToken
    )

    $authority = Get-HerdrCanonicalPath -Path $AuthorityPath
    $receipt = Get-HerdrCanonicalPath -Path $ReceiptPath
    $target = Split-Path -Parent $authority
    if ($target -cne (Split-Path -Parent $receipt) -or
        [IO.Path]::GetFileName($authority) -cne 'receipt-authority.json' -or
        [IO.Path]::GetFileName($receipt) -cne 'bootstrap-receipt.json') {
        throw 'Authority publication paths do not form the fixed #961 pair.'
    }
    if ([IO.Directory]::Exists($target) -or [IO.File]::Exists($authority) -or [IO.File]::Exists($receipt)) {
        throw 'The #961 authority pair already exists; first-install-only publication refuses replacement.'
    }

    $namespaceParent = Split-Path -Parent $target
    Ensure-HerdrManagedDirectory -Path $namespaceParent -Description '#961 authority namespace parent' | Out-Null
    Assert-HerdrAuthoritySafePath -Path $namespaceParent | Out-Null
    $heldAncestors = [Collections.Generic.List[object]]::new()
    $stage = Join-Path $namespaceParent ('.issue-961-authority-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $published = $false
    try {
        foreach ($component in @(Get-HerdrPathComponents -Path $namespaceParent)) {
            $raw = [Herdr.Security.NativeMethods]::OpenDirectoryForRelative($component)
            $null = $heldAncestors.Add([Microsoft.Win32.SafeHandles.SafeFileHandle]::new($raw, $true))
        }
        Ensure-HerdrManagedDirectory -Path $stage -Description '#961 staged authority generation' -RequireLeafCreation | Out-Null
        $stageReceipt = Join-Path $stage 'bootstrap-receipt.json'
        $stageAuthority = Join-Path $stage 'receipt-authority.json'
        Write-HerdrAuthorityStagedFile -Path $stageReceipt -Content $ReceiptContent
        Write-HerdrAuthorityStagedFile -Path $stageAuthority -Content $AuthorityContent
        Protect-HostOwnedReadOnlyTree -TargetPath $stage -ReaderSid $RuntimeSid

        $stagedReceiptHash = Get-HerdrAuthoritySha256 -Path $stageReceipt
        $stagedAuthority = [IO.File]::ReadAllText($stageAuthority, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -AsHashtable
        $stagedReceipt = [IO.File]::ReadAllText($stageReceipt, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -AsHashtable
        if ([string]$stagedAuthority.receipt_path -cne $script:WindowsReceiptPath -or
            [string]$stagedAuthority.receipt_sha256 -cne $stagedReceiptHash -or
            [string]$stagedAuthority.receipt_id -cne [string]$stagedReceipt.receipt_id -or
            [string]$stagedAuthority.authority_id -cne $script:WindowsReceiptAuthorityId) {
            throw 'The staged #961 authority generation is not internally coherent.'
        }
        Assert-HerdrAuthorityNamespaceRuntimeAccess -AuthorityRoot $stage -RuntimeToken $RuntimeToken
        if ([IO.Directory]::Exists($target) -or [IO.File]::Exists($authority) -or [IO.File]::Exists($receipt)) {
            throw 'The #961 authority namespace appeared during first-install publication.'
        }
        [IO.Directory]::Move($stage, $target)
        $published = $true
    }
    finally {
        foreach ($handle in $heldAncestors) { $handle.Dispose() }
        if (-not $published -and [IO.Directory]::Exists($stage)) {
            Remove-Item -LiteralPath $stage -Recurse -Force
        }
    }
}

function Assert-HerdrWindowsAuthority {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AuthorityPath,
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier]$RuntimeSid,
        [Parameter(Mandatory)][object]$RuntimeToken,
        [Parameter(Mandatory)][string]$RuntimeProfilePath
    )

    if ((Get-HerdrCanonicalPath -Path $AuthorityPath) -cne $script:WindowsReceiptAuthorityPath) {
        throw 'The #961 Windows authority check cannot be redirected from its fixed path.'
    }
    Assert-HerdrAuthoritySafePath -Path $AuthorityPath | Out-Null
    Assert-HostOwnedReadOnlyTree -TargetPath (Split-Path -Parent $AuthorityPath) -ReaderSid $RuntimeSid
    Assert-HerdrAuthorityNamespaceRuntimeAccess -AuthorityRoot (Split-Path -Parent $AuthorityPath) -RuntimeToken $RuntimeToken
    $authorityHandle = [IO.File]::Open($AuthorityPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $receiptHandle = $null
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $authority = [IO.File]::ReadAllText($AuthorityPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -AsHashtable
        if ($authority.schema_version -ne 1 -or $authority.authority_id -cne $script:WindowsReceiptAuthorityId -or
            $authority.platform -cne 'Windows' -or $authority.architecture -cne 'x86_64' -or
            $authority.runtime_identity.account -cne $script:WindowsRuntimeAccount -or
            $authority.runtime_identity.sid -cne $RuntimeSid.Value -or
            [string]$authority.receipt_path -cne $script:WindowsReceiptPath) { throw 'Installed Windows authority identity is invalid.' }
        foreach ($field in @('receipt_sha256', 'payload_manifest_sha256', 'bridge_allowlist_sha256', 'role_manifest_sha256')) {
            Assert-HerdrAuthorityHex -Value ([string]$authority[$field]) -Length 64 -Label "authority $field"
        }
        Assert-HerdrAuthorityHex -Value ([string]$authority.source_commit_sha) -Length 40 -Label 'authority source_commit_sha'
        $receiptPath = Assert-HerdrAuthoritySafePath -Path ([string]$authority.receipt_path)
        $receiptHandle = [IO.File]::Open($receiptPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $receiptHash = ([BitConverter]::ToString($hashAlgorithm.ComputeHash($receiptHandle))).Replace('-', '').ToLowerInvariant()
        if ($receiptHash -cne [string]$authority.receipt_sha256) { throw 'Installed authority receipt hash differs from the held receipt.' }
        $receipt = [IO.File]::ReadAllText($receiptPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -AsHashtable
        if ($receipt.receipt_id -cne $authority.receipt_id -or $receipt.source_commit_sha -cne $authority.source_commit_sha -or
            $receipt.payload_manifest_sha256 -cne $authority.payload_manifest_sha256 -or
            $receipt.bridge_allowlist_sha256 -cne $authority.bridge_allowlist_sha256 -or
            $receipt.role_manifest_sha256 -cne $authority.role_manifest_sha256 -or
            $receipt.runtime_identity.sid -cne $authority.runtime_identity.sid -or
            $receipt.python313.sha256 -cne $authority.python313.sha256 -or
            $receipt.python313.launcher.sha256 -cne $authority.python313.launcher.sha256 -or
            $receipt.uv.sha256 -cne $authority.uv.sha256 -or
            $receipt.uv.command_path -cne $authority.uv.command_path -or
            $receipt.uv.executable -cne $authority.uv.executable -or
            [bool]$receipt.uv.command_path_is_reparse -ne [bool]$authority.uv.command_path_is_reparse -or
            $receipt.uv.version_output_sha256 -cne $authority.uv.version_output_sha256) {
            throw 'Installed authority does not exactly bind the receipt identities.'
        }
        $expires = [DateTime]::ParseExact([string]$receipt.expires_at_utc, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        if ($expires.ToUniversalTime() -le [DateTime]::UtcNow) { throw 'Installed Windows receipt is expired.' }
        $roleHash = Get-HerdrStringSha256 -Value (ConvertTo-HerdrCanonicalJson -Value $receipt.role_identities)
        if ($roleHash -cne $authority.role_manifest_sha256) { throw 'Installed receipt role manifest hash is invalid.' }
        foreach ($identity in @($receipt.python313, $receipt.python313.launcher, $receipt.uv) + @($receipt.role_identities.Values)) {
            $identityPath = Assert-HerdrAuthoritySafePath -Path ([string]$identity.executable)
            if ((Get-HerdrAuthoritySha256 -Path $identityPath) -cne [string]$identity.sha256) {
                throw "Installed executable identity hash changed: '$identityPath'."
            }
        }
        if ([bool]$receipt.uv.command_path_is_reparse -ne $true) {
            throw 'Installed uv command receipt does not require a reparse link.'
        }
        $actualUv = Get-HerdrUvIdentity -RuntimeProfilePath $RuntimeProfilePath -ExpectedTargetSha256 ([string]$receipt.uv.sha256)
        if ([string]$actualUv.command_path -cne [string]$receipt.uv.command_path -or
            [string]$actualUv.executable -cne [string]$receipt.uv.executable -or
            [string]$actualUv.version -cne [string]$receipt.uv.version -or
            [string]$actualUv.version_output_sha256 -cne [string]$receipt.uv.version_output_sha256) {
            throw 'Installed uv command no longer resolves to the receipted target.'
        }
    }
    finally {
        $hashAlgorithm.Dispose()
        if ($receiptHandle) { $receiptHandle.Dispose() }
        $authorityHandle.Dispose()
    }
}

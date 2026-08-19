Set-StrictMode -Version Latest

if ($IsWindows -and $null -eq ('Herdr.Security.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace Herdr.Security {
    public sealed class FileIdentity {
        public uint Attributes { get; set; }
        public uint VolumeSerialNumber { get; set; }
        public ulong FileIndex { get; set; }
        public uint NumberOfLinks { get; set; }
    }

    public static class NativeMethods {
        public const uint GenericRead = 0x80000000;
        public const uint FileReadAttributes = 0x00000080;
        public const uint FileShareRead = 0x00000001;
        public const uint FileShareWrite = 0x00000002;
        public const uint FileShareDelete = 0x00000004;
        public const uint OpenExisting = 3;
        public const uint FileFlagOpenReparsePoint = 0x00200000;
        public const uint FileFlagBackupSemantics = 0x02000000;
        public const uint FileFlagSequentialScan = 0x08000000;
        public const uint FileAttributeReparsePoint = 0x00000400;
        public const uint InvalidHandleValue = 0xffffffff;
        public const uint ProcessQueryLimitedInformation = 0x1000;
        public const uint TokenQuery = 0x0008;
        public const int TokenUser = 1;

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation {
            public uint FileAttributes;
            public uint CreationTimeLow;
            public uint CreationTimeHigh;
            public uint LastAccessTimeLow;
            public uint LastAccessTimeHigh;
            public uint LastWriteTimeLow;
            public uint LastWriteTimeHigh;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            IntPtr fileHandle,
            out ByHandleFileInformation fileInformation);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            IntPtr fileHandle,
            StringBuilder filePath,
            uint filePathLength,
            uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(
            uint desiredAccess,
            bool inheritHandle,
            int processId);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(
            IntPtr processHandle,
            uint desiredAccess,
            out IntPtr tokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetTokenInformation(
            IntPtr tokenHandle,
            int tokenInformationClass,
            IntPtr tokenInformation,
            int tokenInformationLength,
            out int returnLength);

        public static IntPtr OpenPath(string path, bool directory, bool exclusive) {
            uint desiredAccess = directory ? FileReadAttributes : GenericRead;
            uint shareMode = exclusive ? 0u : FileShareRead | FileShareWrite | FileShareDelete;
            uint flags = FileFlagOpenReparsePoint | (directory ? FileFlagBackupSemantics : 0u);
            if (!directory) flags |= FileFlagSequentialScan;
            IntPtr handle = CreateFileW(path, desiredAccess, shareMode, IntPtr.Zero, OpenExisting, flags, IntPtr.Zero);
            if (handle == IntPtr.Zero || handle.ToInt64() == -1) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return handle;
        }

        public static FileIdentity ReadFileIdentity(IntPtr handle) {
            ByHandleFileInformation info;
            if (!GetFileInformationByHandle(handle, out info)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return new FileIdentity {
                Attributes = info.FileAttributes,
                VolumeSerialNumber = info.VolumeSerialNumber,
                FileIndex = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow,
                NumberOfLinks = info.NumberOfLinks
            };
        }

        public static string ReadFinalPath(IntPtr handle) {
            uint capacity = 512;
            while (capacity <= 32768) {
                var builder = new StringBuilder((int)capacity);
                uint length = GetFinalPathNameByHandleW(handle, builder, capacity, 0);
                if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (length < capacity - 1) return builder.ToString();
                capacity *= 2;
            }
            throw new IOException("The final Windows path exceeded the supported length.");
        }

        public static string ReadProcessUserSid(int processId) {
            IntPtr process = OpenProcess(ProcessQueryLimitedInformation, false, processId);
            if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr token = IntPtr.Zero;
            IntPtr buffer = IntPtr.Zero;
            try {
                if (!OpenProcessToken(process, TokenQuery, out token)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                int length = 0;
                GetTokenInformation(token, TokenUser, IntPtr.Zero, 0, out length);
                if (length <= 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                buffer = Marshal.AllocHGlobal(length);
                if (!GetTokenInformation(token, TokenUser, buffer, length, out length)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                IntPtr sid = Marshal.ReadIntPtr(buffer);
                return new SecurityIdentifier(sid).Value;
            }
            finally {
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                if (token != IntPtr.Zero) CloseHandle(token);
                CloseHandle(process);
            }
        }

        public static int ReadWindowProcessId(IntPtr windowHandle) {
            uint processId;
            GetWindowThreadProcessId(windowHandle, out processId);
            return unchecked((int)processId);
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    }
}
'@
}

function Get-HerdrWorkbookExtensionAllowlist {
    return @('.xlsx', '.xlsm', '.xlsb')
}

function Get-HerdrCanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path is empty.'
    }
    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('\\.\', [StringComparison]::Ordinal) -or
        $Path.StartsWith('\??\', [StringComparison]::Ordinal)) {
        throw "Device namespace paths are not allowed: '$Path'."
    }
    if ($Path.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw "UNC paths are not allowed: '$Path'."
    }
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
    }
    catch {
        throw "Path is not valid: '$Path'."
    }
    while ($fullPath.Length -gt 1 -and ($fullPath.EndsWith('\') -or $fullPath.EndsWith('/'))) {
        $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }
    return $fullPath
}

function ConvertTo-HerdrFinalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $value = $Path
    $isExtendedLocalPath = $value.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)
    if ($value.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase) -or
        $value.StartsWith('\\.\', [StringComparison]::OrdinalIgnoreCase) -or
        $value.StartsWith('\Device\', [StringComparison]::OrdinalIgnoreCase) -or
        ($value.StartsWith('\\', [StringComparison]::Ordinal) -and -not $isExtendedLocalPath)) {
        throw "Windows resolved a device, namespace, or UNC path: '$Path'."
    }
    if ($isExtendedLocalPath) {
        $value = $value.Substring(4)
    }
    $canonical = Get-HerdrCanonicalPath -Path $value
    if ($IsWindows -and $canonical -notmatch '^[A-Za-z]:\\') {
        throw "Windows resolved a non-local path: '$Path'."
    }
    return $canonical
}

function Get-HerdrPathComponents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $canonical = Get-HerdrCanonicalPath -Path $Path
    $root = [IO.Path]::GetPathRoot($canonical)
    if ([string]::IsNullOrWhiteSpace($root)) { throw "Path has no root: '$canonical'." }
    $components = [Collections.Generic.List[string]]::new()
    $null = $components.Add($root)
    $remainder = $canonical.Substring($root.Length).TrimStart('\', '/')
    if (-not [string]::IsNullOrWhiteSpace($remainder)) {
        $current = $root
        $separatorPattern = if ($IsWindows) { '[\\/]+' } else { '/+' }
        foreach ($part in ($remainder -split $separatorPattern)) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            $current = Join-Path $current $part
            $null = $components.Add($current)
        }
    }
    return @($components)
}

function Get-HerdrPortableIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)

    $linkType = $null
    $linkProperty = $Item.PSObject.Properties['LinkType']
    if ($null -ne $linkProperty) { $linkType = [string]$linkProperty.Value }
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrWhiteSpace($linkType)) {
        throw "Path contains a symbolic or reparse link: '$($Item.FullName)'."
    }
    [pscustomobject][ordered]@{
        Attributes = [int64]$Item.Attributes
        VolumeSerialNumber = $null
        FileIndex = $null
        NumberOfLinks = [int64]1
        FileIdentity = $null
    }
}

function Get-HerdrPhysicalPathProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissingLeaf
    )

    $canonical = Get-HerdrCanonicalPath -Path $Path
    $ancestors = [Collections.Generic.List[object]]::new()
    $leafExists = $true
    $leafIdentity = $null
    $leafFinalPath = $null
    $components = @(Get-HerdrPathComponents -Path $canonical)

    if ($IsWindows) {
        for ($index = 0; $index -lt $components.Count; $index++) {
            $component = [string]$components[$index]
            $isDirectory = [IO.Directory]::Exists($component)
            $isFile = [IO.File]::Exists($component)
            if (-not $isDirectory -and -not $isFile) {
                if ($AllowMissingLeaf -and $index -eq ($components.Count - 1)) {
                    $leafExists = $false
                    break
                }
                throw "Path component does not exist: '$component'."
            }
            $rawHandle = [IntPtr]::Zero
            try {
                $rawHandle = [Herdr.Security.NativeMethods]::OpenPath($component, $isDirectory, $false)
                $identity = [Herdr.Security.NativeMethods]::ReadFileIdentity($rawHandle)
                if (($identity.Attributes -band [Herdr.Security.NativeMethods]::FileAttributeReparsePoint) -ne 0) {
                    throw "Path component is a reparse point: '$component'."
                }
                $finalPath = ConvertTo-HerdrFinalPath -Path ([Herdr.Security.NativeMethods]::ReadFinalPath($rawHandle))
                $record = [pscustomobject][ordered]@{
                    LexicalPath = Get-HerdrCanonicalPath -Path $component
                    FinalPath = $finalPath
                    IsDirectory = $isDirectory
                    Attributes = [int64]$identity.Attributes
                    VolumeSerialNumber = [uint64]$identity.VolumeSerialNumber
                    FileIndex = [uint64]$identity.FileIndex
                    NumberOfLinks = [uint64]$identity.NumberOfLinks
                    FileIdentity = '{0:x8}:{1:x16}' -f $identity.VolumeSerialNumber, $identity.FileIndex
                }
                $null = $ancestors.Add($record)
                if ($index -eq ($components.Count - 1)) {
                    $leafIdentity = $record
                    $leafFinalPath = $finalPath
                }
            }
            finally {
                if ($rawHandle -ne [IntPtr]::Zero -and $rawHandle.ToInt64() -ne -1) {
                    [void][Herdr.Security.NativeMethods]::CloseHandle($rawHandle)
                }
            }
        }
    }
    else {
        for ($index = 0; $index -lt $components.Count; $index++) {
            $component = [string]$components[$index]
            if (-not (Test-Path -LiteralPath $component)) {
                if ($AllowMissingLeaf -and $index -eq ($components.Count - 1)) {
                    $leafExists = $false
                    break
                }
                throw "Path component does not exist: '$component'."
            }
            $item = Get-Item -LiteralPath $component -Force -ErrorAction Stop
            $identity = Get-HerdrPortableIdentity -Item $item
            $record = [pscustomobject][ordered]@{
                LexicalPath = Get-HerdrCanonicalPath -Path $component
                FinalPath = Get-HerdrCanonicalPath -Path $component
                IsDirectory = [bool]$item.PSIsContainer
                Attributes = $identity.Attributes
                VolumeSerialNumber = $identity.VolumeSerialNumber
                FileIndex = $identity.FileIndex
                NumberOfLinks = $identity.NumberOfLinks
                FileIdentity = $identity.FileIdentity
            }
            $null = $ancestors.Add($record)
            if ($index -eq ($components.Count - 1)) {
                $leafIdentity = $record
                $leafFinalPath = $record.FinalPath
            }
        }
    }

    [pscustomobject][ordered]@{
        Path = $canonical
        Exists = $leafExists
        FinalPath = $leafFinalPath
        Leaf = $leafIdentity
        Ancestors = @($ancestors)
        VolumeSerialNumber = if ($null -ne $leafIdentity) { $leafIdentity.VolumeSerialNumber } else { $null }
        FileIndex = if ($null -ne $leafIdentity) { $leafIdentity.FileIndex } else { $null }
        FileIdentity = if ($null -ne $leafIdentity) { $leafIdentity.FileIdentity } else { $null }
        NumberOfLinks = if ($null -ne $leafIdentity) { $leafIdentity.NumberOfLinks } else { $null }
    }
}

function Compare-HerdrPhysicalIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][object]$Actual,
        [Parameter(Mandatory)][string]$Description,
        [switch]$IncludeLinkCount
    )

    $expectedIdentity = if ($Expected.PSObject.Properties['Leaf']) { $Expected.Leaf } else { $Expected }
    $actualIdentity = if ($Actual.PSObject.Properties['Leaf']) { $Actual.Leaf } else { $Actual }
    if ($null -eq $expectedIdentity -or $null -eq $actualIdentity) {
        throw "$Description physical identity is unavailable."
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$expectedIdentity.FileIdentity) -or
        -not [string]::IsNullOrWhiteSpace([string]$actualIdentity.FileIdentity)) {
        if ([string]$expectedIdentity.FileIdentity -cne [string]$actualIdentity.FileIdentity) {
            throw "$Description physical file identity changed."
        }
    }
    if ($IncludeLinkCount -and [int64]$expectedIdentity.NumberOfLinks -ne [int64]$actualIdentity.NumberOfLinks) {
        throw "$Description hard-link count changed."
    }
    return $true
}

function Assert-HerdrPhysicalPathUnderRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CandidatePath,
        [Parameter(Mandatory)][string]$RootPath,
        [object]$ExpectedCandidate,
        [object]$ExpectedRoot,
        [string]$Description = 'Configured path',
        [switch]$AllowEqual
    )

    $rootProof = Get-HerdrPhysicalPathProof -Path $RootPath
    $candidateProof = Get-HerdrPhysicalPathProof -Path $CandidatePath
    if ($null -ne $ExpectedRoot) { Compare-HerdrPhysicalIdentity -Expected $ExpectedRoot -Actual $rootProof -Description "$Description root" | Out-Null }
    if ($null -ne $ExpectedCandidate) { Compare-HerdrPhysicalIdentity -Expected $ExpectedCandidate -Actual $candidateProof -Description "$Description candidate" -IncludeLinkCount | Out-Null }
    if ([string]$rootProof.Leaf.VolumeSerialNumber -ne [string]$candidateProof.Leaf.VolumeSerialNumber -and
        -not [string]::IsNullOrWhiteSpace([string]$rootProof.Leaf.VolumeSerialNumber)) {
        throw "$Description crosses a physical volume boundary."
    }
    if (-not (Test-HerdrPathSameOrDescendant -Candidate $candidateProof.FinalPath -Ancestor $rootProof.FinalPath) -or
        (-not $AllowEqual -and $candidateProof.FinalPath.Equals($rootProof.FinalPath, [StringComparison]::OrdinalIgnoreCase))) {
        throw "$Description is outside the trusted physical root."
    }
    return [pscustomobject][ordered]@{ Root = $rootProof; Candidate = $candidateProof }
}

function Ensure-HerdrManagedDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$TrustedRoot,
        [string]$Description = 'Managed directory'
    )

    $canonical = Get-HerdrCanonicalPath -Path $Path
    $trustedRootCanonical = if ([string]::IsNullOrWhiteSpace($TrustedRoot)) { $null } else { Get-HerdrCanonicalPath -Path $TrustedRoot }
    $trustedRootProof = if ($null -eq $trustedRootCanonical) { $null } else { Get-HerdrPhysicalPathProof -Path $trustedRootCanonical }
    foreach ($component in @(Get-HerdrPathComponents -Path $canonical)) {
        $componentPath = [string]$component
        $componentExists = [IO.Directory]::Exists($componentPath) -or [IO.File]::Exists($componentPath)
        if ($componentExists) {
            if ([IO.File]::Exists($componentPath)) { throw "$Description is a file: '$componentPath'." }
            $isTrustedAncestor = $null -ne $trustedRootCanonical -and
                (Test-HerdrPathSameOrDescendant -Candidate $trustedRootCanonical -Ancestor $componentPath)
            if ($null -ne $trustedRootCanonical -and
                -not $isTrustedAncestor -and
                -not $componentPath.Equals($trustedRootCanonical, [StringComparison]::OrdinalIgnoreCase)) {
                Assert-HerdrPhysicalPathUnderRoot -CandidatePath $componentPath -RootPath $trustedRootCanonical -Description $Description | Out-Null
            }
            else {
                Get-HerdrPhysicalPathProof -Path $componentPath | Out-Null
            }
            continue
        }
        $parent = Split-Path -Parent $componentPath
        if ($null -ne $trustedRootCanonical) {
            Assert-HerdrPhysicalPathUnderRoot -CandidatePath $parent -RootPath $trustedRootCanonical -AllowEqual -Description "$Description parent" | Out-Null
        }
        else {
            Get-HerdrPhysicalPathProof -Path $parent | Out-Null
        }
        [IO.Directory]::CreateDirectory($componentPath) | Out-Null
        $createdProof = Get-HerdrPhysicalPathProof -Path $componentPath
        if (-not $createdProof.Leaf.IsDirectory) { throw "$Description is not a directory: '$componentPath'." }
    }
    if ($null -ne $trustedRootCanonical -and
        -not $canonical.Equals($trustedRootCanonical, [StringComparison]::OrdinalIgnoreCase)) {
        $boundary = Assert-HerdrPhysicalPathUnderRoot -CandidatePath $canonical -RootPath $trustedRootCanonical `
            -ExpectedRoot $trustedRootProof -Description $Description
        $candidateProof = $boundary.Candidate
    }
    else {
        $candidateProof = Get-HerdrPhysicalPathProof -Path $canonical
    }
    if (-not $candidateProof.Leaf.IsDirectory) { throw "$Description is not a directory: '$canonical'." }
    return $canonical
}

function Test-HerdrPathSameOrDescendant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Ancestor
    )

    $candidatePath = Get-HerdrCanonicalPath -Path $Candidate
    $ancestorPath = Get-HerdrCanonicalPath -Path $Ancestor
    if ($candidatePath.Equals($ancestorPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $separator = if ($ancestorPath.EndsWith('\') -or $ancestorPath.EndsWith('/')) { '' } elseif ($IsWindows) { '\' } else { '/' }
    return $candidatePath.StartsWith("$ancestorPath$separator", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-HerdrConfiguredLocalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $canonicalPath = Get-HerdrCanonicalPath -Path $Path
    if ($IsWindows) {
        $driveRoot = [IO.Path]::GetPathRoot($canonicalPath)
        if ($driveRoot -notmatch '^[A-Za-z]:\\$') {
            throw "Configured path must be on a local drive: '$canonicalPath'."
        }
        try {
            $driveType = ([IO.DriveInfo]::new($driveRoot)).DriveType
        }
        catch {
            throw "Could not inspect the configured drive for '$canonicalPath'."
        }
        if ($driveType -ne [IO.DriveType]::Fixed) {
            throw "Configured path must be on a fixed local drive: '$canonicalPath'."
        }
    }
    return $canonicalPath
}

function Assert-HerdrExistingPathIsNotReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissing
    )

    $canonicalPath = Get-HerdrCanonicalPath -Path $Path
    $proof = Get-HerdrPhysicalPathProof -Path $canonicalPath -AllowMissingLeaf:$AllowMissing
    if (-not $proof.Exists) {
        if ($AllowMissing) { return $canonicalPath }
        throw "Configured path does not exist: '$canonicalPath'."
    }
    if (-not $proof.Leaf.IsDirectory -and (Test-Path -LiteralPath $canonicalPath -PathType Container)) {
        throw "Configured path is not a directory: '$canonicalPath'."
    }
    return $canonicalPath
}

function Assert-HerdrPathDoesNotOverlap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right,
        [Parameter(Mandatory)][string]$Description
    )

    if ((Test-HerdrPathSameOrDescendant -Candidate $Left -Ancestor $Right) -or
        (Test-HerdrPathSameOrDescendant -Candidate $Right -Ancestor $Left)) {
        throw "Configured $Description paths overlap."
    }
}

function Assert-HerdrJobId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JobId)

    if ($JobId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $JobId -in @('.', '..') -or
        $JobId.EndsWith('.') -or $JobId.EndsWith(' ')) {
        throw 'Job ID is invalid; use 1-64 ASCII letters, digits, dot, underscore, or hyphen, without a trailing dot or space.'
    }
    return $JobId
}

function Assert-HerdrMetadataValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [int]$MaximumLength = 512
    )

    if ($Value.Length -gt $MaximumLength -or $Value.IndexOf([char]0) -ge 0 -or
        $Value.IndexOf("`r") -ge 0 -or $Value.IndexOf("`n") -ge 0) {
        throw "$Name contains unsupported control data."
    }
    return $Value
}

function Get-HerdrDefaultOneDriveInboxRoot {
    [CmdletBinding()]
    param()

    $oneDriveRoot = if (-not [string]::IsNullOrWhiteSpace($env:OneDriveCommercial)) {
        $env:OneDriveCommercial
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:OneDrive)) {
        $env:OneDrive
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Join-Path $env:USERPROFILE 'OneDrive'
    }
    else {
        throw 'No configured OneDrive root is available; pass -OneDriveInboxRoot explicitly.'
    }
    return (Join-Path (Join-Path $oneDriveRoot 'Herdr Review Exchange') 'Inbox')
}

function Get-HerdrDefaultOneDriveSiblingRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InboxRoot,
        [Parameter(Mandatory)][ValidateSet('Outbox', 'Archive')][string]$Name
    )

    return (Join-Path (Split-Path -Parent (Get-HerdrCanonicalPath -Path $InboxRoot)) $Name)
}

function Get-HerdrBlockedAttributeNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Attributes)

    $blockedAttributes = [ordered]@{
        Offline = [int64]0x1000
        ReparsePoint = [int64][IO.FileAttributes]::ReparsePoint
        RecallOnOpen = [int64]0x40000
        RecallOnDataAccess = [int64]0x400000
    }
    return @(
        foreach ($entry in $blockedAttributes.GetEnumerator()) {
            if (([int64]$Attributes -band $entry.Value) -ne 0) { $entry.Key }
        }
    )
}

function Assert-HerdrWorkbookFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $proof = Get-HerdrPhysicalPathProof -Path $Path
    if (-not $proof.Exists -or $null -eq $proof.Leaf -or $proof.Leaf.IsDirectory) {
        throw 'Workbook source must be a regular file.'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -and $item.Length -ge 0) {
        $extension = [IO.Path]::GetExtension($item.Name).ToLowerInvariant()
        if ($extension -notin (Get-HerdrWorkbookExtensionAllowlist)) {
            throw "Workbook extension '$extension' is not allowed."
        }
        $blocked = @(Get-HerdrBlockedAttributeNames -Attributes $item.Attributes)
        if ($blocked.Count -gt 0) {
            throw "Workbook is not fully hydrated; blocked attributes: $($blocked -join ', ')."
        }
        return $item
    }
    throw 'Workbook source must be a regular file.'
}

function Open-HerdrNativeReadFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not $IsWindows) { throw 'Native file handles are available only on Windows.' }
    $canonical = Get-HerdrCanonicalPath -Path $Path
    $rawHandle = [Herdr.Security.NativeMethods]::OpenPath($canonical, $false, $true)
    $safeHandle = $null
    try {
        $safeHandle = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new($rawHandle, $true)
        $identity = [Herdr.Security.NativeMethods]::ReadFileIdentity($rawHandle)
        if (($identity.Attributes -band [Herdr.Security.NativeMethods]::FileAttributeReparsePoint) -ne 0) {
            throw "Workbook source is a reparse point: '$canonical'."
        }
        if ([int64]$identity.NumberOfLinks -gt 1) {
            throw "Workbook source has multiple hard links: '$canonical'."
        }
        $finalPath = ConvertTo-HerdrFinalPath -Path ([Herdr.Security.NativeMethods]::ReadFinalPath($rawHandle))
        [pscustomobject][ordered]@{
            Path = $canonical
            SafeHandle = $safeHandle
            Identity = [pscustomobject][ordered]@{
                Exists = $true
                IsDirectory = $false
                Attributes = [int64]$identity.Attributes
                VolumeSerialNumber = [uint64]$identity.VolumeSerialNumber
                FileIndex = [uint64]$identity.FileIndex
                NumberOfLinks = [uint64]$identity.NumberOfLinks
                FileIdentity = '{0:x8}:{1:x16}' -f $identity.VolumeSerialNumber, $identity.FileIndex
            }
            FinalPath = $finalPath
        }
    }
    catch {
        if ($null -ne $safeHandle) { $safeHandle.Dispose() }
        elseif ($rawHandle -ne [IntPtr]::Zero -and $rawHandle.ToInt64() -ne -1) { [void][Herdr.Security.NativeMethods]::CloseHandle($rawHandle) }
        throw
    }
}

function ConvertTo-HerdrSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Bytes)

    return [Convert]::ToHexString($Bytes).ToLowerInvariant()
}

function Get-HerdrFileSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$TrustedRoot,
        [object]$ExpectedIdentity
    )

    $canonicalPath = Get-HerdrCanonicalPath -Path $Path
    $boundaryBefore = $null
    if (-not [string]::IsNullOrWhiteSpace($TrustedRoot)) {
        $boundaryBefore = Assert-HerdrPhysicalPathUnderRoot -CandidatePath $canonicalPath -RootPath $TrustedRoot -Description 'File boundary'
    }
    $before = Assert-HerdrWorkbookFile -Path $canonicalPath
    $beforeLength = [int64]$before.Length
    $beforeWriteTime = $before.LastWriteTimeUtc
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    $opened = $null
    $openedIdentity = $null
    try {
        try {
            if ($IsWindows) {
                $opened = Open-HerdrNativeReadFile -Path $canonicalPath
                $openedIdentity = $opened.Identity
                if ($null -ne $ExpectedIdentity) {
                    Compare-HerdrPhysicalIdentity -Expected $ExpectedIdentity -Actual $openedIdentity -Description 'Workbook source' -IncludeLinkCount | Out-Null
                }
                $stream = [IO.FileStream]::new($opened.SafeHandle, [IO.FileAccess]::Read, 1048576, $false)
            }
            else {
                $stream = [IO.FileStream]::new($canonicalPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None, 1048576, [IO.FileOptions]::SequentialScan)
                $openedIdentity = [pscustomobject][ordered]@{
                    Exists = $true
                    IsDirectory = $false
                    Attributes = [int64]$before.Attributes
                    VolumeSerialNumber = $null
                    FileIndex = $null
                    NumberOfLinks = [int64]1
                    FileIdentity = $null
                }
                if ($null -ne $ExpectedIdentity) {
                    Compare-HerdrPhysicalIdentity -Expected $ExpectedIdentity -Actual $openedIdentity -Description 'Workbook source' -IncludeLinkCount | Out-Null
                }
            }
            $digest = $hashAlgorithm.ComputeHash($stream)
        }
        catch {
            throw "Workbook could not be read exclusively: '$canonicalPath'. $($_.Exception.Message)"
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $opened -and $null -ne $opened.SafeHandle -and -not $opened.SafeHandle.IsClosed) { $opened.SafeHandle.Dispose() }
        $hashAlgorithm.Dispose()
    }
    try {
        $after = Assert-HerdrWorkbookFile -Path $canonicalPath
    }
    catch {
        throw "Workbook changed or disappeared during the exclusive read: '$canonicalPath'."
    }
    if ([int64]$after.Length -ne $beforeLength -or $after.LastWriteTimeUtc -ne $beforeWriteTime) {
        throw "Workbook changed during the exclusive read: '$canonicalPath'."
    }
    $afterProof = Get-HerdrPhysicalPathProof -Path $canonicalPath
    Compare-HerdrPhysicalIdentity -Expected $openedIdentity -Actual $afterProof.Leaf -Description 'Workbook source after read' -IncludeLinkCount | Out-Null
    if ($null -ne $boundaryBefore) {
        Assert-HerdrPhysicalPathUnderRoot -CandidatePath $canonicalPath -RootPath $TrustedRoot `
            -ExpectedCandidate $boundaryBefore.Candidate -ExpectedRoot $boundaryBefore.Root -Description 'File boundary after read' | Out-Null
    }
    [pscustomobject][ordered]@{
        Path = $canonicalPath
        CapturedUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        SizeBytes = $beforeLength
        LastWriteTimeUtc = $beforeWriteTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Sha256 = ConvertTo-HerdrSha256 -Bytes $digest
        VolumeSerialNumber = $openedIdentity.VolumeSerialNumber
        FileIndex = $openedIdentity.FileIndex
        NumberOfLinks = $openedIdentity.NumberOfLinks
        FileIdentity = $openedIdentity.FileIdentity
    }
}

function Assert-HerdrSnapshotsEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][object]$Actual,
        [Parameter(Mandatory)][string]$Description
    )

    if ([int64]$Expected.SizeBytes -ne [int64]$Actual.SizeBytes -or
        [string]$Expected.LastWriteTimeUtc -cne [string]$Actual.LastWriteTimeUtc -or
        [string]$Expected.Sha256 -cne [string]$Actual.Sha256) {
        throw "$Description is unstable or has a hash mismatch."
    }
}

function Assert-HerdrSnapshotContentEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][object]$Actual,
        [Parameter(Mandatory)][string]$Description
    )

    if ([int64]$Expected.SizeBytes -ne [int64]$Actual.SizeBytes -or
        [string]$Expected.Sha256 -cne [string]$Actual.Sha256) {
        throw "$Description has a size or hash mismatch."
    }
}

function Copy-HerdrFileExclusive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$TrustedRoot,
        [object]$ExpectedSourceIdentity,
        [string]$TrustedDestinationRoot
    )

    $source = Get-HerdrCanonicalPath -Path $SourcePath
    $destination = Get-HerdrCanonicalPath -Path $DestinationPath
    if (Test-Path -LiteralPath $destination) {
        throw "Destination already exists: '$destination'."
    }
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Destination directory does not exist: '$parent'."
    }
    $temporary = Join-Path $parent ('.herdr-copy-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $sourceStream = $null
    $destinationStream = $null
    $opened = $null
    $sourceIdentity = $null
    $sourceBoundary = $null
    $destinationBoundary = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($TrustedDestinationRoot)) {
            $destinationBoundary = Assert-HerdrPhysicalPathUnderRoot -CandidatePath $parent -RootPath $TrustedDestinationRoot `
                -AllowEqual -Description 'Copy destination boundary'
            if (-not $destinationBoundary.Candidate.Leaf.IsDirectory) { throw 'Copy destination parent is not a directory.' }
        }
        else {
            $destinationParentProof = Get-HerdrPhysicalPathProof -Path $parent
            if (-not $destinationParentProof.Leaf.IsDirectory) { throw 'Copy destination parent is not a directory.' }
        }
        if (-not [string]::IsNullOrWhiteSpace($TrustedRoot)) {
            $sourceBoundary = Assert-HerdrPhysicalPathUnderRoot -CandidatePath $source -RootPath $TrustedRoot -Description 'Copy source boundary'
        }
        if ($IsWindows) {
            $opened = Open-HerdrNativeReadFile -Path $source
            $sourceIdentity = $opened.Identity
            if ($null -ne $ExpectedSourceIdentity) {
                Compare-HerdrPhysicalIdentity -Expected $ExpectedSourceIdentity -Actual $sourceIdentity -Description 'Copy source' -IncludeLinkCount | Out-Null
            }
            $sourceStream = [IO.FileStream]::new($opened.SafeHandle, [IO.FileAccess]::Read, 1048576, $false)
        }
        else {
            $sourceStream = [IO.FileStream]::new($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None, 1048576, [IO.FileOptions]::SequentialScan)
            $sourceIdentity = [pscustomobject][ordered]@{
                Exists = $true
                IsDirectory = $false
                Attributes = $null
                VolumeSerialNumber = $null
                FileIndex = $null
                NumberOfLinks = [int64]1
                FileIdentity = $null
            }
            if ($null -ne $ExpectedSourceIdentity) {
                Compare-HerdrPhysicalIdentity -Expected $ExpectedSourceIdentity -Actual $sourceIdentity -Description 'Copy source' -IncludeLinkCount | Out-Null
            }
        }
        $destinationStream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 1048576, [IO.FileOptions]::SequentialScan)
        $sourceStream.CopyTo($destinationStream, 1048576)
        $destinationStream.Flush($true)
        if (-not [string]::IsNullOrWhiteSpace($TrustedDestinationRoot)) {
            Assert-HerdrPhysicalPathUnderRoot -CandidatePath $parent -RootPath $TrustedDestinationRoot `
                -ExpectedRoot $destinationBoundary.Root -AllowEqual -Description 'Copy destination boundary before commit' | Out-Null
        }
        else {
            $destinationParentProof = Get-HerdrPhysicalPathProof -Path $parent
            if (-not $destinationParentProof.Leaf.IsDirectory) { throw 'Copy destination parent changed to a non-directory.' }
        }
    }
    catch {
        throw "Exclusive workbook copy failed: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $destinationStream) { $destinationStream.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
        if ($null -ne $opened -and $null -ne $opened.SafeHandle -and -not $opened.SafeHandle.IsClosed) { $opened.SafeHandle.Dispose() }
    }
    if ($null -ne $sourceIdentity) {
        $sourceAfter = Get-HerdrPhysicalPathProof -Path $source
        Compare-HerdrPhysicalIdentity -Expected $sourceIdentity -Actual $sourceAfter.Leaf -Description 'Copy source after read' -IncludeLinkCount | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($TrustedRoot)) {
            Assert-HerdrPhysicalPathUnderRoot -CandidatePath $source -RootPath $TrustedRoot `
                -ExpectedCandidate $sourceIdentity -ExpectedRoot $sourceBoundary.Root `
                -Description 'Copy source boundary after read' | Out-Null
        }
    }
    try {
        [IO.File]::Move($temporary, $destination)
    }
    catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        throw "Exclusive workbook copy could not be committed."
    }
    $destinationProof = Get-HerdrPhysicalPathProof -Path $destination
    if (-not [string]::IsNullOrWhiteSpace($TrustedDestinationRoot)) {
        Assert-HerdrPhysicalPathUnderRoot -CandidatePath $destination -RootPath $TrustedDestinationRoot `
            -ExpectedRoot $destinationBoundary.Root -Description 'Copy destination boundary after commit' | Out-Null
    }
    if (-not $destinationProof.Exists -or $destinationProof.Leaf.IsDirectory -or [int64]$destinationProof.Leaf.NumberOfLinks -gt 1) {
        throw "Exclusive workbook copy produced an unsafe destination: '$destination'."
    }
    return $destination
}

function Write-HerdrAtomicText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [string]$TrustedRoot
    )

    $destination = Get-HerdrCanonicalPath -Path $Path
    if (Test-Path -LiteralPath $destination) { throw "Output already exists: '$destination'." }
    $parent = Split-Path -Parent $destination
    $parentProof = Get-HerdrPhysicalPathProof -Path $parent
    if (-not $parentProof.Exists -or -not $parentProof.Leaf.IsDirectory) { throw "Output directory does not exist: '$parent'." }
    $boundaryBefore = $null
    if (-not [string]::IsNullOrWhiteSpace($TrustedRoot)) {
        $boundaryBefore = Assert-HerdrPhysicalPathUnderRoot -CandidatePath $parent -RootPath $TrustedRoot `
            -ExpectedCandidate $parentProof -AllowEqual -Description 'Atomic text destination boundary'
    }
    $temporary = Join-Path $parent ('.herdr-text-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
        $temporaryProof = Get-HerdrPhysicalPathProof -Path $temporary
        if (-not $temporaryProof.Exists -or $temporaryProof.Leaf.IsDirectory -or [int64]$temporaryProof.Leaf.NumberOfLinks -gt 1) {
            throw 'Atomic text temporary file is not a safe regular file.'
        }
        if (-not [string]::IsNullOrWhiteSpace($TrustedRoot)) {
            Assert-HerdrPhysicalPathUnderRoot -CandidatePath $temporary -RootPath $TrustedRoot `
                -ExpectedRoot $boundaryBefore.Root -Description 'Atomic text temporary boundary' | Out-Null
            Assert-HerdrPhysicalPathUnderRoot -CandidatePath $parent -RootPath $TrustedRoot `
                -ExpectedRoot $boundaryBefore.Root -AllowEqual -Description 'Atomic text destination boundary before commit' | Out-Null
        }
        else {
            $parentAfterWrite = Get-HerdrPhysicalPathProof -Path $parent
            Compare-HerdrPhysicalIdentity -Expected $parentProof -Actual $parentAfterWrite -Description 'Atomic text destination parent' | Out-Null
        }
        [IO.File]::Move($temporary, $destination)
    }
    catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        throw "Atomic text output could not be committed."
    }
    $destinationProof = Get-HerdrPhysicalPathProof -Path $destination
    if (-not [string]::IsNullOrWhiteSpace($TrustedRoot)) {
        Assert-HerdrPhysicalPathUnderRoot -CandidatePath $destination -RootPath $TrustedRoot `
            -ExpectedRoot $boundaryBefore.Root -Description 'Atomic text destination boundary after commit' | Out-Null
    }
    if (-not $destinationProof.Exists -or $destinationProof.Leaf.IsDirectory -or
        [int64]$destinationProof.Leaf.NumberOfLinks -gt 1) {
        throw "Atomic text output is not a safe regular file: '$destination'."
    }
    return $destination
}

function Invoke-HerdrReviewStaging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$OneDriveInboxRoot,
        [Parameter(Mandatory)][string]$ExchangeRoot,
        [string]$OneDriveOutboxRoot,
        [string]$OneDriveArchiveRoot,
        [string]$Repository = 'NOT-PROVIDED',
        [string]$Branch = 'NOT-PROVIDED',
        [string]$Commit = 'NOT-PROVIDED',
        [ValidateRange(0, 60000)][int]$StabilityIntervalMilliseconds = 1000,
        [scriptblock]$BetweenSourceReads
    )

    Assert-HerdrJobId -JobId $JobId | Out-Null
    Assert-HerdrMetadataValue -Value $Repository -Name 'Repository' | Out-Null
    Assert-HerdrMetadataValue -Value $Branch -Name 'Branch' | Out-Null
    Assert-HerdrMetadataValue -Value $Commit -Name 'Commit' | Out-Null
    $inboxRoot = Assert-HerdrConfiguredLocalPath -Path $OneDriveInboxRoot
    $exchangeRootCanonical = Assert-HerdrConfiguredLocalPath -Path $ExchangeRoot
    Assert-HerdrExistingPathIsNotReparsePoint -Path $inboxRoot | Out-Null
    $exchangeRootCanonical = Ensure-HerdrManagedDirectory -Path $exchangeRootCanonical -Description 'Exchange root'
    if ([string]::IsNullOrWhiteSpace($OneDriveOutboxRoot)) {
        $OneDriveOutboxRoot = Get-HerdrDefaultOneDriveSiblingRoot -InboxRoot $inboxRoot -Name Outbox
    }
    if ([string]::IsNullOrWhiteSpace($OneDriveArchiveRoot)) {
        $OneDriveArchiveRoot = Get-HerdrDefaultOneDriveSiblingRoot -InboxRoot $inboxRoot -Name Archive
    }
    $outboxRoot = Assert-HerdrConfiguredLocalPath -Path $OneDriveOutboxRoot
    $archiveRoot = Assert-HerdrConfiguredLocalPath -Path $OneDriveArchiveRoot
    Assert-HerdrExistingPathIsNotReparsePoint -Path $outboxRoot | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $archiveRoot | Out-Null
    Assert-HerdrPathDoesNotOverlap -Left $inboxRoot -Right $exchangeRootCanonical -Description 'OneDrive and exchange'
    Assert-HerdrPathDoesNotOverlap -Left $inboxRoot -Right $outboxRoot -Description 'OneDrive Inbox and Outbox'
    Assert-HerdrPathDoesNotOverlap -Left $inboxRoot -Right $archiveRoot -Description 'OneDrive Inbox and Archive'
    Assert-HerdrPathDoesNotOverlap -Left $outboxRoot -Right $archiveRoot -Description 'OneDrive Outbox and Archive'
    Assert-HerdrPathDoesNotOverlap -Left $exchangeRootCanonical -Right $outboxRoot -Description 'exchange and OneDrive Outbox'
    Assert-HerdrPathDoesNotOverlap -Left $exchangeRootCanonical -Right $archiveRoot -Description 'exchange and OneDrive Archive'
    $sourceCanonical = Get-HerdrCanonicalPath -Path $SourcePath
    if (-not (Test-HerdrPathSameOrDescendant -Candidate $sourceCanonical -Ancestor $inboxRoot) -or
        $sourceCanonical.Equals($inboxRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Source workbook is outside the configured OneDrive Inbox.'
    }
    $sourceBoundary = Assert-HerdrPhysicalPathUnderRoot -CandidatePath $sourceCanonical -RootPath $inboxRoot -Description 'OneDrive source'
    $sourceItem = Assert-HerdrWorkbookFile -Path $sourceCanonical
    $stageRoot = Ensure-HerdrManagedDirectory -Path (Join-Path $exchangeRootCanonical 'in') `
        -TrustedRoot $exchangeRootCanonical -Description 'Exchange input root'
    $jobDirectory = Get-HerdrCanonicalPath -Path (Join-Path $stageRoot $JobId)
    if (Test-Path -LiteralPath $jobDirectory) { throw "Staging collision for job '$JobId'." }
    $jobDirectory = Ensure-HerdrManagedDirectory -Path $jobDirectory -TrustedRoot $stageRoot -Description 'Staging job directory'
    $completed = $false
    try {
        $firstSnapshot = Get-HerdrFileSnapshot -Path $sourceCanonical -TrustedRoot $inboxRoot
        if ($null -ne $BetweenSourceReads) { & $BetweenSourceReads }
        if ($StabilityIntervalMilliseconds -gt 0) { Start-Sleep -Milliseconds $StabilityIntervalMilliseconds }
        $secondSnapshot = Get-HerdrFileSnapshot -Path $sourceCanonical -TrustedRoot $inboxRoot -ExpectedIdentity $firstSnapshot
        Assert-HerdrSnapshotsEqual -Expected $firstSnapshot -Actual $secondSnapshot -Description 'OneDrive source'
        $extension = [IO.Path]::GetExtension($sourceItem.Name).ToLowerInvariant()
        $stagedPath = Get-HerdrCanonicalPath -Path (Join-Path $jobDirectory ('input' + $extension))
        Copy-HerdrFileExclusive -SourcePath $sourceCanonical -DestinationPath $stagedPath `
            -TrustedRoot $inboxRoot -ExpectedSourceIdentity $firstSnapshot -TrustedDestinationRoot $jobDirectory | Out-Null
        $stagedSnapshot = Get-HerdrFileSnapshot -Path $stagedPath -TrustedRoot $jobDirectory
        Assert-HerdrSnapshotContentEqual -Expected $firstSnapshot -Actual $stagedSnapshot -Description 'Bridge staging copy'
        if (-not (Test-Path -LiteralPath $sourceCanonical -PathType Leaf)) {
            throw 'OneDrive source was not preserved after staging.'
        }
        Assert-HerdrPhysicalPathUnderRoot -CandidatePath $sourceCanonical -RootPath $inboxRoot `
            -ExpectedCandidate $firstSnapshot -ExpectedRoot $sourceBoundary.Root -Description 'Preserved OneDrive source' | Out-Null
        $manifestPath = Get-HerdrCanonicalPath -Path (Join-Path $jobDirectory 'staging-provenance.json')
        $manifest = [ordered]@{
            schema = 'herdr-review-staging-v1'
            job_id = $JobId
            created_utc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            stability_interval_milliseconds = $StabilityIntervalMilliseconds
            allowed_extensions = @(Get-HerdrWorkbookExtensionAllowlist)
            source_root = $inboxRoot
            one_drive_outbox_root = $outboxRoot
            one_drive_archive_root = $archiveRoot
            exchange_root = $exchangeRootCanonical
            staged_input_path = $stagedPath
            source = [ordered]@{
                path = $firstSnapshot.Path
                file_name = $sourceItem.Name
                extension = $extension
                captured_utc = $firstSnapshot.CapturedUtc
                size_bytes = $firstSnapshot.SizeBytes
                last_write_time_utc = $firstSnapshot.LastWriteTimeUtc
                sha256 = $firstSnapshot.Sha256
                volume_serial_number = $firstSnapshot.VolumeSerialNumber
                file_index = $firstSnapshot.FileIndex
                number_of_links = $firstSnapshot.NumberOfLinks
                file_identity = $firstSnapshot.FileIdentity
            }
            bridge_stage = [ordered]@{
                path = $stagedSnapshot.Path
                file_name = [IO.Path]::GetFileName($stagedPath)
                extension = $extension
                captured_utc = $stagedSnapshot.CapturedUtc
                size_bytes = $stagedSnapshot.SizeBytes
                last_write_time_utc = $stagedSnapshot.LastWriteTimeUtc
                sha256 = $stagedSnapshot.Sha256
                volume_serial_number = $stagedSnapshot.VolumeSerialNumber
                file_index = $stagedSnapshot.FileIndex
                number_of_links = $stagedSnapshot.NumberOfLinks
                file_identity = $stagedSnapshot.FileIdentity
            }
            provenance = [ordered]@{
                repository = $Repository
                branch = $Branch
                commit = $Commit
            }
            source_preserved = $true
        }
        $json = $manifest | ConvertTo-Json -Depth 8 -Compress
        Write-HerdrAtomicText -Path $manifestPath -Content $json -TrustedRoot $jobDirectory | Out-Null
        $completed = $true
        return [pscustomobject][ordered]@{
            Schema = $manifest.schema
            JobId = $JobId
            SourcePath = $firstSnapshot.Path
            SourceSha256 = $firstSnapshot.Sha256
            StagedPath = $stagedSnapshot.Path
            StagedSha256 = $stagedSnapshot.Sha256
            ManifestPath = $manifestPath
            SourcePreserved = $true
        }
    }
    finally {
        if (-not $completed -and (Test-Path -LiteralPath $jobDirectory)) {
            Remove-Item -LiteralPath $jobDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

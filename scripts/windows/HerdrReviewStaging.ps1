Set-StrictMode -Version Latest

if ($IsWindows -and $null -eq ('Herdr.Security.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.IO;

namespace Herdr.Security {
    public sealed class FileIdentity {
        public uint Attributes { get; set; }
        public uint ReparseTag { get; set; }
        public uint VolumeSerialNumber { get; set; }
        public ulong FileIndex { get; set; }
        public uint NumberOfLinks { get; set; }
    }

    public static class NativeMethods {
        public const uint GenericRead = 0x80000000;
        public const uint GenericWrite = 0x40000000;
        public const uint DeleteAccess = 0x00010000;
        public const uint WriteDac = 0x00040000;
        public const uint WriteOwner = 0x00080000;
        public const uint FileDeleteChild = 0x00000040;
        public const uint FileListDirectory = 0x00000001;
        public const uint FileAddSubdirectory = 0x00000004;
        public const uint FileTraverse = 0x00000020;
        public const uint FileReadAttributes = 0x00000080;
        public const uint Synchronize = 0x00100000;
        public const uint FileShareRead = 0x00000001;
        public const uint FileShareWrite = 0x00000002;
        public const uint FileShareDelete = 0x00000004;
        public const uint FileCreate = 2;
        public const uint FileOpen = 1;
        public const uint FileOpenIf = 3;
        public const uint FileDirectoryFile = 0x00000001;
        public const uint FileNonDirectoryFile = 0x00000040;
        public const uint FileSynchronousIoNonalert = 0x00000020;
        public const uint FileDeleteOnClose = 0x00001000;
        public const uint ObjectAttributesCaseInsensitive = 0x00000040;
        public const uint OpenExisting = 3;
        public const uint FileFlagOpenReparsePoint = 0x00200000;
        public const uint FileFlagBackupSemantics = 0x02000000;
        public const uint FileFlagSequentialScan = 0x08000000;
        public const uint FileAttributeReparsePoint = 0x00000400;
        private const int FileAttributeTagInfoClass = 9;
        public const uint InvalidHandleValue = 0xffffffff;
        public const uint ProcessQueryLimitedInformation = 0x1000;
        public const uint TokenQuery = 0x0008;
        public const int TokenUser = 1;
        private const int NativeFileRenameInformation = 10;
        private const int FileDispositionInformation = 4;
        private const uint MAXIMUM_ALLOWED = 0x02000000;
        private const uint EffectiveWriteMask = 0x000D0156;
        private const uint AUTHZ_RM_FLAG_NO_AUDIT = 0x1;

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

        [StructLayout(LayoutKind.Sequential)]
        private struct FileAttributeTagInformation {
            public uint FileAttributes;
            public uint ReparseTag;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct UnicodeString {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ObjectAttributes {
            public int Length;
            public IntPtr RootDirectory;
            public IntPtr ObjectName;
            public uint Attributes;
            public IntPtr SecurityDescriptor;
            public IntPtr SecurityQualityOfService;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoStatusBlock {
            public IntPtr Status;
            public IntPtr Information;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct AuthzAccessRequest {
            public uint DesiredAccess;
            public IntPtr PrincipalSelfSid;
            public IntPtr ObjectTypeList;
            public uint ObjectTypeListLength;
            public IntPtr OptionalArguments;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct AuthzAccessReply {
            public uint ResultListLength;
            public IntPtr GrantedAccessMask;
            public IntPtr SaclEvaluationResults;
            public IntPtr Error;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Luid {
            public uint LowPart;
            public int HighPart;
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

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandleEx(
            IntPtr fileHandle,
            int fileInformationClass,
            out FileAttributeTagInformation fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(
            IntPtr fileHandle,
            int fileInformationClass,
            IntPtr fileInformation,
            uint bufferSize);

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

        [DllImport("ntdll.dll")]
        private static extern int NtCreateFile(
            out IntPtr fileHandle,
            uint desiredAccess,
            ref ObjectAttributes objectAttributes,
            out IoStatusBlock ioStatusBlock,
            IntPtr allocationSize,
            uint fileAttributes,
            uint shareAccess,
            uint createDisposition,
            uint createOptions,
            IntPtr eaBuffer,
            uint eaLength);

        [DllImport("ntdll.dll")]
        private static extern int NtSetInformationFile(
            IntPtr fileHandle,
            out IoStatusBlock ioStatusBlock,
            IntPtr fileInformation,
            uint length,
            int fileInformationClass);

        [DllImport("ntdll.dll")]
        private static extern uint RtlNtStatusToDosError(int status);

        [DllImport("authz.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool AuthzInitializeResourceManager(
            uint flags,
            IntPtr accessCheck,
            IntPtr computeDynamicGroups,
            IntPtr getCentralAccessPolicy,
            string resourceManagerName,
            out IntPtr resourceManager);

        [DllImport("authz.dll", SetLastError = true)]
        private static extern bool AuthzInitializeContextFromSid(
            uint flags,
            IntPtr userSid,
            IntPtr resourceManager,
            IntPtr expirationTime,
            Luid identifier,
            IntPtr dynamicGroupArgs,
            out IntPtr clientContext);

        [DllImport("authz.dll", SetLastError = true)]
        private static extern bool AuthzAccessCheck(
            uint flags,
            IntPtr clientContext,
            ref AuthzAccessRequest accessRequest,
            IntPtr auditEventType,
            IntPtr securityDescriptor,
            IntPtr optionalSecurityDescriptorArray,
            uint optionalSecurityDescriptorCount,
            ref AuthzAccessReply accessReply,
            IntPtr accessCheckResults);

        [DllImport("authz.dll", SetLastError = true)]
        private static extern bool AuthzFreeContext(IntPtr clientContext);

        [DllImport("authz.dll", SetLastError = true)]
        private static extern bool AuthzFreeResourceManager(IntPtr resourceManager);

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

        private static void ThrowNtStatus(int status, string operation) {
            if (status >= 0) return;
            uint error = RtlNtStatusToDosError(status);
            throw new Win32Exception(unchecked((int)error), operation + " failed");
        }

        private static void ValidateRelativeName(string name) {
            if (String.IsNullOrWhiteSpace(name) || name == "." || name == ".." ||
                name.IndexOf('\\') >= 0 || name.IndexOf('/') >= 0) {
                throw new ArgumentException("A relative operation requires one path component.", "name");
            }
        }

        private static IntPtr OpenRelative(
            IntPtr parentHandle,
            string name,
            uint desiredAccess,
            uint shareAccess,
            uint createDisposition,
            uint createOptions) {
            if (parentHandle == IntPtr.Zero || parentHandle.ToInt64() == -1) {
                throw new ArgumentException("A valid parent directory handle is required.", "parentHandle");
            }
            ValidateRelativeName(name);
            IntPtr nameBuffer = Marshal.StringToHGlobalUni(name);
            IntPtr objectName = IntPtr.Zero;
            try {
                var unicodeName = new UnicodeString {
                    Length = checked((ushort)(name.Length * 2)),
                    MaximumLength = checked((ushort)(name.Length * 2 + 2)),
                    Buffer = nameBuffer
                };
                objectName = Marshal.AllocHGlobal(Marshal.SizeOf<UnicodeString>());
                Marshal.StructureToPtr(unicodeName, objectName, false);
                var attributes = new ObjectAttributes {
                    Length = Marshal.SizeOf<ObjectAttributes>(),
                    RootDirectory = parentHandle,
                    ObjectName = objectName,
                    Attributes = ObjectAttributesCaseInsensitive,
                    SecurityDescriptor = IntPtr.Zero,
                    SecurityQualityOfService = IntPtr.Zero
                };
                IntPtr handle;
                IoStatusBlock ioStatus;
                int status = NtCreateFile(
                    out handle,
                    desiredAccess,
                    ref attributes,
                    out ioStatus,
                    IntPtr.Zero,
                    0,
                    shareAccess,
                    createDisposition,
                    createOptions,
                    IntPtr.Zero,
                    0);
                ThrowNtStatus(status, "Relative path operation");
                return handle;
            }
            finally {
                if (objectName != IntPtr.Zero) Marshal.FreeHGlobal(objectName);
                Marshal.FreeHGlobal(nameBuffer);
            }
        }

        public static IntPtr OpenDirectoryForRelative(string path) {
            uint access = FileListDirectory | FileAddSubdirectory | FileTraverse | FileReadAttributes | Synchronize;
            uint flags = FileFlagOpenReparsePoint | FileFlagBackupSemantics;
            IntPtr handle = CreateFileW(
                path,
                access,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                flags,
                IntPtr.Zero);
            if (handle == IntPtr.Zero || handle.ToInt64() == -1) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Opening a relative-operation root failed");
            }
            return handle;
        }

        public static IntPtr OpenDirectoryRelative(IntPtr parentHandle, string name, bool createIfMissing) {
            uint access = FileListDirectory | FileAddSubdirectory | FileTraverse | FileReadAttributes | Synchronize;
            uint options = FileDirectoryFile | FileSynchronousIoNonalert | FileFlagOpenReparsePoint;
            return OpenRelative(parentHandle, name, access, FileShareRead | FileShareWrite,
                createIfMissing ? FileOpenIf : FileOpen, options);
        }

        public static IntPtr CreateDirectoryRelative(IntPtr parentHandle, string name) {
            uint access = FileListDirectory | FileAddSubdirectory | FileTraverse | FileReadAttributes | Synchronize;
            uint options = FileDirectoryFile | FileSynchronousIoNonalert | FileFlagOpenReparsePoint;
            return OpenRelative(parentHandle, name, access, FileShareRead | FileShareWrite, FileCreate, options);
        }

        public static IntPtr CreateFileRelative(IntPtr parentHandle, string name) {
            uint access = GenericWrite | DeleteAccess | Synchronize;
            uint options = FileNonDirectoryFile | FileSynchronousIoNonalert | FileFlagOpenReparsePoint;
            return OpenRelative(parentHandle, name, access, 0, FileCreate, options);
        }

        public static void RenameFileRelative(IntPtr fileHandle, IntPtr destinationParentHandle, string destinationName) {
            if (fileHandle == IntPtr.Zero || fileHandle.ToInt64() == -1) {
                throw new ArgumentException("A valid file handle is required.", "fileHandle");
            }
            if (destinationParentHandle == IntPtr.Zero || destinationParentHandle.ToInt64() == -1) {
                throw new ArgumentException("A valid destination directory handle is required.", "destinationParentHandle");
            }
            ValidateRelativeName(destinationName);
            int nameBytes = checked(destinationName.Length * 2);
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int lengthOffset = rootOffset + IntPtr.Size;
            int nameOffset = lengthOffset + 4;
            IntPtr buffer = Marshal.AllocHGlobal(nameOffset + nameBytes);
            IntPtr nameBuffer = Marshal.StringToHGlobalUni(destinationName);
            try {
                for (int index = 0; index < nameOffset + nameBytes; index++) Marshal.WriteByte(buffer, index, 0);
                Marshal.WriteIntPtr(buffer, rootOffset, destinationParentHandle);
                Marshal.WriteInt32(buffer, lengthOffset, nameBytes);
                byte[] nameBytesArray = new byte[nameBytes];
                Marshal.Copy(nameBuffer, nameBytesArray, 0, nameBytes);
                Marshal.Copy(nameBytesArray, 0, IntPtr.Add(buffer, nameOffset), nameBytes);
                IoStatusBlock ioStatus;
                int status = NtSetInformationFile(fileHandle, out ioStatus, buffer,
                    (uint)(nameOffset + nameBytes), NativeFileRenameInformation);
                ThrowNtStatus(status, "Handle-relative rename");
            }
            finally {
                Marshal.FreeHGlobal(nameBuffer);
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static void DeleteRelative(IntPtr parentHandle, string name, bool directory) {
            uint access = DeleteAccess | Synchronize | (directory ? FileListDirectory | FileReadAttributes : 0u);
            uint options = (directory ? FileDirectoryFile : FileNonDirectoryFile) |
                FileSynchronousIoNonalert | FileFlagOpenReparsePoint;
            IntPtr handle = OpenRelative(parentHandle, name, access,
                FileShareRead | FileShareWrite | FileShareDelete, FileOpen, options);
            try {
                IntPtr disposition = Marshal.AllocHGlobal(1);
                try {
                    Marshal.WriteByte(disposition, 0, 1);
                    if (!SetFileInformationByHandle(handle, FileDispositionInformation, disposition, 1)) {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Handle-relative delete failed");
                    }
                }
                finally {
                    Marshal.FreeHGlobal(disposition);
                }
            }
            finally {
                CloseHandle(handle);
            }
        }

        public static bool HasEffectiveWriteAccess(string userSid, byte[] securityDescriptor) {
            if (String.IsNullOrWhiteSpace(userSid)) throw new ArgumentException("A user SID is required.", "userSid");
            if (securityDescriptor == null || securityDescriptor.Length == 0) throw new ArgumentException("A security descriptor is required.", "securityDescriptor");
            var sid = new SecurityIdentifier(userSid);
            byte[] sidBytes = new byte[sid.BinaryLength];
            sid.GetBinaryForm(sidBytes, 0);
            GCHandle sidPin = GCHandle.Alloc(sidBytes, GCHandleType.Pinned);
            GCHandle descriptorPin = GCHandle.Alloc(securityDescriptor, GCHandleType.Pinned);
            IntPtr resourceManager = IntPtr.Zero;
            IntPtr clientContext = IntPtr.Zero;
            IntPtr granted = IntPtr.Zero;
            IntPtr saclResults = IntPtr.Zero;
            IntPtr errors = IntPtr.Zero;
            try {
                if (!AuthzInitializeResourceManager(AUTHZ_RM_FLAG_NO_AUDIT, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                    "HerdrBridge effective access", out resourceManager)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Authz resource manager initialization failed");
                }
                if (!AuthzInitializeContextFromSid(0, sidPin.AddrOfPinnedObject(), resourceManager,
                    IntPtr.Zero, new Luid(), IntPtr.Zero, out clientContext)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Authz bridge context initialization failed");
                }
                var request = new AuthzAccessRequest {
                    DesiredAccess = MAXIMUM_ALLOWED,
                    PrincipalSelfSid = IntPtr.Zero,
                    ObjectTypeList = IntPtr.Zero,
                    ObjectTypeListLength = 0,
                    OptionalArguments = IntPtr.Zero
                };
                granted = Marshal.AllocHGlobal(sizeof(uint));
                saclResults = Marshal.AllocHGlobal(sizeof(uint));
                errors = Marshal.AllocHGlobal(sizeof(uint));
                Marshal.WriteInt32(granted, 0);
                Marshal.WriteInt32(saclResults, 0);
                Marshal.WriteInt32(errors, 0);
                var reply = new AuthzAccessReply {
                    ResultListLength = 1,
                    GrantedAccessMask = granted,
                    SaclEvaluationResults = saclResults,
                    Error = errors
                };
                bool checkedAccess = AuthzAccessCheck(0, clientContext, ref request, IntPtr.Zero,
                    descriptorPin.AddrOfPinnedObject(), IntPtr.Zero, 0, ref reply, IntPtr.Zero);
                int apiError = checkedAccess ? 0 : Marshal.GetLastWin32Error();
                int resultError = Marshal.ReadInt32(errors);
                if (!checkedAccess && apiError != 5 && resultError != 5) {
                    throw new Win32Exception(apiError, "Authz effective access evaluation failed");
                }
                uint grantedMask = unchecked((uint)Marshal.ReadInt32(granted));
                return (grantedMask & EffectiveWriteMask) != 0;
            }
            finally {
                if (errors != IntPtr.Zero) Marshal.FreeHGlobal(errors);
                if (saclResults != IntPtr.Zero) Marshal.FreeHGlobal(saclResults);
                if (granted != IntPtr.Zero) Marshal.FreeHGlobal(granted);
                if (clientContext != IntPtr.Zero) AuthzFreeContext(clientContext);
                if (resourceManager != IntPtr.Zero) AuthzFreeResourceManager(resourceManager);
                descriptorPin.Free();
                sidPin.Free();
            }
        }

        public static FileIdentity ReadFileIdentity(IntPtr handle) {
            ByHandleFileInformation info;
            if (!GetFileInformationByHandle(handle, out info)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            FileAttributeTagInformation tagInfo;
            if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfoClass, out tagInfo,
                (uint)Marshal.SizeOf<FileAttributeTagInformation>())) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Reading file reparse metadata failed");
            }
            return new FileIdentity {
                Attributes = info.FileAttributes,
                ReparseTag = tagInfo.ReparseTag,
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
        $pathRoot = [IO.Path]::GetPathRoot($fullPath)
        if (-not [string]::IsNullOrWhiteSpace($pathRoot) -and
            $fullPath.Equals($pathRoot, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
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
        if ($value -notmatch '^[A-Za-z]:\\') {
            throw "Windows resolved a non-local extended-length path: '$Path'."
        }
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
        ReparseTag = $null
        VolumeSerialNumber = $null
        FileIndex = $null
        NumberOfLinks = [int64]1
        FileIdentity = $null
    }
}

function Test-HerdrCloudFilesReparseTag {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uint32]$ReparseTag)

    # IO_REPARSE_TAG_CLOUD through IO_REPARSE_TAG_CLOUD_F differ only in the
    # four Cloud Files variant bits (0x0000F000). Keep the Microsoft Cloud
    # Files family narrow; OneDrive, links, junctions, mount points, and all
    # other reparse tags remain denied by this policy.
    $cloudFilesBaseTag = [Convert]::ToUInt32('9000001A', 16)
    $cloudFilesVariantMask = [Convert]::ToUInt32('FFFF0FFF', 16)
    return (($ReparseTag -band $cloudFilesVariantMask) -eq $cloudFilesBaseTag)
}

function Assert-HerdrAllowedReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uint32]$ReparseTag,
        [Parameter(Mandatory)][bool]$IsDirectory,
        [Parameter(Mandatory)][string]$ComponentPath,
        [Parameter(Mandatory)][string]$CandidatePath,
        [string]$AllowedCloudFilesRoot
    )

    $isCloudFilesTag = Test-HerdrCloudFilesReparseTag -ReparseTag $ReparseTag
    $tagDescription = if ($isCloudFilesTag) {
        'Cloud Files'
    }
    elseif ($ReparseTag -eq [Convert]::ToUInt32('A000000C', 16)) {
        'symbolic-link'
    }
    elseif ($ReparseTag -eq [Convert]::ToUInt32('A0000003', 16)) {
        'junction or mount-point'
    }
    else {
        'unrecognized'
    }
    if (-not $isCloudFilesTag) {
        if (-not $IsDirectory) {
            throw "Refusing $tagDescription reparse point on a non-directory path component: '$ComponentPath'."
        }
        throw "Refusing $tagDescription reparse point with tag 0x{0:x8}: '$ComponentPath'." -f $ReparseTag
    }
    # A recognized Cloud Files file leaf is permitted only inside the explicit
    # boundary below; symbolic links, junctions, mount points, and unknown
    # reparse tags remain denied by the branch above.
    if ([string]::IsNullOrWhiteSpace($AllowedCloudFilesRoot)) {
        throw "Refusing Cloud Files reparse point outside a configured OneDrive exchange boundary: '$ComponentPath'."
    }
    $candidateCanonical = Get-HerdrCanonicalPath -Path $CandidatePath
    $boundaryCanonical = Get-HerdrCanonicalPath -Path $AllowedCloudFilesRoot
    $componentCanonical = Get-HerdrCanonicalPath -Path $ComponentPath
    $componentOnBoundaryPath =
        (Test-HerdrPathSameOrDescendant -Candidate $componentCanonical -Ancestor $boundaryCanonical) -or
        (Test-HerdrPathSameOrDescendant -Candidate $boundaryCanonical -Ancestor $componentCanonical)
    if (-not (Test-HerdrPathSameOrDescendant -Candidate $candidateCanonical -Ancestor $boundaryCanonical) -or
        -not $componentOnBoundaryPath) {
        throw "Cloud Files reparse point is outside the configured OneDrive exchange boundary: '$ComponentPath'."
    }
    return $true
}

function Get-HerdrPhysicalPathProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissingLeaf,
        [object]$ExistingLeafHandle,
        [string]$AllowedCloudFilesRoot
    )

    $canonical = Get-HerdrCanonicalPath -Path $Path
    # This optional root scopes Cloud Files reparse-tag admission below. It is
    # not a lexical or physical containment root; those checks belong to the
    # dedicated trusted-root and exchange-boundary callers.
    $allowedCloudFilesRootCanonical = if ([string]::IsNullOrWhiteSpace($AllowedCloudFilesRoot)) {
        $null
    }
    else {
        Get-HerdrCanonicalPath -Path $AllowedCloudFilesRoot
    }
    if ($null -ne $ExistingLeafHandle) {
        if (-not $IsWindows) { throw 'An existing native leaf handle is available only on Windows.' }
        if ($null -eq $ExistingLeafHandle.SafeHandle -or
            $ExistingLeafHandle.SafeHandle.IsClosed -or
            $ExistingLeafHandle.SafeHandle.IsInvalid) {
            throw "The existing native leaf handle is closed: '$canonical'."
        }
        $handlePath = Get-HerdrCanonicalPath -Path ([string]$ExistingLeafHandle.Path)
        if (-not $handlePath.Equals($canonical, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The existing native leaf handle does not belong to '$canonical'."
        }
    }
    $ancestors = [Collections.Generic.List[object]]::new()
    $leafExists = $true
    $leafIdentity = $null
    $leafFinalPath = $null
    $components = @(Get-HerdrPathComponents -Path $canonical)

    if ($IsWindows) {
        for ($index = 0; $index -lt $components.Count; $index++) {
            $component = [string]$components[$index]
            if ($null -ne $ExistingLeafHandle -and $index -eq ($components.Count - 1)) {
                if ($ancestors.Count -eq 0) { throw "The existing native leaf handle has no parent: '$canonical'." }
                $identity = [Herdr.Security.NativeMethods]::ReadFileIdentity(
                    $ExistingLeafHandle.SafeHandle.DangerousGetHandle())
                if (($identity.Attributes -band [Herdr.Security.NativeMethods]::FileAttributeReparsePoint) -ne 0) {
                    Assert-HerdrAllowedReparsePoint -ReparseTag $identity.ReparseTag -IsDirectory:$false `
                        -ComponentPath $component -CandidatePath $canonical -AllowedCloudFilesRoot $allowedCloudFilesRootCanonical | Out-Null
                }
                if ([int64]$identity.NumberOfLinks -gt 1) {
                    throw "Path component has multiple hard links: '$component'."
                }
                $finalPath = ConvertTo-HerdrFinalPath -Path (
                    [Herdr.Security.NativeMethods]::ReadFinalPath($ExistingLeafHandle.SafeHandle.DangerousGetHandle()))
                $parentFinalPath = [string]$ancestors[$ancestors.Count - 1].FinalPath
                $expectedFinalPath = Get-HerdrCanonicalPath -Path (Join-Path -Path $parentFinalPath `
                    -ChildPath ([IO.Path]::GetFileName($canonical)))
                if (-not $finalPath.Equals($expectedFinalPath, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "The existing native leaf handle no longer matches '$canonical'."
                }
                $record = [pscustomobject][ordered]@{
                    LexicalPath = Get-HerdrCanonicalPath -Path $component
                    FinalPath = $finalPath
                    IsDirectory = $false
                    Attributes = [int64]$identity.Attributes
                    ReparseTag = [uint32]$identity.ReparseTag
                    VolumeSerialNumber = [uint64]$identity.VolumeSerialNumber
                    FileIndex = [uint64]$identity.FileIndex
                    NumberOfLinks = [uint64]$identity.NumberOfLinks
                    FileIdentity = '{0:x8}:{1:x16}' -f $identity.VolumeSerialNumber, $identity.FileIndex
                }
                $null = $ancestors.Add($record)
                $leafIdentity = $record
                $leafFinalPath = $finalPath
                continue
            }
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
                    Assert-HerdrAllowedReparsePoint -ReparseTag $identity.ReparseTag -IsDirectory:$isDirectory `
                        -ComponentPath $component -CandidatePath $canonical -AllowedCloudFilesRoot $allowedCloudFilesRootCanonical | Out-Null
                }
                $finalPath = ConvertTo-HerdrFinalPath -Path ([Herdr.Security.NativeMethods]::ReadFinalPath($rawHandle))
                $record = [pscustomobject][ordered]@{
                    LexicalPath = Get-HerdrCanonicalPath -Path $component
                    FinalPath = $finalPath
                    IsDirectory = $isDirectory
                    Attributes = [int64]$identity.Attributes
                    ReparseTag = [uint32]$identity.ReparseTag
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
                ReparseTag = $identity.ReparseTag
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
    if ($expectedIdentity.PSObject.Properties['ReparseTag'] -and $actualIdentity.PSObject.Properties['ReparseTag'] -and
        [uint32]$expectedIdentity.ReparseTag -ne [uint32]$actualIdentity.ReparseTag) {
        throw "$Description reparse tag changed."
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
        [switch]$AllowEqual,
        [object]$ExistingCandidateHandle,
        [string]$AllowedCloudFilesRoot
    )

    $rootProof = Get-HerdrPhysicalPathProof -Path $RootPath -AllowedCloudFilesRoot $AllowedCloudFilesRoot
    $candidateProof = if ($null -eq $ExistingCandidateHandle) {
        Get-HerdrPhysicalPathProof -Path $CandidatePath -AllowedCloudFilesRoot $AllowedCloudFilesRoot
    }
    else {
        Get-HerdrPhysicalPathProof -Path $CandidatePath -ExistingLeafHandle $ExistingCandidateHandle `
            -AllowedCloudFilesRoot $AllowedCloudFilesRoot
    }
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
        [string]$Description = 'Managed directory',
        [switch]$RequireLeafCreation,
        [string]$AllowedCloudFilesRoot
    )

    $canonical = Get-HerdrCanonicalPath -Path $Path
    $trustedRootCanonical = if ([string]::IsNullOrWhiteSpace($TrustedRoot)) { $null } else { Get-HerdrCanonicalPath -Path $TrustedRoot }
    if ($IsWindows) {
        $operationRoot = if ($null -eq $trustedRootCanonical) { [IO.Path]::GetPathRoot($canonical) } else { $trustedRootCanonical }
        $chain = Open-HerdrNativeDirectoryChain -RootPath $operationRoot -TargetPath $canonical `
            -CreateMissing -RequireLeafCreation:$RequireLeafCreation -Description $Description `
            -AllowedCloudFilesRoot $AllowedCloudFilesRoot
        try {
            $nativeIdentity = [Herdr.Security.NativeMethods]::ReadFileIdentity($chain.SafeHandle.DangerousGetHandle())
            if (($nativeIdentity.Attributes -band [Herdr.Security.NativeMethods]::FileAttributeReparsePoint) -ne 0) {
                Assert-HerdrAllowedReparsePoint -ReparseTag $nativeIdentity.ReparseTag -IsDirectory:$true `
                    -ComponentPath $canonical -CandidatePath $canonical -AllowedCloudFilesRoot $AllowedCloudFilesRoot | Out-Null
            }
            $proof = Get-HerdrPhysicalPathProof -Path $canonical -AllowedCloudFilesRoot $AllowedCloudFilesRoot
            if (-not $proof.Exists -or -not $proof.Leaf.IsDirectory) {
                throw "$Description is not a directory: '$canonical'."
            }
            $chainIdentity = [pscustomobject][ordered]@{
                Exists = $true
                IsDirectory = $true
                Attributes = [int64]$nativeIdentity.Attributes
                ReparseTag = [uint32]$nativeIdentity.ReparseTag
                VolumeSerialNumber = [uint64]$nativeIdentity.VolumeSerialNumber
                FileIndex = [uint64]$nativeIdentity.FileIndex
                NumberOfLinks = [uint64]$nativeIdentity.NumberOfLinks
                FileIdentity = '{0:x8}:{1:x16}' -f $nativeIdentity.VolumeSerialNumber, $nativeIdentity.FileIndex
            }
            Compare-HerdrPhysicalIdentity -Expected $chainIdentity -Actual $proof.Leaf -Description $Description -IncludeLinkCount | Out-Null
            return $canonical
        }
        finally {
            $chain.SafeHandle.Dispose()
        }
    }
    $trustedRootProof = if ($null -eq $trustedRootCanonical) { $null } else {
        Get-HerdrPhysicalPathProof -Path $trustedRootCanonical -AllowedCloudFilesRoot $AllowedCloudFilesRoot
    }
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
                Assert-HerdrPhysicalPathUnderRoot -CandidatePath $componentPath -RootPath $trustedRootCanonical -Description $Description `
                    -AllowedCloudFilesRoot $AllowedCloudFilesRoot | Out-Null
            }
            else {
                Get-HerdrPhysicalPathProof -Path $componentPath -AllowedCloudFilesRoot $AllowedCloudFilesRoot | Out-Null
            }
            continue
        }
        $parent = Split-Path -Parent $componentPath
        if ($null -ne $trustedRootCanonical) {
            Assert-HerdrPhysicalPathUnderRoot -CandidatePath $parent -RootPath $trustedRootCanonical -AllowEqual `
                -Description "$Description parent" -AllowedCloudFilesRoot $AllowedCloudFilesRoot | Out-Null
        }
        else {
            Get-HerdrPhysicalPathProof -Path $parent -AllowedCloudFilesRoot $AllowedCloudFilesRoot | Out-Null
        }
        [IO.Directory]::CreateDirectory($componentPath) | Out-Null
        $createdProof = Get-HerdrPhysicalPathProof -Path $componentPath -AllowedCloudFilesRoot $AllowedCloudFilesRoot
        if (-not $createdProof.Leaf.IsDirectory) { throw "$Description is not a directory: '$componentPath'." }
    }
    if ($null -ne $trustedRootCanonical -and
        -not $canonical.Equals($trustedRootCanonical, [StringComparison]::OrdinalIgnoreCase)) {
        $boundary = Assert-HerdrPhysicalPathUnderRoot -CandidatePath $canonical -RootPath $trustedRootCanonical `
            -ExpectedRoot $trustedRootProof -Description $Description -AllowedCloudFilesRoot $AllowedCloudFilesRoot
        $candidateProof = $boundary.Candidate
    }
    else {
        $candidateProof = Get-HerdrPhysicalPathProof -Path $canonical -AllowedCloudFilesRoot $AllowedCloudFilesRoot
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
        [switch]$AllowMissing,
        [string]$AllowedCloudFilesRoot
    )

    $canonicalPath = Get-HerdrCanonicalPath -Path $Path
    $proof = Get-HerdrPhysicalPathProof -Path $canonicalPath -AllowMissingLeaf:$AllowMissing `
        -AllowedCloudFilesRoot $AllowedCloudFilesRoot
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

function Get-HerdrRuntimeString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$Name
    )

    $property = $Document.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Host-owned runtime configuration is missing '$Name'."
    }
    return [string]$property.Value
}

function Get-HerdrRuntimeConfiguration {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = $env:HERDR_WINDOWS_REVIEW_CONFIG }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'A host-owned runtime configuration is required; pass -RuntimeConfigurationPath or set HERDR_WINDOWS_REVIEW_CONFIG.'
    }
    $configurationPath = Get-HerdrCanonicalPath -Path $Path
    if (-not (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
        throw "Host-owned runtime configuration does not exist: '$configurationPath'."
    }
    $configurationItem = Get-Item -LiteralPath $configurationPath -Force -ErrorAction Stop
    if (($configurationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Host-owned runtime configuration must not be a reparse point: '$configurationPath'."
    }
    try {
        $document = [IO.File]::ReadAllText($configurationPath) | ConvertFrom-Json
    }
    catch {
        throw "Host-owned runtime configuration is not valid JSON: '$configurationPath'."
    }
    if ($null -eq $document -or $document -is [Array]) {
        throw 'Host-owned runtime configuration must be one JSON object.'
    }
    $allowed = @(
        'schema', 'approved', 'one_drive_exchange_root', 'one_drive_account',
        'exchange_root', 'review_jobs_root', 'tools_root',
        'designated_interactive_user_sid', 'designated_interactive_session_id',
        'bridge_account_sid'
    )
    foreach ($property in @($document.PSObject.Properties)) {
        if ($property.Name -notin $allowed) {
            throw "Host-owned runtime configuration contains unknown field '$($property.Name)'."
        }
    }
    if ((Get-HerdrRuntimeString -Document $document -Name 'schema') -cne 'herdr-windows-review-runtime-v1') {
        throw 'Host-owned runtime configuration schema is unsupported.'
    }
    $approvedProperty = $document.PSObject.Properties['approved']
    if ($null -eq $approvedProperty -or $approvedProperty.Value -isnot [bool] -or $approvedProperty.Value -ne $true) {
        throw 'Host-owned runtime configuration is not explicitly approved.'
    }
    $oneDriveExchangeRoot = Assert-HerdrConfiguredLocalPath -Path (Get-HerdrRuntimeString -Document $document -Name 'one_drive_exchange_root')
    $exchangeRoot = Assert-HerdrConfiguredLocalPath -Path (Get-HerdrRuntimeString -Document $document -Name 'exchange_root')
    $reviewJobsRoot = Assert-HerdrConfiguredLocalPath -Path (Get-HerdrRuntimeString -Document $document -Name 'review_jobs_root')
    $toolsRoot = Assert-HerdrConfiguredLocalPath -Path (Get-HerdrRuntimeString -Document $document -Name 'tools_root')
    $oneDriveAccount = Assert-HerdrMetadataValue -Value (Get-HerdrRuntimeString -Document $document -Name 'one_drive_account') -Name 'OneDrive account'
    if ($oneDriveAccount -match '^<.*>$') { throw 'OneDrive account must be supplied by host-owned runtime configuration.' }
    $interactiveUserSid = Get-HerdrRuntimeString -Document $document -Name 'designated_interactive_user_sid'
    $bridgeAccountSid = Get-HerdrRuntimeString -Document $document -Name 'bridge_account_sid'
    if ($interactiveUserSid -notmatch '^S-\d-\d+(?:-\d+)+$') { throw 'Configured designated interactive user SID is invalid.' }
    if ($bridgeAccountSid -notmatch '^S-\d-\d+(?:-\d+)+$') { throw 'Configured bridge account SID is invalid.' }
    $sessionText = Get-HerdrRuntimeString -Document $document -Name 'designated_interactive_session_id'
    $interactiveSessionId = 0
    if (-not [int]::TryParse($sessionText, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$interactiveSessionId) -or $interactiveSessionId -le 0) {
        throw 'Configured designated interactive session ID must be a positive integer.'
    }

    $oneDriveInboxRoot = Get-HerdrCanonicalPath -Path (Join-Path $oneDriveExchangeRoot 'Inbox')
    $oneDriveOutboxRoot = Get-HerdrCanonicalPath -Path (Join-Path $oneDriveExchangeRoot 'Outbox')
    $oneDriveArchiveRoot = Get-HerdrCanonicalPath -Path (Join-Path $oneDriveExchangeRoot 'Archive')
    $pathRecords = @(
        [pscustomobject]@{ Name = 'OneDrive exchange'; Path = $oneDriveExchangeRoot },
        [pscustomobject]@{ Name = 'local exchange'; Path = $exchangeRoot },
        [pscustomobject]@{ Name = 'review jobs'; Path = $reviewJobsRoot },
        [pscustomobject]@{ Name = 'tools'; Path = $toolsRoot }
    )
    for ($leftIndex = 0; $leftIndex -lt $pathRecords.Count; $leftIndex++) {
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $pathRecords.Count; $rightIndex++) {
            if ((Test-HerdrPathSameOrDescendant -Candidate $pathRecords[$leftIndex].Path -Ancestor $pathRecords[$rightIndex].Path) -or
                (Test-HerdrPathSameOrDescendant -Candidate $pathRecords[$rightIndex].Path -Ancestor $pathRecords[$leftIndex].Path)) {
                throw "Host-owned runtime configuration paths overlap: $($pathRecords[$leftIndex].Name) and $($pathRecords[$rightIndex].Name)."
            }
        }
    }
    foreach ($managedPath in $pathRecords) {
        if (Test-HerdrPathSameOrDescendant -Candidate $configurationPath -Ancestor $managedPath.Path) {
            throw "Host-owned runtime configuration must be outside the configured $($managedPath.Name) root."
        }
    }
    [pscustomobject][ordered]@{
        Schema = 'herdr-windows-review-runtime-v1'
        ConfigurationPath = $configurationPath
        Approved = $true
        OneDriveExchangeRoot = $oneDriveExchangeRoot
        OneDriveAccount = $oneDriveAccount
        OneDriveInboxRoot = $oneDriveInboxRoot
        OneDriveOutboxRoot = $oneDriveOutboxRoot
        OneDriveArchiveRoot = $oneDriveArchiveRoot
        ExchangeRoot = $exchangeRoot
        ReviewJobsRoot = $reviewJobsRoot
        ToolsRoot = $toolsRoot
        DesignatedInteractiveUserSid = $interactiveUserSid
        DesignatedInteractiveSessionId = $interactiveSessionId
        BridgeAccountSid = $bridgeAccountSid
    }
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
    param(
        [Parameter(Mandatory)][object]$Attributes,
        [uint32]$ReparseTag = 0,
        [string]$ComponentPath,
        [string]$CandidatePath,
        [string]$AllowedCloudFilesRoot
    )

    $blockedAttributes = [ordered]@{
        Offline = [int64]0x1000
        ReparsePoint = [int64][IO.FileAttributes]::ReparsePoint
        RecallOnOpen = [int64]0x40000
        RecallOnDataAccess = [int64]0x400000
    }
    $allowCloudFilesReparsePoint = $false
    if (([int64]$Attributes -band [int64][IO.FileAttributes]::ReparsePoint) -ne 0 -and
        (Test-HerdrCloudFilesReparseTag -ReparseTag $ReparseTag) -and
        -not [string]::IsNullOrWhiteSpace($ComponentPath) -and
        -not [string]::IsNullOrWhiteSpace($CandidatePath) -and
        -not [string]::IsNullOrWhiteSpace($AllowedCloudFilesRoot)) {
        try {
            Assert-HerdrAllowedReparsePoint -ReparseTag $ReparseTag -IsDirectory:$false `
                -ComponentPath $ComponentPath -CandidatePath $CandidatePath `
                -AllowedCloudFilesRoot $AllowedCloudFilesRoot | Out-Null
            $allowCloudFilesReparsePoint = $true
        }
        catch {
            $allowCloudFilesReparsePoint = $false
        }
    }
    return @(
        foreach ($entry in $blockedAttributes.GetEnumerator()) {
            if (([int64]$Attributes -band $entry.Value) -ne 0 -and
                ($entry.Key -ne 'ReparsePoint' -or -not $allowCloudFilesReparsePoint)) {
                $entry.Key
            }
        }
    )
}

function Assert-HerdrWorkbookFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$AllowedCloudFilesRoot
    )

    $proof = Get-HerdrPhysicalPathProof -Path $Path -AllowedCloudFilesRoot $AllowedCloudFilesRoot
    if (-not $proof.Exists -or $null -eq $proof.Leaf -or $proof.Leaf.IsDirectory) {
        throw 'Workbook source must be a regular file.'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -and $item.Length -ge 0) {
        $extension = [IO.Path]::GetExtension($item.Name).ToLowerInvariant()
        if ($extension -notin (Get-HerdrWorkbookExtensionAllowlist)) {
            throw "Workbook extension '$extension' is not allowed."
        }
        $blocked = @(Get-HerdrBlockedAttributeNames -Attributes $item.Attributes `
            -ReparseTag ([uint32]$proof.Leaf.ReparseTag) -ComponentPath ([string]$proof.Leaf.LexicalPath) `
            -CandidatePath $Path -AllowedCloudFilesRoot $AllowedCloudFilesRoot)
        if ($blocked.Count -gt 0) {
            throw "Workbook is not fully hydrated; blocked attributes: $($blocked -join ', ')."
        }
        return $item
    }
    throw 'Workbook source must be a regular file.'
}

function Open-HerdrNativeReadFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$AllowedCloudFilesRoot
    )

    if (-not $IsWindows) { throw 'Native file handles are available only on Windows.' }
    $canonical = Get-HerdrCanonicalPath -Path $Path
    $rawHandle = [Herdr.Security.NativeMethods]::OpenPath($canonical, $false, $true)
    $safeHandle = $null
    try {
        $safeHandle = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new($rawHandle, $true)
        $identity = [Herdr.Security.NativeMethods]::ReadFileIdentity($rawHandle)
        if (($identity.Attributes -band [Herdr.Security.NativeMethods]::FileAttributeReparsePoint) -ne 0) {
            Assert-HerdrAllowedReparsePoint -ReparseTag ([uint32]$identity.ReparseTag) -IsDirectory:$false `
                -ComponentPath $canonical -CandidatePath $canonical `
                -AllowedCloudFilesRoot $AllowedCloudFilesRoot | Out-Null
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
                ReparseTag = [uint32]$identity.ReparseTag
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

function Get-HerdrRelativeChildNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$TargetPath
    )

    $rootComponents = @(Get-HerdrPathComponents -Path $RootPath)
    $targetComponents = @(Get-HerdrPathComponents -Path $TargetPath)
    if ($targetComponents.Count -lt $rootComponents.Count) {
        throw "Target path is outside the trusted root: '$TargetPath'."
    }
    for ($index = 0; $index -lt $rootComponents.Count; $index++) {
        if (-not ([string]$targetComponents[$index]).Equals([string]$rootComponents[$index], [StringComparison]::OrdinalIgnoreCase)) {
            throw "Target path is outside the trusted root: '$TargetPath'."
        }
    }
    $names = [Collections.Generic.List[string]]::new()
    for ($index = $rootComponents.Count; $index -lt $targetComponents.Count; $index++) {
        $name = [IO.Path]::GetFileName([string]$targetComponents[$index])
        if ([string]::IsNullOrWhiteSpace($name)) { throw "Target path contains an invalid relative component: '$TargetPath'." }
        $null = $names.Add($name)
    }
    return @($names)
}

function Open-HerdrNativeDirectoryChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [switch]$CreateMissing,
        [switch]$RequireLeafCreation,
        [string]$Description = 'Directory',
        [string]$AllowedCloudFilesRoot
    )

    if (-not $IsWindows) { throw 'Handle-relative directory operations are Windows-only.' }
    $root = Get-HerdrCanonicalPath -Path $RootPath
    $target = Get-HerdrCanonicalPath -Path $TargetPath
    if (-not (Test-HerdrPathSameOrDescendant -Candidate $target -Ancestor $root)) {
        throw "$Description is outside the trusted physical root: '$target'."
    }
    $rootProof = Get-HerdrPhysicalPathProof -Path $root -AllowedCloudFilesRoot $AllowedCloudFilesRoot
    if (-not $rootProof.Exists -or -not $rootProof.Leaf.IsDirectory) { throw "$Description root is not a directory: '$root'." }
    $current = $null
    $rawHandle = [IntPtr]::Zero
    try {
        $rawHandle = [Herdr.Security.NativeMethods]::OpenDirectoryForRelative($root)
        $current = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new($rawHandle, $true)
        $rawHandle = [IntPtr]::Zero
        $rootNative = [Herdr.Security.NativeMethods]::ReadFileIdentity($current.DangerousGetHandle())
        if (($rootNative.Attributes -band [Herdr.Security.NativeMethods]::FileAttributeReparsePoint) -ne 0) {
            Assert-HerdrAllowedReparsePoint -ReparseTag $rootNative.ReparseTag -IsDirectory:$true `
                -ComponentPath $root -CandidatePath $target -AllowedCloudFilesRoot $AllowedCloudFilesRoot | Out-Null
        }
        $rootIdentity = [pscustomobject][ordered]@{
            Exists = $true
            IsDirectory = $true
            Attributes = [int64]$rootNative.Attributes
            ReparseTag = [uint32]$rootNative.ReparseTag
            VolumeSerialNumber = [uint64]$rootNative.VolumeSerialNumber
            FileIndex = [uint64]$rootNative.FileIndex
            NumberOfLinks = [uint64]$rootNative.NumberOfLinks
            FileIdentity = '{0:x8}:{1:x16}' -f $rootNative.VolumeSerialNumber, $rootNative.FileIndex
        }
        Compare-HerdrPhysicalIdentity -Expected $rootProof.Leaf -Actual $rootIdentity -Description "$Description root" -IncludeLinkCount | Out-Null
        $childNames = @(Get-HerdrRelativeChildNames -RootPath $root -TargetPath $target)
        $currentLexicalPath = $root
        $currentFinalPath = [string]$rootProof.FinalPath
        for ($childIndex = 0; $childIndex -lt $childNames.Count; $childIndex++) {
            $name = [string]$childNames[$childIndex]
            $isRequiredLeaf = $CreateMissing.IsPresent -and $RequireLeafCreation.IsPresent -and
                $childIndex -eq ($childNames.Count - 1)
            try {
                $childRaw = if ($isRequiredLeaf) {
                    [Herdr.Security.NativeMethods]::CreateDirectoryRelative($current.DangerousGetHandle(), $name)
                }
                else {
                    [Herdr.Security.NativeMethods]::OpenDirectoryRelative($current.DangerousGetHandle(), $name, $CreateMissing.IsPresent)
                }
            }
            catch {
                $nativeError = $_.Exception
                $collision = $false
                while ($null -ne $nativeError) {
                    if ($nativeError.PSObject.Properties['NativeErrorCode'] -and
                        [int]$nativeError.NativeErrorCode -in @(80, 183)) {
                        $collision = $true
                        break
                    }
                    $nativeError = $nativeError.InnerException
                }
                if ($isRequiredLeaf -and $collision) {
                    throw "$Description collision at '$target'."
                }
                throw
            }
            $child = $null
            try {
                $child = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new($childRaw, $true)
                $childRaw = [IntPtr]::Zero
                $childIdentity = [Herdr.Security.NativeMethods]::ReadFileIdentity($child.DangerousGetHandle())
                if (($childIdentity.Attributes -band [Herdr.Security.NativeMethods]::FileAttributeReparsePoint) -ne 0) {
                    Assert-HerdrAllowedReparsePoint -ReparseTag $childIdentity.ReparseTag -IsDirectory:$true `
                        -ComponentPath (Join-Path $currentLexicalPath $name) -CandidatePath $target `
                        -AllowedCloudFilesRoot $AllowedCloudFilesRoot | Out-Null
                }
                $childFinalPath = ConvertTo-HerdrFinalPath -Path (
                    [Herdr.Security.NativeMethods]::ReadFinalPath($child.DangerousGetHandle()))
                $expectedChildFinalPath = Get-HerdrCanonicalPath -Path (Join-Path $currentFinalPath $name)
                if (-not $childFinalPath.Equals($expectedChildFinalPath, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "$Description crossed an unexpected final path at '$name'."
                }
                if (-not (Test-HerdrPathSameOrDescendant -Candidate $childFinalPath -Ancestor $rootProof.FinalPath)) {
                    throw "$Description escaped its trusted physical root at '$name'."
                }
                $current.Dispose()
                $current = $child
                $child = $null
                $currentLexicalPath = Join-Path $currentLexicalPath $name
                $currentFinalPath = $childFinalPath
            }
            finally {
                if ($null -ne $child) { $child.Dispose() }
                if ($childRaw -ne [IntPtr]::Zero -and $childRaw.ToInt64() -ne -1) {
                    [void][Herdr.Security.NativeMethods]::CloseHandle($childRaw)
                }
            }
        }
        [pscustomobject][ordered]@{
            Path = $target
            SafeHandle = $current
            RootIdentity = $rootIdentity
        }
        $current = $null
    }
    catch {
        throw "$Description could not be opened with handle-relative no-follow semantics: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $current) { $current.Dispose() }
        if ($rawHandle -ne [IntPtr]::Zero -and $rawHandle.ToInt64() -ne -1) {
            [void][Herdr.Security.NativeMethods]::CloseHandle($rawHandle)
        }
    }
}

function Remove-HerdrNativeRelativeEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TrustedRoot,
        [switch]$Directory,
        [string]$AllowedCloudFilesRoot
    )

    if (-not $IsWindows) { throw 'Handle-relative cleanup is Windows-only.' }
    $canonical = Get-HerdrCanonicalPath -Path $Path
    $parent = Split-Path -Parent $canonical
    $leaf = Split-Path -Leaf $canonical
    $parentHandle = Open-HerdrNativeDirectoryChain -RootPath $TrustedRoot -TargetPath $parent `
        -Description 'Cleanup parent' -AllowedCloudFilesRoot $AllowedCloudFilesRoot
    try {
        [Herdr.Security.NativeMethods]::DeleteRelative($parentHandle.SafeHandle.DangerousGetHandle(), $leaf, $Directory.IsPresent)
    }
    catch [System.ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -notin @(2, 3, 53, 145)) { throw }
    }
    finally {
        if ($null -ne $parentHandle -and $null -ne $parentHandle.SafeHandle) { $parentHandle.SafeHandle.Dispose() }
    }
}

function Remove-HerdrManagedTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TrustedRoot,
        [string[]]$KnownFileNames = @(),
        [string]$AllowedCloudFilesRoot
    )

    $canonical = Get-HerdrCanonicalPath -Path $Path
    if (-not $IsWindows) {
        if (Test-Path -LiteralPath $canonical) { Remove-Item -LiteralPath $canonical -Recurse -Force -ErrorAction SilentlyContinue }
        return
    }
    foreach ($name in @($KnownFileNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        Remove-HerdrNativeRelativeEntry -Path (Join-Path $canonical $name) -TrustedRoot $TrustedRoot `
            -AllowedCloudFilesRoot $AllowedCloudFilesRoot
    }
    Remove-HerdrNativeRelativeEntry -Path $canonical -TrustedRoot $TrustedRoot -Directory `
        -AllowedCloudFilesRoot $AllowedCloudFilesRoot
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
        [object]$ExpectedIdentity,
        [string]$AllowedCloudFilesRoot
    )

    $canonicalPath = Get-HerdrCanonicalPath -Path $Path
    $boundaryBefore = $null
    if (-not [string]::IsNullOrWhiteSpace($TrustedRoot)) {
        $boundaryBefore = Assert-HerdrPhysicalPathUnderRoot -CandidatePath $canonicalPath -RootPath $TrustedRoot `
            -Description 'File boundary' -AllowedCloudFilesRoot $AllowedCloudFilesRoot
    }
    $before = Assert-HerdrWorkbookFile -Path $canonicalPath -AllowedCloudFilesRoot $AllowedCloudFilesRoot
    $beforeLength = [int64]$before.Length
    $beforeWriteTime = $before.LastWriteTimeUtc
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    $opened = $null
    $openedIdentity = $null
    try {
        try {
            if ($IsWindows) {
                $opened = Open-HerdrNativeReadFile -Path $canonicalPath -AllowedCloudFilesRoot $AllowedCloudFilesRoot
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
        $after = Assert-HerdrWorkbookFile -Path $canonicalPath -AllowedCloudFilesRoot $AllowedCloudFilesRoot
    }
    catch {
        throw "Workbook changed or disappeared during the exclusive read: '$canonicalPath'."
    }
    if ([int64]$after.Length -ne $beforeLength -or $after.LastWriteTimeUtc -ne $beforeWriteTime) {
        throw "Workbook changed during the exclusive read: '$canonicalPath'."
    }
    $afterProof = Get-HerdrPhysicalPathProof -Path $canonicalPath -AllowedCloudFilesRoot $AllowedCloudFilesRoot
    Compare-HerdrPhysicalIdentity -Expected $openedIdentity -Actual $afterProof.Leaf -Description 'Workbook source after read' -IncludeLinkCount | Out-Null
    if ($null -ne $boundaryBefore) {
        Assert-HerdrPhysicalPathUnderRoot -CandidatePath $canonicalPath -RootPath $TrustedRoot `
            -ExpectedCandidate $boundaryBefore.Candidate -ExpectedRoot $boundaryBefore.Root -Description 'File boundary after read' `
            -AllowedCloudFilesRoot $AllowedCloudFilesRoot | Out-Null
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

function Copy-HerdrNativeFileExclusive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$TrustedRoot,
        [object]$ExpectedSourceIdentity,
        [string]$TrustedDestinationRoot,
        [string]$SourceAllowedCloudFilesRoot,
        [string]$DestinationAllowedCloudFilesRoot
    )

    $source = Get-HerdrCanonicalPath -Path $SourcePath
    $destination = Get-HerdrCanonicalPath -Path $DestinationPath
    $parent = Split-Path -Parent $destination
    $destinationName = Split-Path -Leaf $destination
    $operationRoot = if ([string]::IsNullOrWhiteSpace($TrustedDestinationRoot)) {
        [IO.Path]::GetPathRoot($parent)
    }
    else {
        Get-HerdrCanonicalPath -Path $TrustedDestinationRoot
    }
    $destinationParent = Open-HerdrNativeDirectoryChain -RootPath $operationRoot -TargetPath $parent `
        -Description 'Copy destination parent' -AllowedCloudFilesRoot $DestinationAllowedCloudFilesRoot
    $temporaryName = '.herdr-copy-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $sourceStream = $null
    $destinationStream = $null
    $opened = $null
    $destinationHandle = $null
    $committed = $false
    $failure = $null
    $sourceIdentity = $null
    try {
        $opened = Open-HerdrNativeReadFile -Path $source -AllowedCloudFilesRoot $SourceAllowedCloudFilesRoot
        $sourceIdentity = $opened.Identity
        if ($null -ne $ExpectedSourceIdentity) {
            Compare-HerdrPhysicalIdentity -Expected $ExpectedSourceIdentity -Actual $sourceIdentity `
                -Description 'Copy source' -IncludeLinkCount | Out-Null
        }
        $sourceStream = [IO.FileStream]::new($opened.SafeHandle, [IO.FileAccess]::Read, 1048576, $false)
        $rawDestination = [Herdr.Security.NativeMethods]::CreateFileRelative(
            $destinationParent.SafeHandle.DangerousGetHandle(), $temporaryName)
        $destinationHandle = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new($rawDestination, $true)
        $destinationStream = [IO.FileStream]::new($destinationHandle, [IO.FileAccess]::Write, 1048576, $false)
        $sourceStream.CopyTo($destinationStream, 1048576)
        $destinationStream.Flush($true)
        [Herdr.Security.NativeMethods]::RenameFileRelative(
            $destinationHandle.DangerousGetHandle(),
            $destinationParent.SafeHandle.DangerousGetHandle(),
            $destinationName)
        $committed = $true
    }
    catch {
        $failure = $_.Exception
    }
    finally {
        if ($null -ne $destinationStream) { $destinationStream.Dispose() }
        if ($null -ne $destinationHandle -and -not $destinationHandle.IsClosed) { $destinationHandle.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
        if ($null -ne $opened -and $null -ne $opened.SafeHandle -and -not $opened.SafeHandle.IsClosed) { $opened.SafeHandle.Dispose() }
    }
    if (-not $committed) {
        try {
            [Herdr.Security.NativeMethods]::DeleteRelative(
                $destinationParent.SafeHandle.DangerousGetHandle(), $temporaryName, $false)
        }
        catch [System.ComponentModel.Win32Exception] {
            if ($_.Exception.NativeErrorCode -notin @(2, 3, 53)) { $failure = $_.Exception }
        }
        finally {
            $destinationParent.SafeHandle.Dispose()
        }
        if ($null -ne $failure) { throw "Exclusive workbook copy failed: $($failure.Message)" }
        throw 'Exclusive workbook copy failed.'
    }
    $destinationParent.SafeHandle.Dispose()
    if ($null -ne $sourceIdentity) {
        $sourceAfter = Get-HerdrPhysicalPathProof -Path $source -AllowedCloudFilesRoot $SourceAllowedCloudFilesRoot
        Compare-HerdrPhysicalIdentity -Expected $sourceIdentity -Actual $sourceAfter.Leaf `
            -Description 'Copy source after read' -IncludeLinkCount | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($TrustedRoot)) {
            Assert-HerdrPhysicalPathUnderRoot -CandidatePath $source -RootPath $TrustedRoot `
                -ExpectedCandidate $sourceIdentity -Description 'Copy source boundary after read' `
                -AllowedCloudFilesRoot $SourceAllowedCloudFilesRoot | Out-Null
        }
    }
    $destinationProof = Get-HerdrPhysicalPathProof -Path $destination -AllowedCloudFilesRoot $DestinationAllowedCloudFilesRoot
    if (-not $destinationProof.Exists -or $destinationProof.Leaf.IsDirectory -or
        [int64]$destinationProof.Leaf.NumberOfLinks -gt 1) {
        throw "Exclusive workbook copy produced an unsafe destination: '$destination'."
    }
    return $destination
}

function Copy-HerdrFileExclusive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$TrustedRoot,
        [object]$ExpectedSourceIdentity,
        [string]$TrustedDestinationRoot,
        [string]$SourceAllowedCloudFilesRoot,
        [string]$DestinationAllowedCloudFilesRoot
    )

    if ($IsWindows) {
        return Copy-HerdrNativeFileExclusive @PSBoundParameters
    }
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
                -AllowEqual -Description 'Copy destination boundary' -AllowedCloudFilesRoot $DestinationAllowedCloudFilesRoot
            if (-not $destinationBoundary.Candidate.Leaf.IsDirectory) { throw 'Copy destination parent is not a directory.' }
        }
        else {
            $destinationParentProof = Get-HerdrPhysicalPathProof -Path $parent -AllowedCloudFilesRoot $DestinationAllowedCloudFilesRoot
            if (-not $destinationParentProof.Leaf.IsDirectory) { throw 'Copy destination parent is not a directory.' }
        }
        if (-not [string]::IsNullOrWhiteSpace($TrustedRoot)) {
            $sourceBoundary = Assert-HerdrPhysicalPathUnderRoot -CandidatePath $source -RootPath $TrustedRoot `
                -Description 'Copy source boundary' -AllowedCloudFilesRoot $SourceAllowedCloudFilesRoot
        }
        if ($IsWindows) {
            $opened = Open-HerdrNativeReadFile -Path $source -AllowedCloudFilesRoot $SourceAllowedCloudFilesRoot
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
                -ExpectedRoot $destinationBoundary.Root -AllowEqual -Description 'Copy destination boundary before commit' `
                -AllowedCloudFilesRoot $DestinationAllowedCloudFilesRoot | Out-Null
        }
        else {
            $destinationParentProof = Get-HerdrPhysicalPathProof -Path $parent -AllowedCloudFilesRoot $DestinationAllowedCloudFilesRoot
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
        $sourceAfter = Get-HerdrPhysicalPathProof -Path $source -AllowedCloudFilesRoot $SourceAllowedCloudFilesRoot
        Compare-HerdrPhysicalIdentity -Expected $sourceIdentity -Actual $sourceAfter.Leaf -Description 'Copy source after read' -IncludeLinkCount | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($TrustedRoot)) {
            Assert-HerdrPhysicalPathUnderRoot -CandidatePath $source -RootPath $TrustedRoot `
                -ExpectedCandidate $sourceIdentity -ExpectedRoot $sourceBoundary.Root `
                -Description 'Copy source boundary after read' -AllowedCloudFilesRoot $SourceAllowedCloudFilesRoot | Out-Null
        }
    }
    try {
        [IO.File]::Move($temporary, $destination)
    }
    catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        throw "Exclusive workbook copy could not be committed."
    }
    $destinationProof = Get-HerdrPhysicalPathProof -Path $destination -AllowedCloudFilesRoot $DestinationAllowedCloudFilesRoot
    if (-not [string]::IsNullOrWhiteSpace($TrustedDestinationRoot)) {
        Assert-HerdrPhysicalPathUnderRoot -CandidatePath $destination -RootPath $TrustedDestinationRoot `
            -ExpectedRoot $destinationBoundary.Root -Description 'Copy destination boundary after commit' `
            -AllowedCloudFilesRoot $DestinationAllowedCloudFilesRoot | Out-Null
    }
    if (-not $destinationProof.Exists -or $destinationProof.Leaf.IsDirectory -or [int64]$destinationProof.Leaf.NumberOfLinks -gt 1) {
        throw "Exclusive workbook copy produced an unsafe destination: '$destination'."
    }
    return $destination
}

function Write-HerdrNativeAtomicText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [string]$TrustedRoot
    )

    $destination = Get-HerdrCanonicalPath -Path $Path
    $parent = Split-Path -Parent $destination
    $destinationName = Split-Path -Leaf $destination
    $operationRoot = if ([string]::IsNullOrWhiteSpace($TrustedRoot)) {
        [IO.Path]::GetPathRoot($parent)
    }
    else {
        Get-HerdrCanonicalPath -Path $TrustedRoot
    }
    $destinationParent = Open-HerdrNativeDirectoryChain -RootPath $operationRoot -TargetPath $parent `
        -Description 'Atomic text destination parent'
    $temporaryName = '.herdr-text-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $destinationStream = $null
    $destinationHandle = $null
    $committed = $false
    $failure = $null
    try {
        $rawDestination = [Herdr.Security.NativeMethods]::CreateFileRelative(
            $destinationParent.SafeHandle.DangerousGetHandle(), $temporaryName)
        $destinationHandle = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new($rawDestination, $true)
        $destinationStream = [IO.FileStream]::new($destinationHandle, [IO.FileAccess]::Write, 65536, $false)
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
        $destinationStream.Write($bytes, 0, $bytes.Length)
        $destinationStream.Flush($true)
        [Herdr.Security.NativeMethods]::RenameFileRelative(
            $destinationHandle.DangerousGetHandle(),
            $destinationParent.SafeHandle.DangerousGetHandle(),
            $destinationName)
        $committed = $true
    }
    catch {
        $failure = $_.Exception
    }
    finally {
        if ($null -ne $destinationStream) { $destinationStream.Dispose() }
        if ($null -ne $destinationHandle -and -not $destinationHandle.IsClosed) { $destinationHandle.Dispose() }
    }
    if (-not $committed) {
        try {
            [Herdr.Security.NativeMethods]::DeleteRelative(
                $destinationParent.SafeHandle.DangerousGetHandle(), $temporaryName, $false)
        }
        catch [System.ComponentModel.Win32Exception] {
            if ($_.Exception.NativeErrorCode -notin @(2, 3, 53)) { $failure = $_.Exception }
        }
        finally {
            $destinationParent.SafeHandle.Dispose()
        }
        if ($null -ne $failure) { throw "Atomic text output could not be committed: $($failure.Message)" }
        throw 'Atomic text output could not be committed.'
    }
    $destinationParent.SafeHandle.Dispose()
    $destinationProof = Get-HerdrPhysicalPathProof -Path $destination
    if (-not $destinationProof.Exists -or $destinationProof.Leaf.IsDirectory -or
        [int64]$destinationProof.Leaf.NumberOfLinks -gt 1) {
        throw "Atomic text output is not a safe regular file: '$destination'."
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

    if ($IsWindows) {
        return Write-HerdrNativeAtomicText @PSBoundParameters
    }
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
        [Parameter(Mandatory)][string]$OneDriveExchangeRoot,
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
    $oneDriveExchangeRootCanonical = Assert-HerdrConfiguredLocalPath -Path $OneDriveExchangeRoot
    $inboxRoot = Assert-HerdrConfiguredLocalPath -Path $OneDriveInboxRoot
    $exchangeRootCanonical = Assert-HerdrConfiguredLocalPath -Path $ExchangeRoot
    Assert-HerdrExistingPathIsNotReparsePoint -Path $inboxRoot -AllowedCloudFilesRoot $oneDriveExchangeRootCanonical | Out-Null
    $exchangeRootCanonical = Ensure-HerdrManagedDirectory -Path $exchangeRootCanonical -Description 'Exchange root'
    if ([string]::IsNullOrWhiteSpace($OneDriveOutboxRoot)) {
        $OneDriveOutboxRoot = Get-HerdrDefaultOneDriveSiblingRoot -InboxRoot $inboxRoot -Name Outbox
    }
    if ([string]::IsNullOrWhiteSpace($OneDriveArchiveRoot)) {
        $OneDriveArchiveRoot = Get-HerdrDefaultOneDriveSiblingRoot -InboxRoot $inboxRoot -Name Archive
    }
    $outboxRoot = Assert-HerdrConfiguredLocalPath -Path $OneDriveOutboxRoot
    $archiveRoot = Assert-HerdrConfiguredLocalPath -Path $OneDriveArchiveRoot
    foreach ($oneDrivePath in @(
        [pscustomobject]@{ Name = 'OneDrive Inbox'; Path = $inboxRoot },
        [pscustomobject]@{ Name = 'OneDrive Outbox'; Path = $outboxRoot },
        [pscustomobject]@{ Name = 'OneDrive Archive'; Path = $archiveRoot }
    )) {
        if (-not (Test-HerdrPathSameOrDescendant -Candidate $oneDrivePath.Path -Ancestor $oneDriveExchangeRootCanonical) -or
            $oneDrivePath.Path.Equals($oneDriveExchangeRootCanonical, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$($oneDrivePath.Name) is outside the configured OneDrive exchange boundary."
        }
    }
    foreach ($oneDrivePath in @(
        [pscustomobject]@{ Name = 'OneDrive Inbox'; Path = $inboxRoot },
        [pscustomobject]@{ Name = 'OneDrive Outbox'; Path = $outboxRoot },
        [pscustomobject]@{ Name = 'OneDrive Archive'; Path = $archiveRoot }
    )) {
        Assert-HerdrPhysicalPathUnderRoot -CandidatePath $oneDrivePath.Path -RootPath $oneDriveExchangeRootCanonical `
            -Description "$($oneDrivePath.Name) physical exchange boundary" `
            -AllowedCloudFilesRoot $oneDriveExchangeRootCanonical | Out-Null
    }
    Assert-HerdrExistingPathIsNotReparsePoint -Path $outboxRoot -AllowedCloudFilesRoot $oneDriveExchangeRootCanonical | Out-Null
    Assert-HerdrExistingPathIsNotReparsePoint -Path $archiveRoot -AllowedCloudFilesRoot $oneDriveExchangeRootCanonical | Out-Null
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
    $sourceBoundary = Assert-HerdrPhysicalPathUnderRoot -CandidatePath $sourceCanonical -RootPath $inboxRoot `
        -Description 'OneDrive source' -AllowedCloudFilesRoot $oneDriveExchangeRootCanonical
    $sourceItem = Assert-HerdrWorkbookFile -Path $sourceCanonical -AllowedCloudFilesRoot $oneDriveExchangeRootCanonical
    $stageRoot = Ensure-HerdrManagedDirectory -Path (Join-Path $exchangeRootCanonical 'in') `
        -TrustedRoot $exchangeRootCanonical -Description 'Exchange input root'
    $jobDirectory = Get-HerdrCanonicalPath -Path (Join-Path $stageRoot $JobId)
    if (-not $IsWindows -and (Test-Path -LiteralPath $jobDirectory)) { throw "Staging collision for job '$JobId'." }
    $jobDirectory = Ensure-HerdrManagedDirectory -Path $jobDirectory -TrustedRoot $stageRoot `
        -RequireLeafCreation -Description 'Staging job directory'
    $completed = $false
    try {
        $firstSnapshot = Get-HerdrFileSnapshot -Path $sourceCanonical -TrustedRoot $inboxRoot `
            -AllowedCloudFilesRoot $oneDriveExchangeRootCanonical
        if ($null -ne $BetweenSourceReads) { & $BetweenSourceReads $sourceCanonical }
        if ($StabilityIntervalMilliseconds -gt 0) { Start-Sleep -Milliseconds $StabilityIntervalMilliseconds }
        $secondSnapshot = Get-HerdrFileSnapshot -Path $sourceCanonical -TrustedRoot $inboxRoot `
            -ExpectedIdentity $firstSnapshot -AllowedCloudFilesRoot $oneDriveExchangeRootCanonical
        Assert-HerdrSnapshotsEqual -Expected $firstSnapshot -Actual $secondSnapshot -Description 'OneDrive source'
        $extension = [IO.Path]::GetExtension($sourceItem.Name).ToLowerInvariant()
        $stagedPath = Get-HerdrCanonicalPath -Path (Join-Path $jobDirectory ('input' + $extension))
        Copy-HerdrFileExclusive -SourcePath $sourceCanonical -DestinationPath $stagedPath `
            -TrustedRoot $inboxRoot -ExpectedSourceIdentity $firstSnapshot -TrustedDestinationRoot $jobDirectory `
            -SourceAllowedCloudFilesRoot $oneDriveExchangeRootCanonical | Out-Null
        $stagedSnapshot = Get-HerdrFileSnapshot -Path $stagedPath -TrustedRoot $jobDirectory
        Assert-HerdrSnapshotContentEqual -Expected $firstSnapshot -Actual $stagedSnapshot -Description 'Bridge staging copy'
        if (-not (Test-Path -LiteralPath $sourceCanonical -PathType Leaf)) {
            throw 'OneDrive source was not preserved after staging.'
        }
        Assert-HerdrPhysicalPathUnderRoot -CandidatePath $sourceCanonical -RootPath $inboxRoot `
            -ExpectedCandidate $firstSnapshot -ExpectedRoot $sourceBoundary.Root -Description 'Preserved OneDrive source' `
            -AllowedCloudFilesRoot $oneDriveExchangeRootCanonical | Out-Null
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
        if (-not $completed) {
            try {
                Remove-HerdrManagedTree -Path $jobDirectory -TrustedRoot $stageRoot `
                    -KnownFileNames @('input.xlsx', 'input.xlsm', 'input.xlsb', 'staging-provenance.json')
            }
            catch {
                Write-Verbose "Safe staging cleanup did not remove '$jobDirectory': $($_.Exception.Message)"
            }
        }
    }
}

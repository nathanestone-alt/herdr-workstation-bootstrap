Set-StrictMode -Version Latest

if ($IsWindows -and $null -eq ('Herdr.Authority.RuntimeToken' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace Herdr.Authority {
    public sealed class RuntimeToken : IDisposable {
        private const uint ProcessQueryLimitedInformation = 0x1000;
        private const uint TokenQuery = 0x0008;
        private const uint TokenDuplicate = 0x0002;
        private const int TokenUser = 1;
        private const int TokenGroups = 2;
        private const int TokenElevationType = 18;
        private const int SecurityImpersonation = 2;
        private const uint MaximumAllowed = 0x02000000;
        private const int ErrorInsufficientBuffer = 122;
        private const uint SeGroupEnabled = 0x00000004;
        private const uint SeGroupUseForDenyOnly = 0x00000010;
        private IntPtr token;

        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime { public uint Low; public uint High; }

        [StructLayout(LayoutKind.Sequential)]
        private struct GenericMapping {
            public uint GenericRead;
            public uint GenericWrite;
            public uint GenericExecute;
            public uint GenericAll;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out FileTime creation, out FileTime exit, out FileTime kernel, out FileTime user);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool DuplicateToken(IntPtr existingToken, int impersonationLevel, out IntPtr duplicateToken);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetTokenInformation(IntPtr token, int informationClass, IntPtr information, int length, out int returnLength);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool AccessCheck(IntPtr securityDescriptor, IntPtr clientToken, uint desiredAccess,
            ref GenericMapping mapping, IntPtr privilegeSet, ref uint privilegeSetLength,
            out uint grantedAccess, out bool accessStatus);

        public int ProcessId { get; private set; }
        public long CreationTimeUtcTicks { get; private set; }
        public int SessionId { get; private set; }
        public string UserSid { get; private set; }
        public int ElevationType { get; private set; }
        public bool AdministratorsGroupPresent { get; private set; }
        public uint AdministratorsGroupAttributes { get; private set; }
        public bool AdministratorsGroupEnabled { get { return AdministratorsGroupPresent && (AdministratorsGroupAttributes & SeGroupEnabled) != 0; } }
        public bool AdministratorsGroupDenyOnly { get { return AdministratorsGroupPresent && (AdministratorsGroupAttributes & SeGroupUseForDenyOnly) != 0; } }

        public RuntimeToken(int processId) {
            IntPtr process = OpenProcess(ProcessQueryLimitedInformation, false, processId);
            if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Opening runtime process failed");
            IntPtr primary = IntPtr.Zero;
            try {
                FileTime creation, exit, kernel, user;
                if (!GetProcessTimes(process, out creation, out exit, out kernel, out user))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Reading runtime process creation time failed");
                ulong fileTime = ((ulong)creation.High << 32) | creation.Low;
                CreationTimeUtcTicks = DateTime.FromFileTimeUtc((long)fileTime).Ticks;
                uint session;
                if (!ProcessIdToSessionId((uint)processId, out session))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Reading runtime process session failed");
                SessionId = checked((int)session);
                if (!OpenProcessToken(process, TokenQuery | TokenDuplicate, out primary))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Opening runtime process token failed");
                if (!DuplicateToken(primary, SecurityImpersonation, out token))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Duplicating runtime process token failed");
                ProcessId = processId;
                UserSid = ReadUserSid(primary);
                ElevationType = ReadInt32(primary, TokenElevationType);
                ReadAdministratorsGroup(primary);
            }
            catch {
                Dispose();
                throw;
            }
            finally {
                if (primary != IntPtr.Zero) CloseHandle(primary);
                CloseHandle(process);
            }
        }

        private static IntPtr ReadTokenBuffer(IntPtr token, int informationClass, out int length) {
            length = 0;
            GetTokenInformation(token, informationClass, IntPtr.Zero, 0, out length);
            if (length <= 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "Sizing token information failed");
            IntPtr buffer = Marshal.AllocHGlobal(length);
            if (!GetTokenInformation(token, informationClass, buffer, length, out length)) {
                int error = Marshal.GetLastWin32Error();
                Marshal.FreeHGlobal(buffer);
                throw new Win32Exception(error, "Reading token information failed");
            }
            return buffer;
        }

        private static string ReadUserSid(IntPtr token) {
            int length;
            IntPtr buffer = ReadTokenBuffer(token, TokenUser, out length);
            try { return new SecurityIdentifier(Marshal.ReadIntPtr(buffer)).Value; }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private static int ReadInt32(IntPtr token, int informationClass) {
            int length;
            IntPtr buffer = ReadTokenBuffer(token, informationClass, out length);
            try { return Marshal.ReadInt32(buffer); }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private void ReadAdministratorsGroup(IntPtr primary) {
            int length;
            IntPtr buffer = ReadTokenBuffer(primary, TokenGroups, out length);
            try {
                int count = Marshal.ReadInt32(buffer);
                int first = IntPtr.Size == 8 ? 8 : 4;
                int stride = IntPtr.Size == 8 ? 16 : 8;
                for (int index = 0; index < count; index++) {
                    IntPtr entry = IntPtr.Add(buffer, first + index * stride);
                    string sid = new SecurityIdentifier(Marshal.ReadIntPtr(entry)).Value;
                    if (String.Equals(sid, "S-1-5-32-544", StringComparison.Ordinal)) {
                        AdministratorsGroupPresent = true;
                        AdministratorsGroupAttributes = unchecked((uint)Marshal.ReadInt32(entry, IntPtr.Size));
                        return;
                    }
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        public uint GetGrantedFileAccess(byte[] securityDescriptor) {
            if (token == IntPtr.Zero) throw new ObjectDisposedException("RuntimeToken");
            if (securityDescriptor == null || securityDescriptor.Length == 0) throw new ArgumentException("A security descriptor is required.");
            GCHandle pin = GCHandle.Alloc(securityDescriptor, GCHandleType.Pinned);
            IntPtr privileges = IntPtr.Zero;
            try {
                var mapping = new GenericMapping {
                    GenericRead = 0x00120089,
                    GenericWrite = 0x00120116,
                    GenericExecute = 0x001200A0,
                    GenericAll = 0x001F01FF
                };
                uint privilegeLength = 0;
                uint granted;
                bool status;
                AccessCheck(pin.AddrOfPinnedObject(), token, MaximumAllowed, ref mapping,
                    IntPtr.Zero, ref privilegeLength, out granted, out status);
                int error = Marshal.GetLastWin32Error();
                if (privilegeLength == 0 || error != ErrorInsufficientBuffer)
                    throw new Win32Exception(error, "Sizing AccessCheck privilege set failed");
                privileges = Marshal.AllocHGlobal(checked((int)privilegeLength));
                if (!AccessCheck(pin.AddrOfPinnedObject(), token, MaximumAllowed, ref mapping,
                    privileges, ref privilegeLength, out granted, out status))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "AccessCheck failed");
                return status ? granted : 0;
            }
            finally {
                if (privileges != IntPtr.Zero) Marshal.FreeHGlobal(privileges);
                pin.Free();
            }
        }

        public void Dispose() {
            if (token != IntPtr.Zero) { CloseHandle(token); token = IntPtr.Zero; }
            GC.SuppressFinalize(this);
        }
        ~RuntimeToken() { Dispose(); }
    }
}
'@
}

function Open-HerdrRuntimeTokenProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ExpectedCreationTimeUtc,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$ExpectedSessionId,
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier]$ExpectedUserSid
    )

    if (-not $IsWindows) { throw 'Runtime token access proof requires Windows.' }
    $creation = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($ExpectedCreationTimeUtc, 'o', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$creation)) {
        throw 'Expected runtime process creation time must use the round-trip UTC format.'
    }
    if ($creation.Kind -ne [DateTimeKind]::Utc) { throw 'Expected runtime process creation time must end in Z.' }
    $proof = [Herdr.Authority.RuntimeToken]::new($ProcessId)
    try {
        if ($proof.CreationTimeUtcTicks -ne $creation.Ticks -or $proof.SessionId -ne $ExpectedSessionId -or
            $proof.UserSid -cne $ExpectedUserSid.Value) {
            throw 'Runtime process identity does not match the commissioned PID/creation/session/SID tuple.'
        }
        return $proof
    }
    catch {
        $proof.Dispose()
        throw
    }
}

function Get-HerdrRuntimeTokenGrantedAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$RuntimeToken, [Parameter(Mandatory)][string]$Path)

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    return [uint32]$RuntimeToken.GetGrantedFileAccess($acl.GetSecurityDescriptorBinaryForm())
}

function Assert-HerdrRuntimeTokenCannotMutate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$RuntimeToken,
        [Parameter(Mandatory)][string]$Path,
        [uint32]$ProhibitedMask = 0x000D0156,
        [string]$Description = 'authority path'
    )

    $granted = Get-HerdrRuntimeTokenGrantedAccess -RuntimeToken $RuntimeToken -Path $Path
    if (($granted -band $ProhibitedMask) -ne 0) {
        throw ("Runtime token has effective mutation authority over {0} '{1}' (granted=0x{2:x8}, prohibited=0x{3:x8})." -f
            $Description, $Path, $granted, $ProhibitedMask)
    }
    return $granted
}

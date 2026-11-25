using System.Runtime.InteropServices;

namespace WorkCtlNext.Core;

internal static class Win32ProcessInterop
{
    private const uint Th32csSnapProcess = 0x00000002;
    internal const uint ProcessQueryLimitedInformation = 0x1000;
    internal const uint ProcessTerminate = 0x0001;
    private const uint TokenQuery = 0x0008;
    private const int TokenUserClass = 1;
    private const uint ScManagerEnumerateService = 0x0004;
    private const int ScEnumProcessInfo = 0;
    private const uint ServiceWin32 = 0x00000030;
    private const uint ServiceActive = 0x00000001;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PROCESSENTRY32W
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public nuint th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExeFile;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_STATUS_PROCESS
    {
        public uint dwServiceType;
        public uint dwCurrentState;
        public uint dwControlsAccepted;
        public uint dwWin32ExitCode;
        public uint dwServiceSpecificExitCode;
        public uint dwCheckPoint;
        public uint dwWaitHint;
        public uint dwProcessId;
        public uint dwServiceFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ENUM_SERVICE_STATUS_PROCESSW
    {
        public nint lpServiceName;
        public nint lpDisplayName;
        public SERVICE_STATUS_PROCESS ServiceStatusProcess;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Process32FirstW(nint hSnapshot, ref PROCESSENTRY32W lppe);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Process32NextW(nint hSnapshot, ref PROCESSENTRY32W lppe);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint OpenProcess(uint dwDesiredAccess, [MarshalAs(UnmanagedType.Bool)] bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(nint hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetProcessTimes(
        nint hProcess,
        out Win32SystemInterop.FILETIME lpCreationTime,
        out Win32SystemInterop.FILETIME lpExitTime,
        out Win32SystemInterop.FILETIME lpKernelTime,
        out Win32SystemInterop.FILETIME lpUserTime);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageNameW(nint hProcess, uint dwFlags, char[] lpExeName, ref int lpdwSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(nint hProcess, uint uExitCode);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(nint ProcessHandle, uint DesiredAccess, out nint TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(nint TokenHandle, int TokenInformationClass, nint TokenInformation, int TokenInformationLength, out int ReturnLength);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LookupAccountSidW(
        string? lpSystemName,
        nint Sid,
        char[] Name,
        ref int cchName,
        char[] ReferencedDomainName,
        ref int cchReferencedDomainName,
        out int peUse);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint OpenSCManagerW(string? lpMachineName, string? lpDatabaseName, uint dwDesiredAccess);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumServicesStatusExW(
        nint hSCManager,
        int InfoLevel,
        uint dwServiceType,
        uint dwServiceState,
        nint lpServices,
        uint cbBufSize,
        out uint pcbBytesNeeded,
        out uint lpServicesReturned,
        ref uint lpResumeHandle,
        string? pszGroupName);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(nint hSCObject);

    public sealed record ToolhelpEntry(int Pid, int ParentPid, string ExeFile, uint Threads);

    public static Dictionary<int, ToolhelpEntry> CaptureToolhelpMap()
    {
        var map = new Dictionary<int, ToolhelpEntry>(512);
        if (!OperatingSystem.IsWindows())
            return map;

        nint snap = CreateToolhelp32Snapshot(Th32csSnapProcess, 0);
        if (snap == nint.Zero || snap == -1)
            return map;

        try
        {
            var entry = new PROCESSENTRY32W { dwSize = (uint)Marshal.SizeOf<PROCESSENTRY32W>(), szExeFile = string.Empty };
            if (!Process32FirstW(snap, ref entry))
                return map;

            do
            {
                int pid = unchecked((int)entry.th32ProcessID);
                int ppid = unchecked((int)entry.th32ParentProcessID);
                map[pid] = new ToolhelpEntry(pid, ppid, entry.szExeFile ?? string.Empty, entry.cntThreads);
            }
            while (Process32NextW(snap, ref entry));
        }
        finally
        {
            CloseHandle(snap);
        }

        return map;
    }

    public static bool TryQueryProcessMetadata(
        int pid,
        bool includeOwner,
        out long creationUtcTicks,
        out string? exePath,
        out string? owner,
        out string? ownerUnavailableReason)
    {
        creationUtcTicks = 0;
        exePath = null;
        owner = null;
        ownerUnavailableReason = null;

        if (!OperatingSystem.IsWindows() || pid <= 0)
        {
            ownerUnavailableReason = "System idle/kernel pseudo-process";
            return false;
        }

        nint hProc = OpenProcess(ProcessQueryLimitedInformation, false, pid);
        if (hProc == nint.Zero)
        {
            int err = Marshal.GetLastWin32Error();
            ownerUnavailableReason = err == 5 ? "Access denied" : $"Unavailable (Win32 {err})";
            return false;
        }

        try
        {
            if (GetProcessTimes(hProc, out Win32SystemInterop.FILETIME created, out _, out _, out _))
                creationUtcTicks = FileTimeToUtcTicks(created);

            var buf = new char[1024];
            int len = buf.Length;
            if (QueryFullProcessImageNameW(hProc, 0, buf, ref len) && len > 0)
                exePath = new string(buf, 0, len);

            if (includeOwner)
            {
                if (!TryReadTokenOwner(hProc, out owner, out ownerUnavailableReason))
                    owner = null;
            }
            return true;
        }
        finally
        {
            CloseHandle(hProc);
        }
    }

    private static bool TryReadTokenOwner(nint hProcess, out string? owner, out string? reason)
    {
        owner = null;
        reason = null;

        if (!OpenProcessToken(hProcess, TokenQuery, out nint hToken) || hToken == nint.Zero)
        {
            int err = Marshal.GetLastWin32Error();
            reason = err == 5 ? "Access denied (protected token)" : $"Token unavailable (Win32 {err})";
            return false;
        }

        nint tokenBuf = nint.Zero;
        try
        {
            _ = GetTokenInformation(hToken, TokenUserClass, nint.Zero, 0, out int needed);
            if (needed <= 0)
            {
                reason = "Token query failed";
                return false;
            }

            tokenBuf = Marshal.AllocHGlobal(needed);
            if (!GetTokenInformation(hToken, TokenUserClass, tokenBuf, needed, out _))
            {
                int err = Marshal.GetLastWin32Error();
                reason = $"Token read failed (Win32 {err})";
                return false;
            }

            nint sid = Marshal.ReadIntPtr(tokenBuf);
            var name = new char[256];
            var dom = new char[256];
            int cName = name.Length;
            int cDom = dom.Length;
            if (!LookupAccountSidW(null, sid, name, ref cName, dom, ref cDom, out _))
            {
                reason = "SID lookup failed";
                return false;
            }

            string acct = new(name, 0, cName);
            string domain = cDom > 0 ? new string(dom, 0, cDom) : string.Empty;
            owner = string.IsNullOrEmpty(domain) ? acct : $"{domain}\\{acct}";
            return true;
        }
        finally
        {
            if (tokenBuf != nint.Zero)
                Marshal.FreeHGlobal(tokenBuf);
            CloseHandle(hToken);
        }
    }

    public static Dictionary<int, List<ProcessServiceAssociation>> CaptureServicesByPid()
    {
        var result = new Dictionary<int, List<ProcessServiceAssociation>>();
        if (!OperatingSystem.IsWindows())
            return result;

        nint scm = OpenSCManagerW(null, null, ScManagerEnumerateService);
        if (scm == nint.Zero)
            return result;

        nint buf = nint.Zero;
        try
        {
            uint resume = 0;
            _ = EnumServicesStatusExW(scm, ScEnumProcessInfo, ServiceWin32, ServiceActive, nint.Zero, 0, out uint bytesNeeded, out _, ref resume, null);
            if (bytesNeeded == 0)
                return result;

            uint alloc = bytesNeeded + 4096;
            buf = Marshal.AllocHGlobal((int)alloc);
            resume = 0;
            if (!EnumServicesStatusExW(scm, ScEnumProcessInfo, ServiceWin32, ServiceActive, buf, alloc, out _, out uint count, ref resume, null))
                return result;

            int stride = Marshal.SizeOf<ENUM_SERVICE_STATUS_PROCESSW>();
            for (int i = 0; i < count; i++)
            {
                ENUM_SERVICE_STATUS_PROCESSW item = Marshal.PtrToStructure<ENUM_SERVICE_STATUS_PROCESSW>(buf + i * stride);
                int pid = unchecked((int)item.ServiceStatusProcess.dwProcessId);
                if (pid <= 0)
                    continue;

                string svcName = Marshal.PtrToStringUni(item.lpServiceName) ?? string.Empty;
                string dispName = Marshal.PtrToStringUni(item.lpDisplayName) ?? svcName;
                string state = item.ServiceStatusProcess.dwCurrentState switch
                {
                    4 => "Running",
                    2 => "StartPending",
                    3 => "StopPending",
                    7 => "Paused",
                    _ => "Active"
                };

                if (!result.TryGetValue(pid, out var list))
                {
                    list = [];
                    result[pid] = list;
                }
                list.Add(new ProcessServiceAssociation(svcName, dispName, state));
            }
        }
        finally
        {
            if (buf != nint.Zero)
                Marshal.FreeHGlobal(buf);
            CloseServiceHandle(scm);
        }

        return result;
    }

    public static ProcessTerminationResult TerminateVerifiedPid(
        ProcessIdentityToken expectedIdentity)
    {
        if (!OperatingSystem.IsWindows() || expectedIdentity.Pid <= 4)
            return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "force", "Refused protected/kernel PID.", "PROTECTED_PROCESS");

        nint hProc = OpenProcess(ProcessTerminate | ProcessQueryLimitedInformation, false, expectedIdentity.Pid);
        if (hProc == nint.Zero)
        {
            int err = Marshal.GetLastWin32Error();
            string code = err == 5 ? "ACCESS_DENIED" : (err == 87 ? "PROCESS_EXITED" : "OPEN_FAILED");
            string msg = err == 5
                ? $"Windows denied termination access for PID {expectedIdentity.Pid} (elevation never bypassed)."
                : (err == 87 ? $"Process PID {expectedIdentity.Pid} has already exited." : $"OpenProcess failed with Win32 error {err}.");
            return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "force", msg, code);
        }

        try
        {
            // Revalidate creation time + executable on THIS handle immediately prior to TerminateProcess (prevents TOCTOU PID reuse!)
            long liveCreated = 0;
            if (GetProcessTimes(hProc, out Win32SystemInterop.FILETIME created, out _, out _, out _))
                liveCreated = FileTimeToUtcTicks(created);

            if (expectedIdentity.CreationTimeUtcTicks != 0 && liveCreated != 0 && liveCreated != expectedIdentity.CreationTimeUtcTicks)
            {
                return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "force",
                    $"PID {expectedIdentity.Pid} creation timestamp changed ({expectedIdentity.CreationTimeUtcTicks} -> {liveCreated}); aborted due to PID reuse.",
                    "PID_REUSED");
            }

            if (!string.IsNullOrWhiteSpace(expectedIdentity.ExecutablePath))
            {
                var buf = new char[1024];
                int len = buf.Length;
                if (QueryFullProcessImageNameW(hProc, 0, buf, ref len) && len > 0)
                {
                    string liveExe = new(buf, 0, len);
                    if (!string.Equals(liveExe, expectedIdentity.ExecutablePath, StringComparison.OrdinalIgnoreCase))
                    {
                        return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "force",
                            $"PID {expectedIdentity.Pid} executable path changed; aborted due to PID reuse.",
                            "PID_REUSED");
                    }
                }
            }

            if (!TerminateProcess(hProc, 1))
            {
                int err = Marshal.GetLastWin32Error();
                return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "force",
                    $"TerminateProcess failed (Win32 error {err}).", "TERMINATE_FAILED");
            }

            return new ProcessTerminationResult(true, expectedIdentity.Pid, expectedIdentity.Name, "force",
                $"Force-terminated {expectedIdentity.Name} (PID {expectedIdentity.Pid}).", null, 1);
        }
        finally
        {
            CloseHandle(hProc);
        }
    }

    private static long FileTimeToUtcTicks(Win32SystemInterop.FILETIME ft)
    {
        long raw = unchecked((long)ft.ToUInt64());
        return raw > 0 ? DateTime.FromFileTimeUtc(raw).Ticks : 0;
    }
}

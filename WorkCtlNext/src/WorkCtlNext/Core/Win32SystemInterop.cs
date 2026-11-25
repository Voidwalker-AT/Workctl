using System.Runtime.InteropServices;

namespace WorkCtlNext.Core;

internal static class Win32SystemInterop
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct FILETIME
    {
        public uint dwLowDateTime;
        public uint dwHighDateTime;

        public ulong ToUInt64() => ((ulong)dwHighDateTime << 32) | dwLowDateTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetSystemTimes(
        out FILETIME lpIdleTime,
        out FILETIME lpKernelTime,
        out FILETIME lpUserTime);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsWindowVisible(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    internal struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    public static bool TryGetSystemTimes(out ulong idleTicks, out ulong kernelTicks, out ulong userTicks)
    {
        if (GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user))
        {
            idleTicks = idle.ToUInt64();
            kernelTicks = kernel.ToUInt64();
            userTicks = user.ToUInt64();
            return true;
        }

        idleTicks = 0;
        kernelTicks = 0;
        userTicks = 0;
        return false;
    }

    public static bool TryGetMemoryStatus(out ulong totalBytes, out ulong availableBytes, out uint memoryLoadPercent)
    {
        var status = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        if (GlobalMemoryStatusEx(ref status))
        {
            totalBytes = status.ullTotalPhys;
            availableBytes = status.ullAvailPhys;
            memoryLoadPercent = status.dwMemoryLoad;
            return true;
        }

        totalBytes = 0;
        availableBytes = 0;
        memoryLoadPercent = 0;
        return false;
    }
}

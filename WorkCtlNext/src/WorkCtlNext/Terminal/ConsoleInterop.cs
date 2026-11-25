using System.Runtime.InteropServices;

namespace WorkCtlNext.Terminal;

internal static partial class ConsoleInterop
{
    internal const int StdInputHandle = -10;
    internal const int StdOutputHandle = -11;

    internal const uint EnableProcessedInput = 0x0001;
    internal const uint EnableLineInput = 0x0002;
    internal const uint EnableEchoInput = 0x0004;
    internal const uint EnableWindowInput = 0x0008;
    internal const uint EnableVirtualTerminalInput = 0x0200;

    internal const uint EnableProcessedOutput = 0x0001;
    internal const uint EnableVirtualTerminalProcessing = 0x0004;

    [StructLayout(LayoutKind.Sequential)]
    internal struct MemoryStatusEx
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

    [LibraryImport("kernel32.dll", SetLastError = true)]
    internal static partial nint GetStdHandle(int nStdHandle);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetConsoleMode(nint hConsoleHandle, out uint lpMode);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetConsoleMode(nint hConsoleHandle, uint dwMode);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    internal static partial uint GetConsoleCP();

    [LibraryImport("kernel32.dll", SetLastError = true)]
    internal static partial uint GetConsoleOutputCP();

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetConsoleCP(uint wCodePageID);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetConsoleOutputCP(uint wCodePageID);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GlobalMemoryStatusEx(ref MemoryStatusEx lpBuffer);

    internal static bool TryGetMemoryStatus(out MemoryStatusEx status, out int win32Error)
    {
        status = new MemoryStatusEx { dwLength = (uint)Marshal.SizeOf<MemoryStatusEx>() };
        if (GlobalMemoryStatusEx(ref status))
        {
            win32Error = 0;
            return true;
        }
        win32Error = Marshal.GetLastWin32Error();
        return false;
    }
}
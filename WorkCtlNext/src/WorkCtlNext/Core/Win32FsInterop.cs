using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace WorkCtlNext.Core;

internal static class Win32FsInterop
{
    public const uint IO_REPARSE_TAG_MOUNT_POINT = 0xA0000003;
    public const uint IO_REPARSE_TAG_SYMLINK = 0xA000000C;
    public const uint IO_REPARSE_TAG_APPEXECLINK = 0x8000001B;

    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;

    private const uint FO_DELETE = 0x0003;
    private const ushort FOF_SILENT = 0x0004;
    private const ushort FOF_NOCONFIRMATION = 0x0010;
    private const ushort FOF_ALLOWUNDO = 0x0040;
    private const ushort FOF_NOERRORUI = 0x0400;

    public static readonly Guid FolderIdDownloads = new("374DE290-123F-4565-9164-39C4925E467B");

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME
    {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint dwFileAttributes;
        public FILETIME ftCreationTime;
        public FILETIME ftLastAccessTime;
        public FILETIME ftLastWriteTime;
        public uint dwVolumeSerialNumber;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint nNumberOfLinks;
        public uint nFileIndexHigh;
        public uint nFileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WIN32_FIND_DATAW
    {
        public uint dwFileAttributes;
        public FILETIME ftCreationTime;
        public FILETIME ftLastAccessTime;
        public FILETIME ftLastWriteTime;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint dwReserved0;
        public uint dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
        public string cAlternateFileName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 1)]
    private struct SHFILEOPSTRUCTW_X86
    {
        public IntPtr hwnd;
        public uint wFunc;
        public IntPtr pFrom;
        public IntPtr pTo;
        public ushort fFlags;
        public int fAnyOperationsAborted;
        public IntPtr hNameMappings;
        public IntPtr lpszProgressTitle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEOPSTRUCTW_X64
    {
        public IntPtr hwnd;
        public uint wFunc;
        public IntPtr pFrom;
        public IntPtr pTo;
        public ushort fFlags;
        public int fAnyOperationsAborted;
        public IntPtr hNameMappings;
        public IntPtr lpszProgressTitle;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle hFile,
        out BY_HANDLE_FILE_INFORMATION lpFileInformation);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindFirstFileW(string lpFileName, out WIN32_FIND_DATAW lpFindFileData);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindClose(IntPtr hFindFile);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperationW(ref SHFILEOPSTRUCTW_X86 lpFileOp);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperationW(ref SHFILEOPSTRUCTW_X64 lpFileOp);

    [DllImport("shell32.dll")]
    private static extern int SHGetKnownFolderPath(
        [MarshalAs(UnmanagedType.LPStruct)] Guid rfid,
        uint dwFlags,
        IntPtr hToken,
        out IntPtr ppszPath);

    public static int GetHardLinkCount(string fullPath)
    {
        if (string.IsNullOrWhiteSpace(fullPath))
            return 1;

        string winPath = PathNormalizer.EnsureLongPathPrefix(fullPath);
        using SafeFileHandle handle = CreateFileW(
            winPath,
            0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            IntPtr.Zero);

        if (handle.IsInvalid)
            return 1;

        if (GetFileInformationByHandle(handle, out BY_HANDLE_FILE_INFORMATION info) && info.nNumberOfLinks > 0)
            return (int)info.nNumberOfLinks;

        return 1;
    }

    public static bool TryGetReparseTag(string fullPath, out uint reparseTag)
    {
        reparseTag = 0;
        if (string.IsNullOrWhiteSpace(fullPath))
            return false;

        string queryPath = PathNormalizer.EnsureLongPathPrefix(fullPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        IntPtr findHandle = FindFirstFileW(queryPath, out WIN32_FIND_DATAW findData);
        if (findHandle == IntPtr.Zero || findHandle == new IntPtr(-1))
            return false;

        try
        {
            if (((FileAttributes)findData.dwFileAttributes & FileAttributes.ReparsePoint) != 0)
            {
                reparseTag = findData.dwReserved0;
                return true;
            }

            return false;
        }
        finally
        {
            FindClose(findHandle);
        }
    }

    public static string? GetKnownFolderPath(Guid folderId)
    {
        IntPtr pPath = IntPtr.Zero;
        try
        {
            int hr = SHGetKnownFolderPath(folderId, 0, IntPtr.Zero, out pPath);
            if (hr == 0 && pPath != IntPtr.Zero)
                return Marshal.PtrToStringUni(pPath);
            return null;
        }
        catch
        {
            return null;
        }
        finally
        {
            if (pPath != IntPtr.Zero)
                Marshal.FreeCoTaskMem(pPath);
        }
    }

    public static (bool Success, int Win32Error, bool Aborted) SendToRecycleBin(string fullPath)
    {
        // SHFileOperationW expects standard Win32 path without \\?\ prefix and double-null terminator.
        string shellPath = PathNormalizer.StripVerbatimPrefix(fullPath);
        if (shellPath.Length > 3)
            shellPath = shellPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

        IntPtr pFrom = AllocDoubleNullUnicode(shellPath);
        try
        {
            ushort flags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI;
            if (IntPtr.Size == 8)
            {
                var op64 = new SHFILEOPSTRUCTW_X64
                {
                    hwnd = IntPtr.Zero,
                    wFunc = FO_DELETE,
                    pFrom = pFrom,
                    pTo = IntPtr.Zero,
                    fFlags = flags,
                    fAnyOperationsAborted = 0,
                    hNameMappings = IntPtr.Zero,
                    lpszProgressTitle = IntPtr.Zero
                };
                int result = SHFileOperationW(ref op64);
                return (result == 0 && op64.fAnyOperationsAborted == 0, result, op64.fAnyOperationsAborted != 0);
            }
            else
            {
                var op86 = new SHFILEOPSTRUCTW_X86
                {
                    hwnd = IntPtr.Zero,
                    wFunc = FO_DELETE,
                    pFrom = pFrom,
                    pTo = IntPtr.Zero,
                    fFlags = flags,
                    fAnyOperationsAborted = 0,
                    hNameMappings = IntPtr.Zero,
                    lpszProgressTitle = IntPtr.Zero
                };
                int result = SHFileOperationW(ref op86);
                return (result == 0 && op86.fAnyOperationsAborted == 0, result, op86.fAnyOperationsAborted != 0);
            }
        }
        finally
        {
            if (pFrom != IntPtr.Zero)
                Marshal.FreeHGlobal(pFrom);
        }
    }

    private static IntPtr AllocDoubleNullUnicode(string value)
    {
        char[] buffer = new char[value.Length + 2];
        value.CopyTo(0, buffer, 0, value.Length);
        buffer[value.Length] = '\0';
        buffer[value.Length + 1] = '\0';
        IntPtr ptr = Marshal.AllocHGlobal(buffer.Length * sizeof(char));
        Marshal.Copy(buffer, 0, ptr, buffer.Length);
        return ptr;
    }
}

using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Xunit;

namespace WorkCtlNext.Tests;

/// <summary>
/// Real Windows ConPTY (CreatePseudoConsole) terminal lifecycle integration harness.
/// Verifies same-tab alt-screen entry/exit, cursor visibility reset, resize stability,
/// Ctrl+C termination cleanup, unchanged parent CWD, and bitwise ConsoleMode preservation.
/// </summary>
public sealed class ConPtyHostTests
{
    private const uint ExtendedStartupInfoPresent = 0x00080000;
    private static readonly nint ProcThreadAttributePseudoConsole = 0x00020016;

    [StructLayout(LayoutKind.Sequential)]
    private struct Coord(short x, short y)
    {
        public short X = x;
        public short Y = y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int nLength;
        public nint lpSecurityDescriptor;
        public int bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int cb;
        public string? lpReserved;
        public string? lpDesktop;
        public string? lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public nint lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx
    {
        public StartupInfo StartupInfo;
        public nint lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public nint hProcess;
        public nint hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe, ref SecurityAttributes lpPipeAttributes, int nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int CreatePseudoConsole(Coord size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out nint phPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int ResizePseudoConsole(nint hPC, Coord size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void ClosePseudoConsole(nint hPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(nint lpAttributeList, int dwAttributeCount, int dwFlags, ref nint lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(nint lpAttributeList, uint dwFlags, nint attribute, nint lpValue, nint cbSize, nint lpPreviousValue, nint lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void DeleteProcThreadAttributeList(nint lpAttributeList);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(
        string? lpApplicationName,
        StringBuilder lpCommandLine,
        nint lpProcessAttributes,
        nint lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        nint lpEnvironment,
        string? lpCurrentDirectory,
        ref StartupInfoEx lpStartupInfo,
        out ProcessInformation lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(nint hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(nint hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(nint hProcess, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(nint hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(nint hFile, byte[] lpBuffer, uint nNumberOfBytesToWrite, out uint lpNumberOfBytesWritten, nint lpOverlapped);

    private static string FindReleaseOrDebugBinary()
    {
        DirectoryInfo? dir = new(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "WorkCtlNext.slnx")))
            dir = dir.Parent;
        Assert.NotNull(dir);
        string rel = Path.Combine(dir.FullName, "src", "WorkCtlNext", "bin", "Release", "net10.0", "workctl-next.exe");
        if (File.Exists(rel)) return rel;
        return Path.Combine(dir.FullName, "src", "WorkCtlNext", "bin", "Debug", "net10.0", "workctl-next.exe");
    }

    private sealed class ConPtyRunner : IDisposable
    {
        public SafeFileHandle InputWrite { get; }
        public SafeFileHandle OutputRead { get; }
        private nint _pseudoConsole;
        private nint _processHandle;
        public int ProcessId { get; }
        private nint _attrList;
        private bool _disposed;

        public ConPtyRunner(string commandLine, string workingDir, short cols, short rows)
        {
            var sa = new SecurityAttributes { nLength = Marshal.SizeOf<SecurityAttributes>() };
            if (!CreatePipe(out SafeFileHandle inRead, out SafeFileHandle inWrite, ref sa, 0) ||
                !CreatePipe(out SafeFileHandle outRead, out SafeFileHandle outWrite, ref sa, 0))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            InputWrite = inWrite;
            OutputRead = outRead;

            int hr = CreatePseudoConsole(new Coord(cols, rows), inRead, outWrite, 0, out nint hPc);
            inRead.Dispose();
            outWrite.Dispose();
            if (hr != 0) throw Marshal.GetExceptionForHR(hr)!;
            _pseudoConsole = hPc;

            nint attrSize = 0;
            InitializeProcThreadAttributeList(nint.Zero, 1, 0, ref attrSize);
            _attrList = Marshal.AllocHGlobal(attrSize);
            if (!InitializeProcThreadAttributeList(_attrList, 1, 0, ref attrSize))
                throw new Win32Exception(Marshal.GetLastWin32Error());

            if (!UpdateProcThreadAttribute(_attrList, 0, ProcThreadAttributePseudoConsole, hPc, (nint)nint.Size, nint.Zero, nint.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());

            var siEx = new StartupInfoEx
            {
                StartupInfo = new StartupInfo
                {
                    cb = Marshal.SizeOf<StartupInfoEx>(),
                    dwFlags = 0x00000100, // STARTF_USESTDHANDLES = 0 handles so ConPTY attaches instead of inheriting vstest pipes
                    hStdInput = nint.Zero,
                    hStdOutput = nint.Zero,
                    hStdError = nint.Zero
                },
                lpAttributeList = _attrList
            };

            var cmd = new StringBuilder(commandLine);
            if (!CreateProcessW(null, cmd, nint.Zero, nint.Zero, false, ExtendedStartupInfoPresent, nint.Zero, workingDir, ref siEx, out ProcessInformation pi))
                throw new Win32Exception(Marshal.GetLastWin32Error());

            _processHandle = pi.hProcess;
            ProcessId = pi.dwProcessId;
            if (pi.hThread != nint.Zero) CloseHandle(pi.hThread);
        }

        public void Resize(short cols, short rows)
        {
            if (_pseudoConsole != nint.Zero)
                ResizePseudoConsole(_pseudoConsole, new Coord(cols, rows));
        }

        public void SendBytes(byte[] bytes)
        {
            if (!WriteFile(InputWrite.DangerousGetHandle(), bytes, (uint)bytes.Length, out _, nint.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        public uint WaitForExit(int timeoutMs)
        {
            uint wait = WaitForSingleObject(_processHandle, (uint)timeoutMs);
            if (wait != 0)
            {
                TerminateProcess(_processHandle, 199);
                throw new TimeoutException($"ConPTY child PID={ProcessId} timed out after {timeoutMs}ms.");
            }
            GetExitCodeProcess(_processHandle, out uint code);
            return code;
        }

        public void CloseConsole()
        {
            if (_pseudoConsole != nint.Zero)
            {
                ClosePseudoConsole(_pseudoConsole);
                _pseudoConsole = nint.Zero;
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;

            CloseConsole();
            if (_processHandle != nint.Zero)
            {
                WaitForSingleObject(_processHandle, 500);
                CloseHandle(_processHandle);
                _processHandle = nint.Zero;
            }
            if (_attrList != nint.Zero)
            {
                DeleteProcThreadAttributeList(_attrList);
                Marshal.FreeHGlobal(_attrList);
                _attrList = nint.Zero;
            }
            InputWrite.Dispose();
            OutputRead.Dispose();
        }
    }

    private sealed class StreamAccumulator
    {
        private readonly StringBuilder _sb = new();
        private readonly object _gate = new();

        public void Append(string chunk)
        {
            lock (_gate) _sb.Append(chunk);
        }

        public string Snapshot()
        {
            lock (_gate) return _sb.ToString();
        }

        public async Task<bool> WaitForSubstringAsync(string marker, TimeSpan timeout, CancellationToken ct)
        {
            DateTime deadline = DateTime.UtcNow + timeout;
            while (DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
            {
                if (Snapshot().Contains(marker, StringComparison.Ordinal))
                    return true;
                await Task.Delay(50, ct).ConfigureAwait(false);
            }
            return Snapshot().Contains(marker, StringComparison.Ordinal);
        }
    }

    private static Task StartDrainAsync(SafeFileHandle readHandle, StreamAccumulator acc, CancellationToken ct)
    {
        return Task.Run(() =>
        {
            byte[] buf = new byte[4096];
            using var fs = new FileStream(readHandle, FileAccess.Read, 4096, isAsync: false);
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    int n = fs.Read(buf, 0, buf.Length);
                    if (n <= 0) break;
                    acc.Append(Encoding.UTF8.GetString(buf, 0, n));
                }
                catch
                {
                    break;
                }
            }
        }, CancellationToken.None);
    }

    [Fact]
    public async Task ConPty_DirectTui_NormalExit_Resize_AndAltScreenRestoration()
    {
        CancellationToken ct = TestContext.Current.CancellationToken;
        string binary = FindReleaseOrDebugBinary();
        using var conpty = new ConPtyRunner($"\"{binary}\" tui", Path.GetTempPath(), 100, 28);
        var acc = new StreamAccumulator();
        using var readCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        Task drain = StartDrainAsync(conpty.OutputRead, acc, readCts.Token);

        bool entered = await acc.WaitForSubstringAsync("WorkCtl Next", TimeSpan.FromSeconds(8), ct);
        Assert.True(entered, $"Timed out waiting for WorkCtl Next UI. Captured len={acc.Snapshot().Length}: {acc.Snapshot()}");

        conpty.SendBytes(Encoding.UTF8.GetBytes("open projects\r"));
        await Task.Delay(250, ct);
        conpty.Resize(68, 18);
        await Task.Delay(250, ct);
        conpty.SendBytes([0x11]); // Ctrl+Q exits cleanly from any region (CommandLine, MainPane, or Narrow)

        uint exitCode = conpty.WaitForExit(8000);
        conpty.CloseConsole();
        await drain.WaitAsync(TimeSpan.FromSeconds(3), ct);
        string captured = acc.Snapshot();

        Assert.Equal(0u, exitCode);
        Assert.Contains("\u001b[?1049h", captured, StringComparison.Ordinal);
        Assert.Contains("\u001b[?1049l", captured, StringComparison.Ordinal);
        Assert.Contains("\u001b[?25h", captured, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ConPty_DirectTui_CtrlC_RestoresAltScreenAndExitsCleanly()
    {
        CancellationToken ct = TestContext.Current.CancellationToken;
        string binary = FindReleaseOrDebugBinary();
        using var conpty = new ConPtyRunner($"\"{binary}\" tui", Path.GetTempPath(), 90, 24);
        var acc = new StreamAccumulator();
        using var readCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        Task drain = StartDrainAsync(conpty.OutputRead, acc, readCts.Token);

        bool entered = await acc.WaitForSubstringAsync("WorkCtl Next", TimeSpan.FromSeconds(8), ct);
        Assert.True(entered, $"Timed out waiting for WorkCtl Next UI. Captured len={acc.Snapshot().Length}: {acc.Snapshot()}");

        conpty.SendBytes([0x03]); // Send Ctrl+C over ConPTY input

        uint exitCode = conpty.WaitForExit(8000);
        conpty.CloseConsole();
        await drain.WaitAsync(TimeSpan.FromSeconds(3), ct);
        string captured = acc.Snapshot();

        Assert.Equal(0u, exitCode);
        Assert.Contains("\u001b[?1049h", captured, StringComparison.Ordinal);
        Assert.Contains("\u001b[?1049l", captured, StringComparison.Ordinal);
        Assert.Contains("\u001b[?25h", captured, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ConPty_ParentPwshSession_NormalExit_PreservesModeAndCwd()
    {
        CancellationToken ct = TestContext.Current.CancellationToken;
        string binary = FindReleaseOrDebugBinary();
        string tempWorkDir = Path.Combine(Path.GetTempPath(), $"conpty_pwsh_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempWorkDir);
        string scriptPath = Path.Combine(tempWorkDir, "host_probe.ps1");

        // Use pure Win32 P/Invoke from pwsh script and log ConsoleMode + PWD before and after child TUI runs
        await File.WriteAllTextAsync(scriptPath, $@"
Add-Type -TypeDefinition '
using System;
using System.Runtime.InteropServices;
public static class ConModeCheck {{
    [DllImport(""kernel32.dll"")] public static extern IntPtr GetStdHandle(int n);
    [DllImport(""kernel32.dll"")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
    public static string Read() {{
        uint i=0, o=0;
        GetConsoleMode(GetStdHandle(-10), out i);
        GetConsoleMode(GetStdHandle(-11), out o);
        return i + "":"" + o;
    }}
}}'
$before = [ConModeCheck]::Read()
$pwdBefore = $PWD.Path
& '{binary}' tui
$childExit = $LASTEXITCODE
$after = [ConModeCheck]::Read()
$pwdAfter = $PWD.Path
Write-Output ""PWSH_PROBE|childExit=$childExit|sameMode=$($before -eq $after)|before=$before|after=$after|samePwd=$($pwdBefore -eq $pwdAfter)""
", ct);

        try
        {
            using var conpty = new ConPtyRunner(
                $"pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\"",
                tempWorkDir,
                100,
                28);

            var acc = new StreamAccumulator();
            using var readCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            Task drain = StartDrainAsync(conpty.OutputRead, acc, readCts.Token);

            bool entered = await acc.WaitForSubstringAsync("WorkCtl Next", TimeSpan.FromSeconds(15), ct);
            Assert.True(entered, $"Timed out waiting for pwsh->WorkCtl Next startup. Captured len={acc.Snapshot().Length}: {acc.Snapshot()}");

            conpty.SendBytes(Encoding.UTF8.GetBytes("exit\r"));

            uint exitCode = conpty.WaitForExit(10000);
            conpty.CloseConsole();
            await drain.WaitAsync(TimeSpan.FromSeconds(5), ct);
            string captured = acc.Snapshot();

            Assert.Equal(0u, exitCode);
            Assert.Contains("PWSH_PROBE|childExit=0|sameMode=True", captured, StringComparison.Ordinal);
            Assert.Contains("samePwd=True", captured, StringComparison.Ordinal);
        }
        finally
        {
            try { Directory.Delete(tempWorkDir, recursive: true); } catch { }
        }
    }
}
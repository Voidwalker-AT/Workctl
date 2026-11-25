using System.Diagnostics;
using System.Text;

namespace WorkCtlNext.Terminal;

/// <summary>
/// Abstraction over host console I/O and mode restoration so terminal lifecycle invariants
/// can be verified both on real Windows consoles and deterministic test doubles.
/// </summary>
public interface ITerminalBackend
{
    bool IsInteractiveTty { get; }
    int WindowWidth { get; }
    int WindowHeight { get; }
    bool SupportsCursorVisibility { get; }
    bool IsUtf8Supported { get; }
    bool TryCaptureModes(out uint inputMode, out uint outputMode);
    bool TryRestoreModes(uint inputMode, uint outputMode);
    bool TryEnableVirtualTerminalProcessing();
    bool TryEnableUtf8();
    void RestoreEncodings();
    bool TryGetCursorVisible(out bool visible);
    void SetCursorVisible(bool visible);
    void SetTreatControlCAsInput(bool treatAsInput);
    bool KeyAvailable { get; }
    ConsoleKeyInfo ReadKey(bool intercept);
    void Write(string text);
    void Flush();
    Task<int> RunForegroundCommandAsync(string executable, string arguments, string workingDirectory, CancellationToken cancellationToken);
    event ConsoleCancelEventHandler? CancelKeyPress;
}

/// <summary>
/// Real Windows Console / Windows Terminal backend using Win32 console modes, UTF-8 codepage setup, and VT sequences.
/// </summary>
public sealed class WindowsTerminalBackend : ITerminalBackend
{
    private bool _encodingCaptured;
    private Encoding? _savedInputEncoding;
    private Encoding? _savedOutputEncoding;
    private uint _savedInputCp;
    private uint _savedOutputCp;

    public bool IsInteractiveTty => !Console.IsInputRedirected && !Console.IsOutputRedirected;

    public bool IsUtf8Supported
    {
        get
        {
            try { return Console.OutputEncoding.CodePage == 65001; }
            catch { return false; }
        }
    }

    public int WindowWidth
    {
        get
        {
            try { return Math.Max(20, Console.WindowWidth); }
            catch { return 80; }
        }
    }

    public int WindowHeight
    {
        get
        {
            try { return Math.Max(8, Console.WindowHeight); }
            catch { return 24; }
        }
    }

    public bool SupportsCursorVisibility => OperatingSystem.IsWindows();

    public bool TryCaptureModes(out uint inputMode, out uint outputMode)
    {
        inputMode = 0;
        outputMode = 0;
        if (!OperatingSystem.IsWindows())
            return false;

        nint inHandle = ConsoleInterop.GetStdHandle(ConsoleInterop.StdInputHandle);
        nint outHandle = ConsoleInterop.GetStdHandle(ConsoleInterop.StdOutputHandle);
        if (inHandle == nint.Zero || inHandle == -1 || outHandle == nint.Zero || outHandle == -1)
            return false;

        return ConsoleInterop.GetConsoleMode(inHandle, out inputMode)
            && ConsoleInterop.GetConsoleMode(outHandle, out outputMode);
    }

    public bool TryRestoreModes(uint inputMode, uint outputMode)
    {
        if (!OperatingSystem.IsWindows())
            return false;

        nint inHandle = ConsoleInterop.GetStdHandle(ConsoleInterop.StdInputHandle);
        nint outHandle = ConsoleInterop.GetStdHandle(ConsoleInterop.StdOutputHandle);
        bool okIn = inHandle != nint.Zero && inHandle != -1 && ConsoleInterop.SetConsoleMode(inHandle, inputMode);
        bool okOut = outHandle != nint.Zero && outHandle != -1 && ConsoleInterop.SetConsoleMode(outHandle, outputMode);
        return okIn && okOut;
    }

    public bool TryEnableVirtualTerminalProcessing()
    {
        if (!OperatingSystem.IsWindows())
            return false;

        nint outHandle = ConsoleInterop.GetStdHandle(ConsoleInterop.StdOutputHandle);
        if (outHandle == nint.Zero || outHandle == -1)
            return false;

        if (!ConsoleInterop.GetConsoleMode(outHandle, out uint outMode))
            return false;

        uint desiredOut = outMode | ConsoleInterop.EnableVirtualTerminalProcessing | ConsoleInterop.EnableProcessedOutput;
        return ConsoleInterop.SetConsoleMode(outHandle, desiredOut);
    }

    public bool TryEnableUtf8()
    {
        if (!OperatingSystem.IsWindows())
            return IsUtf8Supported;

        try
        {
            if (!_encodingCaptured)
            {
                _savedInputEncoding = Console.InputEncoding;
                _savedOutputEncoding = Console.OutputEncoding;
                _savedInputCp = ConsoleInterop.GetConsoleCP();
                _savedOutputCp = ConsoleInterop.GetConsoleOutputCP();
                _encodingCaptured = true;
            }

            ConsoleInterop.SetConsoleCP(65001);
            ConsoleInterop.SetConsoleOutputCP(65001);
            var utf8NoBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
            Console.InputEncoding = utf8NoBom;
            Console.OutputEncoding = utf8NoBom;
            return Console.OutputEncoding.CodePage == 65001 && ConsoleInterop.GetConsoleOutputCP() == 65001;
        }
        catch
        {
            return false;
        }
    }

    public void RestoreEncodings()
    {
        if (!OperatingSystem.IsWindows() || !_encodingCaptured)
            return;

        try
        {
            if (_savedInputEncoding is not null)
                Console.InputEncoding = _savedInputEncoding;
            if (_savedOutputEncoding is not null)
                Console.OutputEncoding = _savedOutputEncoding;
            if (_savedInputCp != 0)
                ConsoleInterop.SetConsoleCP(_savedInputCp);
            if (_savedOutputCp != 0)
                ConsoleInterop.SetConsoleOutputCP(_savedOutputCp);
        }
        catch
        {
            // Best-effort console codepage restoration.
        }
    }

    public async Task<int> RunForegroundCommandAsync(
        string executable,
        string arguments,
        string workingDirectory,
        CancellationToken cancellationToken)
    {
        var psi = new ProcessStartInfo
        {
            FileName = executable,
            Arguments = arguments,
            WorkingDirectory = Directory.Exists(workingDirectory) ? workingDirectory : Environment.CurrentDirectory,
            UseShellExecute = false,
            CreateNoWindow = false
        };
        using Process? proc = Process.Start(psi);
        if (proc is null)
            return 1;
        await proc.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        return proc.ExitCode;
    }

    public bool TryGetCursorVisible(out bool visible)
    {
        visible = true;
        if (!OperatingSystem.IsWindows())
            return false;

        try
        {
            visible = Console.CursorVisible;
            return true;
        }
        catch
        {
            return false;
        }
    }

    public void SetCursorVisible(bool visible)
    {
        if (!OperatingSystem.IsWindows())
            return;
        try { Console.CursorVisible = visible; }
        catch { /* Best-effort */ }
    }

    public void SetTreatControlCAsInput(bool treatAsInput)
    {
        try { Console.TreatControlCAsInput = treatAsInput; }
        catch { /* Best-effort */ }
    }

    public bool KeyAvailable
    {
        get
        {
            try { return Console.KeyAvailable; }
            catch { return false; }
        }
    }

    public ConsoleKeyInfo ReadKey(bool intercept) => Console.ReadKey(intercept);
    public void Write(string text) => Console.Out.Write(text);
    public void Flush() => Console.Out.Flush();

    public event ConsoleCancelEventHandler? CancelKeyPress
    {
        add => Console.CancelKeyPress += value;
        remove => Console.CancelKeyPress -= value;
    }
}

public sealed record TerminalRestorationReport(
    bool EnteredAltScreen,
    bool ExitedAltScreen,
    bool CursorHiddenOnEnter,
    bool CursorRestored,
    bool ConsoleModesCaptured,
    bool ConsoleModesRestored,
    bool CancelRequested,
    string OriginalWorkingDirectory);

/// <summary>
/// RAII / try-finally guard managing same-tab VT alternate screen (?1049h/l),
/// cursor state, Win32 console modes, and Ctrl+C cancellation.
/// Note: finally guarantees restoration for normal exit, Ctrl+C, and recoverable exceptions;
/// forced external termination (e.g., taskkill /F) or machine/power failure bypasses finally blocks.
/// </summary>
public sealed class TerminalSession : IDisposable
{
    public const string EnterAltScreenSeq = "\u001b[?1049h\u001b[?25l";
    public const string ExitAltScreenSeq = "\u001b[?25h\u001b[0m\u001b[?1049l";

    private readonly ITerminalBackend _backend;
    private readonly bool _modesCaptured;
    private readonly uint _savedInputMode;
    private readonly uint _savedOutputMode;
    private readonly bool _cursorCaptured;
    private readonly bool _savedCursorVisible;
    private bool _entered;
    private bool _disposed;
    private volatile bool _cancelRequested;

    public bool CancelRequested => _cancelRequested;
    public int Width => _backend.WindowWidth;
    public int Height => _backend.WindowHeight;
    public TerminalRestorationReport LastReport { get; private set; }

    public TerminalSession(ITerminalBackend backend)
    {
        _backend = backend ?? throw new ArgumentNullException(nameof(backend));
        if (!_backend.IsInteractiveTty)
            throw new InvalidOperationException("Interactive TUI requires an interactive terminal (stdin/stdout cannot be redirected).");

        string cwd = Environment.CurrentDirectory;
        _modesCaptured = _backend.TryCaptureModes(out _savedInputMode, out _savedOutputMode);
        _cursorCaptured = _backend.TryGetCursorVisible(out _savedCursorVisible);
        LastReport = new TerminalRestorationReport(false, false, false, false, _modesCaptured, false, false, cwd);
    }

    public void Enter()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_entered) return;

        _backend.SetTreatControlCAsInput(false);
        _backend.CancelKeyPress += OnCancelKeyPress;
        _backend.TryEnableVirtualTerminalProcessing();
        _backend.TryEnableUtf8();
        _backend.SetCursorVisible(false);
        _backend.Write(EnterAltScreenSeq);
        _backend.Flush();
        _entered = true;

        LastReport = LastReport with
        {
            EnteredAltScreen = true,
            CursorHiddenOnEnter = true
        };
    }

    public void SuspendForForegroundChild()
    {
        if (!_entered || _disposed) return;
        _backend.Write(ExitAltScreenSeq);
        _backend.Flush();
        _backend.SetCursorVisible(_cursorCaptured ? _savedCursorVisible : true);
        if (_modesCaptured)
            _backend.TryRestoreModes(_savedInputMode, _savedOutputMode);
        _backend.SetTreatControlCAsInput(false);
    }

    public void ResumeAfterForegroundChild()
    {
        if (!_entered || _disposed) return;
        _backend.TryEnableVirtualTerminalProcessing();
        _backend.TryEnableUtf8();
        _backend.SetCursorVisible(false);
        _backend.Write(EnterAltScreenSeq);
        _backend.Flush();
    }

    public void RequestCancelFromSignal() => _cancelRequested = true;

    private void OnCancelKeyPress(object? sender, ConsoleCancelEventArgs e)
    {
        e.Cancel = true;
        _cancelRequested = true;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        bool exitedAlt = false;
        bool cursorRestored = false;
        bool modesRestored = false;

        try { _backend.CancelKeyPress -= OnCancelKeyPress; }
        catch { /* Best-effort */ }

        try
        {
            if (_entered)
            {
                _backend.Write(ExitAltScreenSeq);
                _backend.Flush();
                exitedAlt = true;
            }
        }
        finally
        {
            try
            {
                _backend.SetCursorVisible(_cursorCaptured ? _savedCursorVisible : true);
                cursorRestored = true;
            }
            catch { /* Best-effort */ }

            if (_modesCaptured)
                modesRestored = _backend.TryRestoreModes(_savedInputMode, _savedOutputMode);

            _backend.RestoreEncodings();
            _backend.SetTreatControlCAsInput(false);
        }

        LastReport = LastReport with
        {
            ExitedAltScreen = exitedAlt,
            CursorRestored = cursorRestored,
            ConsoleModesRestored = modesRestored,
            CancelRequested = _cancelRequested
        };
    }
}
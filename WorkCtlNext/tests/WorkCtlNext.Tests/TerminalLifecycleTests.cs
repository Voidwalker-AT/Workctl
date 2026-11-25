using System.Text;
using WorkCtlNext.Terminal;
using Xunit;

namespace WorkCtlNext.Tests;

internal sealed class FakeTerminalBackend : ITerminalBackend
{
    public bool IsInteractiveTty { get; set; } = true;
    public int WindowWidth { get; set; } = 120;
    public int WindowHeight { get; set; } = 32;
    public bool SupportsCursorVisibility => true;
    public bool Utf8Supported { get; set; } = true;
    public bool IsUtf8Supported => Utf8Supported;
    public bool FailUtf8Setup { get; set; }
    public List<(string Executable, string Arguments, string WorkingDirectory)> ForegroundCommandsLaunched { get; } = [];
    public int NextForegroundExitCode { get; set; }
    public uint CapturedInputMode { get; set; } = 0x01F7;
    public uint CapturedOutputMode { get; set; } = 0x0007;
    public uint CurrentInputMode { get; set; } = 0x01F7;
    public uint CurrentOutputMode { get; set; } = 0x0003;
    public bool CursorVisible { get; set; } = true;
    public bool TreatControlCAsInput { get; private set; }
    public StringBuilder Output { get; } = new();
    public Queue<ConsoleKeyInfo> Keys { get; } = new();
    public int RestoreModeCalls { get; private set; }
    public bool FailCaptureModes { get; set; }

#pragma warning disable CS0067
    public event ConsoleCancelEventHandler? CancelKeyPress;
#pragma warning restore CS0067

    public bool TryCaptureModes(out uint inputMode, out uint outputMode)
    {
        if (FailCaptureModes)
        {
            inputMode = 0;
            outputMode = 0;
            return false;
        }
        inputMode = CapturedInputMode;
        outputMode = CapturedOutputMode;
        return true;
    }

    public bool TryRestoreModes(uint inputMode, uint outputMode)
    {
        CurrentInputMode = inputMode;
        CurrentOutputMode = outputMode;
        RestoreModeCalls++;
        return true;
    }

    public bool TryEnableVirtualTerminalProcessing()
    {
        CurrentOutputMode |= 0x0004;
        return true;
    }

    public bool TryEnableUtf8()
    {
        if (FailUtf8Setup)
        {
            Utf8Supported = false;
            return false;
        }
        return Utf8Supported;
    }

    public void RestoreEncodings() { }

    public Task<int> RunForegroundCommandAsync(string executable, string arguments, string workingDirectory, CancellationToken cancellationToken)
    {
        ForegroundCommandsLaunched.Add((executable, arguments, workingDirectory));
        return Task.FromResult(NextForegroundExitCode);
    }

    public bool TryGetCursorVisible(out bool visible)
    {
        visible = CursorVisible;
        return true;
    }

    public void SetCursorVisible(bool visible) => CursorVisible = visible;
    public void SetTreatControlCAsInput(bool treatAsInput) => TreatControlCAsInput = treatAsInput;
    public bool KeyAvailable => Keys.Count > 0;
    public ConsoleKeyInfo ReadKey(bool intercept) => Keys.Dequeue();
    public void Write(string text) => Output.Append(text);
    public void Flush() { }
}

public sealed class TerminalLifecycleTests
{
    [Fact]
    public void NormalExit_RestoresAltScreen_Cursor_And_ConsoleModes()
    {
        var fake = new FakeTerminalBackend
        {
            CapturedInputMode = 0x01F7,
            CapturedOutputMode = 0x0003,
            CurrentInputMode = 0x0000,
            CurrentOutputMode = 0x0003,
            CursorVisible = true
        };

        TerminalSession? sessionRef;
        using (var session = new TerminalSession(fake))
        {
            sessionRef = session;
            session.Enter();
            Assert.Contains("\u001b[?1049h", fake.Output.ToString(), StringComparison.Ordinal);
            Assert.False(fake.CursorVisible);
            Assert.True((fake.CurrentOutputMode & 0x0004) != 0);
        }

        Assert.True(fake.CursorVisible);
        Assert.Equal((uint)0x01F7, fake.CurrentInputMode);
        Assert.Equal((uint)0x0003, fake.CurrentOutputMode);
        Assert.Contains("\u001b[?1049l", fake.Output.ToString(), StringComparison.Ordinal);
        Assert.Contains("\u001b[?25h", fake.Output.ToString(), StringComparison.Ordinal);
        Assert.True(sessionRef.LastReport.ExitedAltScreen);
        Assert.True(sessionRef.LastReport.ConsoleModesRestored);
    }

    [Fact]
    public void ExceptionInsideSession_StillRunsFinallyRestoration()
    {
        var fake = new FakeTerminalBackend { CapturedInputMode = 0x01E7, CapturedOutputMode = 0x0007 };
        var session = new TerminalSession(fake);

        Assert.Throws<InvalidOperationException>((Action)(() =>
        {
            using (session)
            {
                session.Enter();
                fake.CurrentInputMode = 0x0000;
                throw new InvalidOperationException("Simulated recoverable UI crash");
            }
        }));

        Assert.True(fake.CursorVisible);
        Assert.Equal((uint)0x01E7, fake.CurrentInputMode);
        Assert.True(session.LastReport.ExitedAltScreen);
        Assert.True(session.LastReport.CursorRestored);
    }

    [Fact]
    public void CtrlCSignal_RestoresTerminalCleanlyOnDispose()
    {
        var fake = new FakeTerminalBackend { CapturedInputMode = 0x01F7, CapturedOutputMode = 0x0007 };
        using var session = new TerminalSession(fake);
        session.Enter();
        session.RequestCancelFromSignal();
        Assert.True(session.CancelRequested);
        session.Dispose();

        Assert.True(session.LastReport.CancelRequested);
        Assert.True(session.LastReport.ExitedAltScreen);
        Assert.True(session.LastReport.ConsoleModesRestored);
        Assert.Equal((uint)0x01F7, fake.CurrentInputMode);
    }

    [Fact]
    public void RedirectedTty_FailsCleanlyWithoutEnteringAltScreen()
    {
        var fake = new FakeTerminalBackend { IsInteractiveTty = false };
        Assert.Throws<InvalidOperationException>((Action)(() => { _ = new TerminalSession(fake); }));
        Assert.Equal(string.Empty, fake.Output.ToString());
    }

    [Fact]
    public void DiffRenderer_HandlesResizeAndLineDiffWithoutOverflow()
    {
        var fake = new FakeTerminalBackend { WindowWidth = 30, WindowHeight = 8 };
        var renderer = new DiffRenderer(fake);

        renderer.Render(["Header very long string exceeding thirty chars", "Line 2"]);
        string first = fake.Output.ToString();
        Assert.Contains("\u001b[?2026h", first, StringComparison.Ordinal);
        Assert.Contains("\u001b[2J\u001b[H", first, StringComparison.Ordinal);

        fake.Output.Clear();
        renderer.Render(["Header very long string exceeding thirty chars", "Line 2 updated"]);
        string second = fake.Output.ToString();
        Assert.DoesNotContain("\u001b[2J", second, StringComparison.Ordinal);
        Assert.Contains("Line 2 updated", second, StringComparison.Ordinal);

        fake.Output.Clear();
        fake.WindowWidth = 22;
        fake.WindowHeight = 10;
        renderer.Render(["Header very long string", "Line 2 updated"]);
        string resized = fake.Output.ToString();
        Assert.Contains("\u001b[2J\u001b[H", resized, StringComparison.Ordinal);
    }

    [Fact]
    public void Utf8Unsupported_TriggersAsciiFallbackInSessionAndTuiTheme()
    {
        var fake = new FakeTerminalBackend { FailUtf8Setup = true };
        using var session = new TerminalSession(fake);
        session.Enter();
        Assert.False(fake.IsUtf8Supported);

        DesignTheme theme = new DesignTheme(noColor: true, asciiOnly: !fake.IsUtf8Supported);
        Assert.True(theme.AsciiOnly);
        Assert.Equal("v", theme.TreeExpanded);
        Assert.Equal(">", theme.TreeCollapsed);
        Assert.Equal("x", theme.IconErr);
    }

    [Fact]
    public void SuspendAndResumeForForegroundChild_PreservesConsoleModesAndAltScreen()
    {
        var fake = new FakeTerminalBackend
        {
            CapturedInputMode = 0x01F7,
            CapturedOutputMode = 0x0007,
            CurrentInputMode = 0x01F7,
            CurrentOutputMode = 0x0003
        };
        using var session = new TerminalSession(fake);
        session.Enter();
        fake.Output.Clear();

        session.SuspendForForegroundChild();
        Assert.True(fake.CursorVisible);
        Assert.Contains("\u001b[?1049l", fake.Output.ToString(), StringComparison.Ordinal);
        Assert.Equal((uint)0x01F7, fake.CurrentInputMode);

        fake.Output.Clear();
        session.ResumeAfterForegroundChild();
        Assert.False(fake.CursorVisible);
        Assert.Contains("\u001b[?1049h", fake.Output.ToString(), StringComparison.Ordinal);
        Assert.True((fake.CurrentOutputMode & 0x0004) != 0);
    }
}
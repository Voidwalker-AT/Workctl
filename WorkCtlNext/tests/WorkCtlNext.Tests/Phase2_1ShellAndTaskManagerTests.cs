using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using WorkCtlNext.Cli;
using WorkCtlNext.Core;
using WorkCtlNext.Providers;
using WorkCtlNext.Terminal;
using Xunit;

namespace WorkCtlNext.Tests;

public sealed partial class Phase2_1ShellAndTaskManagerTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _wsctlPath;
    private readonly string _pwshPath;
    private readonly string _ulvoPath;

    [GeneratedRegex(@"\u001b\[[0-9;?]*[A-Za-z]")]
    private static partial Regex AnsiRegex();

    public Phase2_1ShellAndTaskManagerTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"WorkCtlNext_P21_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
        Directory.CreateDirectory(Path.Combine(_tempDir, "subdir"));
        _wsctlPath = Path.Combine(_tempDir, "wsctl.ps1");
        _pwshPath = Path.Combine(_tempDir, "pwsh.exe");
        _ulvoPath = Path.Combine(_tempDir, "ulvo.exe");
        File.WriteAllText(_wsctlPath, "stub");
        File.WriteAllText(_pwshPath, "stub");
        File.WriteAllText(_ulvoPath, "stub");
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, recursive: true); } catch { }
    }

    private static string StripAnsi(string s) => AnsiRegex().Replace(s, string.Empty);

    private CapabilityDispatcher CreateDispatcher(IProcessRunner? runnerOverride = null, DispatcherPolicyMode mode = DispatcherPolicyMode.InteractivePhase2)
    {
        var runner = runnerOverride ?? new StubProcessRunner
        {
            Handler = (_, args, _) =>
            {
                if (args.Contains("projects"))
                    return Task.FromResult(new SubprocessResult(0, """[{"id":"alpha","name":"Alpha App","path":"subdir","category":"active","status":"active","environment":"uv","gpu":"none","git":true,"commands":{}}]""", "", 4, false, false, false));
                if (args.Contains("info"))
                    return Task.FromResult(new SubprocessResult(0, $$"""{"workspaceRoot":"{{_tempDir.Replace("\\", "\\\\")}}","projectsCount":1}""", "", 4, false, false, false));
                if (args.Contains("ls"))
                    return Task.FromResult(new SubprocessResult(0, "[]", "", 4, false, false, false));
                return Task.FromResult(new SubprocessResult(0, """{"schema_version":1,"version":"1.2.0","registered_projects":1,"vault_exists":true}""", "", 4, false, false, false));
            }
        };

        var cfg = new WorkctlPathsConfig(_tempDir, _wsctlPath, _pwshPath, _ulvoPath, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        return new CapabilityDispatcher(cfg, runner, policyMode: mode);
    }

    [Fact]
    public async Task StartupFocus_StartsInCommandEditor_TypingNeverHijacked_AndTabCompletesInPlace()
    {
        CapabilityDispatcher disp = CreateDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
        var app = new TuiApp(disp, fake, new TuiVisualOptions(NoColor: false, ReducedMotion: true, AsciiOnly: false));
        await app.RefreshAllProvidersAsync(TestContext.Current.CancellationToken);

        Assert.Equal(FocusRegion.CommandLine, app.Session.Focus);
        Assert.Equal(NavigationSectionId.MachineOverview, app.Session.CurrentSection);

        // Typing 'q', '2', '/', '[' must stay inside command buffer rather than quitting or navigating!
        foreach (char ch in "q2/[")
            fake.Keys.Enqueue(new ConsoleKeyInfo(ch, ConsoleKey.NoName, false, false, false));
        // Clear buffer via Ctrl+U, then type 'ta' + Tab (completes 'tasks' without leaving CommandLine), Shift+Tab cycles backward, Ctrl+Q exits cleanly
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0015', ConsoleKey.U, false, false, true));
        fake.Keys.Enqueue(new ConsoleKeyInfo('t', ConsoleKey.T, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('a', ConsoleKey.A, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\t', ConsoleKey.Tab, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\t', ConsoleKey.Tab, true, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true));

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        int exit = await app.RunAsync(cts.Token);
        Assert.Equal(0, exit);
        Assert.Equal(FocusRegion.CommandLine, app.Session.Focus);
        Assert.Equal(NavigationSectionId.MachineOverview, app.Session.CurrentSection);
    }

    [Fact]
    public async Task TreeIndicators_RenderUnicodeWhenUtf8Supported_AndAutoFallbackToAsciiZeroQuestionMarks()
    {
        CapabilityDispatcher disp = CreateDispatcher();

        // Case 1: UTF-8 supported -> Unicode arrows ▾ / ▸, zero '?' glyph corruption
        var utf8Fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32, Utf8Supported = true };
        var utf8App = new TuiApp(disp, utf8Fake, new TuiVisualOptions(false, true, false));
        await utf8App.RefreshAllProvidersAsync(TestContext.Current.CancellationToken);
        string utf8Frame = string.Join("\n", utf8App.RenderFrame(120, 32).Select(StripAnsi));
        Assert.Contains("▾", utf8Frame);
        Assert.DoesNotContain("? MACHINE", utf8Frame);

        // Case 2: UTF-8 unsupported -> RunAsync auto-enables AsciiOnly fallback ('v' / '>') with zero '?' or Unicode symbols
        var asciiFake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32, FailUtf8Setup = true };
        asciiFake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true));
        var asciiApp = new TuiApp(disp, asciiFake, new TuiVisualOptions(false, true, false));
        await asciiApp.RunAsync(TestContext.Current.CancellationToken);
        string asciiFrame = string.Join("\n", asciiApp.RenderFrame(120, 32).Select(StripAnsi));
        Assert.True(asciiApp.ActiveTheme.AsciiOnly);
        Assert.Contains("v MACHINE", asciiFrame);
        Assert.DoesNotContain("▾", asciiFrame);
        Assert.DoesNotContain("?", asciiFrame);
    }

    [Fact]
    public async Task ShellCommandRouter_DistinguishesFourModes_PreservesRawSyntax_AndLaunchesForegroundHandoff()
    {
        var cfg = new WorkctlPathsConfig(_tempDir, _wsctlPath, _pwshPath, _ulvoPath, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));

        Assert.Equal(ShellExecutionKind.WorkCtlNative, ShellCommandRouter.Classify("tasks", cfg).Kind);
        Assert.Equal(ShellExecutionKind.WorkCtlNative, ShellCommandRouter.Classify(":open projects", cfg).Kind);

        var pwshCls = ShellCommandRouter.Classify("pwsh Get-ChildItem | Where-Object {$_.Length -gt 0}", cfg);
        Assert.Equal(ShellExecutionKind.PowerShellCaptured, pwshCls.Kind);
        Assert.Equal("Get-ChildItem | Where-Object {$_.Length -gt 0}", pwshCls.EffectiveCommand);

        var cmdletCls = ShellCommandRouter.Classify("Get-Process | Sort-Object CPU", cfg);
        Assert.Equal(ShellExecutionKind.PowerShellCaptured, cmdletCls.Kind);
        Assert.Equal("Get-Process | Sort-Object CPU", cmdletCls.EffectiveCommand);

        var cmdCls = ShellCommandRouter.Classify("cmd dir /b && ver", cfg);
        Assert.Equal(ShellExecutionKind.CmdCaptured, cmdCls.Kind);
        Assert.Equal("dir /b && ver", cmdCls.EffectiveCommand);

        Assert.Equal(ShellExecutionKind.InteractiveForeground, ShellCommandRouter.Classify("!python", cfg).Kind);
        Assert.Equal(ShellExecutionKind.InteractiveForeground, ShellCommandRouter.Classify("fg vim notes.txt", cfg).Kind);
        Assert.Equal(ShellExecutionKind.InteractiveForeground, ShellCommandRouter.Classify("pwsh", cfg).Kind);

        // Execute captured PowerShell + foreground handoff inside TuiApp via mocked runner & FakeTerminalBackend
        var capturedCalls = new List<(string Exe, string Args)>();
        var runner = new StubProcessRunner
        {
            Handler = (exe, args, _) =>
            {
                capturedCalls.Add((exe, string.Join(" ", args)));
                if (args.Any(a => a.Contains("Get-Location", StringComparison.Ordinal)))
                    return Task.FromResult(new SubprocessResult(0, "Path\n----\n" + _tempDir, "", 12, false, false, false));
                if (args.Contains("projects"))
                    return Task.FromResult(new SubprocessResult(0, "[]", "", 3, false, false, false));
                if (args.Contains("info"))
                    return Task.FromResult(new SubprocessResult(0, $$"""{"workspaceRoot":"{{_tempDir.Replace("\\", "\\\\")}}","projectsCount":0}""", "", 3, false, false, false));
                return Task.FromResult(new SubprocessResult(0, "{}", "", 3, false, false, false));
            }
        };

        var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32, NextForegroundExitCode = 0 };
        CapabilityDispatcher disp = CreateDispatcher(runner);
        var app = new TuiApp(disp, fake, new TuiVisualOptions(false, true, false));

        await app.ExecuteCommandLineAsync("pwsh Get-Location", TestContext.Current.CancellationToken);
        await app.ExecuteCommandLineAsync("fg vim README.md", TestContext.Current.CancellationToken);

        Assert.Contains(capturedCalls, c => c.Args.Contains("Get-Location", StringComparison.Ordinal));
        Assert.Single(fake.ForegroundCommandsLaunched);
        Assert.Equal("vim", fake.ForegroundCommandsLaunched[0].Executable);
        Assert.Equal("README.md", fake.ForegroundCommandsLaunched[0].Arguments);

        string consoleFrame = string.Join("\n", app.RenderFrame(120, 32).Select(StripAnsi));
        Assert.Contains("SHELL TRANSCRIPT", consoleFrame);
        Assert.Contains("Get-Location", consoleFrame);
        Assert.Contains("fg vim README.md", consoleFrame);
    }

    [Fact]
    public void WindowsTelemetryProvider_BuildsCausalTree_RejectsPidReuseParent_AndProtectsSelf()
    {
        var telemetry = new WindowsTelemetryProvider();
        ProcessListSnapshot snap = telemetry.GetProcesses(limit: 20, sort: ProcessSortField.Cpu);
        Assert.NotEmpty(snap.TopProcesses);
        Assert.True(snap.TotalProcessCount >= snap.TopProcesses.Count);

        // Synthetic PID-reuse check: child started BEFORE apparent parent -> causal link rejected!
        var entries = new[]
        {
            new ProcessEntrySnapshot(100, "new-parent", 1024, 1024, TimeSpan.Zero, 0.1, 1, "C:\\new.exe", null, ParentPid: 1, CreationTimeUtcTicks: 2000),
            new ProcessEntrySnapshot(200, "older-child", 1024, 1024, TimeSpan.Zero, 0.1, 1, "C:\\old.exe", null, ParentPid: 100, CreationTimeUtcTicks: 1000),
            new ProcessEntrySnapshot(300, "valid-child", 1024, 1024, TimeSpan.Zero, 0.1, 1, "C:\\ok.exe", null, ParentPid: 100, CreationTimeUtcTicks: 3000)
        };

        IReadOnlyList<ProcessTreeRow> tree = WindowsTelemetryProvider.BuildProcessTree(entries);
        ProcessTreeRow oldChildRow = tree.Single(r => r.Process.Pid == 200);
        ProcessTreeRow validChildRow = tree.Single(r => r.Process.Pid == 300);
        Assert.False(oldChildRow.HasValidParent);
        Assert.Equal(0, oldChildRow.Depth);
        Assert.True(validChildRow.HasValidParent);
        Assert.Equal(1, validChildRow.Depth);

        // Self-protection inspection
        ProcessDetailedInspection? self = telemetry.InspectProcess(Environment.ProcessId);
        Assert.NotNull(self);
        Assert.True(self!.IsWorkCtlSelf);
        Assert.True(self.IsProtected);
        Assert.False(string.IsNullOrWhiteSpace(self.BlockReason));
    }

    [Fact]
    public async Task GuardedProcessTermination_BlocksProtectedAndPidReuse_RequiresTwoStepConfirm_AndTerminatesOnlyIsolatedChild()
    {
        var telemetry = new WindowsTelemetryProvider();
        var termService = new ProcessTerminationService(telemetry);

        // System / self must always be rejected safely
        Assert.False(termService.AnalyzeImpact(Environment.ProcessId).CanTerminate);
        Assert.False(termService.AnalyzeImpact(4).CanTerminate);

        // Launch an isolated disposable child process in TEMP (headless ping sleep, always killed in finally)
        using Process child = Process.Start(new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = "/d /c ping -n 30 127.0.0.1 >nul",
            WorkingDirectory = _tempDir,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        })!;

        try
        {
            long actualCreationTicks = child.StartTime.ToUniversalTime().Ticks;

            // Mismatched creation timestamp MUST abort as PID reuse!
            ProcessImpactAssessment reusedCheck = termService.AnalyzeImpact(
                child.Id,
                expectedCreationUtcTicks: actualCreationTicks - TimeSpan.FromMinutes(10).Ticks,
                expectedName: "cmd");
            Assert.True(reusedCheck.PidReused);
            Assert.False(reusedCheck.CanTerminate);
            Assert.False(child.HasExited);

            // Real target impact assessment: honest Verified / Possible / Unknown + non-windowed graceful notice
            ProcessImpactAssessment impact = termService.AnalyzeImpact(child.Id, actualCreationTicks);
            Assert.True(impact.ProcessExists);
            Assert.False(impact.PidReused);
            Assert.True(impact.CanTerminate);
            Assert.False(impact.SupportsGracefulClose);
            Assert.NotEmpty(impact.VerifiedRelationships);
            Assert.NotEmpty(impact.PossibleConsequences);
            Assert.NotEmpty(impact.UnknownEffects);

            // Missing 2nd confirmation MUST NOT terminate
            ProcessTerminationResult blockedSecond = termService.ForceTerminate(impact.ExpectedIdentity, secondConfirmationExplicit: false);
            Assert.False(blockedSecond.Success);
            Assert.Equal("SECOND_CONFIRMATION_REQUIRED", blockedSecond.ErrorCode);
            Assert.False(child.HasExited);

            // TUI 2-step flow: Step 1 -> cancel keeps alive; Step 1 -> Enter -> Step 2 wrong token blocked -> KILL <PID> succeeds
            CapabilityDispatcher disp = CreateDispatcher();
            var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
            var app = new TuiApp(disp, fake, new TuiVisualOptions(false, true, false));
            await app.ExecuteCommandLineAsync($"kill {child.Id}", TestContext.Current.CancellationToken);
            Assert.Equal(ModalKind.ConfirmTerminateStep1, app.CurrentModal?.Kind);

            string modalFrame = string.Join("\n", app.RenderFrame(120, 32).Select(StripAnsi));
            Assert.Contains("Step 1 Impact Preview", modalFrame);
            Assert.Contains("Step 2 Kill", modalFrame);

            // Escape Step 1 -> child remains alive
            fake.Keys.Enqueue(new ConsoleKeyInfo('\u001b', ConsoleKey.Escape, false, false, false));
            fake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true));
            await app.RunAsync(TestContext.Current.CancellationToken);
            Assert.Null(app.CurrentModal);
            Assert.False(child.HasExited);

            // Open Step 1 -> Advance to Step 2 -> wrong text shows mismatch -> exact KILL <PID> terminates child!
            await app.ExecuteCommandLineAsync($"kill {child.Id}", TestContext.Current.CancellationToken);
            fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false)); // Step 1 -> Step 2
            fake.Keys.Enqueue(new ConsoleKeyInfo('x', ConsoleKey.X, false, false, false));
            fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false)); // Blocked mismatch
            // Clear 'x' with Backspace, then type "KILL <PID>"
            fake.Keys.Enqueue(new ConsoleKeyInfo('\b', ConsoleKey.Backspace, false, false, false));
            foreach (char ch in $"KILL {child.Id}")
                fake.Keys.Enqueue(new ConsoleKeyInfo(ch, ConsoleKey.NoName, false, false, false));
            fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
            fake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true));

            int exitCode = await app.RunAsync(TestContext.Current.CancellationToken);
            Assert.Equal(0, exitCode);
            Assert.True(child.WaitForExit(3000));
        }
        finally
        {
            try
            {
                if (!child.HasExited)
                    child.Kill(entireProcessTree: true);
            }
            catch { }
        }
    }

    [Fact]
    public async Task AgentCli_TasksListAndInspectWorkReadOnly_WhileKillAndShellCommandsRemainBlocked()
    {
        CapabilityDispatcher disp = CreateDispatcher(mode: DispatcherPolicyMode.ReadOnly);

        // Read-only tasks list
        using var outWriter = new StringWriter();
        using var errWriter = new StringWriter();
        var cli = new AgentCli(disp, outWriter, errWriter);
        int exitList = await cli.ExecuteAsync(["tasks", "--sort", "mem", "--limit", "5", "--json"], TestContext.Current.CancellationToken);
        Assert.Equal(0, exitList);
        string json = outWriter.ToString();
        Assert.DoesNotContain("\u001b[", json, StringComparison.Ordinal);
        using (var doc = JsonDocument.Parse(json))
        {
            Assert.True(doc.RootElement.GetProperty("ok").GetBoolean());
            Assert.Equal("windows.processes", doc.RootElement.GetProperty("capability").GetString());
        }

        // Read-only inspect on self PID
        using var inspOut = new StringWriter();
        using var inspErr = new StringWriter();
        var inspCli = new AgentCli(disp, inspOut, inspErr);
        int exitInsp = await inspCli.ExecuteAsync(["tasks", "inspect", "--pid", Environment.ProcessId.ToString(), "--json"], TestContext.Current.CancellationToken);
        Assert.Equal(0, exitInsp);
        using (var doc = JsonDocument.Parse(inspOut.ToString()))
        {
            Assert.True(doc.RootElement.GetProperty("ok").GetBoolean());
            Assert.Equal("tasks.inspect", doc.RootElement.GetProperty("capability").GetString());
            Assert.True(doc.RootElement.GetProperty("data").GetProperty("isProtected").GetBoolean());
        }

        // Blocked commands on AgentCli: kill, pwsh, cmd -> exit 2 POLICY_BLOCKED
        string[][] blockedMatrix =
        [
            ["kill", "1234", "--json"],
            ["pwsh", "Get-Date", "--json"],
            ["cmd", "ver", "--json"]
        ];
        foreach (string[] blockedArgs in blockedMatrix)
        {
            using var bOut = new StringWriter();
            using var bErr = new StringWriter();
            var bCli = new AgentCli(disp, bOut, bErr);
            int code = await bCli.ExecuteAsync(blockedArgs, TestContext.Current.CancellationToken);
            Assert.Equal(2, code);
            Assert.Contains("POLICY_BLOCKED", bOut.ToString(), StringComparison.Ordinal);
        }
    }
}

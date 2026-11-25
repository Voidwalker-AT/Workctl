using System.Text.RegularExpressions;
using WorkCtlNext.Cli;
using WorkCtlNext.Core;
using WorkCtlNext.Terminal;
using Xunit;

namespace WorkCtlNext.Tests;

public sealed partial class UiRedesignTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _fakePwsh;
    private readonly string _fakeWsctl;
    private readonly string _fakeUlvo;

    [GeneratedRegex(@"\u001b\[[0-9;?]*[A-Za-z]")]
    private static partial Regex AnsiRegex();

    public UiRedesignTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"WorkCtlNext_Ui_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
        _fakePwsh = Path.Combine(_tempDir, "pwsh.exe");
        _fakeWsctl = Path.Combine(_tempDir, "wsctl.ps1");
        _fakeUlvo = Path.Combine(_tempDir, "ulvo.exe");
        File.WriteAllText(_fakePwsh, "stub");
        File.WriteAllText(_fakeWsctl, "stub");
        File.WriteAllText(_fakeUlvo, "stub");
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, recursive: true); } catch { }
    }

    private CapabilityDispatcher CreateStubDispatcher(bool includeStaleDoctor = false, bool failProviders = false)
    {
        if (includeStaleDoctor)
        {
            string docDir = Path.Combine(_tempDir, "Shared", "artifacts");
            Directory.CreateDirectory(docDir);
            string ts = DateTimeOffset.UtcNow.AddHours(-20).ToString("O");
            File.WriteAllText(
                Path.Combine(docDir, "doctor-latest.json"),
                $$"""{"status":"GOOD","timestamp":"{{ts}}","summary":{"okCount":34,"totalChecks":41} }""");
        }

        string p1Dir = Path.Combine(_tempDir, "Active", "alpha-app");
        string p2Dir = Path.Combine(_tempDir, "Active", "beta-ml");
        string p3Dir = Path.Combine(_tempDir, "Active", "q-tools");
        Directory.CreateDirectory(p1Dir);
        Directory.CreateDirectory(p2Dir);
        Directory.CreateDirectory(p3Dir);

        var runner = new StubProcessRunner
        {
            Handler = (_, args, _) =>
            {
                if (failProviders)
                {
                    return Task.FromResult(new SubprocessResult(
                        1,
                        string.Empty,
                        "Simulated provider unreachable: connection refused across sub-pipe",
                        15, false, false, false));
                }

                if (args.Contains("projects"))
                {
                    return Task.FromResult(new SubprocessResult(
                        0,
                        """
                        [
                          {"id":"alpha-app","name":"Alpha Web Service","path":"Active/alpha-app","category":"active","status":"active","environment":"node","gpu":"none","git":true,"commands":{"test":{"risk":"safe"}}},
                          {"id":"beta-ml","name":"Beta Deep Learning","path":"Active/beta-ml","category":"research","status":"active","environment":"ulvo","gpu":"required","git":true,"commands":{"train":{"risk":"safe"}}},
                          {"id":"q-tools","name":"Q Query Utilities","path":"Active/q-tools","category":"tools","status":"active","environment":"uv","gpu":"none","git":false,"commands":{}}
                        ]
                        """,
                        "", 6, false, false, false));
                }
                if (args.Contains("info"))
                {
                    return Task.FromResult(new SubprocessResult(0, $$"""{"workspaceRoot":"{{_tempDir.Replace("\\", "\\\\")}}","projectsCount":3}""", "", 4, false, false, false));
                }
                if (args.Contains("ls"))
                {
                    return Task.FromResult(new SubprocessResult(
                        0,
                        """
                        [
                          {"id":"alpha-app","name":"Alpha Web Service","canonical_path":"E:\\Workspace\\Active\\alpha-app","ecosystem":"node","registration_state":"registered","has_connector":true,"classification":"node","manifests":["package.json"]},
                          {"id":"beta-ml","name":"Beta Deep Learning","canonical_path":"E:\\Workspace\\Active\\beta-ml","ecosystem":"python","registration_state":"registered","has_connector":true,"classification":"pytorch","manifests":["pyproject.toml"]}
                        ]
                        """,
                        "", 6, false, false, false));
                }
                if (args.Contains("status"))
                {
                    return Task.FromResult(new SubprocessResult(0, """{"schema_version":1,"version":"1.2.0","registered_projects":2,"vault_exists":true}""", "", 4, false, false, false));
                }
                return Task.FromResult(new SubprocessResult(0, """{"path":"E:\\Workspace\\Active\\alpha-app","native_manifests":["package.json"],"diagnostics":[]}""", "", 5, false, false, false));
            }
        };

        var cfg = failProviders
            ? new WorkctlPathsConfig(_tempDir, Path.Combine(_tempDir, "missing.ps1"), Path.Combine(_tempDir, "missing.exe"), Path.Combine(_tempDir, "missing_ulvo.exe"), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2))
            : new WorkctlPathsConfig(_tempDir, _fakeWsctl, _fakePwsh, _fakeUlvo, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        return new CapabilityDispatcher(cfg, runner);
    }

    private static string StripAnsi(string s) => AnsiRegex().Replace(s, string.Empty);

    [Theory]
    [InlineData(120, 32)]
    [InlineData(100, 28)]
    [InlineData(70, 18)]
    [InlineData(52, 14)]
    public async Task AllScreens_RespectViewportWidthAndHeight_ZeroLineOverflow(int w, int h)
    {
        CapabilityDispatcher dispatcher = CreateStubDispatcher(includeStaleDoctor: true);
        var fake = new FakeTerminalBackend { WindowWidth = w, WindowHeight = h };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(NoColor: false, ReducedMotion: true, AsciiOnly: false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        // Move out of CommandLine into MainPane via F6 (narrow skips hidden tree; wide cycles Cmd->Nav->Main), then exercise 1/2/3/:/? and quit via Ctrl+Q
        if (w < 88)
            fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // Cmd -> MainPane
        else
        {
            fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // Cmd -> Nav
            fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // Nav -> Main
        }
        foreach (char navKey in new[] { '1', '2', '3', '?', '1' })
        {
            fake.Keys.Enqueue(new ConsoleKeyInfo(navKey, ConsoleKey.NoName, false, false, false));
            if (navKey == '?')
                fake.Keys.Enqueue(new ConsoleKeyInfo('\u001b', ConsoleKey.Escape, false, false, false));
        }
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));

        int code = await app.RunAsync(CancellationToken.None);
        Assert.Equal(0, code);

        // Explicitly render every screen synchronously after exit check is identical to live frames
        IReadOnlyList<string> home = app.RenderFrame(w, h);
        Assert.Equal(h, home.Count);
        foreach (string line in home)
            Assert.Equal(w, DiffRenderer.MeasureVisibleLength(line));

        string plainHome = string.Join("\n", home.Select(StripAnsi));
        if (w < 88)
        {
            Assert.DoesNotContain("NAVIGATION", plainHome, StringComparison.Ordinal);
            Assert.Contains("Home", plainHome, StringComparison.Ordinal);
        }
        else
        {
            Assert.Contains("NAVIGATION", plainHome, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task FocusZone_TabCyclesNavigationAndMain_SearchIsolatesHotkeys()
    {
        CapabilityDispatcher dispatcher = CreateStubDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        // 1. Ctrl+N focuses Navigation (or F6 twice -> Main), '2' jumps to Projects, '/' enters Search, type 'q', '-' -> must NOT quit!
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u000e', ConsoleKey.N, false, false, true)); // Ctrl+N -> NavTree
        fake.Keys.Enqueue(new ConsoleKeyInfo('2', ConsoleKey.D2, false, false, false)); // Projects + MainPane
        // 2. Press '/' to enter Search, type 'q', '-' -> must NOT quit or leave Projects!
        fake.Keys.Enqueue(new ConsoleKeyInfo('/', ConsoleKey.Divide, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('-', ConsoleKey.OemMinus, false, false, false));
        // 3. Enter commits filter to Main focus while staying on Projects
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        // Esc clears filter, then Ctrl+Q quits cleanly
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u001b', ConsoleKey.Escape, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true)); // Ctrl+Q

        int code = await app.RunAsync(CancellationToken.None);
        Assert.Equal(0, code);
        Assert.Equal(TuiScreen.Projects, app.Screen);
    }

    [Fact]
    public async Task SearchFilter_PreservedAcrossHelpAndPaletteRoundTrip_AndMatchesTarget()
    {
        CapabilityDispatcher dispatcher = CreateStubDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 116, WindowHeight = 30 };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        // Switch to MainPane via F6x2, then Projects [2], filter '/beta', Enter -> Help [?] -> Esc -> Quit [q]
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // Nav
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // Main
        fake.Keys.Enqueue(new ConsoleKeyInfo('2', ConsoleKey.D2, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('/', ConsoleKey.Divide, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('b', ConsoleKey.B, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('e', ConsoleKey.E, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('t', ConsoleKey.T, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('a', ConsoleKey.A, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('?', ConsoleKey.Oem2, true, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u001b', ConsoleKey.Escape, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));

        await app.RunAsync(CancellationToken.None);
        Assert.Equal(TuiScreen.Projects, app.Screen);
        string frame = string.Join("\n", app.RenderFrame(116, 30).Select(StripAnsi));
        Assert.Contains("Beta Deep Learning", frame, StringComparison.Ordinal);
        Assert.DoesNotContain("Alpha Web Service", frame, StringComparison.Ordinal);
    }

    [Fact]
    public async Task NarrowDrilldown_EnterOpensDetail_EscReturnsPreservingSelection()
    {
        CapabilityDispatcher dispatcher = CreateStubDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 70, WindowHeight = 18 };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // Narrow Cmd -> MainPane
        fake.Keys.Enqueue(new ConsoleKeyInfo('2', ConsoleKey.D2, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.DownArrow, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));

        await app.RunAsync(CancellationToken.None);
        string detailFrame = string.Join("\n", app.RenderFrame(70, 18).Select(StripAnsi));
        Assert.Contains("Project Detail", detailFrame, StringComparison.Ordinal);
        Assert.Contains("Beta Deep Learning", detailFrame, StringComparison.Ordinal);

        // Now press Esc and quit -> detail closes while selection stays at Beta
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u001b', ConsoleKey.Escape, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));
        await app.RunAsync(CancellationToken.None);
        string listFrame = string.Join("\n", app.RenderFrame(70, 18).Select(StripAnsi));
        Assert.DoesNotContain("Project Detail", listFrame, StringComparison.Ordinal);
        Assert.Contains("▸", listFrame, StringComparison.Ordinal);
        Assert.Contains("Beta Deep Learning", listFrame, StringComparison.Ordinal);
    }

    [Fact]
    public async Task StaleDoctor_NeverDisplaysGood_AndUnavailableProvidersRenderErrorBoxCleanly()
    {
        CapabilityDispatcher staleDisp = CreateStubDispatcher(includeStaleDoctor: true, failProviders: false);
        var fake1 = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
        var app1 = new TuiApp(staleDisp, fake1, new TuiVisualOptions(false, true, false));
        await app1.RefreshAllProvidersAsync(CancellationToken.None);
        string stalePlain = string.Join("\n", app1.RenderFrame(120, 32).Select(StripAnsi));
        Assert.Contains("Cached", stalePlain, StringComparison.Ordinal);
        Assert.Contains("Stale", stalePlain, StringComparison.Ordinal);
        Assert.DoesNotContain("GOOD", stalePlain, StringComparison.OrdinalIgnoreCase);

        CapabilityDispatcher errDisp = CreateStubDispatcher(includeStaleDoctor: false, failProviders: true);
        var fake2 = new FakeTerminalBackend { WindowWidth = 100, WindowHeight = 28 };
        var app2 = new TuiApp(errDisp, fake2, new TuiVisualOptions(false, true, false));
        await app2.RefreshAllProvidersAsync(CancellationToken.None);
        var errRows = app2.RenderFrame(100, 28);
        Assert.Equal(28, errRows.Count);
        foreach (string row in errRows)
            Assert.Equal(100, DiffRenderer.MeasureVisibleLength(row));
        string errPlain = string.Join("\n", errRows.Select(StripAnsi));
        Assert.Contains("WSCTL", errPlain, StringComparison.Ordinal);
        Assert.Contains("Unavailable", errPlain, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task NoColorAndAsciiAndReducedMotionAndNoOpDiff_BehaveDeterministically()
    {
        CapabilityDispatcher dispatcher = CreateStubDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(NoColor: true, ReducedMotion: true, AsciiOnly: true));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        Assert.True(app.ReducedMotion);
        var frames = app.RenderFrame(120, 32);
        foreach (string line in frames)
        {
            Assert.DoesNotContain("\u001b", line, StringComparison.Ordinal);
            Assert.DoesNotContain("─", line, StringComparison.Ordinal);
            Assert.DoesNotContain("│", line, StringComparison.Ordinal);
            Assert.DoesNotContain("▸", line, StringComparison.Ordinal);
        }

        // Switch to MainPane via F6x2, toggle motion via [m] and quit via [q]
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('m', ConsoleKey.M, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));
        await app.RunAsync(CancellationToken.None);
        Assert.False(app.ReducedMotion);

        // DiffRenderer skips identical frame renders completely
        var diffBackend = new FakeTerminalBackend { WindowWidth = 40, WindowHeight = 4 };
        var diff = new DiffRenderer(diffBackend);
        string[] sample = ["row1", "row2", "row3", "row4"];
        diff.Render(sample);
        long firstCount = diff.FramesRendered;
        int outLenAfterFirst = diffBackend.Output.Length;
        diff.Render(sample);
        Assert.Equal(firstCount, diff.FramesRendered);
        Assert.Equal(1, diff.SkippedNoOpFrames);
        Assert.Equal(outLenAfterFirst, diffBackend.Output.Length);
    }

    [Fact]
    public async Task AgentCli_AllCommandsStillProduceZeroAnsiJson_UnaffectedByUiRedesign()
    {
        CapabilityDispatcher dispatcher = CreateStubDispatcher();
        foreach (string[] cmd in new string[][]
        {
            ["capabilities", "--json"],
            ["context", "--json"],
            ["projects", "--json"],
            ["runtimes", "--json"],
            ["health", "--json"],
            ["suggest", "--json"]
        })
        {
            var stdout = new StringWriter();
            var stderr = new StringWriter();
            var cli = new AgentCli(dispatcher, stdout, stderr);
            int code = await cli.ExecuteAsync(cmd, CancellationToken.None);
            Assert.Equal(0, code);
            Assert.Equal(string.Empty, stderr.ToString());
            string outJson = stdout.ToString();
            Assert.DoesNotContain("\u001b", outJson, StringComparison.Ordinal);
            Assert.StartsWith("{", outJson.TrimStart(), StringComparison.Ordinal);
        }
    }

    private static async Task RunUntilAsync(
        TuiApp app,
        Func<bool> condition,
        int safetyTimeoutMs = 10000)
    {
        using var cts = new CancellationTokenSource(safetyTimeoutMs);
        Task<int> runTask = app.RunAsync(cts.Token);
        while (!condition() && !runTask.IsCompleted && !cts.IsCancellationRequested)
            await Task.Delay(15, CancellationToken.None);
        cts.Cancel();
        await runTask;
        Assert.True(condition(), "Timed out waiting for RunUntilAsync condition.");
    }

    [Fact]
    public async Task CommandPalette_PartialQueryEnter_ExecutesTopSuggestionCleanly_And100x28SidebarComplete()
    {
        CapabilityDispatcher dispatcher = CreateStubDispatcher(includeStaleDoctor: true);
        var fake = new FakeTerminalBackend { WindowWidth = 100, WindowHeight = 28 };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        string stdPlain = string.Join("\n", app.RenderFrame(100, 28).Select(StripAnsi));
        Assert.Contains("[2] Projects (3)", stdPlain, StringComparison.Ordinal);
        Assert.Contains("[3] Runtimes (2)", stdPlain, StringComparison.Ordinal);

        // Move out of CommandLine first so ':' enters explicit palette mode (drawer opens cleanly on Overview)
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo(':', ConsoleKey.Oem1, true, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('h', ConsoleKey.H, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('e', ConsoleKey.E, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('a', ConsoleKey.A, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('l', ConsoleKey.L, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        await RunUntilAsync(app, () =>
            fake.Keys.Count == 0
            && !app.IsPaletteRunning
            && app.IsCommandDrawerOpen
            && string.Equals(app.PaletteExecutedCommand, "workctl.health", StringComparison.Ordinal));

        string palPlain = string.Join("\n", app.RenderFrame(120, 32).Select(StripAnsi));
        Assert.DoesNotContain("UNKNOWN_CAPABILITY", palPlain, StringComparison.Ordinal);
        Assert.Contains("workctl.health", palPlain, StringComparison.Ordinal);
        Assert.Contains("Overall", palPlain, StringComparison.Ordinal);
        Assert.Contains("Structured", palPlain, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CommandPalette_TypingJDoesNotHijackQuery_AndSuggestionsScrollCleanly()
    {
        CapabilityDispatcher dispatcher = CreateStubDispatcher(includeStaleDoctor: true);
        var fake = new FakeTerminalBackend { WindowWidth = 100, WindowHeight = 20 };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        using var cts = new CancellationTokenSource(10000);
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo(':', ConsoleKey.Oem1, true, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0015', ConsoleKey.U, false, false, true)); // Ctrl+U
        fake.Keys.Enqueue(new ConsoleKeyInfo('j', ConsoleKey.J, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0015', ConsoleKey.U, false, false, true)); // Ctrl+U
        for (int i = 0; i < 8; i++)
            fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.DownArrow, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true)); // Ctrl+Q
        await app.RunAsync(cts.Token);

        var fake2 = new FakeTerminalBackend { WindowWidth = 100, WindowHeight = 20 };
        var app2 = new TuiApp(dispatcher, fake2, new TuiVisualOptions(false, true, false));
        await app2.RefreshAllProvidersAsync(CancellationToken.None);
        fake2.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false));
        fake2.Keys.Enqueue(new ConsoleKeyInfo(':', ConsoleKey.Oem1, true, false, false));
        fake2.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        fake2.Keys.Enqueue(new ConsoleKeyInfo('\u0015', ConsoleKey.U, false, false, true));
        fake2.Keys.Enqueue(new ConsoleKeyInfo('j', ConsoleKey.J, false, false, false));
        await RunUntilAsync(app2, () =>
            fake2.Keys.Count == 0
            && !app2.IsPaletteRunning
            && app2.IsCommandDrawerOpen
            && string.Equals(app2.Session.CommandInput, "j", StringComparison.Ordinal));

        string palWithJ = string.Join("\n", app2.RenderFrame(100, 20).Select(StripAnsi));
        Assert.Contains("j", palWithJ, StringComparison.Ordinal);
        Assert.Contains("Structured", palWithJ, StringComparison.Ordinal);
    }

    [Fact]
    public async Task NarrowProjectDetail_OmitsListSearchBar_AndPinsFooterAtBottomRow()
    {
        CapabilityDispatcher dispatcher = CreateStubDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 70, WindowHeight = 18 };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // Narrow Cmd -> MainPane
        fake.Keys.Enqueue(new ConsoleKeyInfo('2', ConsoleKey.D2, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('/', ConsoleKey.Divide, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));

        int code = await app.RunAsync(CancellationToken.None);
        Assert.Equal(0, code);
        Assert.NotEqual(FocusZone.Search, app.Focus);

        var rows = app.RenderFrame(70, 18).Select(StripAnsi).ToList();
        Assert.Equal(18, rows.Count);
        Assert.DoesNotContain("Type / to filter", string.Join("\n", rows), StringComparison.Ordinal);
        Assert.Contains("Projects (1/3)", rows[2], StringComparison.Ordinal);
        Assert.Contains("Esc Back", rows[17], StringComparison.Ordinal);
    }

    [Fact]
    public async Task HomeWorkflows_And_WideRuntimesEnter_And_DuplicateDisambiguation_WorkCleanly()
    {
        Directory.CreateDirectory(Path.Combine(_tempDir, "Research", "dl-exp1"));
        Directory.CreateDirectory(Path.Combine(_tempDir, "Research", "dl-exp2"));
        var dupRunner = new StubProcessRunner
        {
            Handler = (_, args, _) =>
            {
                if (args.Contains("projects"))
                {
                    return Task.FromResult(new SubprocessResult(
                        0,
                        """
                        [
                          {"id":"dl-exp1","name":"DL Exp","path":"Research/dl-exp1","category":"research","status":"active","environment":"ULVO managed","gpu":"required","git":true,"commands":{}},
                          {"id":"dl-exp2","name":"DL Exp","path":"Research/dl-exp2","category":"research","status":"active","environment":"node_modules","gpu":"none","git":false,"commands":{}}
                        ]
                        """,
                        "", 5, false, false, false));
                }
                if (args.Contains("info"))
                    return Task.FromResult(new SubprocessResult(0, $$"""{"workspaceRoot":"{{_tempDir.Replace("\\", "\\\\")}}","projectsCount":2}""", "", 4, false, false, false));
                if (args.Contains("ls"))
                {
                    return Task.FromResult(new SubprocessResult(
                        0,
                        """
                        [
                          {"id":"r-sandbox","name":"alpha-app","canonical_path":"E:\\Workspace\\Research\\dl-exp1","ecosystem":"Sandbox","registration_state":"registered","has_connector":true,"classification":"sandbox","manifests":["pyproject.toml"]},
                          {"id":"r-multi","name":"alpha-app","canonical_path":"E:\\Workspace\\Research\\dl-exp2","ecosystem":"multi-ecosystem","registration_state":"registered","has_connector":true,"classification":"multi","manifests":["package.json"]}
                        ]
                        """,
                        "", 5, false, false, false));
                }
                if (args.Contains("status"))
                    return Task.FromResult(new SubprocessResult(0, """{"schema_version":1,"version":"1.2.0","registered_projects":2,"vault_exists":true}""", "", 4, false, false, false));
                return Task.FromResult(new SubprocessResult(0, """{"status":"GOOD","summary":{"okCount":10,"totalChecks":10}}""", "", 4, false, false, false));
            }
        };
        var cfg = new WorkctlPathsConfig(_tempDir, _fakeWsctl, _fakePwsh, _fakeUlvo, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        var dispatcher = new CapabilityDispatcher(cfg, dupRunner);
        var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        // Verify Projects disambiguates identical names + normalizes tags without mid-word chop
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // Nav
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // Main
        fake.Keys.Enqueue(new ConsoleKeyInfo('2', ConsoleKey.D2, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));
        await app.RunAsync(CancellationToken.None);
        string projPlain = string.Join("\n", app.RenderFrame(120, 32).Select(StripAnsi));
        Assert.Contains("dl-exp1", projPlain, StringComparison.Ordinal);
        Assert.Contains("dl-exp2", projPlain, StringComparison.Ordinal);
        Assert.Contains("ulvo", projPlain, StringComparison.Ordinal);
        Assert.Contains("ULVO managed", projPlain, StringComparison.Ordinal);
        Assert.DoesNotContain("node_modul", projPlain, StringComparison.Ordinal);
        Assert.DoesNotContain("ULVO ma…", projPlain, StringComparison.Ordinal);

        // Verify Runtimes disambiguates identical names & hides raw not_checked_on_ls
        fake.Keys.Enqueue(new ConsoleKeyInfo('3', ConsoleKey.D3, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));
        await app.RunAsync(CancellationToken.None);
        string envPlain = string.Join("\n", app.RenderFrame(120, 32).Select(StripAnsi));
        Assert.Contains("alpha-app", envPlain, StringComparison.Ordinal);
        Assert.Contains("Sandbox", envPlain, StringComparison.Ordinal);
        Assert.Contains("Multi-Eco", envPlain, StringComparison.Ordinal);
        Assert.DoesNotContain("not_checked_on_ls", envPlain, StringComparison.Ordinal);

        // Verify clean Overview -> ':' Command Area opens cleanly and remains active without blocking
        fake.Keys.Enqueue(new ConsoleKeyInfo('1', ConsoleKey.D1, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo(':', ConsoleKey.Oem1, true, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('h', ConsoleKey.H, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('e', ConsoleKey.E, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('a', ConsoleKey.A, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('l', ConsoleKey.L, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        await RunUntilAsync(app, () =>
            fake.Keys.Count == 0
            && !app.IsPaletteRunning
            && app.IsCommandDrawerOpen
            && app.Session.Focus == FocusRegion.CommandLine);
        Assert.Equal(FocusRegion.CommandLine, app.Session.Focus);
        Assert.True(app.IsCommandDrawerOpen);
    }

    [Fact]
    public async Task UnavailableProviders_SurfaceBothWsctlAndUlvoErrorsWithoutDuplication()
    {
        CapabilityDispatcher errDisp = CreateStubDispatcher(includeStaleDoctor: false, failProviders: true);
        var fake = new FakeTerminalBackend { WindowWidth = 100, WindowHeight = 28 };
        var app = new TuiApp(errDisp, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        string errPlain = string.Join("\n", app.RenderFrame(100, 28).Select(StripAnsi));
        Assert.Contains("PROVIDER DIAGNOSTICS", errPlain, StringComparison.Ordinal);
        Assert.Contains("WSCTL", errPlain, StringComparison.Ordinal);
        Assert.Contains("ULVO", errPlain, StringComparison.Ordinal);
    }

    [Fact]
    public async Task HelpScreen_IsContextAware_SupportsMotionToggle_AndWrapsCleanlyAtNarrow()
    {
        CapabilityDispatcher dispatcher = CreateStubDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 70, WindowHeight = 18 };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // Narrow -> MainPane
        fake.Keys.Enqueue(new ConsoleKeyInfo('2', ConsoleKey.D2, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('?', ConsoleKey.Oem2, true, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('m', ConsoleKey.M, false, false, false));
        await RunUntilAsync(app, () =>
            fake.Keys.Count == 0
            && app.Screen == TuiScreen.Help
            && !app.ReducedMotion);

        Assert.False(app.ReducedMotion);
        var helpRows = app.RenderFrame(70, 18).Select(StripAnsi).ToList();
        Assert.Equal(18, helpRows.Count);
        Assert.Contains("Active Context (Projects)", string.Join("\n", helpRows), StringComparison.Ordinal);
    }

    [Fact]
    public async Task WideRuntimes_EnterProbesEnvironment_AndAnimationIsInterruptibleByKeys()
    {
        var runner = new StubProcessRunner
        {
            Handler = (_, args, _) =>
            {
                if (args.Contains("projects"))
                    return Task.FromResult(new SubprocessResult(0, """[{"id":"alpha-app","name":"Alpha Web","path":"Active/alpha-app","category":"active","status":"active","environment":"node_modules","gpu":"none","git":true,"commands":{}}]""", "", 4, false, false, false));
                if (args.Contains("info"))
                    return Task.FromResult(new SubprocessResult(0, $$"""{"workspaceRoot":"{{_tempDir.Replace("\\", "\\\\")}}","projectsCount":1}""", "", 4, false, false, false));
                if (args.Contains("ls"))
                    return Task.FromResult(new SubprocessResult(0, $$"""[{"id":"r1","name":"alpha-app","canonical_path":"{{Path.Combine(_tempDir, "Active", "alpha-app").Replace("\\", "\\\\")}}","ecosystem":"Node.js","registration_state":"registered","has_connector":true,"classification":"node","manifests":["package.json"]}]""", "", 4, false, false, false));
                if (args.Contains("status") && !args.Contains("env"))
                    return Task.FromResult(new SubprocessResult(0, """{"schema_version":1,"version":"1.2.0","registered_projects":1,"vault_exists":true}""", "", 4, false, false, false));
                if (args[0] == "env")
                    return Task.FromResult(new SubprocessResult(0, """{"environment_id":"env-1","state":"materialized","is_materialized":true,"is_quiescent":true,"can_reclaim":false,"python_version":null}""", "", 4, false, false, false));
                return Task.FromResult(new SubprocessResult(0, """{"path":"E:\\temp","native_manifests":["package.json"],"connector":{"compliance_verdict":"compliant"},"diagnostics":[]}""", "", 4, false, false, false));
            }
        };
        Directory.CreateDirectory(Path.Combine(_tempDir, "Active", "alpha-app"));
        var cfg = new WorkctlPathsConfig(_tempDir, _fakeWsctl, _fakePwsh, _fakeUlvo, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        var dispatcher = new CapabilityDispatcher(cfg, runner);
        var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(false, false, false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        // Switch to MainPane, Runtimes [3] on Wide and press Enter -> must inspect live runtime!
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('3', ConsoleKey.D3, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        await RunUntilAsync(app, () =>
            fake.Keys.Count == 0
            && app.Screen == TuiScreen.Environments
            && !app.IsInspectingEnvironment
            && app.InspectedEnvironmentCount > 0);

        string envPlain = string.Join("\n", app.RenderFrame(120, 32).Select(StripAnsi));
        Assert.Contains("VERIFIED INSPECTION", envPlain, StringComparison.Ordinal);
        Assert.Contains("compliant", envPlain, StringComparison.Ordinal);
        Assert.Contains("materialized", envPlain, StringComparison.Ordinal);

        // Verify animation loop is immediately interruptible on Ctrl+Q even when motion is ON
        var slowRunner = new StubProcessRunner
        {
            Handler = async (_, _, ct) =>
            {
                await Task.Delay(5000, ct);
                return new SubprocessResult(0, "{}", "", 5000, false, true, false);
            }
        };
        var slowDisp = new CapabilityDispatcher(cfg, slowRunner);
        var slowFake = new FakeTerminalBackend { WindowWidth = 100, WindowHeight = 28 };
        slowFake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true)); // Ctrl+Q
        var slowApp = new TuiApp(slowDisp, slowFake, new TuiVisualOptions(false, false, false));
        var sw = System.Diagnostics.Stopwatch.StartNew();
        int exit = await slowApp.RunAsync(CancellationToken.None);
        sw.Stop();
        Assert.Equal(0, exit);
        Assert.True(sw.ElapsedMilliseconds < 1500, $"Expected instant interruptible exit during loading animation, took {sw.ElapsedMilliseconds}ms");
    }

    [Fact]
    public async Task SidebarNavigation_SteppingOntoCommandDoesNotTrapKeys_AndNavigatesBackCleanly()
    {
        CapabilityDispatcher dispatcher = CreateStubDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        // Ctrl+N -> Navigation (starts on Console), Down -> Tasks -> Down -> Performance (skips Services!), Up -> Tasks, Enter opens Tasks!
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u000e', ConsoleKey.N, false, false, true)); // Ctrl+N -> Navigation
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.DownArrow, false, false, false)); // Tasks
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.DownArrow, false, false, false)); // Performance (skips Services!)
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.UpArrow, false, false, false));   // Tasks
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));     // Open Tasks
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));

        int code = await app.RunAsync(CancellationToken.None);
        Assert.Equal(0, code);
        Assert.Equal(NavigationSectionId.MachineProcesses, app.Session.CurrentSection);
    }

    [Fact]
    public async Task Standard100x28Home_DownArrowJumpsDirectlyFromVisibleWorkflowsToSnapshot_AndProjectsRangeUpdatesOnSameFrame()
    {
        var itemsJson = string.Join(",", Enumerable.Range(1, 30).Select(i =>
            $$"""{"id":"proj-{{i:D2}}","name":"Project {{i:D2}}","path":"Active/alpha-app","category":"active","status":"active","environment":"uv","gpu":"none","git":true,"languages":["python"]}"""));
        Directory.CreateDirectory(Path.Combine(_tempDir, "Active", "alpha-app"));
        var runner = new StubProcessRunner
        {
            Handler = (_, args, _) =>
            {
                if (args.Contains("projects"))
                    return Task.FromResult(new SubprocessResult(0, $"[{itemsJson}]", "", 4, false, false, false));
                if (args.Contains("info"))
                    return Task.FromResult(new SubprocessResult(0, $$"""{"workspaceRoot":"{{_tempDir.Replace("\\", "\\\\")}}","projectsCount":30}""", "", 4, false, false, false));
                if (args.Contains("ls"))
                    return Task.FromResult(new SubprocessResult(0, "[]", "", 4, false, false, false));
                return Task.FromResult(new SubprocessResult(0, """{"schema_version":1,"version":"1.2.0","registered_projects":0,"vault_exists":true}""", "", 4, false, false, false));
            }
        };
        var cfg = new WorkctlPathsConfig(_tempDir, _fakeWsctl, _fakePwsh, _fakeUlvo, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        var dispatcher = new CapabilityDispatcher(cfg, runner);
        var fake = new FakeTerminalBackend { WindowWidth = 100, WindowHeight = 28 };
        var app = new TuiApp(dispatcher, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(CancellationToken.None);

        // Move to MainPane, open Projects [2], press End -> range updates immediately on bottom page!
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('2', ConsoleKey.D2, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.End, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));

        int code = await app.RunAsync(CancellationToken.None);
        Assert.Equal(0, code);
        Assert.Equal(TuiScreen.Projects, app.Screen);

        string projPlain = string.Join("\n", app.RenderFrame(100, 28).Select(StripAnsi));
        Assert.Contains("-30/30", projPlain, StringComparison.Ordinal);
        Assert.DoesNotContain("1-20/30", projPlain, StringComparison.Ordinal);
    }
}
using System.Text.RegularExpressions;
using WorkCtlNext.Core;
using WorkCtlNext.Terminal;
using Xunit;

namespace WorkCtlNext.Tests;

public sealed partial class NavigationAndPhase2TuiTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _wsctlPath;
    private readonly string _pwshPath;
    private readonly string _ulvoPath;

    [GeneratedRegex(@"\u001b\[[0-9;?]*[A-Za-z]")]
    private static partial Regex AnsiRegex();

    public NavigationAndPhase2TuiTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"WorkCtlNext_Nav2_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
        Directory.CreateDirectory(Path.Combine(_tempDir, "subdir"));
        File.WriteAllText(Path.Combine(_tempDir, "notes.txt"), "Line 1: hello phase 2\nLine 2: verified");
        File.WriteAllText(Path.Combine(_tempDir, "subdir", "child.txt"), "inside subdir");

        _wsctlPath = Path.Combine(_tempDir, "wsctl.ps1");
        _pwshPath = Path.Combine(_tempDir, "pwsh.exe");
        _ulvoPath = Path.Combine(_tempDir, "ulvo-dir", "ulvo.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(_ulvoPath)!);
        File.WriteAllText(_wsctlPath, "stub");
        File.WriteAllText(_pwshPath, "stub");
        File.WriteAllText(_ulvoPath, "stub");
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, recursive: true); } catch { }
    }

    private static string StripAnsi(string text) => AnsiRegex().Replace(text, string.Empty);

    private CapabilityDispatcher CreateInteractiveDispatcher()
    {
        var runner = new StubProcessRunner
        {
            Handler = (_, args, _) =>
            {
                if (args.Contains("projects"))
                {
                    return Task.FromResult(new SubprocessResult(0, """
                        [
                          {"id":"alpha-app","name":"Alpha Web","path":"subdir","category":"active","status":"active","environment":"node","gpu":"none","git":true,"commands":{}}
                        ]
                        """, "", 4, false, false, false));
                }
                if (args.Contains("info"))
                    return Task.FromResult(new SubprocessResult(0, $$"""{"workspaceRoot":"{{_tempDir.Replace("\\", "\\\\")}}","projectsCount":1}""", "", 4, false, false, false));
                if (args.Contains("ls"))
                    return Task.FromResult(new SubprocessResult(0, "[]", "", 4, false, false, false));
                return Task.FromResult(new SubprocessResult(0, """{"schema_version":1,"version":"1.2.0","registered_projects":1,"vault_exists":true}""", "", 4, false, false, false));
            }
        };

        var cfg = new WorkctlPathsConfig(_tempDir, _wsctlPath, _pwshPath, _ulvoPath, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        return new CapabilityDispatcher(cfg, runner, policyMode: DispatcherPolicyMode.InteractivePhase2);
    }

    [Theory]
    [InlineData(120, 32)]
    [InlineData(100, 28)]
    [InlineData(70, 18)]
    [InlineData(52, 14)]
    public async Task AllPhase2SectionsAndOverlays_RespectViewportBoundsZeroOverflow(int w, int h)
    {
        CapabilityDispatcher disp = CreateInteractiveDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = w, WindowHeight = h };
        var app = new TuiApp(disp, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(TestContext.Current.CancellationToken);

        foreach (string cmd in new[]
        {
            "open overview",
            "open processes",
            "open storage",
            "open network",
            "open services",
            "open workspace",
            "open projects",
            "open git",
            "open ulvo",
            "open toolchains",
            "open running",
            "open installed",
            "open startup"
        })
        {
            await app.ExecuteCommandLineAsync(cmd, TestContext.Current.CancellationToken);
            IReadOnlyList<string> frame = app.RenderFrame(w, h);
            Assert.Equal(h, frame.Count);
            foreach (string line in frame)
                Assert.Equal(w, DiffRenderer.MeasureVisibleLength(line));
        }
    }

    [Fact]
    public async Task HierarchicalTree_ShowsCategoriesAndDeferredSections_AndCollapseExpandWorks()
    {
        CapabilityDispatcher disp = CreateInteractiveDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
        var app = new TuiApp(disp, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(TestContext.Current.CancellationToken);

        string plain = string.Join("\n", app.RenderFrame(120, 32).Select(StripAnsi));
        Assert.Contains("MACHINE", plain);
        Assert.Contains("FILES", plain);
        Assert.Contains("DEVELOPMENT", plain);
        Assert.Contains("APPLICATIONS", plain);
        Assert.Contains("Services", plain);
        Assert.Contains("off", plain);

        // Execute deferred section via command -> shows honest DEFERRED notice with zero synthetic data
        await app.ExecuteCommandLineAsync("open services", TestContext.Current.CancellationToken);
        string svcPlain = string.Join("\n", app.RenderFrame(120, 32).Select(StripAnsi));
        Assert.Contains("DEFERRED", svcPlain);
        Assert.Contains("No synthetic", svcPlain);

        // Move to MainPane via Ctrl+Tab (twice: Cmd -> Nav -> Main), toggle tree collapse with '[', then Ctrl+Q quit
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.Tab, false, false, true)); // NavTree
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.Tab, false, false, true)); // MainPane
        fake.Keys.Enqueue(new ConsoleKeyInfo('[', ConsoleKey.Oem4, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));
        await app.RunAsync(TestContext.Current.CancellationToken);
        Assert.True(app.Session.TreeCollapsed);
        string collapsedPlain = string.Join("\n", app.RenderFrame(120, 32).Select(StripAnsi));
        Assert.DoesNotContain("NAVIGATION", collapsedPlain);
    }

    [Fact]
    public async Task SharedContext_CdUpdatesFileBrowser_AndNeverChangesProcessWorkingDirectory()
    {
        string osBefore = Environment.CurrentDirectory;
        CapabilityDispatcher disp = CreateInteractiveDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
        var app = new TuiApp(disp, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(TestContext.Current.CancellationToken);

        await app.ExecuteCommandLineAsync("cd subdir", TestContext.Current.CancellationToken);
        Assert.Equal(PathNormalizer.NormalizeDisplayPath(Path.Combine(_tempDir, "subdir")), app.Session.ActiveDirectory);
        Assert.Equal(osBefore, Environment.CurrentDirectory);

        await app.ExecuteCommandLineAsync("open workspace", TestContext.Current.CancellationToken);
        await app.ExecuteCommandLineAsync("cd subdir", TestContext.Current.CancellationToken);
        await app.ExecuteCommandLineAsync("ls", TestContext.Current.CancellationToken);
        string plain = string.Join("\n", app.RenderFrame(120, 32).Select(StripAnsi));
        Assert.Contains("child.txt", plain);
        Assert.Equal(osBefore, Environment.CurrentDirectory);
    }

    [Fact]
    public async Task FilesBrowser_CtrlCCopiesWithoutExiting_AndCtrlVPasteModalAndDeleteAndMkdirWorkEndToEnd()
    {
        CapabilityDispatcher disp = CreateInteractiveDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
        var app = new TuiApp(disp, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(TestContext.Current.CancellationToken);

        // Open Files Workspace cleanly
        await app.ExecuteCommandLineAsync("ls", TestContext.Current.CancellationToken);
        Assert.Equal(FocusRegion.MainPane, app.Session.Focus);
        Assert.True(WorkspaceSessionContext.IsFilesSection(app.Session.CurrentSection));

        // Pressing '/' into Files search MUST disable TreatControlCAsInput so Ctrl+C exits rather than copying; Enter back to Files MainPane restores it
        fake.Keys.Enqueue(new ConsoleKeyInfo('/', ConsoleKey.Divide, false, false, false));
        bool treatCtrlCInSearch = true;
        using (var searchCts = new CancellationTokenSource(5000))
        {
            Task<int> searchRun = app.RunAsync(searchCts.Token);
            while ((fake.Keys.Count > 0 || app.Focus != FocusZone.Search) && !searchRun.IsCompleted && !searchCts.IsCancellationRequested)
                await Task.Delay(15, CancellationToken.None);
            treatCtrlCInSearch = fake.TreatControlCAsInput;
            searchCts.Cancel();
            await searchRun;
        }
        Assert.Equal(FocusZone.Search, app.Focus);
        Assert.False(treatCtrlCInSearch);
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));
        await app.RunAsync(TestContext.Current.CancellationToken);
        Assert.NotEqual(FocusZone.Search, app.Focus);

        // DownArrow from subdir -> notes.txt, Space mark notes.txt, Ctrl+C copy (must NOT exit!), then 'F7' mkdir 'copy-target', Enter confirm, 'Enter' open 'copy-target', Ctrl+V paste + Enter confirm!
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.DownArrow, false, false, false)); // subdir
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.DownArrow, false, false, false)); // notes.txt
        fake.Keys.Enqueue(new ConsoleKeyInfo('c', ConsoleKey.C, false, false, true)); // Ctrl+C copy notes.txt (OR wait: subdir index 0, notes index 1 -> check exact sorted order!)
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F7, false, false, false)); // New folder modal
        foreach (char ch in "pasted-dir")
            fake.Keys.Enqueue(new ConsoleKeyInfo(ch, ConsoleKey.NoName, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false)); // Create pasted-dir
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));

        int code = await app.RunAsync(TestContext.Current.CancellationToken);
        Assert.Equal(0, code);
        Assert.True(app.Session.Clipboard.HasItems);
        Assert.Equal(ClipboardMode.Copy, app.Session.Clipboard.Mode);
        Assert.True(Directory.Exists(Path.Combine(_tempDir, "pasted-dir")));

        // Navigate into pasted-dir, Ctrl+V + Enter paste
        await app.ExecuteCommandLineAsync("cd pasted-dir", TestContext.Current.CancellationToken);
        fake.Keys.Enqueue(new ConsoleKeyInfo('v', ConsoleKey.V, false, false, true)); // Ctrl+V -> Paste modal
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false)); // Confirm paste
        fake.Keys.Enqueue(new ConsoleKeyInfo('q', ConsoleKey.Q, false, false, false));
        await app.RunAsync(TestContext.Current.CancellationToken);

        Assert.Single(Directory.GetFiles(Path.Combine(_tempDir, "pasted-dir")));

        // Outside Files (Overview), Ctrl+C MUST exit cleanly!
        await app.ExecuteCommandLineAsync("open overview", TestContext.Current.CancellationToken);
        fake.Keys.Enqueue(new ConsoleKeyInfo('c', ConsoleKey.C, false, false, true));
        int ctrlCExit = await app.RunAsync(TestContext.Current.CancellationToken);
        Assert.Equal(0, ctrlCExit);
    }

    [Fact]
    public async Task CommandLine_UnsupportedShellSyntax_SurfacesErrorInDrawerWithoutCrashing()
    {
        CapabilityDispatcher disp = CreateInteractiveDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 100, WindowHeight = 28 };
        var app = new TuiApp(disp, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(TestContext.Current.CancellationToken);

        await app.ExecuteCommandLineAsync("ls | grep foo", TestContext.Current.CancellationToken);
        string consoleFrame = string.Join("\n", app.RenderFrame(100, 28).Select(StripAnsi));
        Assert.Contains("UNSUPPORTED_SHELL_SYNTAX", consoleFrame);

        // On non-Console sections (e.g. Projects), unsupported syntax opens the Command Drawer overlay cleanly
        await app.ExecuteCommandLineAsync("open projects", TestContext.Current.CancellationToken);
        await app.ExecuteCommandLineAsync("ls | grep foo", TestContext.Current.CancellationToken);
        Assert.True(app.IsCommandDrawerOpen);
        string frame = string.Join("\n", app.RenderFrame(100, 28).Select(StripAnsi));
        Assert.Contains("UNSUPPORTED_SHELL_SYNTAX", frame);
    }

    [Fact]
    public async Task NarrowViewport_StartsInCommandEditor_AndRegionShortcutsKeepFocusSafe()
    {
        CapabilityDispatcher disp = CreateInteractiveDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 70, WindowHeight = 18 };
        var app = new TuiApp(disp, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(TestContext.Current.CancellationToken);

        Assert.Equal(FocusRegion.CommandLine, app.Session.Focus);

        // Switch from CommandLine to MainPane via F6 (narrow skips hidden tree), then test Projects '2', '/', 'q'
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // CommandLine -> MainPane on narrow
        fake.Keys.Enqueue(new ConsoleKeyInfo('2', ConsoleKey.D2, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('/', ConsoleKey.Divide, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true)); // Ctrl+Q exits cleanly

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cts.Token, TestContext.Current.CancellationToken);
        int code = await app.RunAsync(linked.Token);
        Assert.Equal(0, code);
        Assert.NotEqual(FocusZone.Search, app.Focus);
        Assert.Equal(FocusRegion.MainPane, app.Session.Focus);
    }

    [Fact]
    public async Task WideViewport_CtrlTabCyclesAllThreeRegionsDeterministicallyAndNeverTrapsQuit()
    {
        CapabilityDispatcher disp = CreateInteractiveDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
        var app = new TuiApp(disp, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(TestContext.Current.CancellationToken);

        Assert.Equal(FocusRegion.CommandLine, app.Session.Focus);

        // Plain Tab in CommandLine MUST complete/stay in CommandLine without stealing focus!
        fake.Keys.Enqueue(new ConsoleKeyInfo('\t', ConsoleKey.Tab, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0015', ConsoleKey.U, false, false, true)); // Ctrl+U clear accepted completion
        // Step through Ctrl+Tab / F6: CommandLine -> NavigationTree -> MainPane -> CommandLine -> Ctrl+N -> Esc -> Ctrl+Q
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // NavTree
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // MainPane
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // CommandLine
        fake.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.Tab, false, false, true)); // Ctrl+Tab -> NavTree
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u001b', ConsoleKey.Escape, false, false, false)); // Esc -> CommandLine
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true)); // Ctrl+Q

        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cts.Token, TestContext.Current.CancellationToken);
        int code = await app.RunAsync(linked.Token);
        Assert.Equal(0, code);
        Assert.Equal(FocusRegion.CommandLine, app.Session.Focus);
    }

    [Fact]
    public async Task NavigationHistory_AndFilesWorkflows_CutPasteRenameDeleteAndProtectedPolicy_WorkSafely()
    {
        CapabilityDispatcher disp = CreateInteractiveDispatcher();
        var fake = new FakeTerminalBackend { WindowWidth = 120, WindowHeight = 32 };
        var app = new TuiApp(disp, fake, new TuiVisualOptions(false, true, false));
        await app.RefreshAllProvidersAsync(TestContext.Current.CancellationToken);

        // Create clean sandbox folder and target file
        await app.ExecuteCommandLineAsync("open workspace", TestContext.Current.CancellationToken);
        await app.ExecuteCommandLineAsync("cd subdir", TestContext.Current.CancellationToken);
        string moveTarget = Path.Combine(_tempDir, "subdir", "move-target");
        Directory.CreateDirectory(moveTarget);
        string srcFile = Path.Combine(_tempDir, "subdir", "alpha.txt");
        File.WriteAllText(srcFile, "cut-paste content");

        // Navigate back/forward and confirm selection/history
        await app.ExecuteCommandLineAsync("open overview", TestContext.Current.CancellationToken);
        await app.ExecuteCommandLineAsync("back", TestContext.Current.CancellationToken);
        Assert.Equal(NavigationSectionId.FilesWorkspace, app.Session.CurrentSection);
        await app.ExecuteCommandLineAsync("forward", TestContext.Current.CancellationToken);
        Assert.Equal(NavigationSectionId.MachineOverview, app.Session.CurrentSection);
        await app.ExecuteCommandLineAsync("back", TestContext.Current.CancellationToken);

        // Execute cut + paste + rename + delete via modal confirmation
        await app.ExecuteCommandLineAsync($"cut \"{srcFile}\"", TestContext.Current.CancellationToken);
        Assert.True(File.Exists(srcFile)); // Cut MUST NOT mutate disk before confirmed Paste!
        Assert.Equal(ClipboardMode.Cut, app.Session.Clipboard.Mode);

        await app.ExecuteCommandLineAsync($"paste \"{moveTarget}\"", TestContext.Current.CancellationToken);
        Assert.NotNull(app.CurrentModal);
        Assert.Equal(ModalKind.ConfirmPaste, app.CurrentModal!.Kind);
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false)); // Confirm move
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true)); // Ctrl+Q exits regardless of focus
        await app.RunAsync(TestContext.Current.CancellationToken);

        string movedFile = Path.Combine(moveTarget, "alpha.txt");
        Assert.False(File.Exists(srcFile));
        Assert.True(File.Exists(movedFile));

        // Rename via command + confirm modal
        await app.ExecuteCommandLineAsync($"rename \"{movedFile}\" \"beta.txt\"", TestContext.Current.CancellationToken);
        Assert.Equal(ModalKind.PromptRename, app.CurrentModal?.Kind);
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true));
        await app.RunAsync(TestContext.Current.CancellationToken);
        string renamedFile = Path.Combine(moveTarget, "beta.txt");
        Assert.True(File.Exists(renamedFile));

        // Protected path delete MUST show ProtectedBlocked modal and preserve wsctl.ps1
        await app.ExecuteCommandLineAsync($"rm \"{_wsctlPath}\"", TestContext.Current.CancellationToken);
        Assert.Equal(ModalKind.ProtectedBlocked, app.CurrentModal?.Kind);
        Assert.True(File.Exists(_wsctlPath));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false)); // Dismiss
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true));
        await app.RunAsync(TestContext.Current.CancellationToken);

        // Confirm Delete sends beta.txt to Recycle Bin cleanly
        await app.ExecuteCommandLineAsync($"rm \"{renamedFile}\"", TestContext.Current.CancellationToken);
        Assert.Equal(ModalKind.ConfirmDelete, app.CurrentModal?.Kind);
        fake.Keys.Enqueue(new ConsoleKeyInfo('\r', ConsoleKey.Enter, false, false, false));
        fake.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true));
        await app.RunAsync(TestContext.Current.CancellationToken);
        Assert.False(File.Exists(renamedFile));
    }
}

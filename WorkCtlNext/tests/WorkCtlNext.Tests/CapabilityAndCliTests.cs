using System.Text.Json;
using WorkCtlNext.Cli;
using WorkCtlNext.Core;
using WorkCtlNext.Terminal;
using Xunit;

namespace WorkCtlNext.Tests;

public sealed class CapabilityAndCliTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _fakePwsh;
    private readonly string _fakeWsctl;
    private readonly string _fakeUlvo;

    public CapabilityAndCliTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"WorkCtlNext CLI Space {Guid.NewGuid():N}");
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

    [Fact]
    public async Task AgentCli_ProducesValidNoAnsiJson_AndDiagnosticsOnStderr()
    {
        string projDir = Path.Combine(_tempDir, "Active", "dl-exp1");
        Directory.CreateDirectory(projDir);

        var runner = new StubProcessRunner
        {
            Handler = (_, args, _) =>
            {
                if (args.Contains("projects"))
                {
                    return Task.FromResult(new SubprocessResult(
                        0,
                        """[{"id":"dl-exp1","name":"DL Exp 1","path":"Active/dl-exp1","category":"academic","status":"active","environment":"ulvo","gpu":"optional","git":false,"commands":{"verify":{"risk":"safe"}}}]""",
                        "",
                        10, false, false, false));
                }
                if (args[0] == "inspect")
                {
                    return Task.FromResult(new SubprocessResult(
                        0,
                        """{"path":"\\\\?\\E:\\temp","native_manifests":["requirements.txt"],"ulvo_manifest":{"name":"dl-exp1","runtimes":{"python":"3.11"},"python":{"manager":"uv"},"environment":{"mode":"ephemeral"}},"connector":{"compliance_verdict":"compliant"},"diagnostics":[]}""",
                        "",
                        12, false, false, false));
                }
                return Task.FromResult(new SubprocessResult(0, """{"schema_version":1,"version":"1.2.0","registered_projects":1,"vault_exists":true}""", "", 8, false, false, false));
            }
        };

        var cfg = new WorkctlPathsConfig(_tempDir, _fakeWsctl, _fakePwsh, _fakeUlvo, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        var dispatcher = new CapabilityDispatcher(cfg, runner);
        var stdout = new StringWriter();
        var stderr = new StringWriter();
        var cli = new AgentCli(dispatcher, stdout, stderr);

        int exitOk = await cli.ExecuteAsync(["context", "--project", "dl-exp1", "--json"], CancellationToken.None);
        string outStr = stdout.ToString();
        Assert.Equal(0, exitOk);
        Assert.Equal(string.Empty, stderr.ToString());
        Assert.DoesNotContain("\u001b", outStr, StringComparison.Ordinal);

        using JsonDocument doc = JsonDocument.Parse(outStr);
        Assert.True(doc.RootElement.GetProperty("ok").GetBoolean());
        Assert.Equal("workctl.context", doc.RootElement.GetProperty("capability").GetString());
        Assert.True(doc.RootElement.GetProperty("data").GetProperty("project").GetProperty("accessible").GetBoolean());

        // Verify missing project fails with ExitCode 3 and writes JSON to stdout + diagnostic to stderr
        var stdoutMissing = new StringWriter();
        var stderrMissing = new StringWriter();
        var cliMissing = new AgentCli(dispatcher, stdoutMissing, stderrMissing);
        int exitMissing = await cliMissing.ExecuteAsync(["context", "--project", "does-not-exist", "--json"], CancellationToken.None);
        Assert.Equal(3, exitMissing);
        Assert.False(string.IsNullOrWhiteSpace(stderrMissing.ToString()));
        using JsonDocument errDoc = JsonDocument.Parse(stdoutMissing.ToString());
        Assert.False(errDoc.RootElement.GetProperty("ok").GetBoolean());
        Assert.Equal("PROJECT_NOT_FOUND", errDoc.RootElement.GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public async Task SharedDispatcher_EnforcesReadOnlyRiskGateAcrossCliAndTui()
    {
        var runner = new StubProcessRunner();
        var cfg = new WorkctlPathsConfig(_tempDir, _fakeWsctl, _fakePwsh, _fakeUlvo, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        var dispatcher = new CapabilityDispatcher(cfg, runner);

        // Register a hypothetical higher-risk capability into the shared registry to verify enforcement gate.
        dispatcher.Registry.Register(new RegisteredCapability(
            "test.modifying",
            "Mutating Action",
            "Should be blocked by Phase 1 policy gate",
            "core",
            RiskClassification.Modifying,
            [],
            ["json"],
            "mut --json",
            (_, _) => Task.FromResult<object?>("SHOULD_NOT_RUN")));

        DispatchOutcome outcome = await dispatcher.DispatchAsync(new CapabilityInvocationRequest("test.modifying"), CancellationToken.None);
        Assert.Equal(2, outcome.ExitCode);
        Assert.False(outcome.Envelope.Ok);
        Assert.Equal("POLICY_BLOCKED", outcome.Envelope.Error?.Code);

        // Ensure all production Phase 1 built-in capabilities are strictly ReadOnly.
        Assert.All(dispatcher.Registry.All.Where(c => c.Id != "test.modifying"), c => Assert.Equal(RiskClassification.ReadOnly, c.Risk));
    }

    [Fact]
    public async Task TuiApp_NavigatesScreens_Palette_Help_AndRestoresCleanlyOnQuit()
    {
        var runner = new StubProcessRunner
        {
            Handler = (_, args, _) =>
            {
                if (args.Contains("projects"))
                    return Task.FromResult(new SubprocessResult(0, """[{"id":"p1","name":"Proj1","path":"Active","category":"active","status":"active","environment":"uv","gpu":"none","git":false,"commands":{}}]""", "", 5, false, false, false));
                if (args.Contains("ls"))
                    return Task.FromResult(new SubprocessResult(0, "[]", "", 5, false, false, false));
                return Task.FromResult(new SubprocessResult(0, """{"schema_version":1,"version":"1.2.0","registered_projects":0,"vault_exists":true}""", "", 5, false, false, false));
            }
        };

        var cfg = new WorkctlPathsConfig(_tempDir, _fakeWsctl, _fakePwsh, _fakeUlvo, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
        var dispatcher = new CapabilityDispatcher(cfg, runner);
        var fakeTty = new FakeTerminalBackend { WindowWidth = 100, WindowHeight = 25 };

        // Queue: switch to MainPane via F6, Projects [2], CommandLine [Ctrl+L], Help [? via F6], back [Esc], Quit [Ctrl+Q]
        fakeTty.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // NavTree
        fakeTty.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false)); // MainPane
        fakeTty.Keys.Enqueue(new ConsoleKeyInfo('2', ConsoleKey.D2, false, false, false));
        fakeTty.Keys.Enqueue(new ConsoleKeyInfo('\u000c', ConsoleKey.L, false, false, true)); // Ctrl+L
        fakeTty.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false));
        fakeTty.Keys.Enqueue(new ConsoleKeyInfo('\0', ConsoleKey.F6, false, false, false));
        fakeTty.Keys.Enqueue(new ConsoleKeyInfo('?', ConsoleKey.Oem2, true, false, false));
        fakeTty.Keys.Enqueue(new ConsoleKeyInfo('\u001b', ConsoleKey.Escape, false, false, false));
        fakeTty.Keys.Enqueue(new ConsoleKeyInfo('\u0011', ConsoleKey.Q, false, false, true)); // Ctrl+Q

        var app = new TuiApp(dispatcher, fakeTty);
        int exitCode = await app.RunAsync(CancellationToken.None);

        Assert.Equal(0, exitCode);
        string vtOut = fakeTty.Output.ToString();
        Assert.Contains("\u001b[?1049h", vtOut, StringComparison.Ordinal);
        Assert.Contains("\u001b[?1049l", vtOut, StringComparison.Ordinal);
        Assert.True(fakeTty.CursorVisible);
        Assert.Equal(fakeTty.CapturedInputMode, fakeTty.CurrentInputMode);
    }
}
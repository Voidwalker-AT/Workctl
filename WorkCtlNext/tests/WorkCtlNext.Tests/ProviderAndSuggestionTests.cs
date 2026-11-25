using WorkCtlNext.Core;
using WorkCtlNext.Providers;
using Xunit;

namespace WorkCtlNext.Tests;

internal sealed class StubProcessRunner : IProcessRunner
{
    public Func<string, IReadOnlyList<string>, CancellationToken, Task<SubprocessResult>>? Handler { get; set; }
    public List<(string Exe, IReadOnlyList<string> Args, string? Cwd)> Calls { get; } = [];

    public async Task<SubprocessResult> RunAsync(
        string executable,
        IReadOnlyList<string> arguments,
        string? workingDirectory,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        Calls.Add((executable, arguments, workingDirectory));
        if (Handler is null)
            return new SubprocessResult(0, string.Empty, string.Empty, 1, false, false, false);
        return await Handler(executable, arguments, cancellationToken).ConfigureAwait(false);
    }
}

public sealed class ProviderAndSuggestionTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _fakePwsh;
    private readonly string _fakeWsctl;
    private readonly string _fakeUlvo;

    public ProviderAndSuggestionTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"WorkCtlNext Test Dir {Guid.NewGuid():N}");
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

    private WorkctlPathsConfig MakeTestConfig() => new(
        WorkspaceRoot: _tempDir,
        WsctlScriptPath: _fakeWsctl,
        PwshExecutable: _fakePwsh,
        UlvoExecutable: _fakeUlvo,
        WsctlTimeout: TimeSpan.FromSeconds(2),
        UlvoFastTimeout: TimeSpan.FromSeconds(2),
        UlvoEnvTimeout: TimeSpan.FromSeconds(2));

    [Fact]
    public async Task Wsctl_SingleObjectUnwrap_NormalizesAndValidatesDiskPath()
    {
        string existingProj = Path.Combine(_tempDir, "Active", "Demo");
        Directory.CreateDirectory(existingProj);

        var runner = new StubProcessRunner
        {
            Handler = (_, _, _) => Task.FromResult(new SubprocessResult(
                0,
                """{"id":"demo-1","name":"Demo Project","path":"Active/Demo","category":"active","status":"active","environment":"uv","gpu":"none","git":true,"commands":{"verify":{"risk":"safe","executable":"ulvo"}}}""",
                "",
                12,
                false,
                false,
                false))
        };

        var wsctl = new WsctlProvider(runner, MakeTestConfig());
        WsctlProjectsResult res = await wsctl.GetProjectsAsync(CancellationToken.None);

        Assert.Equal(ProviderStatus.Available, res.Status);
        Assert.True(res.NormalizedFromSingleObject);
        ProjectSummary proj = Assert.Single(res.Projects);
        Assert.Equal("demo-1", proj.Id);
        Assert.True(proj.Accessible);
        Assert.Single(proj.Actions);
        Assert.Equal("verify", proj.Actions[0].Name);
    }

    [Fact]
    public async Task Wsctl_ExitZeroWithInvalidOrNullJson_FailsExplicitly()
    {
        var runner = new StubProcessRunner();
        var wsctl = new WsctlProvider(runner, MakeTestConfig());

        runner.Handler = (_, _, _) => Task.FromResult(new SubprocessResult(0, "null", "ConvertFrom-Json failed", 5, false, false, false));
        WsctlProjectsResult nullRes = await wsctl.GetProjectsAsync(CancellationToken.None);
        Assert.Equal(ProviderStatus.Error, nullRes.Status);
        Assert.Equal("WSCTL_INVALID_JSON", nullRes.Error?.Code);

        runner.Handler = (_, _, _) => Task.FromResult(new SubprocessResult(0, "{broken json", "", 5, false, false, false));
        WsctlProjectsResult badRes = await wsctl.GetProjectsAsync(CancellationToken.None);
        Assert.Equal(ProviderStatus.Error, badRes.Status);
        Assert.Equal("WSCTL_INVALID_JSON", badRes.Error?.Code);

        runner.Handler = (_, _, _) => Task.FromResult(new SubprocessResult(0, """[{"name":"NoId"}]""", "", 5, false, false, false));
        WsctlProjectsResult badSchema = await wsctl.GetProjectsAsync(CancellationToken.None);
        Assert.Equal(ProviderStatus.Error, badSchema.Status);
        Assert.Equal("WSCTL_INVALID_SCHEMA", badSchema.Error?.Code);
    }

    [Fact]
    public async Task Wsctl_UnavailableAndTimeout_ReportedHonestly()
    {
        var runner = new StubProcessRunner
        {
            Handler = (_, _, _) => Task.FromResult(new SubprocessResult(-1, "", "", 250, true, false, false))
        };
        var wsctlTimeout = new WsctlProvider(runner, MakeTestConfig());
        WsctlProjectsResult timeoutRes = await wsctlTimeout.GetProjectsAsync(CancellationToken.None);
        Assert.Equal(ProviderStatus.Timeout, timeoutRes.Status);
        Assert.Equal("WSCTL_TIMEOUT", timeoutRes.Error?.Code);

        WorkctlPathsConfig missingCfg = MakeTestConfig() with { WsctlScriptPath = Path.Combine(_tempDir, "missing.ps1") };
        var wsctlMissing = new WsctlProvider(runner, missingCfg);
        WsctlProjectsResult unavailRes = await wsctlMissing.GetProjectsAsync(CancellationToken.None);
        Assert.Equal(ProviderStatus.Unavailable, unavailRes.Status);
        Assert.Equal("WSCTL_UNAVAILABLE", unavailRes.Error?.Code);
    }

    [Fact]
    public void Wsctl_ResolveProject_PrefersExactIdOverSubstringMatch()
    {
        var projects = new[]
        {
            new ProjectSummary("other-proj", "Wrapper for exp1", "a", @"E:\a", "active", "active", true, "venv", "none", false, []),
            new ProjectSummary("exp1", "Experiment One", "b", @"E:\b", "academic", "active", true, "ulvo", "none", false, [])
        };

        (ProjectSummary? resolved, ErrorDetail? err) = WsctlProvider.ResolveProject(projects, "exp1");
        Assert.Null(err);
        Assert.Equal("exp1", resolved?.Id);

        (ProjectSummary? missing, ErrorDetail? missErr) = WsctlProvider.ResolveProject(projects, "nonexistent");
        Assert.Null(missing);
        Assert.Equal("PROJECT_NOT_FOUND", missErr?.Code);
    }

    [Fact]
    public async Task Ulvo_StripsUncPrefix_NeverClaimsEnvHealthOnLs_AndHandlesSlowCancel()
    {
        var runner = new StubProcessRunner
        {
            Handler = (_, args, ct) =>
            {
                if (args[0] == "ls")
                {
                    return Task.FromResult(new SubprocessResult(
                        0,
                        """[{"id":"p1","name":"exp1","canonical_path":"\\\\?\\E:\\Workspace\\Academic\\sem5\\DL\\exp1","ecosystem":"Python","registration_state":"managed","has_connector":true,"classification":"standard","manifests":[".ulvo/manifest.toml"]}]""",
                        "",
                        35,
                        false,
                        false,
                        false));
                }
                if (args[0] == "status")
                {
                    return Task.FromResult(new SubprocessResult(0, """{"schema_version":1,"version":"1.2.0","registered_projects":100,"vault_exists":true,"current_project":null}""", "", 45, false, false, false));
                }
                return Task.FromResult(new SubprocessResult(-1, "", "", 10, false, true, false));
            }
        };

        var ulvo = new UlvoProvider(runner, MakeTestConfig());
        var lsRes = await ulvo.ListProjectsAsync(CancellationToken.None);

        Assert.Equal(ProviderStatus.Available, lsRes.Status);
        UlvoListedProject proj = Assert.Single(lsRes.Projects);
        Assert.Equal(@"E:\Workspace\Academic\sem5\DL\exp1", proj.CanonicalPath);
        Assert.False(proj.EnvHealthChecked);
        Assert.Equal("not_checked_on_ls", proj.EnvHealthState);

        var cancelRes = await ulvo.InspectProjectAsync(@"\\?\E:\Workspace\Academic\sem5\DL\exp1", false, CancellationToken.None);
        Assert.Equal(ProviderStatus.Error, cancelRes.Status);
        Assert.Equal("ULVO_CANCELLED", cancelRes.Error?.Code);
        Assert.DoesNotContain(@"\\?\", runner.Calls.Last().Args[1]);
    }

    [Fact]
    public async Task ProcessRunner_RealHungSubprocess_TimesOutAndTerminatesWithoutHang()
    {
        string pwsh = ProcessRunner.FindExecutableOnPath("pwsh", [@"C:\Users\hp\scoop\shims\pwsh.exe"]) ?? "pwsh";
        var runner = new ProcessRunner();
        SubprocessResult res = await runner.RunAsync(
            pwsh,
            ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30"],
            _tempDir,
            TimeSpan.FromMilliseconds(350),
            CancellationToken.None);

        Assert.True(res.TimedOut);
        Assert.InRange(res.DurationMs, 200, 4000);
    }

    [Fact]
    public void SuggestionEngine_SupportsPrefixFuzzyContextRanking_DeterministicallyWithoutExecution()
    {
        var ranker = new DeterministicSuggestionRanker();
        var caps = new List<CapabilityInfo>
        {
            new("workctl.health", "Workstation Health Summary", "Health", "core", "ReadOnly", "available", [], ["json"], "health --json"),
            new("workctl.context", "Workstation / Project Context", "Context", "core", "ReadOnly", "available", [], ["json"], "context --json"),
            new("wsctl.projects", "List WSCTL Projects", "Projects", "wsctl", "ReadOnly", "available", [], ["json"], "projects --json"),
            new("ulvo.runtimes", "Inspect ULVO Runtimes", "Runtimes", "ulvo", "ReadOnly", "unavailable", [], ["json"], "runtimes --json")
        };

        var activeProj = new ProjectSummary(
            "dl-exp1",
            "DL Exp 1",
            "Academic/sem5/DL/exp1",
            @"E:\Workspace\Academic\sem5\DL\exp1",
            "academic",
            "completed",
            true,
            "ulvo",
            "optional",
            false,
            [new ProjectActionSummary("verify", "safe", "ulvo", "Verify weights", true)]);

        var ctx = new SuggestionContext("Projects", activeProj, WsctlAvailable: true, UlvoAvailable: false);

        // Prefix match check
        var prefixRes = ranker.Suggest("health", caps, ctx);
        Assert.NotEmpty(prefixRes);
        Assert.Equal("workctl.health", prefixRes[0].CapabilityId);
        Assert.Equal("prefix", prefixRes[0].MatchKind);

        // Fuzzy subsequence match check
        var fuzzyRes = ranker.Suggest("ctx", caps, ctx);
        Assert.Contains(fuzzyRes, x => x.CapabilityId == "workctl.context");

        // Context + action match check & unavailable penalty
        var actRes = ranker.Suggest("verify", caps, ctx);
        Assert.Contains(actRes, x => x.DisplayName.Contains("verify", StringComparison.OrdinalIgnoreCase));
        Assert.All(actRes, item => Assert.Equal("ReadOnly", item.Risk));

        // Deterministic repeated ordering
        var r1 = ranker.Suggest("", caps, ctx);
        var r2 = ranker.Suggest("", caps, ctx);
        Assert.Equal(r1.Select(x => x.Command), r2.Select(x => x.Command));
    }

    [Fact]
    public void WindowsMachineProvider_ReturnsReadOnlyHostMetricsQuickly()
    {
        var machine = new WindowsMachineProvider();
        MachineSnapshot snap = machine.GetSnapshot();
        Assert.False(string.IsNullOrWhiteSpace(snap.OsVersion));
        Assert.False(string.IsNullOrWhiteSpace(snap.CpuName));
        Assert.True(snap.TotalRamMb > 0);
        Assert.True(snap.LogicalCores > 0);
        Assert.True(snap.ProcessCount > 0);
        Assert.NotEmpty(snap.FixedDisks);
    }
}
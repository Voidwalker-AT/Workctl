using System.Diagnostics;
using System.Text.Json;
using WorkCtlNext.Cli;
using WorkCtlNext.Core;
using WorkCtlNext.Providers;
using Xunit;

namespace WorkCtlNext.Tests;

public sealed class Phase2CliAndTelemetryTests : IDisposable
{
    private readonly string _tempRoot;
    private readonly WorkctlPathsConfig _config;

    public Phase2CliAndTelemetryTests()
    {
        _tempRoot = Path.Combine(Path.GetTempPath(), $"WorkCtlNext_Cli2_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempRoot);
        File.WriteAllText(Path.Combine(_tempRoot, "sample.txt"), "alpha\nbeta\ngamma\n");
        Directory.CreateDirectory(Path.Combine(_tempRoot, "sub"));

        _config = new WorkctlPathsConfig(
            _tempRoot,
            Path.Combine(_tempRoot, "wsctl.ps1"),
            "pwsh.exe",
            "ulvo.exe",
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2));
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempRoot, recursive: true); } catch { }
    }

    [Fact]
    public async Task AgentCli_ReadOnlyFileAndTelemetryCommands_ReturnValidZeroAnsiJson()
    {
        var runner = new ProcessRunner();
        var dispatcher = new CapabilityDispatcher(_config, runner, policyMode: DispatcherPolicyMode.ReadOnly);

        foreach (string[] cmd in new string[][]
        {
            ["ls", "--path", _tempRoot, "--json"],
            ["stat", "--path", Path.Combine(_tempRoot, "sample.txt"), "--json"],
            ["preview", "--path", Path.Combine(_tempRoot, "sample.txt"), "--limit", "2", "--json"],
            ["resolve", "--path", "sub", "--cwd", _tempRoot, "--json"],
            ["processes", "--limit", "5", "--json"],
            ["storage", "--json"],
            ["network", "--json"]
        })
        {
            var stdout = new StringWriter();
            var stderr = new StringWriter();
            var cli = new AgentCli(dispatcher, stdout, stderr);
            int code = await cli.ExecuteAsync(cmd, TestContext.Current.CancellationToken);
            Assert.Equal(0, code);
            Assert.Equal(string.Empty, stderr.ToString());

            string json = stdout.ToString();
            Assert.DoesNotContain("\u001b", json, StringComparison.Ordinal);
            using JsonDocument doc = JsonDocument.Parse(json);
            Assert.Equal(1, doc.RootElement.GetProperty("schemaVersion").GetInt32());
            Assert.True(doc.RootElement.GetProperty("ok").GetBoolean());
        }
    }

    [Fact]
    public async Task AgentCli_AndReadOnlyPolicy_BlockAllFilesystemMutationsWithExitCode2()
    {
        var runner = new ProcessRunner();
        var readOnlyDisp = new CapabilityDispatcher(_config, runner, policyMode: DispatcherPolicyMode.ReadOnly);
        var interactiveDisp = new CapabilityDispatcher(_config, runner, policyMode: DispatcherPolicyMode.InteractivePhase2);

        foreach (string[] mutCmd in new string[][]
        {
            ["rm", Path.Combine(_tempRoot, "sample.txt")],
            ["mkdir", "newdir"],
            ["cp", "a", "b"],
            ["mv", "a", "b"],
            ["rename", "a", "b"]
        })
        {
            var stdout = new StringWriter();
            var stderr = new StringWriter();
            var cli = new AgentCli(readOnlyDisp, stdout, stderr);
            int code = await cli.ExecuteAsync(mutCmd, TestContext.Current.CancellationToken);
            Assert.Equal(2, code);
            Assert.Contains("POLICY_BLOCKED", stdout.ToString(), StringComparison.Ordinal);
        }

        // Even when calling InteractivePhase2 dispatcher directly, CallerSurface.AgentCli MUST be blocked!
        DispatchOutcome blockedDirect = await interactiveDisp.DispatchAsync(
            new CapabilityInvocationRequest(
                "fs.delete",
                SourcePaths: [Path.Combine(_tempRoot, "sample.txt")],
                WorkingDirectory: _tempRoot,
                Confirmed: true,
                Caller: CallerSurface.AgentCli),
            TestContext.Current.CancellationToken);
        Assert.Equal(2, blockedDirect.ExitCode);
        Assert.Equal("POLICY_BLOCKED", blockedDirect.Envelope.Error?.Code);

        // Unconfirmed HumanTui mutation is also blocked (CONFIRMATION_REQUIRED)
        DispatchOutcome unconfirmed = await interactiveDisp.DispatchAsync(
            new CapabilityInvocationRequest(
                "fs.mkdir",
                TargetPath: "unconfirmed-dir",
                WorkingDirectory: _tempRoot,
                Confirmed: false,
                Caller: CallerSurface.HumanTui),
            TestContext.Current.CancellationToken);
        Assert.Equal(2, unconfirmed.ExitCode);
        Assert.Equal("CONFIRMATION_REQUIRED", unconfirmed.Envelope.Error?.Code);
    }

    [Fact]
    public async Task WindowsTelemetryProvider_ReturnsRealLiveMetrics_AndGitProviderInspectsDisposableRepo()
    {
        var telemetry = new WindowsTelemetryProvider();
        ProcessListSnapshot procs = telemetry.GetTopProcesses(10);
        Assert.True(procs.TotalProcessCount > 5);
        Assert.NotEmpty(procs.TopProcesses);

        PerformanceSnapshot perf = await telemetry.GetPerformanceSnapshotAsync(TestContext.Current.CancellationToken);
        Assert.InRange(perf.CpuUtilizationPercent, 0.0, 100.0);
        Assert.True(perf.TotalRamBytes > 0);
        Assert.True(perf.ThreadCount > 0);

        StorageSnapshot storage = telemetry.GetStorageSnapshot();
        Assert.NotEmpty(storage.Volumes);
        Assert.Contains(storage.Volumes, v => v.IsReady && v.TotalBytes > 0);

        NetworkSnapshot net = telemetry.GetNetworkSnapshot();
        Assert.NotEmpty(net.Interfaces);

        var gitProvider = new GitProvider(_config, new ProcessRunner());
        if (gitProvider.IsGitAvailable())
        {
            // Non-repo returns clean IsGitRepository = false
            GitRepositorySnapshot nonRepo = await gitProvider.GetStatusAsync(_tempRoot, TestContext.Current.CancellationToken);
            Assert.False(nonRepo.IsGitRepository);

            // Real disposable git repo inside temp
            string gitRepo = Path.Combine(_tempRoot, "git-sandbox");
            Directory.CreateDirectory(gitRepo);
            RunGit(gitRepo, "init", "-b", "main");
            RunGit(gitRepo, "config", "user.email", "test@local.invalid");
            RunGit(gitRepo, "config", "user.name", "Test User");
            File.WriteAllText(Path.Combine(gitRepo, "tracked.txt"), "hello git\n");
            RunGit(gitRepo, "add", "tracked.txt");
            RunGit(gitRepo, "commit", "-m", "initial commit");
            File.WriteAllText(Path.Combine(gitRepo, "untracked.txt"), "new file\n");

            GitRepositorySnapshot liveGit = await gitProvider.GetStatusAsync(gitRepo, TestContext.Current.CancellationToken);
            Assert.True(liveGit.IsGitRepository);
            Assert.Equal("main", liveGit.BranchName);
            Assert.Equal(1, liveGit.UntrackedCount);
            Assert.Contains("initial commit", liveGit.LastCommitSummary ?? string.Empty);
        }
    }

    private static void RunGit(string cwd, params string[] args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "git",
            WorkingDirectory = cwd,
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (string a in args) psi.ArgumentList.Add(a);
        using var proc = Process.Start(psi)!;
        proc.WaitForExit(5000);
        Assert.Equal(0, proc.ExitCode);
    }
}

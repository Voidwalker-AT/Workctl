using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Xunit;

namespace WorkCtlNext.Tests;

public sealed class EndToEndBinaryTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _spaceWorkDir;

    public EndToEndBinaryTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"wctl_e2e_{Guid.NewGuid():N}");
        _spaceWorkDir = Path.Combine(_tempDir, "folder with spaces");
        Directory.CreateDirectory(_spaceWorkDir);
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempDir, recursive: true); } catch { }
    }

    private static string FindBuiltBinary()
    {
        string testDir = AppContext.BaseDirectory;
        DirectoryInfo? dir = new(testDir);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "WorkCtlNext.slnx")))
            dir = dir.Parent;
        Assert.NotNull(dir);

        string releaseExe = Path.Combine(dir.FullName, "src", "WorkCtlNext", "bin", "Release", "net10.0", "workctl-next.exe");
        if (File.Exists(releaseExe)) return releaseExe;
        string debugExe = Path.Combine(dir.FullName, "src", "WorkCtlNext", "bin", "Debug", "net10.0", "workctl-next.exe");
        Assert.True(File.Exists(debugExe), $"Compiled binary not found at {releaseExe} or {debugExe}");
        return debugExe;
    }

    private static string FindFixturesDir()
    {
        DirectoryInfo? dir = new(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "WorkCtlNext.slnx")))
            dir = dir.Parent;
        Assert.NotNull(dir);
        return Path.Combine(dir.FullName, "tests", "fixtures");
    }

    private static async Task<(int ExitCode, string Stdout, string Stderr)> RunBinaryAsync(
        string[] args,
        string workingDirectory,
        Dictionary<string, string?>? envOverrides = null)
    {
        using var proc = new Process();
        proc.StartInfo = new ProcessStartInfo
        {
            FileName = FindBuiltBinary(),
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        foreach (string a in args)
            proc.StartInfo.ArgumentList.Add(a);

        if (envOverrides is not null)
        {
            foreach ((string k, string? v) in envOverrides)
            {
                if (v is null) proc.StartInfo.Environment.Remove(k);
                else proc.StartInfo.Environment[k] = v;
            }
        }

        Assert.True(proc.Start());
        Task<string> outTask = proc.StandardOutput.ReadToEndAsync();
        Task<string> errTask = proc.StandardError.ReadToEndAsync();
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        await proc.WaitForExitAsync(cts.Token);
        return (proc.ExitCode, await outTask, await errTask);
    }

    [Fact]
    public async Task Binary_CapabilitiesAndHelp_ArbitrarySpaceWorkingDirectory_ValidNoAnsi()
    {
        var help = await RunBinaryAsync(["--help"], _spaceWorkDir);
        Assert.Equal(0, help.ExitCode);
        Assert.DoesNotContain("\u001b", help.Stdout, StringComparison.Ordinal);
        Assert.Contains("capabilities --json", help.Stdout, StringComparison.Ordinal);

        var caps = await RunBinaryAsync(["capabilities", "--json"], _spaceWorkDir);
        Assert.Equal(0, caps.ExitCode);
        Assert.Equal(string.Empty, caps.Stderr);
        Assert.DoesNotContain("\u001b", caps.Stdout, StringComparison.Ordinal);
        using JsonDocument doc = JsonDocument.Parse(caps.Stdout);
        Assert.True(doc.RootElement.GetProperty("ok").GetBoolean());
        Assert.True(doc.RootElement.GetProperty("data").GetProperty("total").GetInt32() >= 8);
    }

    [Fact]
    public async Task Binary_RedirectedTtyTui_FailsCleanlyWithExitCode2()
    {
        var tui = await RunBinaryAsync(["tui"], _spaceWorkDir);
        Assert.Equal(2, tui.ExitCode);
        Assert.DoesNotContain("\u001b[?1049h", tui.Stdout, StringComparison.Ordinal);
        Assert.Contains("interactive terminal", tui.Stderr, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Binary_NegativeControlFixtures_InvalidJsonSingleObjectAndMissingProviders()
    {
        string fixtures = FindFixturesDir();
        Directory.CreateDirectory(Path.Combine(_spaceWorkDir, "proj dir"));

        // 1. Single-object fixture (wsctl F-08 simulation)
        var single = await RunBinaryAsync(["projects", "--json"], _spaceWorkDir, new()
        {
            ["WORKCTL_NEXT_WORKSPACE_ROOT"] = _spaceWorkDir,
            ["WORKCTL_NEXT_WSCTL_SCRIPT"] = Path.Combine(fixtures, "wsctl_single_object.ps1")
        });
        Assert.Equal(0, single.ExitCode);
        using (JsonDocument d = JsonDocument.Parse(single.Stdout))
        {
            Assert.True(d.RootElement.GetProperty("ok").GetBoolean());
            Assert.True(d.RootElement.GetProperty("data").GetProperty("normalizedFromSingleObject").GetBoolean());
            Assert.Equal(1, d.RootElement.GetProperty("data").GetProperty("returned").GetInt32());
        }

        // 2. Corrupt JSON exiting 0 from WSCTL fixture -> workctl-next MUST exit 1 with JSON error!
        var corrupt = await RunBinaryAsync(["projects", "--json"], _spaceWorkDir, new()
        {
            ["WORKCTL_NEXT_WORKSPACE_ROOT"] = _spaceWorkDir,
            ["WORKCTL_NEXT_WSCTL_SCRIPT"] = Path.Combine(fixtures, "wsctl_malformed_json.ps1")
        });
        Assert.Equal(1, corrupt.ExitCode);
        Assert.False(string.IsNullOrWhiteSpace(corrupt.Stderr));
        using (JsonDocument d = JsonDocument.Parse(corrupt.Stdout))
        {
            Assert.False(d.RootElement.GetProperty("ok").GetBoolean());
            Assert.Equal("WSCTL_INVALID_JSON", d.RootElement.GetProperty("error").GetProperty("code").GetString());
        }

        // 3. Unavailable ULVO & WSCTL -> exit 4!
        var unavail = await RunBinaryAsync(["runtimes", "--json"], _spaceWorkDir, new()
        {
            ["WORKCTL_NEXT_ULVO_EXE"] = Path.Combine(_tempDir, "missing_ulvo.exe")
        });
        Assert.Equal(4, unavail.ExitCode);
        using (JsonDocument d = JsonDocument.Parse(unavail.Stdout))
        {
            Assert.False(d.RootElement.GetProperty("ok").GetBoolean());
            Assert.Equal("ULVO_UNAVAILABLE", d.RootElement.GetProperty("error").GetProperty("code").GetString());
        }
    }

    [Fact]
    public async Task Binary_LiveReadOnlyIntegration_RealWsctlAndRealUlvo()
    {
        var projCtx = await RunBinaryAsync(["context", "--project", "dl-exp1", "--json"], _spaceWorkDir);
        Assert.Equal(0, projCtx.ExitCode);
        Assert.Equal(string.Empty, projCtx.Stderr);
        Assert.DoesNotContain("\u001b", projCtx.Stdout, StringComparison.Ordinal);

        using JsonDocument d = JsonDocument.Parse(projCtx.Stdout);
        Assert.True(d.RootElement.GetProperty("ok").GetBoolean());
        JsonElement data = d.RootElement.GetProperty("data");
        Assert.Equal("dl-exp1", data.GetProperty("project").GetProperty("id").GetString());
        Assert.True(data.GetProperty("project").GetProperty("accessible").GetBoolean());
        Assert.True(data.GetProperty("runtime").GetProperty("hasConnector").GetBoolean());
        Assert.Equal("compliant", data.GetProperty("runtime").GetProperty("complianceVerdict").GetString());

        // Missing project live -> exit 3!
        var missing = await RunBinaryAsync(["context", "--project", "__nonexistent_phase1__", "--json"], _spaceWorkDir);
        Assert.Equal(3, missing.ExitCode);
        using JsonDocument md = JsonDocument.Parse(missing.Stdout);
        Assert.Equal("PROJECT_NOT_FOUND", md.RootElement.GetProperty("error").GetProperty("code").GetString());
    }

    [Fact]
    public async Task Binary_AllAgentCommands_ReturnValidCompactJsonWithoutAnsiOrUncPrefixes()
    {
        string[][] cmds =
        [
            ["capabilities", "--json"],
            ["context", "--json"],
            ["projects", "--limit", "5", "--json"],
            ["runtimes", "--include-projects", "--limit", "5", "--json"],
            ["health", "--json"],
            ["suggest", "--query", "verify", "--project", "dl-exp1", "--json"]
        ];

        foreach (string[] cmd in cmds)
        {
            var res = await RunBinaryAsync(cmd, _spaceWorkDir);
            Assert.True(res.ExitCode == 0, $"Command '{string.Join(' ', cmd)}' exited {res.ExitCode}. stderr={res.Stderr} stdout={res.Stdout}");
            Assert.Equal(string.Empty, res.Stderr);
            Assert.DoesNotContain("\u001b", res.Stdout, StringComparison.Ordinal);
            Assert.DoesNotContain(@"\\?\", res.Stdout, StringComparison.Ordinal);

            using JsonDocument doc = JsonDocument.Parse(res.Stdout);
            Assert.Equal(1, doc.RootElement.GetProperty("schemaVersion").GetInt32());
            Assert.True(doc.RootElement.GetProperty("ok").GetBoolean());
        }
    }

    [Fact]
    public async Task Binary_HungUlvoFixture_TimesOutWithExit5AndLeavesZeroOrphans()
    {
        string slowScript = Path.Combine(_tempDir, "slow_ulvo.cmd");
        await File.WriteAllTextAsync(slowScript, "@echo off\r\npowershell -NoProfile -NonInteractive -Command \"Start-Sleep -Seconds 25\"\r\n", TestContext.Current.CancellationToken);

        var res = await RunBinaryAsync(["runtimes", "--json"], _spaceWorkDir, new()
        {
            ["WORKCTL_NEXT_ULVO_EXE"] = slowScript
        });

        Assert.Equal(5, res.ExitCode);
        using JsonDocument doc = JsonDocument.Parse(res.Stdout);
        Assert.False(doc.RootElement.GetProperty("ok").GetBoolean());
        Assert.Equal("ULVO_TIMEOUT", doc.RootElement.GetProperty("error").GetProperty("code").GetString());
    }
}
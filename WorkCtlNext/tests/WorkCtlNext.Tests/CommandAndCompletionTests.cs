using WorkCtlNext.Core;
using Xunit;

namespace WorkCtlNext.Tests;

public sealed class CommandAndCompletionTests : IDisposable
{
    private readonly string _tempRoot;
    private readonly WorkctlPathsConfig _config;
    private readonly FileSystemService _fs;
    private readonly DeterministicCompletionEngine _engine;

    public CommandAndCompletionTests()
    {
        _tempRoot = Path.Combine(Path.GetTempPath(), $"WorkCtlNext_Cmd_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempRoot);
        Directory.CreateDirectory(Path.Combine(_tempRoot, "Folder Alpha"));
        Directory.CreateDirectory(Path.Combine(_tempRoot, "src"));
        File.WriteAllText(Path.Combine(_tempRoot, "README.md"), "# docs");
        File.WriteAllText(Path.Combine(_tempRoot, "My Notes File.txt"), "hello notes");

        _config = new WorkctlPathsConfig(
            _tempRoot,
            Path.Combine(_tempRoot, "wsctl.ps1"),
            "pwsh.exe",
            "ulvo.exe",
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2),
            TimeSpan.FromSeconds(2));
        _fs = new FileSystemService(_config);
        _engine = new DeterministicCompletionEngine(_fs);
    }

    public void Dispose()
    {
        try { Directory.Delete(_tempRoot, recursive: true); } catch { }
    }

    [Fact]
    public void CommandLineParser_ParsesQuotesAndWindowsBackslashes_AndRejectsUnsupportedShellOperators()
    {
        ParsedCommandLine valid = CommandLineParser.Parse(@"cp ""My Notes File.txt"" ""Folder Alpha""");
        Assert.True(valid.IsValid);
        Assert.Equal("cp", valid.CommandVerb);
        Assert.Equal(2, valid.Arguments.Count);
        Assert.Equal("My Notes File.txt", valid.Arguments[0]);
        Assert.Equal("Folder Alpha", valid.Arguments[1]);

        ParsedCommandLine backslashPath = CommandLineParser.Parse(@"cd C:\Windows\System32");
        Assert.True(backslashPath.IsValid);
        Assert.Equal(@"C:\Windows\System32", backslashPath.Arguments[0]);

        foreach (string unsafeCmd in new[]
        {
            "ls | findstr foo",
            "rm foo && del bar",
            "pwd > out.txt",
            "cd $(Get-Location)",
            "ls; pwd"
        })
        {
            ParsedCommandLine bad = CommandLineParser.Parse(unsafeCmd);
            Assert.False(bad.IsValid);
            Assert.Equal("UNSUPPORTED_SHELL_SYNTAX", bad.ErrorCode);
        }

        ParsedCommandLine unclosed = CommandLineParser.Parse("cd \"Folder Alpha");
        Assert.False(unclosed.IsValid);
        Assert.Equal("UNCLOSED_QUOTE", unclosed.ErrorCode);
    }

    [Fact]
    public void CompletionEngine_CompletesCommandsFilesProjectsFlagsAndCursorAwareReplacement()
    {
        var projects = new List<ProjectSummary>
        {
            new("alpha-app", "Alpha App", "src", Path.Combine(_tempRoot, "src"), "active", "active", true, "node", "none", true, [])
        };
        var caps = new CapabilityRegistry().DescribeAll(_config);

        // Command prefix -> inline ghost + command category
        CompletionResult cmdRes = _engine.Compute(new CompletionRequest("hea", 3, _tempRoot, projects, caps, NavigationSectionId.MachineOverview), TestContext.Current.CancellationToken);
        Assert.Contains(cmdRes.Items, c => c.Label == "health" && c.Category == CompletionCategory.Command);
        Assert.Equal("lth", cmdRes.InlineGhostSuffix);

        // Directory with space -> auto-quotes InsertText on argument completion
        CompletionResult dirRes = _engine.Compute(new CompletionRequest("cd Fold", 7, _tempRoot, projects, caps, NavigationSectionId.FilesWorkspace), TestContext.Current.CancellationToken);
        CompletionCandidate? folderItem = dirRes.Items.FirstOrDefault(c => c.Category == CompletionCategory.Directory && c.Label.StartsWith("Folder Alpha", StringComparison.Ordinal));
        Assert.NotNull(folderItem);
        Assert.StartsWith("\"", folderItem!.InsertText);
        string applied = DeterministicCompletionEngine.ApplyCompletion(dirRes, folderItem);
        Assert.Equal(@"cd ""Folder Alpha\""", applied);

        // Mid-line cursor replacement preserves trailing argument text
        string midInput = "cp READ dest";
        CompletionResult midRes = _engine.Compute(new CompletionRequest(midInput, 7, _tempRoot, projects, caps, NavigationSectionId.FilesWorkspace), TestContext.Current.CancellationToken);
        CompletionCandidate readme = midRes.Items.First(c => c.Label == "README.md");
        string midApplied = DeterministicCompletionEngine.ApplyCompletion(midRes, readme);
        Assert.Equal("cp README.md dest", midApplied);

        // Section + project completion on 'open'
        CompletionResult openRes = _engine.Compute(new CompletionRequest("open pro", 8, _tempRoot, projects, caps, NavigationSectionId.MachineOverview), TestContext.Current.CancellationToken);
        Assert.Contains(openRes.Items, c => c.Category == CompletionCategory.Section && c.Label == "projects");

        // Flag completion
        CompletionResult flagRes = _engine.Compute(new CompletionRequest("projects --d", 12, _tempRoot, projects, caps, NavigationSectionId.DevProjects), TestContext.Current.CancellationToken);
        Assert.Contains(flagRes.Items, c => c.Category == CompletionCategory.Flag && c.Label == "--detailed");
    }

    [Fact]
    public void CompletionEngine_IsDeterministicAcrossRepeatedInvocations()
    {
        var req = new CompletionRequest("ls ", 3, _tempRoot, [], [], NavigationSectionId.FilesWorkspace);
        CompletionResult a = _engine.Compute(req, TestContext.Current.CancellationToken);
        CompletionResult b = _engine.Compute(req, TestContext.Current.CancellationToken);
        Assert.Equal(a.Items.Select(i => i.Label), b.Items.Select(i => i.Label));
    }

    [Fact]
    public void CompletionEngine_CoversAliasesActionsUlvoCapabilitiesToolsRelativeAbsoluteAndInvalidPaths()
    {
        var activeProj = new ProjectSummary(
            "beta-ml",
            "Beta ML",
            "src",
            Path.Combine(_tempRoot, "src"),
            "research",
            "active",
            true,
            "ulvo",
            "none",
            true,
            [new ProjectActionSummary("train", "safe", Description: "Train baseline")]);
        var caps = new CapabilityRegistry().DescribeAll(_config);
        caps = new[]
        {
            new CapabilityInfo("ulvo.runtimes", "Inspect ULVO Runtimes", "List runtimes", "ulvo", "ReadOnly", "unavailable", [], ["json"], "runtimes --json"),
            new CapabilityInfo("workctl.health", "Health", "Health summary", "core", "ReadOnly", "available", [], ["json"], "health --json")
        };
        var tools = new List<ToolAvailability>
        {
            new("git", true, @"C:\Program Files\Git\cmd\git.exe"),
            new("missingtool", false, null)
        };

        // Command aliases ('dir' -> 'ls')
        CompletionResult aliasRes = _engine.Compute(
            new CompletionRequest("dir", 3, _tempRoot, [activeProj], caps, NavigationSectionId.MachineOverview, 12, activeProj, tools),
            TestContext.Current.CancellationToken);
        Assert.Contains(aliasRes.Items, c => c.Category == CompletionCategory.Command && c.InsertText == "dir");

        // Registered actions
        CompletionResult actionRes = _engine.Compute(
            new CompletionRequest("tra", 3, _tempRoot, [activeProj], caps, NavigationSectionId.DevProjects, 12, activeProj, tools),
            TestContext.Current.CancellationToken);
        Assert.Contains(actionRes.Items, c => c.Category == CompletionCategory.Action && c.Label.Contains("train", StringComparison.Ordinal));

        // ULVO capability matching even when unavailable
        CompletionResult ulvoRes = _engine.Compute(
            new CompletionRequest("ulvo.", 5, _tempRoot, [activeProj], caps, NavigationSectionId.DevUlvo, 12, activeProj, tools),
            TestContext.Current.CancellationToken);
        Assert.Contains(ulvoRes.Items, c => c.Category == CompletionCategory.Capability && c.Label == "ulvo.runtimes");

        // Installed tool discovery (excludes non-installed tool)
        CompletionResult toolRes = _engine.Compute(
            new CompletionRequest("gi", 2, _tempRoot, [activeProj], caps, NavigationSectionId.MachineOverview, 12, activeProj, tools),
            TestContext.Current.CancellationToken);
        Assert.Contains(toolRes.Items, c => c.Category == CompletionCategory.Tool && c.Label == "git");
        CompletionResult missingToolRes = _engine.Compute(
            new CompletionRequest("missingt", 8, _tempRoot, [activeProj], caps, NavigationSectionId.MachineOverview, 12, activeProj, tools),
            TestContext.Current.CancellationToken);
        Assert.DoesNotContain(missingToolRes.Items, c => c.Category == CompletionCategory.Tool);

        // Relative and absolute path completion + safe handling of nonexistent directory prefix
        CompletionResult absRes = _engine.Compute(
            new CompletionRequest($"ls \"{_tempRoot}\\sr", 4 + _tempRoot.Length + 3, _tempRoot, [activeProj], caps, NavigationSectionId.FilesWorkspace),
            TestContext.Current.CancellationToken);
        Assert.Contains(absRes.Items, c => c.Category == CompletionCategory.Directory && c.Label.StartsWith("src", StringComparison.Ordinal));

        CompletionResult badPath = _engine.Compute(
            new CompletionRequest("cd Z:\\nonexistent_dir_xyz\\foo", 29, _tempRoot, [activeProj], caps, NavigationSectionId.FilesWorkspace),
            TestContext.Current.CancellationToken);
        Assert.DoesNotContain(badPath.Items, c => c.Category == CompletionCategory.File);
    }
}

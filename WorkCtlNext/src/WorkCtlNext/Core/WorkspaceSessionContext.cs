namespace WorkCtlNext.Core;

public sealed class WorkspaceSessionContext
{
    private readonly WorkctlPathsConfig _config;
    private readonly FileSystemService _fs;
    private readonly List<NavigationHistoryEntry> _backStack = new();
    private readonly List<NavigationHistoryEntry> _forwardStack = new();
    private readonly Dictionary<NavigationSectionId, int> _selectedIndexBySection = new();
    private readonly Dictionary<string, bool> _groupExpanded = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Machine"] = true,
        ["Files"] = true,
        ["Development"] = true,
        ["Applications"] = true
    };
    private readonly HashSet<string> _multiSelectedPaths = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<string> _commandHistory = new();
    private readonly List<ConsoleTranscriptEntry> _transcript = new();
    private int _commandHistoryIndex = -1;

    public WorkspaceSessionContext(WorkctlPathsConfig config, FileSystemService fs)
    {
        _config = config;
        _fs = fs;
        ActiveDirectory = PathNormalizer.NormalizeDisplayPath(
            Directory.Exists(config.WorkspaceRoot) ? config.WorkspaceRoot : AppContext.BaseDirectory);
        CurrentSection = NavigationSectionId.MachineOverview;
        Focus = FocusRegion.CommandLine;
        Clipboard = FileClipboardState.Empty;
    }

    public string ActiveDirectory { get; private set; }
    public ProjectSummary? ActiveProject { get; private set; }
    public NavigationSectionId CurrentSection { get; private set; }
    public FocusRegion Focus { get; set; }
    public bool TreeCollapsed { get; set; }
    public FsEntry? SelectedFileEntry { get; set; }
    public FileClipboardState Clipboard { get; private set; }
    public string CommandInput { get; set; } = string.Empty;
    public int CommandCursorIndex { get; set; }
    public CommandResultFeedback? LastCommandResult { get; set; }
    public IReadOnlyList<string> CommandHistory => _commandHistory;
    public IReadOnlyList<ConsoleTranscriptEntry> Transcript => _transcript;
    public int TranscriptScroll { get; set; }
    public IReadOnlyCollection<string> MultiSelectedPaths => _multiSelectedPaths;
    public IReadOnlyCollection<string> RegisteredProjectPaths { get; private set; } = Array.Empty<string>();
    public bool CanGoBack => _backStack.Count > 0;
    public bool CanGoForward => _forwardStack.Count > 0;

    public static IReadOnlyList<NavigationNodeDescriptor> AllNavigationNodes { get; } =
    [
        new(NavigationSectionId.MachineOverview, "Machine", "Console", "windows.overview", true, null, "1"),
        new(NavigationSectionId.MachineProcesses, "Machine", "Tasks", "windows.processes", true, null, null),
        new(NavigationSectionId.MachineServices, "Machine", "Services", null, false, "Planned in Roadmap (no Windows service backend yet).", null),
        new(NavigationSectionId.MachinePerformance, "Machine", "Performance", "windows.performance", true, null, null),
        new(NavigationSectionId.MachineStorage, "Machine", "Storage", "windows.storage", true, null, null),
        new(NavigationSectionId.MachineNetwork, "Machine", "Network", "windows.network", true, null, null),

        new(NavigationSectionId.FilesThisPc, "Files", "This PC", "fs.list", true, null, null),
        new(NavigationSectionId.FilesQuickAccess, "Files", "Quick Access", "fs.list", true, null, null),
        new(NavigationSectionId.FilesWorkspace, "Files", "Workspace", "fs.list", true, null, null),
        new(NavigationSectionId.FilesDownloads, "Files", "Downloads", "fs.list", true, null, null),

        new(NavigationSectionId.DevProjects, "Development", "Projects", "wsctl.list_projects", true, null, "2"),
        new(NavigationSectionId.DevGit, "Development", "Git", "git.status", true, null, null),
        new(NavigationSectionId.DevUlvo, "Development", "ULVO", "ulvo.list_environments", true, null, "3"),
        new(NavigationSectionId.DevToolchains, "Development", "Toolchains", "wsctl.status", true, null, null),

        new(NavigationSectionId.AppsInstalled, "Applications", "Installed", null, false, "Planned in Roadmap (registry app inventory deferred).", null),
        new(NavigationSectionId.AppsRunning, "Applications", "Running", "apps.running", true, null, null),
        new(NavigationSectionId.AppsStartup, "Applications", "Startup", null, false, "Planned in Roadmap (startup inventory deferred).", null)
    ];

    public static NavigationNodeDescriptor GetNode(NavigationSectionId id)
        => AllNavigationNodes.First(n => n.Id == id);

    public bool IsGroupExpanded(string category)
        => _groupExpanded.TryGetValue(category, out bool exp) && exp;

    public void ToggleGroupExpanded(string category)
    {
        bool cur = IsGroupExpanded(category);
        _groupExpanded[category] = !cur;
    }

    public void SetGroupExpanded(string category, bool expanded)
        => _groupExpanded[category] = expanded;

    public int GetSelectionIndex(NavigationSectionId section)
        => _selectedIndexBySection.TryGetValue(section, out int idx) ? idx : 0;

    public void SetSelectionIndex(NavigationSectionId section, int index)
        => _selectedIndexBySection[section] = Math.Max(0, index);

    public void SetActiveProject(ProjectSummary? project)
    {
        ActiveProject = project;
    }

    public void UpdateRegisteredProjectPaths(IEnumerable<ProjectSummary> projects)
    {
        RegisteredProjectPaths = projects
            .Select(p => PathNormalizer.NormalizeForCompare(p.FullPath))
            .Where(p => !string.IsNullOrWhiteSpace(p))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }

    public void NavigateToSection(NavigationSectionId section, bool recordHistory = true)
    {
        if (section == CurrentSection && recordHistory)
        {
            if (section == NavigationSectionId.FilesThisPc)
                SetActiveDirectory(FileSystemService.VirtualThisPc, pushHistory: false);
            else if (section == NavigationSectionId.FilesQuickAccess)
                SetActiveDirectory(FileSystemService.VirtualQuickAccess, pushHistory: false);
            else if (section == NavigationSectionId.FilesWorkspace)
                SetActiveDirectory(_config.WorkspaceRoot, pushHistory: false);
            else if (section == NavigationSectionId.FilesDownloads)
                SetActiveDirectory(_fs.ResolveDownloadsDirectory(), pushHistory: false);
            return;
        }

        if (recordHistory)
        {
            _backStack.Add(new NavigationHistoryEntry(CurrentSection, ActiveDirectory, ActiveProject?.Id));
            if (_backStack.Count > 64)
                _backStack.RemoveAt(0);
            _forwardStack.Clear();
        }

        CurrentSection = section;

        if (section == NavigationSectionId.FilesThisPc)
            SetActiveDirectory(FileSystemService.VirtualThisPc, pushHistory: false);
        else if (section == NavigationSectionId.FilesQuickAccess)
            SetActiveDirectory(FileSystemService.VirtualQuickAccess, pushHistory: false);
        else if (section == NavigationSectionId.FilesWorkspace)
            SetActiveDirectory(_config.WorkspaceRoot, pushHistory: false);
        else if (section == NavigationSectionId.FilesDownloads)
            SetActiveDirectory(_fs.ResolveDownloadsDirectory(), pushHistory: false);
    }

    public void SetActiveDirectory(string newDirectory, bool pushHistory = true)
    {
        string normalized = FileSystemService.IsVirtualPath(newDirectory)
            ? newDirectory
            : PathNormalizer.NormalizeDisplayPath(newDirectory);

        if (string.Equals(normalized, ActiveDirectory, StringComparison.OrdinalIgnoreCase))
            return;

        if (pushHistory)
        {
            _backStack.Add(new NavigationHistoryEntry(CurrentSection, ActiveDirectory, ActiveProject?.Id));
            if (_backStack.Count > 64)
                _backStack.RemoveAt(0);
            _forwardStack.Clear();
        }

        ActiveDirectory = normalized;
        _multiSelectedPaths.Clear();
        SelectedFileEntry = null;
        _selectedIndexBySection[CurrentSection] = 0;
        // Note: intentionally NEVER alters System.Environment.CurrentDirectory so parent pwsh process CWD stays untouched.
    }

    public bool TryGoBack()
    {
        if (_backStack.Count == 0)
            return false;

        _forwardStack.Add(new NavigationHistoryEntry(CurrentSection, ActiveDirectory, ActiveProject?.Id));
        NavigationHistoryEntry prev = _backStack[^1];
        _backStack.RemoveAt(_backStack.Count - 1);

        CurrentSection = prev.Section;
        ActiveDirectory = prev.ActiveDirectory;
        _multiSelectedPaths.Clear();
        SelectedFileEntry = null;
        return true;
    }

    public bool TryGoForward()
    {
        if (_forwardStack.Count == 0)
            return false;

        _backStack.Add(new NavigationHistoryEntry(CurrentSection, ActiveDirectory, ActiveProject?.Id));
        NavigationHistoryEntry next = _forwardStack[^1];
        _forwardStack.RemoveAt(_forwardStack.Count - 1);

        CurrentSection = next.Section;
        ActiveDirectory = next.ActiveDirectory;
        _multiSelectedPaths.Clear();
        SelectedFileEntry = null;
        return true;
    }

    public void ToggleMultiSelect(string fullPath)
    {
        string norm = PathNormalizer.NormalizeDisplayPath(fullPath);
        if (!_multiSelectedPaths.Add(norm))
            _multiSelectedPaths.Remove(norm);
    }

    public void ClearMultiSelect() => _multiSelectedPaths.Clear();

    public void SetClipboard(ClipboardMode mode, IReadOnlyList<string> paths)
    {
        Clipboard = paths.Count == 0 || mode == ClipboardMode.None
            ? FileClipboardState.Empty
            : new FileClipboardState(
                mode,
                paths.Select(PathNormalizer.NormalizeDisplayPath).Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
                ActiveDirectory,
                DateTimeOffset.UtcNow);
    }

    public void ClearClipboard() => Clipboard = FileClipboardState.Empty;

    public void RecordCommand(string commandLine)
    {
        if (string.IsNullOrWhiteSpace(commandLine))
            return;

        string trimmed = commandLine.Trim();
        if (_commandHistory.Count == 0 || !string.Equals(_commandHistory[^1], trimmed, StringComparison.Ordinal))
            _commandHistory.Add(trimmed);

        if (_commandHistory.Count > 100)
            _commandHistory.RemoveAt(0);

        _commandHistoryIndex = _commandHistory.Count;
    }

    public string? RecallPreviousCommand()
    {
        if (_commandHistory.Count == 0)
            return null;
        if (_commandHistoryIndex < 0 || _commandHistoryIndex > _commandHistory.Count)
            _commandHistoryIndex = _commandHistory.Count;
        if (_commandHistoryIndex > 0)
            _commandHistoryIndex--;
        return _commandHistory[_commandHistoryIndex];
    }

    public string? RecallNextCommand()
    {
        if (_commandHistory.Count == 0)
            return null;
        if (_commandHistoryIndex < _commandHistory.Count - 1)
        {
            _commandHistoryIndex++;
            return _commandHistory[_commandHistoryIndex];
        }

        _commandHistoryIndex = _commandHistory.Count;
        return string.Empty;
    }

    public void AppendTranscript(
        string commandText,
        string modeTag,
        bool ok,
        int exitCode,
        long durationMs,
        IReadOnlyList<string> lines,
        string? workingDirectory = null)
    {
        var bounded = lines.Take(160).ToArray();
        _transcript.Add(new ConsoleTranscriptEntry(
            TimestampUtc: DateTimeOffset.UtcNow,
            CommandText: commandText,
            ModeTag: modeTag,
            Ok: ok,
            ExitCode: exitCode,
            DurationMs: durationMs,
            Lines: bounded,
            WorkingDirectory: workingDirectory ?? ActiveDirectory));

        if (_transcript.Count > 120)
            _transcript.RemoveAt(0);
    }

    public void ClearTranscript()
    {
        _transcript.Clear();
        TranscriptScroll = 0;
    }

    public static bool IsFilesSection(NavigationSectionId id)
        => id is NavigationSectionId.FilesThisPc
            or NavigationSectionId.FilesQuickAccess
            or NavigationSectionId.FilesWorkspace
            or NavigationSectionId.FilesDownloads;
}

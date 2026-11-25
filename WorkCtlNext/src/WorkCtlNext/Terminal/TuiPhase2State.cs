using WorkCtlNext.Core;
using WorkCtlNext.Providers;

namespace WorkCtlNext.Terminal;

public enum ModalKind
{
    None = 0,
    ConfirmDelete = 1,
    ConfirmPaste = 2,
    PromptRename = 3,
    PromptMkdir = 4,
    ProtectedBlocked = 5,
    NarrowTreePicker = 6,
    ConfirmTerminateStep1 = 7,
    ConfirmTerminateForceStep2 = 8
}

public sealed class ActiveModalState
{
    public ModalKind Kind { get; init; }
    public string Title { get; init; } = string.Empty;
    public IReadOnlyList<string> MessageLines { get; init; } = Array.Empty<string>();
    public string InputValue { get; set; } = string.Empty;
    public int InputCursor { get; set; }
    public string? ErrorHint { get; set; }
    public bool RequireElevatedConfirm { get; init; }
    public IReadOnlyList<string> TargetPaths { get; init; } = Array.Empty<string>();
    public string? DestinationDirectory { get; init; }
    public bool IsMove { get; init; }
    public bool PermanentDelete { get; init; }
    public string? PendingRenameSource { get; init; }
    public ProcessImpactAssessment? ProcessImpact { get; init; }
}

public sealed record TreeDisplayRow(
    bool IsGroupHeader,
    string Category,
    NavigationNodeDescriptor? Node);

public sealed partial class TuiApp
{
    private WorkspaceSessionContext _session = null!;
    private ICompletionEngine _completionEngine = null!;

    // Phase 2 live telemetry & provider snapshots
    private volatile ProcessListSnapshot? _processList;
    private volatile PerformanceSnapshot? _performance;
    private volatile StorageSnapshot? _storage;
    private volatile NetworkSnapshot? _network;
    private volatile RunningAppsSnapshot? _runningApps;
    private volatile GitRepositorySnapshot? _gitStatus;

    // Filesystem browser state
    private volatile FsDirectoryListing? _fsListing;
    private volatile FsMetadataSnapshot? _fsSelectedMeta;
    private volatile FsPreviewSnapshot? _fsSelectedPreview;
    private string _fsFilter = string.Empty;
    private int _fsScroll;
    private bool _fsDetailOpen;

    // Navigation tree UI state
    private int _treeCursorIndex;
    private int _treeScroll;

    // Other list & Task Manager state
    private int _processScroll;
    private int _processIndex;
    private ProcessSortField _processSort = ProcessSortField.Cpu;
    private bool _processTreeMode;
    private string _processFilter = string.Empty;
    private bool _processDetailOpen;
    private ProcessIdentityToken? _selectedProcessIdentity;
    private ProcessDetailedInspection? _selectedProcessDetail;
    private int _gitScroll;
    private int _gitIndex;
    private int _storageIndex;
    private int _networkIndex;
    private int _appsIndex;
    private int _toolsIndex;

    // Command area & overlays
    private char _commandPromptChar = '>';
    private CompletionResult? _completion;
    private bool _completionDropdownOpen;
    private int _completionIndex;
    private bool _historyBrowsing;
    private bool _commandDrawerOpen;
    private int _commandDrawerScroll;
    private int _lastDrawerPageHeight = 8;
    private ActiveModalState? _modal;
    private int _treePickerIndex;

    public WorkspaceSessionContext Session => _session;
    public CompletionResult? CurrentCompletion => _completion;
    public bool IsCommandDrawerOpen => _commandDrawerOpen;
    public bool IsCompletionDropdownOpen => _completionDropdownOpen;
    public ActiveModalState? CurrentModal => _modal;
    public FsDirectoryListing? CurrentFileListing => _fsListing;
    public ProcessSortField ProcessSort => _processSort;
    public bool ProcessTreeMode => _processTreeMode;
    public string ProcessFilter => _processFilter;
    public bool ProcessDetailOpen => _processDetailOpen;

    private void InitializePhase2State()
    {
        _session = new WorkspaceSessionContext(_dispatcher.Config, _dispatcher.FileSystem);
        _completionEngine = new DeterministicCompletionEngine(_dispatcher.FileSystem);
        SyncCompatibilityAliasesFromSession();
    }

    private void SyncCompatibilityAliasesFromSession()
    {
        if (_screen == TuiScreen.Help)
            return;

        _screen = _session.CurrentSection switch
        {
            NavigationSectionId.DevProjects => TuiScreen.Projects,
            NavigationSectionId.DevUlvo => TuiScreen.Environments,
            _ => TuiScreen.Home
        };

        if (_focus != FocusZone.Search)
        {
            _focus = _session.Focus switch
            {
                FocusRegion.NavigationTree => FocusZone.Navigation,
                _ => FocusZone.Main
            };
        }
    }

    private void SyncControlCHandling()
    {
        bool allowCtrlCCopy =
            _modal is null
            && _screen != TuiScreen.Help
            && _focus != FocusZone.Search
            && _session.Focus == FocusRegion.MainPane
            && WorkspaceSessionContext.IsFilesSection(_session.CurrentSection)
            && !_fsDetailOpen;

        _backend.SetTreatControlCAsInput(allowCtrlCCopy);
    }

    private List<TreeDisplayRow> BuildVisibleTreeRows()
    {
        var rows = new List<TreeDisplayRow>(24);
        string[] categories = ["Machine", "Files", "Development", "Applications"];
        foreach (string cat in categories)
        {
            rows.Add(new TreeDisplayRow(true, cat, null));
            if (!_session.IsGroupExpanded(cat))
                continue;

            foreach (NavigationNodeDescriptor node in WorkspaceSessionContext.AllNavigationNodes)
            {
                if (string.Equals(node.Category, cat, StringComparison.OrdinalIgnoreCase))
                    rows.Add(new TreeDisplayRow(false, cat, node));
            }
        }
        return rows;
    }

    private void SyncTreeCursorToCurrentSection()
    {
        var rows = BuildVisibleTreeRows();
        for (int i = 0; i < rows.Count; i++)
        {
            if (!rows[i].IsGroupHeader && rows[i].Node?.Id == _session.CurrentSection)
            {
                _treeCursorIndex = i;
                return;
            }
        }
        _treeCursorIndex = Math.Clamp(_treeCursorIndex, 0, Math.Max(0, rows.Count - 1));
    }

    public void RefreshProcessManagerSnapshot()
    {
        ProcessListSnapshot snap = _dispatcher.Telemetry.GetProcesses(
            limit: null,
            sort: _processSort,
            filter: _processFilter,
            resolveOwners: false);
        _processList = snap;
        PreserveOrResolveProcessSelection();
        if (_processDetailOpen && _selectedProcessIdentity is { } sel)
            _selectedProcessDetail = _dispatcher.Telemetry.InspectProcess(sel.Pid, snap.AllProcesses ?? snap.TopProcesses);
    }

    private List<ProcessTreeRow> GetDisplayedProcessRows()
    {
        ProcessListSnapshot snap = _processList ?? (_processList = _dispatcher.Telemetry.GetProcesses(
            limit: null,
            sort: _processSort,
            filter: _processFilter));
        IReadOnlyList<ProcessEntrySnapshot> list = snap.AllProcesses ?? snap.TopProcesses;

        if (_processTreeMode)
        {
            return WindowsTelemetryProvider.BuildProcessTree(list).ToList();
        }

        return list.Select(p => new ProcessTreeRow(p, 0, false, 0, string.Empty)).ToList();
    }

    private void PreserveOrResolveProcessSelection()
    {
        List<ProcessTreeRow> rows = GetDisplayedProcessRows();
        if (rows.Count == 0)
        {
            _processIndex = 0;
            _processScroll = 0;
            _selectedProcessIdentity = null;
            _selectedProcessDetail = null;
            return;
        }

        if (_selectedProcessIdentity is { } prev)
        {
            int matchIdx = rows.FindIndex(r =>
                r.Process.Pid == prev.Pid &&
                (prev.CreationTimeUtcTicks == 0 || r.Process.CreationTimeUtcTicks == 0 || r.Process.CreationTimeUtcTicks == prev.CreationTimeUtcTicks));
            if (matchIdx >= 0)
            {
                _processIndex = matchIdx;
                ProcessEntrySnapshot m = rows[matchIdx].Process;
                _selectedProcessIdentity = new ProcessIdentityToken(m.Pid, m.CreationTimeUtcTicks, m.Name, m.ExecutablePath);
                return;
            }
        }

        _processIndex = Math.Clamp(_processIndex, 0, rows.Count - 1);
        ProcessEntrySnapshot cur = rows[_processIndex].Process;
        _selectedProcessIdentity = new ProcessIdentityToken(cur.Pid, cur.CreationTimeUtcTicks, cur.Name, cur.ExecutablePath);
    }
}

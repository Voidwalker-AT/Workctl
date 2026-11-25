using System.Diagnostics;
using WorkCtlNext.Core;

namespace WorkCtlNext.Terminal;

public enum TuiScreen
{
    Home = 1,
    Projects = 2,
    Environments = 3,
    Palette = 4,
    Help = 5
}

public enum FocusZone
{
    Navigation = 0,
    Main = 1,
    Search = 2
}

public sealed partial class TuiApp
{
    private const int AnimTickMs = 100;
    private const int HighlightDurationMs = 550;
    private const int PaletteOpenFlashMs = 120;

    private readonly CapabilityDispatcher _dispatcher;
    private readonly ITerminalBackend _backend;
    private readonly DiffRenderer _renderer;
    private TuiVisualOptions _visualOptions;
    private DesignTheme _theme;

    private TuiScreen _screen = TuiScreen.Home;
    private TuiScreen _returnScreen = TuiScreen.Home;
    private FocusZone _focus = FocusZone.Main;

    private volatile MachineSnapshot? _machine;
    private volatile WsctlProjectsResult? _wsctlProjects;
    private volatile WsctlHealthSnapshot? _wsctlHealth;
    private volatile UlvoStatusSummary? _ulvoStatus;
    private volatile UlvoRuntimesPayload? _ulvoRuntimes;
    private volatile IReadOnlyList<ToolAvailability> _tools = [];
    private volatile IReadOnlyList<CapabilityInfo> _capabilities = [];

    private volatile bool _loading = true;
    private volatile string _statusMessage = "Loading workstation telemetry...";
    private int _refreshProvidersDone;
    private const int RefreshProvidersTotal = 4;
    private long _lastRefreshMs;

    private long _refreshFlashUntilTs;
    private long _wsctlSettledUntilTs;
    private long _ulvoSettledUntilTs;
    private long _healthSettledUntilTs;
    private long _inspectSettledUntilTs;
    private long _paletteOpenedTs;
    private int _animPhase;

    // Home screen interactive state
    private int _homeItemIndex;

    // Projects screen state (preserved across screen switches)
    private string _projectFilter = string.Empty;
    private int _projectIndex;
    private int _projectScroll;
    private bool _projectDetailOpen;
    private readonly Dictionary<string, UlvoProjectInspection> _projectInspectCache = new(StringComparer.OrdinalIgnoreCase);
    private string? _inspectingProjectId;

    // Environments / Runtimes screen state (preserved across screen switches)
    private string _envFilter = string.Empty;
    private int _envIndex;
    private int _envScroll;
    private bool _envDetailOpen;
    private readonly Dictionary<string, UlvoProjectInspection> _envInspectCache = new(StringComparer.OrdinalIgnoreCase);
    private string? _inspectingEnvPath;

    // Command palette state
    private string _paletteQuery = string.Empty;
    private int _paletteSuggestionIndex;
    private int _paletteSuggestionScroll;
    private int _paletteResultScroll;
    private int _lastPaletteResultPageHeight = 10;
    private DispatchOutcome? _paletteOutcome;
    private string? _paletteExecutedCommand;
    private bool _paletteRunning;
    private bool _paletteShowRawJson;

    // Help screen state
    private int _helpScroll;
    private int _lastHelpPageHeight = 12;

    // Refresh / runtime async coordination
    private Task? _activeRefreshTask;
    private CancellationTokenSource? _refreshCts;
    private Task? _activePaletteTask;
    private Task? _activeProjectInspectTask;
    private Task? _activeEnvInspectTask;
    private TerminalSession? _activeSession;
    private volatile bool _commandExitRequested;

    public TuiScreen Screen => _screen;
    public FocusZone Focus => _focus;
    public bool ReducedMotion => _visualOptions.ReducedMotion;
    public DesignTheme ActiveTheme => _theme;
    public DiffRenderer Renderer => _renderer;
    public string? PaletteExecutedCommand => _paletteExecutedCommand;
    public bool IsPaletteRunning => _paletteRunning || _activePaletteTask is not null;
    public bool IsInspectingEnvironment => _inspectingEnvPath is not null || _activeEnvInspectTask is not null;
    public bool IsEnvironmentDetailOpen => _envDetailOpen;
    public int InspectedEnvironmentCount { get { lock (_envInspectCache) return _envInspectCache.Count; } }

    public TuiApp(
        CapabilityDispatcher dispatcher,
        ITerminalBackend? backend = null,
        TuiVisualOptions? visualOptions = null)
    {
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _backend = backend ?? new WindowsTerminalBackend();
        _renderer = new DiffRenderer(_backend);
        _visualOptions = visualOptions ?? TuiVisualOptions.FromEnvironmentAndArgs([]);
        _theme = new DesignTheme(_visualOptions.NoColor, _visualOptions.AsciiOnly);
        InitializePhase2State();
    }

    public async Task<int> RunAsync(CancellationToken cancellationToken)
    {
        using var session = new TerminalSession(_backend);
        using var loopCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        bool exitRequested = false;

        ConsoleCancelEventHandler cancelHandler = (_, e) =>
        {
            e.Cancel = true;
            exitRequested = true;
            loopCts.Cancel();
        };

        _backend.CancelKeyPress += cancelHandler;
        try
        {
            _commandExitRequested = false;
            _activeSession = session;
            session.Enter();
            if (!_theme.AsciiOnly && !_backend.IsUtf8Supported)
            {
                _visualOptions = _visualOptions with { AsciiOnly = true };
                _theme = new DesignTheme(_visualOptions.NoColor, asciiOnly: true);
            }
            SyncControlCHandling();
            bool alreadyPreloaded = _wsctlProjects is not null || _ulvoStatus is not null;
            if (!alreadyPreloaded || _capabilities.Count == 0)
                _capabilities = _dispatcher.Registry.DescribeAll(_dispatcher.Config, _dispatcher.Git.IsGitAvailable());
            if (!alreadyPreloaded || _tools.Count == 0)
                _tools = _dispatcher.ProbeRelevantTools();
            if (!alreadyPreloaded || _machine is null)
                _machine = _dispatcher.Machine.GetSnapshot();
            if (!alreadyPreloaded || _fsListing is null)
                RefreshFilesView(resetScroll: true);

            if (!alreadyPreloaded)
                BeginBackgroundRefresh(loopCts.Token);
            else
                _loading = false;

            int lastW = _backend.WindowWidth;
            int lastH = _backend.WindowHeight;
            int lastDone = Volatile.Read(ref _refreshProvidersDone);
            _renderer.Render(RenderFrame(lastW, lastH));

            long animStepTicks = Stopwatch.Frequency * AnimTickMs / 1000;
            long nextAnimTickTs = Stopwatch.GetTimestamp() + animStepTicks;
            bool dirty = false;

            while (!exitRequested && !_commandExitRequested && !loopCts.IsCancellationRequested && !session.CancelRequested)
            {
                dirty |= PumpBackgroundTasks();

                int curDone = Volatile.Read(ref _refreshProvidersDone);
                if (curDone != lastDone)
                {
                    lastDone = curDone;
                    dirty = true;
                }

                int curW = _backend.WindowWidth;
                int curH = _backend.WindowHeight;
                if (curW != lastW || curH != lastH)
                {
                    lastW = curW;
                    lastH = curH;
                    _renderer.Invalidate();
                    dirty = true;
                }

                while (_backend.KeyAvailable)
                {
                    ConsoleKeyInfo key = _backend.ReadKey(intercept: true);
                    (bool shouldExit, bool keyDirty) = await HandleKeyAsync(key, loopCts.Token).ConfigureAwait(false);
                    if (keyDirty)
                        dirty = true;
                    if (shouldExit || _commandExitRequested)
                    {
                        exitRequested = true;
                        break;
                    }
                }

                if (exitRequested || _commandExitRequested)
                    break;

                long nowTs = Stopwatch.GetTimestamp();
                if (IsSpinnerActive() && nowTs >= nextAnimTickTs)
                {
                    _animPhase = (_animPhase + 1) & 0x7FFF;
                    nextAnimTickTs = nowTs + animStepTicks;
                    dirty = true;
                }

                dirty |= ExpireTransientTimers(nowTs);

                if (dirty)
                {
                    _renderer.Render(RenderFrame(lastW, lastH));
                    dirty = false;
                }

                try
                {
                    await Task.Delay(35, loopCts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }

            return 0;
        }
        finally
        {
            _backend.CancelKeyPress -= cancelHandler;
            try { _refreshCts?.Cancel(); } catch { /* ignore */ }
            _refreshCts?.Dispose();
            _refreshCts = null;
            _activeSession = null;
            session.Dispose();
        }
    }

    private bool IsSpinnerActive()
    {
        if (_visualOptions.ReducedMotion)
            return false;

        return _loading
            || _paletteRunning
            || _inspectingProjectId is not null
            || _inspectingEnvPath is not null;
    }

    private bool ExpireTransientTimers(long nowTs)
    {
        bool changed = false;
        changed |= ExpireStamp(ref _refreshFlashUntilTs, nowTs);
        changed |= ExpireStamp(ref _wsctlSettledUntilTs, nowTs);
        changed |= ExpireStamp(ref _ulvoSettledUntilTs, nowTs);
        changed |= ExpireStamp(ref _healthSettledUntilTs, nowTs);
        changed |= ExpireStamp(ref _inspectSettledUntilTs, nowTs);

        long opened = Volatile.Read(ref _paletteOpenedTs);
        if (opened != 0 && (nowTs - opened) >= (Stopwatch.Frequency * PaletteOpenFlashMs / 1000))
        {
            Volatile.Write(ref _paletteOpenedTs, 0);
            changed = true;
        }

        return changed;
    }

    private static bool ExpireStamp(ref long stampTs, long nowTs)
    {
        long cur = Volatile.Read(ref stampTs);
        if (cur != 0 && nowTs >= cur)
        {
            Volatile.Write(ref stampTs, 0);
            return true;
        }
        return false;
    }

    private void ClearTransientFlashes()
    {
        Volatile.Write(ref _refreshFlashUntilTs, 0);
        Volatile.Write(ref _wsctlSettledUntilTs, 0);
        Volatile.Write(ref _ulvoSettledUntilTs, 0);
        Volatile.Write(ref _healthSettledUntilTs, 0);
        Volatile.Write(ref _inspectSettledUntilTs, 0);
        Volatile.Write(ref _paletteOpenedTs, 0);
    }

    private void MarkSettled(ref long stampTs)
    {
        if (_visualOptions.ReducedMotion)
            return;
        Volatile.Write(ref stampTs, Stopwatch.GetTimestamp() + (Stopwatch.Frequency * HighlightDurationMs / 1000));
    }

    private static bool IsHighlightActive(long stampTs)
    {
        long val = Volatile.Read(ref stampTs);
        return val != 0 && Stopwatch.GetTimestamp() < val;
    }

    private void BeginBackgroundRefresh(CancellationToken outerCt)
    {
        try { _refreshCts?.Cancel(); } catch (ObjectDisposedException) { }
        _refreshCts?.Dispose();
        _refreshCts = CancellationTokenSource.CreateLinkedTokenSource(outerCt);
        _loading = true;
        Volatile.Write(ref _refreshProvidersDone, 0);
        _statusMessage = "Syncing telemetry...";
        CancellationToken ct = _refreshCts.Token;
        _activeRefreshTask = Task.Run(() => RefreshAllProvidersAsync(ct), CancellationToken.None);
    }

    public async Task RefreshAllProvidersAsync(CancellationToken cancellationToken)
    {
        var sw = Stopwatch.StartNew();
        _machine = _dispatcher.Machine.GetSnapshot();
        _capabilities = _dispatcher.Registry.DescribeAll(_dispatcher.Config, _dispatcher.Git.IsGitAvailable());
        _tools = _dispatcher.ProbeRelevantTools();
        _storage = _dispatcher.Telemetry.GetStorageSnapshot();
        RefreshFilesView();
        Volatile.Write(ref _refreshProvidersDone, 0);

        async Task TrackProjectsAsync()
        {
            WsctlProjectsResult res = await _dispatcher.Wsctl.GetProjectsAsync(cancellationToken).ConfigureAwait(false);
            if (cancellationToken.IsCancellationRequested) return;
            if (res.Error?.Code != "WSCTL_CANCELLED" || _wsctlProjects is null)
            {
                _wsctlProjects = res;
                _session.UpdateRegisteredProjectPaths(res.Projects);
                if (_session.ActiveProject is null)
                    _session.SetActiveProject(ResolveCwdProject());
            }
            MarkSettled(ref _wsctlSettledUntilTs);
            Interlocked.Increment(ref _refreshProvidersDone);
        }

        async Task TrackHealthAsync()
        {
            WsctlHealthSnapshot res = await _dispatcher.Wsctl.GetWorkspaceHealthAsync(cancellationToken).ConfigureAwait(false);
            if (cancellationToken.IsCancellationRequested) return;
            _wsctlHealth = res;
            MarkSettled(ref _healthSettledUntilTs);
            Interlocked.Increment(ref _refreshProvidersDone);
        }

        async Task TrackUlvoStatusAsync()
        {
            UlvoStatusSummary res = await _dispatcher.Ulvo.GetStatusAsync(cancellationToken).ConfigureAwait(false);
            if (cancellationToken.IsCancellationRequested) return;
            if (res.Error?.Code != "ULVO_CANCELLED" || _ulvoStatus is null)
                _ulvoStatus = res;
            MarkSettled(ref _ulvoSettledUntilTs);
            Interlocked.Increment(ref _refreshProvidersDone);
        }

        async Task TrackUlvoRuntimesAsync()
        {
            UlvoRuntimesPayload res = await LoadUlvoRuntimesAsync(cancellationToken).ConfigureAwait(false);
            if (cancellationToken.IsCancellationRequested) return;
            if (res.ListError?.Code != "ULVO_CANCELLED" || _ulvoRuntimes is null)
                _ulvoRuntimes = res;
            MarkSettled(ref _ulvoSettledUntilTs);
            Interlocked.Increment(ref _refreshProvidersDone);
        }

        await Task.WhenAll(
            TrackProjectsAsync(),
            TrackHealthAsync(),
            TrackUlvoStatusAsync(),
            TrackUlvoRuntimesAsync()).ConfigureAwait(false);

        if (cancellationToken.IsCancellationRequested)
            return;

        ClampSelections();

        sw.Stop();
        _lastRefreshMs = sw.ElapsedMilliseconds;
        _loading = false;
        _statusMessage = $"Synced in {_lastRefreshMs}ms";
        if (!_visualOptions.ReducedMotion)
            Volatile.Write(ref _refreshFlashUntilTs, Stopwatch.GetTimestamp() + (Stopwatch.Frequency * 750 / 1000));
    }

    private async Task<UlvoRuntimesPayload> LoadUlvoRuntimesAsync(CancellationToken ct)
    {
        var status = await _dispatcher.Ulvo.GetStatusAsync(ct).ConfigureAwait(false);
        var ls = await _dispatcher.Ulvo.ListProjectsAsync(ct).ConfigureAwait(false);
        return new UlvoRuntimesPayload(
            status,
            ls.Status,
            ls.Projects.Count,
            ls.Projects,
            "Lightweight listing; press Enter on any runtime to inspect health.",
            ls.Error);
    }

    private bool PumpBackgroundTasks()
    {
        bool changed = false;

        if (_activeRefreshTask is { IsCompleted: true })
        {
            if (_activeRefreshTask.IsFaulted && _activeRefreshTask.Exception is not null)
            {
                _loading = false;
                _statusMessage = $"Refresh error: {_activeRefreshTask.Exception.GetBaseException().Message}";
            }
            _activeRefreshTask = null;
            ClampSelections();
            changed = true;
        }

        if (_activePaletteTask is { IsCompleted: true })
        {
            _activePaletteTask = null;
            _paletteRunning = false;
            changed = true;
        }

        if (_activeProjectInspectTask is { IsCompleted: true })
        {
            _activeProjectInspectTask = null;
            _inspectingProjectId = null;
            changed = true;
        }

        if (_activeEnvInspectTask is { IsCompleted: true })
        {
            _activeEnvInspectTask = null;
            _inspectingEnvPath = null;
            changed = true;
        }

        return changed;
    }

    private void ClampSelections()
    {
        int hCount = GetHomeItems().Count;
        _homeItemIndex = hCount == 0 ? 0 : Math.Clamp(_homeItemIndex, 0, hCount - 1);

        int pCount = GetFilteredProjects().Count;
        _projectIndex = pCount == 0 ? 0 : Math.Clamp(_projectIndex, 0, pCount - 1);

        int eCount = GetFilteredRuntimes().Count;
        _envIndex = eCount == 0 ? 0 : Math.Clamp(_envIndex, 0, eCount - 1);
    }

    private Task<(bool ExitRequested, bool Dirty)> HandleKeyAsync(ConsoleKeyInfo key, CancellationToken ct)
        => HandlePhase2KeyAsync(key, ct);

    private bool HandleHelpKey(ConsoleKeyInfo key, ref bool exitRequested, CancellationToken ct)
    {
        if (key.Key is ConsoleKey.Q || key.KeyChar is 'q' or 'Q')
        {
            exitRequested = true;
            return false;
        }

        if (key.Key is ConsoleKey.Escape or ConsoleKey.Enter || key.KeyChar == '?')
        {
            _screen = _returnScreen == TuiScreen.Help ? TuiScreen.Home : _returnScreen;
            _focus = FocusZone.Main;
            _helpScroll = 0;
            return true;
        }

        switch (key.Key)
        {
            case ConsoleKey.UpArrow or ConsoleKey.K:
                _helpScroll = Math.Max(0, _helpScroll - 1);
                return true;
            case ConsoleKey.DownArrow or ConsoleKey.J:
                _helpScroll++;
                return true;
            case ConsoleKey.PageUp:
                _helpScroll = Math.Max(0, _helpScroll - Math.Max(3, _lastHelpPageHeight - 2));
                return true;
            case ConsoleKey.PageDown:
                _helpScroll += Math.Max(3, _lastHelpPageHeight - 2);
                return true;
            case ConsoleKey.Home:
                _helpScroll = 0;
                return true;
        }

        if (key.KeyChar is '1' or '2' or '3' or '4' or ':' or 'r' or 'R' or 'm' or 'M')
            return HandleGlobalNavKey(key, ct);

        return false;
    }

    private bool HandleGlobalNavKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        switch (key.KeyChar)
        {
            case '1':
                SwitchScreen(TuiScreen.Home);
                return true;
            case '2':
                SwitchScreen(TuiScreen.Projects);
                return true;
            case '3':
                SwitchScreen(TuiScreen.Environments);
                return true;
            case '4' or ':':
                OpenPalette();
                return true;
            case '5' or '?':
                OpenHelp();
                return true;
            case 'r' or 'R':
                BeginBackgroundRefresh(ct);
                return true;
            case 'm' or 'M':
                _visualOptions = _visualOptions with { ReducedMotion = !_visualOptions.ReducedMotion };
                if (_visualOptions.ReducedMotion)
                    ClearTransientFlashes();
                _statusMessage = _visualOptions.ReducedMotion ? "Reduced motion ON" : "Motion ON";
                return true;
            default:
                return false;
        }
    }

    private void SwitchScreen(TuiScreen next)
    {
        if (next != TuiScreen.Help && next != TuiScreen.Palette)
            _returnScreen = next;
        _screen = next;
        if (_focus == FocusZone.Search)
            _focus = FocusZone.Main;
        ClearTransientFlashes();
        if (_statusMessage.StartsWith("Inspected ", StringComparison.Ordinal))
            _statusMessage = $"Synced in {_lastRefreshMs}ms";
    }

    private void OpenPalette(string? seedQuery = null, bool autoExecuteSeed = false, CancellationToken ct = default)
    {
        if (_screen != TuiScreen.Palette && _screen != TuiScreen.Help)
            _returnScreen = _screen;
        _screen = TuiScreen.Palette;
        _focus = FocusZone.Search;
        ClearTransientFlashes();
        if (!_visualOptions.ReducedMotion)
            Volatile.Write(ref _paletteOpenedTs, Stopwatch.GetTimestamp());
        if (seedQuery is not null)
        {
            _paletteQuery = seedQuery;
            _paletteSuggestionIndex = 0;
            _paletteSuggestionScroll = 0;
            _paletteResultScroll = 0;
            if (autoExecuteSeed)
                BeginDispatchPaletteCommand(seedQuery, ct);
        }
    }

    private void OpenHelp()
    {
        if (_screen != TuiScreen.Help && _screen != TuiScreen.Palette)
            _returnScreen = _screen;
        _screen = TuiScreen.Help;
        _focus = FocusZone.Main;
        _helpScroll = 0;
        ClearTransientFlashes();
    }

    private bool HandleNavigationZoneKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        if (key.Key == ConsoleKey.Escape)
        {
            if (_screen == TuiScreen.Palette || _screen == TuiScreen.Help)
                _screen = _returnScreen is TuiScreen.Palette or TuiScreen.Help ? TuiScreen.Home : _returnScreen;
            _focus = FocusZone.Main;
            return true;
        }

        if (key.KeyChar == '/')
        {
            if (_screen == TuiScreen.Home)
                SwitchScreen(TuiScreen.Projects);
            if (_screen is TuiScreen.Projects or TuiScreen.Environments)
                _focus = FocusZone.Search;
            else
                OpenPalette();
            return true;
        }

        switch (key.Key)
        {
            case ConsoleKey.UpArrow or ConsoleKey.K:
                _screen = _screen switch
                {
                    TuiScreen.Projects => TuiScreen.Home,
                    TuiScreen.Environments => TuiScreen.Projects,
                    TuiScreen.Palette => TuiScreen.Environments,
                    TuiScreen.Help => TuiScreen.Palette,
                    _ => TuiScreen.Home
                };
                return true;
            case ConsoleKey.DownArrow or ConsoleKey.J:
                _screen = _screen switch
                {
                    TuiScreen.Home => TuiScreen.Projects,
                    TuiScreen.Projects => TuiScreen.Environments,
                    TuiScreen.Environments => TuiScreen.Palette,
                    TuiScreen.Palette => TuiScreen.Help,
                    _ => _screen
                };
                return true;
            case ConsoleKey.Enter or ConsoleKey.RightArrow:
                if (_screen == TuiScreen.Palette)
                    OpenPalette();
                else if (_screen == TuiScreen.Help)
                    OpenHelp();
                else
                    _focus = FocusZone.Main;
                return true;
            default:
                return HandleGlobalNavKey(key, ct);
        }
    }

    private bool HandleSearchKey(ConsoleKeyInfo key)
    {
        if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.U)
        {
            SetActiveFilter(string.Empty);
            return true;
        }

        if (key.Key == ConsoleKey.Escape)
        {
            SetActiveFilter(string.Empty);
            _focus = FocusZone.Main;
            return true;
        }

        if (key.Key is ConsoleKey.Enter or ConsoleKey.DownArrow)
        {
            _focus = FocusZone.Main;
            return true;
        }

        if (key.Key == ConsoleKey.Backspace)
        {
            string cur = GetActiveFilter();
            if (cur.Length > 0)
            {
                SetActiveFilter(cur[..^1]);
                return true;
            }
            _focus = FocusZone.Main;
            return true;
        }

        if (!char.IsControl(key.KeyChar))
        {
            SetActiveFilter(GetActiveFilter() + key.KeyChar);
            return true;
        }

        return false;
    }

    private string GetActiveFilter() => _screen == TuiScreen.Projects ? _projectFilter : _envFilter;

    private void SetActiveFilter(string value)
    {
        if (_screen == TuiScreen.Projects)
        {
            _projectFilter = value;
            _projectIndex = 0;
            _projectScroll = 0;
            _projectDetailOpen = false;
        }
        else if (_screen == TuiScreen.Environments)
        {
            _envFilter = value;
            _envIndex = 0;
            _envScroll = 0;
            _envDetailOpen = false;
        }
    }

    private bool HandleHomeKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        if (key.Key == ConsoleKey.LeftArrow)
        {
            _focus = FocusZone.Navigation;
            return true;
        }

        if (key.KeyChar == '/')
        {
            SwitchScreen(TuiScreen.Projects);
            _focus = FocusZone.Search;
            return true;
        }

        var items = GetHomeItems();
        if (items.Count > 0)
        {
            switch (key.Key)
            {
                case ConsoleKey.UpArrow or ConsoleKey.K:
                    _homeItemIndex = Math.Max(0, _homeItemIndex - 1);
                    return true;
                case ConsoleKey.DownArrow or ConsoleKey.J:
                    _homeItemIndex = Math.Min(items.Count - 1, _homeItemIndex + 1);
                    return true;
                case ConsoleKey.Home:
                    _homeItemIndex = 0;
                    return true;
                case ConsoleKey.End:
                    _homeItemIndex = items.Count - 1;
                    return true;
            }
        }

        if (key.Key == ConsoleKey.Enter)
        {
            if (items.Count > 0)
            {
                HomeQuickItem selected = items[Math.Clamp(_homeItemIndex, 0, items.Count - 1)];
                if (selected.ProjectId is not null)
                {
                    SwitchScreen(TuiScreen.Projects);
                    var list = GetFilteredProjects();
                    int idx = list.FindIndex(p => string.Equals(p.Id, selected.ProjectId, StringComparison.OrdinalIgnoreCase));
                    if (idx >= 0) _projectIndex = idx;
                    return true;
                }
                if (selected.Command is not null)
                {
                    bool autoRun = !selected.Command.Contains('<', StringComparison.Ordinal);
                    OpenPalette(selected.Command, autoExecuteSeed: autoRun, ct);
                    return true;
                }
            }

            OpenPalette();
            return true;
        }

        return false;
    }

    private bool HandleProjectsKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        if (key.KeyChar == '/' && !(DesignTheme.GetBreakpoint(_backend.WindowWidth) == LayoutBreakpoint.Narrow && _projectDetailOpen))
        {
            _focus = FocusZone.Search;
            return true;
        }

        if (key.Key == ConsoleKey.Escape)
        {
            if (_projectDetailOpen)
            {
                _projectDetailOpen = false;
                return true;
            }
            if (!string.IsNullOrEmpty(_projectFilter))
            {
                SetActiveFilter(string.Empty);
                return true;
            }
            SwitchScreen(TuiScreen.Home);
            return true;
        }

        if (key.Key == ConsoleKey.LeftArrow)
        {
            if (_projectDetailOpen)
            {
                _projectDetailOpen = false;
                return true;
            }
            _focus = FocusZone.Navigation;
            return true;
        }

        var items = GetFilteredProjects();
        if (items.Count == 0)
            return false;

        switch (key.Key)
        {
            case ConsoleKey.UpArrow or ConsoleKey.K:
                _projectIndex = Math.Max(0, _projectIndex - 1);
                return true;
            case ConsoleKey.DownArrow or ConsoleKey.J:
                _projectIndex = Math.Min(items.Count - 1, _projectIndex + 1);
                return true;
            case ConsoleKey.PageUp:
                _projectIndex = Math.Max(0, _projectIndex - 10);
                return true;
            case ConsoleKey.PageDown:
                _projectIndex = Math.Min(items.Count - 1, _projectIndex + 10);
                return true;
            case ConsoleKey.Home:
                _projectIndex = 0;
                return true;
            case ConsoleKey.End:
                _projectIndex = items.Count - 1;
                return true;
            case ConsoleKey.Enter:
                ProjectSummary sel = items[Math.Clamp(_projectIndex, 0, items.Count - 1)];
                if (DesignTheme.GetBreakpoint(_backend.WindowWidth) == LayoutBreakpoint.Narrow)
                    _projectDetailOpen = true;
                BeginInspectProjectRuntime(sel, ct);
                return true;
            default:
                if (key.KeyChar is 'o' or 'O')
                {
                    ProjectSummary p = items[Math.Clamp(_projectIndex, 0, items.Count - 1)];
                    OpenPalette($"context --project {p.Id} --json");
                    return true;
                }
                return false;
        }
    }

    private void BeginInspectProjectRuntime(ProjectSummary project, CancellationToken ct)
    {
        if (!project.Accessible)
        {
            _statusMessage = $"Skipped inspect: '{project.Id}' directory missing";
            return;
        }
        _inspectingProjectId = project.Id;
        _statusMessage = $"Inspecting {project.Id}...";
        _activeProjectInspectTask = Task.Run(async () =>
        {
            try
            {
                var res = await _dispatcher.Ulvo.InspectProjectAsync(project.FullPath, includeEnvStatus: true, ct).ConfigureAwait(false);
                lock (_projectInspectCache)
                    _projectInspectCache[project.Id] = res;
                MarkSettled(ref _inspectSettledUntilTs);
                _statusMessage = $"Inspected {project.Id} ({res.Status})";
            }
            catch (Exception ex)
            {
                _statusMessage = $"Inspect error: {ex.Message}";
            }
        }, CancellationToken.None);
    }

    private bool HandleEnvironmentsKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        if (key.KeyChar == '/' && !(DesignTheme.GetBreakpoint(_backend.WindowWidth) == LayoutBreakpoint.Narrow && _envDetailOpen))
        {
            _focus = FocusZone.Search;
            return true;
        }

        if (key.Key == ConsoleKey.Escape)
        {
            if (_envDetailOpen)
            {
                _envDetailOpen = false;
                return true;
            }
            if (!string.IsNullOrEmpty(_envFilter))
            {
                SetActiveFilter(string.Empty);
                return true;
            }
            SwitchScreen(TuiScreen.Home);
            return true;
        }

        if (key.Key == ConsoleKey.LeftArrow)
        {
            if (_envDetailOpen)
            {
                _envDetailOpen = false;
                return true;
            }
            _focus = FocusZone.Navigation;
            return true;
        }

        var items = GetFilteredRuntimes();
        if (items.Count == 0)
            return false;

        switch (key.Key)
        {
            case ConsoleKey.UpArrow or ConsoleKey.K:
                _envIndex = Math.Max(0, _envIndex - 1);
                return true;
            case ConsoleKey.DownArrow or ConsoleKey.J:
                _envIndex = Math.Min(items.Count - 1, _envIndex + 1);
                return true;
            case ConsoleKey.PageUp:
                _envIndex = Math.Max(0, _envIndex - 10);
                return true;
            case ConsoleKey.PageDown:
                _envIndex = Math.Min(items.Count - 1, _envIndex + 10);
                return true;
            case ConsoleKey.Home:
                _envIndex = 0;
                return true;
            case ConsoleKey.End:
                _envIndex = items.Count - 1;
                return true;
            case ConsoleKey.Enter:
                UlvoListedProject sel = items[Math.Clamp(_envIndex, 0, items.Count - 1)];
                if (DesignTheme.GetBreakpoint(_backend.WindowWidth) == LayoutBreakpoint.Narrow)
                    _envDetailOpen = true;
                BeginInspectEnvironmentRuntime(sel, ct);
                return true;
            default:
                return false;
        }
    }

    private void BeginInspectEnvironmentRuntime(UlvoListedProject item, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(item.CanonicalPath) || !Directory.Exists(item.CanonicalPath))
        {
            _statusMessage = $"Skipped probe: '{item.Name}' path missing";
            return;
        }
        _inspectingEnvPath = item.CanonicalPath;
        _statusMessage = $"Probing {item.Name}...";
        _activeEnvInspectTask = Task.Run(async () =>
        {
            try
            {
                var res = await _dispatcher.Ulvo.InspectProjectAsync(item.CanonicalPath, includeEnvStatus: true, ct).ConfigureAwait(false);
                lock (_envInspectCache)
                    _envInspectCache[item.CanonicalPath] = res;
                MarkSettled(ref _inspectSettledUntilTs);
                _statusMessage = $"Probed {item.Name} ({res.EnvStatus?.State ?? res.Status.ToString()})";
            }
            catch (Exception ex)
            {
                _statusMessage = $"Probe error: {ex.Message}";
            }
        }, CancellationToken.None);
    }

    private bool HandlePaletteKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        if (key.Key == ConsoleKey.Escape)
        {
            _screen = _returnScreen == TuiScreen.Palette ? TuiScreen.Home : _returnScreen;
            _focus = FocusZone.Main;
            return true;
        }

        // Ctrl+J toggles Raw JSON view cleanly without stealing literal 'j' typing in the search box.
        if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.J)
        {
            _paletteShowRawJson = !_paletteShowRawJson;
            _paletteResultScroll = 0;
            return true;
        }

        var suggestions = GetSuggestions();

        if (key.Key == ConsoleKey.UpArrow || ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.P))
        {
            if (suggestions.Count > 0)
                _paletteSuggestionIndex = Math.Max(0, _paletteSuggestionIndex - 1);
            return true;
        }

        if (key.Key == ConsoleKey.DownArrow || ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.N))
        {
            if (suggestions.Count > 0)
                _paletteSuggestionIndex = Math.Min(suggestions.Count - 1, _paletteSuggestionIndex + 1);
            return true;
        }

        if (key.Key == ConsoleKey.PageUp && _paletteOutcome is not null)
        {
            _paletteResultScroll = Math.Max(0, _paletteResultScroll - Math.Max(3, _lastPaletteResultPageHeight - 2));
            return true;
        }

        if (key.Key == ConsoleKey.PageDown && _paletteOutcome is not null)
        {
            _paletteResultScroll += Math.Max(3, _lastPaletteResultPageHeight - 2);
            return true;
        }

        if (key.Key == ConsoleKey.Tab)
        {
            if (suggestions.Count > 0)
            {
                int idx = Math.Clamp(_paletteSuggestionIndex, 0, suggestions.Count - 1);
                _paletteQuery = suggestions[idx].Command;
            }
            return true;
        }

        if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.U)
        {
            _paletteQuery = string.Empty;
            _paletteSuggestionIndex = 0;
            _paletteSuggestionScroll = 0;
            return true;
        }

        if (key.Key == ConsoleKey.Backspace)
        {
            if (_paletteQuery.Length > 0)
            {
                _paletteQuery = _paletteQuery[..^1];
                _paletteSuggestionIndex = 0;
                _paletteSuggestionScroll = 0;
                return true;
            }
            return false;
        }

        if (key.Key == ConsoleKey.Enter)
        {
            (string cmd, _) = ResolvePaletteExecutionTarget(suggestions);
            BeginDispatchPaletteCommand(cmd, ct);
            return true;
        }

        if (!char.IsControl(key.KeyChar))
        {
            _paletteQuery += key.KeyChar;
            _paletteSuggestionIndex = 0;
            _paletteSuggestionScroll = 0;
            return true;
        }

        return false;
    }

    private (string Command, bool UsesExactInput) ResolvePaletteExecutionTarget(IReadOnlyList<SuggestionItem> suggestions)
    {
        string trimmed = _paletteQuery.Trim();
        string headWord = trimmed.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? string.Empty;
        bool isDirectCmd = headWord is "capabilities" or "context" or "projects" or "runtimes" or "health" or "suggest"
            || headWord.Contains('.', StringComparison.Ordinal);

        if (string.IsNullOrWhiteSpace(trimmed))
        {
            string fallback = suggestions.Count > 0
                ? suggestions[Math.Clamp(_paletteSuggestionIndex, 0, suggestions.Count - 1)].Command
                : "capabilities --json";
            return (fallback, false);
        }

        if (isDirectCmd || suggestions.Count == 0)
            return (trimmed, true);

        return (suggestions[Math.Clamp(_paletteSuggestionIndex, 0, suggestions.Count - 1)].Command, false);
    }

    private void BeginDispatchPaletteCommand(string rawCmd, CancellationToken ct)
    {
        if (_paletteRunning)
            return;

        _paletteRunning = true;
        _paletteExecutedCommand = rawCmd;
        _paletteResultScroll = 0;
        CapabilityInvocationRequest req = ParsePaletteCommand(rawCmd);
        _activePaletteTask = Task.Run(async () =>
        {
            try
            {
                _paletteOutcome = await _dispatcher.DispatchAsync(req, ct).ConfigureAwait(false);
                _statusMessage = _paletteOutcome.Envelope.Ok
                    ? $"Ran {req.CapabilityId} ({_paletteOutcome.Envelope.DurationMs}ms)"
                    : $"Command error: {_paletteOutcome.Envelope.Error?.Code ?? "FAILED"}";
            }
            catch (Exception ex)
            {
                _statusMessage = $"Palette error: {ex.Message}";
            }
        }, CancellationToken.None);
    }

    private CapabilityInvocationRequest ParsePaletteCommand(string rawCmd)
    {
        string[] parts = rawCmd.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        string head = parts.Length > 0 ? parts[0].ToLowerInvariant() : "capabilities";
        string? projectId = null;
        string? category = null;
        string? tag = null;
        string? query = null;
        bool detailed = false;
        bool includeEnv = false;

        for (int i = 1; i < parts.Length; i++)
        {
            switch (parts[i])
            {
                case "--project" when i + 1 < parts.Length:
                    projectId = parts[++i];
                    break;
                case "--category" when i + 1 < parts.Length:
                    category = parts[++i];
                    break;
                case "--tag" when i + 1 < parts.Length:
                    tag = parts[++i];
                    break;
                case "--query" when i + 1 < parts.Length:
                    query = parts[++i];
                    break;
                case "--detailed":
                    detailed = true;
                    break;
                case "--include-env-status":
                    includeEnv = true;
                    break;
            }
        }

        string capId = head switch
        {
            "capabilities" => "workctl.capabilities",
            "context" => "workctl.context",
            "projects" => "wsctl.projects",
            "runtimes" => "ulvo.runtimes",
            "health" => "workctl.health",
            "suggest" => "workctl.suggest",
            _ => head
        };

        ProjectSummary? active = GetSelectedProject() ?? ResolveCwdProject();
        return new CapabilityInvocationRequest(
            CapabilityId: capId,
            ProjectId: projectId,
            Category: category,
            Tag: tag,
            Query: query ?? (capId == "workctl.suggest" && parts.Length == 1 ? string.Empty : null),
            CurrentScreen: _returnScreen.ToString(),
            ActiveProject: active,
            Detailed: detailed,
            IncludeEnvStatus: includeEnv,
            IncludeProjects: true);
    }

    private List<ProjectSummary> GetFilteredProjects()
    {
        WsctlProjectsResult? ws = _wsctlProjects;
        if (ws is null || ws.Projects.Count == 0)
            return [];

        if (string.IsNullOrWhiteSpace(_projectFilter))
            return ws.Projects.ToList();

        string q = _projectFilter.Trim();
        return ws.Projects
            .Where(p => p.Name.Contains(q, StringComparison.OrdinalIgnoreCase)
                     || p.Id.Contains(q, StringComparison.OrdinalIgnoreCase)
                     || p.Category.Contains(q, StringComparison.OrdinalIgnoreCase)
                     || p.Environment.Contains(q, StringComparison.OrdinalIgnoreCase))
            .ToList();
    }

    private List<UlvoListedProject> GetFilteredRuntimes()
    {
        UlvoRuntimesPayload? ur = _ulvoRuntimes;
        if (ur is null || ur.Projects.Count == 0)
            return [];

        if (string.IsNullOrWhiteSpace(_envFilter))
            return ur.Projects.ToList();

        string q = _envFilter.Trim();
        return ur.Projects
            .Where(p => p.Name.Contains(q, StringComparison.OrdinalIgnoreCase)
                     || p.Id.Contains(q, StringComparison.OrdinalIgnoreCase)
                     || p.Ecosystem.Contains(q, StringComparison.OrdinalIgnoreCase)
                     || p.Classification.Contains(q, StringComparison.OrdinalIgnoreCase)
                     || p.CanonicalPath.Contains(q, StringComparison.OrdinalIgnoreCase))
            .ToList();
    }

    private ProjectSummary? GetSelectedProject()
    {
        var list = GetFilteredProjects();
        if (list.Count == 0)
            return null;
        return list[Math.Clamp(_projectIndex, 0, list.Count - 1)];
    }

    private ProjectSummary? ResolveCwdProject()
    {
        WsctlProjectsResult? ws = _wsctlProjects;
        if (ws is null)
            return null;
        string cwd = (_session?.ActiveDirectory ?? Environment.CurrentDirectory).TrimEnd('\\');
        return ws.Projects.FirstOrDefault(p =>
            cwd.Equals(p.FullPath.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)
            || cwd.StartsWith(p.FullPath.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))
            ?? _session?.ActiveProject;
    }

    private IReadOnlyList<SuggestionItem> GetSuggestions()
    {
        WsctlHealthSnapshot? wh = _wsctlHealth;
        WsctlProjectsResult? ws = _wsctlProjects;
        UlvoStatusSummary? us = _ulvoStatus;
        bool wsAvail = wh?.InfoStatus == ProviderStatus.Available || (ws?.Status == ProviderStatus.Available);
        bool ulvoAvail = us?.Status == ProviderStatus.Available;
        ProjectSummary? activeCtx = _returnScreen == TuiScreen.Projects
            ? (GetSelectedProject() ?? ResolveCwdProject())
            : ResolveCwdProject();
        var ctx = new SuggestionContext(
            _returnScreen.ToString(),
            activeCtx,
            wsAvail,
            ulvoAvail);

        var caps = _capabilities;
        if (caps.Count == 0)
        {
            caps = _dispatcher.Registry.DescribeAll(_dispatcher.Config);
            _capabilities = caps;
        }

        return _dispatcher.Suggestions.Suggest(_paletteQuery, caps, ctx, limit: 12);
    }

    private sealed record HomeQuickItem(
        bool IsWorkflow,
        string Title,
        string Subtitle,
        string? Command,
        string? ProjectId,
        bool Available,
        bool Attention);

    private List<HomeQuickItem> GetHomeItems()
    {
        int w = Math.Max(40, _backend.WindowWidth);
        int h = Math.Max(10, _backend.WindowHeight);
        LayoutBreakpoint bp = DesignTheme.GetBreakpoint(w);
        int bodyH = Math.Max(4, h - 4);
        int mainW = bp == LayoutBreakpoint.Narrow ? w : Math.Max(20, w - (bp == LayoutBreakpoint.Wide ? 24 : 22) - 3);
        return GetHomeItemsForLayout(mainW, bodyH, bp);
    }

    private List<HomeQuickItem> GetHomeItemsForLayout(int mainW, int bodyH, LayoutBreakpoint bp)
    {
        (int wfMax, int projMax) = ComputeHomeLowerCapacities(mainW, bodyH, bp);
        var list = new List<HomeQuickItem>();
        var workflows = GetHomeWorkflowSuggestions().Take(wfMax).ToList();
        foreach (SuggestionItem s in workflows)
        {
            list.Add(new HomeQuickItem(
                IsWorkflow: true,
                Title: ShortPaletteCommand(s.Command),
                Subtitle: s.Reason,
                Command: s.Command,
                ProjectId: null,
                Available: s.Available,
                Attention: false));
        }

        WsctlProjectsResult? ws = _wsctlProjects;
        if (projMax > 0 && ws is { Status: ProviderStatus.Available, Projects.Count: > 0 })
        {
            var ordered = ws.Projects
                .OrderBy(p => p.Accessible ? 1 : 0)
                .Take(projMax);
            foreach (ProjectSummary p in ordered)
            {
                string envLabel = p.Accessible ? _theme.FormatEnvTag(p.Environment) : "missing dir";
                string sub = p.Accessible ? $"{p.Category} {_theme.MiddleDot} {envLabel}" : "missing dir";
                list.Add(new HomeQuickItem(
                    IsWorkflow: false,
                    Title: p.Name,
                    Subtitle: sub,
                    Command: null,
                    ProjectId: p.Id,
                    Available: p.Accessible,
                    Attention: !p.Accessible));
            }
        }

        return list;
    }

    private (int WfMax, int ProjMax) ComputeHomeLowerCapacities(int mainW, int bodyH, LayoutBreakpoint bp)
    {
        int remain;
        bool dual;
        if (bp == LayoutBreakpoint.Wide && mainW >= 78 && bodyH >= 18)
        {
            int leftW = (mainW - 3) / 2;
            int rightW = Math.Max(20, mainW - leftW - 3);
            int sysCount = BuildSystemCluster(leftW, compactDisks: false, barW: 10).Count;
            int wsCount = BuildWorkspaceCluster(rightW, includeTools: true).Count;
            remain = Math.Max(0, bodyH - Math.Max(sysCount, wsCount) - 1);
            dual = mainW >= 78 && remain >= 5;
        }
        else
        {
            bool tight = bodyH <= 16;
            int barW = bp == LayoutBreakpoint.Narrow ? 6 : 10;
            int sysCount = BuildSystemCluster(mainW, compactDisks: tight || bp == LayoutBreakpoint.Narrow, barW: barW).Count;
            int wsCount = BuildWorkspaceCluster(mainW, includeTools: bodyH >= 21).Count;
            int used = sysCount + wsCount + (sysCount + wsCount + 2 <= bodyH ? 1 : 0);
            int rawRemain = Math.Max(0, bodyH - used);
            remain = rawRemain >= 3 ? rawRemain - 1 : 0;
            dual = false;
        }

        int errLines = 0;
        WsctlProjectsResult? ws = _wsctlProjects;
        UlvoStatusSummary? us = _ulvoStatus;
        int errCount = (ws is not null && ws.Status != ProviderStatus.Available && ws.Error is not null ? 1 : 0)
                     + (us is not null && us.Status != ProviderStatus.Available && us.Error is not null ? 1 : 0);
        if (errCount > 0 && remain >= 3)
            errLines = Math.Min(remain, 1 + errCount + 1);

        int usable = Math.Max(0, remain - errLines);
        if (usable <= 1)
            return (0, 0);

        if (dual)
        {
            int wfMax = Math.Min(6, Math.Max(1, usable - 1));
            int projMax = Math.Max(0, usable - 2);
            return (wfMax, projMax);
        }

        int wfSlots = Math.Min(6, Math.Max(1, usable >= 7 ? 3 : usable - 1));
        int leftAfter = usable - (1 + wfSlots);
        int projSlots = leftAfter >= 3 ? Math.Max(0, leftAfter - 1) : 0;
        return (wfSlots, projSlots);
    }

    private List<SuggestionItem> GetHomeWorkflowSuggestions()
    {
        WsctlProjectsResult? ws = _wsctlProjects;
        WsctlHealthSnapshot? wh = _wsctlHealth;
        UlvoStatusSummary? us = _ulvoStatus;
        bool wsAvail = wh?.InfoStatus == ProviderStatus.Available || (ws?.Status == ProviderStatus.Available);
        bool ulvoAvail = us?.Status == ProviderStatus.Available;
        var ctx = new SuggestionContext("Home", ResolveCwdProject(), wsAvail, ulvoAvail);
        var caps = _capabilities;
        if (caps.Count == 0)
            caps = _dispatcher.Registry.DescribeAll(_dispatcher.Config);

        return _dispatcher.Suggestions.Suggest(string.Empty, caps, ctx, limit: 12)
            .Where(s => s.CapabilityId != "windows.machine")
            .DistinctBy(s => s.Command, StringComparer.OrdinalIgnoreCase)
            .Take(6)
            .ToList();
    }

    private static string ShortPaletteCommand(string cmd)
    {
        string s = cmd.EndsWith(" --json", StringComparison.OrdinalIgnoreCase)
            ? cmd[..^" --json".Length]
            : cmd;
        if (s == "suggest --query <text>") return "suggest";
        if (s == "context --project <id>") return "context <id>";
        return s;
    }
}

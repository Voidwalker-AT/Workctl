using System.Diagnostics;
using WorkCtlNext.Core;

namespace WorkCtlNext.Terminal;

public sealed partial class TuiApp
{
    private async Task<(bool ExitRequested, bool Dirty)> HandlePhase2KeyAsync(ConsoleKeyInfo key, CancellationToken ct)
    {
        // 1. Ctrl+C arbitrage: copy ONLY inside Files browser MainPane (outside modals/text inputs); exit cleanly everywhere else.
        if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.C)
        {
            if (_modal is null
                && _screen != TuiScreen.Help
                && _focus != FocusZone.Search
                && _session.Focus == FocusRegion.MainPane
                && WorkspaceSessionContext.IsFilesSection(_session.CurrentSection)
                && !_fsDetailOpen)
            {
                CopySelectionToClipboard(cut: false);
                return (false, true);
            }

            return (true, false);
        }

        // 2. Modal dialog owns all keyboard events while active.
        if (_modal is not null)
        {
            bool modalDirty = await HandleModalKeyAsync(key, ct).ConfigureAwait(false);
            return (false, modalDirty);
        }

        bool exitRequested = false;
        bool dirty = HandlePhase2NonModalKey(key, ref exitRequested, ct);
        return (exitRequested, dirty);
    }

    private bool HandlePhase2NonModalKey(ConsoleKeyInfo key, ref bool exitRequested, CancellationToken ct)
    {
        // 3. Help overlay key handling.
        if (_screen == TuiScreen.Help)
            return HandleHelpKeyPhase2(key, ref exitRequested, ct);

        // 4. Ctrl+Q exits cleanly from any region.
        if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.Q)
        {
            exitRequested = true;
            return false;
        }

        // 5. Global navigation focus shortcuts (Ctrl+L / Ctrl+K -> Command Editor; Ctrl+N -> Navigation; Ctrl+Tab / F6 -> Cycle Regions)
        if ((key.Modifiers & ConsoleModifiers.Control) != 0 && (key.Key == ConsoleKey.L || key.Key == ConsoleKey.K))
        {
            FocusCommandLine('>', initialText: null);
            return true;
        }

        if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.N)
        {
            FocusNavigationRegion();
            return true;
        }

        if (key.Key == ConsoleKey.F6 || (key.Key == ConsoleKey.Tab && (key.Modifiers & ConsoleModifiers.Control) != 0))
        {
            CycleFocusRegion((key.Modifiers & ConsoleModifiers.Shift) != 0);
            return true;
        }

        // 6. Filter / Search bar captures printable input strictly
        if (_focus == FocusZone.Search)
            return HandleFilterSearchKey(key);

        // 7. Command Editor owns all ordinary typing, Tab completion, Up/Down history/suggestions, PgUp/PgDn transcript, Esc
        if (_session.Focus == FocusRegion.CommandLine)
            return HandleCommandLineKey(key, ct);

        // 8. Quit key outside text inputs
        if (key.KeyChar is 'q' or 'Q')
        {
            exitRequested = true;
            return false;
        }

        // 9. Tree collapse/drawer toggle ('[' or Ctrl+B) outside Command Editor
        if (key.KeyChar == '[' || ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.B))
        {
            ToggleTreeOrOpenPicker();
            return true;
        }

        // 10. Tab outside Command Editor cycles back toward Command Editor or Navigation
        if (key.Key == ConsoleKey.Tab)
        {
            CycleFocusRegion((key.Modifiers & ConsoleModifiers.Shift) != 0);
            return true;
        }

        // 10. Command drawer toggle / dismiss
        if (key.KeyChar == ':')
        {
            FocusCommandLine(':');
            return true;
        }

        if (_commandDrawerOpen && key.Key == ConsoleKey.Escape)
        {
            _commandDrawerOpen = false;
            return true;
        }

        if (_commandDrawerOpen && ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.J || key.Key == ConsoleKey.F4))
        {
            _paletteShowRawJson = !_paletteShowRawJson;
            _commandDrawerScroll = 0;
            return true;
        }

        // 11. Alt+Left / Alt+Right session history navigation
        if ((key.Modifiers & ConsoleModifiers.Alt) != 0 && key.Key == ConsoleKey.LeftArrow)
        {
            if (_session.TryGoBack())
            {
                SyncTreeCursorToCurrentSection();
                SyncCompatibilityAliasesFromSession();
                RefreshActiveSectionTelemetry(ct);
                SyncControlCHandling();
                return true;
            }
            return false;
        }

        if ((key.Modifiers & ConsoleModifiers.Alt) != 0 && key.Key == ConsoleKey.RightArrow)
        {
            if (_session.TryGoForward())
            {
                SyncTreeCursorToCurrentSection();
                SyncCompatibilityAliasesFromSession();
                RefreshActiveSectionTelemetry(ct);
                SyncControlCHandling();
                return true;
            }
            return false;
        }

        // 12. Global quick keys (preserved & expanded cleanly)
        if (HandlePhase2GlobalShortcut(key, ct))
            return true;

        // 13. Navigation Tree vs Main Workspace dispatch
        if (_session.Focus == FocusRegion.NavigationTree)
            return HandleTreeNavigationKey(key, ct);

        return HandleMainSectionKey(key, ct);
    }

    private bool HandlePhase2GlobalShortcut(ConsoleKeyInfo key, CancellationToken ct)
    {
        switch (key.KeyChar)
        {
            case '1':
                NavigateToSection(NavigationSectionId.MachineOverview, ct, focusMain: true);
                return true;
            case '2':
                NavigateToSection(NavigationSectionId.DevProjects, ct, focusMain: true);
                return true;
            case '3':
                NavigateToSection(NavigationSectionId.DevUlvo, ct, focusMain: true);
                return true;
            case '?':
                _returnScreen = _screen == TuiScreen.Help ? TuiScreen.Home : _screen;
                _screen = TuiScreen.Help;
                _helpScroll = 0;
                SyncControlCHandling();
                return true;
            case 'r' or 'R':
                BeginBackgroundRefresh(ct);
                RefreshActiveSectionTelemetry(ct);
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

    private bool HandleHelpKeyPhase2(ConsoleKeyInfo key, ref bool exitRequested, CancellationToken ct)
    {
        if (key.Key is ConsoleKey.Q || key.KeyChar is 'q' or 'Q')
        {
            exitRequested = true;
            return false;
        }

        if (key.Key is ConsoleKey.Escape or ConsoleKey.Enter || key.KeyChar == '?')
        {
            _screen = _returnScreen == TuiScreen.Help ? TuiScreen.Home : _returnScreen;
            SyncCompatibilityAliasesFromSession();
            _helpScroll = 0;
            SyncControlCHandling();
            return true;
        }

        if (key.KeyChar is 'm' or 'M' or 'r' or 'R' or '1' or '2' or '3' or ':')
        {
            if (key.KeyChar == ':')
            {
                _screen = _returnScreen == TuiScreen.Help ? TuiScreen.Home : _returnScreen;
                FocusCommandLine(':');
                return true;
            }
            if (HandlePhase2GlobalShortcut(key, ct))
            {
                if (key.KeyChar is '1' or '2' or '3')
                    _screen = _screen == TuiScreen.Help ? TuiScreen.Home : _screen;
                return true;
            }
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

        return false;
    }

    private void FocusNavigationRegion()
    {
        LayoutBreakpoint bp = DesignTheme.GetBreakpoint(_backend.WindowWidth);
        _completionDropdownOpen = false;
        if (bp == LayoutBreakpoint.Narrow)
        {
            _treePickerIndex = 0;
            _modal = new ActiveModalState
            {
                Kind = ModalKind.NarrowTreePicker,
                Title = "Select Section"
            };
        }
        else
        {
            _session.TreeCollapsed = false;
            _session.Focus = FocusRegion.NavigationTree;
            SyncTreeCursorToCurrentSection();
        }
        SyncCompatibilityAliasesFromSession();
        SyncControlCHandling();
    }

    private void ToggleTreeOrOpenPicker()
    {
        LayoutBreakpoint bp = DesignTheme.GetBreakpoint(_backend.WindowWidth);
        if (bp == LayoutBreakpoint.Narrow)
        {
            _treePickerIndex = 0;
            _modal = new ActiveModalState
            {
                Kind = ModalKind.NarrowTreePicker,
                Title = "Select Section"
            };
        }
        else
        {
            _session.TreeCollapsed = !_session.TreeCollapsed;
            if (_session.TreeCollapsed && _session.Focus == FocusRegion.NavigationTree)
                _session.Focus = FocusRegion.MainPane;
        }
        SyncCompatibilityAliasesFromSession();
        SyncControlCHandling();
    }

    private void CycleFocusRegion(bool reverse)
    {
        bool navVisible = DesignTheme.GetBreakpoint(_backend.WindowWidth) != LayoutBreakpoint.Narrow && !_session.TreeCollapsed;
        _session.Focus = reverse switch
        {
            true => _session.Focus switch
            {
                FocusRegion.CommandLine => FocusRegion.MainPane,
                FocusRegion.MainPane => navVisible ? FocusRegion.NavigationTree : FocusRegion.CommandLine,
                FocusRegion.NavigationTree => FocusRegion.CommandLine,
                _ => FocusRegion.CommandLine
            },
            false => _session.Focus switch
            {
                FocusRegion.CommandLine => navVisible ? FocusRegion.NavigationTree : FocusRegion.MainPane,
                FocusRegion.NavigationTree => FocusRegion.MainPane,
                FocusRegion.MainPane => FocusRegion.CommandLine,
                _ => FocusRegion.CommandLine
            }
        };

        if (_session.Focus == FocusRegion.CommandLine)
            FocusCommandLine('>', initialText: null);
        else
        {
            _completionDropdownOpen = false;
            if (_session.Focus == FocusRegion.NavigationTree)
                SyncTreeCursorToCurrentSection();
            SyncCompatibilityAliasesFromSession();
            SyncControlCHandling();
        }
    }

    private bool HandleTreeNavigationKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        var rows = BuildVisibleTreeRows();
        if (rows.Count == 0)
            return false;

        _treeCursorIndex = Math.Clamp(_treeCursorIndex, 0, rows.Count - 1);
        TreeDisplayRow current = rows[_treeCursorIndex];

        if (key.Key == ConsoleKey.Escape)
        {
            FocusCommandLine('>', initialText: null);
            return true;
        }

        switch (key.Key)
        {
            case ConsoleKey.UpArrow or ConsoleKey.K:
                for (int next = _treeCursorIndex - 1; next >= 0; next--)
                {
                    if (rows[next].IsGroupHeader || (rows[next].Node is { IsEnabled: true }))
                    {
                        _treeCursorIndex = next;
                        return true;
                    }
                }
                return false;

            case ConsoleKey.DownArrow or ConsoleKey.J:
                for (int next = _treeCursorIndex + 1; next < rows.Count; next++)
                {
                    if (rows[next].IsGroupHeader || (rows[next].Node is { IsEnabled: true }))
                    {
                        _treeCursorIndex = next;
                        return true;
                    }
                }
                return false;

            case ConsoleKey.Home:
                _treeCursorIndex = 0;
                return true;

            case ConsoleKey.End:
                for (int next = rows.Count - 1; next >= 0; next--)
                {
                    if (rows[next].IsGroupHeader || (rows[next].Node is { IsEnabled: true }))
                    {
                        _treeCursorIndex = next;
                        return true;
                    }
                }
                return true;

            case ConsoleKey.LeftArrow:
                if (current.IsGroupHeader)
                {
                    _session.SetGroupExpanded(current.Category, false);
                }
                else
                {
                    _session.SetGroupExpanded(current.Category, false);
                    rows = BuildVisibleTreeRows();
                    int gIdx = rows.FindIndex(r => r.IsGroupHeader && string.Equals(r.Category, current.Category, StringComparison.OrdinalIgnoreCase));
                    if (gIdx >= 0) _treeCursorIndex = gIdx;
                }
                return true;

            case ConsoleKey.RightArrow or ConsoleKey.L:
                if (current.IsGroupHeader)
                {
                    _session.SetGroupExpanded(current.Category, true);
                }
                else if (current.Node is { IsEnabled: true } enabledNode)
                {
                    NavigateToSection(enabledNode.Id, ct, focusMain: true);
                }
                return true;

            case ConsoleKey.Spacebar:
                _session.ToggleGroupExpanded(current.Category);
                rows = BuildVisibleTreeRows();
                _treeCursorIndex = Math.Clamp(_treeCursorIndex, 0, Math.Max(0, rows.Count - 1));
                return true;

            case ConsoleKey.Enter:
                if (current.IsGroupHeader)
                {
                    _session.ToggleGroupExpanded(current.Category);
                    rows = BuildVisibleTreeRows();
                    _treeCursorIndex = Math.Clamp(_treeCursorIndex, 0, Math.Max(0, rows.Count - 1));
                }
                else if (current.Node is { IsEnabled: true } chosenNode)
                {
                    NavigateToSection(chosenNode.Id, ct, focusMain: true);
                }
                return true;
        }

        if (key.KeyChar == '/')
        {
            if (_session.CurrentSection is NavigationSectionId.DevProjects or NavigationSectionId.DevUlvo or NavigationSectionId.MachineProcesses ||
                WorkspaceSessionContext.IsFilesSection(_session.CurrentSection))
            {
                _session.Focus = FocusRegion.MainPane;
                _focus = FocusZone.Search;
                SyncControlCHandling();
                return true;
            }
        }

        return false;
    }

    private bool HandleMainSectionKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        if (WorkspaceSessionContext.IsFilesSection(_session.CurrentSection))
        {
            if (HandleFilesBrowserKey(key, ct))
                return true;
            if (key.Key == ConsoleKey.Escape)
            {
                FocusCommandLine('>', initialText: null);
                return true;
            }
            return false;
        }

        bool handled = _session.CurrentSection switch
        {
            NavigationSectionId.DevProjects => HandleProjectsKeyPhase2(key, ct),
            NavigationSectionId.DevUlvo => HandleEnvironmentsKey(key, ct),
            NavigationSectionId.MachineOverview => HandleOverviewKey(key, ct),
            NavigationSectionId.MachineProcesses => HandleTasksManagerKey(key, ct),
            NavigationSectionId.MachineStorage => HandleStorageKey(key, ct),
            NavigationSectionId.MachineNetwork => HandleSimpleListKey(key, ref _networkIndex, _network?.Interfaces.Count ?? 0, ct),
            NavigationSectionId.AppsRunning => HandleSimpleListKey(key, ref _appsIndex, _runningApps?.Apps.Count ?? 0, ct),
            NavigationSectionId.DevToolchains => HandleSimpleListKey(key, ref _toolsIndex, _tools.Count, ct),
            NavigationSectionId.DevGit => HandleGitKey(key, ct),
            _ => false
        };

        if (!handled && key.Key == ConsoleKey.Escape)
        {
            FocusCommandLine('>', initialText: null);
            return true;
        }

        return handled;
    }

    private bool HandleTasksManagerKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        if (key.Key == ConsoleKey.LeftArrow && !_session.TreeCollapsed && DesignTheme.GetBreakpoint(_backend.WindowWidth) != LayoutBreakpoint.Narrow)
        {
            _session.Focus = FocusRegion.NavigationTree;
            SyncCompatibilityAliasesFromSession();
            SyncControlCHandling();
            return true;
        }

        if (key.Key == ConsoleKey.Escape)
        {
            if (_processDetailOpen)
            {
                _processDetailOpen = false;
                return true;
            }
            if (!string.IsNullOrEmpty(_processFilter))
            {
                _processFilter = string.Empty;
                RefreshProcessManagerSnapshot();
                return true;
            }
            FocusCommandLine('>', initialText: null);
            return true;
        }

        if (key.KeyChar == '/')
        {
            _focus = FocusZone.Search;
            SyncControlCHandling();
            return true;
        }

        if (key.KeyChar is 's' or 'S' || key.Key == ConsoleKey.F3)
        {
            _processSort = _processSort switch
            {
                ProcessSortField.Cpu => ProcessSortField.Memory,
                ProcessSortField.Memory => ProcessSortField.Pid,
                ProcessSortField.Pid => ProcessSortField.Name,
                ProcessSortField.Name => ProcessSortField.Tree,
                _ => ProcessSortField.Cpu
            };
            _processTreeMode = _processSort == ProcessSortField.Tree;
            RefreshProcessManagerSnapshot();
            return true;
        }

        if (key.KeyChar is 't' or 'T')
        {
            _processTreeMode = !_processTreeMode;
            if (_processTreeMode && _processSort != ProcessSortField.Tree)
                _processSort = ProcessSortField.Tree;
            else if (!_processTreeMode && _processSort == ProcessSortField.Tree)
                _processSort = ProcessSortField.Cpu;
            RefreshProcessManagerSnapshot();
            return true;
        }

        if (key.Key == ConsoleKey.F5)
        {
            RefreshProcessManagerSnapshot();
            return true;
        }

        List<ProcessTreeRow> rows = GetDisplayedProcessRows();
        if (rows.Count == 0)
            return false;

        _processIndex = Math.Clamp(_processIndex, 0, rows.Count - 1);

        if (key.Key == ConsoleKey.Enter || key.KeyChar is 'i' or 'I')
        {
            _processDetailOpen = !_processDetailOpen;
            if (_processDetailOpen)
            {
                ProcessEntrySnapshot target = rows[_processIndex].Process;
                _selectedProcessIdentity = new ProcessIdentityToken(target.Pid, target.CreationTimeUtcTicks, target.Name, target.ExecutablePath);
                _selectedProcessDetail = _dispatcher.Telemetry.InspectProcess(target.Pid, _processList?.AllProcesses ?? _processList?.TopProcesses);
            }
            return true;
        }

        if (key.KeyChar is 'k' or 'K' || key.Key == ConsoleKey.Delete)
        {
            ProcessEntrySnapshot target = rows[_processIndex].Process;
            OpenKillProcessModal(target.Pid, target.CreationTimeUtcTicks, target.Name, target.ExecutablePath);
            return true;
        }

        int prevIdx = _processIndex;
        bool moved = HandleSimpleListKey(key, ref _processIndex, rows.Count, ct);
        if (moved && _processIndex != prevIdx)
        {
            ProcessEntrySnapshot sel = rows[Math.Clamp(_processIndex, 0, rows.Count - 1)].Process;
            _selectedProcessIdentity = new ProcessIdentityToken(sel.Pid, sel.CreationTimeUtcTicks, sel.Name, sel.ExecutablePath);
            if (_processDetailOpen)
                _selectedProcessDetail = _dispatcher.Telemetry.InspectProcess(sel.Pid, _processList?.AllProcesses ?? _processList?.TopProcesses);
        }
        return moved;
    }

    private bool HandleOverviewKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        if (key.Key == ConsoleKey.LeftArrow && !_session.TreeCollapsed && DesignTheme.GetBreakpoint(_backend.WindowWidth) != LayoutBreakpoint.Narrow)
        {
            _session.Focus = FocusRegion.NavigationTree;
            SyncCompatibilityAliasesFromSession();
            SyncControlCHandling();
            return true;
        }

        if (key.KeyChar == '/')
        {
            NavigateToSection(NavigationSectionId.DevProjects, ct);
            _focus = FocusZone.Search;
            return true;
        }

        if (key.KeyChar is 'f' or 'F')
        {
            NavigateToSection(NavigationSectionId.FilesWorkspace, ct);
            return true;
        }

        if (key.KeyChar is 'g' or 'G')
        {
            NavigateToSection(NavigationSectionId.DevGit, ct);
            return true;
        }

        return false;
    }

    private bool HandleProjectsKeyPhase2(ConsoleKeyInfo key, CancellationToken ct)
    {
        // Offer quick jump from selected project straight into its folder in Files Browser!
        if (key.KeyChar is 'o' or 'O')
        {
            ProjectSummary? sel = GetSelectedProject();
            if (sel is not null && sel.Accessible && Directory.Exists(sel.FullPath))
            {
                _session.SetActiveProject(sel);
                _session.SetActiveDirectory(sel.FullPath);
                NavigateToSection(NavigationSectionId.FilesWorkspace, ct);
                return true;
            }
        }

        bool handled = HandleProjectsKey(key, ct);
        if (handled && _focus == FocusZone.Navigation)
        {
            _session.Focus = FocusRegion.NavigationTree;
            SyncControlCHandling();
        }
        return handled;
    }

    private bool HandleStorageKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        int count = _storage?.Volumes.Count ?? 0;
        if (HandleSimpleListKey(key, ref _storageIndex, count, ct))
            return true;

        if (key.Key == ConsoleKey.Enter && _storage is not null && count > 0)
        {
            VolumeSnapshot vol = _storage.Volumes[Math.Clamp(_storageIndex, 0, count - 1)];
            if (vol.IsReady)
            {
                _session.SetActiveDirectory(vol.Name);
                NavigateToSection(NavigationSectionId.FilesWorkspace, ct);
                RefreshFilesView(resetScroll: true);
                return true;
            }
        }
        return false;
    }

    private bool HandleGitKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        int count = _gitStatus?.ChangedFiles.Count ?? 0;
        if (HandleSimpleListKey(key, ref _gitIndex, count, ct))
            return true;

        if (key.Key == ConsoleKey.Enter && _gitStatus is { IsGitRepository: true, RepoRoot: not null } && count > 0)
        {
            GitChangedFile f = _gitStatus.ChangedFiles[Math.Clamp(_gitIndex, 0, count - 1)];
            string full = Path.Combine(_gitStatus.RepoRoot, f.Path);
            if (File.Exists(full))
            {
                Task t = ExecuteCommandLineAsync($"preview \"{full}\"", ct);
                _activePaletteTask = t;
                return true;
            }
        }
        return false;
    }

    private bool HandleSimpleListKey(ConsoleKeyInfo key, ref int idx, int count, CancellationToken ct)
    {
        if (key.Key == ConsoleKey.LeftArrow && !_session.TreeCollapsed && DesignTheme.GetBreakpoint(_backend.WindowWidth) != LayoutBreakpoint.Narrow)
        {
            _session.Focus = FocusRegion.NavigationTree;
            SyncCompatibilityAliasesFromSession();
            SyncControlCHandling();
            return true;
        }
        if (count == 0) return false;

        switch (key.Key)
        {
            case ConsoleKey.UpArrow or ConsoleKey.K:
                idx = Math.Max(0, idx - 1);
                return true;
            case ConsoleKey.DownArrow or ConsoleKey.J:
                idx = Math.Min(count - 1, idx + 1);
                return true;
            case ConsoleKey.Home:
                idx = 0;
                return true;
            case ConsoleKey.End:
                idx = count - 1;
                return true;
            case ConsoleKey.PageUp:
                idx = Math.Max(0, idx - 10);
                return true;
            case ConsoleKey.PageDown:
                idx = Math.Min(count - 1, idx + 10);
                return true;
        }
        return false;
    }

    private bool HandleFilesBrowserKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        if (_fsDetailOpen)
        {
            if (key.Key is ConsoleKey.Escape or ConsoleKey.Backspace or ConsoleKey.LeftArrow)
            {
                _fsDetailOpen = false;
                SyncControlCHandling();
                return true;
            }
            return false;
        }

        if (key.KeyChar == '/')
        {
            _focus = FocusZone.Search;
            SyncControlCHandling();
            return true;
        }

        if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.X)
        {
            CopySelectionToClipboard(cut: true);
            return true;
        }

        if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.V)
        {
            OpenPasteConfirmationModal();
            return true;
        }

        if (key.Key == ConsoleKey.F2)
        {
            OpenRenameModal();
            return true;
        }

        if (key.Key == ConsoleKey.F7)
        {
            OpenMkdirModal();
            return true;
        }

        if (key.Key == ConsoleKey.Delete)
        {
            OpenDeleteConfirmationModal();
            return true;
        }

        if (key.Key == ConsoleKey.Backspace)
        {
            string? parent = _fsListing?.ParentPath;
            if (!string.IsNullOrWhiteSpace(parent))
            {
                _fsFilter = string.Empty;
                _session.SetActiveDirectory(parent);
                RefreshFilesView(resetScroll: true);
                return true;
            }
            return false;
        }

        if (key.Key == ConsoleKey.LeftArrow)
        {
            if (!_session.TreeCollapsed && DesignTheme.GetBreakpoint(_backend.WindowWidth) != LayoutBreakpoint.Narrow)
            {
                _session.Focus = FocusRegion.NavigationTree;
                SyncCompatibilityAliasesFromSession();
                SyncControlCHandling();
                return true;
            }
            return false;
        }

        if (key.Key == ConsoleKey.Escape && !string.IsNullOrEmpty(_fsFilter))
        {
            _fsFilter = string.Empty;
            RefreshFilesView(resetScroll: true);
            return true;
        }

        List<FsEntry> entries = GetFilteredFileEntries();
        if (entries.Count == 0)
            return false;

        int idx = Math.Clamp(_session.GetSelectionIndex(_session.CurrentSection), 0, entries.Count - 1);

        switch (key.Key)
        {
            case ConsoleKey.UpArrow or ConsoleKey.K:
                idx = Math.Max(0, idx - 1);
                _session.SetSelectionIndex(_session.CurrentSection, idx);
                _session.SelectedFileEntry = entries[idx];
                RefreshSelectedFileInspection(entries[idx]);
                return true;

            case ConsoleKey.DownArrow or ConsoleKey.J:
                idx = Math.Min(entries.Count - 1, idx + 1);
                _session.SetSelectionIndex(_session.CurrentSection, idx);
                _session.SelectedFileEntry = entries[idx];
                RefreshSelectedFileInspection(entries[idx]);
                return true;

            case ConsoleKey.Home:
                _session.SetSelectionIndex(_session.CurrentSection, 0);
                _session.SelectedFileEntry = entries[0];
                RefreshSelectedFileInspection(entries[0]);
                return true;

            case ConsoleKey.End:
                idx = entries.Count - 1;
                _session.SetSelectionIndex(_session.CurrentSection, idx);
                _session.SelectedFileEntry = entries[idx];
                RefreshSelectedFileInspection(entries[idx]);
                return true;

            case ConsoleKey.PageUp:
                idx = Math.Max(0, idx - 12);
                _session.SetSelectionIndex(_session.CurrentSection, idx);
                _session.SelectedFileEntry = entries[idx];
                RefreshSelectedFileInspection(entries[idx]);
                return true;

            case ConsoleKey.PageDown:
                idx = Math.Min(entries.Count - 1, idx + 12);
                _session.SetSelectionIndex(_session.CurrentSection, idx);
                _session.SelectedFileEntry = entries[idx];
                RefreshSelectedFileInspection(entries[idx]);
                return true;

            case ConsoleKey.Spacebar:
                FsEntry markTarget = entries[idx];
                if (markTarget.Kind is not FsEntryKind.Drive and not FsEntryKind.QuickLink)
                {
                    _session.ToggleMultiSelect(markTarget.FullPath);
                    if (idx < entries.Count - 1)
                    {
                        idx++;
                        _session.SetSelectionIndex(_session.CurrentSection, idx);
                        _session.SelectedFileEntry = entries[idx];
                        RefreshSelectedFileInspection(entries[idx]);
                    }
                    return true;
                }
                return false;

            case ConsoleKey.Enter:
                FsEntry cur = entries[idx];
                if (cur.IsDirectory)
                {
                    _fsFilter = string.Empty;
                    _session.SetActiveDirectory(cur.FullPath);
                    RefreshFilesView(resetScroll: true);
                    return true;
                }
                RefreshSelectedFileInspection(cur);
                _fsDetailOpen = true;
                SyncControlCHandling();
                return true;
        }

        return false;
    }

    private bool HandleCommandLineKey(ConsoleKeyInfo key, CancellationToken ct)
    {
        if (key.Key == ConsoleKey.Escape)
        {
            _completionDropdownOpen = false;
            _commandDrawerOpen = false;
            _historyBrowsing = false;
            _commandPromptChar = '>';
            return true;
        }

        if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.J || key.Key == ConsoleKey.F4)
        {
            _paletteShowRawJson = !_paletteShowRawJson;
            _commandDrawerScroll = 0;
            return true;
        }

        if (key.Key == ConsoleKey.PageUp)
        {
            if (_commandDrawerOpen)
                _commandDrawerScroll = Math.Max(0, _commandDrawerScroll - Math.Max(3, _lastDrawerPageHeight - 2));
            else if (_session.CurrentSection == NavigationSectionId.MachineOverview)
                _session.TranscriptScroll = Math.Max(0, _session.TranscriptScroll - 6);
            return true;
        }

        if (key.Key == ConsoleKey.PageDown)
        {
            if (_commandDrawerOpen)
                _commandDrawerScroll += Math.Max(3, _lastDrawerPageHeight - 2);
            else if (_session.CurrentSection == NavigationSectionId.MachineOverview)
                _session.TranscriptScroll += 6;
            return true;
        }

        if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.U)
        {
            _session.CommandInput = string.Empty;
            _session.CommandCursorIndex = 0;
            _historyBrowsing = false;
            UpdateCompletionSuggestions();
            return true;
        }

        if (key.Key == ConsoleKey.Tab)
        {
            bool shift = (key.Modifiers & ConsoleModifiers.Shift) != 0;
            if (_completion is null || _completion.Items.Count == 0)
                UpdateCompletionSuggestions();

            if (_completion is { Items.Count: > 0 })
            {
                if (shift)
                {
                    _completionIndex = _completionIndex <= 0 ? _completion.Items.Count - 1 : _completionIndex - 1;
                    _completionDropdownOpen = true;
                    AcceptCompletionSelection();
                    return true;
                }

                string prev = _session.CommandInput;
                AcceptCompletionSelection();
                if (string.Equals(prev, _session.CommandInput, StringComparison.Ordinal) && _completion is { Items.Count: > 1 })
                {
                    _completionIndex = (_completionIndex + 1) % _completion.Items.Count;
                    AcceptCompletionSelection();
                }
                _completionDropdownOpen = true;
                _historyBrowsing = false;
                return true;
            }

            _completionDropdownOpen = !_completionDropdownOpen;
            return true;
        }

        if (key.Key == ConsoleKey.UpArrow || ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.P))
        {
            if (_completionDropdownOpen && _completion is { Items.Count: > 0 } && !string.IsNullOrEmpty(_session.CommandInput) && !_historyBrowsing)
            {
                _completionIndex = Math.Max(0, _completionIndex - 1);
                return true;
            }

            string? hist = _session.RecallPreviousCommand();
            if (hist is not null)
            {
                _historyBrowsing = true;
                _completionDropdownOpen = false;
                _session.CommandInput = hist;
                _session.CommandCursorIndex = hist.Length;
                UpdateCompletionSuggestions();
            }
            return true;
        }

        if (key.Key == ConsoleKey.DownArrow)
        {
            if (_completionDropdownOpen && _completion is { Items.Count: > 0 } && !string.IsNullOrEmpty(_session.CommandInput) && !_historyBrowsing)
            {
                _completionIndex = Math.Min(_completion.Items.Count - 1, _completionIndex + 1);
                return true;
            }

            string? nextHist = _session.RecallNextCommand();
            if (nextHist is not null)
            {
                _historyBrowsing = !string.IsNullOrEmpty(nextHist);
                _completionDropdownOpen = false;
                _session.CommandInput = nextHist;
                _session.CommandCursorIndex = nextHist.Length;
                UpdateCompletionSuggestions();
            }
            return true;
        }

        if (key.Key == ConsoleKey.LeftArrow)
        {
            _session.CommandCursorIndex = Math.Max(0, _session.CommandCursorIndex - 1);
            UpdateCompletionSuggestions();
            return true;
        }

        if (key.Key == ConsoleKey.RightArrow)
        {
            if (_session.CommandCursorIndex >= _session.CommandInput.Length
                && !string.IsNullOrEmpty(_completion?.InlineGhostSuffix))
            {
                _session.CommandInput += _completion.InlineGhostSuffix;
                _session.CommandCursorIndex = _session.CommandInput.Length;
                _historyBrowsing = false;
                UpdateCompletionSuggestions();
                return true;
            }
            _session.CommandCursorIndex = Math.Min(_session.CommandInput.Length, _session.CommandCursorIndex + 1);
            UpdateCompletionSuggestions();
            return true;
        }

        if (key.Key == ConsoleKey.Home)
        {
            _session.CommandCursorIndex = 0;
            return true;
        }

        if (key.Key == ConsoleKey.End)
        {
            _session.CommandCursorIndex = _session.CommandInput.Length;
            return true;
        }

        if (key.Key == ConsoleKey.Backspace)
        {
            if (_session.CommandCursorIndex > 0 && _session.CommandInput.Length > 0)
            {
                int pos = _session.CommandCursorIndex - 1;
                _session.CommandInput = _session.CommandInput.Remove(pos, 1);
                _session.CommandCursorIndex = pos;
                _historyBrowsing = false;
                _completionDropdownOpen = !string.IsNullOrEmpty(_session.CommandInput);
                UpdateCompletionSuggestions();
                return true;
            }
            return false;
        }

        if (key.Key == ConsoleKey.Delete)
        {
            if (_session.CommandCursorIndex < _session.CommandInput.Length)
            {
                _session.CommandInput = _session.CommandInput.Remove(_session.CommandCursorIndex, 1);
                _historyBrowsing = false;
                UpdateCompletionSuggestions();
                return true;
            }
            return false;
        }

        if (key.Key == ConsoleKey.Enter)
        {
            string cmd = _session.CommandInput.Trim();
            if (string.IsNullOrEmpty(cmd) && _commandPromptChar == ':' && _completion is { Items.Count: > 0 })
            {
                int idx = Math.Clamp(_completionIndex, 0, _completion.Items.Count - 1);
                cmd = _completion.Items[idx].InsertText;
                if (cmd == "help")
                {
                    CompletionCandidate? healthItem = _completion.Items.FirstOrDefault(i => i.InsertText == "health");
                    if (healthItem is not null) cmd = "health";
                }
            }

            if (string.IsNullOrEmpty(cmd))
                return true;

            _completionDropdownOpen = false;
            _historyBrowsing = false;
            _session.CommandInput = string.Empty;
            _session.CommandCursorIndex = 0;
            _completion = null;

            if (string.Equals(cmd, "exit", StringComparison.OrdinalIgnoreCase) || string.Equals(cmd, "quit", StringComparison.OrdinalIgnoreCase))
            {
                _commandExitRequested = true;
                return true;
            }

            _paletteRunning = true;
            _activePaletteTask = RunCommandHotStartAsync(cmd, ct);
            return true;
        }

        if (!char.IsControl(key.KeyChar) && (key.Modifiers & (ConsoleModifiers.Control | ConsoleModifiers.Alt)) == 0)
        {
            int pos = Math.Clamp(_session.CommandCursorIndex, 0, _session.CommandInput.Length);
            _session.CommandInput = _session.CommandInput.Insert(pos, key.KeyChar.ToString());
            _session.CommandCursorIndex = pos + 1;
            _historyBrowsing = false;
            _completionDropdownOpen = true;
            _completionIndex = 0;
            UpdateCompletionSuggestions();
            return true;
        }

        return false;
    }

    private bool HandleFilterSearchKey(ConsoleKeyInfo key)
    {
        if (_session.CurrentSection == NavigationSectionId.MachineProcesses)
        {
            if (key.Key == ConsoleKey.Escape)
            {
                _processFilter = string.Empty;
                _focus = FocusZone.Main;
                RefreshProcessManagerSnapshot();
                SyncControlCHandling();
                return true;
            }
            if (key.Key == ConsoleKey.Enter)
            {
                _focus = FocusZone.Main;
                SyncControlCHandling();
                return true;
            }
            if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.U)
            {
                _processFilter = string.Empty;
                RefreshProcessManagerSnapshot();
                return true;
            }
            if (key.Key == ConsoleKey.Backspace && _processFilter.Length > 0)
            {
                _processFilter = _processFilter[..^1];
                RefreshProcessManagerSnapshot();
                return true;
            }
            if (!char.IsControl(key.KeyChar) && (key.Modifiers & (ConsoleModifiers.Control | ConsoleModifiers.Alt)) == 0)
            {
                _processFilter += key.KeyChar;
                RefreshProcessManagerSnapshot();
                return true;
            }
            return false;
        }

        if (WorkspaceSessionContext.IsFilesSection(_session.CurrentSection))
        {
            if (key.Key == ConsoleKey.Escape)
            {
                _fsFilter = string.Empty;
                _focus = FocusZone.Main;
                RefreshFilesView(resetScroll: true);
                SyncControlCHandling();
                return true;
            }
            if (key.Key == ConsoleKey.Enter)
            {
                _focus = FocusZone.Main;
                SyncControlCHandling();
                return true;
            }
            if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.U)
            {
                _fsFilter = string.Empty;
                RefreshFilesView(resetScroll: true);
                return true;
            }
            if (key.Key == ConsoleKey.Backspace && _fsFilter.Length > 0)
            {
                _fsFilter = _fsFilter[..^1];
                RefreshFilesView(resetScroll: true);
                return true;
            }
            if (!char.IsControl(key.KeyChar) && (key.Modifiers & (ConsoleModifiers.Control | ConsoleModifiers.Alt)) == 0)
            {
                _fsFilter += key.KeyChar;
                RefreshFilesView(resetScroll: true);
                return true;
            }
            return false;
        }

        bool res = HandleSearchKey(key);
        if (res) SyncControlCHandling();
        return res;
    }

    private async Task<bool> HandleModalKeyAsync(ConsoleKeyInfo key, CancellationToken ct)
    {
        ActiveModalState m = _modal!;
        if (m.Kind == ModalKind.NarrowTreePicker)
        {
            var nodes = WorkspaceSessionContext.AllNavigationNodes.Where(n => n.IsEnabled).ToList();
            if (nodes.Count == 0)
                return false;
            switch (key.Key)
            {
                case ConsoleKey.Escape:
                    _modal = null;
                    SyncControlCHandling();
                    return true;
                case ConsoleKey.UpArrow or ConsoleKey.K:
                    _treePickerIndex = Math.Max(0, _treePickerIndex - 1);
                    return true;
                case ConsoleKey.DownArrow or ConsoleKey.J:
                    _treePickerIndex = Math.Min(nodes.Count - 1, _treePickerIndex + 1);
                    return true;
                case ConsoleKey.Enter:
                    NavigationNodeDescriptor chosen = nodes[Math.Clamp(_treePickerIndex, 0, nodes.Count - 1)];
                    _modal = null;
                    NavigateToSection(chosen.Id, ct, focusMain: true);
                    return true;
            }
            return false;
        }

        if (m.Kind == ModalKind.ConfirmTerminateStep1 && m.ProcessImpact is { } imp1)
        {
            if (key.Key == ConsoleKey.Escape || key.KeyChar is 'n' or 'N')
            {
                _modal = null;
                SyncControlCHandling();
                return true;
            }
            if (!imp1.ProcessExists || imp1.PidReused || !imp1.CanTerminate)
            {
                if (key.Key is ConsoleKey.Enter or ConsoleKey.Spacebar)
                {
                    _modal = null;
                    SyncControlCHandling();
                    return true;
                }
                return false;
            }
            if (imp1.SupportsGracefulClose && key.KeyChar is 'g' or 'G')
            {
                await ExecuteGracefulTerminateFromModalAsync(ct).ConfigureAwait(false);
                return true;
            }
            if (key.Key == ConsoleKey.Enter || key.KeyChar is 'f' or 'F')
            {
                TransitionKillModalToForceStep2(imp1);
                return true;
            }
            return false;
        }

        if (m.Kind == ModalKind.ProtectedBlocked)
        {
            if (key.Key is ConsoleKey.Enter or ConsoleKey.Escape or ConsoleKey.Spacebar)
            {
                _modal = null;
                SyncControlCHandling();
                return true;
            }
            return false;
        }

        if (key.Key == ConsoleKey.Escape || (m.Kind is ModalKind.ConfirmDelete or ModalKind.ConfirmPaste && key.KeyChar is 'n' or 'N'))
        {
            _modal = null;
            SyncControlCHandling();
            return true;
        }

        if (m.Kind is ModalKind.PromptMkdir or ModalKind.PromptRename or ModalKind.ConfirmTerminateForceStep2)
        {
            if (key.Key == ConsoleKey.Enter)
            {
                await ConfirmActiveModalAsync(ct).ConfigureAwait(false);
                return true;
            }
            if (key.Key == ConsoleKey.LeftArrow)
            {
                m.InputCursor = Math.Max(0, m.InputCursor - 1);
                return true;
            }
            if (key.Key == ConsoleKey.RightArrow)
            {
                m.InputCursor = Math.Min(m.InputValue.Length, m.InputCursor + 1);
                return true;
            }
            if (key.Key == ConsoleKey.Home)
            {
                m.InputCursor = 0;
                return true;
            }
            if (key.Key == ConsoleKey.End)
            {
                m.InputCursor = m.InputValue.Length;
                return true;
            }
            if ((key.Modifiers & ConsoleModifiers.Control) != 0 && key.Key == ConsoleKey.U)
            {
                m.InputValue = string.Empty;
                m.InputCursor = 0;
                m.ErrorHint = null;
                return true;
            }
            if (key.Key == ConsoleKey.Backspace && m.InputCursor > 0 && m.InputValue.Length > 0)
            {
                int pos = m.InputCursor - 1;
                m.InputValue = m.InputValue.Remove(pos, 1);
                m.InputCursor = pos;
                m.ErrorHint = null;
                return true;
            }
            if (!char.IsControl(key.KeyChar) && (key.Modifiers & (ConsoleModifiers.Control | ConsoleModifiers.Alt)) == 0)
            {
                int pos = Math.Clamp(m.InputCursor, 0, m.InputValue.Length);
                m.InputValue = m.InputValue.Insert(pos, key.KeyChar.ToString());
                m.InputCursor = pos + 1;
                m.ErrorHint = null;
                return true;
            }
            return false;
        }

        if (m.Kind is ModalKind.ConfirmDelete or ModalKind.ConfirmPaste)
        {
            if (key.Key == ConsoleKey.Enter || key.KeyChar is 'y' or 'Y')
            {
                await ConfirmActiveModalAsync(ct).ConfigureAwait(false);
                return true;
            }
        }

        return false;
    }

    private async Task RunCommandHotStartAsync(string cmd, CancellationToken ct)
    {
        try
        {
            await ExecuteCommandLineAsync(cmd, ct).ConfigureAwait(false);
        }
        finally
        {
            _paletteRunning = false;
            SyncControlCHandling();
        }
    }
}

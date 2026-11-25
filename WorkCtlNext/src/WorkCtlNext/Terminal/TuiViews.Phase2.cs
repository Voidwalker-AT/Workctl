using System.Text.Json;
using WorkCtlNext.Core;

namespace WorkCtlNext.Terminal;

public sealed partial class TuiApp
{
    private List<string> BuildHierarchicalSidebar(int w, int h)
    {
        var allRows = BuildVisibleTreeRows();
        bool navFocused = _session.Focus == FocusRegion.NavigationTree;

        string headerLeft = _theme.Style(navFocused ? _theme.Bold + _theme.Accent : _theme.MutedText,
            navFocused ? " NAVIGATION [Ctrl+N]" : " NAVIGATION");
        string headerRight = _theme.Style(_theme.MutedText, "[ ");
        var outRows = new List<string>(h)
        {
            LayoutEngine.AlignLeftRight(headerLeft, headerRight, w)
        };

        int projCount = _wsctlProjects?.Projects.Count ?? 0;
        int envCount = _ulvoRuntimes?.Projects.Count ?? 0;
        int procCount = _processList?.TotalProcessCount ?? _machine?.ProcessCount ?? 0;
        int listH = Math.Max(1, h - 2);

        if (_treeCursorIndex < _treeScroll)
            _treeScroll = _treeCursorIndex;
        if (_treeCursorIndex >= _treeScroll + listH)
            _treeScroll = _treeCursorIndex - listH + 1;
        _treeScroll = Math.Clamp(_treeScroll, 0, Math.Max(0, allRows.Count - listH));

        int maxLabelWidth = Math.Max(10, w - 4);

        for (int i = 0; i < listH; i++)
        {
            int idx = _treeScroll + i;
            if (idx >= allRows.Count)
            {
                outRows.Add(string.Empty);
                continue;
            }

            TreeDisplayRow row = allRows[idx];
            bool isCursor = idx == _treeCursorIndex && navFocused;
            string scrollChar = LayoutEngine.ScrollbarGlyph(_theme, i, listH, allRows.Count, _treeScroll);
            string rendered;

            if (row.IsGroupHeader)
            {
                bool exp = _session.IsGroupExpanded(row.Category);
                string glyph = exp ? _theme.TreeExpanded : _theme.TreeCollapsed;
                string txt = $" {_theme.Style(isCursor ? _theme.Accent : _theme.Secondary, glyph)} {_theme.Style(_theme.Bold + (isCursor ? _theme.Primary : _theme.Secondary), row.Category.ToUpperInvariant())}";
                rendered = isCursor ? PaintRowBg(txt, w - 1, true) : txt;
            }
            else
            {
                NavigationNodeDescriptor node = row.Node!;
                bool activeSection = _session.CurrentSection == node.Id;
                string labelText = node.Id switch
                {
                    NavigationSectionId.MachineOverview => "[1] Console",
                    NavigationSectionId.MachineProcesses => procCount > 0 ? $"Tasks ({procCount})" : "Tasks",
                    NavigationSectionId.DevProjects => projCount > 0 ? $"[2] Projects ({projCount})" : "[2] Projects",
                    NavigationSectionId.DevUlvo => envCount > 0 ? $"ULVO [3] Runtimes ({envCount})" : "ULVO [3] Runtimes",
                    _ => node.Label
                };

                string ptr = (activeSection || isCursor) ? _theme.FocusPointer : " ";
                if (!node.IsEnabled)
                {
                    // Non-interactive roadmap placeholder (cannot be focused or invoked from tree)
                    string offTag = _theme.Style(_theme.MutedText, "off");
                    string leftPart = $"   {_theme.Style(_theme.MutedText, _theme.TruncateEnd(labelText, Math.Max(6, w - 9)))}";
                    rendered = LayoutEngine.AlignLeftRight(leftPart, offTag, w - 1);
                }
                else
                {
                    string ptrStyled = _theme.Style(activeSection || isCursor ? _theme.Accent : _theme.MutedText, ptr);
                    string lblColor = activeSection ? _theme.Bold + _theme.Primary : (isCursor ? _theme.Primary : _theme.Secondary);
                    string leftPart = $" {ptrStyled} {_theme.Style(lblColor, _theme.TruncateEnd(labelText, maxLabelWidth))}";
                    rendered = (activeSection || isCursor)
                        ? PaintRowBg(leftPart, w - 1, navFocused || isCursor)
                        : leftPart;
                }
            }

            string cell = DiffRenderer.PadVisible(rendered, Math.Max(4, w - 1), resetBeforeFill: false);
            outRows.Add(cell + scrollChar);
        }

        // Bottom sidebar summary line showing active focus & backstack capability
        if (outRows.Count < h)
        {
            string zoneLabel = _session.Focus switch
            {
                FocusRegion.NavigationTree => _theme.Style(_theme.Accent, "Focus: Nav"),
                FocusRegion.CommandLine => _theme.Style(_theme.Accent, "Focus: Cmd"),
                _ => _focus == FocusZone.Search
                    ? _theme.Style(_theme.Warning, "Focus: Find")
                    : _theme.Style(_theme.MutedText, "Focus: Main")
            };
            string hist = _session.CanGoBack ? _theme.Style(_theme.MutedText, "Alt+<-") : string.Empty;
            outRows.Add(LayoutEngine.AlignLeftRight(" " + zoneLabel, hist, w - 1));
        }

        while (outRows.Count < h)
            outRows.Add(string.Empty);

        return outRows;
    }

    private List<string> BuildMainSectionPane(int w, int h, LayoutBreakpoint bp)
    {
        return _session.CurrentSection switch
        {
            NavigationSectionId.MachineOverview => BuildCleanOverviewPane(w, h, bp),
            NavigationSectionId.MachineProcesses => BuildProcessesPane(w, h),
            NavigationSectionId.MachinePerformance => BuildPerformancePane(w, h),
            NavigationSectionId.MachineStorage => BuildStoragePane(w, h),
            NavigationSectionId.MachineNetwork => BuildNetworkPane(w, h),
            NavigationSectionId.MachineServices => BuildDeferredPane("Machine / Services", "windows.services", "Windows Service Control Manager inventory is not implemented in Phase 2.", w, h),

            NavigationSectionId.FilesThisPc
            or NavigationSectionId.FilesQuickAccess
            or NavigationSectionId.FilesWorkspace
            or NavigationSectionId.FilesDownloads => BuildFilesBrowserPane(w, h, bp),

            NavigationSectionId.DevProjects => BuildProjectsPane(w, h, bp),
            NavigationSectionId.DevGit => BuildGitPane(w, h),
            NavigationSectionId.DevUlvo => BuildEnvironmentsPane(w, h, bp),
            NavigationSectionId.DevToolchains => BuildToolchainsPane(w, h),

            NavigationSectionId.AppsRunning => BuildRunningAppsPane(w, h),
            NavigationSectionId.AppsInstalled => BuildDeferredPane("Applications / Installed", "apps.installed", "Windows installed package registry audit is deferred cleanly with zero fabricated rows.", w, h),
            NavigationSectionId.AppsStartup => BuildDeferredPane("Applications / Startup", "apps.startup", "Windows startup registry audit is deferred cleanly with zero fabricated rows.", w, h),

            _ => BuildCleanOverviewPane(w, h, bp)
        };
    }

    private List<string> BuildCleanOverviewPane(int w, int h, LayoutBreakpoint bp)
    {
        var lines = new List<string>(h);

        // Focused two-column cluster at wide, single vertical cluster at standard/narrow; zero workflow table congestion!
        if (bp == LayoutBreakpoint.Wide && w >= 72)
        {
            int leftW = (w - 3) / 2;
            int rightW = Math.Max(20, w - leftW - 3);
            var sysRows = BuildSystemCluster(leftW, compactDisks: false, barW: 10);
            var wsRows = BuildWorkspaceCluster(rightW, includeTools: true);
            int clusterH = Math.Max(sysRows.Count, wsRows.Count);
            lines.AddRange(LayoutEngine.ComposeColumns(sysRows, leftW, wsRows, rightW, clusterH, _theme));
        }
        else
        {
            lines.AddRange(BuildSystemCluster(w, compactDisks: bp == LayoutBreakpoint.Narrow, barW: 8));
            lines.Add(string.Empty);
            lines.AddRange(BuildWorkspaceCluster(w, includeTools: false));
        }

        if (_session.Clipboard.HasItems)
        {
            lines.Add(string.Empty);
            string clipText = $"{_session.Clipboard.Mode} {_theme.MiddleDot} {_session.Clipboard.Paths.Count} item(s) staged for Paste (Ctrl+V in Files)";
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Clipboard", _theme.Style(_theme.Warning, clipText), 10));
        }

        bool wsctlBad = _wsctlProjects is { Status: not ProviderStatus.Available };
        bool ulvoBad = _ulvoStatus is { Status: not ProviderStatus.Available };
        if (wsctlBad || ulvoBad)
        {
            lines.Add(string.Empty);
            lines.Add($" {_theme.Style(_theme.Bold + _theme.Error, "PROVIDER DIAGNOSTICS")}");
            if (wsctlBad && _wsctlProjects is { } ws)
                lines.AddRange(LayoutEngine.BuildErrorBox(_theme, $"WSCTL ({ws.Status})", ws.Error?.Message, w));
            if (ulvoBad && _ulvoStatus is { } ul)
                lines.AddRange(LayoutEngine.BuildErrorBox(_theme, $"ULVO ({ul.Status})", ul.Error?.Message, w));
        }

        int remaining = h - lines.Count;
        if (remaining >= 4)
        {
            lines.Add(_theme.Style(_theme.Border, " " + new string(_theme.RuleH[0], Math.Max(8, w - 2))));
            int consoleAvail = h - lines.Count;
            lines.AddRange(BuildShellWorkspaceSection(w, consoleAvail));
        }

        return lines.Take(h).ToList();
    }

    private List<string> BuildShellWorkspaceSection(int w, int h)
    {
        var outLines = new List<string>(h);
        if (_session.Transcript.Count == 0)
        {
            string rightCwd = DesignTheme.TruncateMiddle(_session.ActiveDirectory, Math.Max(14, w - 24));
            outLines.Add(LayoutEngine.AlignLeftRight(
                $" {_theme.Style(_theme.Bold + _theme.Accent, "WORKSTATION SHELL")}",
                _theme.Style(_theme.MutedText, $"{rightCwd} "),
                w));

            FsDirectoryListing? cur = _fsListing;
            if (cur is not null && cur.Entries.Count > 0 && outLines.Count + 2 < h)
            {
                string cwdSummary = $"{cur.DirectoryCount} folders, {cur.FileCount} files";
                outLines.Add($" {_theme.Style(_theme.Secondary, $"Directory: {cwdSummary}")}");
                int showFiles = Math.Min(cur.Entries.Count, Math.Max(0, h - outLines.Count - 4));
                for (int i = 0; i < showFiles; i++)
                {
                    FsEntry e = cur.Entries[i];
                    string kind = e.IsDirectory ? "<DIR>" : FileSystemService.FormatBytes(e.SizeBytes);
                    outLines.Add(LayoutEngine.AlignLeftRight(
                        $"   {_theme.Style(e.IsDirectory ? _theme.Primary : _theme.Secondary, _theme.TruncateEnd(e.Name, Math.Max(10, w - 18)))}",
                        _theme.Style(_theme.MutedText, kind + " "),
                        w));
                }
            }

            if (outLines.Count + 2 <= h)
            {
                outLines.Add(string.Empty);
                string md = _theme.MiddleDot;
                foreach (string hint in new[]
                {
                    "Ready for commands below: ls, cd <dir>, tasks, pwsh <cmd>, cmd <cmd>, !pwsh (foreground)",
                    $"Navigation: Tab complete {md} Ctrl+N tree {md} Ctrl+Tab/F6 region {md} Ctrl+L focus prompt"
                })
                {
                    if (outLines.Count >= h) break;
                    foreach (string wr in DesignTheme.WrapText(hint, Math.Max(18, w - 3), _theme.AsciiOnly))
                    {
                        if (outLines.Count >= h) break;
                        outLines.Add($" {_theme.Style(_theme.MutedText, wr)}");
                    }
                }
            }
            return outLines;
        }

        var rawLines = new List<string>();
        foreach (ConsoleTranscriptEntry entry in _session.Transcript)
        {
            string statusGlyph = entry.Ok ? _theme.Style(_theme.Success, _theme.IconOk) : _theme.Style(_theme.Error, $"x{entry.ExitCode}");
            string modeCol = entry.ModeTag switch
            {
                "PWSH" => _theme.Accent,
                "CMD" => _theme.Warning,
                "TTY" => _theme.Success,
                "ERR" => _theme.Error,
                _ => _theme.Secondary
            };
            string headerLeft = $" {_theme.Style(_theme.Accent, ">")} {_theme.Style(_theme.Bold + _theme.Primary, _theme.TruncateEnd(entry.CommandText, Math.Max(10, w - 26)))}";
            string headerRight = $"{_theme.Style(modeCol, $"[{entry.ModeTag}]")} {statusGlyph} {_theme.Style(_theme.MutedText, $"{entry.DurationMs}ms ")}";
            rawLines.Add(LayoutEngine.AlignLeftRight(headerLeft, headerRight, w));

            foreach (string bodyLine in entry.Lines)
            {
                foreach (string wr in DesignTheme.WrapText(bodyLine, Math.Max(18, w - 4), _theme.AsciiOnly))
                    rawLines.Add($"   {_theme.Style(_theme.Secondary, wr)}");
            }
        }

        int listH = Math.Max(1, h - 1);
        int maxScroll = Math.Max(0, rawLines.Count - listH);
        int scroll = _session.TranscriptScroll >= int.MaxValue - 100
            ? maxScroll
            : Math.Clamp(_session.TranscriptScroll, 0, maxScroll);
        _session.TranscriptScroll = scroll;

        outLines.Add(LayoutEngine.AlignLeftRight(
            $" {_theme.Style(_theme.Bold + _theme.Accent, "SHELL TRANSCRIPT")}",
            _theme.Style(_theme.MutedText, rawLines.Count > listH ? $"PgUp/PgDn scroll ({scroll + 1}-{Math.Min(rawLines.Count, scroll + listH)}/{rawLines.Count}) " : "Use 'clear' to reset "),
            w));

        for (int i = 0; i < listH && scroll + i < rawLines.Count; i++)
            outLines.Add(rawLines[scroll + i]);

        return outLines;
    }

    private List<string> BuildFilesBrowserPane(int w, int h, LayoutBreakpoint bp)
    {
        if (_fsDetailOpen && _fsListing is not null && GetHighlightedFileEntry() is { } detailEntry)
        {
            return BuildFullFileInspectorView(detailEntry, w, h);
        }

        var lines = new List<string>(h);
        FsDirectoryListing? listing = _fsListing;

        string dirTitle = listing is null
            ? _session.ActiveDirectory
            : DesignTheme.TruncateMiddle(listing.CurrentPath, Math.Max(14, w - 34));
        string countTag = listing is null
            ? ""
            : $"({listing.DirectoryCount}d {listing.FileCount}f)";

        var titleBadges = new List<string>();
        if (_session.MultiSelectedPaths.Count > 0)
            titleBadges.Add(_theme.Style(_theme.Warning, $"MARK:{_session.MultiSelectedPaths.Count}"));
        if (_session.Clipboard.HasItems)
            titleBadges.Add(_theme.Style(_theme.Accent, $"{_session.Clipboard.Mode.ToString().ToUpperInvariant()}:{_session.Clipboard.Paths.Count}"));
        if (listing?.DirectoryProtectionTier == FsProtectionTier.Blocked)
            titleBadges.Add(_theme.Style(_theme.Error, "PROTECTED"));

        string topRight = string.Join(" ", new[] { _theme.Style(_theme.MutedText, countTag) }.Concat(titleBadges).Where(s => !string.IsNullOrEmpty(s)));
        lines.Add(LayoutEngine.AlignLeftRight($" {_theme.Style(_theme.Bold + _theme.Accent, dirTitle)}", topRight + " ", w));

        if (_focus == FocusZone.Search || !string.IsNullOrEmpty(_fsFilter))
        {
            string fText = string.IsNullOrEmpty(_fsFilter) ? _theme.Style(_theme.MutedText, "type filename...") : _theme.Style(_theme.Primary, _fsFilter);
            lines.Add(LayoutEngine.PaintSurfaceRow($" Filter (/): {fText}", w, _theme, _theme.CommandBarBg));
        }

        if (listing?.AccessWarning is not null)
        {
            lines.Add($" {_theme.Style(_theme.Warning, _theme.IconWarn + " " + _theme.TruncateEnd(listing.AccessWarning, Math.Max(12, w - 5)))}");
        }

        int listAvailH = Math.Max(2, h - lines.Count);
        bool splitPreview = w >= 71 && listAvailH >= 6 && listing is not null;

        if (splitPreview)
        {
            int leftW = (int)(w * 0.58);
            int rightW = Math.Max(18, w - leftW - 3);
            var listLines = BuildFilesListRows(leftW, listAvailH);
            var inspLines = BuildFileInspectorPanel(GetHighlightedFileEntry(), rightW, listAvailH);
            lines.AddRange(LayoutEngine.ComposeColumns(listLines, leftW, inspLines, rightW, listAvailH, _theme));
        }
        else
        {
            lines.AddRange(BuildFilesListRows(w, listAvailH));
        }

        return lines;
    }

    private List<string> BuildFilesListRows(int w, int h)
    {
        List<FsEntry> entries = GetFilteredFileEntries();
        if (entries.Count == 0)
        {
            return [$"  {_theme.Style(_theme.MutedText, "(empty directory)")}"];
        }

        int selectedIdx = Math.Clamp(_session.GetSelectionIndex(_session.CurrentSection), 0, entries.Count - 1);
        if (selectedIdx < _fsScroll) _fsScroll = selectedIdx;
        if (selectedIdx >= _fsScroll + h) _fsScroll = selectedIdx - h + 1;
        _fsScroll = Math.Clamp(_fsScroll, 0, Math.Max(0, entries.Count - h));

        bool paneFocused = _session.Focus == FocusRegion.MainPane && _modal is null;
        var outRows = new List<string>(h);

        for (int i = 0; i < h; i++)
        {
            int idx = _fsScroll + i;
            if (idx >= entries.Count)
            {
                outRows.Add(string.Empty);
                continue;
            }

            FsEntry e = entries[idx];
            bool isCursor = idx == selectedIdx;
            bool isMarked = _session.MultiSelectedPaths.Contains(e.FullPath);
            string ptr = isCursor ? _theme.Style(_theme.Accent, _theme.FocusPointer) : " ";
            string mark = isMarked ? _theme.Style(_theme.Warning, "[x]") : "   ";

            (string badge, string badgeCol) = e.Kind switch
            {
                FsEntryKind.Drive => ("[DRV]", _theme.Accent),
                FsEntryKind.QuickLink => ("[LNK]", _theme.Accent),
                FsEntryKind.ReparseDirectory when e.ReparseKind == FsReparseKind.Junction => ("[JNC]", _theme.Warning),
                FsEntryKind.ReparseDirectory => ("[SYM]", _theme.Warning),
                FsEntryKind.Directory => ("[DIR]", _theme.Accent),
                FsEntryKind.ReparseFile => ("[SYM]", _theme.Warning),
                _ => ("     ", _theme.MutedText)
            };

            string extra = string.Empty;
            if (e.HardLinkCount > 1)
                extra += $" x{e.HardLinkCount}";
            if (e.ProtectionTier == FsProtectionTier.Blocked)
                extra += " LOCK";

            string rightText = e.Kind is FsEntryKind.Drive or FsEntryKind.QuickLink
                ? (e.SecondaryNote ?? string.Empty)
                : e.IsDirectory
                    ? (w >= 54 && e.LinkTarget is not null ? $"-> {DesignTheme.TruncateMiddle(e.LinkTarget, 14)}" : (e.IsReparsePoint ? "<LNK>" : "<DIR>"))
                    : FileSystemService.FormatBytes(e.SizeBytes);

            int rightBudget = Math.Min(rightText.Length, Math.Max(6, w / 3));
            string rightTrimmed = _theme.TruncateEnd(rightText, rightBudget);
            int nameBudget = Math.Max(8, w - 13 - rightTrimmed.Length - extra.Length);
            string nameTrimmed = DesignTheme.TruncateMiddle(e.Name, nameBudget);

            string nameStyled = e.IsDirectory ? _theme.Style(_theme.Primary, nameTrimmed) : _theme.Style(_theme.Secondary, nameTrimmed);
            string extraStyled = string.IsNullOrEmpty(extra) ? "" : _theme.Style(_theme.Warning, extra);
            string leftPart = $" {ptr}{mark} {_theme.Style(badgeCol, badge)} {nameStyled}{extraStyled}";
            string scrollChar = LayoutEngine.ScrollbarGlyph(_theme, i, h, entries.Count, _fsScroll);
            string rowLine = LayoutEngine.AlignLeftRight(leftPart, _theme.Style(_theme.MutedText, rightTrimmed), Math.Max(6, w - 2)) + " " + scrollChar;

            if (isCursor)
                rowLine = PaintRowBg(rowLine, w, paneFocused);

            outRows.Add(rowLine);
        }

        return outRows;
    }

    private List<string> BuildFileInspectorPanel(FsEntry? entry, int w, int h)
    {
        var lines = new List<string>(h);
        if (entry is null)
        {
            lines.Add(_theme.Style(_theme.MutedText, " No selection"));
            return lines;
        }

        lines.Add(_theme.Style(_theme.Bold + _theme.Primary, " " + _theme.TruncateEnd(entry.Name, Math.Max(8, w - 2))));

        FsMetadataSnapshot? meta = _fsSelectedMeta;
        if (meta is not null && meta.Exists)
        {
            string kindStr = meta.IsReparsePoint ? $"{meta.ReparseKind} Reparse" : (meta.IsDirectory ? "Directory" : "File");
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Type", _theme.Style(_theme.Accent, kindStr), 7));
            if (!meta.IsDirectory)
                lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Size", _theme.Style(_theme.Primary, FileSystemService.FormatBytes(meta.SizeBytes)), 7));
            if (meta.HardLinkCount > 1)
                lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Links", _theme.Style(_theme.Warning, $"{meta.HardLinkCount} NTFS hardlinks"), 7));
            if (!string.IsNullOrWhiteSpace(meta.LinkTarget))
                lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Target", _theme.Style(_theme.Secondary, DesignTheme.TruncateMiddle(meta.LinkTarget, Math.Max(8, w - 10))), 7));
            if (meta.LastWriteTime.HasValue)
                lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Mod", _theme.Style(_theme.MutedText, meta.LastWriteTime.Value.ToLocalTime().ToString("yyyy-MM-dd HH:mm")), 7));
            if (meta.ProtectionTier != FsProtectionTier.None)
                lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Policy", _theme.Style(meta.ProtectionTier == FsProtectionTier.Blocked ? _theme.Error : _theme.Warning, $"{meta.ProtectionTier}: {_theme.TruncateEnd(meta.ProtectionReason ?? "", Math.Max(8, w - 18))}"), 7));
        }
        else if (!string.IsNullOrWhiteSpace(entry.SecondaryNote))
        {
            lines.Add($" {_theme.Style(_theme.Secondary, _theme.TruncateEnd(entry.SecondaryNote, Math.Max(8, w - 2)))}");
        }

        lines.Add(_theme.Style(_theme.Border, " " + new string(_theme.RuleH[0], Math.Max(4, w - 2))));

        FsPreviewSnapshot? prev = _fsSelectedPreview;
        if (prev is null)
        {
            lines.Add($" {_theme.Style(_theme.MutedText, entry.IsDirectory ? "Press Enter to open folder" : "Press Enter to inspect")}");
        }
        else if (prev.DisabledReason is not null)
        {
            foreach (string wr in DesignTheme.WrapText(prev.DisabledReason, Math.Max(10, w - 2), _theme.AsciiOnly))
                lines.Add($" {_theme.Style(_theme.Warning, wr)}");
        }
        else
        {
            lines.Add($" {_theme.Style(_theme.MutedText, $"Preview ({prev.EncodingName}, {prev.LineCount} lines{(prev.IsTruncated ? ", truncated" : "")})")}");
            foreach (string pl in prev.Lines)
            {
                if (lines.Count >= h) break;
                lines.Add($" {_theme.Style(_theme.Secondary, _theme.TruncateEnd(pl, Math.Max(6, w - 2)))}");
            }
        }

        return lines.Take(h).ToList();
    }

    private List<string> BuildFullFileInspectorView(FsEntry entry, int w, int h)
    {
        var lines = new List<string>(h)
        {
            $" {_theme.Style(_theme.Bold + _theme.Accent, $"{_theme.BackArrow} File Inspector")} {_theme.Style(_theme.Border, _theme.MiddleDot)} {_theme.Style(_theme.Primary, _theme.TruncateEnd(entry.Name, Math.Max(10, w - 22)))}"
        };
        lines.AddRange(BuildFileInspectorPanel(entry, w, Math.Max(2, h - 1)));
        return lines.Take(h).ToList();
    }

    private List<string> BuildProcessesPane(int w, int h)
    {
        List<ProcessTreeRow> rows = GetDisplayedProcessRows();
        ProcessListSnapshot snap = _processList!;
        _processIndex = rows.Count == 0 ? 0 : Math.Clamp(_processIndex, 0, rows.Count - 1);
        if (rows.Count > 0 && _selectedProcessIdentity is null)
        {
            ProcessEntrySnapshot first = rows[_processIndex].Process;
            _selectedProcessIdentity = new ProcessIdentityToken(first.Pid, first.CreationTimeUtcTicks, first.Name, first.ExecutablePath);
        }

        if (_processDetailOpen && w < 100 && rows.Count > 0)
        {
            ProcessDetailedInspection? insp = _selectedProcessDetail ?? _dispatcher.Telemetry.InspectProcess(rows[_processIndex].Process.Pid, snap.AllProcesses ?? snap.TopProcesses);
            return BuildProcessInspectorPanel(insp, w, h, fullScreen: true);
        }

        var lines = new List<string>(h)
        {
            LayoutEngine.AlignLeftRight(
                $" {_theme.Style(_theme.Bold + _theme.Accent, "TASK MANAGER")} {_theme.Style(_theme.MutedText, $"[{(_processTreeMode ? "Tree" : $"Sort: {_processSort}")}]")}",
                _theme.Style(_theme.MutedText, $"{rows.Count}/{snap.TotalProcessCount} procs · WS {FileSystemService.FormatBytes(snap.TotalWorkingSetBytes)} "),
                w)
        };

        if (_focus == FocusZone.Search || !string.IsNullOrEmpty(_processFilter))
        {
            string fText = string.IsNullOrEmpty(_processFilter)
                ? _theme.Style(_theme.MutedText, "filter by pid, name, owner, or path...")
                : _theme.Style(_theme.Primary, _processFilter);
            lines.Add(LayoutEngine.PaintSurfaceRow($" Filter (/): {fText}", w, _theme, _theme.CommandBarBg));
        }

        int bodyH = Math.Max(2, h - lines.Count);
        bool splitDetail = _processDetailOpen && w >= 100 && bodyH >= 6 && rows.Count > 0;
        if (splitDetail)
        {
            int leftW = (int)(w * 0.56);
            int rightW = Math.Max(22, w - leftW - 3);
            var listLines = BuildTaskListRows(rows, leftW, bodyH);
            ProcessDetailedInspection? insp = _selectedProcessDetail ?? _dispatcher.Telemetry.InspectProcess(rows[_processIndex].Process.Pid, snap.AllProcesses ?? snap.TopProcesses);
            var detailLines = BuildProcessInspectorPanel(insp, rightW, bodyH, fullScreen: false);
            lines.AddRange(LayoutEngine.ComposeColumns(listLines, leftW, detailLines, rightW, bodyH, _theme));
        }
        else
        {
            lines.AddRange(BuildTaskListRows(rows, w, bodyH));
        }

        return lines.Take(h).ToList();
    }

    private List<string> BuildTaskListRows(IReadOnlyList<ProcessTreeRow> rows, int w, int h)
    {
        var outRows = new List<string>(h);
        if (w >= 80)
            outRows.Add(_theme.Style(_theme.MutedText, $" {"PID",-6} {"PPID",-6} {"PROCESS",-24} {"CPU%",6} {"MEM",9} {"THR",4} {"WINDOW / EXECUTABLE"}"));
        else
            outRows.Add(_theme.Style(_theme.MutedText, $" {"PID",-6} {"PROCESS",-18} {"CPU%",6} {"MEM",9} {"THR",4}"));

        int listH = Math.Max(1, h - 1);
        if (rows.Count == 0)
        {
            outRows.Add($"  {_theme.Style(_theme.MutedText, "(no matching processes)")}");
            return outRows;
        }

        if (_processIndex < _processScroll) _processScroll = _processIndex;
        if (_processIndex >= _processScroll + listH) _processScroll = _processIndex - listH + 1;
        _processScroll = Math.Clamp(_processScroll, 0, Math.Max(0, rows.Count - listH));

        bool focused = _session.Focus == FocusRegion.MainPane && _modal is null;
        for (int i = 0; i < listH; i++)
        {
            int idx = _processScroll + i;
            if (idx >= rows.Count) { outRows.Add(string.Empty); continue; }

            ProcessTreeRow tr = rows[idx];
            ProcessEntrySnapshot p = tr.Process;
            bool sel = idx == _processIndex;
            string prefix = _theme.AsciiOnly ? tr.TreePrefix : tr.TreePrefix.Replace("|- ", "├─ ").Replace("`- ", "└─ ").Replace("|  ", "│  ");
            string nameDisp = prefix + p.Name;
            string scrollChar = LayoutEngine.ScrollbarGlyph(_theme, i, listH, rows.Count, _processScroll);

            string row;
            if (w >= 80)
            {
                string extra = p.Pid == Environment.ProcessId ? "[WORKCTL-SELF] " : (p.HasVisibleWindow ? "[WIN] " : string.Empty);
                extra += p.WindowTitle ?? p.ExecutablePath ?? string.Empty;
                int extraW = Math.Max(6, w - 65);
                string extraDisp = extra.Length > extraW ? DesignTheme.TruncateMiddle(extra, extraW) : extra;
                row = $" {(sel ? _theme.FocusPointer : " ")}{p.Pid,-6} {p.ParentPid,-6} {_theme.TruncateEnd(nameDisp, 24),-24} {p.CpuPercentApprox,5:F1}% {FileSystemService.FormatBytes(p.WorkingSetBytes),9} {p.ThreadCount,4} {extraDisp}";
            }
            else
            {
                row = $" {(sel ? _theme.FocusPointer : " ")}{p.Pid,-6} {_theme.TruncateEnd(nameDisp, 18),-18} {p.CpuPercentApprox,5:F1}% {FileSystemService.FormatBytes(p.WorkingSetBytes),9} {p.ThreadCount,4}";
            }

            string cell = DiffRenderer.PadVisible(sel ? PaintRowBg(row, w - 1, focused) : row, Math.Max(6, w - 1), resetBeforeFill: false);
            outRows.Add(cell + scrollChar);
        }
        return outRows;
    }

    private List<string> BuildProcessInspectorPanel(ProcessDetailedInspection? insp, int w, int h, bool fullScreen)
    {
        var lines = new List<string>(h);
        if (insp is null)
        {
            lines.Add($" {_theme.Style(_theme.MutedText, "No process selected or process exited.")}");
            return lines;
        }

        ProcessEntrySnapshot p = insp.Process;
        string title = fullScreen
            ? $" {_theme.Style(_theme.Bold + _theme.Accent, $"{_theme.BackArrow} Task Inspector (Esc Back)")} {_theme.Style(_theme.Border, _theme.MiddleDot)} {_theme.Style(_theme.Primary, p.Name)}"
            : $" {_theme.Style(_theme.Bold + _theme.Accent, "PROCESS DETAIL")} {_theme.Style(_theme.MutedText, $"(PID {p.Pid})")}";
        lines.Add(title);

        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Identity", _theme.Style(_theme.Primary, $"{p.Name} (PID {p.Pid}, PPID {p.ParentPid})"), 10));
        string parentTxt = insp.VerifiedParentPid.HasValue
            ? $"{insp.VerifiedParentName} (PID {insp.VerifiedParentPid.Value})"
            : (insp.ParentExitedOrReused ? $"PID {p.ParentPid} exited/reused" : "Root / no active parent");
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Parent", _theme.Style(_theme.Secondary, _theme.TruncateEnd(parentTxt, Math.Max(10, w - 13))), 10));
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Children", _theme.Style(_theme.Secondary, insp.VerifiedChildren.Count == 0 ? "None" : $"{insp.VerifiedChildren.Count} ({string.Join(", ", insp.VerifiedChildren.Take(3).Select(c => c.Name))})"), 10));
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Owner", _theme.Style(_theme.Secondary, _theme.TruncateEnd(insp.OwnerStatus, Math.Max(10, w - 13))), 10));
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Memory", _theme.Style(_theme.Primary, $"WS {FileSystemService.FormatBytes(p.WorkingSetBytes)} · Priv {FileSystemService.FormatBytes(p.PrivateMemoryBytes)} · {p.ThreadCount} thr"), 10));

        string svcs = insp.AssociatedServices.Count > 0
            ? string.Join(", ", insp.AssociatedServices.Select(s => $"{s.ServiceName}({s.State})"))
            : "None detected";
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Services", _theme.Style(insp.AssociatedServices.Count > 0 ? _theme.Warning : _theme.MutedText, _theme.TruncateEnd(svcs, Math.Max(10, w - 13))), 10));

        string exeTxt = string.IsNullOrWhiteSpace(p.ExecutablePath) ? "[Unavailable / access denied]" : p.ExecutablePath;
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Path", _theme.Style(_theme.Secondary, DesignTheme.TruncateMiddle(exeTxt, Math.Max(10, w - 13))), 10));

        string flags = insp.IsWorkCtlSelf ? "SELF (protected)"
            : insp.IsAncestorHost ? "ANCESTOR HOST (protected)"
            : insp.IsUlvoManaged ? "ULVO MANAGED (guarded)"
            : insp.IsProtected ? "PROTECTED"
            : (insp.IsWorkCtlOwned ? "WORKCTL OWNED · Safe target" : (insp.SupportsGracefulClose ? "Windowed · Graceful/Force allowed" : "Console/Background · Force only"));
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Policy", _theme.Style(insp.IsProtected ? _theme.Error : _theme.Success, _theme.TruncateEnd(flags, Math.Max(10, w - 13))), 10));

        if (!string.IsNullOrWhiteSpace(insp.BlockReason) && lines.Count + 2 <= h)
        {
            foreach (string wr in DesignTheme.WrapText(insp.BlockReason, Math.Max(14, w - 3), _theme.AsciiOnly))
            {
                if (lines.Count >= h) break;
                lines.Add($" {_theme.Style(_theme.Warning, wr)}");
            }
        }
        else if (lines.Count < h)
        {
            lines.Add($" {_theme.Style(_theme.Accent, "Press [k] or [Del] for guarded Terminate Impact Preview")}");
        }

        return lines.Take(h).ToList();
    }

    private List<string> BuildPerformancePane(int w, int h)
    {
        var lines = new List<string>(h)
        {
            $" {_theme.Style(_theme.Bold + _theme.Accent, "SYSTEM PERFORMANCE")}"
        };

        PerformanceSnapshot? p = _performance;
        if (p is null)
        {
            lines.Add($" {_theme.Style(_theme.MutedText, "Sampling Win32 CPU and RAM counters... press r to refresh.")}");
            return lines;
        }

        int barW = Math.Clamp(w / 4, 10, 26);
        string cpuBar = _theme.BuildBar(p.CpuUtilizationPercent / 100.0, barW, _theme.ThresholdColor(p.CpuUtilizationPercent));
        string ramBar = _theme.BuildBar(p.RamUsedPercent / 100.0, barW, _theme.ThresholdColor(p.RamUsedPercent));

        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "CPU Load", $"{cpuBar} {_theme.Style(_theme.Primary, $"{p.CpuUtilizationPercent:F1}%")} ({Environment.ProcessorCount} logical cores)", 11));
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Memory", $"{ramBar} {_theme.Style(_theme.Primary, $"{p.RamUsedPercent:F1}%")} ({FileSystemService.FormatBytes(p.TotalRamBytes - p.AvailableRamBytes)} / {FileSystemService.FormatBytes(p.TotalRamBytes)})", 11));
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Available", _theme.Style(_theme.Success, FileSystemService.FormatBytes(p.AvailableRamBytes)), 11));
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Threads", _theme.Style(_theme.Primary, $"{p.ThreadCount} across {p.ProcessCount} processes"), 11));
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Uptime", _theme.Style(_theme.Secondary, $"{(int)p.Uptime.TotalDays}d {p.Uptime.Hours}h {p.Uptime.Minutes}m"), 11));
        if (!string.IsNullOrWhiteSpace(p.TopCpuProcessName))
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Peak WS", _theme.Style(_theme.Accent, $"{p.TopCpuProcessName} (PID {p.TopCpuProcessPid})"), 11));
        return lines;
    }

    private List<string> BuildStoragePane(int w, int h)
    {
        StorageSnapshot snap = _storage ?? (_storage = _dispatcher.Telemetry.GetStorageSnapshot());
        var lines = new List<string>(h)
        {
            LayoutEngine.AlignLeftRight(
                $" {_theme.Style(_theme.Bold + _theme.Accent, "STORAGE VOLUMES")}",
                _theme.Style(_theme.MutedText, $"Total Free {FileSystemService.FormatBytes(snap.TotalFreeBytes)} / {FileSystemService.FormatBytes(snap.TotalCapacityBytes)} "),
                w)
        };
        lines.Add($" {_theme.Style(_theme.MutedText, "Enter opens ready volume inside Files browser")}");
        lines.Add(string.Empty);

        int barW = Math.Clamp(w / 5, 8, 22);
        bool focused = _session.Focus == FocusRegion.MainPane && _modal is null;
        _storageIndex = snap.Volumes.Count == 0 ? 0 : Math.Clamp(_storageIndex, 0, snap.Volumes.Count - 1);

        for (int i = 0; i < snap.Volumes.Count && lines.Count < h; i++)
        {
            VolumeSnapshot v = snap.Volumes[i];
            bool sel = i == _storageIndex;
            string ptr = sel ? _theme.Style(_theme.Accent, _theme.FocusPointer) : " ";
            if (!v.IsReady)
            {
                string row = $" {ptr} {v.Name,-5} {_theme.Style(_theme.MutedText, $"{v.DriveType} · not ready")}";
                lines.Add(sel ? PaintRowBg(row, w, focused) : row);
                continue;
            }

            string bar = _theme.BuildBar(v.UsedPercent / 100.0, barW, _theme.ThresholdColor(v.UsedPercent));
            string lbl = string.IsNullOrWhiteSpace(v.Label) ? v.FileSystem : $"{v.Label} ({v.FileSystem})";
            string rowReady = $" {ptr} {_theme.Style(_theme.Primary, $"{v.Name,-5}")} {bar} {v.UsedPercent,5:F1}%  {_theme.Style(_theme.Success, FileSystemService.FormatBytes(v.FreeBytes))} free / {FileSystemService.FormatBytes(v.TotalBytes)}  {_theme.Style(_theme.MutedText, _theme.TruncateEnd(lbl, 18))}";
            lines.Add(sel ? PaintRowBg(rowReady, w, focused) : rowReady);
        }
        return lines;
    }

    private List<string> BuildNetworkPane(int w, int h)
    {
        NetworkSnapshot snap = _network ?? (_network = _dispatcher.Telemetry.GetNetworkSnapshot());
        var lines = new List<string>(h)
        {
            LayoutEngine.AlignLeftRight(
                $" {_theme.Style(_theme.Bold + _theme.Accent, "NETWORK INTERFACES")}",
                _theme.Style(_theme.MutedText, $"{snap.UpCount}/{snap.TotalCount} Up "),
                w),
            _theme.Style(_theme.MutedText, $" {"ADAPTER",-18} {"STATE",-6} {"Mbps",6} {"IPv4",-16} {"GATEWAY"}")
        };

        bool focused = _session.Focus == FocusRegion.MainPane && _modal is null;
        _networkIndex = snap.Interfaces.Count == 0 ? 0 : Math.Clamp(_networkIndex, 0, snap.Interfaces.Count - 1);
        for (int i = 0; i < snap.Interfaces.Count && lines.Count < h; i++)
        {
            NetworkInterfaceSnapshot ni = snap.Interfaces[i];
            bool sel = i == _networkIndex;
            bool up = string.Equals(ni.Status, "Up", StringComparison.OrdinalIgnoreCase);
            string row = $" {(sel ? _theme.FocusPointer : " ")}{_theme.TruncateEnd(ni.Name, 17),-17} {_theme.Style(up ? _theme.Success : _theme.MutedText, $"{ni.Status,-6}")} {ni.SpeedMbps,6} {_theme.TruncateEnd(ni.IPv4Addresses ?? "-", 16),-16} {_theme.TruncateEnd(ni.GatewayAddresses ?? "-", Math.Max(8, w - 53))}";
            lines.Add(sel ? PaintRowBg(row, w, focused) : row);
        }
        return lines;
    }

    private List<string> BuildGitPane(int w, int h)
    {
        var lines = new List<string>(h)
        {
            $" {_theme.Style(_theme.Bold + _theme.Accent, "GIT WORKSPACE STATUS")}"
        };

        GitRepositorySnapshot? g = _gitStatus;
        if (g is null)
        {
            lines.Add($" {_theme.Style(_theme.MutedText, _theme.TruncateEnd($"Checking Git status for {_session.ActiveDirectory}...", Math.Max(14, w - 3)))}");
            return lines;
        }

        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Target", _theme.Style(_theme.Primary, DesignTheme.TruncateMiddle(g.TargetPath, Math.Max(14, w - 14))), 9));
        if (!g.IsGitRepository)
        {
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Status", _theme.Style(_theme.Warning, g.ErrorMessage ?? "Not a Git repository."), 9));
            return lines;
        }

        string branchText = g.BranchName ?? "(unknown)";
        if (!string.IsNullOrWhiteSpace(g.UpstreamBranch))
            branchText += $" -> {g.UpstreamBranch} (+{g.AheadCount}/-{g.BehindCount})";
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Branch", _theme.Style(_theme.Accent, branchText), 9));
        lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Changes", _theme.Style(_theme.Primary, $"Staged {g.StagedCount} · Modified {g.ModifiedCount} · Untracked {g.UntrackedCount} · Conflicts {g.ConflictCount}"), 9));
        if (!string.IsNullOrWhiteSpace(g.LastCommitSummary))
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "HEAD", _theme.Style(_theme.Secondary, _theme.TruncateEnd(g.LastCommitSummary, Math.Max(14, w - 14))), 9));

        lines.Add(string.Empty);
        if (g.ChangedFiles.Count == 0)
        {
            lines.Add($" {_theme.Style(_theme.Success, $"{_theme.IconOk} Working tree clean")}");
            return lines;
        }

        bool focused = _session.Focus == FocusRegion.MainPane && _modal is null;
        int avail = Math.Max(1, h - lines.Count);
        _gitIndex = Math.Clamp(_gitIndex, 0, g.ChangedFiles.Count - 1);
        if (_gitIndex < _gitScroll) _gitScroll = _gitIndex;
        if (_gitIndex >= _gitScroll + avail) _gitScroll = _gitIndex - avail + 1;

        for (int i = 0; i < avail && (_gitScroll + i) < g.ChangedFiles.Count; i++)
        {
            int idx = _gitScroll + i;
            GitChangedFile f = g.ChangedFiles[idx];
            bool sel = idx == _gitIndex;
            string xy = $"{f.IndexStatus}{f.WorkTreeStatus}";
            string col = xy == "??" ? _theme.MutedText : (f.IndexStatus != " " ? _theme.Success : _theme.Warning);
            string row = $" {(sel ? _theme.FocusPointer : " ")} {_theme.Style(col, xy)}  {_theme.TruncateEnd(f.Path, Math.Max(10, w - 10))}";
            lines.Add(sel ? PaintRowBg(row, w, focused) : row);
        }
        return lines;
    }

    private List<string> BuildToolchainsPane(int w, int h)
    {
        var lines = new List<string>(h)
        {
            $" {_theme.Style(_theme.Bold + _theme.Accent, "WORKSTATION TOOLCHAINS")}"
        };

        bool focused = _session.Focus == FocusRegion.MainPane && _modal is null;
        _toolsIndex = _tools.Count == 0 ? 0 : Math.Clamp(_toolsIndex, 0, _tools.Count - 1);
        for (int i = 0; i < _tools.Count && lines.Count < h; i++)
        {
            ToolAvailability t = _tools[i];
            bool sel = i == _toolsIndex;
            string statusGlyph = t.Installed ? _theme.Style(_theme.Success, _theme.IconOk) : _theme.Style(_theme.MutedText, _theme.DotIdle);
            string pathText = t.Installed ? (t.Path ?? "on PATH") : "not found";
            string row = $" {(sel ? _theme.FocusPointer : " ")} {statusGlyph} {_theme.Style(_theme.Primary, $"{t.Name,-11}")} {_theme.Style(_theme.Secondary, DesignTheme.TruncateMiddle(pathText, Math.Max(10, w - 20)))}";
            lines.Add(sel ? PaintRowBg(row, w, focused) : row);
        }
        return lines;
    }

    private List<string> BuildRunningAppsPane(int w, int h)
    {
        RunningAppsSnapshot snap = _runningApps ?? (_runningApps = _dispatcher.Telemetry.GetRunningApps(40));
        var lines = new List<string>(h)
        {
            LayoutEngine.AlignLeftRight(
                $" {_theme.Style(_theme.Bold + _theme.Accent, "RUNNING WINDOWED APPLICATIONS")}",
                _theme.Style(_theme.MutedText, $"{snap.Apps.Count} visible windows "),
                w)
        };

        bool focused = _session.Focus == FocusRegion.MainPane && _modal is null;
        _appsIndex = snap.Apps.Count == 0 ? 0 : Math.Clamp(_appsIndex, 0, snap.Apps.Count - 1);
        for (int i = 0; i < snap.Apps.Count && lines.Count < h; i++)
        {
            RunningAppSnapshot a = snap.Apps[i];
            bool sel = i == _appsIndex;
            string row = $" {(sel ? _theme.FocusPointer : " ")} {_theme.TruncateEnd(a.ProcessName, 16),-16} {FileSystemService.FormatBytes(a.WorkingSetBytes),9}  {_theme.TruncateEnd(a.WindowTitle, Math.Max(10, w - 34))}";
            lines.Add(sel ? PaintRowBg(row, w, focused) : row);
        }
        return lines;
    }

    private List<string> BuildDeferredPane(string title, string plannedCapability, string explanation, int w, int h)
    {
        var lines = new List<string>(h)
        {
            $" {_theme.Style(_theme.Bold + _theme.MutedText, $"{title} [DEFERRED]")}",
            string.Empty,
            $" {_theme.Style(_theme.Warning, $"{_theme.IconWarn} Capability '{plannedCapability}' is disabled in Phase 2.")}"
        };
        foreach (string wrapped in DesignTheme.WrapText(explanation, Math.Max(20, w - 4), _theme.AsciiOnly))
            lines.Add($" {_theme.Style(_theme.Secondary, wrapped)}");
        lines.Add(string.Empty);
        lines.Add($" {_theme.Style(_theme.MutedText, "No synthetic or fabricated items are shown.")}");
        return lines;
    }

    private IReadOnlyList<string> BuildPersistentCommandArea(int width, LayoutBreakpoint bp, bool compact)
    {
        var rows = new List<string>(3);
        if (!compact)
        {
            rows.Add(_theme.Style(_theme.Border, new string(_theme.RuleH[0], width)));
        }

        // Input line: always shows CWD badge, prompt, visible cursor at exact insertion offset, ghost suffix, and status
        bool cmdFocused = _session.Focus == FocusRegion.CommandLine && _modal is null;
        string cwdCompact = DesignTheme.TruncateMiddle(_session.ActiveDirectory, Math.Clamp(width / 4, 10, 32));
        string cwdPill = _theme.Style(cmdFocused ? _theme.Secondary : _theme.MutedText, cwdCompact);

        string promptTok = _theme.Style(cmdFocused ? _theme.Bold + _theme.Accent : _theme.Secondary, $" {_commandPromptChar} ");
        string typed = _session.CommandInput;
        int curPos = Math.Clamp(_session.CommandCursorIndex, 0, typed.Length);
        string ghostText = cmdFocused && !string.IsNullOrEmpty(_completion?.InlineGhostSuffix)
            ? _completion.InlineGhostSuffix
            : string.Empty;

        string editableDisplay;
        if (!cmdFocused)
        {
            editableDisplay = string.IsNullOrEmpty(typed)
                ? _theme.Style(_theme.MutedText, bp == LayoutBreakpoint.Narrow ? "Ctrl+L to type commands" : "Ctrl+L or Ctrl+Tab for command prompt (ls cd tasks pwsh)")
                : _theme.Style(_theme.Primary, typed);
        }
        else if (curPos < typed.Length)
        {
            string before = _theme.Style(_theme.Primary, typed[..curPos]);
            string curChar = typed.Substring(curPos, 1);
            string curStyled = _theme.NoColor ? curChar : $"\u001b[7m{curChar}\u001b[27m";
            string after = _theme.Style(_theme.Primary, typed[(curPos + 1)..]);
            string ghostStyled = string.IsNullOrEmpty(ghostText) ? string.Empty : _theme.Style(_theme.MutedText, ghostText);
            editableDisplay = before + curStyled + after + ghostStyled;
        }
        else if (!string.IsNullOrEmpty(ghostText))
        {
            string head = _theme.Style(_theme.Primary, typed);
            string firstGhost = ghostText[..1];
            string cursorOnGhost = _theme.NoColor ? firstGhost : $"\u001b[7m{firstGhost}\u001b[27m";
            string tailGhost = ghostText.Length > 1 ? _theme.Style(_theme.MutedText, ghostText[1..]) : string.Empty;
            editableDisplay = head + cursorOnGhost + tailGhost;
        }
        else
        {
            string head = _theme.Style(_theme.Primary, typed);
            string cursorCell = _theme.NoColor ? "_" : "\u001b[7m \u001b[27m";
            string placeholder = string.IsNullOrEmpty(typed)
                ? _theme.Style(_theme.MutedText, bp == LayoutBreakpoint.Narrow
                    ? "Type cmd"
                    : $"Type command (ls, cd, tasks, pwsh, cmd, help) {_theme.MiddleDot} Tab complete")
                : string.Empty;
            editableDisplay = head + cursorCell + placeholder;
        }

        string rightStatus = string.Empty;
        if (_session.Clipboard.HasItems)
        {
            rightStatus = _theme.Style(_theme.Warning, $"[CLIP: {_session.Clipboard.Mode.ToString().ToUpperInvariant()} {_session.Clipboard.Paths.Count}] ");
        }
        else if (_session.LastCommandResult is { } res)
        {
            string col = res.Success ? _theme.Success : _theme.Error;
            string glyph = res.Success ? _theme.IconOk : _theme.IconErr;
            rightStatus = _theme.Style(col, $"{glyph} {_theme.TruncateEnd(res.Headline, Math.Clamp(width / 3, 12, 36))} ");
        }

        string inputLeft = $" {cwdPill}{promptTok}{editableDisplay}";
        string inputRow = LayoutEngine.AlignLeftRight(inputLeft, rightStatus, width);
        inputRow = LayoutEngine.PaintSurfaceRow(inputRow, width, _theme, cmdFocused ? _theme.FocusRowBg : _theme.CommandBarBg);
        rows.Add(inputRow);

        // Bottom context hint strip (row h - 1)
        string hints = BuildContextHintStrip(width, bp);
        rows.Add(hints);
        return rows;
    }

    private string BuildContextHintStrip(int width, LayoutBreakpoint bp)
    {
        if (_modal is not null)
        {
            return _modal.Kind == ModalKind.ConfirmTerminateStep1 && _modal.ProcessImpact is { CanTerminate: true } imp
                ? (imp.SupportsGracefulClose
                    ? $" {LayoutEngine.FormatKeyHint(_theme, "g", "Graceful")}  {LayoutEngine.FormatKeyHint(_theme, "f", "Force Step 2")}  {LayoutEngine.FormatKeyHint(_theme, "Esc", "Cancel")}"
                    : $" {LayoutEngine.FormatKeyHint(_theme, "Enter/f", "Step 2 Kill")}  {LayoutEngine.FormatKeyHint(_theme, "Esc", "Cancel")}")
                : $" {LayoutEngine.FormatKeyHint(_theme, "Enter", "Confirm")}  {LayoutEngine.FormatKeyHint(_theme, "Esc", "Cancel")}";
        }

        if (_focus == FocusZone.Search)
        {
            return $" {LayoutEngine.FormatKeyHint(_theme, "Enter", "Keep")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+U", "Clear")}  {LayoutEngine.FormatKeyHint(_theme, "Esc", "Cancel")}";
        }

        if (_session.Focus == FocusRegion.CommandLine)
        {
            return bp == LayoutBreakpoint.Narrow
                ? $" {LayoutEngine.FormatKeyHint(_theme, "Tab", "Complete")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+N", "Menu")}  {LayoutEngine.FormatKeyHint(_theme, "Enter", "Run")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+Q", "Quit")}"
                : $" {LayoutEngine.FormatKeyHint(_theme, "Tab", "Complete")}  {LayoutEngine.FormatKeyHint(_theme, _theme.Arrows, "Pick/Hist")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+N", "Tree")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+Tab/F6", "Region")}  {LayoutEngine.FormatKeyHint(_theme, "PgUp/Dn", "Scroll")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+Q", "Quit")}";
        }

        if (_session.CurrentSection == NavigationSectionId.MachineProcesses)
        {
            return bp == LayoutBreakpoint.Narrow
                ? $" {LayoutEngine.FormatKeyHint(_theme, "Enter", "Inspect")}  {LayoutEngine.FormatKeyHint(_theme, "s", "Sort")}  {LayoutEngine.FormatKeyHint(_theme, "k", "Kill")}  {LayoutEngine.FormatKeyHint(_theme, "Esc", "Cmd")}"
                : $" {LayoutEngine.FormatKeyHint(_theme, "Enter", "Inspect")}  {LayoutEngine.FormatKeyHint(_theme, "s", "Sort")}  {LayoutEngine.FormatKeyHint(_theme, "t", "Tree")}  {LayoutEngine.FormatKeyHint(_theme, "/", "Filter")}  {LayoutEngine.FormatKeyHint(_theme, "k/Del", "Kill")}  {LayoutEngine.FormatKeyHint(_theme, "F5", "Refresh")}  {LayoutEngine.FormatKeyHint(_theme, "Esc/Ctrl+L", "Cmd")}";
        }

        if (bp == LayoutBreakpoint.Narrow && ((_screen == TuiScreen.Projects && _projectDetailOpen) || (_screen == TuiScreen.Environments && _envDetailOpen) || _fsDetailOpen || _processDetailOpen))
        {
            return $" {LayoutEngine.FormatKeyHint(_theme, "Esc", "Back")}  {LayoutEngine.FormatKeyHint(_theme, "Enter", "Inspect")}  {LayoutEngine.FormatKeyHint(_theme, "o", "Files")}  {LayoutEngine.FormatKeyHint(_theme, "q", "Quit")}";
        }

        if (_screen == TuiScreen.Help)
        {
            return $" {LayoutEngine.FormatKeyHint(_theme, _theme.Arrows, "Scroll")}  {LayoutEngine.FormatKeyHint(_theme, "m", "Motion")}  {LayoutEngine.FormatKeyHint(_theme, "Esc", "Back")}  {LayoutEngine.FormatKeyHint(_theme, "q", "Quit")}";
        }

        if (WorkspaceSessionContext.IsFilesSection(_session.CurrentSection))
        {
            return bp == LayoutBreakpoint.Narrow
                ? $" {LayoutEngine.FormatKeyHint(_theme, "Space", "Mark")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+C/V", "Cp/Ps")}  {LayoutEngine.FormatKeyHint(_theme, "Del", "Rm")}  {LayoutEngine.FormatKeyHint(_theme, "Esc", "Cmd")}"
                : $" {LayoutEngine.FormatKeyHint(_theme, "Space", "Mark")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+C/X/V", "Cp/Cut/Ps")}  {LayoutEngine.FormatKeyHint(_theme, "F2", "Ren")}  {LayoutEngine.FormatKeyHint(_theme, "F7", "Mkdir")}  {LayoutEngine.FormatKeyHint(_theme, "Del", "Rm")}  {LayoutEngine.FormatKeyHint(_theme, "Esc", "Cmd")}";
        }

        return bp == LayoutBreakpoint.Narrow
            ? $" {LayoutEngine.FormatKeyHint(_theme, "Ctrl+N", "Menu")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+L", "Cmd")}  {LayoutEngine.FormatKeyHint(_theme, "?", "Help")}  {LayoutEngine.FormatKeyHint(_theme, "q", "Quit")}"
            : $" {LayoutEngine.FormatKeyHint(_theme, "Ctrl+N", "Tree")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+Tab/F6", "Region")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+L", "Cmd")}  {LayoutEngine.FormatKeyHint(_theme, "Esc", "Prompt")}  {LayoutEngine.FormatKeyHint(_theme, "?", "Help")}  {LayoutEngine.FormatKeyHint(_theme, "q", "Quit")}";
    }

    private void RenderCompletionDropdownOverlay(List<string> canvas, int totalW, int mainX, int mainW, int topRow, int bodyH, int maxItemsCap = 7)
    {
        CompletionResult? comp = _completion;
        if (comp is null || comp.Items.Count == 0 || bodyH < 3)
            return;

        int maxVisible = Math.Clamp(bodyH - 2, 1, maxItemsCap);
        int count = Math.Min(maxVisible, comp.Items.Count);
        var boxRows = new List<string>(count);
        int innerW = Math.Clamp(mainW - 2, 24, 92);

        for (int i = 0; i < count; i++)
        {
            CompletionCandidate item = comp.Items[i];
            bool sel = i == _completionIndex;
            string cat = item.Category switch
            {
                CompletionCategory.Command => "CMD",
                CompletionCategory.Directory => "DIR",
                CompletionCategory.File => "FIL",
                CompletionCategory.Project => "PRJ",
                CompletionCategory.Capability => "CAP",
                CompletionCategory.Section => "SEC",
                CompletionCategory.Flag => "FLG",
                CompletionCategory.Action => "ACT",
                CompletionCategory.Tool => "TL ",
                _ => "SUG"
            };
            string left = $" {(sel ? _theme.FocusPointer : " ")} {_theme.Style(_theme.Accent, cat)} {_theme.Style(sel ? _theme.Bold + _theme.Primary : _theme.Primary, _theme.TruncateEnd(item.Label, Math.Max(10, innerW / 2)))}";
            string right = _theme.Style(_theme.MutedText, _theme.TruncateEnd(item.Meta, Math.Max(6, innerW / 3)));
            string row = LayoutEngine.AlignLeftRight(left, right + " ", innerW);
            boxRows.Add(sel ? LayoutEngine.PaintSurfaceRow(row, innerW, _theme, _theme.FocusRowBg) : row);
        }

        int boxH = boxRows.Count + 2;
        int startRow = Math.Max(topRow, topRow + bodyH - boxH);
        LayoutEngine.OverlayBox(canvas, totalW, startRow, mainX + 1, innerW + 2, boxRows, $"Completions ({comp.Items.Count})", _theme);
    }

    private void RenderCommandDrawerOverlay(List<string> canvas, int totalW, int mainX, int mainW, int topRow, int bodyH)
    {
        if (bodyH < 4)
            return;

        int boxW = Math.Clamp(mainW, 30, totalW - mainX);
        int innerW = Math.Max(20, boxW - 2);
        var content = new List<string>();

        if (_paletteOutcome is { } outRes)
        {
            string modeLabel = _paletteShowRawJson ? "Raw JSON" : "Structured";
            string statusStr = outRes.Envelope.Ok
                ? _theme.Style(_theme.Success, $"{_theme.IconOk} {outRes.Envelope.Capability} ({outRes.Envelope.DurationMs}ms)")
                : _theme.Style(_theme.Error, $"{_theme.IconErr} {outRes.Envelope.Error?.Code ?? "ERROR"}");
            content.Add(LayoutEngine.AlignLeftRight(" " + statusStr, _theme.Style(_theme.Accent, $"[{modeLabel}] "), innerW));

            if (!outRes.Envelope.Ok && outRes.Envelope.Error is { } err)
            {
                content.AddRange(LayoutEngine.BuildErrorBox(_theme, err.Code, err.Message, innerW));
                string recovery = SuggestRecoveryForError(err.Code);
                if (!string.IsNullOrEmpty(recovery))
                    content.Add($"   {_theme.Style(_theme.MutedText, _theme.TruncateEnd($"Recovery: {recovery}", Math.Max(16, innerW - 4)))}");
            }
            else if (_paletteShowRawJson)
            {
                string json = JsonSerializer.Serialize(outRes.Envelope, JsonDefaults.Readable);
                foreach (string jl in json.Split('\n'))
                    content.Add(" " + _theme.Style(_theme.Secondary, jl.TrimEnd('\r')));
            }
            else
            {
                content.AddRange(FormatStructuredOutcome(outRes.Envelope, innerW, Math.Max(4, bodyH - 4)));
            }
        }
        else if (_session.LastCommandResult is { } res)
        {
            string titleBadge = res.Success
                ? $"{_theme.IconOk} Command Completed"
                : $"{_theme.IconErr} {(string.IsNullOrWhiteSpace(res.ErrorCode) ? "COMMAND_ERROR" : res.ErrorCode)}";
            content.Add($" {_theme.Style(res.Success ? _theme.Success : _theme.Error, titleBadge)}");
            if (!string.IsNullOrWhiteSpace(res.CommandText))
                content.Add($"   {_theme.Style(_theme.MutedText, _theme.TruncateEnd($"Target: {res.CommandText}", Math.Max(16, innerW - 4)))}");
            foreach (string wr in DesignTheme.WrapText(res.Headline, Math.Max(16, innerW - 4), _theme.AsciiOnly))
                content.Add($"   {_theme.Style(_theme.Primary, wr)}");
            foreach (string d in res.Details)
                content.Add($"   {_theme.Style(_theme.Secondary, _theme.TruncateEnd(d, Math.Max(14, innerW - 4)))}");
            if (!res.Success)
            {
                string rec = SuggestRecoveryForError(res.ErrorCode);
                if (!string.IsNullOrEmpty(rec))
                    content.Add($"   {_theme.Style(_theme.MutedText, _theme.TruncateEnd($"Recovery: {rec}", Math.Max(16, innerW - 4)))}");
            }
        }

        if (content.Count == 0)
            return;

        int maxInnerH = Math.Max(2, bodyH - 2);
        _lastDrawerPageHeight = maxInnerH;
        _commandDrawerScroll = Math.Clamp(_commandDrawerScroll, 0, Math.Max(0, content.Count - maxInnerH));
        var sliced = content.Skip(_commandDrawerScroll).Take(maxInnerH).ToList();

        int startRow = Math.Max(topRow, topRow + bodyH - (sliced.Count + 2));
        LayoutEngine.OverlayBox(canvas, totalW, startRow, mainX, boxW, sliced, "Command Result (Esc Close · Ctrl+J Mode)", _theme);
    }

    private static string SuggestRecoveryForError(string? code) => code switch
    {
        "UNSUPPORTED_SHELL_SYNTAX" => "Use built-in commands ('help') or run shell pipelines in PowerShell.",
        "POLICY_BLOCKED" => "Target is protected; choose a user workspace path.",
        "DIRECTORY_NOT_FOUND" or "NOT_FOUND" => "Use 'ls' or 'cd' with Tab completion to verify target path.",
        "DESTINATION_EXISTS" => "Rename or pick an empty destination (silent overwrite blocked).",
        "RECYCLE_BIN_FAILED" => "Path exceeds shell Recycle Bin limits; verify target before manual cleanup.",
        "UNKNOWN_COMMAND" => "Type 'help' or press Tab to view valid built-in commands.",
        _ => "Inspect path/arguments and press Esc to continue."
    };

    private void RenderActiveModalOverlay(List<string> canvas, int totalW, int topRow, int bodyH)
    {
        ActiveModalState m = _modal!;
        LayoutBreakpoint modalBp = DesignTheme.GetBreakpoint(totalW);
        bool sidebarVisible = m.Kind != ModalKind.NarrowTreePicker && modalBp != LayoutBreakpoint.Narrow && !_session.TreeCollapsed;
        int areaStart = sidebarVisible ? (modalBp == LayoutBreakpoint.Wide ? 27 : 26) + 3 : 0;
        int areaW = totalW - areaStart;
        int boxW = Math.Clamp((int)(areaW * 0.86), 34, Math.Max(34, areaW - 2));
        int innerW = boxW - 2;
        var rows = new List<string>();

        if (m.Kind == ModalKind.NarrowTreePicker)
        {
            var nodes = WorkspaceSessionContext.AllNavigationNodes.Where(n => n.IsEnabled).ToList();
            int maxShow = Math.Max(4, Math.Min(bodyH - 4, nodes.Count));
            int clampedIdx = nodes.Count == 0 ? 0 : Math.Clamp(_treePickerIndex, 0, nodes.Count - 1);
            int start = Math.Clamp(clampedIdx - maxShow / 2, 0, Math.Max(0, nodes.Count - maxShow));
            for (int i = start; i < Math.Min(nodes.Count, start + maxShow); i++)
            {
                NavigationNodeDescriptor n = nodes[i];
                bool sel = i == clampedIdx;
                string line = $" {(sel ? _theme.FocusPointer : " ")} {_theme.Style(_theme.MutedText, $"{n.Category,-12}")} {_theme.Style(_theme.Primary, n.Label)}";
                rows.Add(sel ? LayoutEngine.PaintSurfaceRow(line, innerW, _theme, _theme.FocusRowBg) : line);
            }
            LayoutEngine.OverlayBox(canvas, totalW, topRow + 1, areaStart + Math.Max(0, (areaW - boxW) / 2), boxW, rows, m.Title, _theme, _theme.Accent);
            return;
        }

        if (m.Kind == ModalKind.ConfirmTerminateStep1 && m.ProcessImpact is { } imp)
        {
            if (!imp.ProcessExists || imp.PidReused || !imp.CanTerminate)
            {
                foreach (string msg in m.MessageLines)
                {
                    foreach (string wr in DesignTheme.WrapText(msg, Math.Max(16, innerW - 2), _theme.AsciiOnly))
                        rows.Add(" " + _theme.Style(_theme.Warning, wr));
                }
                rows.Add(string.Empty);
                rows.Add($" {_theme.Style(_theme.Accent, "[Enter / Esc]")} Dismiss (Action unavailable)");
            }
            else
            {
                rows.Add($" {_theme.Style(_theme.Bold + _theme.Accent, "VERIFIED RELATIONSHIPS")}");
                foreach (string v in imp.VerifiedRelationships.Take(4))
                {
                    foreach (string wr in DesignTheme.WrapText($"• {v}", Math.Max(16, innerW - 2), _theme.AsciiOnly))
                        rows.Add(" " + _theme.Style(_theme.Primary, wr));
                }
                rows.Add($" {_theme.Style(_theme.Bold + _theme.Warning, "POSSIBLE CONSEQUENCES")}");
                foreach (string c in imp.PossibleConsequences.Take(2))
                {
                    foreach (string wr in DesignTheme.WrapText($"• {c}", Math.Max(16, innerW - 2), _theme.AsciiOnly))
                        rows.Add(" " + _theme.Style(_theme.Secondary, wr));
                }
                rows.Add($" {_theme.Style(_theme.Bold + _theme.MutedText, "UNKNOWN EFFECTS (UNVERIFIABLE)")}");
                foreach (string u in imp.UnknownEffects.Take(2))
                {
                    foreach (string wr in DesignTheme.WrapText($"• {u}", Math.Max(16, innerW - 2), _theme.AsciiOnly))
                        rows.Add(" " + _theme.Style(_theme.MutedText, wr));
                }
                rows.Add(string.Empty);
                string actFooter = imp.SupportsGracefulClose
                    ? $" {_theme.Style(_theme.Success, "[G] Graceful Close")}   {_theme.Style(_theme.Warning, "[F / Enter] Force Step 2 ->")}   {_theme.Style(_theme.MutedText, "[Esc] Cancel")}"
                    : $" {_theme.Style(_theme.Warning, "[Enter / F] Proceed to Step 2 Force Kill ->")}   {_theme.Style(_theme.MutedText, "[Esc] Cancel")}";
                rows.Add(actFooter);
            }

            int tBoxH = Math.Min(bodyH, rows.Count + 2);
            int tStartRow = topRow + Math.Max(0, (bodyH - tBoxH) / 2);
            int tStartCol = areaStart + Math.Max(0, (areaW - boxW) / 2);
            LayoutEngine.OverlayBox(canvas, totalW, tStartRow, tStartCol, boxW, rows.Take(Math.Max(3, tBoxH - 2)).ToList(), m.Title, _theme, imp.CanTerminate ? _theme.Warning : _theme.Error);
            return;
        }

        foreach (string msg in m.MessageLines)
        {
            foreach (string wr in DesignTheme.WrapText(msg, Math.Max(16, innerW - 2), _theme.AsciiOnly))
                rows.Add(" " + _theme.Style(m.Kind is ModalKind.ProtectedBlocked or ModalKind.ConfirmTerminateForceStep2 ? _theme.Warning : _theme.Secondary, wr));
        }

        if (m.Kind is ModalKind.PromptMkdir or ModalKind.PromptRename or ModalKind.ConfirmTerminateForceStep2)
        {
            rows.Add(string.Empty);
            string inputLine = $" > {_theme.Style(_theme.Bold + _theme.Primary, m.InputValue)}{_theme.Style(_theme.Accent, "_")}";
            rows.Add(LayoutEngine.PaintSurfaceRow(inputLine, innerW, _theme, _theme.FocusRowBg));
            if (!string.IsNullOrEmpty(m.ErrorHint))
                rows.Add($" {_theme.Style(_theme.Error, _theme.IconErr + " " + m.ErrorHint)}");
        }

        rows.Add(string.Empty);
        string footer = m.Kind switch
        {
            ModalKind.ProtectedBlocked => $" {_theme.Style(_theme.Accent, "[Enter / Esc]")} Dismiss",
            ModalKind.ConfirmTerminateForceStep2 => $" {_theme.Style(_theme.Error, "[Enter]")} Execute Kill    {_theme.Style(_theme.MutedText, "[Esc]")} Cancel",
            _ => $" {_theme.Style(_theme.Success, "[Enter / Y]")} Confirm    {_theme.Style(_theme.MutedText, "[Esc / N]")} Cancel"
        };
        rows.Add(footer);

        string borderCol = m.Kind switch
        {
            ModalKind.ProtectedBlocked or ModalKind.ConfirmTerminateForceStep2 => _theme.Error,
            ModalKind.ConfirmDelete or ModalKind.ConfirmPaste when m.RequireElevatedConfirm || m.PermanentDelete => _theme.Warning,
            _ => _theme.Accent
        };

        int boxH = rows.Count + 2;
        int startRow = topRow + Math.Max(0, (bodyH - boxH) / 2);
        int startCol = areaStart + Math.Max(0, (areaW - boxW) / 2);
        LayoutEngine.OverlayBox(canvas, totalW, startRow, startCol, boxW, rows, m.Title, _theme, borderCol);
    }
}

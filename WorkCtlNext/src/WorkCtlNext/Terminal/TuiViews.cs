using System.Text.Json;
using WorkCtlNext.Core;

namespace WorkCtlNext.Terminal;

public sealed partial class TuiApp
{
    public IReadOnlyList<string> RenderFrame()
        => RenderFrame(_backend.WindowWidth, _backend.WindowHeight);

    public IReadOnlyList<string> RenderFrame(int width, int height)
    {
        int w = Math.Max(40, width);
        int h = Math.Max(10, height);
        LayoutBreakpoint bp = DesignTheme.GetBreakpoint(w);

        bool compactCommandArea = h < 15;
        int cmdRows = compactCommandArea ? 2 : 3; // hairline (optional) + input bar + context hint strip
        int topChromeRows = 2; // row 0 header + row 1 divider or narrow strip
        int bodyH = Math.Max(3, h - topChromeRows - cmdRows);

        var lines = new List<string>(h);
        lines.Add(BuildHeaderLine(w, bp));

        bool showSidebar = bp != LayoutBreakpoint.Narrow && !_session.TreeCollapsed;
        int navW = bp == LayoutBreakpoint.Wide ? 27 : 26;
        int mainX = showSidebar ? navW + 3 : 0;
        int mainW = showSidebar ? Math.Max(20, w - navW - 3) : w;

        if (showSidebar)
        {
            lines.Add(_theme.Style(_theme.Border, new string(_theme.RuleH[0], w)));
            var navLines = BuildHierarchicalSidebar(navW, bodyH);
            var mainLines = _screen == TuiScreen.Help
                ? BuildHelpPane(mainW, bodyH)
                : BuildMainSectionPane(mainW, bodyH, bp);
            lines.AddRange(LayoutEngine.ComposeColumns(navLines, navW, mainLines, mainW, bodyH, _theme));
        }
        else
        {
            lines.Add(BuildNarrowTabStrip(w));
            var mainLines = _screen == TuiScreen.Help
                ? BuildHelpPane(w, bodyH)
                : BuildMainSectionPane(w, bodyH, bp);
            for (int i = 0; i < Math.Min(bodyH, mainLines.Count); i++)
                lines.Add(mainLines[i]);
            while (lines.Count < h - cmdRows)
                lines.Add(string.Empty);
        }

        // Composite non-corrupting docked overlays over body region [topChromeRows .. topChromeRows + bodyH - 1]
        if (_modal is not null)
        {
            RenderActiveModalOverlay(lines, w, topChromeRows, bodyH);
        }
        else if (_screen != TuiScreen.Help)
        {
            bool showDropdown = _session.Focus == FocusRegion.CommandLine
                && _completionDropdownOpen
                && _completion is { Items.Count: > 0 };

            int dropdownReservedRows = 0;
            if (showDropdown)
            {
                int ddItems = Math.Min(Math.Clamp(bodyH - 2, 1, _commandDrawerOpen ? 4 : 7), _completion!.Items.Count);
                dropdownReservedRows = ddItems + 2;
            }

            if (_commandDrawerOpen)
            {
                int drawerAvailH = Math.Max(4, bodyH - dropdownReservedRows);
                RenderCommandDrawerOverlay(lines, w, mainX, mainW, topChromeRows, drawerAvailH);
            }

            if (showDropdown)
            {
                RenderCompletionDropdownOverlay(lines, w, mainX, mainW, topChromeRows, bodyH, maxItemsCap: _commandDrawerOpen ? 4 : 7);
            }
        }

        // Bottom Region: Persistent Command Area (always present, zero layout shift)
        lines.AddRange(BuildPersistentCommandArea(w, bp, compactCommandArea));

        for (int i = 0; i < lines.Count; i++)
            lines[i] = DiffRenderer.ClampAndPad(lines[i], w);

        while (lines.Count < h)
            lines.Add(new string(' ', w));

        return lines.Count > h ? lines.Take(h).ToList() : lines;
    }

    private string BuildHeaderLine(int width, LayoutBreakpoint bp)
    {
        NavigationNodeDescriptor node = WorkspaceSessionContext.GetNode(_session.CurrentSection);
        string ctx = _screen == TuiScreen.Help
            ? "Help"
            : _session.CurrentSection switch
            {
                NavigationSectionId.DevProjects when _projectDetailOpen => "Project Detail",
                NavigationSectionId.DevUlvo when _envDetailOpen => "Runtime Detail",
                NavigationSectionId.MachineOverview => $"Console {_theme.MiddleDot} Overview",
                _ when WorkspaceSessionContext.IsFilesSection(_session.CurrentSection) => $"{node.Label} {(_theme.AsciiOnly ? ">" : "·")} {DesignTheme.TruncateMiddle(_session.ActiveDirectory, 28)}",
                _ => $"{node.Category} {_theme.MiddleDot} {node.Label}"
            };

        var parts = new List<string>(5);
        bool busy = _loading || _paletteRunning || _inspectingProjectId is not null || _inspectingEnvPath is not null;
        if (busy)
        {
            string sp = _theme.SpinnerGlyph(_animPhase, _visualOptions.ReducedMotion);
            string label = _loading
                ? $"{sp} Sync {Volatile.Read(ref _refreshProvidersDone)}/{RefreshProvidersTotal}"
                : $"{sp} Sync";
            parts.Add(_theme.Style(_theme.Accent, label));
        }
        else if (IsHighlightActive(_refreshFlashUntilTs) && !_visualOptions.ReducedMotion)
        {
            parts.Add(_theme.Style(_theme.Success, $"{_theme.IconOk} Synced"));
        }

        if (_performance is { } perf)
        {
            string cpuCol = _theme.ThresholdColor(perf.CpuUtilizationPercent);
            parts.Add(_theme.Style(cpuCol, $"CPU {perf.CpuUtilizationPercent:F0}%"));
        }

        MachineSnapshot? machine = _machine;
        if (machine is not null)
        {
            string ramCol = _theme.ThresholdColor(machine.MemoryLoadPercent);
            parts.Add(_theme.Style(ramCol, $"RAM {machine.MemoryLoadPercent}%"));
            if (bp == LayoutBreakpoint.Wide)
                parts.Add(_theme.Style(_theme.Secondary, $"{machine.ProcessCount} procs"));
        }

        if (bp != LayoutBreakpoint.Narrow)
        {
            bool filesRw = WorkspaceSessionContext.IsFilesSection(_session.CurrentSection);
            parts.Add(_theme.Style(filesRw ? _theme.Accent : _theme.MutedText, filesRw ? "Files RW" : "Guarded"));
        }

        return LayoutEngine.ComposeHeaderLine(width, _theme, ctx, parts);
    }

    private string BuildNarrowTabStrip(int width)
    {
        int projCount = _wsctlProjects?.Projects.Count ?? 0;

        string Tab(bool active, string key, string label)
        {
            if (active)
                return _theme.Style(_theme.Bold + _theme.Accent, $"{_theme.FocusPointer}{key} {label}");
            return _theme.Style(_theme.Secondary, $" {key} {label}");
        }

        bool isFiles = WorkspaceSessionContext.IsFilesSection(_session.CurrentSection);
        bool isHome = _screen != TuiScreen.Help && _session.CurrentSection == NavigationSectionId.MachineOverview;
        bool isProj = _screen != TuiScreen.Help && _session.CurrentSection == NavigationSectionId.DevProjects;
        bool isRun = _screen != TuiScreen.Help && _session.CurrentSection == NavigationSectionId.DevUlvo;

        string pLabel = width >= 60 && projCount > 0 ? $"Proj({projCount})" : "Proj";
        string strip = string.Join(" ",
            Tab(isHome, "1", "Home"),
            Tab(isProj, "2", pLabel),
            Tab(isRun, "3", "ULVO"),
            _theme.Style(isFiles ? _theme.Bold + _theme.Accent : _theme.Secondary, isFiles ? $"{_theme.FocusPointer}Files" : "Files"),
            Tab(_screen == TuiScreen.Help, "?", "Help"),
            _theme.Style(_theme.MutedText, "[Menu"));

        return " " + strip;
    }

    private List<string> BuildSidebar(int w, int h)
    {
        var rows = new List<string>(h);
        bool navFocused = _focus == FocusZone.Navigation;
        string headerText = navFocused ? " NAVIGATION [FOCUSED]" : " NAVIGATION";
        rows.Add(_theme.Style(navFocused ? _theme.Bold + _theme.Accent : _theme.MutedText, headerText));
        rows.Add(string.Empty);

        int projCount = _wsctlProjects?.Projects.Count ?? 0;
        int envCount = _ulvoRuntimes?.Projects.Count ?? 0;

        rows.Add(FormatNavItem(TuiScreen.Home, "1", "Overview", w, navFocused));
        rows.Add(FormatNavItem(TuiScreen.Projects, "2", projCount > 0 ? $"Projects ({projCount})" : "Projects", w, navFocused));
        rows.Add(FormatNavItem(TuiScreen.Environments, "3", envCount > 0 ? $"Runtimes ({envCount})" : "Runtimes", w, navFocused));
        rows.Add(FormatNavItem(TuiScreen.Palette, ":", "Command", w, navFocused));
        rows.Add(FormatNavItem(TuiScreen.Help, "?", "Help", w, navFocused));

        if (h >= 15)
        {
            rows.Add(string.Empty);
            rows.Add(_theme.Style(_theme.Border, " " + new string(_theme.RuleH[0], Math.Max(4, w - 2))));
            rows.Add(_theme.Style(_theme.Secondary, " PROVIDERS"));

            WsctlProjectsResult? ws = _wsctlProjects;
            string wsIcon = ws?.Status == ProviderStatus.Available
                ? _theme.Style(_theme.Success, _theme.DotLive)
                : _loading && ws is null
                    ? _theme.Style(_theme.Accent, _theme.SpinnerGlyph(_animPhase, _visualOptions.ReducedMotion))
                    : _theme.Style(_theme.Error, _theme.IconErr);
            rows.Add($" {wsIcon} {_theme.Style(_theme.Primary, "WSCTL")}");

            WsctlHealthSnapshot? wh = _wsctlHealth;
            if (wh is not null)
            {
                string docText;
                string docColor;
                string docGlyph;
                if (string.Equals(wh.DoctorSnapshotStatus, "UNAVAILABLE", StringComparison.OrdinalIgnoreCase))
                {
                    docText = "Doctor none";
                    docColor = _theme.Warning;
                    docGlyph = _theme.IconWarn;
                }
                else if (wh.DoctorSnapshotStale)
                {
                    docText = $"Doctor {DesignTheme.FormatAgeCompact(wh.DoctorSnapshotAgeSeconds)}";
                    docColor = _theme.Warning;
                    docGlyph = _theme.IconWarn;
                }
                else
                {
                    docText = "Doctor fresh";
                    docColor = _theme.Success;
                    docGlyph = _theme.IconOk;
                }
                rows.Add($"   {_theme.Style(docColor, docGlyph)} {_theme.Style(_theme.Secondary, _theme.TruncateEnd(docText, Math.Max(8, w - 6)))}");
            }

            UlvoStatusSummary? us = _ulvoStatus;
            string ulIcon = us?.Status == ProviderStatus.Available
                ? _theme.Style(_theme.Success, _theme.DotLive)
                : _loading && us is null
                    ? _theme.Style(_theme.Accent, _theme.SpinnerGlyph(_animPhase, _visualOptions.ReducedMotion))
                    : us?.Status == ProviderStatus.Degraded
                        ? _theme.Style(_theme.Warning, _theme.IconWarn)
                        : _theme.Style(_theme.Error, _theme.IconErr);
            rows.Add($" {ulIcon} {_theme.Style(_theme.Primary, "ULVO")}");
        }

        while (rows.Count < h - 1)
            rows.Add(string.Empty);

        if (rows.Count < h)
        {
            string zone = _focus switch
            {
                FocusZone.Navigation => _theme.Style(_theme.Accent, "Focus: Nav"),
                FocusZone.Search => _theme.Style(_screen == TuiScreen.Palette ? _theme.Accent : _theme.Warning, _screen == TuiScreen.Palette ? "Focus: Cmd" : "Focus: Find"),
                _ => _theme.Style(_theme.MutedText, "Focus: Main")
            };
            rows.Add($" {zone}");
        }

        return rows;
    }

    private string FormatNavItem(TuiScreen target, string key, string label, int w, bool navFocused)
    {
        bool selected = _screen == target;
        string ptr = selected ? _theme.FocusPointer : " ";
        string kStyled = _theme.Style(selected ? _theme.Accent : _theme.MutedText, $"[{key}]");
        string lblStyled = _theme.Style(selected ? _theme.Bold + _theme.Primary : _theme.Secondary, label);
        string raw = $" {_theme.Style(selected ? _theme.Accent : _theme.MutedText, ptr)} {kStyled} {lblStyled}";
        return selected ? PaintRowBg(raw, w, navFocused) : raw;
    }

    private List<string> BuildMainPane(int w, int h, LayoutBreakpoint bp) => _screen switch
    {
        TuiScreen.Home => BuildHomePane(w, h, bp),
        TuiScreen.Projects => BuildProjectsPane(w, h, bp),
        TuiScreen.Environments => BuildEnvironmentsPane(w, h, bp),
        TuiScreen.Palette => BuildPalettePane(w, h, bp),
        TuiScreen.Help => BuildHelpPane(w, h),
        _ => BuildHomePane(w, h, bp)
    };

    private List<string> BuildHomePane(int w, int h, LayoutBreakpoint bp)
    {
        var lines = new List<string>(h);

        if (bp == LayoutBreakpoint.Wide && w >= 78 && h >= 18)
        {
            int leftW = (w - 3) / 2;
            int rightW = Math.Max(20, w - leftW - 3);
            var sysRows = BuildSystemCluster(leftW, compactDisks: false, barW: 10);
            var wsRows = BuildWorkspaceCluster(rightW, includeTools: true);
            int clusterH = Math.Max(sysRows.Count, wsRows.Count);
            lines.AddRange(LayoutEngine.ComposeColumns(sysRows, leftW, wsRows, rightW, clusterH, _theme));
            lines.Add(_theme.Style(_theme.Border, new string(_theme.RuleH[0], w)));

            int remain = Math.Max(0, h - lines.Count);
            lines.AddRange(BuildHomeLowerRegion(w, h, bp, remain, allowDualColumns: true));
        }
        else
        {
            bool tight = h <= 16;
            int barW = bp == LayoutBreakpoint.Narrow ? 6 : 10;
            var sysRows = BuildSystemCluster(w, compactDisks: tight || bp == LayoutBreakpoint.Narrow, barW: barW);
            var wsRows = BuildWorkspaceCluster(w, includeTools: h >= 21);

            lines.AddRange(sysRows);
            if (lines.Count + wsRows.Count + 2 <= h)
                lines.Add(_theme.Style(_theme.Border, new string(_theme.RuleH[0], w)));
            lines.AddRange(wsRows);

            int remain = Math.Max(0, h - lines.Count);
            if (remain >= 3)
            {
                lines.Add(_theme.Style(_theme.Border, new string(_theme.RuleH[0], w)));
                lines.AddRange(BuildHomeLowerRegion(w, h, bp, remain - 1, allowDualColumns: false));
            }
        }

        while (lines.Count < h)
            lines.Add(string.Empty);

        return lines.Take(h).ToList();
    }

    private List<string> BuildSystemCluster(int w, bool compactDisks, int barW)
    {
        var rows = new List<string>(8)
        {
            $" {_theme.Style(_theme.Bold + _theme.Accent, "SYSTEM")}"
        };

        MachineSnapshot? machine = _machine;
        if (machine is null)
        {
            rows.Add($"  {_theme.Style(_theme.Secondary, "Reading host metrics...")}");
            return rows;
        }

        int valW = Math.Max(14, w - 11);
        string hostStr = $"{machine.MachineName} {_theme.MiddleDot} {DesignTheme.FormatOsCompact(machine.OsVersion)}";
        rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "Host", _theme.Style(_theme.Primary, _theme.TruncateEnd(hostStr, valW))));

        string cpuStr = _theme.TruncateEnd(DesignTheme.FormatCpuCompact(machine.CpuName, machine.LogicalCores, valW), valW);
        rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "CPU", _theme.Style(_theme.Primary, cpuStr)));

        double usedGb = Math.Max(0, (machine.TotalRamMb - machine.AvailableRamMb) / 1024.0);
        double totalGb = Math.Max(0.1, machine.TotalRamMb / 1024.0);
        string ramBar = _theme.BuildBar(machine.MemoryLoadPercent / 100.0, barW, _theme.ThresholdColor(machine.MemoryLoadPercent));
        string ramPct = $"{machine.MemoryLoadPercent,3}%";
        string ramText = $"{ramBar} {_theme.Style(_theme.Primary, ramPct)} {_theme.Style(_theme.Secondary, $"{usedGb:F1}/{totalGb:F0}G")}";
        rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "Memory", ramText));

        var readyDisks = machine.FixedDisks.Where(d => d.IsReady && d.TotalGb > 0).ToList();
        if (compactDisks || readyDisks.Count <= 1)
        {
            string diskText = readyDisks.Count == 0
                ? _theme.Style(_theme.Warning, "No ready fixed drives")
                : string.Join("  ", readyDisks.Take(3).Select(d =>
                {
                    double pct = ((d.TotalGb - d.FreeGb) / d.TotalGb) * 100.0;
                    string c = _theme.ThresholdColor(pct);
                    return $"{_theme.Style(_theme.Primary, d.Name)} {_theme.Style(c, $"{d.FreeGb:F0}G free")}";
                }));
            rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "Disks", diskText));
        }
        else
        {
            foreach (var d in readyDisks.Take(2))
            {
                double ratio = (d.TotalGb - d.FreeGb) / d.TotalGb;
                double usedPct = ratio * 100.0;
                string pctColor = _theme.ThresholdColor(usedPct);
                string bar = _theme.BuildBar(ratio, barW, pctColor);
                string pctPad = $"{usedPct,3:F0}%";
                string freeStr = $"{d.FreeGb,2:F0}G free";
                string txt = $"{bar} {_theme.Style(pctColor, pctPad)} {_theme.Style(_theme.Primary, d.Name)} {_theme.Style(_theme.Secondary, freeStr)}";
                rows.Add(LayoutEngine.FormatKeyValueRow(_theme, d == readyDisks[0] ? "Disks" : "", txt));
            }
        }

        rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "Procs", _theme.Style(_theme.Primary, $"{machine.ProcessCount} running")));
        return rows;
    }

    private List<string> BuildWorkspaceCluster(int w, bool includeTools)
    {
        var rows = new List<string>(8)
        {
            $" {_theme.Style(_theme.Bold + _theme.Accent, "WORKSPACE & RUNTIMES")}"
        };

        int valW = Math.Max(14, w - 11);
        rows.Add(LayoutEngine.FormatKeyValueRow(
            _theme,
            "Dir",
            _theme.Style(_theme.Primary, DesignTheme.TruncateMiddle(_session.ActiveDirectory, valW))));

        ProjectSummary? cwdProj = ResolveCwdProject();
        string activeVal = cwdProj is not null
            ? $"{_theme.Style(_theme.Success, cwdProj.Name)} {_theme.Style(_theme.MutedText, $"({_theme.FormatEnvTag(cwdProj.Environment)})")}"
            : _theme.Style(_theme.MutedText, "None in CWD");
        rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "Project", activeVal));

        WsctlProjectsResult? ws = _wsctlProjects;
        bool wsFlash = IsHighlightActive(_wsctlSettledUntilTs);
        if (ws is { Status: ProviderStatus.Available })
        {
            int total = ws.Projects.Count;
            int accessible = ws.Projects.Count(p => p.Accessible);
            int missing = total - accessible;
            string wsGlyph = missing > 0 ? _theme.Style(_theme.Warning, _theme.IconWarn) : _theme.Style(_theme.Success, _theme.IconOk);
            string wsCountText = missing > 0
                ? $"{accessible}/{total} accessible ({missing} missing)"
                : $"{total}/{total} accessible";
            string wsCol = wsFlash ? _theme.Accent : _theme.Primary;
            rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "WSCTL", $"{wsGlyph} {_theme.Style(wsCol, _theme.TruncateEnd(wsCountText, Math.Max(10, valW - 2)))}"));
        }
        else if (_loading && ws is null)
        {
            string sp = _theme.SpinnerGlyph(_animPhase, _visualOptions.ReducedMotion);
            rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "WSCTL", _theme.Style(_theme.Accent, $"{sp} Indexing catalog...")));
        }
        else
        {
            string msg = ws?.Error?.Message ?? "WSCTL provider unavailable";
            rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "WSCTL", _theme.Style(_theme.Error, $"{_theme.IconErr} {_theme.TruncateEnd(msg, Math.Max(8, valW - 2))}")));
        }

        (string docLabel, string docGlyph, string docColor) = _theme.FormatDoctorSummary(_wsctlHealth, _loading);
        if (IsHighlightActive(_healthSettledUntilTs) && _wsctlHealth is not null && !_wsctlHealth.DoctorSnapshotStale)
            docColor = _theme.Accent;
        rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "Doctor", _theme.Style(docColor, $"{docGlyph} {_theme.TruncateEnd(docLabel, Math.Max(8, valW - 2))}")));

        UlvoStatusSummary? us = _ulvoStatus;
        bool ulvoFlash = IsHighlightActive(_ulvoSettledUntilTs);
        if (us is { Status: ProviderStatus.Available })
        {
            string vault = us.VaultExists ? "Vault OK" : "No vault";
            string ulvoStr = $"v{us.Version ?? "?"} {_theme.MiddleDot} {vault} {_theme.MiddleDot} {us.RegisteredProjects} tracked";
            string uCol = ulvoFlash ? _theme.Accent : _theme.Primary;
            rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "ULVO", _theme.Style(uCol, _theme.TruncateEnd(ulvoStr, valW))));
        }
        else if (_loading && us is null)
        {
            string sp = _theme.SpinnerGlyph(_animPhase, _visualOptions.ReducedMotion);
            rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "ULVO", _theme.Style(_theme.Accent, $"{sp} Checking runtime...")));
        }
        else
        {
            string uErr = us?.Error?.Message ?? "Unavailable";
            rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "ULVO", _theme.Style(_theme.Error, $"{_theme.IconErr} {_theme.TruncateEnd(uErr, Math.Max(8, valW - 2))}")));
        }

        var tools = _tools;
        if (includeTools && tools.Count > 0)
        {
            var ready = tools.Where(t => t.Installed).Select(t => t.Name).ToList();
            string toolSummary;
            if (ready.Count == 0)
            {
                toolSummary = _theme.Style(_theme.MutedText, "none detected");
            }
            else
            {
                var shown = ready.Take(4).ToList();
                int extra = ready.Count - shown.Count;
                string names = string.Join(" ", shown) + (extra > 0 ? $" +{extra}" : string.Empty);
                toolSummary = $"{_theme.Style(_theme.Primary, $"{ready.Count}/{tools.Count}")} {_theme.Style(_theme.Secondary, _theme.TruncateEnd(names, Math.Max(10, valW - 6)))}";
            }
            rows.Add(LayoutEngine.FormatKeyValueRow(_theme, "Tools", toolSummary));
        }

        return rows;
    }

    private List<string> BuildHomeLowerRegion(int w, int bodyH, LayoutBreakpoint bp, int maxRows, bool allowDualColumns)
    {
        var rows = new List<string>();
        if (maxRows <= 0)
            return rows;

        // Collect all active provider errors so ULVO errors are never swallowed by WSCTL errors.
        var providerErrs = new List<(string Provider, string Code, string Message)>();
        WsctlProjectsResult? ws = _wsctlProjects;
        if (ws is not null && ws.Status != ProviderStatus.Available && ws.Error is not null)
            providerErrs.Add(("WSCTL", ws.Error.Code, ws.Error.Message));
        UlvoStatusSummary? us = _ulvoStatus;
        if (us is not null && us.Status != ProviderStatus.Available && us.Error is not null)
            providerErrs.Add(("ULVO", us.Error.Code, us.Error.Message));

        if (providerErrs.Count > 0 && maxRows >= 3)
        {
            rows.Add($" {_theme.Style(_theme.Bold + _theme.Error, "PROVIDER DIAGNOSTICS")}");
            foreach ((string prov, string code, string msg) in providerErrs)
            {
                if (rows.Count >= maxRows - 2) break;
                string line = $"  {_theme.Style(_theme.Error, _theme.IconErr)} {_theme.Style(_theme.Primary, $"{prov} {code}")}  {_theme.Style(_theme.Secondary, _theme.TruncateEnd(msg, Math.Max(16, w - prov.Length - code.Length - 8)))}";
                rows.Add(line);
            }
            if (rows.Count < maxRows - 2)
                rows.Add(string.Empty);
        }

        int remain = maxRows - rows.Count;
        if (remain <= 0)
            return rows.Take(maxRows).ToList();

        var allItems = GetHomeItemsForLayout(w, bodyH, bp);
        int sel = allItems.Count == 0 ? 0 : Math.Clamp(_homeItemIndex, 0, allItems.Count - 1);
        int workflowCount = allItems.Count(x => x.IsWorkflow);
        bool mainFocused = _focus == FocusZone.Main;

        if (allowDualColumns && w >= 78 && remain >= 5)
        {
            int leftW = (w - 3) / 2;
            int rightW = Math.Max(20, w - leftW - 3);

            var leftRows = new List<string>(remain)
            {
                $" {_theme.Style(_theme.Bold + _theme.Accent, "WORKFLOWS")} {_theme.Style(_theme.MutedText, $"({_theme.Arrows} Select {_theme.MiddleDot} Enter Run)")}"
            };

            for (int i = 0; i < workflowCount && leftRows.Count < remain; i++)
            {
                HomeQuickItem item = allItems[i];
                bool isSel = i == sel;
                string ptr = isSel ? _theme.Style(_theme.Accent, _theme.FocusPointer) : " ";
                string dot = item.Available ? _theme.Style(_theme.Success, _theme.DotLive) : _theme.Style(_theme.Warning, _theme.IconWarn);
                string cmd = _theme.Style(isSel ? _theme.Bold + _theme.Primary : _theme.Primary, _theme.TruncateEnd(item.Title, 13).PadRight(13));
                int descW = Math.Max(8, leftW - 20);
                string desc = _theme.Style(_theme.Secondary, _theme.TruncateEnd(item.Subtitle, descW));
                string row = $" {ptr} {dot} {cmd} {desc}";
                leftRows.Add(isSel ? PaintRowBg(row, leftW, mainFocused) : row);
            }

            // Fill remaining Wide lower-left rows with cohesive local environment summary
            if (leftRows.Count + 4 <= remain && _tools.Count > 0)
            {
                leftRows.Add(string.Empty);
                leftRows.Add($" {_theme.Style(_theme.Bold + _theme.Accent, "TOOLING & POLICY")}");
                var installedNames = _tools.Where(t => t.Installed).Select(t => t.Name).ToList();
                string toolLine = installedNames.Count > 0
                    ? string.Join($" {_theme.MiddleDot} ", installedNames.Take(7)) + (installedNames.Count > 7 ? $" +{installedNames.Count - 7}" : "")
                    : "none detected";
                leftRows.Add(LayoutEngine.FormatKeyValueRow(_theme, "Ready", _theme.Style(_theme.Secondary, _theme.TruncateEnd(toolLine, Math.Max(12, leftW - 11)))));
                leftRows.Add(LayoutEngine.FormatKeyValueRow(_theme, "Policy", _theme.Style(_theme.Primary, "Read-Only (WSCTL/ULVO safe)")));
                leftRows.Add(LayoutEngine.FormatKeyValueRow(_theme, "Shortcuts", _theme.Style(_theme.MutedText, ": Palette  / Filter  ? Help")));
            }

            int totalProj = ws?.Projects.Count ?? 0;
            int okProj = ws?.Projects.Count(p => p.Accessible) ?? 0;
            int missingProj = totalProj - okProj;
            string rightTitle = missingProj > 0 ? "ATTENTION & PROJECTS" : "WORKSPACE SNAPSHOT";
            string rightBadge = totalProj > 0 ? $"({okProj}/{totalProj} ok)" : string.Empty;

            var rightRows = new List<string>(remain)
            {
                $" {_theme.Style(_theme.Bold + _theme.Accent, rightTitle)} {_theme.Style(_theme.MutedText, rightBadge)}"
            };

            int renderedProjects = 0;
            for (int i = workflowCount; i < allItems.Count && rightRows.Count < remain - 1; i++)
            {
                HomeQuickItem item = allItems[i];
                bool isSel = i == sel;
                string ptr = isSel ? _theme.Style(_theme.Accent, _theme.FocusPointer) : " ";
                string glyph = item.Attention
                    ? _theme.Style(_theme.Warning, _theme.IconWarn)
                    : _theme.Style(_theme.Success, _theme.DotLive);
                int subMax = 15;
                int nameMax = Math.Max(10, rightW - subMax - 8);
                string nm = _theme.Style(isSel ? _theme.Bold + _theme.Primary : _theme.Primary, _theme.TruncateEnd(item.Title, nameMax));
                string sub = _theme.Style(item.Attention ? _theme.Warning : _theme.Secondary, _theme.TruncateEnd(item.Subtitle, subMax));
                string left = $" {ptr} {glyph} {nm}";
                int pad = Math.Max(1, rightW - DiffRenderer.MeasureVisibleLength(left) - DiffRenderer.MeasureVisibleLength(sub) - 1);
                string row = left + new string(' ', pad) + sub + " ";
                rightRows.Add(isSel ? PaintRowBg(row, rightW, mainFocused) : row);
                renderedProjects++;
            }

            if (totalProj > renderedProjects && rightRows.Count < remain)
            {
                int remProj = totalProj - renderedProjects;
                rightRows.Add($"   {_theme.Style(_theme.MutedText, $"+{remProj} more {_theme.MiddleDot} [2] Browse all {totalProj}")}");
            }

            int colH = Math.Min(remain, Math.Max(leftRows.Count, rightRows.Count));
            rows.AddRange(LayoutEngine.ComposeColumns(leftRows, leftW, rightRows, rightW, colH, _theme));
            return rows.Take(maxRows).ToList();
        }

        // Single-column stacked lower section (Standard / Narrow) — strictly bounded to visible items.
        rows.Add($" {_theme.Style(_theme.Bold + _theme.Accent, "WORKFLOWS")} {_theme.Style(_theme.MutedText, $"({_theme.Arrows} Select {_theme.MiddleDot} Enter Run)")}");
        for (int i = 0; i < workflowCount && rows.Count < maxRows; i++)
        {
            HomeQuickItem item = allItems[i];
            bool isSel = i == sel;
            string ptr = isSel ? _theme.Style(_theme.Accent, _theme.FocusPointer) : " ";
            string dot = item.Available ? _theme.Style(_theme.Success, _theme.DotLive) : _theme.Style(_theme.Warning, _theme.IconWarn);
            string cmd = _theme.Style(isSel ? _theme.Bold + _theme.Primary : _theme.Primary, _theme.TruncateEnd(item.Title, 13).PadRight(13));
            string desc = _theme.Style(_theme.Secondary, _theme.TruncateEnd(item.Subtitle, Math.Max(10, w - 21)));
            string row = $" {ptr} {dot} {cmd} {desc}";
            rows.Add(isSel ? PaintRowBg(row, w, mainFocused) : row);
        }

        int leftAfterWf = maxRows - rows.Count;
        if (leftAfterWf >= 2 && allItems.Count > workflowCount && ws is { Status: ProviderStatus.Available, Projects.Count: > 0 })
        {
            int okProj = ws.Projects.Count(p => p.Accessible);
            rows.Add($" {_theme.Style(_theme.Bold + _theme.Accent, "WORKSPACE SNAPSHOT")} {_theme.Style(_theme.MutedText, $"({okProj}/{ws.Projects.Count} ok {_theme.MiddleDot} [2] Projects)")}");
            for (int i = workflowCount; i < allItems.Count && rows.Count < maxRows; i++)
            {
                HomeQuickItem item = allItems[i];
                bool isSel = i == sel;
                string ptr = isSel ? _theme.Style(_theme.Accent, _theme.FocusPointer) : " ";
                string glyph = item.Attention ? _theme.Style(_theme.Warning, _theme.IconWarn) : _theme.Style(_theme.Success, _theme.DotLive);
                string nm = _theme.Style(isSel ? _theme.Bold + _theme.Primary : _theme.Primary, _theme.TruncateEnd(item.Title, Math.Max(14, w / 2 - 4)));
                string sub = _theme.Style(item.Attention ? _theme.Warning : _theme.Secondary, item.Subtitle);
                string row = $" {ptr} {glyph} {nm}  {sub}";
                rows.Add(isSel ? PaintRowBg(row, w, mainFocused) : row);
            }
        }

        return rows.Take(maxRows).ToList();
    }

    private List<string> BuildProjectsPane(int w, int h, LayoutBreakpoint bp)
    {
        var rows = new List<string>(h);
        var items = GetFilteredProjects();
        int total = _wsctlProjects?.Projects.Count ?? 0;

        if (bp == LayoutBreakpoint.Narrow && _projectDetailOpen && items.Count > 0)
        {
            int selIdx = Math.Clamp(_projectIndex, 0, items.Count - 1);
            ProjectSummary sel = items[selIdx];
            string crumb = $" {_theme.Style(_theme.Accent, _theme.BackArrow)} {_theme.Style(_theme.Primary, $"Projects ({selIdx + 1}/{items.Count})")} {_theme.Style(_theme.MutedText, $"{_theme.MiddleDot} Esc Back")}";
            rows.Add(LayoutEngine.PaintSurfaceRow(crumb, w, _theme, _theme.CommandBarBg));
            rows.Add(_theme.Style(_theme.Border, new string(_theme.RuleH[0], w)));
            rows.AddRange(BuildProjectDetailLines(sel, w, Math.Max(2, h - 2)));
            return rows;
        }

        bool searchFocused = _focus == FocusZone.Search;
        string cursor = searchFocused ? _theme.Style(_theme.Accent, "▏") : string.Empty;
        string filterTxt = string.IsNullOrEmpty(_projectFilter)
            ? (searchFocused ? cursor : _theme.Style(_theme.MutedText, "Type / to filter by name, category, or env..."))
            : _theme.Style(_theme.Primary, _projectFilter) + cursor;

        int accessible = _wsctlProjects?.Projects.Count(p => p.Accessible) ?? 0;
        int listH = Math.Max(2, h - 2);
        if (items.Count > 0)
        {
            int pSel = Math.Clamp(_projectIndex, 0, items.Count - 1);
            if (pSel < _projectScroll) _projectScroll = pSel;
            if (pSel >= _projectScroll + listH) _projectScroll = pSel - listH + 1;
            _projectScroll = Math.Clamp(_projectScroll, 0, Math.Max(0, items.Count - listH));
        }
        else
        {
            _projectScroll = 0;
        }

        string rangePrefix = items.Count > 0
            ? $"{Math.Min(items.Count, _projectScroll + 1)}-{Math.Min(items.Count, _projectScroll + listH)}/{items.Count}"
            : $"0/{total}";
        string badgeText = string.IsNullOrEmpty(_projectFilter) && total > 0
            ? $"{rangePrefix} {_theme.MiddleDot} {accessible}/{total} ok"
            : $"{items.Count}/{total} match";

        string badge = _theme.Style(_theme.Secondary, badgeText);
        string leftFilter = $" {_theme.Style(searchFocused ? _theme.Accent : _theme.Secondary, "/")} {filterTxt}";
        int maxFilterLeft = Math.Max(14, w - DiffRenderer.MeasureVisibleLength(badge) - 2);
        string leftTrimmed = DiffRenderer.ClampAndPad(leftFilter, maxFilterLeft).TrimEnd();
        int gap = Math.Max(1, w - DiffRenderer.MeasureVisibleLength(leftTrimmed) - DiffRenderer.MeasureVisibleLength(badge) - 1);
        string filterBar = leftTrimmed + new string(' ', gap) + badge + " ";

        rows.Add(LayoutEngine.PaintSurfaceRow(filterBar, w, _theme, searchFocused ? _theme.FocusRowBg : _theme.CommandBarBg));
        rows.Add(_theme.Style(_theme.Border, new string(_theme.RuleH[0], w)));

        int innerH = Math.Max(2, h - 2);

        if (_wsctlProjects is null && _loading)
        {
            string sp = _theme.SpinnerGlyph(_animPhase, _visualOptions.ReducedMotion);
            rows.Add($"  {_theme.Style(_theme.Accent, $"{sp} Loading WSCTL workspace catalog...")}");
            return rows;
        }

        if (_wsctlProjects is not null && _wsctlProjects.Status != ProviderStatus.Available)
        {
            rows.AddRange(LayoutEngine.BuildErrorBox(
                _theme,
                $"WSCTL Unavailable ({_wsctlProjects.Error?.Code ?? "ERROR"})",
                _wsctlProjects.Error?.Message,
                w));
            return rows;
        }

        if (items.Count == 0)
        {
            rows.Add($"  {_theme.Style(_theme.Secondary, total == 0 ? "No WSCTL projects found." : $"No projects matching '{_projectFilter}'. Press Esc to clear.")}");
            return rows;
        }

        if (bp == LayoutBreakpoint.Narrow)
        {
            rows.AddRange(BuildProjectListLines(items, w, innerH));
            return rows;
        }

        int listW = Math.Clamp((int)(w * 0.48), 26, Math.Max(26, w - 34));
        int detailW = Math.Max(20, w - listW - 3);
        var listLines = BuildProjectListLines(items, listW, innerH);
        ProjectSummary current = items[Math.Clamp(_projectIndex, 0, items.Count - 1)];
        var detailLines = BuildProjectDetailLines(current, detailW, innerH);
        rows.AddRange(LayoutEngine.ComposeColumns(listLines, listW, detailLines, detailW, innerH, _theme));
        return rows;
    }

    private List<string> BuildProjectListLines(List<ProjectSummary> items, int w, int h)
    {
        var list = new List<string>(h);
        if (items.Count == 0 || h <= 0)
            return list;

        int sel = Math.Clamp(_projectIndex, 0, items.Count - 1);
        if (sel < _projectScroll) _projectScroll = sel;
        if (sel >= _projectScroll + h) _projectScroll = sel - h + 1;
        _projectScroll = Math.Clamp(_projectScroll, 0, Math.Max(0, items.Count - h));

        bool hasScroll = items.Count > h;
        int rowW = hasScroll ? Math.Max(14, w - 1) : w;
        bool mainActive = _focus == FocusZone.Main;

        // Detect duplicate full names or truncated prefixes so identical series entries remain distinguishable.
        var nameCounts = items
            .GroupBy(x => x.Name, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.Count(), StringComparer.OrdinalIgnoreCase);

        int approxNameBudget = Math.Max(10, rowW - 16);
        var prefixCounts = items
            .GroupBy(x => _theme.TruncateEnd(x.Name, approxNameBudget), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.Count(), StringComparer.OrdinalIgnoreCase);

        for (int i = _projectScroll; i < Math.Min(items.Count, _projectScroll + h); i++)
        {
            ProjectSummary p = items[i];
            bool isSel = i == sel;
            string ptr = isSel ? _theme.Style(_theme.Accent, _theme.FocusPointer) : " ";
            string dot = p.Accessible
                ? _theme.Style(_theme.Success, _theme.DotLive)
                : _theme.Style(_theme.Warning, _theme.IconWarn);

            string tagText = _theme.FormatEnvTag(string.IsNullOrWhiteSpace(p.Environment) ? p.Category : p.Environment);
            int nameMax = Math.Max(10, rowW - tagText.Length - 8);
            string baseTrunc = _theme.TruncateEnd(p.Name, nameMax);
            bool collides = nameCounts[p.Name] > 1 || prefixCounts[_theme.TruncateEnd(p.Name, approxNameBudget)] > 1;

            string styledName;
            if (collides)
            {
                string idHint = $" {_theme.MiddleDot} {p.Id}";
                int trimmedNameW = Math.Max(6, nameMax - idHint.Length);
                string nm = _theme.TruncateEnd(p.Name, trimmedNameW);
                styledName = _theme.Style(isSel ? _theme.Bold + _theme.Primary : _theme.Primary, nm)
                           + _theme.Style(_theme.MutedText, idHint);
            }
            else
            {
                styledName = _theme.Style(isSel ? _theme.Bold + _theme.Primary : _theme.Primary, baseTrunc);
            }

            string left = $" {ptr} {dot} {styledName}";
            int pad = Math.Max(1, rowW - DiffRenderer.MeasureVisibleLength(left) - tagText.Length - 1);
            string tagColor = p.Accessible ? _theme.Secondary : _theme.Warning;
            string rowContent = left + new string(' ', pad) + _theme.Style(tagColor, tagText) + " ";
            string rowPainted = isSel ? PaintRowBg(rowContent, rowW, mainActive) : rowContent;
            if (hasScroll)
            {
                string sbGlyph = LayoutEngine.ScrollbarGlyph(_theme, i - _projectScroll, h, items.Count, _projectScroll);
                rowPainted = DiffRenderer.PadVisible(rowPainted, rowW, resetBeforeFill: false) + sbGlyph;
            }
            list.Add(rowPainted);
        }

        return list;
    }

    private List<string> BuildProjectDetailLines(ProjectSummary p, int w, int h)
    {
        var lines = new List<string>(h)
        {
            $" {_theme.Style(_theme.Bold + _theme.Accent, _theme.TruncateEnd(p.Name, w - 2))}",
            $" {_theme.Style(_theme.MutedText, p.Id)} {_theme.Style(_theme.Border, _theme.MiddleDot)} {_theme.Style(_theme.Secondary, p.Category)}"
        };

        int valW = Math.Max(12, w - 11);
        lines.Add(LayoutEngine.FormatKeyValueRow(
            _theme,
            "Status",
            _theme.Style(p.Accessible ? _theme.Success : _theme.Warning, $"{p.Status} ({(p.Accessible ? "accessible" : "missing dir")})")));

        string envDetail = string.IsNullOrWhiteSpace(p.Environment) ? _theme.EmDash : p.Environment;
        lines.Add(LayoutEngine.FormatKeyValueRow(
            _theme,
            "Env",
            _theme.Style(_theme.Primary, _theme.TruncateEnd($"{envDetail} {_theme.MiddleDot} GPU: {p.Gpu} {_theme.MiddleDot} Git: {(p.Git ? "yes" : "no")}", valW))));

        if (p.FullPath.Length <= valW)
        {
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Path", _theme.Style(_theme.Secondary, p.FullPath)));
        }
        else if (h >= 12)
        {
            var pathLines = DesignTheme.WrapText(p.FullPath, valW, _theme.AsciiOnly);
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Path", _theme.Style(_theme.Secondary, pathLines[0])));
            if (pathLines.Count > 1)
                lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "", _theme.Style(_theme.Secondary, _theme.TruncateEnd(string.Join(" ", pathLines.Skip(1)), valW))));
        }
        else
        {
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Path", _theme.Style(_theme.Secondary, DesignTheme.TruncateMiddle(p.FullPath, valW))));
        }

        if (p.Languages is { Count: > 0 })
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Langs", _theme.Style(_theme.Secondary, _theme.TruncateEnd(string.Join(", ", p.Languages), valW))));

        if (p.Tags is { Count: > 0 })
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Tags", _theme.Style(_theme.MutedText, _theme.TruncateEnd(string.Join(", ", p.Tags), valW))));

        if (p.Actions.Count > 0)
        {
            lines.Add(LayoutEngine.FormatKeyValueRow(
                _theme,
                "Actions",
                _theme.Style(_theme.Secondary, $"{p.Actions.Count} registered (read-only metadata)")));

            var pills = p.Actions.Take(6).Select(a =>
            {
                string col = a.Risk.ToLowerInvariant() switch
                {
                    "modifying" => _theme.Warning,
                    "privileged" or "destructive" => _theme.Error,
                    "unspecified" => _theme.MutedText,
                    _ => _theme.Primary
                };
                return $"{_theme.Style(col, a.Name)} {_theme.Style(_theme.MutedText, $"[{a.Risk}]")}";
            }).ToList();

            string suffix = p.Actions.Count > 6 ? _theme.Style(_theme.MutedText, $" +{p.Actions.Count - 6}") : string.Empty;
            var curLine = new List<string>();
            int curLen = 0;
            for (int idx = 0; idx < pills.Count; idx++)
            {
                string pill = pills[idx];
                int pLen = DiffRenderer.MeasureVisibleLength(pill);
                int addLen = curLine.Count == 0 ? pLen : pLen + 2;
                if (curLine.Count > 0 && curLen + addLen > valW)
                {
                    lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "", string.Join("  ", curLine)));
                    curLine.Clear();
                    curLen = 0;
                }
                curLine.Add(pill);
                curLen += curLine.Count == 1 ? pLen : pLen + 2;
            }
            if (curLine.Count > 0)
                lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "", string.Join("  ", curLine) + suffix));
        }

        UlvoProjectInspection? cached = null;
        lock (_projectInspectCache)
            _projectInspectCache.TryGetValue(p.Id, out cached);

        if (string.Equals(_inspectingProjectId, p.Id, StringComparison.OrdinalIgnoreCase))
        {
            string sp = _theme.SpinnerGlyph(_animPhase, _visualOptions.ReducedMotion);
            lines.Add(string.Empty);
            lines.Add($" {_theme.Style(_theme.Accent, $"{sp} Running live ULVO inspection...")}");
        }
        else if (cached is not null)
        {
            bool settled = IsHighlightActive(_inspectSettledUntilTs);
            lines.Add(string.Empty);
            lines.Add($" {_theme.Style(settled ? _theme.Bold + _theme.Accent : _theme.Bold + _theme.Secondary, "ULVO INSPECTION")}");
            string stateCol = cached.Status == ProviderStatus.Available ? _theme.Success : _theme.Warning;
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "State", _theme.Style(stateCol, $"{cached.Status} ({cached.ComplianceVerdict ?? "n/a"})")));
            if (cached.PythonVersion is not null || cached.PythonManager is not null)
            {
                string pyStr = cached.PythonManager is not null
                    ? $"{cached.PythonVersion ?? "?"} via {cached.PythonManager}"
                    : cached.PythonVersion!;
                lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Python", _theme.Style(_theme.Primary, pyStr)));
            }
            if (cached.EnvStatus is not null)
                lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "EnvState", _theme.Style(_theme.Secondary, $"{cached.EnvStatus.State} (materialized={cached.EnvStatus.IsMaterialized})")));
        }
        else
        {
            lines.Add(string.Empty);
            lines.Add($" {_theme.Style(_theme.MutedText, $"Enter Inspect runtime {_theme.MiddleDot} o Command Palette")}");
        }

        return lines.Take(h).ToList();
    }

    private List<string> BuildEnvironmentsPane(int w, int h, LayoutBreakpoint bp)
    {
        var rows = new List<string>(h);
        var items = GetFilteredRuntimes();
        int total = _ulvoRuntimes?.ListedTotal ?? 0;

        if (bp == LayoutBreakpoint.Narrow && _envDetailOpen && items.Count > 0)
        {
            int selIdx = Math.Clamp(_envIndex, 0, items.Count - 1);
            UlvoListedProject sel = items[selIdx];
            string crumb = $" {_theme.Style(_theme.Accent, _theme.BackArrow)} {_theme.Style(_theme.Primary, $"Runtimes ({selIdx + 1}/{items.Count})")} {_theme.Style(_theme.MutedText, $"{_theme.MiddleDot} Esc Back")}";
            rows.Add(LayoutEngine.PaintSurfaceRow(crumb, w, _theme, _theme.CommandBarBg));
            rows.Add(_theme.Style(_theme.Border, new string(_theme.RuleH[0], w)));
            rows.AddRange(BuildRuntimeDetailLines(sel, w, Math.Max(2, h - 2)));
            return rows;
        }

        bool searchFocused = _focus == FocusZone.Search;
        string cursor = searchFocused ? _theme.Style(_theme.Accent, "▏") : string.Empty;
        string filterTxt = string.IsNullOrEmpty(_envFilter)
            ? (searchFocused ? cursor : _theme.Style(_theme.MutedText, "Type / to filter runtimes..."))
            : _theme.Style(_theme.Primary, _envFilter) + cursor;

        int listH = Math.Max(2, h - 2);
        if (items.Count > 0)
        {
            int eSel = Math.Clamp(_envIndex, 0, items.Count - 1);
            if (eSel < _envScroll) _envScroll = eSel;
            if (eSel >= _envScroll + listH) _envScroll = eSel - listH + 1;
            _envScroll = Math.Clamp(_envScroll, 0, Math.Max(0, items.Count - listH));
        }
        else
        {
            _envScroll = 0;
        }

        string rangeStr = items.Count > 0
            ? $"{Math.Min(items.Count, _envScroll + 1)}-{Math.Min(items.Count, _envScroll + listH)}/{items.Count}"
            : $"0/{total}";
        string summaryPill = _ulvoStatus is { Status: ProviderStatus.Available }
            ? _theme.Style(_theme.Secondary, $"{rangeStr} {_theme.MiddleDot} Enter inspects")
            : _theme.Style(_theme.Warning, "ULVO offline");

        string leftFilter = $" {_theme.Style(searchFocused ? _theme.Accent : _theme.Secondary, "/")} {filterTxt}";
        int maxLeft = Math.Max(14, w - DiffRenderer.MeasureVisibleLength(summaryPill) - 2);
        string leftTrimmed = DiffRenderer.ClampAndPad(leftFilter, maxLeft).TrimEnd();
        int gap = Math.Max(1, w - DiffRenderer.MeasureVisibleLength(leftTrimmed) - DiffRenderer.MeasureVisibleLength(summaryPill) - 1);
        string bar = leftTrimmed + new string(' ', gap) + summaryPill + " ";

        rows.Add(LayoutEngine.PaintSurfaceRow(bar, w, _theme, searchFocused ? _theme.FocusRowBg : _theme.CommandBarBg));
        rows.Add(_theme.Style(_theme.Border, new string(_theme.RuleH[0], w)));

        int innerH = Math.Max(2, h - 2);
        if (_ulvoRuntimes is null && _loading)
        {
            string sp = _theme.SpinnerGlyph(_animPhase, _visualOptions.ReducedMotion);
            rows.Add($"  {_theme.Style(_theme.Accent, $"{sp} Listing ULVO tracked runtimes...")}");
            return rows;
        }

        if (_ulvoStatus is not null && _ulvoStatus.Status != ProviderStatus.Available)
        {
            rows.AddRange(LayoutEngine.BuildErrorBox(
                _theme,
                $"ULVO Unavailable ({_ulvoStatus.Error?.Code ?? _ulvoStatus.Status.ToString()})",
                _ulvoStatus.Error?.Message,
                w));
            return rows;
        }

        if (items.Count == 0)
        {
            rows.Add($"  {_theme.Style(_theme.Secondary, total == 0 ? "No runtimes tracked by ULVO." : $"No runtimes matching '{_envFilter}'.")}");
            return rows;
        }

        if (bp == LayoutBreakpoint.Narrow)
        {
            rows.AddRange(BuildRuntimeListLines(items, w, innerH));
            return rows;
        }

        int listW = Math.Clamp((int)(w * 0.48), 26, Math.Max(26, w - 34));
        int detailW = Math.Max(20, w - listW - 3);
        var listLines = BuildRuntimeListLines(items, listW, innerH);
        var current = items[Math.Clamp(_envIndex, 0, items.Count - 1)];
        var detailLines = BuildRuntimeDetailLines(current, detailW, innerH);
        rows.AddRange(LayoutEngine.ComposeColumns(listLines, listW, detailLines, detailW, innerH, _theme));
        return rows;
    }

    private List<string> BuildRuntimeListLines(List<UlvoListedProject> items, int w, int h)
    {
        var list = new List<string>(h);
        if (items.Count == 0 || h <= 0)
            return list;

        int sel = Math.Clamp(_envIndex, 0, items.Count - 1);
        if (sel < _envScroll) _envScroll = sel;
        if (sel >= _envScroll + h) _envScroll = sel - h + 1;
        _envScroll = Math.Clamp(_envScroll, 0, Math.Max(0, items.Count - h));

        bool hasScroll = items.Count > h;
        int rowW = hasScroll ? Math.Max(14, w - 1) : w;
        bool mainFocused = _focus == FocusZone.Main;

        var nameCounts = items
            .GroupBy(x => x.Name, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.Count(), StringComparer.OrdinalIgnoreCase);

        for (int i = _envScroll; i < Math.Min(items.Count, _envScroll + h); i++)
        {
            UlvoListedProject item = items[i];
            bool isSel = i == sel;
            string ptr = isSel ? _theme.Style(_theme.Accent, _theme.FocusPointer) : " ";
            string dot = item.HasConnector ? _theme.Style(_theme.Success, _theme.DotLive) : _theme.Style(_theme.MutedText, _theme.DotIdle);
            string eco = _theme.FormatEcosystem(item.Ecosystem, 12);
            int nameMax = Math.Max(10, rowW - eco.Length - 8);

            string styledName;
            if (nameCounts[item.Name] > 1)
            {
                string parent = Path.GetFileName(Path.GetDirectoryName(item.CanonicalPath.TrimEnd('\\')) ?? string.Empty);
                string suffix = string.IsNullOrWhiteSpace(parent) ? string.Empty : $" ({parent})";
                string nm = _theme.TruncateEnd(item.Name, Math.Max(6, nameMax - suffix.Length));
                styledName = _theme.Style(isSel ? _theme.Bold + _theme.Primary : _theme.Primary, nm)
                           + _theme.Style(_theme.MutedText, suffix);
            }
            else
            {
                styledName = _theme.Style(isSel ? _theme.Bold + _theme.Primary : _theme.Primary, _theme.TruncateEnd(item.Name, nameMax));
            }

            string left = $" {ptr} {dot} {styledName}";
            int pad = Math.Max(1, rowW - DiffRenderer.MeasureVisibleLength(left) - eco.Length - 1);
            string rowContent = left + new string(' ', pad) + _theme.Style(_theme.Secondary, eco) + " ";
            string rowPainted = isSel ? PaintRowBg(rowContent, rowW, mainFocused) : rowContent;
            if (hasScroll)
            {
                string sbGlyph = LayoutEngine.ScrollbarGlyph(_theme, i - _envScroll, h, items.Count, _envScroll);
                rowPainted = DiffRenderer.PadVisible(rowPainted, rowW, resetBeforeFill: false) + sbGlyph;
            }
            list.Add(rowPainted);
        }

        return list;
    }

    private List<string> BuildRuntimeDetailLines(UlvoListedProject item, int w, int h)
    {
        int valW = Math.Max(12, w - 11);
        var lines = new List<string>(h)
        {
            $" {_theme.Style(_theme.Bold + _theme.Accent, _theme.TruncateEnd(item.Name, w - 2))}",
            $" {_theme.Style(_theme.MutedText, item.Id)} {_theme.Style(_theme.Border, _theme.MiddleDot)} {_theme.Style(_theme.Secondary, item.Ecosystem)}",
            LayoutEngine.FormatKeyValueRow(_theme, "Class", _theme.Style(_theme.Primary, item.Classification)),
            LayoutEngine.FormatKeyValueRow(_theme, "Reg", _theme.Style(_theme.Secondary, item.RegistrationState)),
            LayoutEngine.FormatKeyValueRow(_theme, "Connector", _theme.Style(item.HasConnector ? _theme.Success : _theme.Warning, item.HasConnector ? "present" : "missing")),
            LayoutEngine.FormatKeyValueRow(_theme, "Path", _theme.Style(_theme.Secondary, DesignTheme.TruncateMiddle(item.CanonicalPath, valW)))
        };

        if (item.Manifests.Count > 0)
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Manifests", _theme.Style(_theme.Primary, _theme.TruncateEnd(string.Join(", ", item.Manifests), valW))));

        UlvoProjectInspection? cached = null;
        lock (_envInspectCache)
            _envInspectCache.TryGetValue(item.CanonicalPath, out cached);

        if (string.Equals(_inspectingEnvPath, item.CanonicalPath, StringComparison.OrdinalIgnoreCase))
        {
            string sp = _theme.SpinnerGlyph(_animPhase, _visualOptions.ReducedMotion);
            lines.Add(string.Empty);
            lines.Add($" {_theme.Style(_theme.Accent, $"{sp} Probing live runtime & environment...")}");
        }
        else if (cached is not null)
        {
            bool settled = IsHighlightActive(_inspectSettledUntilTs);
            lines.Add(string.Empty);
            lines.Add($" {_theme.Style(settled ? _theme.Bold + _theme.Accent : _theme.Bold + _theme.Secondary, "VERIFIED INSPECTION")}");
            string stCol = cached.Status == ProviderStatus.Available ? _theme.Success : _theme.Warning;
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Verdict", _theme.Style(stCol, cached.ComplianceVerdict ?? cached.Status.ToString())));
            if (cached.PythonVersion is not null || cached.PythonManager is not null)
            {
                string pyStr = cached.PythonManager is not null
                    ? $"{cached.PythonVersion ?? "?"} via {cached.PythonManager}"
                    : cached.PythonVersion!;
                lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Python", _theme.Style(_theme.Primary, pyStr)));
            }
            if (cached.EnvironmentMode is not null)
                lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Mode", _theme.Style(_theme.Secondary, cached.EnvironmentMode)));
            if (cached.EnvStatus is not null)
                lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "EnvState", _theme.Style(_theme.Primary, $"{cached.EnvStatus.State} (materialized={cached.EnvStatus.IsMaterialized})")));
        }
        else
        {
            lines.Add(LayoutEngine.FormatKeyValueRow(_theme, "EnvCheck", _theme.Style(_theme.MutedText, "Not probed yet (Enter to inspect)")));
        }

        return lines.Take(h).ToList();
    }

    private List<string> BuildPalettePane(int w, int h, LayoutBreakpoint bp)
    {
        var rows = new List<string>(h);
        string cursor = _theme.Style(_theme.Accent, "▏");
        string queryView = string.IsNullOrEmpty(_paletteQuery)
            ? cursor + _theme.Style(_theme.MutedText, "Type capability or command (e.g. capabilities, health, suggest)...")
            : _theme.Style(_theme.Primary, _paletteQuery) + cursor;

        bool flashOpen = Volatile.Read(ref _paletteOpenedTs) != 0 && !_visualOptions.ReducedMotion;
        string promptMark = flashOpen
            ? _theme.Style(_theme.Bold + _theme.Accent, $"{_theme.FocusPointer} :")
            : _theme.Style(_theme.Bold + _theme.Accent, " :");
        rows.Add(LayoutEngine.PaintSurfaceRow($"{promptMark} {queryView}", w, _theme, _theme.FocusRowBg));
        rows.Add(_theme.Style(flashOpen ? _theme.Accent : _theme.Border, new string(_theme.RuleH[0], w)));

        var suggestions = GetSuggestions();
        (_, bool exactInput) = ResolvePaletteExecutionTarget(suggestions);
        string enterActionLabel = exactInput ? "Enter run exact" : "Enter run highlighted";

        int remain = Math.Max(1, h - 2);
        if (_paletteOutcome is null && !_paletteRunning)
        {
            AddSuggestionRows(rows, suggestions, w, remain, enterActionLabel);
            return rows;
        }

        int suggH = Math.Clamp(suggestions.Count + 1, 3, Math.Max(3, remain / 3));
        int resultH = Math.Max(3, remain - suggH - 1);
        _lastPaletteResultPageHeight = Math.Max(2, resultH - 1);

        AddSuggestionRows(rows, suggestions, w, suggH, enterActionLabel);
        rows.Add(_theme.Style(_theme.Border, new string(_theme.RuleH[0], w)));
        rows.AddRange(BuildPaletteResultRows(w, resultH));
        return rows.Take(h).ToList();
    }

    private void AddSuggestionRows(List<string> rows, IReadOnlyList<SuggestionItem> suggestions, int w, int maxRows, string enterActionLabel)
    {
        if (maxRows <= 0) return;
        int visibleSlots = Math.Max(1, maxRows - 1);
        int sel = suggestions.Count == 0 ? 0 : Math.Clamp(_paletteSuggestionIndex, 0, suggestions.Count - 1);
        if (sel < _paletteSuggestionScroll) _paletteSuggestionScroll = sel;
        if (sel >= _paletteSuggestionScroll + visibleSlots) _paletteSuggestionScroll = sel - visibleSlots + 1;
        _paletteSuggestionScroll = Math.Clamp(_paletteSuggestionScroll, 0, Math.Max(0, suggestions.Count - visibleSlots));

        string rangeTxt = suggestions.Count > visibleSlots
            ? $"{_paletteSuggestionScroll + 1}-{Math.Min(suggestions.Count, _paletteSuggestionScroll + visibleSlots)}/{suggestions.Count}"
            : $"{suggestions.Count}";
        rows.Add($" {_theme.Style(_theme.Secondary, $"SUGGESTIONS ({rangeTxt}) {_theme.MiddleDot} Tab complete {_theme.MiddleDot} {enterActionLabel}")}");

        bool hasScroll = suggestions.Count > visibleSlots;
        int rowW = hasScroll ? Math.Max(20, w - 1) : w;

        for (int i = _paletteSuggestionScroll; i < Math.Min(suggestions.Count, _paletteSuggestionScroll + visibleSlots); i++)
        {
            SuggestionItem s = suggestions[i];
            bool isSel = i == sel;
            string ptr = isSel ? _theme.Style(_theme.Accent, _theme.FocusPointer) : " ";
            string dot = s.Available ? _theme.Style(_theme.Success, _theme.DotLive) : _theme.Style(_theme.Warning, _theme.IconWarn);

            int cmdColW = Math.Clamp(w / 4, 16, 30);
            string cmdRaw = _theme.TruncateEnd(s.Command, cmdColW);
            string cmdStyled = _theme.Style(isSel ? _theme.Bold + _theme.Primary : _theme.Primary, cmdRaw.PadRight(cmdColW));

            string riskShort = string.Equals(s.Risk, "ReadOnly", StringComparison.OrdinalIgnoreCase) ? "RO" : s.Risk;
            string provTag = $"[{s.Provider} {_theme.MiddleDot} {riskShort}]".PadRight(14);
            string unavailTag = s.Available ? string.Empty : " [unavailable]";

            string metaBadges = _theme.Style(_theme.MutedText, provTag)
                              + (s.Available ? string.Empty : _theme.Style(_theme.Warning, unavailTag));

            string prefix = $" {ptr} {dot} {cmdStyled}  {metaBadges} ";
            int descMax = Math.Max(6, rowW - DiffRenderer.MeasureVisibleLength(prefix) - 1);
            string descText = string.IsNullOrWhiteSpace(s.Reason) ? s.DisplayName : s.Reason;
            string descStyled = _theme.Style(_theme.Secondary, _theme.TruncateEnd(descText, descMax));

            string line = prefix + descStyled;
            string painted = isSel ? PaintRowBg(line, rowW, focusedBg: true) : line;
            if (hasScroll)
            {
                string sbGlyph = LayoutEngine.ScrollbarGlyph(_theme, i - _paletteSuggestionScroll, visibleSlots, suggestions.Count, _paletteSuggestionScroll);
                painted = DiffRenderer.PadVisible(painted, rowW, resetBeforeFill: false) + sbGlyph;
            }
            rows.Add(painted);
        }
    }

    private List<string> BuildPaletteResultRows(int w, int h)
    {
        var lines = new List<string>(h);
        if (_paletteRunning)
        {
            string sp = _theme.SpinnerGlyph(_animPhase, _visualOptions.ReducedMotion);
            lines.Add($" {_theme.Style(_theme.Accent, $"{sp} Executing {_paletteExecutedCommand}...")}");
            return lines;
        }

        CapabilityEnvelope<object?> env = _paletteOutcome!.Envelope;
        string modeLabel = _paletteShowRawJson ? "Raw JSON" : "Structured";
        string statusBadge = env.Ok
            ? _theme.Style(_theme.Success, $"{_theme.IconOk} OK ({env.DurationMs}ms)")
            : _theme.Style(_theme.Error, $"{_theme.IconErr} ERR");

        if (!env.Ok && env.Error is not null)
        {
            lines.Add($" {_theme.Style(_theme.Bold + _theme.Accent, env.Capability)}  {statusBadge}");
            lines.AddRange(LayoutEngine.BuildErrorBox(_theme, env.Error.Code, env.Error.Message, w));
            return lines.Take(h).ToList();
        }

        var bodyAll = new List<string>();
        if (_paletteShowRawJson)
        {
            string json = JsonSerializer.Serialize(env, JsonDefaults.Readable);
            foreach (string rawLine in json.Split('\n').Take(400))
                bodyAll.Add($"  {_theme.Style(_theme.Secondary, _theme.TruncateEnd(rawLine.TrimEnd('\r'), w - 3))}");
        }
        else
        {
            bodyAll.AddRange(FormatStructuredOutcome(env, w, 200));
        }

        int bodyH = Math.Max(1, h - 1);
        _paletteResultScroll = Math.Clamp(_paletteResultScroll, 0, Math.Max(0, bodyAll.Count - bodyH));
        string scrollHint = bodyAll.Count > bodyH
            ? $" {_theme.MiddleDot} Lines {_paletteResultScroll + 1}-{Math.Min(bodyAll.Count, _paletteResultScroll + bodyH)}/{bodyAll.Count} {_theme.MiddleDot} PgUp/PgDn"
            : string.Empty;

        lines.Add($" {_theme.Style(_theme.Bold + _theme.Accent, env.Capability)}  {statusBadge}  {_theme.Style(_theme.MutedText, $"[{modeLabel} {_theme.MiddleDot} Ctrl+J toggle{scrollHint}]")}");
        lines.AddRange(bodyAll.Skip(_paletteResultScroll).Take(bodyH));
        return lines;
    }

    private List<string> FormatStructuredOutcome(CapabilityEnvelope<object?> env, int w, int maxRows)
    {
        var outLines = new List<string>();
        if (env.Data is null)
        {
            outLines.Add($"  {_theme.Style(_theme.MutedText, "(empty payload)")}");
            return outLines;
        }

        switch (env.Data)
        {
            case HealthPayload hp:
                outLines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Overall", _theme.Style(hp.OverallStatus == "healthy" ? _theme.Success : _theme.Warning, hp.OverallStatus)));
                outLines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Memory", _theme.Style(_theme.Primary, $"{hp.Machine.MemoryLoadPercent}% load, {hp.Machine.AvailableRamMb / 1024.0:F1} GB free")));
                (string dLbl, string dGlyph, string dCol) = _theme.FormatDoctorSummary(hp.Wsctl, false);
                outLines.Add(LayoutEngine.FormatKeyValueRow(_theme, "Doctor", _theme.Style(dCol, $"{dGlyph} {dLbl}")));
                outLines.Add(LayoutEngine.FormatKeyValueRow(_theme, "ULVO", _theme.Style(_theme.Primary, $"v{hp.Ulvo.Version ?? "?"} ({hp.Ulvo.RegisteredProjects} projects)")));
                return outLines;

            case ProjectsPayload pp:
                outLines.Add($"  {_theme.Style(_theme.Primary, $"Matched {pp.TotalMatched} projects (showing {pp.Returned})")}");
                foreach (object item in pp.Items.Take(Math.Max(1, maxRows - 1)))
                {
                    if (item is CompactProjectItem c)
                        outLines.Add($"   {_theme.Style(_theme.Accent, c.Id.PadRight(22))} {_theme.Style(_theme.Secondary, $"{c.Category} {_theme.MiddleDot} {_theme.FormatEnvTag(c.Environment)}")}");
                    else if (item is ProjectSummary p)
                        outLines.Add($"   {_theme.Style(_theme.Accent, p.Id.PadRight(22))} {_theme.Style(_theme.Secondary, p.Name)}");
                }
                return outLines;

            case UlvoRuntimesPayload rp:
                outLines.Add($"  {_theme.Style(_theme.Primary, $"ULVO {rp.Summary.Status} {_theme.MiddleDot} Listed {rp.ListedTotal} projects")}");
                foreach (var p in rp.Projects.Take(Math.Max(1, maxRows - 1)))
                    outLines.Add($"   {_theme.Style(_theme.Accent, _theme.TruncateEnd(p.Name, 24).PadRight(24))} {_theme.Style(_theme.Secondary, $"{p.Ecosystem} {_theme.MiddleDot} {p.Classification}")}");
                return outLines;

            default:
                JsonElement el = JsonSerializer.SerializeToElement(env.Data, JsonDefaults.Compact);
                if (el.ValueKind == JsonValueKind.Object)
                {
                    if (el.TryGetProperty("capabilities", out JsonElement caps) && caps.ValueKind == JsonValueKind.Array)
                    {
                        foreach (JsonElement c in caps.EnumerateArray().Take(maxRows))
                        {
                            string id = c.TryGetProperty("id", out var idP) ? idP.GetString() ?? "" : "";
                            string prov = c.TryGetProperty("provider", out var prP) ? prP.GetString() ?? "" : "";
                            string cmd = c.TryGetProperty("cliCommand", out var cmdP) ? cmdP.GetString() ?? "" : "";
                            string av = c.TryGetProperty("availability", out var avP) ? avP.GetString() ?? "" : "";
                            string avCol = av == "available" ? _theme.Success : _theme.Warning;
                            outLines.Add($"  {_theme.Style(_theme.Accent, id.PadRight(22))} {_theme.Style(_theme.MutedText, prov.PadRight(8))} {_theme.Style(_theme.Primary, _theme.TruncateEnd(cmd, Math.Max(12, w - 48)).PadRight(Math.Clamp(w - 48, 12, 32)))} {_theme.Style(avCol, $"[{av}]")}");
                        }
                        return outLines;
                    }
                    if (el.TryGetProperty("suggestions", out JsonElement suggs) && suggs.ValueKind == JsonValueKind.Array)
                    {
                        foreach (JsonElement s in suggs.EnumerateArray().Take(maxRows))
                        {
                            string cmd = s.TryGetProperty("command", out var cP) ? cP.GetString() ?? "" : "";
                            string reason = s.TryGetProperty("reason", out var rP) ? rP.GetString() ?? "" : "";
                            outLines.Add($"  {_theme.Style(_theme.Primary, _theme.TruncateEnd(cmd, 28).PadRight(28))} {_theme.Style(_theme.Secondary, _theme.TruncateEnd(reason, Math.Max(10, w - 33)))}");
                        }
                        return outLines;
                    }
                    foreach (JsonProperty prop in el.EnumerateObject().Take(maxRows))
                    {
                        string val = prop.Value.ValueKind is JsonValueKind.String or JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False
                            ? prop.Value.ToString()
                            : $"[{prop.Value.ValueKind}]";
                        outLines.Add(LayoutEngine.FormatKeyValueRow(_theme, prop.Name, _theme.Style(_theme.Primary, _theme.TruncateEnd(val, Math.Max(12, w - 16))), 12));
                    }
                }
                return outLines;
        }
    }

    private List<string> BuildHelpPane(int w, int h)
    {
        var allLines = new List<string>(32);
        const int keyCol = 15;
        int descMax = Math.Max(16, w - keyCol - 4);

        void AddHelpRow(string key, string desc)
        {
            var wrapped = DesignTheme.WrapText(desc, descMax, _theme.AsciiOnly);
            allLines.Add("  " + LayoutEngine.FormatKeyHintAligned(_theme, key, wrapped[0], keyCol));
            for (int i = 1; i < wrapped.Count; i++)
                allLines.Add("  " + new string(' ', keyCol + 1) + _theme.Style(_theme.Secondary, wrapped[i]));
        }

        string ctxName = _returnScreen switch
        {
            TuiScreen.Projects => "Projects",
            TuiScreen.Environments => "Runtimes",
            TuiScreen.Palette => "Command Palette",
            _ => "Overview"
        };

        allLines.Add($" {_theme.Style(_theme.Bold + _theme.Accent, "KEYBOARD & INTERACTION GUIDE")}");
        allLines.Add(string.Empty);
        allLines.Add($" {_theme.Style(_theme.Bold + _theme.Secondary, $"Active Context ({ctxName})")}");
        switch (_returnScreen)
        {
            case TuiScreen.Projects:
                AddHelpRow("/ Filter", "Filter projects by name, ID, category, or env (all keys captured)");
                AddHelpRow("Enter", "Inspect selected project runtime via ULVO (or open Detail on narrow)");
                AddHelpRow("o", "Open selected project context inside Command Palette");
                AddHelpRow("Esc", "Close narrow Detail, clear active filter, or return to Overview");
                break;
            case TuiScreen.Environments:
                AddHelpRow("/ Filter", "Filter tracked ULVO runtimes by name, ecosystem, or path");
                AddHelpRow("Enter", "Probe selected runtime environment health on demand");
                AddHelpRow("Esc", "Close narrow Detail, clear active filter, or return to Overview");
                break;
            default:
                AddHelpRow($"{_theme.Arrows} / j k", "Move between Workflows and Snapshot items on Overview");
                AddHelpRow("Enter", "Execute highlighted workflow or jump to highlighted project");
                AddHelpRow("/", "Jump directly to Projects filter bar");
                break;
        }

        allLines.Add(string.Empty);
        allLines.Add($" {_theme.Style(_theme.Bold + _theme.Secondary, "Global Navigation")}");
        AddHelpRow("1 / 2 / 3", "Switch between Overview, Projects, and Runtimes");
        AddHelpRow("4 / : / Ctrl+K", "Open Command Palette & fuzzy suggestions");
        AddHelpRow("Tab / <- ->", "Cycle keyboard focus between Navigation Sidebar and Main Pane");
        AddHelpRow($"{_theme.Arrows} / j k", "Move row selection (plus PgUp / PgDn / Home / End)");
        AddHelpRow("Esc / ?", "Close Help and return to previous screen");

        allLines.Add(string.Empty);
        allLines.Add($" {_theme.Style(_theme.Bold + _theme.Secondary, "Palette, Display & Safety")}");
        AddHelpRow("Ctrl+J", "Toggle Structured view vs Raw JSON in Command Palette");
        AddHelpRow("PgUp / PgDn", "Scroll Command Palette result output or Help guide");
        AddHelpRow("Ctrl+U", "Clear active search or Command Palette query");
        AddHelpRow("r / m", $"Refresh live telemetry {_theme.MiddleDot} Toggle reduced motion ({(_visualOptions.ReducedMotion ? "ON" : "OFF")})");
        AddHelpRow("q / Ctrl+C", "Quit cleanly and restore terminal buffer, cursor, and modes");

        allLines.Add(string.Empty);
        string modeSummary = $"Motion: {(_visualOptions.ReducedMotion ? "Reduced" : "Normal")} {_theme.MiddleDot} Color: {(_visualOptions.NoColor ? "OFF" : "TrueColor")} {_theme.MiddleDot} Glyphs: {(_visualOptions.AsciiOnly ? "ASCII" : "Unicode")}";
        allLines.Add($"  {_theme.Style(_theme.MutedText, _theme.TruncateEnd(modeSummary, Math.Max(16, w - 3)))}");

        _lastHelpPageHeight = h;
        _helpScroll = Math.Clamp(_helpScroll, 0, Math.Max(0, allLines.Count - h));
        if (allLines.Count <= h)
            return allLines;

        var view = allLines.Skip(_helpScroll).Take(h).ToList();
        return view;
    }

    private string BuildFooterLine(int width, LayoutBreakpoint bp)
    {
        string hints = _screen == TuiScreen.Palette
            ? $"{LayoutEngine.FormatKeyHint(_theme, _theme.Arrows, "Pick")}  {LayoutEngine.FormatKeyHint(_theme, "Tab", "Fill")}  {LayoutEngine.FormatKeyHint(_theme, "Enter", "Run")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+J", "JSON")}  {LayoutEngine.FormatKeyHint(_theme, "Esc", "Back")}"
            : _focus == FocusZone.Search
            ? $"{LayoutEngine.FormatKeyHint(_theme, "Enter", "Keep")}  {LayoutEngine.FormatKeyHint(_theme, "Ctrl+U", "Clear")}  {LayoutEngine.FormatKeyHint(_theme, "Esc", "Cancel")}"
            : bp == LayoutBreakpoint.Narrow && ((_screen == TuiScreen.Projects && _projectDetailOpen) || (_screen == TuiScreen.Environments && _envDetailOpen))
            ? $"{LayoutEngine.FormatKeyHint(_theme, "Esc", "Back")}  {LayoutEngine.FormatKeyHint(_theme, "Enter", "Inspect")}  {LayoutEngine.FormatKeyHint(_theme, ":", "Cmd")}  {LayoutEngine.FormatKeyHint(_theme, "q", "Quit")}"
            : _screen switch
            {
                TuiScreen.Help => $"{LayoutEngine.FormatKeyHint(_theme, _theme.Arrows, "Scroll")}  {LayoutEngine.FormatKeyHint(_theme, "m", "Motion")}  {LayoutEngine.FormatKeyHint(_theme, "Esc", "Back")}  {LayoutEngine.FormatKeyHint(_theme, "q", "Quit")}",
                _ => bp == LayoutBreakpoint.Narrow
                    ? $"{LayoutEngine.FormatKeyHint(_theme, "1-3", "Views")}  {LayoutEngine.FormatKeyHint(_theme, "/", "Find")}  {LayoutEngine.FormatKeyHint(_theme, ":", "Cmd")}  {LayoutEngine.FormatKeyHint(_theme, "?", "Help")}  {LayoutEngine.FormatKeyHint(_theme, "q", "Quit")}"
                    : $"{LayoutEngine.FormatKeyHint(_theme, "Tab", "Focus")}  {LayoutEngine.FormatKeyHint(_theme, "1-3", "Views")}  {LayoutEngine.FormatKeyHint(_theme, "/", "Find")}  {LayoutEngine.FormatKeyHint(_theme, ":", "Cmd")}  {LayoutEngine.FormatKeyHint(_theme, "r", "Sync")}  {LayoutEngine.FormatKeyHint(_theme, "?", "Help")}  {LayoutEngine.FormatKeyHint(_theme, "q", "Quit")}"
            };

        if (bp == LayoutBreakpoint.Narrow)
            return " " + hints;

        string status = _theme.Style(_theme.MutedText, _theme.TruncateEnd(_statusMessage, Math.Max(12, width / 3)));
        int hLen = DiffRenderer.MeasureVisibleLength(hints) + 1;
        int sLen = DiffRenderer.MeasureVisibleLength(status);
        int gap = width - hLen - sLen - 1;
        if (gap < 2)
            return " " + hints;

        return " " + hints + new string(' ', gap) + status + " ";
    }

    private string PaintRowBg(string content, int width, bool focusedBg)
        => LayoutEngine.PaintSurfaceRow(content, width, _theme, focusedBg ? _theme.FocusRowBg : _theme.InactiveRowBg);
}

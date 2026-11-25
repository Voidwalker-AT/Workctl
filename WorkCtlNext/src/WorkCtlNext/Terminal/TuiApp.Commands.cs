using System.Diagnostics;
using WorkCtlNext.Core;

namespace WorkCtlNext.Terminal;

public sealed partial class TuiApp
{
    public void RefreshFilesView(bool resetScroll = false)
    {
        IReadOnlyCollection<string> projPaths = _session.RegisteredProjectPaths;
        FsDirectoryListing listing = _dispatcher.FileSystem.ListDirectory(
            _session.ActiveDirectory,
            maxEntries: 1000,
            registeredProjectPaths: projPaths);
        _fsListing = listing;

        List<FsEntry> filtered = GetFilteredFileEntries();
        int idx = _session.GetSelectionIndex(_session.CurrentSection);
        if (filtered.Count == 0)
        {
            idx = 0;
            _fsScroll = 0;
            _session.SelectedFileEntry = null;
            _fsSelectedMeta = null;
            _fsSelectedPreview = null;
        }
        else
        {
            idx = Math.Clamp(idx, 0, filtered.Count - 1);
            if (resetScroll)
                _fsScroll = 0;
            _session.SetSelectionIndex(_session.CurrentSection, idx);
            _session.SelectedFileEntry = filtered[idx];
            RefreshSelectedFileInspection(filtered[idx]);
        }
    }

    private void RefreshSelectedFileInspection(FsEntry entry)
    {
        if (entry.Kind is FsEntryKind.Drive or FsEntryKind.QuickLink)
        {
            _fsSelectedMeta = null;
            _fsSelectedPreview = null;
            return;
        }

        _fsSelectedMeta = _dispatcher.FileSystem.InspectPath(entry.FullPath, _session.RegisteredProjectPaths);
        if (!entry.IsDirectory && !entry.IsReparsePoint)
            _fsSelectedPreview = _dispatcher.FileSystem.PreviewFile(entry.FullPath, maxBytes: 32 * 1024, maxLines: 60);
        else
            _fsSelectedPreview = null;
    }

    public List<FsEntry> GetFilteredFileEntries()
    {
        FsDirectoryListing? listing = _fsListing;
        if (listing is null)
            return [];

        if (string.IsNullOrWhiteSpace(_fsFilter))
            return listing.Entries.ToList();

        return listing.Entries
            .Where(e => e.Name.Contains(_fsFilter, StringComparison.OrdinalIgnoreCase))
            .ToList();
    }

    private FsEntry? GetHighlightedFileEntry()
    {
        List<FsEntry> entries = GetFilteredFileEntries();
        if (entries.Count == 0)
            return null;
        int idx = Math.Clamp(_session.GetSelectionIndex(_session.CurrentSection), 0, entries.Count - 1);
        return entries[idx];
    }

    private IReadOnlyList<string> GetEffectiveFileTargetPaths()
    {
        if (_session.MultiSelectedPaths.Count > 0)
            return _session.MultiSelectedPaths.ToArray();

        FsEntry? cur = GetHighlightedFileEntry();
        if (cur is not null && cur.Kind is not FsEntryKind.Drive and not FsEntryKind.QuickLink)
            return [cur.FullPath];

        return Array.Empty<string>();
    }

    private void RefreshActiveSectionTelemetry(CancellationToken ct, bool forceAsync = true)
    {
        NavigationSectionId section = _session.CurrentSection;
        switch (section)
        {
            case NavigationSectionId.MachineProcesses:
                RefreshProcessManagerSnapshot();
                break;
            case NavigationSectionId.MachineStorage:
                _storage = _dispatcher.Telemetry.GetStorageSnapshot();
                break;
            case NavigationSectionId.MachineNetwork:
                _network = _dispatcher.Telemetry.GetNetworkSnapshot();
                break;
            case NavigationSectionId.AppsRunning:
                _runningApps = _dispatcher.Telemetry.GetRunningApps(40);
                break;
            case NavigationSectionId.MachinePerformance:
                if (forceAsync)
                    _ = Task.Run(async () =>
                    {
                        try { _performance = await _dispatcher.Telemetry.GetPerformanceSnapshotAsync(ct).ConfigureAwait(false); }
                        catch { }
                    }, CancellationToken.None);
                break;
            case NavigationSectionId.DevGit:
                if (forceAsync)
                {
                    string dir = FileSystemService.IsVirtualPath(_session.ActiveDirectory)
                        ? _dispatcher.Config.WorkspaceRoot
                        : _session.ActiveDirectory;
                    _ = Task.Run(async () =>
                    {
                        try { _gitStatus = await _dispatcher.Git.GetStatusAsync(dir, ct).ConfigureAwait(false); }
                        catch { }
                    }, CancellationToken.None);
                }
                break;
            case NavigationSectionId.FilesThisPc:
            case NavigationSectionId.FilesQuickAccess:
            case NavigationSectionId.FilesWorkspace:
            case NavigationSectionId.FilesDownloads:
                RefreshFilesView();
                break;
        }
    }

    private void NavigateToSection(NavigationSectionId section, CancellationToken ct, bool focusMain = false)
    {
        _screen = TuiScreen.Home;
        _fsDetailOpen = false;
        _projectDetailOpen = false;
        _envDetailOpen = false;
        _processDetailOpen = false;
        if (_focus == FocusZone.Search)
            _focus = FocusZone.Main;

        _session.NavigateToSection(section);
        if (focusMain || _session.TreeCollapsed || DesignTheme.GetBreakpoint(_backend.WindowWidth) == LayoutBreakpoint.Narrow)
            _session.Focus = FocusRegion.MainPane;

        SyncTreeCursorToCurrentSection();
        SyncCompatibilityAliasesFromSession();
        RefreshActiveSectionTelemetry(ct);
        SyncControlCHandling();
    }

    private void UpdateCompletionSuggestions()
    {
        IReadOnlyList<ProjectSummary> projects = _wsctlProjects?.Projects ?? Array.Empty<ProjectSummary>();
        var req = new CompletionRequest(
            Input: _session.CommandInput,
            CursorIndex: _session.CommandCursorIndex,
            ActiveDirectory: _session.ActiveDirectory,
            Projects: projects,
            Capabilities: _capabilities,
            CurrentSection: _session.CurrentSection,
            MaxItems: 10,
            ActiveProject: _session.ActiveProject,
            Tools: _tools,
            Processes: _processList?.AllProcesses ?? _processList?.TopProcesses);

        _completion = _completionEngine.Compute(req);
        _completionIndex = _completion.Items.Count == 0
            ? 0
            : Math.Clamp(_completionIndex, 0, _completion.Items.Count - 1);
    }

    private void FocusCommandLine(char promptChar, string? initialText = "")
    {
        _commandPromptChar = promptChar;
        _session.Focus = FocusRegion.CommandLine;
        if (initialText is not null)
        {
            _session.CommandInput = initialText;
            _session.CommandCursorIndex = initialText.Length;
        }
        else
        {
            _session.CommandCursorIndex = Math.Clamp(_session.CommandCursorIndex, 0, _session.CommandInput.Length);
        }
        _completionDropdownOpen = promptChar == ':' || !string.IsNullOrEmpty(_session.CommandInput);
        _completionIndex = 0;
        _historyBrowsing = false;
        if (promptChar == ':')
            _commandDrawerOpen = false;
        UpdateCompletionSuggestions();
        SyncCompatibilityAliasesFromSession();
        SyncControlCHandling();
    }

    private bool AcceptCompletionSelection()
    {
        if (_completion is null || _completion.Items.Count == 0)
            return false;

        int idx = Math.Clamp(_completionIndex, 0, _completion.Items.Count - 1);
        CompletionCandidate chosen = _completion.Items[idx];
        string updated = DeterministicCompletionEngine.ApplyCompletion(_completion, chosen);
        _session.CommandInput = updated;
        _session.CommandCursorIndex = updated.Length;
        UpdateCompletionSuggestions();
        return true;
    }

    private void CopySelectionToClipboard(bool cut)
    {
        IReadOnlyList<string> targets = GetEffectiveFileTargetPaths();
        if (targets.Count == 0)
        {
            SetToastResult(false, cut ? "cut" : "copy", "No copyable file or folder selected.", [], "EMPTY_SELECTION");
            return;
        }

        if (cut)
        {
            foreach (string path in targets)
            {
                ProtectionAssessment assess = _dispatcher.FileSystem.Policy.Assess(
                    path, FsOperationKind.MoveOrRename, _session.RegisteredProjectPaths);
                if (assess.Tier == FsProtectionTier.Blocked)
                {
                    OpenProtectedBlockedModal("Cut Blocked by ProtectedPathPolicy", assess.NormalizedPath, assess.Reason!);
                    return;
                }
            }
        }

        _session.SetClipboard(cut ? ClipboardMode.Cut : ClipboardMode.Copy, targets);
        string verb = cut ? "Cut" : "Copied";
        SetToastResult(true, cut ? "cut" : "copy",
            $"{verb} {targets.Count} item(s) to internal clipboard (Ctrl+V in target folder to paste).",
            targets.Take(5).ToArray(), null);
    }

    private void OpenPasteConfirmationModal(string? explicitDestDir = null)
    {
        if (!_session.Clipboard.HasItems)
        {
            SetToastResult(false, "paste", "Internal file clipboard is empty. Use Ctrl+C or Ctrl+X on files first.", [], "CLIPBOARD_EMPTY");
            return;
        }

        string destDir = string.IsNullOrWhiteSpace(explicitDestDir)
            ? _session.ActiveDirectory
            : _dispatcher.FileSystem.ResolvePathRelativeTo(explicitDestDir, _session.ActiveDirectory);

        if (FileSystemService.IsVirtualPath(destDir) || !Directory.Exists(PathNormalizer.EnsureLongPathPrefix(destDir)))
        {
            SetToastResult(false, "paste", $"Cannot paste into '{destDir}'. Navigate to a valid directory first.", [], "INVALID_DESTINATION");
            return;
        }

        bool isMove = _session.Clipboard.Mode == ClipboardMode.Cut;
        FsOperationKind opKind = isMove ? FsOperationKind.MoveOrRename : FsOperationKind.CopyDestination;
        var lines = new List<string>
        {
            $"Action: {(isMove ? "MOVE (Cut -> Paste)" : "COPY (Clipboard -> Destination)")}",
            $"Destination: {destDir}",
            $"Items ({_session.Clipboard.Paths.Count}):"
        };

        bool elevated = false;
        foreach (string src in _session.Clipboard.Paths.Take(5))
        {
            string dstItem = Path.Combine(destDir, Path.GetFileName(src));
            ProtectionAssessment dstAssess = _dispatcher.FileSystem.Policy.Assess(dstItem, opKind, _session.RegisteredProjectPaths);
            if (dstAssess.Tier == FsProtectionTier.Blocked)
            {
                OpenProtectedBlockedModal("Paste Blocked by ProtectedPathPolicy", dstItem, dstAssess.Reason!);
                return;
            }
            if (dstAssess.Tier == FsProtectionTier.Warn)
                elevated = true;

            bool conflict = File.Exists(dstItem) || Directory.Exists(dstItem);
            string tag = conflict ? " [CONFLICT: exists]" : string.Empty;
            lines.Add($"  • {Path.GetFileName(src)}{tag}");
        }
        if (_session.Clipboard.Paths.Count > 5)
            lines.Add($"  … and {_session.Clipboard.Paths.Count - 5} more");

        ProtectionAssessment dirAssess = _dispatcher.FileSystem.Policy.Assess(destDir, opKind, _session.RegisteredProjectPaths);
        if (dirAssess.Tier == FsProtectionTier.Warn)
        {
            elevated = true;
            lines.Add($"Warning: {dirAssess.Reason}");
        }

        _modal = new ActiveModalState
        {
            Kind = ModalKind.ConfirmPaste,
            Title = isMove ? "Confirm Move (Paste)" : "Confirm Copy (Paste)",
            MessageLines = lines,
            RequireElevatedConfirm = elevated,
            TargetPaths = _session.Clipboard.Paths,
            DestinationDirectory = destDir,
            IsMove = isMove
        };
        SyncControlCHandling();
    }

    private void OpenDeleteConfirmationModal(IReadOnlyList<string>? explicitTargets = null, bool permanent = false)
    {
        IReadOnlyList<string> targets = explicitTargets is { Count: > 0 }
            ? explicitTargets
            : GetEffectiveFileTargetPaths();

        if (targets.Count == 0)
        {
            SetToastResult(false, "delete", "No file or folder selected to delete.", [], "EMPTY_SELECTION");
            return;
        }

        bool elevated = permanent;
        var lines = new List<string>();
        foreach (string path in targets)
        {
            ProtectionAssessment assess = _dispatcher.FileSystem.Policy.Assess(
                path, FsOperationKind.Delete, _session.RegisteredProjectPaths);
            if (assess.Tier == FsProtectionTier.Blocked)
            {
                OpenProtectedBlockedModal("Delete Blocked by ProtectedPathPolicy", assess.NormalizedPath, assess.Reason!);
                return;
            }
            if (assess.Tier == FsProtectionTier.Warn)
                elevated = true;
        }

        int reparseCount = 0;
        foreach (string path in targets.Take(5))
        {
            bool isReparse = false;
            try { isReparse = File.GetAttributes(PathNormalizer.EnsureLongPathPrefix(path)).HasFlag(FileAttributes.ReparsePoint); }
            catch { }
            if (isReparse) reparseCount++;

            string tag = isReparse ? " [Reparse/Junction -> unlink link ONLY, target preserved]" : string.Empty;
            lines.Add($"  • {Path.GetFileName(path)}{tag}");
        }
        if (targets.Count > 5)
            lines.Add($"  … and {targets.Count - 5} more");

        lines.Insert(0, reparseCount == targets.Count
            ? "Mode: Unlink reparse point(s) safely (linked target preserved)."
            : (permanent ? "Mode: PERMANENT DELETE (cannot be undone)." : "Mode: Recoverable Windows Recycle Bin (junctions unlinked only)."));

        if (elevated)
            lines.Add("PROTECTED/PROJECT LOCATION: confirm explicitly before proceeding.");

        _modal = new ActiveModalState
        {
            Kind = ModalKind.ConfirmDelete,
            Title = permanent ? "Confirm Permanent Delete" : "Confirm Delete to Recycle Bin",
            MessageLines = lines,
            RequireElevatedConfirm = elevated,
            TargetPaths = targets,
            PermanentDelete = permanent
        };
        SyncControlCHandling();
    }

    private void OpenRenameModal(string? explicitPath = null)
    {
        string? target = explicitPath ?? GetHighlightedFileEntry()?.FullPath;
        FsEntry? cur = GetHighlightedFileEntry();
        if (string.IsNullOrWhiteSpace(target) || (explicitPath is null && cur?.Kind is FsEntryKind.Drive or FsEntryKind.QuickLink))
        {
            SetToastResult(false, "rename", "Select a concrete file or directory to rename.", [], "EMPTY_SELECTION");
            return;
        }

        string norm = PathNormalizer.NormalizeDisplayPath(target);
        ProtectionAssessment assess = _dispatcher.FileSystem.Policy.Assess(
            norm, FsOperationKind.MoveOrRename, _session.RegisteredProjectPaths);
        if (assess.Tier == FsProtectionTier.Blocked)
        {
            OpenProtectedBlockedModal("Rename Blocked by ProtectedPathPolicy", assess.NormalizedPath, assess.Reason!);
            return;
        }

        string leaf = Path.GetFileName(norm);
        _modal = new ActiveModalState
        {
            Kind = ModalKind.PromptRename,
            Title = "Rename Item",
            MessageLines = [$"Target: {norm}", assess.Tier == FsProtectionTier.Warn ? $"Warning: {assess.Reason}" : "Enter new filename:"],
            InputValue = leaf,
            InputCursor = leaf.Length,
            PendingRenameSource = norm
        };
        SyncControlCHandling();
    }

    private void OpenMkdirModal()
    {
        if (FileSystemService.IsVirtualPath(_session.ActiveDirectory))
        {
            SetToastResult(false, "mkdir", "Cannot create directory inside virtual view. Navigate to a drive or folder first.", [], "INVALID_DESTINATION");
            return;
        }

        ProtectionAssessment assess = _dispatcher.FileSystem.Policy.Assess(
            _session.ActiveDirectory, FsOperationKind.CreateDirectory, _session.RegisteredProjectPaths);
        if (assess.Tier == FsProtectionTier.Blocked)
        {
            OpenProtectedBlockedModal("New Folder Blocked by ProtectedPathPolicy", assess.NormalizedPath, assess.Reason!);
            return;
        }

        _modal = new ActiveModalState
        {
            Kind = ModalKind.PromptMkdir,
            Title = "Create Directory",
            MessageLines = [$"Parent: {_session.ActiveDirectory}", "Enter new folder name:"],
            InputValue = string.Empty,
            InputCursor = 0,
            DestinationDirectory = _session.ActiveDirectory
        };
        SyncControlCHandling();
    }

    private void OpenProtectedBlockedModal(string title, string path, string reason)
    {
        _modal = new ActiveModalState
        {
            Kind = ModalKind.ProtectedBlocked,
            Title = title,
            MessageLines = [$"Path: {path}", $"Reason: {reason}", "Press Enter or Esc to dismiss."]
        };
        SetToastResult(false, "policy", reason, [path], "POLICY_BLOCKED");
        SyncControlCHandling();
    }

    private void OpenKillProcessModal(int pid, long expectedCreatedTicks = 0, string? expectedName = null, string? expectedExe = null)
    {
        ProcessImpactAssessment impact = _dispatcher.ProcessTermination.AnalyzeImpact(pid, expectedCreatedTicks, expectedName, expectedExe);
        if (!impact.ProcessExists || impact.PidReused || !impact.CanTerminate)
        {
            var blockedLines = new List<string>
            {
                $"Target: {impact.ExpectedIdentity.Name} (PID {impact.ExpectedIdentity.Pid})",
                $"Status: {impact.BlockReason ?? "Action unavailable."}"
            };
            blockedLines.AddRange(impact.VerifiedRelationships.Take(4));
            _modal = new ActiveModalState
            {
                Kind = ModalKind.ConfirmTerminateStep1,
                Title = impact.PidReused ? "Process Termination Aborted (PID Reused)" : "Termination Unavailable (Guarded)",
                MessageLines = blockedLines,
                ProcessImpact = impact
            };
            SetToastResult(false, $"kill {pid}", impact.BlockReason ?? "Termination blocked.", [], impact.PidReused ? "PID_REUSED" : "PROTECTED_PROCESS");
            SyncControlCHandling();
            return;
        }

        _modal = new ActiveModalState
        {
            Kind = ModalKind.ConfirmTerminateStep1,
            Title = $"Terminate Process — Step 1 Impact Preview ({impact.ExpectedIdentity.Name})",
            MessageLines = Array.Empty<string>(),
            ProcessImpact = impact
        };
        SyncControlCHandling();
    }

    private void TransitionKillModalToForceStep2(ProcessImpactAssessment impact)
    {
        _modal = new ActiveModalState
        {
            Kind = ModalKind.ConfirmTerminateForceStep2,
            Title = $"FINAL CONFIRMATION — Force Kill PID {impact.ExpectedIdentity.Pid}",
            MessageLines =
            [
                $"Target: {impact.ExpectedIdentity.Name} (PID {impact.ExpectedIdentity.Pid})",
                "Force termination (TerminateProcess) cannot be undone and discards unsaved state.",
                $"Type KILL {impact.ExpectedIdentity.Pid} and press Enter to execute:"
            ],
            InputValue = string.Empty,
            InputCursor = 0,
            RequireElevatedConfirm = true,
            ProcessImpact = impact
        };
        SyncControlCHandling();
    }

    private async Task<bool> ConfirmActiveModalAsync(CancellationToken ct)
    {
        ActiveModalState? m = _modal;
        if (m is null)
            return false;

        if (m.Kind == ModalKind.ProtectedBlocked)
        {
            _modal = null;
            SyncControlCHandling();
            return true;
        }

        if (m.Kind == ModalKind.PromptMkdir)
        {
            string name = m.InputValue.Trim();
            if (string.IsNullOrWhiteSpace(name))
            {
                m.ErrorHint = "Folder name cannot be empty.";
                return true;
            }

            var req = new CapabilityInvocationRequest(
                CapabilityId: "fs.mkdir",
                TargetPath: name,
                WorkingDirectory: _session.ActiveDirectory,
                Confirmed: true,
                RegisteredProjectPaths: _session.RegisteredProjectPaths,
                Caller: CallerSurface.HumanTui);
            DispatchOutcome outcome = await _dispatcher.DispatchAsync(req, ct).ConfigureAwait(false);
            ApplyMutationOutcome("mkdir", outcome);
            if (outcome.Envelope.Ok)
            {
                _modal = null;
                RefreshFilesView();
            }
            else
            {
                m.ErrorHint = outcome.Envelope.Error?.Message ?? "Failed to create directory.";
            }
            SyncControlCHandling();
            return true;
        }

        if (m.Kind == ModalKind.PromptRename)
        {
            string newName = m.InputValue.Trim();
            var req = new CapabilityInvocationRequest(
                CapabilityId: "fs.rename",
                TargetPath: m.PendingRenameSource,
                NewName: newName,
                WorkingDirectory: _session.ActiveDirectory,
                Confirmed: true,
                RegisteredProjectPaths: _session.RegisteredProjectPaths,
                Caller: CallerSurface.HumanTui);
            DispatchOutcome outcome = await _dispatcher.DispatchAsync(req, ct).ConfigureAwait(false);
            ApplyMutationOutcome("rename", outcome);
            if (outcome.Envelope.Ok)
            {
                _modal = null;
                RefreshFilesView();
            }
            else
            {
                m.ErrorHint = outcome.Envelope.Error?.Message ?? "Rename failed.";
            }
            SyncControlCHandling();
            return true;
        }

        if (m.Kind == ModalKind.ConfirmPaste)
        {
            string cap = m.IsMove ? "fs.move" : "fs.copy";
            var req = new CapabilityInvocationRequest(
                CapabilityId: cap,
                SourcePaths: m.TargetPaths,
                DestinationPath: m.DestinationDirectory,
                WorkingDirectory: _session.ActiveDirectory,
                Confirmed: true,
                RegisteredProjectPaths: _session.RegisteredProjectPaths,
                Caller: CallerSurface.HumanTui);
            DispatchOutcome outcome = await _dispatcher.DispatchAsync(req, ct).ConfigureAwait(false);
            ApplyMutationOutcome(m.IsMove ? "move" : "copy", outcome);
            if (outcome.Envelope.Ok && m.IsMove)
                _session.ClearClipboard();
            _modal = null;
            RefreshFilesView();
            SyncControlCHandling();
            return true;
        }

        if (m.Kind == ModalKind.ConfirmDelete)
        {
            var req = new CapabilityInvocationRequest(
                CapabilityId: "fs.delete",
                SourcePaths: m.TargetPaths,
                WorkingDirectory: _session.ActiveDirectory,
                Confirmed: true,
                Permanent: m.PermanentDelete,
                RegisteredProjectPaths: _session.RegisteredProjectPaths,
                Caller: CallerSurface.HumanTui);
            DispatchOutcome outcome = await _dispatcher.DispatchAsync(req, ct).ConfigureAwait(false);
            ApplyMutationOutcome("delete", outcome);
            if (outcome.Envelope.Ok)
                _session.ClearMultiSelect();
            _modal = null;
            RefreshFilesView();
            SyncControlCHandling();
            return true;
        }

        if (m.Kind == ModalKind.ConfirmTerminateForceStep2 && m.ProcessImpact is { } imp2)
        {
            string expectedToken = $"KILL {imp2.ExpectedIdentity.Pid}";
            if (!string.Equals(m.InputValue.Trim(), expectedToken, StringComparison.OrdinalIgnoreCase))
            {
                m.ErrorHint = $"Confirmation mismatch. Type '{expectedToken}' exactly.";
                return true;
            }

            var req = new CapabilityInvocationRequest(
                CapabilityId: "tasks.terminate",
                Pid: imp2.ExpectedIdentity.Pid,
                Confirmed: true,
                ForceTerminate: true,
                ExpectedProcessIdentity: imp2.ExpectedIdentity,
                Caller: CallerSurface.HumanTui);
            DispatchOutcome outcome = await _dispatcher.DispatchAsync(req, ct).ConfigureAwait(false);
            string msg = outcome.Envelope.Ok && outcome.Envelope.Data is ProcessTerminationResult ptr
                ? ptr.Message
                : (outcome.Envelope.Error?.Message ?? "Force termination failed.");
            SetToastResult(outcome.Envelope.Ok, $"kill {imp2.ExpectedIdentity.Pid}", msg, [], outcome.Envelope.Error?.Code);
            _session.AppendTranscript($"kill {imp2.ExpectedIdentity.Pid} --force", "TASKS", outcome.Envelope.Ok, outcome.ExitCode, outcome.Envelope.DurationMs, [msg]);
            _modal = null;
            RefreshProcessManagerSnapshot();
            SyncControlCHandling();
            return true;
        }

        return false;
    }

    private async Task<bool> ExecuteGracefulTerminateFromModalAsync(CancellationToken ct)
    {
        if (_modal?.Kind != ModalKind.ConfirmTerminateStep1 || _modal.ProcessImpact is not { CanTerminate: true, SupportsGracefulClose: true } imp)
            return false;

        var req = new CapabilityInvocationRequest(
            CapabilityId: "tasks.terminate",
            Pid: imp.ExpectedIdentity.Pid,
            Confirmed: true,
            ForceTerminate: false,
            ExpectedProcessIdentity: imp.ExpectedIdentity,
            Caller: CallerSurface.HumanTui);
        DispatchOutcome outcome = await _dispatcher.DispatchAsync(req, ct).ConfigureAwait(false);
        string msg = outcome.Envelope.Ok && outcome.Envelope.Data is ProcessTerminationResult ptr
            ? ptr.Message
            : (outcome.Envelope.Error?.Message ?? "Graceful close declined or timed out.");
        SetToastResult(outcome.Envelope.Ok, $"end {imp.ExpectedIdentity.Pid}", msg, [], outcome.Envelope.Error?.Code);
        _session.AppendTranscript($"end-task {imp.ExpectedIdentity.Pid}", "TASKS", outcome.Envelope.Ok, outcome.ExitCode, outcome.Envelope.DurationMs, [msg]);
        _modal = null;
        RefreshProcessManagerSnapshot();
        SyncControlCHandling();
        return true;
    }

    private void ApplyMutationOutcome(string op, DispatchOutcome outcome)
    {
        if (outcome.Envelope.Ok)
        {
            string msg = outcome.Envelope.Data is FsMutationResult fsRes ? fsRes.Message : $"{op} succeeded.";
            DesignTheme theme = _theme;
            List<string> details = outcome.Envelope.Data is FsMutationResult r
                ? r.ItemResults.Select(x => $"{(x.Succeeded ? theme.IconOk : theme.IconErr)} {x.Message}").ToList()
                : [];
            SetToastResult(true, op, msg, details, null);
        }
        else
        {
            SetToastResult(false, op, outcome.Envelope.Error?.Message ?? $"{op} failed.", [], outcome.Envelope.Error?.Code);
        }
    }

    public async Task ExecuteCommandLineAsync(string rawCommandLine, CancellationToken ct)
    {
        ShellCommandClassification cls = ShellCommandRouter.Classify(rawCommandLine, _dispatcher.Config);
        if (cls.Kind == ShellExecutionKind.Empty)
            return;

        _session.RecordCommand(rawCommandLine);

        if (cls.Kind is ShellExecutionKind.PowerShellCaptured or ShellExecutionKind.CmdCaptured)
        {
            ShellExecutionOutcome shOut = await ShellExecutionService.ExecuteCapturedAsync(
                cls, _dispatcher.Config, _dispatcher.Runner, _session.ActiveDirectory, ct).ConfigureAwait(false);
            string summary = shOut.Success
                ? $"{cls.ModeLabel} exited 0 ({shOut.DurationMs}ms, {shOut.OutputLines.Count} line(s))"
                : (shOut.ErrorMessage ?? $"{cls.ModeLabel} exited {shOut.ExitCode}");
            _paletteOutcome = null;
            _session.AppendTranscript(rawCommandLine, cls.ModeLabel, shOut.Success, shOut.ExitCode, shOut.DurationMs,
                shOut.OutputLines.Count > 0 ? shOut.OutputLines : [summary]);
            _session.TranscriptScroll = int.MaxValue;
            SetToastResult(shOut.Success, rawCommandLine, summary, shOut.OutputLines.Take(8).ToArray(), shOut.ErrorCode);
            if (_session.CurrentSection != NavigationSectionId.MachineOverview)
                _commandDrawerOpen = true;
            return;
        }

        if (cls.Kind == ShellExecutionKind.InteractiveForeground)
        {
            var fgSw = Stopwatch.StartNew();
            string targetExe = cls.TargetExecutable ?? _dispatcher.Config.PwshExecutable;
            string targetArgs = cls.TargetArguments ?? string.Empty;
            int exitCode;
            try
            {
                _activeSession?.SuspendForForegroundChild();
                exitCode = await _backend.RunForegroundCommandAsync(targetExe, targetArgs, _session.ActiveDirectory, ct).ConfigureAwait(false);
            }
            finally
            {
                _activeSession?.ResumeAfterForegroundChild();
                _renderer.Invalidate();
            }
            fgSw.Stop();
            bool ok = exitCode == 0;
            string fgMsg = $"Foreground '{targetExe}' exited with code {exitCode} ({fgSw.ElapsedMilliseconds}ms).";
            _paletteOutcome = null;
            _session.AppendTranscript(rawCommandLine, "TTY", ok, exitCode, fgSw.ElapsedMilliseconds, [fgMsg]);
            _session.TranscriptScroll = int.MaxValue;
            SetToastResult(ok, rawCommandLine, fgMsg, [], ok ? null : "NONZERO_EXIT");
            return;
        }

        ParsedCommandLine parsed = CommandLineParser.Parse(cls.EffectiveCommand);
        if (parsed.IsEmpty)
            return;

        if (!parsed.IsValid)
        {
            _paletteOutcome = null;
            SetToastResult(false, rawCommandLine, parsed.ErrorMessage ?? "Syntax error.", [], parsed.ErrorCode);
            string codePrefix = string.IsNullOrWhiteSpace(parsed.ErrorCode) ? string.Empty : $"{parsed.ErrorCode}: ";
            _session.AppendTranscript(rawCommandLine, "ERR", false, 2, 0, [$"{codePrefix}{parsed.ErrorMessage ?? "Syntax error."}"]);
            _session.TranscriptScroll = int.MaxValue;
            if (_session.CurrentSection != NavigationSectionId.MachineOverview || _commandDrawerOpen)
                _commandDrawerOpen = true;
            return;
        }

        string verb = parsed.CommandVerb!;
        IReadOnlyList<string> args = parsed.Arguments;

        if (args.Any(a => a is "--help" or "-h") && verb != "help")
        {
            BuiltInCommandSpec? spec = CommandLineParser.FindSpec(verb);
            string summary = spec is not null ? $"{spec.Syntax} — {spec.Summary}" : $"Command '{verb}'";
            SetToastResult(true, rawCommandLine, summary, [], null);
            _session.AppendTranscript(rawCommandLine, "SYS", true, 0, 0, [summary]);
            _session.TranscriptScroll = int.MaxValue;
            if (_session.CurrentSection != NavigationSectionId.MachineOverview)
                _commandDrawerOpen = true;
            return;
        }

        switch (verb)
        {
            case "exit":
                _commandExitRequested = true;
                break;

            case "clear":
                _session.ClearTranscript();
                _commandDrawerOpen = false;
                _paletteOutcome = null;
                _session.LastCommandResult = null;
                break;

            case "pwd":
                SetToastResult(true, rawCommandLine, $"CWD: {_session.ActiveDirectory}", [], null);
                _session.AppendTranscript(rawCommandLine, "SYS", true, 0, 0, [_session.ActiveDirectory]);
                _session.TranscriptScroll = int.MaxValue;
                if (_session.CurrentSection != NavigationSectionId.MachineOverview)
                    _commandDrawerOpen = true;
                break;

            case "back":
                if (_session.TryGoBack())
                {
                    SyncTreeCursorToCurrentSection();
                    SyncCompatibilityAliasesFromSession();
                    RefreshActiveSectionTelemetry(ct);
                    SetToastResult(true, rawCommandLine, $"Navigated back -> {_session.ActiveDirectory}", [], null);
                }
                else
                {
                    SetToastResult(false, rawCommandLine, "Navigation back stack is empty.", [], "NO_HISTORY");
                }
                break;

            case "forward":
                if (_session.TryGoForward())
                {
                    SyncTreeCursorToCurrentSection();
                    SyncCompatibilityAliasesFromSession();
                    RefreshActiveSectionTelemetry(ct);
                    SetToastResult(true, rawCommandLine, $"Navigated forward -> {_session.ActiveDirectory}", [], null);
                }
                else
                {
                    SetToastResult(false, rawCommandLine, "Navigation forward stack is empty.", [], "NO_HISTORY");
                }
                break;

            case "help":
                if (args.Count > 0)
                {
                    BuiltInCommandSpec? spec = CommandLineParser.FindSpec(args[0]);
                    if (spec is not null)
                    {
                        SetToastResult(true, rawCommandLine, $"{spec.Syntax} — {spec.Summary}", [], null);
                        _commandDrawerOpen = true;
                        return;
                    }
                }
                _returnScreen = _screen == TuiScreen.Help ? TuiScreen.Home : _screen;
                _screen = TuiScreen.Help;
                _commandDrawerOpen = false;
                break;

            case "cd":
                string target = args.Count > 0 ? string.Join(" ", args) : _dispatcher.Config.WorkspaceRoot;
                ProjectSummary? projMatch = (_wsctlProjects?.Projects ?? [])
                    .FirstOrDefault(p => p.Accessible && string.Equals(p.Id, target, StringComparison.OrdinalIgnoreCase));
                if (projMatch is not null)
                {
                    target = projMatch.FullPath;
                    _session.SetActiveProject(projMatch);
                }

                (bool cdOk, string? cdResolved, string? cdErr) = _dispatcher.FileSystem.ResolveDirectoryTarget(target, _session.ActiveDirectory);
                if (!cdOk || cdResolved is null)
                {
                    SetToastResult(false, rawCommandLine, cdErr ?? $"Directory not found: '{target}'", [], "DIRECTORY_NOT_FOUND");
                    _session.AppendTranscript(rawCommandLine, "ERR", false, 3, 0, [cdErr ?? $"Directory not found: '{target}'"]);
                    _session.TranscriptScroll = int.MaxValue;
                    if (_session.CurrentSection != NavigationSectionId.MachineOverview)
                        _commandDrawerOpen = true;
                    return;
                }

                _session.SetActiveDirectory(cdResolved);
                RefreshFilesView(resetScroll: true);
                SetToastResult(true, rawCommandLine, $"CWD -> {cdResolved}", [], null);
                _session.AppendTranscript(rawCommandLine, "FS", true, 0, 0, [$"Changed directory -> {cdResolved}"]);
                _session.TranscriptScroll = int.MaxValue;
                break;

            case "ls":
                string? lsArg = args.FirstOrDefault(a => !a.StartsWith('-'));
                if (lsArg is not null)
                {
                    (bool lsOk, string? lsDir, string? lsErr) = _dispatcher.FileSystem.ResolveDirectoryTarget(lsArg, _session.ActiveDirectory);
                    if (!lsOk || lsDir is null)
                    {
                        SetToastResult(false, rawCommandLine, lsErr ?? "Directory not found.", [], "DIRECTORY_NOT_FOUND");
                        _commandDrawerOpen = true;
                        return;
                    }
                    _session.SetActiveDirectory(lsDir);
                }
                if (!WorkspaceSessionContext.IsFilesSection(_session.CurrentSection))
                    _session.NavigateToSection(NavigationSectionId.FilesWorkspace, recordHistory: false);
                SyncTreeCursorToCurrentSection();
                SyncCompatibilityAliasesFromSession();
                RefreshFilesView(resetScroll: true);
                _session.Focus = FocusRegion.MainPane;
                SetToastResult(true, rawCommandLine, $"Listed {_fsListing?.Entries.Count ?? 0} entries in {_session.ActiveDirectory}", [], null);
                break;

            case "stat":
                if (args.Count == 0) { SetToastResult(false, rawCommandLine, "Usage: stat <path>", [], "MISSING_ARGUMENT"); _commandDrawerOpen = true; return; }
                string statTarget = _dispatcher.FileSystem.ResolvePathRelativeTo(args[0], _session.ActiveDirectory);
                DispatchOutcome statOut = await _dispatcher.DispatchAsync(new CapabilityInvocationRequest(
                    "fs.inspect", TargetPath: statTarget, WorkingDirectory: _session.ActiveDirectory,
                    RegisteredProjectPaths: _session.RegisteredProjectPaths, Caller: CallerSurface.HumanTui), ct).ConfigureAwait(false);
                DisplayDispatchInDrawer("fs.inspect", rawCommandLine, statOut);
                break;

            case "preview":
                if (args.Count == 0) { SetToastResult(false, rawCommandLine, "Usage: preview <file>", [], "MISSING_ARGUMENT"); _commandDrawerOpen = true; return; }
                string prevTarget = _dispatcher.FileSystem.ResolvePathRelativeTo(args[0], _session.ActiveDirectory);
                DispatchOutcome prevOut = await _dispatcher.DispatchAsync(new CapabilityInvocationRequest(
                    "fs.preview", TargetPath: prevTarget, WorkingDirectory: _session.ActiveDirectory,
                    Limit: 40, Caller: CallerSurface.HumanTui), ct).ConfigureAwait(false);
                DisplayDispatchInDrawer("fs.preview", rawCommandLine, prevOut);
                break;

            case "open":
                await ExecuteOpenCommandAsync(rawCommandLine, args, ct).ConfigureAwait(false);
                break;

            case "projects":
                NavigateToSection(NavigationSectionId.DevProjects, ct);
                _projectFilter = args.Count > 0 ? string.Join(" ", args) : string.Empty;
                _projectIndex = 0;
                _projectScroll = 0;
                break;

            case "project":
                if (args.Count == 0) { SetToastResult(false, rawCommandLine, "Usage: project <id>", [], "MISSING_ARGUMENT"); _commandDrawerOpen = true; return; }
                ProjectSummary? foundProj = (_wsctlProjects?.Projects ?? [])
                    .FirstOrDefault(p => string.Equals(p.Id, args[0], StringComparison.OrdinalIgnoreCase) ||
                                         p.Name.Contains(args[0], StringComparison.OrdinalIgnoreCase));
                if (foundProj is null)
                {
                    SetToastResult(false, rawCommandLine, $"Project '{args[0]}' not found.", [], "PROJECT_NOT_FOUND");
                    _commandDrawerOpen = true;
                    return;
                }
                _session.SetActiveProject(foundProj);
                if (foundProj.Accessible && Directory.Exists(foundProj.FullPath))
                    _session.SetActiveDirectory(foundProj.FullPath);
                NavigateToSection(NavigationSectionId.DevProjects, ct);
                List<ProjectSummary> filt = GetFilteredProjects();
                int pIdx = filt.FindIndex(p => string.Equals(p.Id, foundProj.Id, StringComparison.OrdinalIgnoreCase));
                if (pIdx >= 0) { _projectIndex = pIdx; _projectDetailOpen = true; }
                SetToastResult(true, rawCommandLine, $"Active project -> {foundProj.Id}", [], null);
                break;

            case "runtimes":
                NavigateToSection(NavigationSectionId.DevUlvo, ct);
                break;

            case "tasks":
                if (args.Count >= 1 && string.Equals(args[0], "tree", StringComparison.OrdinalIgnoreCase))
                {
                    _processTreeMode = !_processTreeMode;
                    NavigateToSection(NavigationSectionId.MachineProcesses, ct, focusMain: true);
                    RefreshProcessManagerSnapshot();
                    SetToastResult(true, rawCommandLine, $"Task tree view: {(_processTreeMode ? "ON" : "OFF")}", [], null);
                    break;
                }
                if (args.Count >= 2 && string.Equals(args[0], "sort", StringComparison.OrdinalIgnoreCase))
                {
                    _processSort = args[1].ToLowerInvariant() switch
                    {
                        "mem" or "memory" => ProcessSortField.Memory,
                        "pid" => ProcessSortField.Pid,
                        "name" => ProcessSortField.Name,
                        "tree" => ProcessSortField.Tree,
                        _ => ProcessSortField.Cpu
                    };
                    if (_processSort == ProcessSortField.Tree) _processTreeMode = true;
                    NavigateToSection(NavigationSectionId.MachineProcesses, ct, focusMain: true);
                    RefreshProcessManagerSnapshot();
                    SetToastResult(true, rawCommandLine, $"Tasks sorted by {_processSort}", [], null);
                    break;
                }
                if (args.Count >= 1 && string.Equals(args[0], "inspect", StringComparison.OrdinalIgnoreCase))
                {
                    string? pidArg = args.Skip(1).FirstOrDefault(a => a != "--pid");
                    if (!int.TryParse(pidArg, out int inspectPid) || inspectPid <= 0)
                    {
                        SetToastResult(false, rawCommandLine, "Usage: tasks inspect <pid>", [], "INVALID_ARGUMENTS");
                        _commandDrawerOpen = true;
                        return;
                    }
                    DispatchOutcome inspOut = await _dispatcher.DispatchAsync(new CapabilityInvocationRequest(
                        "tasks.inspect", Pid: inspectPid, Caller: CallerSurface.HumanTui), ct).ConfigureAwait(false);
                    DisplayDispatchInDrawer("tasks.inspect", rawCommandLine, inspOut);
                    break;
                }
                NavigateToSection(NavigationSectionId.MachineProcesses, ct, focusMain: true);
                break;

            case "kill":
                int targetPid = 0;
                if (args.Count > 0 && int.TryParse(args[0], out int explicitPid) && explicitPid > 0)
                {
                    targetPid = explicitPid;
                }
                else if (_session.CurrentSection == NavigationSectionId.MachineProcesses && _selectedProcessIdentity is { } curTask)
                {
                    targetPid = curTask.Pid;
                }
                if (targetPid <= 0)
                {
                    SetToastResult(false, rawCommandLine, "Usage: kill <pid> (or select a task in Tasks view)", [], "MISSING_ARGUMENT");
                    if (_session.CurrentSection != NavigationSectionId.MachineOverview) _commandDrawerOpen = true;
                    return;
                }
                OpenKillProcessModal(targetPid);
                break;

            case "perf":
                NavigateToSection(NavigationSectionId.MachinePerformance, ct);
                _performance = await _dispatcher.Telemetry.GetPerformanceSnapshotAsync(ct).ConfigureAwait(false);
                break;

            case "storage":
                NavigateToSection(NavigationSectionId.MachineStorage, ct);
                break;

            case "network":
                NavigateToSection(NavigationSectionId.MachineNetwork, ct);
                break;

            case "apps":
                NavigateToSection(NavigationSectionId.AppsRunning, ct);
                break;

            case "git":
                string gitDir = args.Count > 0
                    ? _dispatcher.FileSystem.ResolvePathRelativeTo(args[0], _session.ActiveDirectory)
                    : _session.ActiveDirectory;
                _gitStatus = await _dispatcher.Git.GetStatusAsync(gitDir, ct).ConfigureAwait(false);
                NavigateToSection(NavigationSectionId.DevGit, ct);
                break;

            case "context":
            case "health":
            case "capabilities":
            case "suggest":
                string capId = verb switch
                {
                    "context" => "workctl.context",
                    "health" => "workctl.health",
                    "capabilities" => "workctl.capabilities",
                    _ => "workctl.suggest"
                };
                string? qArg = verb == "suggest" ? string.Join(" ", args) : null;
                DispatchOutcome capOut = await _dispatcher.DispatchAsync(new CapabilityInvocationRequest(
                    capId, Query: qArg, ActiveProject: _session.ActiveProject, Caller: CallerSurface.HumanTui), ct).ConfigureAwait(false);
                DisplayDispatchInDrawer(capId, rawCommandLine, capOut);
                break;

            case "mkdir":
                if (args.Count == 0) { OpenMkdirModal(); return; }
                string newDirPath = _dispatcher.FileSystem.ResolvePathRelativeTo(args[0], _session.ActiveDirectory);
                ProtectionAssessment mkAssess = _dispatcher.FileSystem.Policy.Assess(newDirPath, FsOperationKind.CreateDirectory, _session.RegisteredProjectPaths);
                if (mkAssess.Tier == FsProtectionTier.Blocked)
                {
                    OpenProtectedBlockedModal("Create Directory Blocked", mkAssess.NormalizedPath, mkAssess.Reason!);
                    return;
                }
                _modal = new ActiveModalState
                {
                    Kind = ModalKind.PromptMkdir,
                    Title = "Confirm Create Directory",
                    MessageLines = [$"Target: {newDirPath}", "Press Enter to create, Esc to cancel:"],
                    InputValue = args[0],
                    InputCursor = args[0].Length,
                    DestinationDirectory = _session.ActiveDirectory
                };
                SyncControlCHandling();
                break;

            case "cp":
                if (args.Count == 0) { SetToastResult(false, rawCommandLine, "Usage: cp <src> [dstDir]", [], "MISSING_ARGUMENT"); _commandDrawerOpen = true; return; }
                string cpSrc = _dispatcher.FileSystem.ResolvePathRelativeTo(args[0], _session.ActiveDirectory);
                string cpDst = args.Count > 1
                    ? _dispatcher.FileSystem.ResolvePathRelativeTo(args[1], _session.ActiveDirectory)
                    : _session.ActiveDirectory;
                _session.SetClipboard(ClipboardMode.Copy, [cpSrc]);
                OpenPasteConfirmationModal(cpDst);
                break;

            case "mv":
                if (args.Count < 2) { SetToastResult(false, rawCommandLine, "Usage: mv <src> <dstDir>", [], "MISSING_ARGUMENT"); _commandDrawerOpen = true; return; }
                string mvSrc = _dispatcher.FileSystem.ResolvePathRelativeTo(args[0], _session.ActiveDirectory);
                string mvDst = _dispatcher.FileSystem.ResolvePathRelativeTo(args[1], _session.ActiveDirectory);
                _session.SetClipboard(ClipboardMode.Cut, [mvSrc]);
                OpenPasteConfirmationModal(mvDst);
                break;

            case "cut":
                if (args.Count == 0) { CopySelectionToClipboard(cut: true); return; }
                _session.SetClipboard(ClipboardMode.Cut, args.Select(a => _dispatcher.FileSystem.ResolvePathRelativeTo(a, _session.ActiveDirectory)).ToArray());
                SetToastResult(true, rawCommandLine, $"Cut {args.Count} item(s) to internal clipboard.", [], null);
                break;

            case "paste":
                OpenPasteConfirmationModal(args.Count > 0 ? args[0] : null);
                break;

            case "rename":
                if (args.Count == 0) { OpenRenameModal(); return; }
                if (args.Count == 1) { OpenRenameModal(_dispatcher.FileSystem.ResolvePathRelativeTo(args[0], _session.ActiveDirectory)); return; }
                string renTarget = _dispatcher.FileSystem.ResolvePathRelativeTo(args[0], _session.ActiveDirectory);
                _modal = new ActiveModalState
                {
                    Kind = ModalKind.PromptRename,
                    Title = "Confirm Rename",
                    MessageLines = [$"Target: {renTarget}", $"New name: {args[1]}"],
                    InputValue = args[1],
                    InputCursor = args[1].Length,
                    PendingRenameSource = renTarget
                };
                SyncControlCHandling();
                break;

            case "rm":
                if (args.Count == 0) { OpenDeleteConfirmationModal(); return; }
                OpenDeleteConfirmationModal(args.Select(a => _dispatcher.FileSystem.ResolvePathRelativeTo(a, _session.ActiveDirectory)).ToArray());
                break;

            default:
                // Fallback: resolve top completion or capability ID directly (supports partial 'heal' -> 'workctl.health'!)
                CompletionResult? comp = _completion ?? _completionEngine.Compute(new CompletionRequest(
                    rawCommandLine, rawCommandLine.Length, _session.ActiveDirectory,
                    _wsctlProjects?.Projects ?? [], _capabilities, _session.CurrentSection));
                string? candidateVerb = comp.Items.FirstOrDefault()?.InsertText;
                if (candidateVerb is not null && !string.Equals(candidateVerb, verb, StringComparison.OrdinalIgnoreCase))
                {
                    string mappedCap = candidateVerb switch
                    {
                        "health" => "workctl.health",
                        "capabilities" => "workctl.capabilities",
                        "context" => "workctl.context",
                        "projects" => "wsctl.projects",
                        "runtimes" => "ulvo.runtimes",
                        "suggest" => "workctl.suggest",
                        _ => candidateVerb
                    };
                    if (_dispatcher.Registry.TryGet(mappedCap, out _) &&
                        !mappedCap.StartsWith("fs.", StringComparison.OrdinalIgnoreCase))
                    {
                        DispatchOutcome fbOut = await _dispatcher.DispatchAsync(new CapabilityInvocationRequest(
                            mappedCap, ActiveProject: _session.ActiveProject, Caller: CallerSurface.HumanTui), ct).ConfigureAwait(false);
                        DisplayDispatchInDrawer(mappedCap, rawCommandLine, fbOut);
                        return;
                    }
                }
                if (_dispatcher.Registry.TryGet(verb, out _) && !verb.StartsWith("fs.", StringComparison.OrdinalIgnoreCase))
                {
                    DispatchOutcome directOut = await _dispatcher.DispatchAsync(new CapabilityInvocationRequest(
                        verb, ActiveProject: _session.ActiveProject, Caller: CallerSurface.HumanTui), ct).ConfigureAwait(false);
                    DisplayDispatchInDrawer(verb, rawCommandLine, directOut);
                    return;
                }
                SetToastResult(false, rawCommandLine, $"Unknown command '{verb}'. Type 'help' or press Tab for completions.", [], "UNKNOWN_COMMAND");
                _commandDrawerOpen = true;
                break;
        }
    }

    private async Task ExecuteOpenCommandAsync(string rawCommandLine, IReadOnlyList<string> args, CancellationToken ct)
    {
        if (args.Count == 0)
        {
            SetToastResult(false, rawCommandLine, "Usage: open <section|project|path>", [], "MISSING_ARGUMENT");
            _commandDrawerOpen = true;
            return;
        }

        string target = string.Join(" ", args);
        NavigationSectionId? mappedSection = target.ToLowerInvariant() switch
        {
            "overview" or "home" or "console" or "shell" => NavigationSectionId.MachineOverview,
            "processes" or "ps" or "tasks" => NavigationSectionId.MachineProcesses,
            "services" => NavigationSectionId.MachineServices,
            "performance" or "perf" => NavigationSectionId.MachinePerformance,
            "storage" => NavigationSectionId.MachineStorage,
            "network" => NavigationSectionId.MachineNetwork,
            "this-pc" or "files" => NavigationSectionId.FilesThisPc,
            "quick-access" => NavigationSectionId.FilesQuickAccess,
            "workspace" => NavigationSectionId.FilesWorkspace,
            "downloads" => NavigationSectionId.FilesDownloads,
            "projects" => NavigationSectionId.DevProjects,
            "git" => NavigationSectionId.DevGit,
            "ulvo" or "runtimes" => NavigationSectionId.DevUlvo,
            "toolchains" => NavigationSectionId.DevToolchains,
            "installed" => NavigationSectionId.AppsInstalled,
            "running" or "apps" => NavigationSectionId.AppsRunning,
            "startup" => NavigationSectionId.AppsStartup,
            _ => null
        };

        if (mappedSection.HasValue)
        {
            NavigateToSection(mappedSection.Value, ct);
            return;
        }

        string pathCandidate = _dispatcher.FileSystem.ResolvePathRelativeTo(target, _session.ActiveDirectory);
        if (Directory.Exists(PathNormalizer.EnsureLongPathPrefix(pathCandidate)))
        {
            _session.SetActiveDirectory(pathCandidate);
            if (!WorkspaceSessionContext.IsFilesSection(_session.CurrentSection))
                _session.NavigateToSection(NavigationSectionId.FilesWorkspace, recordHistory: false);
            SyncTreeCursorToCurrentSection();
            SyncCompatibilityAliasesFromSession();
            RefreshFilesView(resetScroll: true);
            return;
        }

        if (File.Exists(PathNormalizer.EnsureLongPathPrefix(pathCandidate)))
        {
            DispatchOutcome prevOut = await _dispatcher.DispatchAsync(new CapabilityInvocationRequest(
                "fs.preview", TargetPath: pathCandidate, WorkingDirectory: _session.ActiveDirectory,
                Limit: 60, Caller: CallerSurface.HumanTui), ct).ConfigureAwait(false);
            DisplayDispatchInDrawer("fs.preview", rawCommandLine, prevOut);
            return;
        }

        SetToastResult(false, rawCommandLine, $"Section, project, or path not found: '{target}'.", [], "NOT_FOUND");
        _commandDrawerOpen = true;
    }

    private void DisplayDispatchInDrawer(string capabilityId, string commandText, DispatchOutcome outcome)
    {
        _paletteExecutedCommand = capabilityId;
        _paletteOutcome = outcome;
        _paletteResultScroll = 0;
        _commandDrawerScroll = 0;
        if (_session.CurrentSection != NavigationSectionId.MachineOverview || _commandPromptChar == ':')
            _commandDrawerOpen = true;

        IReadOnlyList<string> summaryLines = outcome.Envelope.Ok
            ? FormatStructuredOutcome(outcome.Envelope, 88, 24).Select(StripAnsiSimple).ToArray()
            : [$"{outcome.Envelope.Error?.Code}: {outcome.Envelope.Error?.Message}"];

        _session.AppendTranscript(commandText, "SYS", outcome.Envelope.Ok, outcome.ExitCode, outcome.Envelope.DurationMs,
            summaryLines.Count > 0 ? summaryLines : [$"{capabilityId} completed"]);
        _session.TranscriptScroll = int.MaxValue;

        _session.LastCommandResult = new CommandResultFeedback(
            outcome.Envelope.Ok,
            commandText,
            outcome.Envelope.Ok ? $"{capabilityId} succeeded ({outcome.Envelope.DurationMs}ms)" : $"{outcome.Envelope.Error?.Code}: {outcome.Envelope.Error?.Message}",
            Array.Empty<string>(),
            outcome.Envelope.Error?.Code,
            DateTimeOffset.UtcNow);
    }

    private static string StripAnsiSimple(string s)
        => System.Text.RegularExpressions.Regex.Replace(s, @"\u001b\[[0-9;?]*[A-Za-z]", string.Empty);

    private void SetToastResult(bool success, string command, string headline, IReadOnlyList<string> details, string? errorCode)
    {
        _session.LastCommandResult = new CommandResultFeedback(
            success,
            command,
            headline,
            details,
            errorCode,
            DateTimeOffset.UtcNow);
    }
}

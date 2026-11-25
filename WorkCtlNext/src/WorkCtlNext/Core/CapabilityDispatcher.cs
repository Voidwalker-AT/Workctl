using System.Diagnostics;
using WorkCtlNext.Providers;

namespace WorkCtlNext.Core;

public sealed record DispatchOutcome(
    int ExitCode,
    CapabilityEnvelope<object?> Envelope);

public sealed record CompactProjectItem(
    string Id,
    string Name,
    string Path,
    string Category,
    string Status,
    bool Accessible,
    string Environment,
    IReadOnlyList<string> Actions);

public sealed record ProjectsPayload(
    int TotalMatched,
    int Returned,
    bool NormalizedFromSingleObject,
    IReadOnlyList<object> Items);

public sealed record ProjectContextPayload(
    object Project,
    IReadOnlyList<ProjectActionSummary> Actions,
    UlvoProjectInspection? Runtime,
    IReadOnlyList<ToolAvailability> Tools,
    string Note);

public sealed record GeneralContextPayload(
    string CurrentDirectory,
    MachineSnapshot Machine,
    ProviderStatus WsctlStatus,
    ProjectSummary? DetectedProject,
    UlvoStatusSummary Ulvo,
    IReadOnlyList<ToolAvailability> Tools,
    IReadOnlyList<SuggestionItem> Suggestions,
    ErrorDetail? WsctlError = null);

public sealed record HealthPayload(
    string OverallStatus,
    MachineSnapshot Machine,
    WsctlHealthSnapshot Wsctl,
    UlvoStatusSummary Ulvo);

/// <summary>
/// Single command/capability dispatcher shared by BOTH Agent CLI and Human TUI.
/// Enforces Phase 1 RiskClassification.ReadOnly gate identically across all callers.
/// </summary>
public sealed class CapabilityDispatcher
{
    public const RiskClassification Phase1MaxAllowedRisk = RiskClassification.ReadOnly;

    private static readonly HashSet<string> KnownMutatingCapabilities = new(StringComparer.OrdinalIgnoreCase)
    {
        "fs.mkdir", "fs.copy", "fs.move", "fs.rename", "fs.delete", "tasks.terminate"
    };

    public WorkctlPathsConfig Config { get; }
    public IProcessRunner Runner { get; }
    public DispatcherPolicyMode PolicyMode { get; }
    public WindowsMachineProvider Machine { get; }
    public WindowsTelemetryProvider Telemetry { get; }
    public ProcessTerminationService ProcessTermination { get; }
    public WsctlProvider Wsctl { get; }
    public UlvoProvider Ulvo { get; }
    public GitProvider Git { get; }
    public FileSystemService FileSystem { get; }
    public CapabilityRegistry Registry { get; }
    public ISuggestionRanker Suggestions { get; }

    public CapabilityDispatcher(
        WorkctlPathsConfig config,
        IProcessRunner runner,
        ISuggestionRanker? suggestionRanker = null,
        DispatcherPolicyMode policyMode = DispatcherPolicyMode.ReadOnly,
        FileSystemService? fileSystem = null,
        GitProvider? gitProvider = null,
        WindowsTelemetryProvider? telemetryProvider = null)
    {
        Config = config ?? throw new ArgumentNullException(nameof(config));
        Runner = runner ?? throw new ArgumentNullException(nameof(runner));

        PolicyMode = policyMode;
        Machine = new WindowsMachineProvider();
        Telemetry = telemetryProvider ?? new WindowsTelemetryProvider(Config);
        ProcessTermination = new ProcessTerminationService(Telemetry);
        Wsctl = new WsctlProvider(runner, config);
        Ulvo = new UlvoProvider(runner, config);
        Git = gitProvider ?? new GitProvider(config, runner);
        FileSystem = fileSystem ?? new FileSystemService(config);
        Suggestions = suggestionRanker ?? new DeterministicSuggestionRanker();
        Registry = BuildDefaultRegistry();
    }

    private CapabilityRegistry BuildDefaultRegistry()
    {
        var reg = new CapabilityRegistry();
        string[] formats = ["json", "tui"];

        reg.Register(new RegisteredCapability(
            "workctl.capabilities",
            "List Capabilities",
            "Discover implemented capabilities, providers, risk classes, and availability.",
            "core",
            RiskClassification.ReadOnly,
            [],
            formats,
            "capabilities --json",
            ExecuteCapabilitiesAsync));

        reg.Register(new RegisteredCapability(
            "workctl.context",
            "Workstation / Project Context",
            "Retrieve compact machine + WSCTL + ULVO context for CWD or --project <id>.",
            "core",
            RiskClassification.ReadOnly,
            [],
            formats,
            "context --json",
            ExecuteContextAsync));

        reg.Register(new RegisteredCapability(
            "wsctl.projects",
            "List WSCTL Projects",
            "Catalog registered WSCTL projects through verified no-write CLI.",
            "wsctl",
            RiskClassification.ReadOnly,
            [],
            formats,
            "projects --json",
            ExecuteProjectsAsync));

        reg.Register(new RegisteredCapability(
            "wsctl.project.inspect",
            "Inspect WSCTL Project",
            "Resolve project root, accessibility, and registered action metadata.",
            "wsctl",
            RiskClassification.ReadOnly,
            ["project"],
            formats,
            "context --project <id> --json",
            ExecuteProjectInspectAsync));

        reg.Register(new RegisteredCapability(
            "ulvo.runtimes",
            "Inspect ULVO Runtimes",
            "Inspect ULVO status and bounded recorded runtime catalog without heavy vault scans.",
            "ulvo",
            RiskClassification.ReadOnly,
            [],
            formats,
            "runtimes --json",
            ExecuteRuntimesAsync));

        reg.Register(new RegisteredCapability(
            "ulvo.project.inspect",
            "Inspect Project Runtime (ULVO)",
            "Run fast zero-write ulvo inspect on an accessible project directory.",
            "ulvo",
            RiskClassification.ReadOnly,
            ["projectPath"],
            formats,
            "context --project <id> --json",
            ExecuteUlvoInspectAsync));

        reg.Register(new RegisteredCapability(
            "windows.machine",
            "Windows Machine Snapshot",
            "Read-only OS, CPU, RAM, fixed disk, and process count metrics.",
            "windows",
            RiskClassification.ReadOnly,
            [],
            formats,
            "context --json",
            (req, ct) => Task.FromResult<object?>(Machine.GetSnapshot())));

        reg.Register(new RegisteredCapability(
            "workctl.health",
            "Workstation Health Summary",
            "Aggregate read-only machine, WSCTL cached doctor freshness, and ULVO status.",
            "core",
            RiskClassification.ReadOnly,
            [],
            formats,
            "health --json",
            ExecuteHealthAsync));

        reg.Register(new RegisteredCapability(
            "workctl.suggest",
            "Command Suggestions",
            "Deterministic prefix, fuzzy, and contextual command ranking (no history or ML).",
            "core",
            RiskClassification.ReadOnly,
            [],
            formats,
            "suggest --query <text> --json",
            ExecuteSuggestAsync));

        // Phase 2 / 2.1 read-only machine, task-manager, Git, app, and filesystem inspection capabilities
        reg.Register(new RegisteredCapability(
            "windows.processes",
            "Windows Task Manager List",
            "Inspect live Windows processes with PID, PPID, CPU%, memory, executable path, and sorting.",
            "windows",
            RiskClassification.ReadOnly,
            [],
            formats,
            "tasks [--sort <cpu|mem|pid|name>] [--filter <text>] [--limit <n>] --json",
            (req, ct) => Task.FromResult<object?>(ExecuteTasksList(req))));

        reg.Register(new RegisteredCapability(
            "tasks.inspect",
            "Inspect Process Identity & Relations",
            "Inspect single PID metadata, verified parent/children, owner, services, and safety flags.",
            "windows",
            RiskClassification.ReadOnly,
            ["pid"],
            formats,
            "tasks inspect --pid <pid> --json",
            (req, ct) => Task.FromResult<object?>(ExecuteTaskInspect(req))));

        reg.Register(new RegisteredCapability(
            "windows.performance",
            "Windows Performance",
            "Live CPU utilization delta, thread count, and RAM pressure via Win32 APIs.",
            "windows",
            RiskClassification.ReadOnly,
            [],
            formats,
            string.Empty,
            async (req, ct) => await Telemetry.GetPerformanceSnapshotAsync(ct).ConfigureAwait(false)));

        reg.Register(new RegisteredCapability(
            "windows.storage",
            "Windows Storage Volumes",
            "Mounted Windows drives, volume labels, filesystems, and free capacity.",
            "windows",
            RiskClassification.ReadOnly,
            [],
            formats,
            "storage --json",
            (req, ct) => Task.FromResult<object?>(Telemetry.GetStorageSnapshot())));

        reg.Register(new RegisteredCapability(
            "windows.network",
            "Windows Network Interfaces",
            "Network adapters, operational status, IPv4 addresses, gateways, and counters.",
            "windows",
            RiskClassification.ReadOnly,
            [],
            formats,
            "network --json",
            (req, ct) => Task.FromResult<object?>(Telemetry.GetNetworkSnapshot())));

        reg.Register(new RegisteredCapability(
            "apps.running",
            "Running Windowed Applications",
            "Inspect active processes owning visible top-level windows.",
            "windows",
            RiskClassification.ReadOnly,
            [],
            formats,
            string.Empty,
            (req, ct) => Task.FromResult<object?>(Telemetry.GetRunningApps(req.Limit ?? 40))));

        reg.Register(new RegisteredCapability(
            "git.status",
            "Git Repository Status",
            "Inspect branch, upstream divergence, and working tree status via git --no-optional-locks.",
            "git",
            RiskClassification.ReadOnly,
            [],
            formats,
            "git --path <dir> --json",
            ExecuteGitStatusAsync));

        reg.Register(new RegisteredCapability(
            "fs.list",
            "List Directory Entries",
            "List directory entries, reparse points, and hardlink metadata.",
            "fs",
            RiskClassification.ReadOnly,
            [],
            formats,
            "ls --path <dir> --json",
            ExecuteFsListAsync));

        reg.Register(new RegisteredCapability(
            "fs.inspect",
            "Inspect Filesystem Metadata",
            "Inspect NTFS hardlinks, junctions, symlinks, protection tier, and timestamps.",
            "fs",
            RiskClassification.ReadOnly,
            ["path"],
            formats,
            "stat --path <target> --json",
            ExecuteFsInspectAsync));

        reg.Register(new RegisteredCapability(
            "fs.preview",
            "Preview Text File",
            "Read bounded binary-safe UTF-8/UTF-16 preview of a text file.",
            "fs",
            RiskClassification.ReadOnly,
            ["path"],
            formats,
            "preview --path <file> --json",
            ExecuteFsPreviewAsync));

        reg.Register(new RegisteredCapability(
            "fs.resolve",
            "Resolve Filesystem Path",
            "Resolve relative/tilde/junction paths against working directory safely.",
            "fs",
            RiskClassification.ReadOnly,
            ["path"],
            formats,
            "resolve --path <target> --json",
            ExecuteFsResolveAsync));

        if (PolicyMode == DispatcherPolicyMode.InteractivePhase2)
        {
            reg.Register(new RegisteredCapability(
                "fs.mkdir",
                "Create Directory",
                "Create a directory inside an allowed destination after policy checks.",
                "fs",
                RiskClassification.Modifying,
                ["path"],
                formats,
                string.Empty,
                ExecuteFsMkdirAsync));

            reg.Register(new RegisteredCapability(
                "fs.copy",
                "Copy Files or Directories",
                "Copy selected files/directories without silent overwrite.",
                "fs",
                RiskClassification.Modifying,
                [],
                formats,
                string.Empty,
                ExecuteFsCopyAsync));

            reg.Register(new RegisteredCapability(
                "fs.move",
                "Move Files or Directories",
                "Move selected items with cross-volume copy-verify-delete safety.",
                "fs",
                RiskClassification.Modifying,
                [],
                formats,
                string.Empty,
                ExecuteFsMoveAsync));

            reg.Register(new RegisteredCapability(
                "fs.rename",
                "Rename File or Directory",
                "Rename item safely with conflict and Windows device-name checks.",
                "fs",
                RiskClassification.Modifying,
                ["path", "newName"],
                formats,
                string.Empty,
                ExecuteFsRenameAsync));

            reg.Register(new RegisteredCapability(
                "fs.delete",
                "Delete Files or Directories",
                "Send to Recycle Bin (or unlink reparse points without recursion) after confirmation.",
                "fs",
                RiskClassification.Destructive,
                [],
                formats,
                string.Empty,
                ExecuteFsDeleteAsync));

            reg.Register(new RegisteredCapability(
                "tasks.terminate",
                "Terminate Process (Human Guarded)",
                "Gracefully close or force-terminate a verified PID after impact preview and explicit human confirmation.",
                "windows",
                RiskClassification.Destructive,
                ["pid"],
                formats,
                string.Empty,
                ExecuteTaskTerminateAsync));
        }

        return reg;
    }

    public async Task<DispatchOutcome> DispatchAsync(
        CapabilityInvocationRequest request,
        CancellationToken cancellationToken)
    {
        var sw = Stopwatch.StartNew();
        DateTimeOffset now = DateTimeOffset.UtcNow;

        if (!Registry.TryGet(request.CapabilityId, out RegisteredCapability? cap) || cap is null)
        {
            if (KnownMutatingCapabilities.Contains(request.CapabilityId))
            {
                return MakeError(2, request.CapabilityId, now, sw.ElapsedMilliseconds,
                    new ErrorDetail("POLICY_BLOCKED", $"Mutating capability '{request.CapabilityId}' is blocked under policy '{PolicyMode}' (Agent CLI / ReadOnly surfaces remain strictly ReadOnly).", "core"));
            }

            return MakeError(2, request.CapabilityId, now, sw.ElapsedMilliseconds,
                new ErrorDetail("UNKNOWN_CAPABILITY", $"Capability '{request.CapabilityId}' is not registered.", "core"));
        }

        RiskClassification effectiveLimit = (PolicyMode == DispatcherPolicyMode.InteractivePhase2 && request.Caller == CallerSurface.HumanTui)
            ? RiskClassification.Destructive
            : Phase1MaxAllowedRisk;

        if (cap.Risk > effectiveLimit)
        {
            return MakeError(2, cap.Id, now, sw.ElapsedMilliseconds,
                new ErrorDetail("POLICY_BLOCKED", $"Capability '{cap.Id}' requires risk '{cap.Risk}', blocked on '{request.Caller}' under policy '{PolicyMode}' (max allowed: {effectiveLimit}).", "core"));
        }

        if (cap.Risk > RiskClassification.ReadOnly && !request.Confirmed)
        {
            return MakeError(2, cap.Id, now, sw.ElapsedMilliseconds,
                new ErrorDetail("CONFIRMATION_REQUIRED", $"Capability '{cap.Id}' requires explicit human confirmation before execution.", "core"));
        }

        foreach (string reqArg in cap.RequiredArguments)
        {
            bool present = reqArg switch
            {
                "project" => !string.IsNullOrWhiteSpace(request.ProjectId),
                "projectPath" => !string.IsNullOrWhiteSpace(request.ProjectPath),
                "path" => !string.IsNullOrWhiteSpace(request.TargetPath),
                "newName" => !string.IsNullOrWhiteSpace(request.NewName),
                "pid" => request.Pid is > 0,
                _ => true
            };
            if (!present)
            {
                return MakeError(2, cap.Id, now, sw.ElapsedMilliseconds,
                    new ErrorDetail("MISSING_ARGUMENT", $"Capability '{cap.Id}' requires argument '--{reqArg}'.", "core"));
            }
        }

        try
        {
            object? payload = await cap.Executor(request, cancellationToken).ConfigureAwait(false);
            sw.Stop();
            return new DispatchOutcome(
                0,
                new CapabilityEnvelope<object?>(1, true, cap.Id, now, "live", sw.ElapsedMilliseconds, payload));
        }
        catch (DispatchFailureException dfx)
        {
            sw.Stop();
            return MakeError(dfx.ExitCode, cap.Id, now, sw.ElapsedMilliseconds, dfx.Detail);
        }
        catch (OperationCanceledException)
        {
            sw.Stop();
            return MakeError(5, cap.Id, now, sw.ElapsedMilliseconds,
                new ErrorDetail("CANCELLED", $"Execution of '{cap.Id}' was cancelled.", "core"));
        }
        catch (Exception ex)
        {
            sw.Stop();
            return MakeError(1, cap.Id, now, sw.ElapsedMilliseconds,
                new ErrorDetail("INTERNAL_ERROR", ex.Message, "core"));
        }
    }

    private Task<object?> ExecuteCapabilitiesAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        IReadOnlyList<CapabilityInfo> caps = Registry.DescribeAll(Config, Git.IsGitAvailable());
        return Task.FromResult<object?>(new
        {
            phase = 2,
            mode = PolicyMode == DispatcherPolicyMode.InteractivePhase2 && req.Caller == CallerSurface.HumanTui
                ? "interactive_guarded"
                : "read_only",
            total = caps.Count,
            capabilities = caps
        });
    }

    private async Task<object?> ExecuteProjectsAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        WsctlProjectsResult res = await Wsctl.GetProjectsAsync(ct).ConfigureAwait(false);
        if (res.Status != ProviderStatus.Available)
            throw new DispatchFailureException(MapProviderExitCode(res.Status, res.Error), res.Error!);

        IEnumerable<ProjectSummary> filtered = res.Projects;
        if (!string.IsNullOrWhiteSpace(req.Category))
            filtered = filtered.Where(p => string.Equals(p.Category, req.Category.Trim(), StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(req.Tag))
            filtered = filtered.Where(p => p.Tags is not null && p.Tags.Any(t => string.Equals(t, req.Tag.Trim(), StringComparison.OrdinalIgnoreCase)));

        var matched = filtered.ToList();
        int limit = req.Limit is > 0 ? req.Limit.Value : 50;
        var bounded = matched.Take(limit).ToList();

        var items = new List<object>(bounded.Count);
        foreach (ProjectSummary p in bounded)
        {
            if (req.Detailed)
            {
                items.Add(p);
            }
            else
            {
                items.Add(new CompactProjectItem(
                    Id: p.Id,
                    Name: p.Name,
                    Path: p.FullPath,
                    Category: p.Category,
                    Status: p.Status,
                    Accessible: p.Accessible,
                    Environment: p.Environment,
                    Actions: p.Actions.Select(a => a.Name).ToList()));
            }
        }

        return new ProjectsPayload(matched.Count, items.Count, res.NormalizedFromSingleObject, items);
    }

    private async Task<object?> ExecuteProjectInspectAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        WsctlProjectsResult res = await Wsctl.GetProjectsAsync(ct).ConfigureAwait(false);
        if (res.Status != ProviderStatus.Available)
            throw new DispatchFailureException(MapProviderExitCode(res.Status, res.Error), res.Error!);

        (ProjectSummary? proj, ErrorDetail? lookupErr) = WsctlProvider.ResolveProject(res.Projects, req.ProjectId!);
        if (proj is null)
            throw new DispatchFailureException(3, lookupErr!);

        return proj;
    }

    private async Task<object?> ExecuteUlvoInspectAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        UlvoProjectInspection res = await Ulvo.InspectProjectAsync(req.ProjectPath!, req.IncludeEnvStatus, ct).ConfigureAwait(false);
        if (res.Status is ProviderStatus.Unavailable or ProviderStatus.Timeout or ProviderStatus.Error)
            throw new DispatchFailureException(MapProviderExitCode(res.Status, res.Error), res.Error!);
        return res;
    }

    private async Task<object?> ExecuteContextAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        IReadOnlyList<ToolAvailability> tools = ProbeRelevantTools();

        if (!string.IsNullOrWhiteSpace(req.ProjectId))
        {
            WsctlProjectsResult projRes = await Wsctl.GetProjectsAsync(ct).ConfigureAwait(false);
            if (projRes.Status != ProviderStatus.Available)
                throw new DispatchFailureException(MapProviderExitCode(projRes.Status, projRes.Error), projRes.Error!);

            (ProjectSummary? proj, ErrorDetail? lookupErr) = WsctlProvider.ResolveProject(projRes.Projects, req.ProjectId);
            if (proj is null)
                throw new DispatchFailureException(3, lookupErr!);

            UlvoProjectInspection? runtime = null;
            if (proj.Accessible)
            {
                runtime = await Ulvo.InspectProjectAsync(proj.FullPath, req.IncludeEnvStatus, ct).ConfigureAwait(false);
            }
            else
            {
                runtime = new UlvoProjectInspection(
                    ProviderStatus.Unavailable,
                    proj.FullPath,
                    false,
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    [],
                    ["Project directory missing on disk; ULVO inspect skipped."],
                    false,
                    null,
                    0,
                    new ErrorDetail("PROJECT_DIR_MISSING", $"Project directory '{proj.FullPath}' does not exist on disk.", "wsctl"));
            }

            object projectView = req.Detailed
                ? proj
                : new
                {
                    id = proj.Id,
                    name = proj.Name,
                    path = proj.FullPath,
                    category = proj.Category,
                    status = proj.Status,
                    accessible = proj.Accessible,
                    environment = proj.Environment,
                    gpu = proj.Gpu,
                    git = proj.Git
                };

            return new ProjectContextPayload(
                Project: projectView,
                Actions: proj.Actions,
                Runtime: runtime,
                Tools: tools,
                Note: "Read-only Phase 1 context: registered action execution is disabled.");
        }

        // General workstation context (no --project specified): probe machine + WSCTL + ULVO concurrently.
        Task<WsctlProjectsResult> wsctlTask = Wsctl.GetProjectsAsync(ct);
        Task<UlvoStatusSummary> ulvoTask = Ulvo.GetStatusAsync(ct);
        MachineSnapshot machine = Machine.GetSnapshot();
        await Task.WhenAll(wsctlTask, ulvoTask).ConfigureAwait(false);

        WsctlProjectsResult wsRes = wsctlTask.Result;
        UlvoStatusSummary ulvoRes = ulvoTask.Result;

        string cwd = Environment.CurrentDirectory;
        ProjectSummary? detected = wsRes.Status == ProviderStatus.Available
            ? wsRes.Projects.FirstOrDefault(p => PathNormalizer.IsSameOrSubdirectory(cwd, p.FullPath))
            : null;

        var sugContext = new SuggestionContext(
            req.CurrentScreen ?? "Home",
            detected,
            wsRes.Status == ProviderStatus.Available,
            ulvoRes.Status == ProviderStatus.Available);
        IReadOnlyList<SuggestionItem> suggestions = Suggestions.Suggest(string.Empty, Registry.DescribeAll(Config), sugContext, 5);

        return new GeneralContextPayload(
            CurrentDirectory: cwd,
            Machine: machine,
            WsctlStatus: wsRes.Status,
            DetectedProject: detected,
            Ulvo: ulvoRes,
            Tools: tools,
            Suggestions: suggestions,
            WsctlError: wsRes.Error);
    }

    private async Task<object?> ExecuteRuntimesAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        Task<UlvoStatusSummary> statusTask = Ulvo.GetStatusAsync(ct);
        Task<(ProviderStatus Status, IReadOnlyList<UlvoListedProject> Projects, long DurationMs, ErrorDetail? Error)>? lsTask =
            req.IncludeProjects ? Ulvo.ListProjectsAsync(ct) : null;

        await statusTask.ConfigureAwait(false);
        UlvoStatusSummary status = statusTask.Result;
        if (status.Status != ProviderStatus.Available)
            throw new DispatchFailureException(MapProviderExitCode(status.Status, status.Error), status.Error!);

        if (lsTask is null)
        {
            return new UlvoRuntimesPayload(
                Summary: status,
                ListStatus: ProviderStatus.Available,
                ListedTotal: status.RegisteredProjects,
                Projects: [],
                PolicyNote: "Fast bounded mode: pass --include-projects for normalized ulvo ls catalog. Heavy vault scans (env audit/ps) are disabled in Phase 1.");
        }

        var lsRes = await lsTask.ConfigureAwait(false);
        int limit = req.Limit is > 0 ? req.Limit.Value : 25;
        return new UlvoRuntimesPayload(
            Summary: status,
            ListStatus: lsRes.Status,
            ListedTotal: lsRes.Projects.Count,
            Projects: lsRes.Projects.Take(limit).ToList(),
            PolicyNote: "envHealthChecked=false on 'ulvo ls'; pass --project <id> --include-env-status to probe an individual project.",
            ListError: lsRes.Error);
    }

    private async Task<object?> ExecuteHealthAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        Task<WsctlHealthSnapshot> wsTask = Wsctl.GetWorkspaceHealthAsync(ct);
        Task<UlvoStatusSummary> ulvoTask = Ulvo.GetStatusAsync(ct);
        MachineSnapshot machine = Machine.GetSnapshot();
        await Task.WhenAll(wsTask, ulvoTask).ConfigureAwait(false);

        WsctlHealthSnapshot ws = wsTask.Result;
        UlvoStatusSummary ulvo = ulvoTask.Result;

        string overall = (machine.Status == "ok" && ws.InfoStatus == ProviderStatus.Available && ulvo.Status == ProviderStatus.Available && !ws.DoctorSnapshotStale)
            ? "healthy"
            : "degraded";

        return new HealthPayload(overall, machine, ws, ulvo);
    }

    private async Task<object?> ExecuteSuggestAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        ProjectSummary? active = req.ActiveProject;
        bool wsctlAvail = !string.IsNullOrWhiteSpace(Config.PwshExecutable) && File.Exists(Config.WsctlScriptPath);
        bool ulvoAvail = !string.IsNullOrWhiteSpace(Config.UlvoExecutable)
            && (Path.IsPathRooted(Config.UlvoExecutable)
                ? File.Exists(Config.UlvoExecutable)
                : ProcessRunner.FindExecutableOnPath(Config.UlvoExecutable) is not null);

        if (active is null && !string.IsNullOrWhiteSpace(req.ProjectId))
        {
            WsctlProjectsResult projRes = await Wsctl.GetProjectsAsync(ct).ConfigureAwait(false);
            if (projRes.Status != ProviderStatus.Available)
                throw new DispatchFailureException(MapProviderExitCode(projRes.Status, projRes.Error), projRes.Error!);

            (ProjectSummary? resolved, ErrorDetail? lookupErr) = WsctlProvider.ResolveProject(projRes.Projects, req.ProjectId);
            if (resolved is null)
                throw new DispatchFailureException(3, lookupErr!);
            active = resolved;
        }

        var ctx = new SuggestionContext(req.CurrentScreen ?? "Palette", active, wsctlAvail, ulvoAvail);
        var items = Suggestions.Suggest(req.Query ?? string.Empty, Registry.DescribeAll(Config, Git.IsGitAvailable()), ctx, req.Limit ?? 15);
        return new
        {
            query = req.Query ?? string.Empty,
            contextProject = active?.Id,
            autoExecute = false,
            count = items.Count,
            suggestions = items
        };
    }

    private async Task<object?> ExecuteGitStatusAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        string targetDir = !string.IsNullOrWhiteSpace(req.TargetPath)
            ? req.TargetPath
            : !string.IsNullOrWhiteSpace(req.WorkingDirectory)
                ? req.WorkingDirectory
                : Config.WorkspaceRoot;

        if (!Git.IsGitAvailable())
            throw new DispatchFailureException(4, new ErrorDetail("PROVIDER_UNAVAILABLE", "Git executable is not installed or unavailable on PATH.", "git"));

        GitRepositorySnapshot snap = await Git.GetStatusAsync(targetDir, ct).ConfigureAwait(false);
        return snap;
    }

    private Task<object?> ExecuteFsListAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        string baseDir = !string.IsNullOrWhiteSpace(req.WorkingDirectory) ? req.WorkingDirectory : Config.WorkspaceRoot;
        string target = string.IsNullOrWhiteSpace(req.TargetPath) ? baseDir : req.TargetPath;
        (bool ok, string? resolved, string? err) = FileSystem.ResolveDirectoryTarget(target, baseDir);
        if (!ok || resolved is null)
            throw new DispatchFailureException(3, new ErrorDetail("DIRECTORY_NOT_FOUND", err ?? $"Directory not found: '{target}'.", "fs"));

        FsDirectoryListing listing = FileSystem.ListDirectory(resolved, req.Limit ?? 500, req.RegisteredProjectPaths);
        return Task.FromResult<object?>(listing);
    }

    private Task<object?> ExecuteFsInspectAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        string baseDir = !string.IsNullOrWhiteSpace(req.WorkingDirectory) ? req.WorkingDirectory : Config.WorkspaceRoot;
        string target = FileSystem.ResolvePathRelativeTo(req.TargetPath!, baseDir);
        FsMetadataSnapshot meta = FileSystem.InspectPath(target, req.RegisteredProjectPaths);
        if (!meta.Exists)
            throw new DispatchFailureException(3, new ErrorDetail("NOT_FOUND", meta.ErrorMessage ?? $"Path not found: '{target}'.", "fs"));
        return Task.FromResult<object?>(meta);
    }

    private Task<object?> ExecuteFsPreviewAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        string baseDir = !string.IsNullOrWhiteSpace(req.WorkingDirectory) ? req.WorkingDirectory : Config.WorkspaceRoot;
        string target = FileSystem.ResolvePathRelativeTo(req.TargetPath!, baseDir);
        int maxLines = req.Limit is > 0 ? Math.Clamp(req.Limit.Value, 1, 200) : 120;
        FsPreviewSnapshot preview = FileSystem.PreviewFile(target, maxBytes: 64 * 1024, maxLines: maxLines);
        if (!preview.Exists)
            throw new DispatchFailureException(3, new ErrorDetail("NOT_FOUND", preview.DisabledReason ?? $"File not found: '{target}'.", "fs"));
        return Task.FromResult<object?>(preview);
    }

    private Task<object?> ExecuteFsResolveAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        string baseDir = !string.IsNullOrWhiteSpace(req.WorkingDirectory) ? req.WorkingDirectory : Config.WorkspaceRoot;
        (bool isDir, string? resolvedDir, string? err) = FileSystem.ResolveDirectoryTarget(req.TargetPath!, baseDir);
        string resolved = resolvedDir ?? FileSystem.ResolvePathRelativeTo(req.TargetPath!, baseDir);
        bool exists = isDir || File.Exists(PathNormalizer.EnsureLongPathPrefix(resolved));
        return Task.FromResult<object?>(new
        {
            input = req.TargetPath,
            workingDirectory = baseDir,
            resolvedPath = resolved,
            exists,
            isDirectory = isDir,
            note = exists ? null : err
        });
    }

    private Task<object?> ExecuteFsMkdirAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        string baseDir = !string.IsNullOrWhiteSpace(req.WorkingDirectory) ? req.WorkingDirectory : Config.WorkspaceRoot;
        FsMutationResult res = FileSystem.CreateDirectory(baseDir, req.TargetPath!, req.RegisteredProjectPaths);
        EnsureMutationSucceeded(res);
        return Task.FromResult<object?>(res);
    }

    private Task<object?> ExecuteFsCopyAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        string baseDir = !string.IsNullOrWhiteSpace(req.WorkingDirectory) ? req.WorkingDirectory : Config.WorkspaceRoot;
        IReadOnlyList<string> sources = ResolveSourceList(req, baseDir);
        string destDir = string.IsNullOrWhiteSpace(req.DestinationPath)
            ? baseDir
            : FileSystem.ResolvePathRelativeTo(req.DestinationPath, baseDir);
        FsMutationResult res = FileSystem.CopyItems(sources, destDir, req.RegisteredProjectPaths);
        EnsureMutationSucceeded(res);
        return Task.FromResult<object?>(res);
    }

    private Task<object?> ExecuteFsMoveAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        string baseDir = !string.IsNullOrWhiteSpace(req.WorkingDirectory) ? req.WorkingDirectory : Config.WorkspaceRoot;
        IReadOnlyList<string> sources = ResolveSourceList(req, baseDir);
        string destRaw = string.IsNullOrWhiteSpace(req.DestinationPath) ? baseDir : req.DestinationPath;
        string destResolved = FileSystem.ResolvePathRelativeTo(destRaw, baseDir);

        bool destIsExistingDir = Directory.Exists(PathNormalizer.EnsureLongPathPrefix(destResolved));
        string? explicitSingleDst = (sources.Count == 1 && !destIsExistingDir) ? destResolved : null;
        string destDir = explicitSingleDst is not null
            ? (Path.GetDirectoryName(explicitSingleDst) ?? baseDir)
            : destResolved;

        FsMutationResult res = FileSystem.MoveItems(sources, destDir, explicitSingleDst, req.RegisteredProjectPaths);
        EnsureMutationSucceeded(res);
        return Task.FromResult<object?>(res);
    }

    private Task<object?> ExecuteFsRenameAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        string baseDir = !string.IsNullOrWhiteSpace(req.WorkingDirectory) ? req.WorkingDirectory : Config.WorkspaceRoot;
        string target = FileSystem.ResolvePathRelativeTo(req.TargetPath!, baseDir);
        FsMutationResult res = FileSystem.RenameItem(target, req.NewName!, req.RegisteredProjectPaths);
        EnsureMutationSucceeded(res);
        return Task.FromResult<object?>(res);
    }

    private Task<object?> ExecuteFsDeleteAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        string baseDir = !string.IsNullOrWhiteSpace(req.WorkingDirectory) ? req.WorkingDirectory : Config.WorkspaceRoot;
        IReadOnlyList<string> targets = ResolveSourceList(req, baseDir);
        FsMutationResult res = FileSystem.DeleteItems(targets, req.Permanent, req.RegisteredProjectPaths);
        EnsureMutationSucceeded(res);
        return Task.FromResult<object?>(res);
    }

    private object ExecuteTasksList(CapabilityInvocationRequest req)
    {
        ProcessSortField sort = req.Tag?.Trim().ToLowerInvariant() switch
        {
            "mem" or "memory" => ProcessSortField.Memory,
            "pid" => ProcessSortField.Pid,
            "name" => ProcessSortField.Name,
            _ => ProcessSortField.Cpu
        };
        int cap = Math.Clamp(req.Limit ?? 50, 1, 200);
        ProcessListSnapshot snap = Telemetry.GetProcesses(limit: cap, sort: sort, filter: req.Query);
        return new ProcessListSnapshot(snap.TopProcesses, snap.TotalProcessCount, snap.TotalWorkingSetBytes, snap.CapturedAtUtc);
    }

    private ProcessDetailedInspection ExecuteTaskInspect(CapabilityInvocationRequest req)
    {
        int pid = req.Pid ?? throw new DispatchFailureException(2, new ErrorDetail("MISSING_ARGUMENT", "Missing '--pid'.", "core"));
        ProcessDetailedInspection? detail = Telemetry.InspectProcess(pid);
        if (detail is null)
            throw new DispatchFailureException(3, new ErrorDetail("PROCESS_NOT_FOUND", $"Process PID {pid} was not found.", "windows"));
        return detail;
    }

    private async Task<object?> ExecuteTaskTerminateAsync(CapabilityInvocationRequest req, CancellationToken ct)
    {
        int pid = req.Pid ?? req.ExpectedProcessIdentity?.Pid ?? throw new DispatchFailureException(2, new ErrorDetail("MISSING_ARGUMENT", "Missing '--pid'.", "core"));
        ProcessIdentityToken identity = req.ExpectedProcessIdentity ?? new ProcessIdentityToken(pid, 0, $"PID {pid}", null);
        ProcessTerminationResult res = req.ForceTerminate
            ? ProcessTermination.ForceTerminate(identity, secondConfirmationExplicit: req.Confirmed)
            : await ProcessTermination.TryGracefulCloseAsync(identity, ct).ConfigureAwait(false);

        if (!res.Success)
        {
            string code = res.ErrorCode ?? "TERMINATE_FAILED";
            int exitCode = code switch
            {
                "PROTECTED_PROCESS" or "ACCESS_DENIED" or "SECOND_CONFIRMATION_REQUIRED" => 2,
                "PROCESS_EXITED" or "PID_REUSED" => 3,
                _ => 1
            };
            throw new DispatchFailureException(exitCode, new ErrorDetail(code, res.Message, "windows"));
        }
        return res;
    }

    private IReadOnlyList<string> ResolveSourceList(CapabilityInvocationRequest req, string baseDir)
    {
        if (req.SourcePaths is { Count: > 0 })
            return req.SourcePaths.Select(s => FileSystem.ResolvePathRelativeTo(s, baseDir)).ToArray();

        if (!string.IsNullOrWhiteSpace(req.TargetPath))
            return [FileSystem.ResolvePathRelativeTo(req.TargetPath, baseDir)];

        throw new DispatchFailureException(2, new ErrorDetail("MISSING_ARGUMENT", $"Capability '{req.CapabilityId}' requires source path(s).", "core"));
    }

    private static void EnsureMutationSucceeded(FsMutationResult res)
    {
        if (res.Success)
            return;

        string code = res.ErrorCode ?? "FS_ERROR";
        int exitCode = code switch
        {
            "POLICY_BLOCKED" or "INVALID_NAME" or "INVALID_DESTINATION" or "EMPTY_SELECTION" => 2,
            "NOT_FOUND" or "DESTINATION_NOT_FOUND" => 3,
            _ => 1
        };

        string failedDetails = res.ItemResults.Count > 0
            ? string.Join("; ", res.ItemResults.Where(r => !r.Succeeded).Select(r => $"{Path.GetFileName(r.SourcePath)} ({r.ErrorCode}): {r.Message}"))
            : res.Message;

        string msg = res.ItemResults.Any(r => !r.Succeeded)
            ? $"{res.Message} [{failedDetails}]"
            : res.Message;

        throw new DispatchFailureException(exitCode, new ErrorDetail(code, msg, "fs"));
    }

    public IReadOnlyList<ToolAvailability> ProbeRelevantTools()
    {
        var specs = new (string Name, string[] Fallbacks)[]
        {
            ("wsctl", [Config.WsctlScriptPath]),
            ("ulvo", [Config.UlvoExecutable]),
            ("pwsh", [Config.PwshExecutable]),
            ("git", []),
            ("dotnet", []),
            ("python", []),
            ("uv", []),
            ("rg", []),
            ("fd", []),
            ("fzf", []),
            ("yazi", []),
            ("lazygit", [])
        };

        var result = new List<ToolAvailability>(specs.Length);
        foreach ((string name, string[] fallbacks) in specs)
        {
            string? path = ProcessRunner.FindExecutableOnPath(name, fallbacks);
            result.Add(new ToolAvailability(name, path is not null, path));
        }
        return result;
    }

    private static DispatchOutcome MakeError(int exitCode, string capId, DateTimeOffset now, long durationMs, ErrorDetail err)
        => new(exitCode, new CapabilityEnvelope<object?>(1, false, capId, now, "live", durationMs, null, err));

    private static int MapProviderExitCode(ProviderStatus status, ErrorDetail? err)
        => status switch
        {
            ProviderStatus.Unavailable => 4,
            ProviderStatus.Timeout => 5,
            _ when err?.Code is "WSCTL_CANCELLED" or "ULVO_CANCELLED" => 5,
            _ => 1
        };

    private sealed class DispatchFailureException(int exitCode, ErrorDetail detail) : Exception(detail.Message)
    {
        public int ExitCode { get; } = exitCode;
        public ErrorDetail Detail { get; } = detail;
    }
}
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using WorkCtlNext.Core;

namespace WorkCtlNext.Providers;

public sealed class WindowsTelemetryProvider
{
    private readonly object _sampleLock = new();
    private readonly WorkctlPathsConfig? _pathsConfig;
    private bool _hasCpuSample;
    private ulong _lastIdleTicks;
    private ulong _lastKernelTicks;
    private ulong _lastUserTicks;
    private double _lastCpuPercent;
    private Dictionary<int, (TimeSpan Cpu, DateTimeOffset At)> _processCpuSamples = new();
    private readonly ConcurrentDictionary<(int Pid, long CreatedTicks), string> _ownerCache = new();
    private readonly ConcurrentDictionary<int, long> _workCtlOwnedPids = new();

    public WindowsTelemetryProvider(WorkctlPathsConfig? pathsConfig = null)
    {
        _pathsConfig = pathsConfig;
    }

    public void RegisterOwnedProcess(int pid, long creationTimeUtcTicks = 0)
    {
        if (pid > 4)
            _workCtlOwnedPids[pid] = creationTimeUtcTicks;
    }

    public void UnregisterOwnedProcess(int pid)
        => _workCtlOwnedPids.TryRemove(pid, out _);

    public bool IsWorkCtlOwnedPid(int pid, long creationTimeUtcTicks)
        => _workCtlOwnedPids.TryGetValue(pid, out long recorded)
           && (recorded == 0 || creationTimeUtcTicks == 0 || recorded == creationTimeUtcTicks);

    public ProcessListSnapshot GetTopProcesses(int limit = 25)
        => GetProcesses(limit: Math.Clamp(limit, 1, 100), sort: ProcessSortField.Cpu);

    public ProcessListSnapshot GetProcesses(
        int? limit = null,
        ProcessSortField sort = ProcessSortField.Cpu,
        string? filter = null,
        bool resolveOwners = false)
    {
        DateTimeOffset now = DateTimeOffset.UtcNow;
        var entries = new List<ProcessEntrySnapshot>(384);
        long totalWorkingSet = 0;
        int totalCount = 0;
        var nextSamples = new Dictionary<int, (TimeSpan Cpu, DateTimeOffset At)>();
        int logicalProcessors = Math.Max(1, Environment.ProcessorCount);
        Dictionary<int, Win32ProcessInterop.ToolhelpEntry> toolhelp = Win32ProcessInterop.CaptureToolhelpMap();

        Process[] processes = Process.GetProcesses();
        try
        {
            totalCount = processes.Length;
            lock (_sampleLock)
            {
                foreach (Process p in processes)
                {
                    try
                    {
                        int pid = p.Id;
                        long ws = p.WorkingSet64;
                        long priv = p.PrivateMemorySize64;
                        totalWorkingSet += ws;

                        TimeSpan cpuTime = TimeSpan.Zero;
                        try { cpuTime = p.TotalProcessorTime; } catch { }

                        double cpuPct = 0;
                        if (_processCpuSamples.TryGetValue(pid, out var prev))
                        {
                            double wallMs = (now - prev.At).TotalMilliseconds;
                            if (wallMs >= 50)
                            {
                                double cpuMs = (cpuTime - prev.Cpu).TotalMilliseconds;
                                if (cpuMs >= 0)
                                    cpuPct = Math.Clamp(cpuMs / (wallMs * logicalProcessors) * 100.0, 0.0, 100.0);
                            }
                        }
                        nextSamples[pid] = (cpuTime, now);

                        int threads = 0;
                        if (toolhelp.TryGetValue(pid, out Win32ProcessInterop.ToolhelpEntry? th))
                            threads = unchecked((int)th.Threads);
                        else
                        {
                            try { threads = p.Threads.Count; } catch { }
                        }

                        string? title = null;
                        bool hasVisibleWindow = false;
                        try
                        {
                            IntPtr hwnd = p.MainWindowHandle;
                            string t = p.MainWindowTitle;
                            if (!string.IsNullOrWhiteSpace(t))
                                title = t;
                            hasVisibleWindow = hwnd != IntPtr.Zero && Win32SystemInterop.IsWindowVisible(hwnd);
                        }
                        catch { }

                        Win32ProcessInterop.TryQueryProcessMetadata(
                            pid,
                            includeOwner: false,
                            out long createdTicks,
                            out string? exePath,
                            out _,
                            out _);

                        if (createdTicks == 0)
                        {
                            try { createdTicks = p.StartTime.ToUniversalTime().Ticks; } catch { }
                        }
                        if (exePath is null)
                        {
                            try { exePath = p.MainModule?.FileName; } catch { }
                        }

                        string? cachedOwner = null;
                        if (_ownerCache.TryGetValue((pid, createdTicks), out string? o))
                        {
                            cachedOwner = o;
                        }
                        else if (resolveOwners && pid > 4)
                        {
                            if (Win32ProcessInterop.TryQueryProcessMetadata(pid, includeOwner: true, out _, out _, out string? fetchedOwner, out _) &&
                                !string.IsNullOrWhiteSpace(fetchedOwner))
                            {
                                cachedOwner = fetchedOwner;
                                _ownerCache[(pid, createdTicks)] = fetchedOwner;
                            }
                        }

                        int ppid = th?.ParentPid ?? 0;

                        entries.Add(new ProcessEntrySnapshot(
                            Pid: pid,
                            Name: p.ProcessName,
                            WorkingSetBytes: ws,
                            PrivateMemoryBytes: priv,
                            TotalProcessorTime: cpuTime,
                            CpuPercentApprox: Math.Round(cpuPct, 1),
                            ThreadCount: threads,
                            ExecutablePath: exePath,
                            WindowTitle: title,
                            ParentPid: ppid,
                            CreationTimeUtcTicks: createdTicks,
                            Owner: cachedOwner,
                            HasVisibleWindow: hasVisibleWindow));
                    }
                    catch
                    {
                        // Protected system/idle processes may reject per-process handles.
                    }
                }

                _processCpuSamples = nextSamples;
            }
        }
        finally
        {
            foreach (Process p in processes)
                p.Dispose();
        }

        IEnumerable<ProcessEntrySnapshot> query = entries;
        if (!string.IsNullOrWhiteSpace(filter))
        {
            string f = filter.Trim();
            query = query.Where(e =>
                e.Name.Contains(f, StringComparison.OrdinalIgnoreCase) ||
                e.Pid.ToString().Contains(f, StringComparison.OrdinalIgnoreCase) ||
                (e.ExecutablePath?.Contains(f, StringComparison.OrdinalIgnoreCase) ?? false) ||
                (e.Owner?.Contains(f, StringComparison.OrdinalIgnoreCase) ?? false) ||
                (e.WindowTitle?.Contains(f, StringComparison.OrdinalIgnoreCase) ?? false));
        }

        IOrderedEnumerable<ProcessEntrySnapshot> sorted = sort switch
        {
            ProcessSortField.Memory => query.OrderByDescending(e => e.WorkingSetBytes).ThenBy(e => e.Pid),
            ProcessSortField.Pid => query.OrderBy(e => e.Pid),
            ProcessSortField.Name => query.OrderBy(e => e.Name, StringComparer.OrdinalIgnoreCase).ThenBy(e => e.Pid),
            _ => query.OrderByDescending(e => e.CpuPercentApprox > 0.1 ? e.CpuPercentApprox : 0)
                      .ThenByDescending(e => e.WorkingSetBytes)
                      .ThenBy(e => e.Pid)
        };

        ProcessEntrySnapshot[] allArray = sorted.ToArray();
        IReadOnlyList<ProcessEntrySnapshot> top = limit.HasValue
            ? allArray.Take(Math.Clamp(limit.Value, 1, 500)).ToArray()
            : allArray;

        return new ProcessListSnapshot(top, totalCount, totalWorkingSet, now, allArray);
    }

    public static IReadOnlyList<ProcessTreeRow> BuildProcessTree(IReadOnlyList<ProcessEntrySnapshot> processes)
    {
        var byPid = new Dictionary<int, ProcessEntrySnapshot>(processes.Count);
        foreach (ProcessEntrySnapshot p in processes)
            byPid[p.Pid] = p;

        // Validate parent links causally using CreationTimeUtcTicks so reused OS PIDs never falsely become parents.
        var childrenByParent = new Dictionary<int, List<ProcessEntrySnapshot>>();
        var roots = new List<ProcessEntrySnapshot>();

        foreach (ProcessEntrySnapshot child in processes)
        {
            if (child.ParentPid > 0 &&
                child.ParentPid != child.Pid &&
                byPid.TryGetValue(child.ParentPid, out ProcessEntrySnapshot? parent) &&
                IsCausallyValidParent(parent, child))
            {
                if (!childrenByParent.TryGetValue(parent.Pid, out var list))
                {
                    list = [];
                    childrenByParent[parent.Pid] = list;
                }
                list.Add(child);
            }
            else
            {
                roots.Add(child);
            }
        }

        var result = new List<ProcessTreeRow>(processes.Count);
        var visited = new HashSet<int>();

        void Visit(ProcessEntrySnapshot node, int depth, string prefix, bool hasValidParent)
        {
            if (!visited.Add(node.Pid))
                return;

            List<ProcessEntrySnapshot>? kids = childrenByParent.TryGetValue(node.Pid, out var foundKids) ? foundKids : null;
            int kidCount = kids?.Count ?? 0;
            result.Add(new ProcessTreeRow(node, depth, hasValidParent, kidCount, prefix));

            if (kids is null || kids.Count == 0)
                return;

            var orderedKids = kids
                .OrderByDescending(k => k.WorkingSetBytes)
                .ThenBy(k => k.Pid)
                .ToList();
            for (int i = 0; i < orderedKids.Count; i++)
            {
                bool isLast = i == orderedKids.Count - 1;
                string childPrefix = depth == 0
                    ? (isLast ? "`- " : "|- ")
                    : (prefix.Replace("`- ", "   ").Replace("|- ", "|  ") + (isLast ? "`- " : "|- "));
                Visit(orderedKids[i], depth + 1, childPrefix, hasValidParent: true);
            }
        }

        foreach (ProcessEntrySnapshot root in roots.OrderByDescending(r => r.WorkingSetBytes).ThenBy(r => r.Pid))
        {
            Visit(root, 0, string.Empty, hasValidParent: false);
        }

        // Append any residual nodes if a malformed cycle ever occurred
        foreach (ProcessEntrySnapshot p in processes)
        {
            if (!visited.Contains(p.Pid))
                result.Add(new ProcessTreeRow(p, 0, false, 0, string.Empty));
        }

        return result;
    }

    public static bool IsCausallyValidParent(ProcessEntrySnapshot parent, ProcessEntrySnapshot child)
    {
        if (parent.CreationTimeUtcTicks == 0 || child.CreationTimeUtcTicks == 0)
            return true;
        return parent.CreationTimeUtcTicks <= child.CreationTimeUtcTicks;
    }

    public ProcessDetailedInspection? InspectProcess(int pid, IReadOnlyList<ProcessEntrySnapshot>? existingSnapshot = null)
    {
        ProcessListSnapshot snap = existingSnapshot is null
            ? GetProcesses(resolveOwners: false)
            : new ProcessListSnapshot(existingSnapshot, existingSnapshot.Count, 0, DateTimeOffset.UtcNow, existingSnapshot);

        IReadOnlyList<ProcessEntrySnapshot> pool = snap.AllProcesses ?? snap.TopProcesses;
        ProcessEntrySnapshot? target = pool.FirstOrDefault(p => p.Pid == pid);
        if (target is null)
            return null;

        var unavailable = new List<string>();
        bool metaOk = Win32ProcessInterop.TryQueryProcessMetadata(
            pid,
            includeOwner: true,
            out long liveTicks,
            out string? exePath,
            out string? owner,
            out string? ownerReason);

        if (liveTicks == 0)
            liveTicks = target.CreationTimeUtcTicks;
        exePath ??= target.ExecutablePath;
        if (string.IsNullOrWhiteSpace(exePath))
            unavailable.Add("ExecutablePath (access denied or kernel process)");

        string ownerStatus;
        if (!string.IsNullOrWhiteSpace(owner))
        {
            ownerStatus = owner;
            _ownerCache[(pid, liveTicks)] = owner;
        }
        else if (!metaOk && ownerReason is not null)
        {
            ownerStatus = ownerReason;
            unavailable.Add($"Owner ({ownerReason})");
        }
        else
        {
            ownerStatus = ownerReason ?? "Unavailable";
            unavailable.Add($"Owner ({ownerStatus})");
        }

        ProcessEntrySnapshot enrichedTarget = target with
        {
            CreationTimeUtcTicks = liveTicks,
            ExecutablePath = exePath,
            Owner = owner
        };

        var byPid = pool.ToDictionary(p => p.Pid, p => p);
        int? verifiedParentPid = null;
        string? verifiedParentName = null;
        bool parentExitedOrReused = false;
        if (enrichedTarget.ParentPid > 0 && enrichedTarget.ParentPid != enrichedTarget.Pid)
        {
            if (byPid.TryGetValue(enrichedTarget.ParentPid, out ProcessEntrySnapshot? parent) && IsCausallyValidParent(parent, enrichedTarget))
            {
                verifiedParentPid = parent.Pid;
                verifiedParentName = parent.Name;
            }
            else
            {
                parentExitedOrReused = true;
            }
        }

        IReadOnlyList<ProcessEntrySnapshot> children = pool
            .Where(c => c.Pid != enrichedTarget.Pid && c.ParentPid == enrichedTarget.Pid && IsCausallyValidParent(enrichedTarget, c))
            .OrderByDescending(c => c.WorkingSetBytes)
            .ToArray();

        Dictionary<int, List<ProcessServiceAssociation>> servicesByPid = Win32ProcessInterop.CaptureServicesByPid();
        IReadOnlyList<ProcessServiceAssociation> svcs = servicesByPid.TryGetValue(pid, out var svcList)
            ? svcList
            : Array.Empty<ProcessServiceAssociation>();

        HashSet<int> ancestorHostPids = ComputeWorkCtlAncestorPids(byPid);
        bool isSelf = pid == Environment.ProcessId;
        bool isAncestorHost = !isSelf && ancestorHostPids.Contains(pid);
        bool isOwned = IsWorkCtlOwnedPid(pid, liveTicks);
        bool isUlvo = IsUlvoManagedProcess(enrichedTarget, byPid);
        bool isCritical = IsCriticalProtectedProcess(enrichedTarget, svcs, isSelf, isAncestorHost, isUlvo, out string? blockReason);
        bool supportsGraceful = !isCritical && enrichedTarget.HasVisibleWindow;

        return new ProcessDetailedInspection(
            Process: enrichedTarget,
            VerifiedParentPid: verifiedParentPid,
            VerifiedParentName: verifiedParentName,
            ParentExitedOrReused: parentExitedOrReused,
            VerifiedChildren: children,
            AssociatedServices: svcs,
            IsProtected: isCritical,
            IsWorkCtlSelf: isSelf,
            IsAncestorHost: isAncestorHost,
            IsWorkCtlOwned: isOwned,
            IsUlvoManaged: isUlvo,
            SupportsGracefulClose: supportsGraceful,
            BlockReason: blockReason,
            OwnerStatus: ownerStatus,
            UnavailableFields: unavailable);
    }

    public static HashSet<int> ComputeWorkCtlAncestorPids(IReadOnlyDictionary<int, ProcessEntrySnapshot> byPid)
    {
        var ancestors = new HashSet<int>();
        if (!byPid.TryGetValue(Environment.ProcessId, out ProcessEntrySnapshot? cur))
            return ancestors;

        for (int hop = 0; hop < 16; hop++)
        {
            if (cur.ParentPid <= 0 || cur.ParentPid == cur.Pid)
                break;
            if (!byPid.TryGetValue(cur.ParentPid, out ProcessEntrySnapshot? parent))
                break;
            if (!IsCausallyValidParent(parent, cur) || !ancestors.Add(parent.Pid))
                break;
            cur = parent;
        }
        return ancestors;
    }

    public bool IsUlvoManagedProcess(ProcessEntrySnapshot proc, IReadOnlyDictionary<int, ProcessEntrySnapshot> byPid)
    {
        if (MatchesUlvoExeOrPath(proc))
            return true;

        ProcessEntrySnapshot cur = proc;
        var seen = new HashSet<int> { proc.Pid };
        for (int hop = 0; hop < 8; hop++)
        {
            if (cur.ParentPid <= 0 || !byPid.TryGetValue(cur.ParentPid, out ProcessEntrySnapshot? parent))
                break;
            if (!IsCausallyValidParent(parent, cur) || !seen.Add(parent.Pid))
                break;
            if (MatchesUlvoExeOrPath(parent))
                return true;
            cur = parent;
        }
        return false;
    }

    private bool MatchesUlvoExeOrPath(ProcessEntrySnapshot proc)
    {
        if (string.Equals(proc.Name, "ulvo", StringComparison.OrdinalIgnoreCase))
            return true;

        if (!string.IsNullOrWhiteSpace(proc.ExecutablePath))
        {
            string p = PathNormalizer.NormalizeForCompare(proc.ExecutablePath);
            if (_pathsConfig is not null && !string.IsNullOrWhiteSpace(_pathsConfig.UlvoExecutable) && Path.IsPathRooted(_pathsConfig.UlvoExecutable))
            {
                if (string.Equals(p, PathNormalizer.NormalizeForCompare(_pathsConfig.UlvoExecutable), StringComparison.OrdinalIgnoreCase))
                    return true;
            }
            if (p.Contains(@"\ULVO\", StringComparison.OrdinalIgnoreCase) || p.Contains(@"\.ulvo\", StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    private static bool IsCriticalProtectedProcess(
        ProcessEntrySnapshot proc,
        IReadOnlyList<ProcessServiceAssociation> svcs,
        bool isSelf,
        bool isAncestorHost,
        bool isUlvo,
        out string? blockReason)
    {
        if (isSelf)
        {
            blockReason = "Cannot terminate the active WorkCtl Next process from its own task manager.";
            return true;
        }
        if (isAncestorHost)
        {
            blockReason = $"Cannot terminate ancestor terminal/shell host '{proc.Name}' (PID {proc.Pid}).";
            return true;
        }
        if (proc.Pid is 0 or 4)
        {
            blockReason = "Windows kernel/idle process is protected and cannot be terminated.";
            return true;
        }
        if (CriticalWindowsProcessNames.Contains(proc.Name))
        {
            blockReason = $"Protected critical Windows system process '{proc.Name}' cannot be terminated.";
            return true;
        }
        if (isUlvo)
        {
            blockReason = "ULVO-managed workload requires ULVO lifecycle authorization (cannot terminate directly).";
            return true;
        }
        if (svcs.Count > 0)
        {
            blockReason = $"Process hosts active Windows service(s): {string.Join(", ", svcs.Select(s => s.ServiceName))}. Service modification is deferred.";
            return true;
        }
        blockReason = null;
        return false;
    }

    private static readonly HashSet<string> CriticalWindowsProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "System", "Idle", "Registry", "Secure System", "Memory Compression",
        "smss", "csrss", "wininit", "services", "lsass", "lsaiso",
        "winlogon", "dwm", "fontdrvhost", "svchost", "audiodg", "sihost", "vmmem"
    };

    public async Task<PerformanceSnapshot> GetPerformanceSnapshotAsync(CancellationToken cancellationToken)
    {
        bool needPrimingSample;
        lock (_sampleLock)
        {
            needPrimingSample = !_hasCpuSample;
        }

        if (needPrimingSample)
        {
            SampleCpuPercent();
            await Task.Delay(80, cancellationToken).ConfigureAwait(false);
        }

        double cpuPct = SampleCpuPercent();
        Win32SystemInterop.TryGetMemoryStatus(out ulong totalRam, out ulong availRam, out uint memLoad);
        long totalRamSigned = totalRam > long.MaxValue ? long.MaxValue : (long)totalRam;
        long availRamSigned = availRam > long.MaxValue ? long.MaxValue : (long)availRam;
        double ramUsedPct = totalRamSigned > 0
            ? Math.Round((double)(totalRamSigned - availRamSigned) / totalRamSigned * 100.0, 1)
            : memLoad;

        int procCount = 0;
        int threadCount = 0;
        string? topProcName = null;
        int topProcPid = 0;
        long maxWs = -1;

        Process[] processes = Process.GetProcesses();
        try
        {
            procCount = processes.Length;
            foreach (Process p in processes)
            {
                try
                {
                    int threads = p.Threads.Count;
                    threadCount += threads;
                    long ws = p.WorkingSet64;
                    if (ws > maxWs && p.Id > 4)
                    {
                        maxWs = ws;
                        topProcName = p.ProcessName;
                        topProcPid = p.Id;
                    }
                }
                catch
                {
                }
            }
        }
        finally
        {
            foreach (Process p in processes)
                p.Dispose();
        }

        return new PerformanceSnapshot(
            CpuUtilizationPercent: Math.Round(cpuPct, 1),
            ProcessCount: procCount,
            ThreadCount: threadCount,
            TotalRamBytes: totalRamSigned,
            AvailableRamBytes: availRamSigned,
            RamUsedPercent: ramUsedPct,
            Uptime: TimeSpan.FromMilliseconds(Environment.TickCount64),
            TopCpuProcessName: topProcName,
            TopCpuProcessPid: topProcPid,
            CapturedAtUtc: DateTimeOffset.UtcNow);
    }

    public StorageSnapshot GetStorageSnapshot()
    {
        var volumes = new List<VolumeSnapshot>();
        long totalCap = 0;
        long totalFree = 0;

        foreach (DriveInfo drive in DriveInfo.GetDrives())
        {
            try
            {
                if (!drive.IsReady)
                {
                    volumes.Add(new VolumeSnapshot(
                        Name: drive.Name,
                        Label: string.Empty,
                        DriveType: drive.DriveType.ToString(),
                        FileSystem: string.Empty,
                        TotalBytes: 0,
                        FreeBytes: 0,
                        UsedBytes: 0,
                        UsedPercent: 0,
                        IsReady: false));
                    continue;
                }

                long total = drive.TotalSize;
                long free = drive.AvailableFreeSpace;
                long used = Math.Max(0, total - free);
                double usedPct = total > 0 ? Math.Round((double)used / total * 100.0, 1) : 0;
                totalCap += total;
                totalFree += free;

                volumes.Add(new VolumeSnapshot(
                    Name: drive.Name,
                    Label: drive.VolumeLabel,
                    DriveType: drive.DriveType.ToString(),
                    FileSystem: drive.DriveFormat,
                    TotalBytes: total,
                    FreeBytes: free,
                    UsedBytes: used,
                    UsedPercent: usedPct,
                    IsReady: true));
            }
            catch
            {
            }
        }

        return new StorageSnapshot(volumes, totalCap, totalFree, DateTimeOffset.UtcNow);
    }

    public NetworkSnapshot GetNetworkSnapshot()
    {
        var list = new List<NetworkInterfaceSnapshot>();
        int upCount = 0;

        foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                continue;

            try
            {
                bool isUp = ni.OperationalStatus == OperationalStatus.Up;
                if (isUp)
                    upCount++;

                IPInterfaceProperties ipProps = ni.GetIPProperties();
                string ipv4 = string.Join(", ", ipProps.UnicastAddresses
                    .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
                    .Select(a => a.Address.ToString()));
                string gateways = string.Join(", ", ipProps.GatewayAddresses
                    .Select(g => g.Address.ToString())
                    .Where(g => !string.IsNullOrWhiteSpace(g)));

                long rx = 0;
                long tx = 0;
                try
                {
                    IPv4InterfaceStatistics stats = ni.GetIPv4Statistics();
                    rx = stats.BytesReceived;
                    tx = stats.BytesSent;
                }
                catch { }

                list.Add(new NetworkInterfaceSnapshot(
                    Name: ni.Name,
                    Description: ni.Description,
                    Type: ni.NetworkInterfaceType.ToString(),
                    Status: ni.OperationalStatus.ToString(),
                    SpeedMbps: ni.Speed > 0 ? ni.Speed / 1_000_000 : 0,
                    IPv4Addresses: string.IsNullOrWhiteSpace(ipv4) ? null : ipv4,
                    GatewayAddresses: string.IsNullOrWhiteSpace(gateways) ? null : gateways,
                    BytesReceived: rx,
                    BytesSent: tx));
            }
            catch
            {
            }
        }

        IReadOnlyList<NetworkInterfaceSnapshot> ordered = list
            .OrderByDescending(i => string.Equals(i.Status, "Up", StringComparison.OrdinalIgnoreCase))
            .ThenByDescending(i => i.SpeedMbps)
            .ThenBy(i => i.Name, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        return new NetworkSnapshot(ordered, upCount, ordered.Count, DateTimeOffset.UtcNow);
    }

    public RunningAppsSnapshot GetRunningApps(int limit = 40)
    {
        int capped = Math.Clamp(limit, 1, 100);
        var apps = new List<RunningAppSnapshot>();
        Process[] processes = Process.GetProcesses();
        try
        {
            foreach (Process p in processes)
            {
                try
                {
                    IntPtr hwnd = p.MainWindowHandle;
                    if (hwnd == IntPtr.Zero)
                        continue;

                    string title = p.MainWindowTitle;
                    if (string.IsNullOrWhiteSpace(title))
                        continue;

                    bool visible = Win32SystemInterop.IsWindowVisible(hwnd);
                    if (!visible)
                        continue;

                    string? exe = null;
                    try { exe = p.MainModule?.FileName; } catch { }

                    apps.Add(new RunningAppSnapshot(
                        Pid: p.Id,
                        ProcessName: p.ProcessName,
                        WindowTitle: title,
                        WorkingSetBytes: p.WorkingSet64,
                        HasVisibleWindow: true,
                        ExecutablePath: exe));
                }
                catch
                {
                }
            }
        }
        finally
        {
            foreach (Process p in processes)
                p.Dispose();
        }

        IReadOnlyList<RunningAppSnapshot> ordered = apps
            .OrderByDescending(a => a.WorkingSetBytes)
            .Take(capped)
            .ToArray();

        return new RunningAppsSnapshot(ordered, DateTimeOffset.UtcNow);
    }

    private double SampleCpuPercent()
    {
        if (!Win32SystemInterop.TryGetSystemTimes(out ulong idle, out ulong kernel, out ulong user))
            return _lastCpuPercent;

        lock (_sampleLock)
        {
            if (!_hasCpuSample)
            {
                _lastIdleTicks = idle;
                _lastKernelTicks = kernel;
                _lastUserTicks = user;
                _hasCpuSample = true;
                return _lastCpuPercent;
            }

            ulong deltaIdle = idle >= _lastIdleTicks ? idle - _lastIdleTicks : 0;
            ulong deltaKernel = kernel >= _lastKernelTicks ? kernel - _lastKernelTicks : 0;
            ulong deltaUser = user >= _lastUserTicks ? user - _lastUserTicks : 0;

            _lastIdleTicks = idle;
            _lastKernelTicks = kernel;
            _lastUserTicks = user;

            ulong total = deltaKernel + deltaUser;
            if (total == 0)
                return _lastCpuPercent;

            // Win32 kernel time includes idle time.
            ulong busy = total >= deltaIdle ? total - deltaIdle : 0;
            _lastCpuPercent = Math.Clamp((double)busy / total * 100.0, 0.0, 100.0);
            return _lastCpuPercent;
        }
    }
}

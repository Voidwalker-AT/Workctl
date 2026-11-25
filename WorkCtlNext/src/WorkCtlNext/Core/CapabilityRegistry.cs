namespace WorkCtlNext.Core;

public delegate Task<object?> CapabilityExecutorAsync(
    CapabilityInvocationRequest request,
    CancellationToken cancellationToken);

public sealed record CapabilityInvocationRequest(
    string CapabilityId,
    string? ProjectId = null,
    string? ProjectPath = null,
    string? Category = null,
    string? Tag = null,
    string? Query = null,
    string? CurrentScreen = null,
    ProjectSummary? ActiveProject = null,
    bool Detailed = false,
    bool IncludeEnvStatus = false,
    bool IncludeProjects = false,
    int? Limit = null,
    string? TargetPath = null,
    string? WorkingDirectory = null,
    IReadOnlyList<string>? SourcePaths = null,
    string? DestinationPath = null,
    string? NewName = null,
    bool Confirmed = false,
    bool Permanent = false,
    IReadOnlyCollection<string>? RegisteredProjectPaths = null,
    CallerSurface Caller = CallerSurface.HumanTui,
    int? Pid = null,
    ProcessIdentityToken? ExpectedProcessIdentity = null,
    bool ForceTerminate = false);

public sealed record RegisteredCapability(
    string Id,
    string DisplayName,
    string Description,
    string Provider,
    RiskClassification Risk,
    IReadOnlyList<string> RequiredArguments,
    IReadOnlyList<string> OutputFormats,
    string CliCommand,
    CapabilityExecutorAsync Executor);

/// <summary>
/// Single in-process capability catalog shared identically by both Human TUI and Agent CLI.
/// </summary>
public sealed class CapabilityRegistry
{
    private readonly Dictionary<string, RegisteredCapability> _entries = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<RegisteredCapability> _ordered = [];

    public void Register(RegisteredCapability entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (_entries.ContainsKey(entry.Id))
            throw new InvalidOperationException($"Duplicate capability ID '{entry.Id}'.");
        _entries[entry.Id] = entry;
        _ordered.Add(entry);
    }

    public bool TryGet(string id, out RegisteredCapability? capability)
        => _entries.TryGetValue(id, out capability);

    public IReadOnlyList<RegisteredCapability> All => _ordered;

    public IReadOnlyList<CapabilityInfo> DescribeAll(WorkctlPathsConfig config)
        => DescribeAll(config, gitAvailable: ProcessRunner.FindExecutableOnPath("git") is not null);

    public IReadOnlyList<CapabilityInfo> DescribeAll(WorkctlPathsConfig config, bool gitAvailable)
    {
        bool wsctlAvail = !string.IsNullOrWhiteSpace(config.PwshExecutable)
            && File.Exists(config.PwshExecutable)
            && File.Exists(config.WsctlScriptPath);
        bool ulvoAvail = !string.IsNullOrWhiteSpace(config.UlvoExecutable)
            && (Path.IsPathRooted(config.UlvoExecutable)
                ? File.Exists(config.UlvoExecutable)
                : ProcessRunner.FindExecutableOnPath(config.UlvoExecutable) is not null);

        var list = new List<CapabilityInfo>(_ordered.Count);
        foreach (RegisteredCapability cap in _ordered)
        {
            string avail = cap.Provider switch
            {
                "wsctl" => wsctlAvail ? "available" : "unavailable",
                "ulvo" => ulvoAvail ? "available" : "unavailable",
                "git" => gitAvailable ? "available" : "unavailable",
                _ => "available"
            };

            list.Add(new CapabilityInfo(
                Id: cap.Id,
                DisplayName: cap.DisplayName,
                Description: cap.Description,
                Provider: cap.Provider,
                Risk: cap.Risk.ToString(),
                Availability: avail,
                RequiredArguments: cap.RequiredArguments,
                OutputFormats: cap.OutputFormats,
                CliCommand: cap.CliCommand));
        }

        return list;
    }
}
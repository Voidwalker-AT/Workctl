namespace WorkCtlNext.Core;

public enum CallerSurface
{
    HumanTui = 0,
    AgentCli = 1
}

public enum DispatcherPolicyMode
{
    ReadOnly = 0,
    InteractivePhase2 = 1
}

public enum FocusRegion
{
    NavigationTree = 0,
    MainPane = 1,
    CommandLine = 2
}

public enum NavigationSectionId
{
    MachineOverview = 0,
    MachineProcesses = 1,
    MachineServices = 2,
    MachinePerformance = 3,
    MachineStorage = 4,
    MachineNetwork = 5,

    FilesThisPc = 6,
    FilesQuickAccess = 7,
    FilesWorkspace = 8,
    FilesDownloads = 9,

    DevProjects = 10,
    DevGit = 11,
    DevUlvo = 12,
    DevToolchains = 13,

    AppsInstalled = 14,
    AppsRunning = 15,
    AppsStartup = 16
}

public enum ClipboardMode
{
    None = 0,
    Copy = 1,
    Cut = 2
}

public sealed record NavigationNodeDescriptor(
    NavigationSectionId Id,
    string Category,
    string Label,
    string? CapabilityId,
    bool IsEnabled,
    string? DisabledReason,
    string? ShortcutHint);

public sealed record FileClipboardState(
    ClipboardMode Mode,
    IReadOnlyList<string> Paths,
    string? SourceDirectory,
    DateTimeOffset CapturedAtUtc)
{
    public static readonly FileClipboardState Empty =
        new(ClipboardMode.None, Array.Empty<string>(), null, DateTimeOffset.MinValue);

    public bool HasItems => Mode != ClipboardMode.None && Paths.Count > 0;
}

public sealed record NavigationHistoryEntry(
    NavigationSectionId Section,
    string ActiveDirectory,
    string? ActiveProjectId);

public sealed record CommandResultFeedback(
    bool Success,
    string CommandText,
    string Headline,
    IReadOnlyList<string> Details,
    string? ErrorCode,
    DateTimeOffset ExecutedAtUtc);

public sealed record ConsoleTranscriptEntry(
    DateTimeOffset TimestampUtc,
    string CommandText,
    string ModeTag,
    bool Ok,
    int ExitCode,
    long DurationMs,
    IReadOnlyList<string> Lines,
    string WorkingDirectory);

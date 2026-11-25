namespace WorkCtlNext.Core;

public enum ProcessSortField
{
    Cpu = 0,
    Memory = 1,
    Pid = 2,
    Name = 3,
    Tree = 4
}

public sealed record ProcessEntrySnapshot(
    int Pid,
    string Name,
    long WorkingSetBytes,
    long PrivateMemoryBytes,
    TimeSpan TotalProcessorTime,
    double CpuPercentApprox,
    int ThreadCount,
    string? ExecutablePath,
    string? WindowTitle,
    int ParentPid = 0,
    long CreationTimeUtcTicks = 0,
    string? Owner = null,
    bool HasVisibleWindow = false);

public sealed record ProcessListSnapshot(
    IReadOnlyList<ProcessEntrySnapshot> TopProcesses,
    int TotalProcessCount,
    long TotalWorkingSetBytes,
    DateTimeOffset CapturedAtUtc,
    IReadOnlyList<ProcessEntrySnapshot>? AllProcesses = null);

public sealed record ProcessIdentityToken(
    int Pid,
    long CreationTimeUtcTicks,
    string Name,
    string? ExecutablePath);

public sealed record ProcessServiceAssociation(
    string ServiceName,
    string DisplayName,
    string State);

public sealed record ProcessTreeRow(
    ProcessEntrySnapshot Process,
    int Depth,
    bool HasValidParent,
    int DirectChildCount,
    string TreePrefix);

public sealed record ProcessDetailedInspection(
    ProcessEntrySnapshot Process,
    int? VerifiedParentPid,
    string? VerifiedParentName,
    bool ParentExitedOrReused,
    IReadOnlyList<ProcessEntrySnapshot> VerifiedChildren,
    IReadOnlyList<ProcessServiceAssociation> AssociatedServices,
    bool IsProtected,
    bool IsWorkCtlSelf,
    bool IsAncestorHost,
    bool IsWorkCtlOwned,
    bool IsUlvoManaged,
    bool SupportsGracefulClose,
    string? BlockReason,
    string OwnerStatus,
    IReadOnlyList<string> UnavailableFields);

public sealed record ProcessImpactAssessment(
    ProcessIdentityToken ExpectedIdentity,
    bool ProcessExists,
    bool PidReused,
    bool CanTerminate,
    string? BlockReason,
    bool SupportsGracefulClose,
    string GracefulExplanation,
    IReadOnlyList<string> VerifiedRelationships,
    IReadOnlyList<string> PossibleConsequences,
    IReadOnlyList<string> UnknownEffects,
    ProcessDetailedInspection? Detail);

public sealed record ProcessTerminationResult(
    bool Success,
    int Pid,
    string ProcessName,
    string Method,
    string Message,
    string? ErrorCode = null,
    int? ExitStatus = null);

public sealed record PerformanceSnapshot(
    double CpuUtilizationPercent,
    int ProcessCount,
    int ThreadCount,
    long TotalRamBytes,
    long AvailableRamBytes,
    double RamUsedPercent,
    TimeSpan Uptime,
    string? TopCpuProcessName,
    int TopCpuProcessPid,
    DateTimeOffset CapturedAtUtc);

public sealed record VolumeSnapshot(
    string Name,
    string Label,
    string DriveType,
    string FileSystem,
    long TotalBytes,
    long FreeBytes,
    long UsedBytes,
    double UsedPercent,
    bool IsReady);

public sealed record StorageSnapshot(
    IReadOnlyList<VolumeSnapshot> Volumes,
    long TotalCapacityBytes,
    long TotalFreeBytes,
    DateTimeOffset CapturedAtUtc);

public sealed record NetworkInterfaceSnapshot(
    string Name,
    string Description,
    string Type,
    string Status,
    long SpeedMbps,
    string? IPv4Addresses,
    string? GatewayAddresses,
    long BytesReceived,
    long BytesSent);

public sealed record NetworkSnapshot(
    IReadOnlyList<NetworkInterfaceSnapshot> Interfaces,
    int UpCount,
    int TotalCount,
    DateTimeOffset CapturedAtUtc);

public sealed record RunningAppSnapshot(
    int Pid,
    string ProcessName,
    string WindowTitle,
    long WorkingSetBytes,
    bool HasVisibleWindow,
    string? ExecutablePath);

public sealed record RunningAppsSnapshot(
    IReadOnlyList<RunningAppSnapshot> Apps,
    DateTimeOffset CapturedAtUtc);

public sealed record GitChangedFile(
    string IndexStatus,
    string WorkTreeStatus,
    string Path,
    string? OriginalPath = null);

public sealed record GitRepositorySnapshot(
    string TargetPath,
    bool IsGitRepository,
    string? RepoRoot,
    string? BranchName,
    string? UpstreamBranch,
    int AheadCount,
    int BehindCount,
    bool IsDetachedHead,
    int StagedCount,
    int ModifiedCount,
    int UntrackedCount,
    int ConflictCount,
    IReadOnlyList<GitChangedFile> ChangedFiles,
    string? LastCommitSummary,
    string? ErrorMessage,
    DateTimeOffset CapturedAtUtc);

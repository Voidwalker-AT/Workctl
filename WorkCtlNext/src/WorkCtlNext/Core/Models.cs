using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WorkCtlNext.Core;

public enum RiskClassification
{
    ReadOnly = 0,
    OrdinarySafe = 1,
    Modifying = 2,
    Privileged = 3,
    Destructive = 4,
    Protected = 5
}

public enum ProviderStatus
{
    Available,
    Degraded,
    Unavailable,
    Stale,
    Error,
    Timeout
}

public sealed record ErrorDetail(
    string Code,
    string Message,
    string Provider,
    int? ExitCode = null,
    bool Retryable = false);

public sealed record CapabilityEnvelope<T>(
    int SchemaVersion,
    bool Ok,
    string Capability,
    DateTimeOffset CapturedAtUtc,
    string Freshness,
    long DurationMs,
    T? Data = default,
    ErrorDetail? Error = null);

public sealed record CapabilityInfo(
    string Id,
    string DisplayName,
    string Description,
    string Provider,
    string Risk,
    string Availability,
    IReadOnlyList<string> RequiredArguments,
    IReadOnlyList<string> OutputFormats,
    string CliCommand);

public sealed record FixedDiskSummary(
    string Name,
    string? Label,
    string? Format,
    double TotalGb,
    double FreeGb,
    bool IsReady,
    string? Error = null);

public sealed record MachineSnapshot(
    string MachineName,
    string OsVersion,
    string CpuName,
    int LogicalCores,
    double TotalRamMb,
    double AvailableRamMb,
    uint MemoryLoadPercent,
    int ProcessCount,
    IReadOnlyList<FixedDiskSummary> FixedDisks,
    string Status,
    IReadOnlyList<string> Errors,
    string? CpuError = null,
    string? MemoryError = null);

public sealed record ProjectActionSummary(
    string Name,
    string Risk,
    string? Executable = null,
    string? Description = null,
    bool Structured = false);

public sealed record ProjectSummary(
    string Id,
    string Name,
    string RelativePath,
    string FullPath,
    string Category,
    string Status,
    bool Accessible,
    string Environment,
    string Gpu,
    bool Git,
    IReadOnlyList<ProjectActionSummary> Actions,
    IReadOnlyList<string>? Languages = null,
    IReadOnlyList<string>? Tags = null,
    string? Documentation = null);

public sealed record WsctlProjectsResult(
    ProviderStatus Status,
    string SourceMode,
    long DurationMs,
    IReadOnlyList<ProjectSummary> Projects,
    bool NormalizedFromSingleObject = false,
    ErrorDetail? Error = null);

public sealed record WsctlHealthSnapshot(
    ProviderStatus InfoStatus,
    string? WorkspaceRoot,
    int? RegisteredProjectsCount,
    string? LastAuditTimestamp,
    double? DoctorSnapshotAgeSeconds,
    bool DoctorSnapshotStale,
    string DoctorSnapshotStatus,
    int? DoctorOkCount,
    int? DoctorTotalChecks,
    string LiveDoctorPolicyNote,
    ErrorDetail? Error = null);

public sealed record UlvoStatusSummary(
    ProviderStatus Status,
    string? Version,
    bool VaultExists,
    int RegisteredProjects,
    string? CurrentProject,
    string? ProjectDiagnostic,
    long DurationMs,
    ErrorDetail? Error = null);

public sealed record UlvoListedProject(
    string Id,
    string Name,
    string CanonicalPath,
    string Ecosystem,
    string RegistrationState,
    bool HasConnector,
    string Classification,
    IReadOnlyList<string> Manifests,
    bool EnvHealthChecked = false,
    string EnvHealthState = "not_checked_on_ls");

public sealed record UlvoEnvStatusSummary(
    string? EnvironmentId,
    string? State,
    bool IsMaterialized,
    bool IsQuiescent,
    bool CanReclaim,
    string? PythonVersion);

public sealed record UlvoProjectInspection(
    ProviderStatus Status,
    string ProjectPath,
    bool HasConnector,
    string? ManifestName,
    string? ComplianceVerdict,
    string? PythonVersion,
    string? PythonManager,
    string? EnvironmentMode,
    bool? GpuRequired,
    string? GpuFramework,
    string? GpuCudaVersion,
    IReadOnlyList<string> NativeManifests,
    IReadOnlyList<string> Diagnostics,
    bool EnvStatusChecked,
    UlvoEnvStatusSummary? EnvStatus,
    long DurationMs,
    ErrorDetail? Error = null);

public sealed record UlvoRuntimesPayload(
    UlvoStatusSummary Summary,
    ProviderStatus ListStatus,
    int ListedTotal,
    IReadOnlyList<UlvoListedProject> Projects,
    string PolicyNote,
    ErrorDetail? ListError = null);

public sealed record ToolAvailability(
    string Name,
    bool Installed,
    string? Path = null);

public sealed record SuggestionItem(
    string CapabilityId,
    string DisplayName,
    string Command,
    string Provider,
    string Risk,
    double Score,
    string MatchKind,
    string Reason,
    bool Available);

public static class JsonDefaults
{
    public static readonly JsonSerializerOptions Compact = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
        WriteIndented = false
    };

    public static readonly JsonSerializerOptions Readable = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
        WriteIndented = true
    };
}

public static class PathNormalizer
{
    /// <summary>
    /// Strips Win32 verbatim extended-length prefixes (e.g. \\?\E:\... or \\?\UNC\server\share),
    /// matching ulvo_core::strip_unc_prefix semantics cleanly.
    /// </summary>
    public static string StripVerbatimPrefix(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return path;
        if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
            return @"\\" + path[@"\\?\UNC\".Length..];
        if (path.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
            return path[@"\\?\".Length..];
        return path;
    }

    public static string NormalizeForCompare(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return string.Empty;
        string stripped = StripVerbatimPrefix(path).Trim();
        string normalized;
        try
        {
            normalized = Path.GetFullPath(stripped).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }
        catch
        {
            normalized = stripped.Replace('/', Path.DirectorySeparatorChar).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }

        // Preserve trailing backslash on drive roots ("E:" -> "E:\") so Path.GetFullPath never treats them as drive-relative.
        if (normalized.Length == 2 && char.IsLetter(normalized[0]) && normalized[1] == ':')
        {
            normalized += Path.DirectorySeparatorChar;
        }

        return normalized;
    }

    public static string NormalizeDisplayPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return string.Empty;
        string normalized = NormalizeForCompare(path);
        return normalized;
    }

    public static string EnsureLongPathPrefix(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return path;

        string stripped = StripVerbatimPrefix(path);
        if (stripped.Length < 248)
            return stripped;

        if (stripped.StartsWith(@"\\", StringComparison.Ordinal))
            return @"\\?\UNC\" + stripped[2..];

        return Path.IsPathRooted(stripped) ? @"\\?\" + stripped : stripped;
    }

    public static bool IsSameOrSubdirectory(string candidateDir, string projectRoot)
    {
        string normCandidate = NormalizeForCompare(candidateDir);
        string normRoot = NormalizeForCompare(projectRoot);
        if (string.IsNullOrEmpty(normCandidate) || string.IsNullOrEmpty(normRoot))
            return false;

        if (string.Equals(normCandidate, normRoot, StringComparison.OrdinalIgnoreCase))
            return true;

        string rootPrefix = normRoot + Path.DirectorySeparatorChar;
        return normCandidate.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase);
    }
}
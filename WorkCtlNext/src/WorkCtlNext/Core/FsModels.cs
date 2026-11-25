namespace WorkCtlNext.Core;

public enum FsReparseKind
{
    None = 0,
    Junction = 1,
    SymbolicLink = 2,
    AppExecLink = 3,
    CloudPlaceholder = 4,
    Other = 5
}

public enum FsEntryKind
{
    Drive = 0,
    Directory = 1,
    File = 2,
    ReparseDirectory = 3,
    ReparseFile = 4,
    QuickLink = 5
}

public enum FsProtectionTier
{
    None = 0,
    Warn = 1,
    Blocked = 2
}

public sealed record ProtectionAssessment(
    string NormalizedPath,
    FsProtectionTier Tier,
    string? Reason,
    bool IsUlvoVault);

public sealed record FsEntry(
    string Name,
    string FullPath,
    FsEntryKind Kind,
    bool IsDirectory,
    bool IsHidden,
    bool IsSystem,
    bool IsReadOnly,
    bool IsReparsePoint,
    FsReparseKind ReparseKind,
    string? LinkTarget,
    long SizeBytes,
    int HardLinkCount,
    DateTimeOffset LastWriteTime,
    string Extension,
    FsProtectionTier ProtectionTier,
    string? ProtectionReason,
    string? SecondaryNote = null);

public sealed record FsDirectoryListing(
    string CurrentPath,
    string? ParentPath,
    bool IsVirtualLocation,
    IReadOnlyList<FsEntry> Entries,
    int DirectoryCount,
    int FileCount,
    long TotalListedFileBytes,
    bool IsTruncated,
    int TotalEntryCount,
    FsProtectionTier DirectoryProtectionTier,
    string? DirectoryProtectionReason,
    string? AccessWarning);

public sealed record FsMetadataSnapshot(
    string Name,
    string FullPath,
    bool Exists,
    FsEntryKind Kind,
    bool IsDirectory,
    string AttributesText,
    bool IsReparsePoint,
    FsReparseKind ReparseKind,
    string? LinkTarget,
    long SizeBytes,
    int HardLinkCount,
    DateTimeOffset? CreationTime,
    DateTimeOffset? LastWriteTime,
    FsProtectionTier ProtectionTier,
    string? ProtectionReason,
    bool IsTextCandidate,
    string? ErrorMessage);

public sealed record FsPreviewSnapshot(
    string FullPath,
    bool Exists,
    bool IsDirectory,
    bool IsBinary,
    bool IsTruncated,
    long TotalBytes,
    int BytesRead,
    int LineCount,
    IReadOnlyList<string> Lines,
    string? EncodingName,
    string? DisabledReason);

public sealed record FsOperationItemResult(
    string SourcePath,
    string? DestinationPath,
    bool Succeeded,
    string? ErrorCode,
    string Message);

public sealed record FsMutationResult(
    bool Success,
    string Operation,
    string? ErrorCode,
    string Message,
    IReadOnlyList<FsOperationItemResult> ItemResults,
    int SucceededCount,
    int FailedCount);

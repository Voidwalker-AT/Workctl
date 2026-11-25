using System.Security.Cryptography;
using System.Text;

namespace WorkCtlNext.Core;

public sealed class FileSystemService
{
    public const string VirtualThisPc = "This PC";
    public const string VirtualQuickAccess = "Quick Access";
    private const int DefaultMaxListEntries = 1000;
    private const int HardLinkListThreshold = 250;

    private readonly WorkctlPathsConfig _config;
    private readonly ProtectedPathPolicy _policy;

    private static readonly HashSet<string> ReservedDosNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    };

    private static readonly HashSet<string> BinaryExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".exe", ".dll", ".pdb", ".obj", ".lib", ".sys", ".bin", ".dat",
        ".zip", ".7z", ".rar", ".gz", ".tar", ".xz",
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp",
        ".pdf", ".docx", ".xlsx", ".pptx", ".mp3", ".mp4", ".wav", ".avi", ".mkv",
        ".woff", ".woff2", ".ttf", ".otf", ".sqlite", ".db"
    };

    public FileSystemService(WorkctlPathsConfig config, ProtectedPathPolicy? policy = null)
    {
        _config = config;
        _policy = policy ?? new ProtectedPathPolicy(config);
    }

    public ProtectedPathPolicy Policy => _policy;

    public string ResolveDownloadsDirectory()
    {
        string? known = Win32FsInterop.GetKnownFolderPath(Win32FsInterop.FolderIdDownloads);
        if (!string.IsNullOrWhiteSpace(known) && Directory.Exists(known))
            return PathNormalizer.NormalizeDisplayPath(known);

        string fallback = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        return PathNormalizer.NormalizeDisplayPath(fallback);
    }

    public (bool Success, string? ResolvedPath, string? Error) ResolveDirectoryTarget(string? rawTarget, string activeDirectory)
    {
        if (string.IsNullOrWhiteSpace(rawTarget))
        {
            string fallback = string.IsNullOrWhiteSpace(activeDirectory) ? _config.WorkspaceRoot : activeDirectory;
            return (true, PathNormalizer.NormalizeDisplayPath(fallback), null);
        }

        string trimmed = rawTarget.Trim().Trim('"');
        if (trimmed.Equals("~", StringComparison.Ordinal))
            trimmed = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        else if (trimmed.StartsWith("~\\", StringComparison.Ordinal) || trimmed.StartsWith("~/", StringComparison.Ordinal))
            trimmed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), trimmed[2..]);
        else if (trimmed.Equals(VirtualThisPc, StringComparison.OrdinalIgnoreCase) ||
                 trimmed.Equals("this-pc", StringComparison.OrdinalIgnoreCase))
            return (true, VirtualThisPc, null);
        else if (trimmed.Equals(VirtualQuickAccess, StringComparison.OrdinalIgnoreCase) ||
                 trimmed.Equals("quick-access", StringComparison.OrdinalIgnoreCase))
            return (true, VirtualQuickAccess, null);
        else if (trimmed.Equals("downloads", StringComparison.OrdinalIgnoreCase) && !Directory.Exists(Path.Combine(activeDirectory, "downloads")))
            trimmed = ResolveDownloadsDirectory();
        else if (trimmed.Equals("workspace", StringComparison.OrdinalIgnoreCase) && !Directory.Exists(Path.Combine(activeDirectory, "workspace")))
            trimmed = _config.WorkspaceRoot;

        string candidate;
        try
        {
            if (trimmed.Length == 2 && char.IsLetter(trimmed[0]) && trimmed[1] == ':')
                trimmed += Path.DirectorySeparatorChar;

            if (Path.IsPathRooted(trimmed))
                candidate = Path.GetFullPath(trimmed);
            else
            {
                string baseDir = IsVirtualPath(activeDirectory) || string.IsNullOrWhiteSpace(activeDirectory)
                    ? _config.WorkspaceRoot
                    : activeDirectory;
                candidate = Path.GetFullPath(Path.Combine(baseDir, trimmed));
            }
        }
        catch (Exception ex)
        {
            return (false, null, $"Invalid path '{rawTarget}': {ex.Message}");
        }

        string normalized = PathNormalizer.NormalizeDisplayPath(candidate);
        string longPath = PathNormalizer.EnsureLongPathPrefix(normalized);

        if (Directory.Exists(longPath))
            return (true, normalized, null);

        if (File.Exists(longPath))
            return (false, normalized, $"'{normalized}' is a file, not a directory.");

        return (false, normalized, $"Directory not found: '{normalized}'.");
    }

    public string ResolvePathRelativeTo(string rawTarget, string activeDirectory)
    {
        string trimmed = rawTarget.Trim().Trim('"');
        if (trimmed.Equals("~", StringComparison.Ordinal))
            trimmed = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        else if (trimmed.StartsWith("~\\", StringComparison.Ordinal) || trimmed.StartsWith("~/", StringComparison.Ordinal))
            trimmed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), trimmed[2..]);

        if (trimmed.Length == 2 && char.IsLetter(trimmed[0]) && trimmed[1] == ':')
            trimmed += Path.DirectorySeparatorChar;

        if (Path.IsPathRooted(trimmed))
            return PathNormalizer.NormalizeDisplayPath(trimmed);

        string baseDir = IsVirtualPath(activeDirectory) || string.IsNullOrWhiteSpace(activeDirectory)
            ? _config.WorkspaceRoot
            : activeDirectory;
        return PathNormalizer.NormalizeDisplayPath(Path.Combine(baseDir, trimmed));
    }

    public static bool IsVirtualPath(string? path)
        => string.Equals(path, VirtualThisPc, StringComparison.OrdinalIgnoreCase) ||
           string.Equals(path, VirtualQuickAccess, StringComparison.OrdinalIgnoreCase);

    public FsDirectoryListing ListThisPc(IReadOnlyCollection<string>? registeredProjectPaths = null)
    {
        var entries = new List<FsEntry>();
        foreach (DriveInfo drive in DriveInfo.GetDrives())
        {
            try
            {
                bool ready = drive.IsReady;
                long total = ready ? drive.TotalSize : 0;
                long free = ready ? drive.AvailableFreeSpace : 0;
                string label = ready && !string.IsNullOrWhiteSpace(drive.VolumeLabel)
                    ? $"{drive.Name} ({drive.VolumeLabel})"
                    : drive.Name;
                string note = ready
                    ? $"{drive.DriveFormat} · {FormatBytes(free)} free / {FormatBytes(total)}"
                    : $"{drive.DriveType} · not ready";
                var assess = _policy.Assess(drive.Name, FsOperationKind.Read, registeredProjectPaths);

                entries.Add(new FsEntry(
                    Name: label,
                    FullPath: PathNormalizer.NormalizeDisplayPath(drive.Name),
                    Kind: FsEntryKind.Drive,
                    IsDirectory: true,
                    IsHidden: false,
                    IsSystem: false,
                    IsReadOnly: false,
                    IsReparsePoint: false,
                    ReparseKind: FsReparseKind.None,
                    LinkTarget: null,
                    SizeBytes: free,
                    HardLinkCount: 1,
                    LastWriteTime: DateTimeOffset.MinValue,
                    Extension: string.Empty,
                    ProtectionTier: assess.Tier,
                    ProtectionReason: assess.Reason,
                    SecondaryNote: note));
            }
            catch
            {
            }
        }

        return new FsDirectoryListing(
            CurrentPath: VirtualThisPc,
            ParentPath: null,
            IsVirtualLocation: true,
            Entries: entries,
            DirectoryCount: entries.Count,
            FileCount: 0,
            TotalListedFileBytes: 0,
            IsTruncated: false,
            TotalEntryCount: entries.Count,
            DirectoryProtectionTier: FsProtectionTier.Blocked,
            DirectoryProtectionReason: "Virtual drive root overview",
            AccessWarning: null);
    }

    public FsDirectoryListing ListQuickAccess(IReadOnlyCollection<string>? registeredProjectPaths = null)
    {
        var targets = new List<(string Label, string Path, string Note)>
        {
            ("Workspace", _config.WorkspaceRoot, "Registered workstation root"),
            ("Downloads", ResolveDownloadsDirectory(), "User downloads folder"),
            ("User Profile", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Windows user home"),
            ("Temp", Path.GetTempPath().TrimEnd(Path.DirectorySeparatorChar), "System temporary directory")
        };

        var entries = new List<FsEntry>();
        foreach ((string label, string path, string note) in targets)
        {
            string norm = PathNormalizer.NormalizeDisplayPath(path);
            bool exists = Directory.Exists(norm);
            var assess = _policy.Assess(norm, FsOperationKind.Read, registeredProjectPaths);
            entries.Add(new FsEntry(
                Name: label,
                FullPath: norm,
                Kind: FsEntryKind.QuickLink,
                IsDirectory: true,
                IsHidden: false,
                IsSystem: false,
                IsReadOnly: false,
                IsReparsePoint: false,
                ReparseKind: FsReparseKind.None,
                LinkTarget: norm,
                SizeBytes: 0,
                HardLinkCount: 1,
                LastWriteTime: exists ? Directory.GetLastWriteTimeUtc(norm) : DateTimeOffset.MinValue,
                Extension: string.Empty,
                ProtectionTier: assess.Tier,
                ProtectionReason: assess.Reason,
                SecondaryNote: exists ? note : $"{note} (missing)"));
        }

        return new FsDirectoryListing(
            CurrentPath: VirtualQuickAccess,
            ParentPath: VirtualThisPc,
            IsVirtualLocation: true,
            Entries: entries,
            DirectoryCount: entries.Count,
            FileCount: 0,
            TotalListedFileBytes: 0,
            IsTruncated: false,
            TotalEntryCount: entries.Count,
            DirectoryProtectionTier: FsProtectionTier.None,
            DirectoryProtectionReason: null,
            AccessWarning: null);
    }

    public FsDirectoryListing ListDirectory(
        string directoryPath,
        int maxEntries = DefaultMaxListEntries,
        IReadOnlyCollection<string>? registeredProjectPaths = null)
    {
        if (string.Equals(directoryPath, VirtualThisPc, StringComparison.OrdinalIgnoreCase))
            return ListThisPc(registeredProjectPaths);
        if (string.Equals(directoryPath, VirtualQuickAccess, StringComparison.OrdinalIgnoreCase))
            return ListQuickAccess(registeredProjectPaths);

        string norm = PathNormalizer.NormalizeDisplayPath(directoryPath);
        string longPath = PathNormalizer.EnsureLongPathPrefix(norm);
        ProtectionAssessment dirAssess = _policy.Assess(norm, FsOperationKind.Read, registeredProjectPaths);

        string? parent = null;
        try
        {
            DirectoryInfo? parentInfo = Directory.GetParent(norm);
            parent = parentInfo is not null ? PathNormalizer.NormalizeDisplayPath(parentInfo.FullName) : VirtualThisPc;
        }
        catch
        {
            parent = VirtualThisPc;
        }

        if (!Directory.Exists(longPath))
        {
            return new FsDirectoryListing(
                norm, parent, false, Array.Empty<FsEntry>(), 0, 0, 0, false, 0,
                dirAssess.Tier, dirAssess.Reason, $"Directory does not exist: {norm}");
        }

        var dirs = new List<FsEntry>();
        var files = new List<FsEntry>();
        string? warning = null;
        int totalSeen = 0;

        try
        {
            var dirInfo = new DirectoryInfo(longPath);
            List<FileSystemInfo> rawEntries = dirInfo.EnumerateFileSystemInfos().ToList();
            totalSeen = rawEntries.Count;
            bool computeHardLinks = totalSeen <= HardLinkListThreshold;

            foreach (FileSystemInfo fsi in rawEntries)
            {
                try
                {
                    FsEntry entry = BuildEntry(fsi, computeHardLinks, registeredProjectPaths);
                    if (entry.IsDirectory)
                        dirs.Add(entry);
                    else
                        files.Add(entry);
                }
                catch
                {
                }
            }
        }
        catch (UnauthorizedAccessException)
        {
            warning = $"Access denied enumerating '{norm}'.";
        }
        catch (Exception ex)
        {
            warning = $"Error reading '{norm}': {ex.Message}";
        }

        dirs.Sort((a, b) => StringComparer.OrdinalIgnoreCase.Compare(a.Name, b.Name));
        files.Sort((a, b) => StringComparer.OrdinalIgnoreCase.Compare(a.Name, b.Name));

        var combined = new List<FsEntry>(dirs.Count + files.Count);
        combined.AddRange(dirs);
        combined.AddRange(files);

        bool truncated = combined.Count > maxEntries;
        if (truncated)
            combined = combined.Take(maxEntries).ToList();

        long listedFileBytes = files.Sum(f => f.SizeBytes);

        return new FsDirectoryListing(
            CurrentPath: norm,
            ParentPath: parent,
            IsVirtualLocation: false,
            Entries: combined,
            DirectoryCount: dirs.Count,
            FileCount: files.Count,
            TotalListedFileBytes: listedFileBytes,
            IsTruncated: truncated,
            TotalEntryCount: totalSeen,
            DirectoryProtectionTier: dirAssess.Tier,
            DirectoryProtectionReason: dirAssess.Reason,
            AccessWarning: warning);
    }

    public FsMetadataSnapshot InspectPath(string targetPath, IReadOnlyCollection<string>? registeredProjectPaths = null)
    {
        string norm = PathNormalizer.NormalizeDisplayPath(targetPath);
        string longPath = PathNormalizer.EnsureLongPathPrefix(norm);
        ProtectionAssessment assess = _policy.Assess(norm, FsOperationKind.Read, registeredProjectPaths);

        try
        {
            bool isDir = Directory.Exists(longPath);
            bool isFile = !isDir && File.Exists(longPath);
            if (!isDir && !isFile)
            {
                return new FsMetadataSnapshot(
                    Name: Path.GetFileName(norm),
                    FullPath: norm,
                    Exists: false,
                    Kind: FsEntryKind.File,
                    IsDirectory: false,
                    AttributesText: "Missing",
                    IsReparsePoint: false,
                    ReparseKind: FsReparseKind.None,
                    LinkTarget: null,
                    SizeBytes: 0,
                    HardLinkCount: 0,
                    CreationTime: null,
                    LastWriteTime: null,
                    ProtectionTier: assess.Tier,
                    ProtectionReason: assess.Reason,
                    IsTextCandidate: false,
                    ErrorMessage: $"Path does not exist: '{norm}'.");
            }

            FileSystemInfo fsi = isDir ? new DirectoryInfo(longPath) : new FileInfo(longPath);
            FsEntry entry = BuildEntry(fsi, computeHardLinks: true, registeredProjectPaths);
            bool textCandidate = !isDir && !entry.IsReparsePoint && !BinaryExtensions.Contains(entry.Extension);

            return new FsMetadataSnapshot(
                Name: entry.Name,
                FullPath: entry.FullPath,
                Exists: true,
                Kind: entry.Kind,
                IsDirectory: entry.IsDirectory,
                AttributesText: fsi.Attributes.ToString(),
                IsReparsePoint: entry.IsReparsePoint,
                ReparseKind: entry.ReparseKind,
                LinkTarget: entry.LinkTarget,
                SizeBytes: entry.SizeBytes,
                HardLinkCount: entry.HardLinkCount,
                CreationTime: fsi.CreationTime,
                LastWriteTime: entry.LastWriteTime,
                ProtectionTier: assess.Tier,
                ProtectionReason: assess.Reason,
                IsTextCandidate: textCandidate,
                ErrorMessage: null);
        }
        catch (Exception ex)
        {
            return new FsMetadataSnapshot(
                Name: Path.GetFileName(norm),
                FullPath: norm,
                Exists: false,
                Kind: FsEntryKind.File,
                IsDirectory: false,
                AttributesText: "Error",
                IsReparsePoint: false,
                ReparseKind: FsReparseKind.None,
                LinkTarget: null,
                SizeBytes: 0,
                HardLinkCount: 1,
                CreationTime: null,
                LastWriteTime: null,
                ProtectionTier: assess.Tier,
                ProtectionReason: assess.Reason,
                IsTextCandidate: false,
                ErrorMessage: ex.Message);
        }
    }

    public FsPreviewSnapshot PreviewFile(string targetPath, int maxBytes = 64 * 1024, int maxLines = 120)
    {
        string norm = PathNormalizer.NormalizeDisplayPath(targetPath);
        string longPath = PathNormalizer.EnsureLongPathPrefix(norm);

        if (Directory.Exists(longPath))
        {
            return new FsPreviewSnapshot(norm, true, true, false, false, 0, 0, 0, Array.Empty<string>(), null, "Path is a directory.");
        }

        if (!File.Exists(longPath))
        {
            return new FsPreviewSnapshot(norm, false, false, false, false, 0, 0, 0, Array.Empty<string>(), null, $"File not found: '{norm}'.");
        }

        string ext = Path.GetExtension(norm);
        if (BinaryExtensions.Contains(ext))
        {
            long len = new FileInfo(longPath).Length;
            return new FsPreviewSnapshot(norm, true, false, true, false, len, 0, 0, Array.Empty<string>(), null, $"Binary file type ({ext}); raw preview skipped.");
        }

        try
        {
            using var fs = new FileStream(longPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            long totalLen = fs.Length;
            int toRead = (int)Math.Min(maxBytes, totalLen);
            byte[] buffer = new byte[toRead];
            int totalRead = 0;
            while (totalRead < toRead)
            {
                int n = fs.Read(buffer, totalRead, toRead - totalRead);
                if (n <= 0)
                    break;
                totalRead += n;
            }

            if (totalRead == 0)
            {
                return new FsPreviewSnapshot(norm, true, false, false, false, totalLen, 0, 0, Array.Empty<string>(), "UTF-8", null);
            }

            (Encoding encoding, int bomOffset, string encName, bool looksBinary) = DetectEncodingAndBinary(buffer, totalRead);
            if (looksBinary)
            {
                return new FsPreviewSnapshot(norm, true, false, true, false, totalLen, totalRead, 0, Array.Empty<string>(), null, "Binary content detected (NUL or control bytes); preview skipped.");
            }

            string decoded = encoding.GetString(buffer, bomOffset, totalRead - bomOffset);
            string[] splitLines = decoded.Replace("\r\n", "\n").Split('\n');
            bool lineTruncated = splitLines.Length > maxLines;
            IReadOnlyList<string> lines = lineTruncated
                ? splitLines.Take(maxLines).Select(SanitizePreviewLine).ToArray()
                : splitLines.Select(SanitizePreviewLine).ToArray();

            bool byteTruncated = totalLen > totalRead;
            return new FsPreviewSnapshot(
                FullPath: norm,
                Exists: true,
                IsDirectory: false,
                IsBinary: false,
                IsTruncated: byteTruncated || lineTruncated,
                TotalBytes: totalLen,
                BytesRead: totalRead,
                LineCount: lines.Count,
                Lines: lines,
                EncodingName: encName,
                DisabledReason: null);
        }
        catch (IOException ex)
        {
            return new FsPreviewSnapshot(norm, true, false, false, false, 0, 0, 0, Array.Empty<string>(), null, $"Unable to read file (possibly locked): {ex.Message}");
        }
        catch (UnauthorizedAccessException)
        {
            return new FsPreviewSnapshot(norm, true, false, false, false, 0, 0, 0, Array.Empty<string>(), null, "Access denied reading file.");
        }
    }

    public FsMutationResult CreateDirectory(
        string parentDirectory,
        string directoryNameOrPath,
        IReadOnlyCollection<string>? registeredProjectPaths = null)
    {
        if (string.IsNullOrWhiteSpace(directoryNameOrPath))
            return Fail("mkdir", "INVALID_NAME", "Directory name cannot be empty.");

        string candidate = Path.IsPathRooted(directoryNameOrPath.Trim())
            ? directoryNameOrPath.Trim()
            : Path.Combine(parentDirectory, directoryNameOrPath.Trim());

        string? leafError = ValidateNameSegment(Path.GetFileName(candidate.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)));
        if (leafError is not null)
            return Fail("mkdir", "INVALID_NAME", leafError);

        string norm = PathNormalizer.NormalizeDisplayPath(candidate);
        ProtectionAssessment assess = _policy.Assess(norm, FsOperationKind.CreateDirectory, registeredProjectPaths);
        if (assess.Tier == FsProtectionTier.Blocked)
            return Fail("mkdir", "POLICY_BLOCKED", assess.Reason ?? "Target path is protected.");

        string longTarget = PathNormalizer.EnsureLongPathPrefix(norm);
        if (File.Exists(longTarget) || Directory.Exists(longTarget))
            return Fail("mkdir", "DESTINATION_EXISTS", $"Destination already exists: '{norm}'.");

        try
        {
            Directory.CreateDirectory(longTarget);
            var item = new FsOperationItemResult(norm, norm, true, null, $"Created directory '{norm}'.");
            return new FsMutationResult(true, "mkdir", null, $"Created directory '{Path.GetFileName(norm)}'.", [item], 1, 0);
        }
        catch (Exception ex)
        {
            return Fail("mkdir", MapExceptionCode(ex), ex.Message);
        }
    }

    public FsMutationResult RenameItem(
        string sourcePath,
        string newName,
        IReadOnlyCollection<string>? registeredProjectPaths = null)
    {
        if (string.IsNullOrWhiteSpace(newName))
            return Fail("rename", "INVALID_NAME", "New name cannot be empty.");

        if (newName.IndexOfAny(['\\', '/', ':']) >= 0)
            return Fail("rename", "INVALID_NAME", "Rename target must be a single name, not a path.");

        string? nameErr = ValidateNameSegment(newName);
        if (nameErr is not null)
            return Fail("rename", "INVALID_NAME", nameErr);

        string normSrc = PathNormalizer.NormalizeDisplayPath(sourcePath);
        string? parentDir = Path.GetDirectoryName(normSrc);
        if (string.IsNullOrWhiteSpace(parentDir))
            return Fail("rename", "POLICY_BLOCKED", "Drive roots cannot be renamed.");

        ProtectionAssessment srcAssess = _policy.Assess(normSrc, FsOperationKind.MoveOrRename, registeredProjectPaths);
        if (srcAssess.Tier == FsProtectionTier.Blocked)
            return Fail("rename", "POLICY_BLOCKED", srcAssess.Reason ?? "Source path is protected.");

        string trimmedNew = newName.Trim();
        string normDst = PathNormalizer.NormalizeDisplayPath(Path.Combine(parentDir, trimmedNew));
        ProtectionAssessment dstAssess = _policy.Assess(normDst, FsOperationKind.MoveOrRename, registeredProjectPaths);
        if (dstAssess.Tier == FsProtectionTier.Blocked)
            return Fail("rename", "POLICY_BLOCKED", dstAssess.Reason ?? "Destination path is protected.");

        string longSrc = PathNormalizer.EnsureLongPathPrefix(normSrc);
        string longDst = PathNormalizer.EnsureLongPathPrefix(normDst);
        bool isDir = Directory.Exists(longSrc);
        bool isFile = !isDir && File.Exists(longSrc);
        if (!isDir && !isFile)
            return Fail("rename", "NOT_FOUND", $"Source not found: '{normSrc}'.");

        string srcLeaf = Path.GetFileName(normSrc);
        bool caseOnlyRename = string.Equals(srcLeaf, trimmedNew, StringComparison.OrdinalIgnoreCase);

        if (!caseOnlyRename && (File.Exists(longDst) || Directory.Exists(longDst)))
            return Fail("rename", "DESTINATION_EXISTS", $"Destination already exists: '{normDst}'.");

        if (string.Equals(srcLeaf, trimmedNew, StringComparison.Ordinal))
            return Fail("rename", "NO_CHANGE", "New name matches existing name.");

        try
        {
            if (caseOnlyRename)
            {
                string staging = PathNormalizer.EnsureLongPathPrefix(Path.Combine(parentDir, $".workctl-rename-{Guid.NewGuid():N}"));
                if (isDir)
                {
                    Directory.Move(longSrc, staging);
                    Directory.Move(staging, longDst);
                }
                else
                {
                    File.Move(longSrc, staging);
                    File.Move(staging, longDst);
                }
            }
            else if (isDir)
            {
                Directory.Move(longSrc, longDst);
            }
            else
            {
                File.Move(longSrc, longDst, overwrite: false);
            }

            var item = new FsOperationItemResult(normSrc, normDst, true, null, $"Renamed '{srcLeaf}' to '{trimmedNew}'.");
            return new FsMutationResult(true, "rename", null, $"Renamed '{srcLeaf}' -> '{trimmedNew}'.", [item], 1, 0);
        }
        catch (Exception ex)
        {
            return Fail("rename", MapExceptionCode(ex), ex.Message);
        }
    }

    public FsMutationResult CopyItems(
        IReadOnlyList<string> sourcePaths,
        string destinationDirectory,
        IReadOnlyCollection<string>? registeredProjectPaths = null)
        => TransferItems(sourcePaths, destinationDirectory, isMove: false, explicitSingleDestinationPath: null, registeredProjectPaths);

    public FsMutationResult MoveItems(
        IReadOnlyList<string> sourcePaths,
        string destinationDirectory,
        string? explicitSingleDestinationPath = null,
        IReadOnlyCollection<string>? registeredProjectPaths = null)
        => TransferItems(sourcePaths, destinationDirectory, isMove: true, explicitSingleDestinationPath, registeredProjectPaths);

    public FsMutationResult DeleteItems(
        IReadOnlyList<string> targetPaths,
        bool permanent = false,
        IReadOnlyCollection<string>? registeredProjectPaths = null)
    {
        if (targetPaths.Count == 0)
            return Fail("delete", "EMPTY_SELECTION", "No items selected for deletion.");

        var results = new List<FsOperationItemResult>(targetPaths.Count);
        int ok = 0;
        int fail = 0;

        foreach (string raw in targetPaths)
        {
            string norm = PathNormalizer.NormalizeDisplayPath(raw);
            ProtectionAssessment assess = _policy.Assess(norm, FsOperationKind.Delete, registeredProjectPaths);
            if (assess.Tier == FsProtectionTier.Blocked)
            {
                fail++;
                results.Add(new FsOperationItemResult(norm, null, false, "POLICY_BLOCKED", assess.Reason ?? "Path is protected."));
                continue;
            }

            string longPath = PathNormalizer.EnsureLongPathPrefix(norm);
            try
            {
                bool isDir = Directory.Exists(longPath);
                bool isFile = !isDir && File.Exists(longPath);
                if (!isDir && !isFile)
                {
                    fail++;
                    results.Add(new FsOperationItemResult(norm, null, false, "NOT_FOUND", $"Item does not exist: '{norm}'."));
                    continue;
                }

                FileAttributes attrs = File.GetAttributes(longPath);
                if (attrs.HasFlag(FileAttributes.ReparsePoint))
                {
                    // Never traverse or send junction targets into Recycle Bin recursively; unlink ONLY the reparse point itself.
                    if (isDir)
                        Directory.Delete(longPath, recursive: false);
                    else
                        File.Delete(longPath);

                    ok++;
                    results.Add(new FsOperationItemResult(norm, null, true, null, $"Unlinked reparse point '{norm}' without deleting target."));
                    continue;
                }

                if (!permanent)
                {
                    if (norm.Length >= 258)
                    {
                        fail++;
                        results.Add(new FsOperationItemResult(norm, null, false, "RECYCLE_BIN_FAILED",
                            $"Path length ({norm.Length}) exceeds Windows Shell Recycle Bin limit; refusing silent permanent delete."));
                        continue;
                    }

                    (bool sent, int win32Err, bool aborted) = Win32FsInterop.SendToRecycleBin(norm);
                    if (!sent)
                    {
                        fail++;
                        results.Add(new FsOperationItemResult(norm, null, false, "RECYCLE_BIN_FAILED",
                            aborted
                                ? "Recycle Bin operation was aborted."
                                : $"Recycle Bin failed with Win32 code {win32Err}; source preserved."));
                        continue;
                    }

                    ok++;
                    results.Add(new FsOperationItemResult(norm, null, true, null, $"Moved '{norm}' to Recycle Bin."));
                }
                else
                {
                    DeleteRecursivelySafe(longPath, isDir);
                    ok++;
                    results.Add(new FsOperationItemResult(norm, null, true, null, $"Permanently deleted '{norm}'."));
                }
            }
            catch (Exception ex)
            {
                fail++;
                results.Add(new FsOperationItemResult(norm, null, false, MapExceptionCode(ex), ex.Message));
            }
        }

        string? firstErr = results.FirstOrDefault(r => !r.Succeeded)?.ErrorCode;
        string summary = fail == 0
            ? $"{(permanent ? "Deleted" : "Recycled")} {ok} item(s)."
            : $"{(permanent ? "Delete" : "Recycle")} completed with {ok} succeeded and {fail} failed.";
        return new FsMutationResult(fail == 0, "delete", firstErr, summary, results, ok, fail);
    }

    private FsMutationResult TransferItems(
        IReadOnlyList<string> sourcePaths,
        string destinationDirectory,
        bool isMove,
        string? explicitSingleDestinationPath,
        IReadOnlyCollection<string>? registeredProjectPaths)
    {
        string op = isMove ? "move" : "copy";
        if (sourcePaths.Count == 0)
            return Fail(op, "EMPTY_SELECTION", $"No source items provided for {op}.");

        string normDestDir = PathNormalizer.NormalizeDisplayPath(destinationDirectory);
        if (IsVirtualPath(normDestDir))
            return Fail(op, "INVALID_DESTINATION", $"Cannot {op} into virtual location '{normDestDir}'.");

        if (explicitSingleDestinationPath is null && !Directory.Exists(PathNormalizer.EnsureLongPathPrefix(normDestDir)))
            return Fail(op, "DESTINATION_NOT_FOUND", $"Destination directory does not exist: '{normDestDir}'.");

        var results = new List<FsOperationItemResult>(sourcePaths.Count);
        int ok = 0;
        int fail = 0;

        foreach (string rawSrc in sourcePaths)
        {
            string normSrc = PathNormalizer.NormalizeDisplayPath(rawSrc);
            string longSrc = PathNormalizer.EnsureLongPathPrefix(normSrc);
            string itemName = Path.GetFileName(normSrc.TrimEnd(Path.DirectorySeparatorChar));
            string normDst = explicitSingleDestinationPath is not null && sourcePaths.Count == 1
                ? PathNormalizer.NormalizeDisplayPath(explicitSingleDestinationPath)
                : PathNormalizer.NormalizeDisplayPath(Path.Combine(normDestDir, itemName));
            string longDst = PathNormalizer.EnsureLongPathPrefix(normDst);

            ProtectionAssessment srcAssess = _policy.Assess(
                normSrc,
                isMove ? FsOperationKind.MoveOrRename : FsOperationKind.CopySource,
                registeredProjectPaths);
            if (srcAssess.Tier == FsProtectionTier.Blocked)
            {
                fail++;
                results.Add(new FsOperationItemResult(normSrc, normDst, false, "POLICY_BLOCKED", srcAssess.Reason ?? "Source path is protected."));
                continue;
            }

            ProtectionAssessment dstAssess = _policy.Assess(
                normDst,
                isMove ? FsOperationKind.MoveOrRename : FsOperationKind.CopyDestination,
                registeredProjectPaths);
            if (dstAssess.Tier == FsProtectionTier.Blocked)
            {
                fail++;
                results.Add(new FsOperationItemResult(normSrc, normDst, false, "POLICY_BLOCKED", dstAssess.Reason ?? "Destination path is protected."));
                continue;
            }

            bool srcIsDir = Directory.Exists(longSrc);
            bool srcIsFile = !srcIsDir && File.Exists(longSrc);
            if (!srcIsDir && !srcIsFile)
            {
                fail++;
                results.Add(new FsOperationItemResult(normSrc, normDst, false, "NOT_FOUND", $"Source not found: '{normSrc}'."));
                continue;
            }

            if (File.Exists(longDst) || Directory.Exists(longDst))
            {
                fail++;
                results.Add(new FsOperationItemResult(normSrc, normDst, false, "DESTINATION_EXISTS",
                    $"Destination already exists (silent overwrite blocked): '{normDst}'."));
                continue;
            }

            if (srcIsDir && ProtectedPathPolicy.IsSameOrDescendant(normDst, normSrc))
            {
                fail++;
                results.Add(new FsOperationItemResult(normSrc, normDst, false, "INVALID_DESTINATION",
                    $"Cannot {op} directory '{normSrc}' into itself or a descendant '{normDst}'."));
                continue;
            }

            try
            {
                if (!isMove)
                {
                    if (srcIsFile)
                        CopySingleFileVerified(longSrc, longDst);
                    else
                        CopyDirectorySafe(longSrc, longDst);

                    ok++;
                    results.Add(new FsOperationItemResult(normSrc, normDst, true, null, $"Copied '{normSrc}' -> '{normDst}'."));
                }
                else
                {
                    bool sameVolume = IsSameVolume(normSrc, normDst);
                    FileAttributes attrs = File.GetAttributes(longSrc);
                    if (sameVolume || attrs.HasFlag(FileAttributes.ReparsePoint))
                    {
                        if (srcIsDir)
                            Directory.Move(longSrc, longDst);
                        else
                            File.Move(longSrc, longDst, overwrite: false);
                    }
                    else
                    {
                        CrossVolumeMoveVerified(longSrc, longDst, srcIsDir);
                    }

                    ok++;
                    results.Add(new FsOperationItemResult(normSrc, normDst, true, null, $"Moved '{normSrc}' -> '{normDst}'."));
                }
            }
            catch (Exception ex)
            {
                fail++;
                results.Add(new FsOperationItemResult(normSrc, normDst, false, MapExceptionCode(ex), ex.Message));
            }
        }

        string? firstErr = results.FirstOrDefault(r => !r.Succeeded)?.ErrorCode;
        string summary = fail == 0
            ? $"{(isMove ? "Moved" : "Copied")} {ok} item(s)."
            : $"{(isMove ? "Move" : "Copy")} partial failure: {ok} succeeded, {fail} failed.";
        return new FsMutationResult(fail == 0, op, firstErr, summary, results, ok, fail);
    }

    private static void CopySingleFileVerified(string longSrc, string longDst)
    {
        FileAttributes attrs = File.GetAttributes(longSrc);
        if (attrs.HasFlag(FileAttributes.ReparsePoint))
        {
            var fi = new FileInfo(longSrc);
            if (!string.IsNullOrWhiteSpace(fi.LinkTarget))
            {
                File.CreateSymbolicLink(longDst, fi.LinkTarget);
                return;
            }
        }

        string dstDir = Path.GetDirectoryName(longDst) ?? throw new InvalidOperationException("Invalid destination directory.");
        Directory.CreateDirectory(dstDir);
        File.Copy(longSrc, longDst, overwrite: false);
    }

    private static void CopyDirectorySafe(string longSrc, string longDst)
    {
        FileAttributes rootAttrs = File.GetAttributes(longSrc);
        if (rootAttrs.HasFlag(FileAttributes.ReparsePoint))
            throw new InvalidOperationException("Refusing to recursively copy a junction or directory symbolic link.");

        Directory.CreateDirectory(longDst);
        foreach (string file in Directory.EnumerateFiles(longSrc))
        {
            string dstFile = Path.Combine(longDst, Path.GetFileName(file));
            CopySingleFileVerified(file, dstFile);
        }

        foreach (string dir in Directory.EnumerateDirectories(longSrc))
        {
            FileAttributes subAttrs = File.GetAttributes(dir);
            if (subAttrs.HasFlag(FileAttributes.ReparsePoint))
            {
                // Skip traversing reparse directory loops safely.
                continue;
            }

            string dstSub = Path.Combine(longDst, Path.GetFileName(dir));
            CopyDirectorySafe(dir, dstSub);
        }
    }

    private static void CrossVolumeMoveVerified(string longSrc, string longDst, bool srcIsDir)
    {
        string dstParent = Path.GetDirectoryName(longDst) ?? throw new InvalidOperationException("Invalid destination parent.");
        Directory.CreateDirectory(dstParent);
        string staging = Path.Combine(dstParent, $".workctl-mv-{Guid.NewGuid():N}");

        try
        {
            if (!srcIsDir)
            {
                CopySingleFileVerified(longSrc, staging);
                VerifyFilesIdentical(longSrc, staging);
                File.Move(staging, longDst, overwrite: false);
                File.Delete(longSrc);
            }
            else
            {
                CopyDirectorySafe(longSrc, staging);
                VerifyDirectoriesIdentical(longSrc, staging);
                Directory.Move(staging, longDst);
                DeleteRecursivelySafe(longSrc, isDir: true);
            }
        }
        catch
        {
            // Clean up only the unverified staging copy on failure; never delete source!
            try
            {
                if (File.Exists(staging))
                    File.Delete(staging);
                else if (Directory.Exists(staging))
                    DeleteRecursivelySafe(staging, isDir: true);
            }
            catch
            {
            }

            throw;
        }
    }

    private static void VerifyFilesIdentical(string srcFile, string dstFile)
    {
        var sInfo = new FileInfo(srcFile);
        var dInfo = new FileInfo(dstFile);
        if (sInfo.Length != dInfo.Length)
            throw new IOException($"Copy verification size mismatch ({dInfo.Length} != {sInfo.Length}).");

        byte[] srcHash = ComputeSha256(srcFile);
        byte[] dstHash = ComputeSha256(dstFile);
        if (!srcHash.AsSpan().SequenceEqual(dstHash))
            throw new IOException("Copy verification SHA-256 mismatch.");
    }

    private static void VerifyDirectoriesIdentical(string srcDir, string dstDir)
    {
        foreach (string srcFile in Directory.EnumerateFiles(srcDir))
        {
            string dstFile = Path.Combine(dstDir, Path.GetFileName(srcFile));
            if (!File.Exists(dstFile))
                throw new IOException($"Missing copied file during move verification: {dstFile}");
            VerifyFilesIdentical(srcFile, dstFile);
        }

        foreach (string sub in Directory.EnumerateDirectories(srcDir))
        {
            if (File.GetAttributes(sub).HasFlag(FileAttributes.ReparsePoint))
                continue;
            string dstSub = Path.Combine(dstDir, Path.GetFileName(sub));
            if (!Directory.Exists(dstSub))
                throw new IOException($"Missing copied directory during move verification: {dstSub}");
            VerifyDirectoriesIdentical(sub, dstSub);
        }
    }

    private static byte[] ComputeSha256(string filePath)
    {
        using var fs = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read);
        return SHA256.HashData(fs);
    }

    private static void DeleteRecursivelySafe(string longPath, bool isDir)
    {
        FileAttributes attrs = File.GetAttributes(longPath);
        if (attrs.HasFlag(FileAttributes.ReparsePoint))
        {
            if (isDir)
                Directory.Delete(longPath, recursive: false);
            else
                File.Delete(longPath);
            return;
        }

        if (!isDir)
        {
            if (attrs.HasFlag(FileAttributes.ReadOnly))
                File.SetAttributes(longPath, attrs & ~FileAttributes.ReadOnly);
            File.Delete(longPath);
            return;
        }

        foreach (string file in Directory.EnumerateFiles(longPath))
            DeleteRecursivelySafe(file, isDir: false);

        foreach (string dir in Directory.EnumerateDirectories(longPath))
            DeleteRecursivelySafe(dir, isDir: true);

        Directory.Delete(longPath, recursive: false);
    }

    private FsEntry BuildEntry(
        FileSystemInfo fsi,
        bool computeHardLinks,
        IReadOnlyCollection<string>? registeredProjectPaths)
    {
        FileAttributes attrs = fsi.Attributes;
        bool isDir = attrs.HasFlag(FileAttributes.Directory);
        bool isReparse = attrs.HasFlag(FileAttributes.ReparsePoint);
        string displayPath = PathNormalizer.NormalizeDisplayPath(fsi.FullName);

        FsReparseKind reparseKind = FsReparseKind.None;
        string? linkTarget = fsi.LinkTarget;
        if (isReparse && Win32FsInterop.TryGetReparseTag(displayPath, out uint tag))
        {
            reparseKind = tag switch
            {
                Win32FsInterop.IO_REPARSE_TAG_MOUNT_POINT => FsReparseKind.Junction,
                Win32FsInterop.IO_REPARSE_TAG_SYMLINK => FsReparseKind.SymbolicLink,
                Win32FsInterop.IO_REPARSE_TAG_APPEXECLINK => FsReparseKind.AppExecLink,
                >= 0x9000001Au and <= 0x9000601Au => FsReparseKind.CloudPlaceholder,
                _ => FsReparseKind.Other
            };
        }
        else if (isReparse)
        {
            reparseKind = FsReparseKind.Other;
        }

        FsEntryKind kind = (isDir, isReparse) switch
        {
            (true, true) => FsEntryKind.ReparseDirectory,
            (true, false) => FsEntryKind.Directory,
            (false, true) => FsEntryKind.ReparseFile,
            _ => FsEntryKind.File
        };

        long size = 0;
        if (!isDir && fsi is FileInfo fi)
        {
            try { size = fi.Length; } catch { size = 0; }
        }

        int hardLinks = !isDir && computeHardLinks
            ? Win32FsInterop.GetHardLinkCount(displayPath)
            : 1;

        ProtectionAssessment assess = _policy.Assess(displayPath, FsOperationKind.Read, registeredProjectPaths);

        return new FsEntry(
            Name: fsi.Name,
            FullPath: displayPath,
            Kind: kind,
            IsDirectory: isDir,
            IsHidden: attrs.HasFlag(FileAttributes.Hidden),
            IsSystem: attrs.HasFlag(FileAttributes.System),
            IsReadOnly: attrs.HasFlag(FileAttributes.ReadOnly),
            IsReparsePoint: isReparse,
            ReparseKind: reparseKind,
            LinkTarget: linkTarget,
            SizeBytes: size,
            HardLinkCount: hardLinks,
            LastWriteTime: fsi.LastWriteTime,
            Extension: isDir ? string.Empty : fsi.Extension,
            ProtectionTier: assess.Tier,
            ProtectionReason: assess.Reason);
    }

    private static (Encoding Encoding, int BomOffset, string Name, bool LooksBinary) DetectEncodingAndBinary(byte[] bytes, int length)
    {
        if (length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            return (Encoding.UTF8, 3, "UTF-8 BOM", ContainsExcessiveControlBytes(bytes, 3, length, allowZero: false));
        if (length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
            return (Encoding.Unicode, 2, "UTF-16 LE", false);
        if (length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF)
            return (Encoding.BigEndianUnicode, 2, "UTF-16 BE", false);

        return (Encoding.UTF8, 0, "UTF-8", ContainsExcessiveControlBytes(bytes, 0, length, allowZero: false));
    }

    private static bool ContainsExcessiveControlBytes(byte[] bytes, int start, int length, bool allowZero)
    {
        int checkLen = Math.Min(length, 8192);
        int weird = 0;
        for (int i = start; i < checkLen; i++)
        {
            byte b = bytes[i];
            if (b == 0 && !allowZero)
                return true;
            if (b < 0x20 && b != (byte)'\r' && b != (byte)'\n' && b != (byte)'\t' && b != (byte)'\b')
                weird++;
        }

        int count = Math.Max(1, checkLen - start);
        return weird * 10 > count; // > 10% non-printable control bytes
    }

    private static string SanitizePreviewLine(string line)
    {
        if (string.IsNullOrEmpty(line))
            return string.Empty;

        var sb = new StringBuilder(line.Length);
        foreach (char ch in line)
        {
            if (ch == '\t')
                sb.Append("    ");
            else if (char.IsControl(ch))
                sb.Append(' ');
            else
                sb.Append(ch);
        }
        return sb.ToString();
    }

    private static string? ValidateNameSegment(string? segment)
    {
        if (string.IsNullOrWhiteSpace(segment))
            return "Name cannot be empty or whitespace.";
        string trimmed = segment.Trim();
        if (trimmed is "." or "..")
            return "Name cannot be '.' or '..'.";
        if (trimmed.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            return "Name contains invalid Windows filename characters.";
        if (trimmed.EndsWith('.') || trimmed.EndsWith(' '))
            return "Windows filenames cannot end with a trailing dot or space.";
        string basePart = Path.GetFileNameWithoutExtension(trimmed);
        if (ReservedDosNames.Contains(trimmed) || ReservedDosNames.Contains(basePart))
            return $"'{trimmed}' is a reserved Windows device name.";
        return null;
    }

    private static bool IsSameVolume(string pathA, string pathB)
    {
        string? rootA = Path.GetPathRoot(pathA);
        string? rootB = Path.GetPathRoot(pathB);
        return string.Equals(rootA, rootB, StringComparison.OrdinalIgnoreCase);
    }

    private static string MapExceptionCode(Exception ex) => ex switch
    {
        UnauthorizedAccessException => "ACCESS_DENIED",
        FileNotFoundException => "NOT_FOUND",
        DirectoryNotFoundException => "NOT_FOUND",
        PathTooLongException => "PATH_TOO_LONG",
        IOException io when (io.HResult & 0xFFFF) == 32 || (io.HResult & 0xFFFF) == 33 => "FILE_LOCKED",
        IOException => "IO_ERROR",
        _ => "FS_ERROR"
    };

    private static FsMutationResult Fail(string op, string code, string msg)
        => new(false, op, code, msg, Array.Empty<FsOperationItemResult>(), 0, 1);

    public static string FormatBytes(long bytes)
    {
        if (bytes < 1024) return $"{bytes} B";
        double kb = bytes / 1024.0;
        if (kb < 1024) return $"{kb:0.#} KB";
        double mb = kb / 1024.0;
        if (mb < 1024) return $"{mb:0.#} MB";
        double gb = mb / 1024.0;
        return $"{gb:0.##} GB";
    }
}

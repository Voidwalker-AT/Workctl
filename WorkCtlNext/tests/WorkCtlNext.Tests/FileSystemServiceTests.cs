using System.Diagnostics;
using System.Runtime.InteropServices;
using WorkCtlNext.Core;
using Xunit;

namespace WorkCtlNext.Tests;

public sealed class FileSystemServiceTests : IDisposable
{
    private readonly string _tempRoot;
    private readonly WorkctlPathsConfig _config;
    private readonly FileSystemService _fs;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLinkW(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);

    public FileSystemServiceTests()
    {
        _tempRoot = Path.Combine(Path.GetTempPath(), $"WorkCtlNext_Fs_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempRoot);
        _config = new WorkctlPathsConfig(
            WorkspaceRoot: _tempRoot,
            WsctlScriptPath: Path.Combine(_tempRoot, "wsctl.ps1"),
            PwshExecutable: "pwsh.exe",
            UlvoExecutable: Path.Combine(_tempRoot, "ulvo-bin", "ulvo.exe"),
            WsctlTimeout: TimeSpan.FromSeconds(2),
            UlvoFastTimeout: TimeSpan.FromSeconds(2),
            UlvoEnvTimeout: TimeSpan.FromSeconds(2));
        _fs = new FileSystemService(_config);
    }

    public void Dispose()
    {
        SafeDeleteTree(_tempRoot);
    }

    private static void SafeDeleteTree(string path)
    {
        if (!Directory.Exists(path))
            return;
        try
        {
            foreach (string subDir in Directory.EnumerateDirectories(path))
            {
                if (File.GetAttributes(subDir).HasFlag(FileAttributes.ReparsePoint))
                    Directory.Delete(subDir, recursive: false);
                else
                    SafeDeleteTree(subDir);
            }
            foreach (string file in Directory.EnumerateFiles(path))
            {
                FileAttributes attrs = File.GetAttributes(file);
                if (attrs.HasFlag(FileAttributes.ReadOnly))
                    File.SetAttributes(file, attrs & ~FileAttributes.ReadOnly);
                File.Delete(file);
            }
            Directory.Delete(path, recursive: false);
        }
        catch
        {
        }
    }

    [Fact]
    public void PathNormalizer_PreservesDriveRootBackslash_AndStripsExtendedPrefix()
    {
        Assert.Equal(@"E:\", PathNormalizer.NormalizeForCompare(@"E:\"));
        Assert.Equal(@"E:\", PathNormalizer.NormalizeForCompare(@"\\?\E:\"));
        Assert.Equal(@"C:\Users\Test", PathNormalizer.NormalizeForCompare(@"\\?\C:\Users\Test\"));
    }

    [Fact]
    public void JunctionDetection_AndNonRecursiveDelete_UnlinksOnlyJunctionAndPreservesTarget()
    {
        string targetDir = Path.Combine(_tempRoot, "real-target");
        string junctionDir = Path.Combine(_tempRoot, "junction-link");
        Directory.CreateDirectory(targetDir);
        string sentinel = Path.Combine(targetDir, "precious.txt");
        File.WriteAllText(sentinel, "must survive junction unlink");

        using (var proc = Process.Start(new ProcessStartInfo
        {
            FileName = "cmd.exe",
            ArgumentList = { "/c", "mklink", "/J", junctionDir, targetDir },
            CreateNoWindow = true,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        })!)
        {
            proc.WaitForExit(5000);
            Assert.Equal(0, proc.ExitCode);
        }

        FsDirectoryListing listing = _fs.ListDirectory(_tempRoot);
        FsEntry? juncEntry = listing.Entries.FirstOrDefault(e => e.Name == "junction-link");
        Assert.NotNull(juncEntry);
        Assert.True(juncEntry!.IsReparsePoint);
        Assert.Equal(FsReparseKind.Junction, juncEntry.ReparseKind);
        Assert.Equal(FsEntryKind.ReparseDirectory, juncEntry.Kind);

        FsMetadataSnapshot meta = _fs.InspectPath(junctionDir);
        Assert.True(meta.Exists);
        Assert.Equal(FsReparseKind.Junction, meta.ReparseKind);

        // Copying a junction recursively must refuse to follow reparse loop/tree
        string copyDest = Path.Combine(_tempRoot, "copy-dest");
        Directory.CreateDirectory(copyDest);
        FsMutationResult copyRes = _fs.CopyItems([junctionDir], copyDest);
        Assert.False(copyRes.Success);

        // Deleting a junction must unlink ONLY the junction and preserve target & sentinel file!
        FsMutationResult delRes = _fs.DeleteItems([junctionDir], permanent: false);
        Assert.True(delRes.Success);
        Assert.False(Directory.Exists(junctionDir));
        Assert.True(Directory.Exists(targetDir));
        Assert.True(File.Exists(sentinel));
        Assert.Equal("must survive junction unlink", File.ReadAllText(sentinel));
    }

    [Fact]
    public void Hardlink_ReportsLinkCountTwo_AndDeletingOnePreservesSibling()
    {
        string a = Path.Combine(_tempRoot, "origin.txt");
        string b = Path.Combine(_tempRoot, "hardlink.txt");
        File.WriteAllText(a, "shared inode payload");

        bool linked = CreateHardLinkW(b, a, IntPtr.Zero);
        Assert.True(linked);

        FsMetadataSnapshot metaA = _fs.InspectPath(a);
        Assert.Equal(2, metaA.HardLinkCount);

        FsDirectoryListing listing = _fs.ListDirectory(_tempRoot);
        FsEntry entryB = listing.Entries.Single(e => e.Name == "hardlink.txt");
        Assert.Equal(2, entryB.HardLinkCount);

        FsMutationResult del = _fs.DeleteItems([a], permanent: true);
        Assert.True(del.Success);
        Assert.False(File.Exists(a));
        Assert.True(File.Exists(b));
        Assert.Equal("shared inode payload", File.ReadAllText(b));
        Assert.Equal(1, _fs.InspectPath(b).HardLinkCount);
    }

    [Fact]
    public void PreviewFile_BoundsLargeText_AndSkipsBinaryWithoutCrash()
    {
        string bigText = Path.Combine(_tempRoot, "many_lines.log");
        File.WriteAllLines(bigText, Enumerable.Range(1, 200).Select(i => $"line-{i:D3}: telemetry sample"));

        FsPreviewSnapshot txtPrev = _fs.PreviewFile(bigText, maxBytes: 64 * 1024, maxLines: 50);
        Assert.True(txtPrev.Exists);
        Assert.False(txtPrev.IsBinary);
        Assert.True(txtPrev.IsTruncated);
        Assert.Equal(50, txtPrev.LineCount);
        Assert.StartsWith("line-001", txtPrev.Lines[0]);

        string binFile = Path.Combine(_tempRoot, "blob.dat");
        File.WriteAllBytes(binFile, [0x4D, 0x5A, 0x00, 0x01, 0x02, 0x00, 0xFF]);

        FsPreviewSnapshot binPrev = _fs.PreviewFile(binFile);
        Assert.True(binPrev.Exists);
        Assert.True(binPrev.IsBinary);
        Assert.NotNull(binPrev.DisabledReason);
        Assert.Empty(binPrev.Lines);
    }

    [Fact]
    public void LockedFile_CopyMoveDelete_ReportHonestErrorsWithoutCrashing()
    {
        string locked = Path.Combine(_tempRoot, "locked.txt");
        File.WriteAllText(locked, "in use");
        string dest = Path.Combine(_tempRoot, "dest");
        Directory.CreateDirectory(dest);

        using var lockStream = new FileStream(locked, FileMode.Open, FileAccess.ReadWrite, FileShare.None);

        FsPreviewSnapshot prev = _fs.PreviewFile(locked);
        Assert.True(prev.Exists);
        Assert.NotNull(prev.DisabledReason);

        FsMutationResult mv = _fs.MoveItems([locked], dest);
        Assert.False(mv.Success);
        Assert.True(File.Exists(locked));

        FsMutationResult del = _fs.DeleteItems([locked], permanent: true);
        Assert.False(del.Success);
        Assert.True(File.Exists(locked));
    }

    [Fact]
    public void OverwriteConflict_SelfDescendantCopy_CaseOnlyRename_AndReservedNames_AreSafe()
    {
        string srcDir = Path.Combine(_tempRoot, "src");
        string dstDir = Path.Combine(_tempRoot, "dst");
        Directory.CreateDirectory(srcDir);
        Directory.CreateDirectory(dstDir);

        string a = Path.Combine(srcDir, "alpha.txt");
        string existingConflict = Path.Combine(dstDir, "alpha.txt");
        File.WriteAllText(a, "new content");
        File.WriteAllText(existingConflict, "existing protected content");

        // Must never silently overwrite existing file
        FsMutationResult conflictCopy = _fs.CopyItems([a], dstDir);
        Assert.False(conflictCopy.Success);
        Assert.Equal("DESTINATION_EXISTS", conflictCopy.ErrorCode);
        Assert.Equal("existing protected content", File.ReadAllText(existingConflict));

        // Partial batch failure: good file succeeds, conflict fails
        string b = Path.Combine(srcDir, "beta.txt");
        File.WriteAllText(b, "beta body");
        FsMutationResult batch = _fs.CopyItems([a, b], dstDir);
        Assert.False(batch.Success);
        Assert.Equal(1, batch.SucceededCount);
        Assert.Equal(1, batch.FailedCount);
        Assert.True(File.Exists(Path.Combine(dstDir, "beta.txt")));

        // Move conflict leaves source completely intact
        FsMutationResult mvConflict = _fs.MoveItems([a], dstDir);
        Assert.False(mvConflict.Success);
        Assert.True(File.Exists(a));

        // Self-descendant copy rejected
        string sub = Path.Combine(srcDir, "sub");
        Directory.CreateDirectory(sub);
        FsMutationResult selfRes = _fs.CopyItems([srcDir], sub);
        Assert.False(selfRes.Success);
        Assert.Equal("INVALID_DESTINATION", selfRes.ErrorCode);

        // Case-only rename works cleanly on NTFS
        FsMutationResult caseRen = _fs.RenameItem(a, "Alpha.TXT");
        Assert.True(caseRen.Success);
        FsDirectoryListing listAfter = _fs.ListDirectory(srcDir);
        Assert.Contains(listAfter.Entries, e => string.Equals(e.Name, "Alpha.TXT", StringComparison.Ordinal));

        // Reserved DOS device name rejected
        FsMutationResult dosRes = _fs.RenameItem(Path.Combine(srcDir, "Alpha.TXT"), "NUL");
        Assert.False(dosRes.Success);
        Assert.Equal("INVALID_NAME", dosRes.ErrorCode);
    }

    [Fact]
    public void RecoverableDelete_UsesRecycleBin_AndLongPathRefusesSilentPermanentFallback()
    {
        string toRecycle = Path.Combine(_tempRoot, "trash-me.txt");
        File.WriteAllText(toRecycle, "send to recycle bin");

        FsMutationResult recycled = _fs.DeleteItems([toRecycle], permanent: false);
        Assert.True(recycled.Success);
        Assert.False(File.Exists(toRecycle));

        // Build > 260-char path in temp to verify non-permanent delete refuses silent permanent deletion fallback
        string deep = _tempRoot;
        for (int i = 0; i < 6; i++)
            deep = Path.Combine(deep, new string((char)('a' + i), 38));
        Directory.CreateDirectory(PathNormalizer.EnsureLongPathPrefix(deep));
        string longFile = Path.Combine(deep, "long_target_file.txt");
        File.WriteAllText(PathNormalizer.EnsureLongPathPrefix(longFile), "keep safe");

        FsMutationResult refuseFallback = _fs.DeleteItems([longFile], permanent: false);
        Assert.False(refuseFallback.Success);
        Assert.Equal("RECYCLE_BIN_FAILED", refuseFallback.ErrorCode);
        Assert.True(File.Exists(PathNormalizer.EnsureLongPathPrefix(longFile)));
    }

    [Fact]
    public void ProtectedPathPolicy_BlocksCriticalSystemWsctlUlvoGitAndAppLocations()
    {
        var policy = new ProtectedPathPolicy(new WorkctlPathsConfig(
            WorkspaceRoot: @"E:\Workspace",
            WsctlScriptPath: @"E:\Workspace\wsctl.ps1",
            PwshExecutable: "pwsh.exe",
            UlvoExecutable: @"E:\TOOLS\ulvo\ulvo.exe",
            WsctlTimeout: TimeSpan.FromSeconds(2),
            UlvoFastTimeout: TimeSpan.FromSeconds(2),
            UlvoEnvTimeout: TimeSpan.FromSeconds(2)));

        Assert.Equal(FsProtectionTier.Blocked, policy.Assess(@"C:\", FsOperationKind.Delete).Tier);
        Assert.Equal(FsProtectionTier.Blocked, policy.Assess(@"C:\Windows\System32", FsOperationKind.Delete).Tier);
        Assert.Equal(FsProtectionTier.Blocked, policy.Assess(@"E:\Workspace\wsctl.ps1", FsOperationKind.MoveOrRename).Tier);
        Assert.Equal(FsProtectionTier.Blocked, policy.Assess(@"E:\Workspace\workspace.json", FsOperationKind.Delete).Tier);
        Assert.Equal(FsProtectionTier.Blocked, policy.Assess(@"E:\Workspace\Shared\script.ps1", FsOperationKind.Delete).Tier);
        Assert.Equal(FsProtectionTier.Blocked, policy.Assess(@"E:\TOOLS\ulvo\vault\env", FsOperationKind.Delete).Tier);
        Assert.Equal(FsProtectionTier.Blocked, policy.Assess(@"E:\TOOLS", FsOperationKind.Delete).Tier);
        Assert.Equal(FsProtectionTier.Blocked, policy.Assess(@"E:\TOOLS", FsOperationKind.MoveOrRename).Tier);
        Assert.Equal(FsProtectionTier.Blocked, policy.Assess(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "scoop"), FsOperationKind.Delete).Tier);
        Assert.Equal(FsProtectionTier.Blocked, policy.Assess(Path.Combine(_tempRoot, ".ulvo", "store"), FsOperationKind.CopySource).Tier);
        Assert.Equal(FsProtectionTier.Blocked, policy.Assess(Path.Combine(_tempRoot, "repo", ".git", "config"), FsOperationKind.Delete).Tier);
        Assert.Equal(FsProtectionTier.Blocked, policy.Assess(AppContext.BaseDirectory, FsOperationKind.Delete).Tier);

        var nestedUlvoPolicy = new ProtectedPathPolicy(new WorkctlPathsConfig(
            WorkspaceRoot: @"E:\Workspace",
            WsctlScriptPath: @"E:\Workspace\wsctl.ps1",
            PwshExecutable: "pwsh.exe",
            UlvoExecutable: @"E:\Workspace\Active\ULVO\bin\ulvo.exe",
            WsctlTimeout: TimeSpan.FromSeconds(2),
            UlvoFastTimeout: TimeSpan.FromSeconds(2),
            UlvoEnvTimeout: TimeSpan.FromSeconds(2)));
        Assert.Equal(FsProtectionTier.Blocked, nestedUlvoPolicy.Assess(@"E:\Workspace\Active\ULVO\bin", FsOperationKind.Delete).Tier);
        Assert.Equal(FsProtectionTier.Blocked, nestedUlvoPolicy.Assess(@"E:\Workspace\Active\ULVO", FsOperationKind.MoveOrRename).Tier);
        Assert.True(nestedUlvoPolicy.Assess(@"E:\Workspace\Active\ULVO\bin", FsOperationKind.Read).IsUlvoVault);

        string userTempSandbox = Path.Combine(Path.GetTempPath(), "workctl-safe-dir");
        Assert.Equal(FsProtectionTier.None, policy.Assess(userTempSandbox, FsOperationKind.Delete).Tier);
    }
}

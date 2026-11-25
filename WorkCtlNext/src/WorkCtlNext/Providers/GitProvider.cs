using System.Text.RegularExpressions;
using WorkCtlNext.Core;

namespace WorkCtlNext.Providers;

public sealed class GitProvider
{
    private readonly WorkctlPathsConfig _config;
    private readonly IProcessRunner _runner;
    private string? _cachedGitPath;
    private bool _checkedGit;

    public GitProvider(WorkctlPathsConfig config, IProcessRunner runner)
    {
        _config = config;
        _runner = runner;
    }

    public bool IsGitAvailable()
    {
        return ResolveGitExecutable() is not null;
    }

    public string? ResolveGitExecutable()
    {
        if (_checkedGit)
            return _cachedGitPath;

        string? envPath = Environment.GetEnvironmentVariable("PATH");
        if (!string.IsNullOrWhiteSpace(envPath))
        {
            foreach (string dir in envPath.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    string candidate = Path.Combine(dir.Trim(), "git.exe");
                    if (File.Exists(candidate))
                    {
                        _cachedGitPath = candidate;
                        _checkedGit = true;
                        return _cachedGitPath;
                    }
                }
                catch
                {
                }
            }
        }

        string programFilesGit = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Git", "cmd", "git.exe");
        if (File.Exists(programFilesGit))
        {
            _cachedGitPath = programFilesGit;
            _checkedGit = true;
            return _cachedGitPath;
        }

        _checkedGit = true;
        return null;
    }

    public async Task<GitRepositorySnapshot> GetStatusAsync(string targetDirectory, CancellationToken cancellationToken)
    {
        string normalized = PathNormalizer.NormalizeDisplayPath(targetDirectory);
        DateTimeOffset now = DateTimeOffset.UtcNow;

        if (string.IsNullOrWhiteSpace(normalized) || !Directory.Exists(PathNormalizer.EnsureLongPathPrefix(normalized)))
        {
            return EmptySnapshot(normalized, isRepo: false, "Target directory does not exist.", now);
        }

        string? gitExe = ResolveGitExecutable();
        if (gitExe is null)
        {
            return EmptySnapshot(normalized, isRepo: false, "Git executable not found in PATH.", now);
        }

        SubprocessResult statusRes = await _runner.RunAsync(
            gitExe,
            ["-C", normalized, "--no-optional-locks", "status", "--porcelain=v1", "--branch"],
            normalized,
            _config.GitTimeout,
            cancellationToken).ConfigureAwait(false);
        if (statusRes.TimedOut || statusRes.Cancelled)
        {
            return EmptySnapshot(normalized, isRepo: false, "Git status timed out or was cancelled.", now);
        }

        if (statusRes.ExitCode != 0)
        {
            string err = statusRes.Stderr.Trim();
            if (err.Contains("not a git repository", StringComparison.OrdinalIgnoreCase))
                return EmptySnapshot(normalized, isRepo: false, null, now);

            return EmptySnapshot(normalized, isRepo: false, string.IsNullOrWhiteSpace(err) ? $"git exited {statusRes.ExitCode}" : err, now);
        }

        SubprocessResult rootRes = await _runner.RunAsync(
            gitExe,
            ["-C", normalized, "--no-optional-locks", "rev-parse", "--show-toplevel"],
            normalized,
            _config.GitTimeout,
            cancellationToken).ConfigureAwait(false);
        string? repoRoot = rootRes.ExitCode == 0
            ? PathNormalizer.NormalizeDisplayPath(rootRes.Stdout.Trim())
            : normalized;

        SubprocessResult logRes = await _runner.RunAsync(
            gitExe,
            ["-C", normalized, "--no-optional-locks", "log", "-1", "--oneline"],
            normalized,
            _config.GitTimeout,
            cancellationToken).ConfigureAwait(false);
        string? lastCommit = logRes.ExitCode == 0 && !string.IsNullOrWhiteSpace(logRes.Stdout)
            ? logRes.Stdout.Trim().Split('\n')[0].Trim()
            : null;

        return ParseStatus(normalized, repoRoot, lastCommit, statusRes.Stdout, now);
    }

    private static GitRepositorySnapshot ParseStatus(
        string targetPath,
        string? repoRoot,
        string? lastCommit,
        string stdout,
        DateTimeOffset now)
    {
        string? branchName = null;
        string? upstream = null;
        int ahead = 0;
        int behind = 0;
        bool detached = false;
        int staged = 0;
        int modified = 0;
        int untracked = 0;
        int conflict = 0;
        var files = new List<GitChangedFile>();

        foreach (string rawLine in stdout.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (rawLine.StartsWith("## ", StringComparison.Ordinal))
            {
                ParseBranchHeader(rawLine[3..], out branchName, out upstream, out ahead, out behind, out detached);
                continue;
            }

            if (rawLine.Length < 4)
                continue;

            char x = rawLine[0];
            char y = rawLine[1];
            string pathPart = rawLine[3..];
            string? origPath = null;
            int renameArrow = pathPart.IndexOf(" -> ", StringComparison.Ordinal);
            if (renameArrow >= 0)
            {
                origPath = pathPart[..renameArrow];
                pathPart = pathPart[(renameArrow + 4)..];
            }

            if (x == '?' && y == '?')
            {
                untracked++;
            }
            else if (x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D'))
            {
                conflict++;
            }
            else
            {
                if (x != ' ' && x != '?')
                    staged++;
                if (y != ' ' && y != '?')
                    modified++;
            }

            files.Add(new GitChangedFile(x.ToString(), y.ToString(), pathPart, origPath));
        }

        return new GitRepositorySnapshot(
            TargetPath: targetPath,
            IsGitRepository: true,
            RepoRoot: repoRoot,
            BranchName: branchName,
            UpstreamBranch: upstream,
            AheadCount: ahead,
            BehindCount: behind,
            IsDetachedHead: detached,
            StagedCount: staged,
            ModifiedCount: modified,
            UntrackedCount: untracked,
            ConflictCount: conflict,
            ChangedFiles: files,
            LastCommitSummary: lastCommit,
            ErrorMessage: null,
            CapturedAtUtc: now);
    }

    private static void ParseBranchHeader(
        string header,
        out string? branchName,
        out string? upstream,
        out int ahead,
        out int behind,
        out bool detached)
    {
        branchName = null;
        upstream = null;
        ahead = 0;
        behind = 0;
        detached = false;

        string trimmed = header.Trim();
        if (trimmed.StartsWith("No commits yet on ", StringComparison.Ordinal))
        {
            branchName = trimmed["No commits yet on ".Length..].Trim();
            return;
        }

        if (trimmed.StartsWith("HEAD (no branch)", StringComparison.Ordinal))
        {
            branchName = "HEAD (detached)";
            detached = true;
            return;
        }

        string branchPart = trimmed;
        int bracketStart = trimmed.LastIndexOf(" [", StringComparison.Ordinal);
        if (bracketStart >= 0 && trimmed.EndsWith("]", StringComparison.Ordinal))
        {
            string trackingInfo = trimmed[(bracketStart + 2)..^1];
            branchPart = trimmed[..bracketStart];
            Match mAhead = Regex.Match(trackingInfo, @"ahead\s+(\d+)");
            if (mAhead.Success && int.TryParse(mAhead.Groups[1].Value, out int a))
                ahead = a;
            Match mBehind = Regex.Match(trackingInfo, @"behind\s+(\d+)");
            if (mBehind.Success && int.TryParse(mBehind.Groups[1].Value, out int b))
                behind = b;
        }

        int dots = branchPart.IndexOf("...", StringComparison.Ordinal);
        if (dots >= 0)
        {
            branchName = branchPart[..dots].Trim();
            upstream = branchPart[(dots + 3)..].Trim();
        }
        else
        {
            branchName = branchPart.Trim();
        }
    }

    private static GitRepositorySnapshot EmptySnapshot(string targetPath, bool isRepo, string? error, DateTimeOffset now)
        => new(
            TargetPath: targetPath,
            IsGitRepository: isRepo,
            RepoRoot: null,
            BranchName: null,
            UpstreamBranch: null,
            AheadCount: 0,
            BehindCount: 0,
            IsDetachedHead: false,
            StagedCount: 0,
            ModifiedCount: 0,
            UntrackedCount: 0,
            ConflictCount: 0,
            ChangedFiles: Array.Empty<GitChangedFile>(),
            LastCommitSummary: null,
            ErrorMessage: error,
            CapturedAtUtc: now);
}

using System.Collections.Concurrent;
using System.Diagnostics;

namespace WorkCtlNext.Core;

public enum CompletionCategory
{
    Command = 0,
    Capability = 1,
    Directory = 2,
    File = 3,
    Project = 4,
    Section = 5,
    Flag = 6,
    Action = 7,
    Tool = 8,
    Suggestion = 9
}

public sealed record CompletionRequest(
    string Input,
    int CursorIndex,
    string ActiveDirectory,
    IReadOnlyList<ProjectSummary> Projects,
    IReadOnlyList<CapabilityInfo> Capabilities,
    NavigationSectionId CurrentSection,
    int MaxItems = 12,
    ProjectSummary? ActiveProject = null,
    IReadOnlyList<ToolAvailability>? Tools = null,
    IReadOnlyList<ProcessEntrySnapshot>? Processes = null);

public sealed record CompletionCandidate(
    string Label,
    string InsertText,
    string Meta,
    CompletionCategory Category,
    int Score,
    string? Description = null);

public sealed record CompletionResult(
    string Input,
    int CursorIndex,
    int ReplaceStart,
    int ReplaceLength,
    string? InlineGhostSuffix,
    IReadOnlyList<CompletionCandidate> Items,
    bool DirectoryCachePending);

public interface ICompletionEngine
{
    CompletionResult Compute(CompletionRequest request, CancellationToken cancellationToken = default);
}

public sealed class DeterministicCompletionEngine : ICompletionEngine
{
    private const int MaxCachedDirs = 32;
    private const int MaxEntriesPerCachedDir = 300;
    private static readonly TimeSpan CacheTtl = TimeSpan.FromSeconds(3);

    private readonly FileSystemService _fs;
    private readonly ConcurrentDictionary<string, CachedDirSnapshot> _dirCache = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, byte> _inflightWarm = new(StringComparer.OrdinalIgnoreCase);

    private static readonly (string Name, string Desc)[] SectionTargets =
    [
        ("overview", "Console & machine overview"),
        ("tasks", "Integrated Task Manager"),
        ("processes", "Live processes (Tasks)"),
        ("performance", "Live CPU & RAM"),
        ("storage", "Mounted volumes"),
        ("network", "Network adapters"),
        ("this-pc", "This PC drives"),
        ("quick-access", "Quick Access links"),
        ("workspace", "Workspace root"),
        ("downloads", "Downloads folder"),
        ("projects", "WSCTL projects"),
        ("git", "Git working tree status"),
        ("ulvo", "ULVO environments"),
        ("toolchains", "Detected toolchains"),
        ("running", "Running windowed apps")
    ];

    private sealed record CachedDirSnapshot(
        IReadOnlyList<FsEntry> Entries,
        DateTimeOffset CapturedAtUtc);

    public DeterministicCompletionEngine(FileSystemService fs)
    {
        _fs = fs;
    }

    public CompletionResult Compute(CompletionRequest request, CancellationToken cancellationToken = default)
    {
        string input = request.Input ?? string.Empty;
        int cursor = Math.Clamp(request.CursorIndex, 0, input.Length);
        (IReadOnlyList<CommandToken> tokens, int activeIndex) = CommandLineParser.TokenizeForCompletion(input, cursor);

        int replaceStart;
        int replaceLen;
        string prefix;
        bool isQuotedPrefix = false;

        if (activeIndex >= 0)
        {
            CommandToken tok = tokens[activeIndex];
            replaceStart = tok.StartIndex;
            replaceLen = tok.EndIndex - tok.StartIndex;
            int offsetInside = Math.Clamp(cursor - tok.StartIndex, 0, tok.RawText.Length);
            prefix = tok.RawText[..offsetInside];
            if (prefix.StartsWith('"') || prefix.StartsWith('\''))
            {
                isQuotedPrefix = true;
                prefix = prefix[1..];
            }
        }
        else
        {
            replaceStart = cursor;
            replaceLen = 0;
            prefix = string.Empty;
        }

        // Token index 0 or empty line -> complete commands + contextual suggestions + capabilities.
        bool isCommandPosition = tokens.Count == 0 || activeIndex == 0 || (activeIndex == -1 && cursor <= (tokens.Count > 0 ? tokens[0].EndIndex : 0));

        var candidates = new List<CompletionCandidate>();
        bool pendingCache = false;

        if (isCommandPosition)
        {
            CollectCommandCandidates(prefix, request, candidates);
        }
        else
        {
            string verb = CommandLineParser.ResolveCanonicalVerb(tokens[0].UnquotedText) ?? tokens[0].UnquotedText.ToLowerInvariant();
            pendingCache = CollectArgumentCandidates(verb, prefix, request, candidates, cancellationToken);
        }

        List<CompletionCandidate> sorted = candidates
            .GroupBy(c => (c.Category, c.InsertText), new CategoryInsertComparer())
            .Select(g => g.OrderByDescending(x => x.Score).First())
            .OrderByDescending(c => c.Score)
            .ThenBy(c => c.Category)
            .ThenBy(c => c.Label, StringComparer.OrdinalIgnoreCase)
            .Take(Math.Clamp(request.MaxItems, 1, 25))
            .ToList();

        string? inlineGhost = ComputeInlineGhost(input, cursor, replaceStart, replaceLen, prefix, isQuotedPrefix, sorted);

        return new CompletionResult(
            Input: input,
            CursorIndex: cursor,
            ReplaceStart: replaceStart,
            ReplaceLength: replaceLen,
            InlineGhostSuffix: inlineGhost,
            Items: sorted,
            DirectoryCachePending: pendingCache);
    }

    public static string ApplyCompletion(CompletionResult result, CompletionCandidate candidate)
    {
        string before = result.Input[..Math.Clamp(result.ReplaceStart, 0, result.Input.Length)];
        int afterStart = Math.Clamp(result.ReplaceStart + result.ReplaceLength, 0, result.Input.Length);
        string after = result.Input[afterStart..];
        string insert = candidate.InsertText;

        bool isCommandSlot = result.ReplaceStart == 0;
        string separator = isCommandSlot && string.IsNullOrEmpty(after) && !insert.EndsWith(' ')
            ? " "
            : string.Empty;

        return before + insert + separator + after;
    }

    private void CollectCommandCandidates(
        string prefix,
        CompletionRequest request,
        List<CompletionCandidate> candidates)
    {
        foreach (BuiltInCommandSpec spec in CommandLineParser.BuiltInCommands)
        {
            int primaryBonus = spec.Name switch
            {
                "health" => 165,
                "tasks" => 162,
                "context" => 158,
                "capabilities" => 154,
                "projects" => 152,
                "ls" or "cd" => 150,
                "runtimes" => 148,
                "pwsh" or "cmd" => 142,
                _ => 135
            };

            int score = ScoreMatch(spec.Name, prefix, baseBonus: primaryBonus);
            if (score > 0 || string.IsNullOrEmpty(prefix))
            {
                if (spec.Name is "ls" or "cd" or "cp" or "mv" or "rm" or "mkdir" or "rename" or "preview" &&
                    WorkspaceSessionContext.IsFilesSection(request.CurrentSection))
                {
                    score += 20;
                }

                candidates.Add(new CompletionCandidate(
                    Label: spec.Name,
                    InsertText: spec.Name,
                    Meta: spec.Syntax,
                    Category: CompletionCategory.Command,
                    Score: Math.Max(1, score),
                    Description: spec.Summary));
            }

            if (!string.IsNullOrEmpty(prefix))
            {
                foreach (string alias in spec.Aliases)
                {
                    int aliasScore = ScoreMatch(alias, prefix, baseBonus: 132);
                    if (aliasScore > 0)
                    {
                        candidates.Add(new CompletionCandidate(
                            Label: $"{alias} (-> {spec.Name})",
                            InsertText: alias,
                            Meta: $"alias: {spec.Syntax}",
                            Category: CompletionCategory.Command,
                            Score: aliasScore,
                            Description: spec.Summary));
                    }
                }
            }
        }

        foreach (CapabilityInfo cap in request.Capabilities)
        {
            int ulvoBoost = string.Equals(cap.Provider, "ulvo", StringComparison.OrdinalIgnoreCase) ? 12 : 0;
            int score = ScoreMatch(cap.Id, prefix, baseBonus: 95 + ulvoBoost);
            if (score > 0)
            {
                candidates.Add(new CompletionCandidate(
                    Label: cap.Id,
                    InsertText: string.IsNullOrWhiteSpace(cap.CliCommand) ? cap.Id : cap.CliCommand.Split(' ')[0],
                    Meta: $"{cap.Provider} · {cap.Risk}",
                    Category: CompletionCategory.Capability,
                    Score: score,
                    Description: cap.Description));
            }
        }

        // Registered WSCTL project actions (contextual metadata — never auto-executed)
        IEnumerable<ProjectSummary> actionSources = request.ActiveProject is not null
            ? [request.ActiveProject]
            : request.Projects.Take(5);
        foreach (ProjectSummary proj in actionSources)
        {
            foreach (ProjectActionSummary act in proj.Actions)
            {
                string actionToken = $"{proj.Id}:{act.Name}";
                int score = Math.Max(ScoreMatch(act.Name, prefix, baseBonus: 82), ScoreMatch(actionToken, prefix, baseBonus: 78));
                if (score > 0)
                {
                    candidates.Add(new CompletionCandidate(
                        Label: $"{act.Name} ({proj.Id})",
                        InsertText: QuoteIfNeeded($"project {proj.Id}"),
                        Meta: $"action [{act.Risk}]",
                        Category: CompletionCategory.Action,
                        Score: score,
                        Description: act.Description ?? $"Registered action on {proj.Id}"));
                }
            }
        }

        // Available external tools (safe discovery/handoff candidates — never auto-executed as shell)
        if (request.Tools is not null && !string.IsNullOrEmpty(prefix))
        {
            foreach (ToolAvailability tool in request.Tools.Where(t => t.Installed))
            {
                int score = ScoreMatch(tool.Name, prefix, baseBonus: 72);
                if (score > 0)
                {
                    candidates.Add(new CompletionCandidate(
                        Label: tool.Name,
                        InsertText: tool.Name is "wsctl" or "ulvo" or "git" ? tool.Name : $"open toolchains",
                        Meta: $"tool · installed",
                        Category: CompletionCategory.Tool,
                        Score: score,
                        Description: tool.Path ?? tool.Name));
                }
            }
        }
    }

    private bool CollectArgumentCandidates(
        string verb,
        string prefix,
        CompletionRequest request,
        List<CompletionCandidate> candidates,
        CancellationToken cancellationToken)
    {
        bool pendingCache = false;

        if (prefix.StartsWith('-'))
        {
            CollectFlagCandidates(verb, prefix, candidates);
            return false;
        }

        if (verb == "help")
        {
            foreach (BuiltInCommandSpec spec in CommandLineParser.BuiltInCommands)
            {
                int sc = ScoreMatch(spec.Name, prefix, baseBonus: 130);
                if (sc > 0 || string.IsNullOrEmpty(prefix))
                {
                    candidates.Add(new CompletionCandidate(spec.Name, spec.Name, spec.Syntax, CompletionCategory.Command, Math.Max(1, sc), spec.Summary));
                }
            }
            return false;
        }

        if (verb == "tasks")
        {
            foreach ((string sub, string desc) in new[]
            {
                ("inspect", "Inspect process details by PID"),
                ("tree", "Toggle hierarchy process tree view"),
                ("sort", "Sort by cpu, mem, pid, or name"),
                ("cpu", "Sort tasks by CPU%"),
                ("mem", "Sort tasks by working set memory"),
                ("pid", "Sort tasks by PID"),
                ("name", "Sort tasks by process name")
            })
            {
                int sc = ScoreMatch(sub, prefix, baseBonus: 132);
                if (sc > 0 || string.IsNullOrEmpty(prefix))
                    candidates.Add(new CompletionCandidate(sub, sub, "tasks", CompletionCategory.Action, Math.Max(1, sc), desc));
            }
        }

        if (verb is "tasks" or "kill" && request.Processes is not null)
        {
            foreach (ProcessEntrySnapshot proc in request.Processes.Take(24))
            {
                string pidStr = proc.Pid.ToString(System.Globalization.CultureInfo.InvariantCulture);
                int sc = Math.Max(ScoreMatch(pidStr, prefix, baseBonus: 120), ScoreMatch(proc.Name, prefix, baseBonus: 95));
                if (sc > 0 || (verb == "kill" && string.IsNullOrEmpty(prefix)))
                {
                    candidates.Add(new CompletionCandidate(
                        Label: $"{pidStr} ({proc.Name})",
                        InsertText: pidStr,
                        Meta: FileSystemService.FormatBytes(proc.WorkingSetBytes),
                        Category: CompletionCategory.Suggestion,
                        Score: Math.Max(1, sc),
                        Description: proc.ExecutablePath ?? proc.Name));
                }
            }
        }

        if (verb == "open")
        {
            foreach ((string name, string desc) in SectionTargets)
            {
                int sc = ScoreMatch(name, prefix, baseBonus: 135);
                if (sc > 0 || string.IsNullOrEmpty(prefix))
                {
                    candidates.Add(new CompletionCandidate(name, name, "section", CompletionCategory.Section, Math.Max(1, sc), desc));
                }
            }
        }

        if (verb is "project" or "projects" or "context" or "suggest" or "open")
        {
            foreach (ProjectSummary proj in request.Projects)
            {
                int sc = Math.Max(ScoreMatch(proj.Id, prefix, baseBonus: 125), ScoreMatch(proj.Name, prefix, baseBonus: 110));
                if (sc > 0 || (string.IsNullOrEmpty(prefix) && verb is "project" or "context"))
                {
                    candidates.Add(new CompletionCandidate(
                        Label: proj.Id,
                        InsertText: QuoteIfNeeded(proj.Id),
                        Meta: proj.Category,
                        Category: CompletionCategory.Project,
                        Score: Math.Max(1, sc),
                        Description: proj.FullPath));
                }
            }
        }

        bool expectsFilesystem = verb is "cd" or "ls" or "open" or "cp" or "mv" or "cut" or "paste" or "rename" or "rm" or "stat" or "preview" or "git";
        if (expectsFilesystem)
        {
            bool dirsOnly = verb is "cd" or "paste" or "git";
            if (verb is "cd" or "ls")
            {
                foreach ((string special, string meta) in new[]
                {
                    ("..", "parent dir"),
                    ("workspace", "Workspace root"),
                    ("downloads", "Downloads folder"),
                    ("this-pc", "Drives root")
                })
                {
                    int sc = ScoreMatch(special, prefix, baseBonus: 118);
                    if (sc > 0 || string.IsNullOrEmpty(prefix))
                        candidates.Add(new CompletionCandidate(special, special, meta, CompletionCategory.Directory, Math.Max(1, sc)));
                }
            }

            if (verb == "cd")
            {
                foreach (ProjectSummary proj in request.Projects.Where(p => p.Accessible))
                {
                    int sc = Math.Max(ScoreMatch(proj.Id, prefix, baseBonus: 105), ScoreMatch(proj.FullPath, prefix, baseBonus: 95));
                    if (sc > 0)
                    {
                        candidates.Add(new CompletionCandidate(
                            Label: $"{proj.Id} ({proj.FullPath})",
                            InsertText: QuoteIfNeeded(proj.FullPath),
                            Meta: "project root",
                            Category: CompletionCategory.Project,
                            Score: sc));
                    }
                }
            }

            pendingCache = CollectDirectoryEntries(prefix, request.ActiveDirectory, dirsOnly, candidates, cancellationToken);
        }

        return pendingCache;
    }

    private bool CollectDirectoryEntries(
        string prefix,
        string activeDirectory,
        bool dirsOnly,
        List<CompletionCandidate> candidates,
        CancellationToken cancellationToken)
    {
        if (FileSystemService.IsVirtualPath(activeDirectory) && !Path.IsPathRooted(prefix))
        {
            FsDirectoryListing drives = _fs.ListThisPc();
            foreach (FsEntry d in drives.Entries)
            {
                int sc = ScoreMatch(d.FullPath, prefix, baseBonus: 120);
                if (sc > 0 || string.IsNullOrEmpty(prefix))
                {
                    candidates.Add(new CompletionCandidate(d.Name, QuoteIfNeeded(d.FullPath), "drive", CompletionCategory.Directory, Math.Max(1, sc)));
                }
            }
            return false;
        }

        (string searchDir, string leafPrefix, string typedDirPrefix) = SplitTypedPath(prefix, activeDirectory);
        if (string.IsNullOrWhiteSpace(searchDir))
            return false;

        IReadOnlyList<FsEntry>? entries = TryGetCachedOrFastEntries(searchDir, out bool isPending, cancellationToken);
        if (entries is null)
            return isPending;

        foreach (FsEntry e in entries)
        {
            if (dirsOnly && !e.IsDirectory)
                continue;

            int sc = ScoreMatch(e.Name, leafPrefix, baseBonus: e.IsDirectory ? 128 : 120);
            if (sc <= 0 && !string.IsNullOrEmpty(leafPrefix))
                continue;

            string rawCandidate = string.IsNullOrEmpty(typedDirPrefix)
                ? e.Name + (e.IsDirectory ? Path.DirectorySeparatorChar : string.Empty)
                : typedDirPrefix + e.Name + (e.IsDirectory ? Path.DirectorySeparatorChar : string.Empty);

            string meta = e.IsDirectory
                ? (e.IsReparsePoint ? e.ReparseKind.ToString().ToLowerInvariant() : "dir")
                : FileSystemService.FormatBytes(e.SizeBytes);

            candidates.Add(new CompletionCandidate(
                Label: e.Name + (e.IsDirectory ? "\\" : string.Empty),
                InsertText: QuoteIfNeeded(rawCandidate),
                Meta: meta,
                Category: e.IsDirectory ? CompletionCategory.Directory : CompletionCategory.File,
                Score: Math.Max(1, sc)));
        }

        return isPending;
    }

    private IReadOnlyList<FsEntry>? TryGetCachedOrFastEntries(
        string directoryPath,
        out bool cachePending,
        CancellationToken cancellationToken)
    {
        cachePending = false;
        string norm = PathNormalizer.NormalizeForCompare(directoryPath);
        if (string.IsNullOrWhiteSpace(norm))
            return null;

        DateTimeOffset now = DateTimeOffset.UtcNow;
        if (_dirCache.TryGetValue(norm, out CachedDirSnapshot? cached) && now - cached.CapturedAtUtc <= CacheTtl)
        {
            return cached.Entries;
        }

        // Fast bounded synchronous probe (< 5ms budget for local folders <= MaxEntriesPerCachedDir)
        // while keeping large directories asynchronously warmed if slow or uncached.
        try
        {
            string longDir = PathNormalizer.EnsureLongPathPrefix(norm);
            if (!Directory.Exists(longDir))
                return Array.Empty<FsEntry>();

            var sw = Stopwatch.StartNew();
            var fast = _fs.ListDirectory(norm, MaxEntriesPerCachedDir);
            sw.Stop();
            EvictCacheIfFull();
            _dirCache[norm] = new CachedDirSnapshot(fast.Entries, now);
            if (sw.ElapsedMilliseconds > 15)
                cachePending = true;
            return fast.Entries;
        }
        catch
        {
            cachePending = true;
            ScheduleBackgroundWarm(norm, cancellationToken);
            return null;
        }
    }

    private void ScheduleBackgroundWarm(string normDir, CancellationToken cancellationToken)
    {
        if (!_inflightWarm.TryAdd(normDir, 0))
            return;

        _ = Task.Run(() =>
        {
            try
            {
                if (!cancellationToken.IsCancellationRequested)
                {
                    var listing = _fs.ListDirectory(normDir, MaxEntriesPerCachedDir);
                    EvictCacheIfFull();
                    _dirCache[normDir] = new CachedDirSnapshot(listing.Entries, DateTimeOffset.UtcNow);
                }
            }
            catch
            {
            }
            finally
            {
                _inflightWarm.TryRemove(normDir, out _);
            }
        }, CancellationToken.None);
    }

    private void EvictCacheIfFull()
    {
        if (_dirCache.Count < MaxCachedDirs)
            return;

        foreach (string oldestKey in _dirCache
            .OrderBy(kv => kv.Value.CapturedAtUtc)
            .Take(8)
            .Select(kv => kv.Key)
            .ToArray())
        {
            _dirCache.TryRemove(oldestKey, out _);
        }
    }

    private static (string SearchDir, string LeafPrefix, string TypedDirPrefix) SplitTypedPath(string prefix, string activeDir)
    {
        if (string.IsNullOrEmpty(prefix))
            return (activeDir, string.Empty, string.Empty);

        string cleaned = prefix.Replace('/', Path.DirectorySeparatorChar);
        if (cleaned == "~" || cleaned.StartsWith("~\\", StringComparison.Ordinal))
        {
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string rest = cleaned.Length <= 2 ? string.Empty : cleaned[2..];
            int homeSep = rest.LastIndexOf(Path.DirectorySeparatorChar);
            if (homeSep < 0)
                return (home, rest, "~\\");
            return (Path.Combine(home, rest[..homeSep]), rest[(homeSep + 1)..], "~\\" + rest[..(homeSep + 1)]);
        }

        int lastSep = cleaned.LastIndexOf(Path.DirectorySeparatorChar);
        if (lastSep < 0)
            return (activeDir, cleaned, string.Empty);

        string dirPart = cleaned[..(lastSep + 1)];
        string leafPart = cleaned[(lastSep + 1)..];
        try
        {
            string resolved = Path.IsPathRooted(dirPart)
                ? PathNormalizer.NormalizeDisplayPath(dirPart)
                : PathNormalizer.NormalizeDisplayPath(Path.Combine(activeDir, dirPart));
            return (resolved, leafPart, dirPart);
        }
        catch
        {
            return (string.Empty, string.Empty, string.Empty);
        }
    }

    private static void CollectFlagCandidates(string verb, string prefix, List<CompletionCandidate> candidates)
    {
        var flags = new List<(string Flag, string Desc)>
        {
            ("--help", "Show command help")
        };

        if (verb is "projects" or "context" or "suggest")
            flags.Add(("--project", "Filter/target project ID"));
        if (verb is "projects" or "context")
            flags.Add(("--detailed", "Include extended fields"));
        if (verb is "projects" or "ls" or "suggest")
            flags.Add(("--limit", "Limit result count"));
        if (verb == "ls")
            flags.Add(("--path", "Explicit directory path"));

        foreach ((string flag, string desc) in flags)
        {
            int sc = ScoreMatch(flag, prefix, baseBonus: 120);
            if (sc > 0)
                candidates.Add(new CompletionCandidate(flag, flag, "flag", CompletionCategory.Flag, sc, desc));
        }
    }

    private static string? ComputeInlineGhost(
        string input,
        int cursor,
        int replaceStart,
        int replaceLen,
        string prefix,
        bool isQuotedPrefix,
        IReadOnlyList<CompletionCandidate> sorted)
    {
        if (cursor != input.Length || sorted.Count == 0 || string.IsNullOrEmpty(prefix))
            return null;

        // Only emit ghost continuation when user is at end of current typed segment.
        if (cursor != replaceStart + replaceLen)
            return null;

        CompletionCandidate top = sorted[0];
        string candidateText = isQuotedPrefix ? top.InsertText.Trim('"') : top.InsertText;
        if (candidateText.StartsWith('"') && !isQuotedPrefix)
        {
            // When unquoted prefix would expand into quoted path with spaces, keep suffix clean if possible.
            candidateText = candidateText.Trim('"');
        }

        if (candidateText.Length <= prefix.Length)
            return null;

        if (candidateText.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            return candidateText[prefix.Length..];

        return null;
    }

    private static int ScoreMatch(string target, string prefix, int baseBonus)
    {
        if (string.IsNullOrEmpty(prefix))
            return baseBonus;

        if (string.Equals(target, prefix, StringComparison.OrdinalIgnoreCase))
            return baseBonus + 100;

        if (target.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            return baseBonus + 70 - Math.Min(40, target.Length - prefix.Length);

        int sub = target.IndexOf(prefix, StringComparison.OrdinalIgnoreCase);
        if (sub >= 0)
            return baseBonus + 35 - Math.Min(25, sub);

        if (IsFuzzySubsequence(target, prefix))
            return baseBonus + 10;

        return 0;
    }

    private static bool IsFuzzySubsequence(string text, string query)
    {
        int qi = 0;
        for (int ti = 0; ti < text.Length && qi < query.Length; ti++)
        {
            if (char.ToLowerInvariant(text[ti]) == char.ToLowerInvariant(query[qi]))
                qi++;
        }
        return qi == query.Length;
    }

    public static string QuoteIfNeeded(string text)
    {
        if (string.IsNullOrEmpty(text))
            return text;
        if (text.Contains(' ') && !(text.StartsWith('"') && text.EndsWith('"')))
            return $"\"{text}\"";
        return text;
    }

    private sealed class CategoryInsertComparer : IEqualityComparer<(CompletionCategory Category, string InsertText)>
    {
        public bool Equals((CompletionCategory Category, string InsertText) x, (CompletionCategory Category, string InsertText) y)
            => x.Category == y.Category && string.Equals(x.InsertText, y.InsertText, StringComparison.OrdinalIgnoreCase);

        public int GetHashCode((CompletionCategory Category, string InsertText) obj)
            => HashCode.Combine(obj.Category, StringComparer.OrdinalIgnoreCase.GetHashCode(obj.InsertText));
    }
}

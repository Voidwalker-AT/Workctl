namespace WorkCtlNext.Core;

public sealed record SuggestionContext(
    string CurrentScreen,
    ProjectSummary? ActiveProject,
    bool WsctlAvailable,
    bool UlvoAvailable,
    string? ActiveDirectory = null);

public interface ISuggestionRanker
{
    IReadOnlyList<SuggestionItem> Suggest(
        string query,
        IReadOnlyList<CapabilityInfo> capabilities,
        SuggestionContext context,
        int limit = 15);
}

/// <summary>
/// Purely deterministic suggestion ranker (prefix, fuzzy subsequence, context boosts).
/// Never imports PowerShell history, stores ML state, or auto-executes suggestions.
/// Designed behind ISuggestionRanker so a future offline-trained ranker can supplement ordering safely.
/// </summary>
public sealed class DeterministicSuggestionRanker : ISuggestionRanker
{
    private sealed record RawCandidate(
        string CapabilityId,
        string DisplayName,
        string Command,
        string Provider,
        string Risk,
        bool Available,
        double ContextBonus,
        string ContextReason,
        string SearchHaystack);

    public IReadOnlyList<SuggestionItem> Suggest(
        string query,
        IReadOnlyList<CapabilityInfo> capabilities,
        SuggestionContext context,
        int limit = 15)
    {
        if (limit <= 0)
            return [];

        string q = (query ?? string.Empty).Trim();
        var pool = BuildCandidatePool(capabilities, context);
        var scored = new List<SuggestionItem>(pool.Count);

        foreach (RawCandidate cand in pool)
        {
            (double matchScore, string matchKind) = ScoreMatch(q, cand);
            if (!string.IsNullOrEmpty(q) && matchScore <= 0)
                continue;

            double availAdjustment = cand.Available ? 10.0 : -40.0;
            double total = matchScore + cand.ContextBonus + availAdjustment;

            string reason = cand.Available
                ? cand.ContextReason
                : $"{cand.ContextReason}; provider unavailable";

            scored.Add(new SuggestionItem(
                CapabilityId: cand.CapabilityId,
                DisplayName: cand.DisplayName,
                Command: cand.Command,
                Provider: cand.Provider,
                Risk: cand.Risk,
                Score: Math.Round(total, 2),
                MatchKind: matchKind,
                Reason: reason,
                Available: cand.Available));
        }

        return scored
            .OrderByDescending(x => x.Score)
            .ThenByDescending(x => x.Available)
            .ThenBy(x => x.Command, StringComparer.OrdinalIgnoreCase)
            .ThenBy(x => x.CapabilityId, StringComparer.OrdinalIgnoreCase)
            .Take(limit)
            .ToList();
    }

    private static List<RawCandidate> BuildCandidatePool(
        IReadOnlyList<CapabilityInfo> capabilities,
        SuggestionContext context)
    {
        var list = new List<RawCandidate>();
        foreach (CapabilityInfo cap in capabilities)
        {
            bool avail = !string.Equals(cap.Availability, "unavailable", StringComparison.OrdinalIgnoreCase);
            (double bonus, string reason) = ComputeContextBonus(cap, context);
            string command = cap.CliCommand;
            if (cap.Id == "wsctl.project.inspect" && context.ActiveProject is not null)
                command = $"context --project {context.ActiveProject.Id} --json";

            string haystack = $"{command} {cap.Id} {cap.DisplayName} {cap.Provider} {cap.Description}";
            list.Add(new RawCandidate(cap.Id, cap.DisplayName, command, cap.Provider, cap.Risk, avail, bonus, reason, haystack));
        }

        if (context.ActiveProject is not null)
        {
            ProjectSummary proj = context.ActiveProject;
            list.Add(new RawCandidate(
                CapabilityId: "workctl.context",
                DisplayName: $"Inspect project context: {proj.Id}",
                Command: $"context --project {proj.Id} --json",
                Provider: "core",
                Risk: "ReadOnly",
                Available: context.WsctlAvailable,
                ContextBonus: 28.0,
                ContextReason: $"Active project context ({proj.Id})",
                SearchHaystack: $"context --project {proj.Id} inspect {proj.Name} {proj.Category}"));

            foreach (ProjectActionSummary act in proj.Actions)
            {
                // Registered actions are NEVER auto-executed or executable in Phase 1; surfaced read-only as metadata context.
                list.Add(new RawCandidate(
                    CapabilityId: "wsctl.project.inspect",
                    DisplayName: $"Preview registered action: {proj.Id}.{act.Name} [{act.Risk}]",
                    Command: $"context --project {proj.Id} --json",
                    Provider: "wsctl",
                    Risk: "ReadOnly",
                    Available: context.WsctlAvailable && proj.Accessible,
                    ContextBonus: 18.0,
                    ContextReason: $"Registered action metadata '{act.Name}' ({act.Risk}; execution disabled in Phase 1)",
                    SearchHaystack: $"{act.Name} {proj.Id} action {act.Risk} {act.Description}"));
            }
        }

        return list;
    }

    private static (double Bonus, string Reason) ComputeContextBonus(CapabilityInfo cap, SuggestionContext context)
    {
        double bonus = 5.0;
        string reason = DescribeCapabilityShort(cap);

        if (string.Equals(context.CurrentScreen, "Projects", StringComparison.OrdinalIgnoreCase) && cap.Provider == "wsctl")
        {
            bonus += 15.0;
            reason = $"{DescribeCapabilityShort(cap)} (Projects view)";
        }
        else if (string.Equals(context.CurrentScreen, "Environments", StringComparison.OrdinalIgnoreCase) && cap.Provider == "ulvo")
        {
            bonus += 15.0;
            reason = $"{DescribeCapabilityShort(cap)} (Runtimes view)";
        }
        else if (context.CurrentScreen.StartsWith("Files", StringComparison.OrdinalIgnoreCase) && cap.Provider == "fs")
        {
            bonus += 16.0;
            reason = $"{DescribeCapabilityShort(cap)} (Files context)";
        }
        else if (string.Equals(context.CurrentScreen, "DevGit", StringComparison.OrdinalIgnoreCase) && cap.Provider == "git")
        {
            bonus += 16.0;
            reason = $"{DescribeCapabilityShort(cap)} (Git workspace)";
        }
        else if (string.Equals(context.CurrentScreen, "Home", StringComparison.OrdinalIgnoreCase) && cap.Provider is "core" or "windows")
        {
            bonus += 10.0;
        }

        if (!string.IsNullOrWhiteSpace(context.ActiveDirectory) && cap.Id is "fs.list" or "git.status")
        {
            bonus += 6.0;
        }

        if (context.ActiveProject is not null && cap.Id is "ulvo.project.inspect" or "wsctl.project.inspect" or "workctl.context")
        {
            bonus += 8.0;
            reason += $"; project '{context.ActiveProject.Id}'";
        }

        return (bonus, reason);
    }

    private static string DescribeCapabilityShort(CapabilityInfo cap) => cap.Id switch
    {
        "workctl.capabilities" => "Registered read-only capabilities and provider availability",
        "workctl.context" => "Active directory, matched project, runtimes, and tools",
        "workctl.health" => "Host load, Doctor cache age, and ULVO status summary",
        "workctl.suggest" => "Deterministic capability ranking for query or project",
        "wsctl.projects" => "Registered WSCTL project catalog and disk accessibility",
        "wsctl.project.inspect" => "Project root, metadata, and declared action risks",
        "ulvo.runtimes" => "Tracked ULVO project environments without vault scans",
        "ulvo.project.inspect" => "Fast zero-write ULVO manifest and connector check",
        "windows.machine" => "OS, CPU, RAM, fixed drives, and process count",
        _ => cap.Description
    };

    private static (double Score, string MatchKind) ScoreMatch(string query, RawCandidate candidate)
    {
        if (string.IsNullOrEmpty(query))
            return (10.0, "contextual");

        string cmd = candidate.Command;
        string id = candidate.CapabilityId;
        string name = candidate.DisplayName;

        if (cmd.StartsWith(query, StringComparison.OrdinalIgnoreCase) || id.StartsWith(query, StringComparison.OrdinalIgnoreCase))
            return (100.0 - Math.Min(20.0, cmd.Length * 0.2), "prefix");

        // Also match second-token prefixes such as "--project" or "projects" or action names
        foreach (string token in candidate.SearchHaystack.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (token.StartsWith(query, StringComparison.OrdinalIgnoreCase))
                return (82.0 - Math.Min(15.0, token.Length * 0.2), "token_prefix");
        }

        if (name.Contains(query, StringComparison.OrdinalIgnoreCase) || cmd.Contains(query, StringComparison.OrdinalIgnoreCase))
            return (65.0, "substring");

        double? fuzzyCmd = ScoreFuzzySubsequence(query, cmd);
        double? fuzzyName = ScoreFuzzySubsequence(query, name);
        double? best = (fuzzyCmd, fuzzyName) switch
        {
            (double a, double b) => Math.Max(a, b),
            (double a, null) => a,
            (null, double b) => b,
            _ => null
        };

        return best.HasValue ? (best.Value, "fuzzy") : (0.0, "none");
    }

    private static double? ScoreFuzzySubsequence(string pattern, string target)
    {
        if (string.IsNullOrEmpty(pattern) || string.IsNullOrEmpty(target))
            return null;

        int pi = 0;
        int contiguous = 0;
        double score = 20.0;

        for (int ti = 0; ti < target.Length && pi < pattern.Length; ti++)
        {
            if (char.ToUpperInvariant(target[ti]) == char.ToUpperInvariant(pattern[pi]))
            {
                bool isBoundary = ti == 0 || !char.IsLetterOrDigit(target[ti - 1]);
                if (isBoundary) score += 6.0;
                score += contiguous > 0 ? 4.5 : 1.0;
                contiguous++;
                pi++;
            }
            else
            {
                contiguous = 0;
            }
        }

        if (pi < pattern.Length)
            return null;

        return Math.Min(59.0, score - target.Length * 0.1);
    }
}
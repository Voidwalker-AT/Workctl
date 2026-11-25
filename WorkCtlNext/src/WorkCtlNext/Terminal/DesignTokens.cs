using System.Globalization;
using WorkCtlNext.Core;

namespace WorkCtlNext.Terminal;

public enum LayoutBreakpoint
{
    Narrow = 0,   // < 88 cols (e.g. 70x18)
    Standard = 1, // 88..111 cols (e.g. 100x28)
    Wide = 2      // >= 112 cols (e.g. 120x32)
}

public sealed record TuiVisualOptions(
    bool NoColor,
    bool ReducedMotion,
    bool AsciiOnly)
{
    public static TuiVisualOptions FromEnvironmentAndArgs(string[] args)
    {
        bool noColor = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("NO_COLOR"))
            || args.Contains("--no-color", StringComparer.OrdinalIgnoreCase);
        bool noAnim = string.Equals(Environment.GetEnvironmentVariable("WORKCTL_NO_ANIM"), "1", StringComparison.Ordinal)
            || args.Contains("--no-anim", StringComparer.OrdinalIgnoreCase)
            || args.Contains("--reduced-motion", StringComparer.OrdinalIgnoreCase);
        bool ascii = args.Contains("--ascii", StringComparer.OrdinalIgnoreCase)
            || string.Equals(Environment.GetEnvironmentVariable("WORKCTL_ASCII"), "1", StringComparison.Ordinal);
        return new TuiVisualOptions(noColor, noAnim, ascii);
    }
}

/// <summary>
/// OKLCH-derived dark graphite instrumentation palette (cool slate neutrals H ~ 248 deg,
/// split-analogous teal-cyan accent H ~ 206 deg) with terminal canvas inheritance,
/// WCAG 2.2 AA readable text contrast (>= 4.5:1 on every elevated surface), and
/// CVD-safe lightness separation (delta-L >= 0.15 between Success and Error).
/// </summary>
public sealed class DesignTheme
{
    private static readonly string[] BrailleSpinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
    private static readonly string[] AsciiSpinner = ["|", "/", "-", "\\"];

    public bool NoColor { get; }
    public bool AsciiOnly { get; }

    // Foreground palette ANSI tokens (empty when NO_COLOR active)
    public string Reset => NoColor ? "" : "\u001b[0m";
    public string Bold => NoColor ? "" : "\u001b[1m";
    public string Primary => NoColor ? "" : "\u001b[38;2;226;232;236m";    // #e2e8ec oklch(0.928 0.008 236.6)
    public string Secondary => NoColor ? "" : "\u001b[38;2;154;166;178m";  // #9aa6b2 oklch(0.719 0.022 248.1)
    public string MutedText => NoColor ? "" : "\u001b[38;2;130;144;158m";  // #82909e oklch(0.647 0.027 248.2) >= 4.6:1 even on #1e2730
    public string Border => NoColor ? "" : "\u001b[38;2;96;108;120m";      // #606c78 oklch(0.525 0.024 248.3) hairlines/track >= 3.2:1
    public string Muted => MutedText;                                      // Backward-compatible alias for readable dimmed text
    public string Accent => NoColor ? "" : "\u001b[38;2;86;182;194m";      // #56b6c2 oklch(0.723 0.092 206.3)
    public string Success => NoColor ? "" : "\u001b[38;2;131;219;165m";    // #83dba5 oklch(0.821 0.115 155.9) delta-L=0.150 vs Error
    public string Warning => NoColor ? "" : "\u001b[38;2;226;179;84m";     // #e2b354 oklch(0.791 0.125 82.7)
    public string Error => NoColor ? "" : "\u001b[38;2;224;108;117m";      // #e06c75 oklch(0.671 0.145 17.0)

    // Surface elevation tokens
    public string FocusRowBg => NoColor ? "" : "\u001b[48;2;30;39;48m";    // #1e2730 elevated focused row / input
    public string InactiveRowBg => NoColor ? "" : "\u001b[48;2;22;27;33m"; // #161b21 unfocused active marker
    public string CommandBarBg => NoColor ? "" : "\u001b[48;2;20;25;31m";  // #14191f recessed search/command strip
    public string HeaderBarBg => NoColor ? "" : "\u001b[48;2;17;21;26m";   // #11151a recessed top chrome header

    // Glyphs (safe Unicode or strict 7-bit ASCII fallback)
    public string RuleH => AsciiOnly ? "-" : "─";
    public string RuleV => AsciiOnly ? "|" : "│";
    public string ScrollTrack => AsciiOnly ? "|" : "│";
    public string ScrollThumb => AsciiOnly ? "#" : "┃";
    public string FocusPointer => AsciiOnly ? ">" : "▸";
    public string TreeExpanded => AsciiOnly ? "v" : "▾";
    public string TreeCollapsed => AsciiOnly ? ">" : "▸";
    public string TreeLeaf => AsciiOnly ? "-" : "·";
    public string BackArrow => AsciiOnly ? "<-" : "←";
    public string EmDash => AsciiOnly ? "-" : "—";
    public string DotLive => AsciiOnly ? "*" : "•";
    public string DotIdle => AsciiOnly ? "o" : "◦";
    public string IconOk => AsciiOnly ? "+" : "✓";
    public string IconWarn => AsciiOnly ? "!" : "▲";
    public string IconErr => AsciiOnly ? "x" : "×";
    public string BarFull => AsciiOnly ? "#" : "█";
    public string BarEmpty => AsciiOnly ? "-" : "░";
    public string MiddleDot => AsciiOnly ? "|" : "·";
    public string Arrows => AsciiOnly ? "^v" : "↑↓";

    public DesignTheme(bool noColor, bool asciiOnly)
    {
        NoColor = noColor;
        AsciiOnly = asciiOnly;
    }

    public static LayoutBreakpoint GetBreakpoint(int width)
        => width >= 112 ? LayoutBreakpoint.Wide
         : width >= 88 ? LayoutBreakpoint.Standard
         : LayoutBreakpoint.Narrow;

    public string SpinnerGlyph(int frameIndex, bool reducedMotion)
    {
        if (reducedMotion)
            return DotIdle;
        string[] frames = AsciiOnly ? AsciiSpinner : BrailleSpinner;
        return frames[Math.Abs(frameIndex) % frames.Length];
    }

    public string Style(string color, string text)
        => NoColor || string.IsNullOrEmpty(color) ? text : $"{color}{text}{Reset}";

    public string BuildBar(double ratio, int barWidth, string fillColor)
    {
        double clamped = Math.Clamp(ratio, 0.0, 1.0);
        int filled = (int)Math.Round(clamped * barWidth, MidpointRounding.AwayFromZero);
        if (clamped > 0.0 && filled == 0)
            filled = 1;
        // Preserve 1 empty cell until genuinely >= 99.5% so 96% and 100% remain visually distinct.
        if (clamped < 0.995 && barWidth > 1 && filled >= barWidth)
            filled = barWidth - 1;
        filled = Math.Clamp(filled, 0, barWidth);
        int empty = barWidth - filled;

        string fullPart = string.Concat(Enumerable.Repeat(BarFull, filled));
        string emptyPart = string.Concat(Enumerable.Repeat(BarEmpty, empty));
        return NoColor
            ? $"[{fullPart}{emptyPart}]"
            : $"{fillColor}{fullPart}{Border}{emptyPart}{Reset}";
    }

    public string ThresholdColor(double percent)
        => percent >= 90 ? Error
         : percent >= 75 ? Warning
         : Accent;

    public static string FormatAgeCompact(double? ageSeconds)
    {
        if (ageSeconds is null) return "unknown age";
        double s = Math.Max(0, ageSeconds.Value);
        if (s < 60) return $"{s:F0}s ago";
        if (s < 3600) return $"{s / 60.0:F0}m ago";
        if (s < 86400) return $"{s / 3600.0:F0}h ago";
        return $"{s / 86400.0:F0}d ago";
    }

    public (string Label, string Glyph, string Color) FormatDoctorSummary(WsctlHealthSnapshot? health, bool loading)
    {
        if (health is null)
            return loading ? ("Checking cache...", DotIdle, Secondary) : ("Pending", DotIdle, MutedText);

        if (string.Equals(health.DoctorSnapshotStatus, "UNAVAILABLE", StringComparison.OrdinalIgnoreCase))
            return ("No cached report", IconWarn, Warning);

        if (string.Equals(health.DoctorSnapshotStatus, "INVALID_ARTIFACT", StringComparison.OrdinalIgnoreCase))
            return ("Cache corrupt", IconErr, Error);

        string age = FormatAgeCompact(health.DoctorSnapshotAgeSeconds);
        if (health.DoctorSnapshotStale)
            return ($"Cached {MiddleDot} {age} {MiddleDot} Stale", IconWarn, Warning);

        string counts = health.DoctorOkCount.HasValue && health.DoctorTotalChecks.HasValue
            ? $"{health.DoctorOkCount}/{health.DoctorTotalChecks} passed"
            : health.DoctorSnapshotStatus;
        return ($"Verified ({counts} {MiddleDot} {age})", IconOk, Success);
    }

    public static string FormatCpuCompact(string cpuName, int logicalCores, int maxWidth)
    {
        if (string.IsNullOrWhiteSpace(cpuName))
            return $"Unknown CPU ({logicalCores}c)";

        string clean = cpuName
            .Replace("(R)", string.Empty, StringComparison.OrdinalIgnoreCase)
            .Replace("(TM)", string.Empty, StringComparison.OrdinalIgnoreCase)
            .Replace("  ", " ", StringComparison.Ordinal);

        int atIdx = clean.IndexOf(" @ ", StringComparison.Ordinal);
        if (atIdx > 0)
            clean = clean[..atIdx];
        clean = clean.Trim();

        string full = $"{clean} ({logicalCores}c)";
        if (full.Length <= maxWidth)
            return full;

        // Drop leading "12th Gen " / "13th Gen " marketing prefix before truncating actual model identifier.
        int genIdx = clean.IndexOf("Gen ", StringComparison.OrdinalIgnoreCase);
        if (genIdx > 0 && genIdx < 12)
        {
            string withoutGen = clean[(genIdx + 4)..].Trim();
            string candidate = $"{withoutGen} ({logicalCores}c)";
            if (candidate.Length <= maxWidth)
                return candidate;
            full = candidate;
        }

        return full;
    }

    public static string FormatOsCompact(string osVersion)
    {
        if (string.IsNullOrWhiteSpace(osVersion))
            return "Windows";

        string s = osVersion
            .Replace("Microsoft Windows 10.0.", "Win10 ", StringComparison.OrdinalIgnoreCase)
            .Replace("Microsoft Windows 11.0.", "Win11 ", StringComparison.OrdinalIgnoreCase)
            .Replace("Microsoft Windows ", "Win ", StringComparison.OrdinalIgnoreCase)
            .Replace(" (X64)", " x64", StringComparison.OrdinalIgnoreCase)
            .Replace(" (Arm64)", " arm64", StringComparison.OrdinalIgnoreCase)
            .Trim();
        return s;
    }

    public string FormatEnvTag(string? rawEnv)
    {
        if (string.IsNullOrWhiteSpace(rawEnv))
            return EmDash;

        string t = rawEnv.Trim();
        string lower = t.ToLowerInvariant();
        if (lower == "none") return EmDash;
        if (lower.StartsWith("node", StringComparison.Ordinal)) return "node";
        if (lower.StartsWith("ulvo", StringComparison.Ordinal)) return "ulvo";
        if (lower.StartsWith("godot", StringComparison.Ordinal)) return "godot";
        if (lower.StartsWith("system/", StringComparison.Ordinal)) return "sys/dyn";
        if (lower.StartsWith(".net", StringComparison.Ordinal) || lower == "dotnet") return ".net";
        if (lower.StartsWith("python", StringComparison.Ordinal)) return "python";
        return TruncateEnd(t, 8, AsciiOnly);
    }

    public string FormatEcosystem(string? rawEco, int maxWidth = 12)
    {
        if (string.IsNullOrWhiteSpace(rawEco))
            return EmDash;

        string t = rawEco.Trim();
        if (t.StartsWith("multi-eco", StringComparison.OrdinalIgnoreCase))
            return TruncateEnd("Multi-Eco", maxWidth, AsciiOnly);

        return TruncateEnd(t, maxWidth, AsciiOnly);
    }

    public static string TruncateMiddle(string text, int maxWidth)
    {
        if (maxWidth <= 0) return string.Empty;
        if (text.Length <= maxWidth) return text;
        if (maxWidth <= 4) return text[..maxWidth];
        int head = Math.Max(2, (maxWidth - 3) / 3);
        int tail = Math.Max(2, maxWidth - head - 3);
        return string.Concat(text.AsSpan(0, head), "...", text.AsSpan(text.Length - tail));
    }

    public string TruncateEnd(string text, int maxWidth)
        => TruncateEnd(text, maxWidth, AsciiOnly);

    public static string TruncateEnd(string text, int maxWidth, bool asciiOnly = false)
    {
        if (maxWidth <= 0) return string.Empty;
        if (text.Length <= maxWidth) return text;
        if (asciiOnly)
        {
            if (maxWidth <= 3) return text[..maxWidth];
            return string.Concat(text.AsSpan(0, maxWidth - 3), "...");
        }
        if (maxWidth == 1) return text[..1];
        return string.Concat(text.AsSpan(0, maxWidth - 1), "…");
    }

    public static IReadOnlyList<string> WrapText(string text, int maxWidth, bool asciiOnly = false)
    {
        if (maxWidth <= 4) return [TruncateEnd(text, Math.Max(1, maxWidth), asciiOnly)];
        if (string.IsNullOrEmpty(text)) return [string.Empty];

        var lines = new List<string>();
        string remaining = text.Trim();
        while (remaining.Length > maxWidth)
        {
            int split = remaining.LastIndexOf(' ', maxWidth);
            if (split <= maxWidth / 3)
                split = maxWidth;
            lines.Add(remaining[..split].TrimEnd());
            remaining = remaining[split..].TrimStart();
        }
        if (remaining.Length > 0)
            lines.Add(remaining);
        return lines;
    }

    public static string FormatGbCompact(double gb)
        => gb.ToString("F1", CultureInfo.InvariantCulture) + " GB";
}

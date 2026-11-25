using System.Diagnostics;

namespace WorkCtlNext.Core;

public enum ShellExecutionKind
{
    Empty = 0,
    WorkCtlNative = 1,
    PowerShellCaptured = 2,
    CmdCaptured = 3,
    InteractiveForeground = 4
}

public sealed record ShellCommandClassification(
    ShellExecutionKind Kind,
    string RawInput,
    string EffectiveCommand,
    string? TargetExecutable,
    string? TargetArguments,
    string ModeLabel,
    string Reason);

public sealed record ShellExecutionOutcome(
    ShellCommandClassification Classification,
    bool Success,
    int ExitCode,
    IReadOnlyList<string> OutputLines,
    long DurationMs,
    string? ErrorCode = null,
    string? ErrorMessage = null);

/// <summary>
/// Explicit 4-way shell router distinguishing WorkCtl built-in commands from
/// explicit native PowerShell, CMD, and interactive foreground external applications
/// without passing arbitrary native shell syntax through WorkCtl's parser.
/// </summary>
public static class ShellCommandRouter
{
    private static readonly HashSet<string> InteractivePrograms = new(StringComparer.OrdinalIgnoreCase)
    {
        "vim", "nvim", "vi", "nano", "less", "more", "ssh", "sftp",
        "htop", "btop", "top", "diskpart", "lazygit", "yazi", "fzf"
    };

    private static readonly HashSet<string> InteractiveShellNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "pwsh", "pwsh.exe", "powershell", "powershell.exe", "cmd", "cmd.exe", "python", "python.exe", "node", "node.exe"
    };

    private static readonly HashSet<string> CmdBuiltInOrUtilities = new(StringComparer.OrdinalIgnoreCase)
    {
        "echo", "ver", "whoami", "ipconfig", "where", "tasklist", "systeminfo", "netstat", "set", "assoc", "ftype", "doskey"
    };

    private static readonly HashSet<string> ExternalNonInteractiveTools = new(StringComparer.OrdinalIgnoreCase)
    {
        "dotnet", "uv", "cargo", "rustc", "go", "npm", "pnpm", "pip", "winget", "scoop", "choco", "rg", "fd", "wsctl", "ulvo"
    };

    public static ShellCommandClassification Classify(string? rawInput, WorkctlPathsConfig config)
    {
        string raw = rawInput ?? string.Empty;
        string trimmed = raw.Trim();
        if (string.IsNullOrEmpty(trimmed))
            return new(ShellExecutionKind.Empty, raw, string.Empty, null, null, "NONE", "Empty input");

        // 1. Explicit WorkCtl built-in prefix ':' or 'wctl '
        if (trimmed.StartsWith(':'))
        {
            string body = trimmed[1..].TrimStart();
            return new(ShellExecutionKind.WorkCtlNative, raw, body, null, null, "SYS", "Explicit WorkCtl built-in command");
        }

        // 2. Explicit Foreground Interactive Handoff ('!cmd', 'fg ...', 'run ...')
        if (trimmed.StartsWith('!'))
        {
            string body = trimmed[1..].TrimStart();
            if (string.IsNullOrEmpty(body))
                return new(ShellExecutionKind.InteractiveForeground, raw, string.Empty, ResolvePwsh(config), "-NoLogo", "TTY", "Interactive PowerShell session");

            SplitFirstToken(body, out string exe, out string args);
            string resolvedExe = ResolveExecutableForHandoff(exe, config, out string resolvedArgs, args);
            return new(ShellExecutionKind.InteractiveForeground, raw, body, resolvedExe, resolvedArgs, "TTY", "Explicit foreground console handoff");
        }

        SplitFirstToken(trimmed, out string firstVerb, out string tail);

        if (firstVerb is "fg" or "run" && !string.IsNullOrWhiteSpace(tail))
        {
            SplitFirstToken(tail, out string exe, out string args);
            string resolvedExe = ResolveExecutableForHandoff(exe, config, out string resolvedArgs, args);
            return new(ShellExecutionKind.InteractiveForeground, raw, tail, resolvedExe, resolvedArgs, "TTY", "Explicit foreground application handoff");
        }

        // 3. Explicit PowerShell captured command ('pwsh <cmd>', 'ps1 <cmd>', 'psh <cmd>')
        if (firstVerb is "pwsh" or "pwsh.exe" or "ps1" or "psh" or "powershell" or "powershell.exe")
        {
            if (string.IsNullOrWhiteSpace(tail))
            {
                string sh = firstVerb.StartsWith("powershell", StringComparison.OrdinalIgnoreCase) ? "powershell.exe" : ResolvePwsh(config);
                return new(ShellExecutionKind.InteractiveForeground, raw, trimmed, sh, "-NoLogo", "TTY", "Bare interactive shell launches foreground TTY");
            }
            return new(ShellExecutionKind.PowerShellCaptured, raw, tail, ResolvePwsh(config), tail, "PWSH", "Native PowerShell command (raw syntax preserved)");
        }

        // 4. Explicit CMD captured command ('cmd <cmd>', 'cmd.exe <cmd>')
        if (firstVerb is "cmd" or "cmd.exe")
        {
            if (string.IsNullOrWhiteSpace(tail))
                return new(ShellExecutionKind.InteractiveForeground, raw, trimmed, "cmd.exe", string.Empty, "TTY", "Bare interactive CMD launches foreground TTY");
            return new(ShellExecutionKind.CmdCaptured, raw, tail, "cmd.exe", tail, "CMD", "Native CMD command (raw syntax preserved)");
        }

        // 5. WorkCtl built-in command match (kept in native parser for safety, so unsafe 'ls | ...' stays rejected)
        string verbLower = firstVerb.ToLowerInvariant();
        if (CommandLineParser.ResolveCanonicalVerb(verbLower) is not null)
        {
            return new(ShellExecutionKind.WorkCtlNative, raw, trimmed, null, null, "SYS", "WorkCtl built-in command");
        }

        // 6. Interactive standalone apps without inline execution -> foreground TTY handoff
        if (InteractivePrograms.Contains(firstVerb) ||
            (InteractiveShellNames.Contains(firstVerb) && string.IsNullOrWhiteSpace(tail)))
        {
            return new(ShellExecutionKind.InteractiveForeground, raw, trimmed, firstVerb, tail, "TTY", "Interactive external application");
        }

        // 7. Native PowerShell cmdlet Verb-Noun syntax (e.g., Get-ChildItem, Select-String) or $variable / $(expr)
        if (LooksLikePowerShellExpression(firstVerb, trimmed))
        {
            return new(ShellExecutionKind.PowerShellCaptured, raw, trimmed, ResolvePwsh(config), trimmed, "PWSH", "PowerShell cmdlet/expression preserved verbatim");
        }

        // 8. Recognized CMD utilities (e.g., echo, ipconfig, where, whoami, ver, tasklist)
        if (CmdBuiltInOrUtilities.Contains(firstVerb))
        {
            return new(ShellExecutionKind.CmdCaptured, raw, trimmed, "cmd.exe", trimmed, "CMD", "Windows CMD command preserved verbatim");
        }

        // 9. Recognized external CLI tool with arguments (e.g., dotnet --version, git log -n 5, python -c "...") -> captured cleanly via PowerShell/process
        if (ExternalNonInteractiveTools.Contains(firstVerb) || InteractiveShellNames.Contains(firstVerb))
        {
            return new(ShellExecutionKind.PowerShellCaptured, raw, trimmed, ResolvePwsh(config), trimmed, "PWSH", $"External tool '{firstVerb}' captured in workspace");
        }

        // Default back to WorkCtl native so unrecognized typos get helpful command suggestions & error details
        return new(ShellExecutionKind.WorkCtlNative, raw, trimmed, null, null, "SYS", "Unrecognized command checked against WorkCtl registry");
    }

    private static bool LooksLikePowerShellExpression(string firstVerb, string trimmed)
    {
        if (trimmed.StartsWith('$') || trimmed.StartsWith("& {", StringComparison.Ordinal) || trimmed.StartsWith("& (", StringComparison.Ordinal))
            return true;

        int dash = firstVerb.IndexOf('-');
        if (dash > 1 && dash < firstVerb.Length - 1)
        {
            bool leftLetters = firstVerb[..dash].All(char.IsLetter);
            bool rightAlpha = firstVerb[(dash + 1)..].All(char.IsLetterOrDigit);
            if (leftLetters && rightAlpha)
                return true;
        }
        return false;
    }

    private static string ResolvePwsh(WorkctlPathsConfig config)
        => !string.IsNullOrWhiteSpace(config.PwshExecutable) ? config.PwshExecutable : "pwsh.exe";

    private static string ResolveExecutableForHandoff(string exe, WorkctlPathsConfig config, out string finalArgs, string rawArgs)
    {
        if (string.Equals(exe, "pwsh", StringComparison.OrdinalIgnoreCase))
        {
            finalArgs = string.IsNullOrWhiteSpace(rawArgs) ? "-NoLogo" : $"-NoLogo {rawArgs}";
            return ResolvePwsh(config);
        }
        finalArgs = rawArgs;
        return exe;
    }

    private static void SplitFirstToken(string text, out string first, out string rest)
    {
        int i = 0;
        while (i < text.Length && !char.IsWhiteSpace(text[i]))
            i++;
        first = text[..i];
        rest = i < text.Length ? text[i..].TrimStart() : string.Empty;
    }
}

public static class ShellExecutionService
{
    public static async Task<ShellExecutionOutcome> ExecuteCapturedAsync(
        ShellCommandClassification classification,
        WorkctlPathsConfig config,
        IProcessRunner runner,
        string workingDirectory,
        CancellationToken cancellationToken)
    {
        var sw = Stopwatch.StartNew();
        string cwd = Directory.Exists(PathNormalizer.EnsureLongPathPrefix(workingDirectory))
            ? workingDirectory
            : (Directory.Exists(config.WorkspaceRoot) ? config.WorkspaceRoot : AppContext.BaseDirectory);

        string exe;
        string[] args;
        if (classification.Kind == ShellExecutionKind.CmdCaptured)
        {
            exe = "cmd.exe";
            args = ["/d", "/c", classification.EffectiveCommand];
        }
        else
        {
            exe = !string.IsNullOrWhiteSpace(config.PwshExecutable) ? config.PwshExecutable : "pwsh.exe";
            args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", classification.EffectiveCommand];
        }

        SubprocessResult res = await runner.RunAsync(
            exe,
            args,
            cwd,
            TimeSpan.FromSeconds(20),
            cancellationToken).ConfigureAwait(false);
        sw.Stop();

        var lines = new List<string>();
        if (!string.IsNullOrWhiteSpace(res.Stdout))
        {
            foreach (string ln in res.Stdout.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
                lines.Add(ln);
            while (lines.Count > 0 && lines[^1].Length == 0)
                lines.RemoveAt(lines.Count - 1);
        }
        if (!string.IsNullOrWhiteSpace(res.Stderr))
        {
            foreach (string ln in res.Stderr.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
            {
                if (!string.IsNullOrEmpty(ln))
                    lines.Add($"[stderr] {ln}");
            }
        }

        if (res.TimedOut)
        {
            return new ShellExecutionOutcome(classification, false, 5, lines, sw.ElapsedMilliseconds, "SHELL_TIMEOUT", $"Command timed out after {sw.ElapsedMilliseconds}ms.");
        }
        if (res.Cancelled)
        {
            return new ShellExecutionOutcome(classification, false, 5, lines, sw.ElapsedMilliseconds, "SHELL_CANCELLED", "Shell command was cancelled.");
        }
        if (res.StartFailed)
        {
            return new ShellExecutionOutcome(classification, false, 4, lines, sw.ElapsedMilliseconds, "SHELL_UNAVAILABLE", res.StartError ?? $"Shell executable '{exe}' could not be launched.");
        }

        bool ok = res.ExitCode == 0;
        return new ShellExecutionOutcome(
            classification,
            ok,
            res.ExitCode,
            lines,
            sw.ElapsedMilliseconds,
            ok ? null : "NONZERO_EXIT",
            ok ? null : $"Exited with code {res.ExitCode}.");
    }
}

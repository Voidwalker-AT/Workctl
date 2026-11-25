using System.Text;

namespace WorkCtlNext.Core;

public sealed record CommandToken(
    string RawText,
    string UnquotedText,
    int StartIndex,
    int EndIndex,
    bool IsQuoted,
    bool IsClosedQuote);

public sealed record BuiltInCommandSpec(
    string Name,
    IReadOnlyList<string> Aliases,
    string Syntax,
    string Summary,
    bool MutatesFilesystem,
    bool RequiresConfirmation);

public sealed record ParsedCommandLine(
    bool IsEmpty,
    bool IsValid,
    string RawInput,
    string? CommandVerb,
    IReadOnlyList<CommandToken> Tokens,
    IReadOnlyList<string> Arguments,
    string? ErrorCode,
    string? ErrorMessage);

public static class CommandLineParser
{
    public static IReadOnlyList<BuiltInCommandSpec> BuiltInCommands { get; } =
    [
        new("help", ["?"], "help [command]", "Show available interactive commands and keybindings", false, false),
        new("ls", ["dir"], "ls [path]", "List directory contents in current or specified directory", false, false),
        new("cd", [], "cd <path>", "Change active working directory (syncs File Browser)", false, false),
        new("pwd", [], "pwd", "Print active workstation directory path", false, false),
        new("stat", ["inspect"], "stat <path>", "Inspect file metadata, hardlinks, junctions, protection", false, false),
        new("preview", ["cat"], "preview <file>", "Preview bounded UTF-8/UTF-16 text file safely", false, false),
        new("open", ["go", "view"], "open <section|project|path>", "Switch section, open project, or open directory/file", false, false),
        new("projects", [], "projects [filter]", "Open or filter registered WSCTL projects", false, false),
        new("project", [], "project <id>", "Set active project and inspect details", false, false),
        new("context", [], "context", "Refresh combined machine + WSCTL + ULVO context", false, false),
        new("runtimes", ["ulvo"], "runtimes", "Inspect ULVO environments and status", false, false),
        new("health", [], "health", "Inspect workstation & cached WSCTL doctor health", false, false),
        new("capabilities", ["caps"], "capabilities", "List registered capabilities and availability", false, false),
        new("suggest", [], "suggest [query]", "Rank commands/actions deterministically", false, false),
        new("git", [], "git [path]", "Inspect read-only Git status for active directory", false, false),
        new("tasks", ["processes", "ps", "top"], "tasks [inspect <pid>|sort <col>|tree]", "Integrated Windows Task Manager view and inspection", false, false),
        new("kill", ["end-task"], "kill <pid>", "Analyze process impact & terminate with confirmation (Human TUI only)", true, true),
        new("pwsh", ["ps1", "psh"], "pwsh <command>", "Run explicit native PowerShell command (captured in console)", false, false),
        new("cmd", [], "cmd <command>", "Run explicit native CMD command (captured in console)", false, false),
        new("fg", ["run"], "fg <exe> [args]", "Suspend TUI and run interactive command in foreground terminal", false, false),
        new("perf", ["performance"], "perf", "View live CPU/RAM performance snapshot", false, false),
        new("storage", ["df"], "storage", "View mounted Windows volumes and free space", false, false),
        new("network", ["net"], "network", "View network adapters and IPv4 status", false, false),
        new("apps", [], "apps", "View running windowed applications", false, false),
        new("back", [], "back", "Navigate back in session history", false, false),
        new("forward", [], "forward", "Navigate forward in session history", false, false),
        new("clear", ["cls"], "clear", "Clear shell transcript and dismiss result drawer", false, false),
        new("exit", ["quit"], "exit", "Exit WorkCtl Next cleanly and restore terminal state", false, false),
        new("mkdir", [], "mkdir <name>", "Create new directory (confirmed, policy-checked)", true, true),
        new("cp", ["copy"], "cp <src> [dst]", "Copy file or directory without silent overwrite", true, true),
        new("mv", ["move"], "mv <src> <dst>", "Move file or directory with cross-volume verification", true, true),
        new("cut", [], "cut <path...>", "Place items onto internal Cut clipboard", false, false),
        new("paste", [], "paste [dstDir]", "Paste internal clipboard items (confirmed)", true, true),
        new("rename", ["ren"], "rename <src> <newName>", "Rename file or directory safely", true, true),
        new("rm", ["del", "delete"], "rm <path...>", "Recycle items (or unlink junctions) after confirmation", true, true)
    ];

    public static ParsedCommandLine Parse(string? rawInput)
    {
        string input = rawInput ?? string.Empty;
        if (string.IsNullOrWhiteSpace(input))
            return new ParsedCommandLine(true, true, input, null, Array.Empty<CommandToken>(), Array.Empty<string>(), null, null);

        (IReadOnlyList<CommandToken> tokens, string? syntaxErr, string? syntaxCode) = TokenizeInternal(input);
        if (syntaxErr is not null)
        {
            return new ParsedCommandLine(
                IsEmpty: false,
                IsValid: false,
                RawInput: input,
                CommandVerb: tokens.Count > 0 ? tokens[0].UnquotedText : null,
                Tokens: tokens,
                Arguments: tokens.Skip(1).Select(t => t.UnquotedText).ToArray(),
                ErrorCode: syntaxCode,
                ErrorMessage: syntaxErr);
        }

        if (tokens.Count == 0)
            return new ParsedCommandLine(true, true, input, null, tokens, Array.Empty<string>(), null, null);

        if (tokens.Any(t => !t.IsClosedQuote))
        {
            return new ParsedCommandLine(
                IsEmpty: false,
                IsValid: false,
                RawInput: input,
                CommandVerb: tokens[0].UnquotedText,
                Tokens: tokens,
                Arguments: tokens.Skip(1).Select(t => t.UnquotedText).ToArray(),
                ErrorCode: "UNCLOSED_QUOTE",
                ErrorMessage: "Command has an unclosed quote.");
        }

        string verb = tokens[0].UnquotedText;
        string canonical = ResolveCanonicalVerb(verb) ?? verb.ToLowerInvariant();
        return new ParsedCommandLine(
            IsEmpty: false,
            IsValid: true,
            RawInput: input,
            CommandVerb: canonical,
            Tokens: tokens,
            Arguments: tokens.Skip(1).Select(t => t.UnquotedText).ToArray(),
            ErrorCode: null,
            ErrorMessage: null);
    }

    public static string? ResolveCanonicalVerb(string verb)
    {
        if (string.IsNullOrWhiteSpace(verb))
            return null;
        string lower = verb.Trim().ToLowerInvariant();
        foreach (BuiltInCommandSpec spec in BuiltInCommands)
        {
            if (string.Equals(spec.Name, lower, StringComparison.OrdinalIgnoreCase))
                return spec.Name;
            foreach (string alias in spec.Aliases)
            {
                if (string.Equals(alias, lower, StringComparison.OrdinalIgnoreCase))
                    return spec.Name;
            }
        }
        return null;
    }

    public static BuiltInCommandSpec? FindSpec(string? verb)
    {
        string? canonical = ResolveCanonicalVerb(verb ?? string.Empty);
        if (canonical is null)
            return null;
        return BuiltInCommands.FirstOrDefault(c => string.Equals(c.Name, canonical, StringComparison.OrdinalIgnoreCase));
    }

    public static (IReadOnlyList<CommandToken> Tokens, int ActiveTokenIndex) TokenizeForCompletion(string input, int cursorIndex)
    {
        (IReadOnlyList<CommandToken> tokens, _, _) = TokenizeInternal(input);
        int clamped = Math.Clamp(cursorIndex, 0, input.Length);

        for (int i = 0; i < tokens.Count; i++)
        {
            CommandToken t = tokens[i];
            if (clamped >= t.StartIndex && clamped <= t.EndIndex)
                return (tokens, i);
        }

        return (tokens, -1);
    }

    private static (IReadOnlyList<CommandToken> Tokens, string? Error, string? ErrorCode) TokenizeInternal(string input)
    {
        var tokens = new List<CommandToken>();
        int i = 0;
        int n = input.Length;
        string? shellSyntaxError = null;

        while (i < n)
        {
            while (i < n && char.IsWhiteSpace(input[i]))
                i++;
            if (i >= n)
                break;

            char c = input[i];
            if (c is '|' or '&' or ';' or '>' or '<' or '`')
            {
                shellSyntaxError ??= $"Unsupported shell operator '{c}': pipelines, redirection, and chaining are disabled for safety.";
                i++;
                continue;
            }

            if (c == '$' && i + 1 < n && input[i + 1] == '(')
            {
                shellSyntaxError ??= "Unsupported shell subexpression '$(' is disabled for safety.";
                i += 2;
                continue;
            }

            int start = i;
            var sb = new StringBuilder();
            bool quoted = false;
            bool closedQuote = true;

            if (c is '"' or '\'')
            {
                quoted = true;
                closedQuote = false;
                char quoteChar = c;
                i++;
                while (i < n)
                {
                    char ch = input[i];
                    if (ch == '\\' && i + 1 < n && input[i + 1] == quoteChar)
                    {
                        sb.Append(quoteChar);
                        i += 2;
                        continue;
                    }
                    if (ch == quoteChar)
                    {
                        closedQuote = true;
                        i++;
                        break;
                    }
                    sb.Append(ch);
                    i++;
                }
            }
            else
            {
                while (i < n && !char.IsWhiteSpace(input[i]))
                {
                    char ch = input[i];
                    if (ch is '|' or '&' or ';' or '>' or '<' or '`')
                    {
                        shellSyntaxError ??= $"Unsupported shell operator '{ch}': pipelines, redirection, and chaining are disabled for safety.";
                        break;
                    }
                    if (ch == '$' && i + 1 < n && input[i + 1] == '(')
                    {
                        shellSyntaxError ??= "Unsupported shell subexpression '$(' is disabled for safety.";
                        break;
                    }
                    if (ch == '"')
                    {
                        quoted = true;
                        closedQuote = false;
                        i++;
                        while (i < n)
                        {
                            if (input[i] == '"')
                            {
                                closedQuote = true;
                                i++;
                                break;
                            }
                            sb.Append(input[i]);
                            i++;
                        }
                        continue;
                    }
                    sb.Append(ch);
                    i++;
                }
            }

            int end = i;
            tokens.Add(new CommandToken(
                RawText: input[start..end],
                UnquotedText: sb.ToString(),
                StartIndex: start,
                EndIndex: end,
                IsQuoted: quoted,
                IsClosedQuote: closedQuote));
        }

        return (tokens, shellSyntaxError, shellSyntaxError is not null ? "UNSUPPORTED_SHELL_SYNTAX" : null);
    }
}

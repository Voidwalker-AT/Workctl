using System.Globalization;
using System.Text.Json;
using WorkCtlNext.Core;

namespace WorkCtlNext.Cli;

/// <summary>
/// Deterministic, zero-ANSI, low-token JSON command surface for AI agents.
/// Shares CapabilityDispatcher directly with the Human TUI.
/// </summary>
public sealed class AgentCli
{
    private readonly CapabilityDispatcher _dispatcher;
    private readonly TextWriter _stdout;
    private readonly TextWriter _stderr;

    public AgentCli(CapabilityDispatcher dispatcher, TextWriter? stdout = null, TextWriter? stderr = null)
    {
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _stdout = stdout ?? Console.Out;
        _stderr = stderr ?? Console.Error;
    }

    public static bool IsCliCommand(string[] args)
    {
        if (args.Length == 0)
            return false;

        string first = args[0];
        return !string.Equals(first, "tui", StringComparison.OrdinalIgnoreCase);
    }

    public async Task<int> ExecuteAsync(string[] args, CancellationToken cancellationToken)
    {
        if (args.Length == 0)
            return 2;

        string cmd = args[0].Trim();
        if (cmd is "--help" or "-h" or "help")
        {
            _stdout.WriteLine(BuildHelpText());
            return 0;
        }

        string[] flagArgs = args[1..];
        string lowerCmd = cmd.ToLowerInvariant();
        if (lowerCmd is "tasks" or "processes" && flagArgs.Length > 0 && string.Equals(flagArgs[0], "inspect", StringComparison.OrdinalIgnoreCase))
        {
            lowerCmd = "tasks inspect";
            flagArgs = flagArgs[1..];
        }

        string capabilityId = lowerCmd switch
        {
            "capabilities" => "workctl.capabilities",
            "context" => "workctl.context",
            "projects" => "wsctl.projects",
            "runtimes" => "ulvo.runtimes",
            "health" => "workctl.health",
            "suggest" => "workctl.suggest",
            "ls" or "dir" => "fs.list",
            "stat" or "inspect-file" => "fs.inspect",
            "preview" => "fs.preview",
            "resolve" => "fs.resolve",
            "tasks" or "processes" => "windows.processes",
            "tasks inspect" => "tasks.inspect",
            "storage" => "windows.storage",
            "network" => "windows.network",
            "git" => "git.status",
            "rm" or "delete" or "del" => "fs.delete",
            "mv" or "move" => "fs.move",
            "cp" or "copy" => "fs.copy",
            "mkdir" => "fs.mkdir",
            "rename" => "fs.rename",
            "kill" or "terminate" or "end-task" => "tasks.terminate",
            "pwsh" or "pwsh.exe" or "ps1" or "psh" or "powershell" or "powershell.exe" or "cmd" or "cmd.exe" or "fg" or "run" => "shell.exec",
            _ => string.Empty
        };

        if (string.IsNullOrEmpty(capabilityId))
        {
            return EmitError(2, cmd, "UNKNOWN_COMMAND", $"Unknown CLI command '{cmd}'. Run '--help' for supported commands.", pretty: false, verbose: false);
        }

        if (capabilityId is "fs.delete" or "fs.move" or "fs.copy" or "fs.mkdir" or "fs.rename" or "tasks.terminate" or "shell.exec")
        {
            return EmitError(2, capabilityId, "POLICY_BLOCKED", $"Command '{cmd}' ({capabilityId}) is mutating or shell execution and is blocked on Agent CLI (read-only surface).", pretty: false, verbose: false);
        }

        if (!TryParseFlags(flagArgs, capabilityId, out ParsedFlags? flags, out string? flagErr))
        {
            return EmitError(2, capabilityId, "INVALID_ARGUMENTS", flagErr!, pretty: false, verbose: false);
        }

        var req = new CapabilityInvocationRequest(
            CapabilityId: capabilityId,
            ProjectId: flags!.ProjectId,
            Category: flags.Category,
            Tag: flags.Tag,
            Query: flags.Query,
            Detailed: flags.Detailed,
            IncludeEnvStatus: flags.IncludeEnvStatus,
            IncludeProjects: flags.IncludeProjects,
            Limit: flags.Limit,
            TargetPath: flags.TargetPath,
            WorkingDirectory: flags.WorkingDirectory ?? Environment.CurrentDirectory,
            Caller: CallerSurface.AgentCli,
            Pid: flags.Pid);

        DispatchOutcome outcome = await _dispatcher.DispatchAsync(req, cancellationToken).ConfigureAwait(false);
        JsonSerializerOptions jsonOpts = flags.Pretty ? JsonDefaults.Readable : JsonDefaults.Compact;
        string serialized = JsonSerializer.Serialize(outcome.Envelope, jsonOpts);
        _stdout.WriteLine(serialized);

        if (!outcome.Envelope.Ok && outcome.Envelope.Error is not null)
        {
            _stderr.WriteLine($"[{outcome.Envelope.Error.Provider}] {outcome.Envelope.Error.Code}: {outcome.Envelope.Error.Message}");
        }

        return outcome.ExitCode;
    }

    private int EmitError(int exitCode, string cap, string code, string msg, bool pretty, bool verbose)
    {
        var env = new CapabilityEnvelope<object?>(
            SchemaVersion: 1,
            Ok: false,
            Capability: cap,
            CapturedAtUtc: DateTimeOffset.UtcNow,
            Freshness: "live",
            DurationMs: 0,
            Data: null,
            Error: new ErrorDetail(code, msg, "core"));

        _stdout.WriteLine(JsonSerializer.Serialize(env, pretty ? JsonDefaults.Readable : JsonDefaults.Compact));
        _stderr.WriteLine($"{code}: {msg}");
        return exitCode;
    }

    private static bool TryParseFlags(string[] rest, string capabilityId, out ParsedFlags? parsed, out string? error)
    {
        parsed = null;
        error = null;

        string? projectId = null;
        string? category = null;
        string? tag = null;
        string? query = null;
        string? targetPath = null;
        string? workingDir = null;
        bool detailed = false;
        bool pretty = false;
        bool verbose = false;
        bool includeEnvStatus = false;
        bool includeProjects = false;
        int? limit = null;
        int? pid = null;

        for (int i = 0; i < rest.Length; i++)
        {
            string arg = rest[i];
            switch (arg)
            {
                case "--json":
                    break; // Explicit default machine format
                case "--pretty":
                    pretty = true;
                    break;
                case "--detailed":
                    detailed = true;
                    break;
                case "--verbose":
                    verbose = true;
                    break;
                case "--include-env-status":
                    includeEnvStatus = true;
                    break;
                case "--include-projects":
                    includeProjects = true;
                    break;
                case "--project":
                    if (i + 1 >= rest.Length) { error = "Missing value for '--project'."; return false; }
                    projectId = rest[++i];
                    break;
                case "--category":
                    if (i + 1 >= rest.Length) { error = "Missing value for '--category'."; return false; }
                    category = rest[++i];
                    break;
                case "--tag":
                case "--sort":
                    if (i + 1 >= rest.Length) { error = $"Missing value for '{arg}'."; return false; }
                    tag = rest[++i];
                    break;
                case "--query":
                case "--filter":
                    if (i + 1 >= rest.Length) { error = $"Missing value for '{arg}'."; return false; }
                    query = rest[++i];
                    break;
                case "--path":
                    if (i + 1 >= rest.Length) { error = "Missing value for '--path'."; return false; }
                    targetPath = rest[++i];
                    break;
                case "--cwd":
                    if (i + 1 >= rest.Length) { error = "Missing value for '--cwd'."; return false; }
                    workingDir = rest[++i];
                    break;
                case "--pid":
                    if (i + 1 >= rest.Length || !int.TryParse(rest[++i], NumberStyles.Integer, CultureInfo.InvariantCulture, out int parsedPid) || parsedPid <= 0)
                    {
                        error = "'--pid' requires a positive integer.";
                        return false;
                    }
                    pid = parsedPid;
                    break;
                case "--limit":
                    if (i + 1 >= rest.Length || !int.TryParse(rest[++i], NumberStyles.Integer, CultureInfo.InvariantCulture, out int parsedLim) || parsedLim <= 0)
                    {
                        error = "'--limit' requires a positive integer.";
                        return false;
                    }
                    limit = parsedLim;
                    break;
                default:
                    if (!arg.StartsWith('-') && capabilityId == "wsctl.project.inspect" && projectId is null)
                    {
                        projectId = arg;
                        break;
                    }
                    if (!arg.StartsWith('-') && capabilityId is "fs.list" or "fs.inspect" or "fs.preview" or "fs.resolve" or "git.status" && targetPath is null)
                    {
                        targetPath = arg;
                        break;
                    }
                    if (!arg.StartsWith('-') && capabilityId == "tasks.inspect" && pid is null && int.TryParse(arg, NumberStyles.Integer, CultureInfo.InvariantCulture, out int posPid) && posPid > 0)
                    {
                        pid = posPid;
                        break;
                    }
                    error = $"Unknown option '{arg}' for '{capabilityId}'.";
                    return false;
            }
        }

        parsed = new ParsedFlags(projectId, category, tag, query, targetPath, workingDir, detailed, pretty, verbose, includeEnvStatus, includeProjects, limit, pid);
        return true;
    }

    public static string BuildHelpText() => string.Join(Environment.NewLine,
    [
        "workctl-next (Phase 2.1 — Command Shell, Navigation & Task Manager CLI)",
        "",
        "Human TUI:",
        "  workctl-next                  Launch interactive full-screen workstation shell inside current tab",
        "  workctl-next tui              Explicit TUI launch",
        "",
        "Agent CLI (compact JSON on stdout, diagnostics on stderr, zero ANSI, strictly read-only):",
        "  workctl-next --help",
        "  workctl-next capabilities --json",
        "  workctl-next context [--project <id>] [--detailed] [--include-env-status] --json",
        "  workctl-next projects [--category <cat>] [--tag <tag>] [--detailed] [--limit <n>] --json",
        "  workctl-next runtimes [--include-projects] [--limit <n>] --json",
        "  workctl-next health --json",
        "  workctl-next suggest [--query <text>] [--project <id>] [--limit <n>] --json",
        "  workctl-next ls [--path <dir>] [--limit <n>] --json",
        "  workctl-next stat --path <target> --json",
        "  workctl-next preview --path <file> [--limit <lines>] --json",
        "  workctl-next resolve --path <target> [--cwd <dir>] --json",
        "  workctl-next tasks [--sort <cpu|mem|pid|name>] [--filter <text>] [--limit <n>] --json",
        "  workctl-next tasks inspect --pid <pid> --json",
        "  workctl-next processes [--limit <n>] --json",
        "  workctl-next storage --json",
        "  workctl-next network --json",
        "  workctl-next git [--path <dir>] --json",
        "",
        "Flags: --json (default on CLI commands), --pretty, --verbose (stderr diagnostics)",
        "Exit codes: 0=ok, 1=error, 2=usage/policy, 3=not_found/ambiguous, 4=provider_unavailable, 5=timeout/cancelled"
    ]);

    private sealed record ParsedFlags(
        string? ProjectId,
        string? Category,
        string? Tag,
        string? Query,
        string? TargetPath,
        string? WorkingDirectory,
        bool Detailed,
        bool Pretty,
        bool Verbose,
        bool IncludeEnvStatus,
        bool IncludeProjects,
        int? Limit,
        int? Pid);
}
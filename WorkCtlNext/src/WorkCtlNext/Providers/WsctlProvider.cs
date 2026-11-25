using System.Globalization;
using System.Text.Json;
using WorkCtlNext.Core;

namespace WorkCtlNext.Providers;

/// <summary>
/// Read-only WSCTL provider executing only verified zero-write WSCTL CLI paths
/// (projects -Json, info -Json) and strictly validating output against known WSCTL
/// exit-code / single-object / corrupt-JSON defects without trusting exit code 0 blindly.
/// </summary>
public sealed class WsctlProvider
{
    private readonly IProcessRunner _runner;
    private readonly WorkctlPathsConfig _config;

    public WsctlProvider(IProcessRunner runner, WorkctlPathsConfig config)
    {
        _runner = runner ?? throw new ArgumentNullException(nameof(runner));
        _config = config ?? throw new ArgumentNullException(nameof(config));
    }

    public async Task<WsctlProjectsResult> GetProjectsAsync(CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(_config.PwshExecutable) || !File.Exists(_config.PwshExecutable))
        {
            return new WsctlProjectsResult(
                ProviderStatus.Unavailable,
                "wsctl_cli_no_write",
                0,
                [],
                Error: new ErrorDetail("PWSH_UNAVAILABLE", "PowerShell 7 (pwsh) executable was not found.", "wsctl"));
        }

        if (!File.Exists(_config.WsctlScriptPath))
        {
            return new WsctlProjectsResult(
                ProviderStatus.Unavailable,
                "wsctl_cli_no_write",
                0,
                [],
                Error: new ErrorDetail("WSCTL_UNAVAILABLE", $"WSCTL entrypoint '{_config.WsctlScriptPath}' was not found.", "wsctl"));
        }

        var args = new[]
        {
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", _config.WsctlScriptPath,
            "projects",
            "-Json"
        };

        SubprocessResult res = await _runner.RunAsync(
            _config.PwshExecutable,
            args,
            _config.WorkspaceRoot,
            _config.WsctlTimeout,
            cancellationToken).ConfigureAwait(false);

        if (res.StartFailed)
        {
            return new WsctlProjectsResult(
                ProviderStatus.Unavailable,
                "wsctl_cli_no_write",
                res.DurationMs,
                [],
                Error: new ErrorDetail("WSCTL_START_FAILED", res.StartError ?? "Failed to execute wsctl.", "wsctl"));
        }

        if (res.TimedOut)
        {
            return new WsctlProjectsResult(
                ProviderStatus.Timeout,
                "wsctl_cli_no_write",
                res.DurationMs,
                [],
                Error: new ErrorDetail("WSCTL_TIMEOUT", $"WSCTL query timed out after {res.DurationMs} ms.", "wsctl", Retryable: true));
        }

        if (res.Cancelled)
        {
            return new WsctlProjectsResult(
                ProviderStatus.Error,
                "wsctl_cli_no_write",
                res.DurationMs,
                [],
                Error: new ErrorDetail("WSCTL_CANCELLED", "WSCTL query was cancelled.", "wsctl"));
        }

        if (res.ExitCode != 0)
        {
            string msg = FirstNonEmpty(res.Stderr, $"WSCTL exited with code {res.ExitCode}.");
            return new WsctlProjectsResult(
                ProviderStatus.Error,
                "wsctl_cli_no_write",
                res.DurationMs,
                [],
                Error: new ErrorDetail("WSCTL_NONZERO_EXIT", msg, "wsctl", res.ExitCode));
        }

        return ParseProjectsJson(res.Stdout, res.Stderr, res.DurationMs);
    }

    public WsctlProjectsResult ParseProjectsJson(string stdout, string stderr, long durationMs)
    {
        string trimmed = stdout.Trim();
        if (string.IsNullOrEmpty(trimmed) || string.Equals(trimmed, "null", StringComparison.OrdinalIgnoreCase))
        {
            string detail = FirstNonEmpty(stderr, "WSCTL returned empty or null JSON output despite exit code 0.");
            return new WsctlProjectsResult(
                ProviderStatus.Error,
                "wsctl_cli_no_write",
                durationMs,
                [],
                Error: new ErrorDetail("WSCTL_INVALID_JSON", detail, "wsctl", 0));
        }

        try
        {
            using JsonDocument doc = JsonDocument.Parse(trimmed);
            JsonElement root = doc.RootElement;
            bool singleObject = false;
            var list = new List<ProjectSummary>();

            if (root.ValueKind == JsonValueKind.Array)
            {
                foreach (JsonElement item in root.EnumerateArray())
                {
                    if (!TryParseProject(item, _config.WorkspaceRoot, out ProjectSummary? proj, out string? schemaErr))
                    {
                        return new WsctlProjectsResult(
                            ProviderStatus.Error,
                            "wsctl_cli_no_write",
                            durationMs,
                            [],
                            Error: new ErrorDetail("WSCTL_INVALID_SCHEMA", schemaErr!, "wsctl", 0));
                    }
                    list.Add(proj!);
                }
            }
            else if (root.ValueKind == JsonValueKind.Object)
            {
                // Compensate cleanly for wsctl.ps1 F-08 single-element array unwrap.
                singleObject = true;
                if (!TryParseProject(root, _config.WorkspaceRoot, out ProjectSummary? proj, out string? schemaErr))
                {
                    return new WsctlProjectsResult(
                        ProviderStatus.Error,
                        "wsctl_cli_no_write",
                        durationMs,
                        [],
                        Error: new ErrorDetail("WSCTL_INVALID_SCHEMA", schemaErr!, "wsctl", 0));
                }
                list.Add(proj!);
            }
            else
            {
                return new WsctlProjectsResult(
                    ProviderStatus.Error,
                    "wsctl_cli_no_write",
                    durationMs,
                    [],
                    Error: new ErrorDetail("WSCTL_INVALID_JSON", $"Unexpected JSON root kind '{root.ValueKind}'.", "wsctl", 0));
            }

            return new WsctlProjectsResult(ProviderStatus.Available, "wsctl_cli_no_write", durationMs, list, singleObject);
        }
        catch (JsonException ex)
        {
            return new WsctlProjectsResult(
                ProviderStatus.Error,
                "wsctl_cli_no_write",
                durationMs,
                [],
                Error: new ErrorDetail("WSCTL_INVALID_JSON", $"Malformed WSCTL JSON: {ex.Message}", "wsctl", 0));
        }
    }

    public static (ProjectSummary? Project, ErrorDetail? Error) ResolveProject(
        IReadOnlyList<ProjectSummary> projects,
        string query)
    {
        if (string.IsNullOrWhiteSpace(query))
            return (null, new ErrorDetail("INVALID_ARGUMENT", "Project identifier cannot be empty.", "wsctl"));

        string q = query.Trim();
        ProjectSummary? exactId = projects.FirstOrDefault(p => string.Equals(p.Id, q, StringComparison.OrdinalIgnoreCase));
        if (exactId is not null)
            return (exactId, null);

        ProjectSummary? exactName = projects.FirstOrDefault(p => string.Equals(p.Name, q, StringComparison.OrdinalIgnoreCase));
        if (exactName is not null)
            return (exactName, null);

        var partial = projects
            .Where(p => p.Id.Contains(q, StringComparison.OrdinalIgnoreCase)
                     || p.Name.Contains(q, StringComparison.OrdinalIgnoreCase))
            .ToList();

        if (partial.Count == 1)
            return (partial[0], null);

        if (partial.Count > 1)
        {
            string candidates = string.Join(", ", partial.Take(5).Select(p => p.Id));
            return (null, new ErrorDetail(
                "PROJECT_AMBIGUOUS",
                $"Project query '{q}' matched multiple projects ({candidates}). Specify an exact ID.",
                "wsctl"));
        }

        return (null, new ErrorDetail("PROJECT_NOT_FOUND", $"Project '{q}' was not found in WSCTL registry.", "wsctl"));
    }

    public async Task<WsctlHealthSnapshot> GetWorkspaceHealthAsync(CancellationToken cancellationToken)
    {
        ProviderStatus infoStatus = ProviderStatus.Unavailable;
        string? workspaceRoot = null;
        int? projectsCount = null;
        ErrorDetail? infoError = null;

        if (!string.IsNullOrWhiteSpace(_config.PwshExecutable)
            && File.Exists(_config.PwshExecutable)
            && File.Exists(_config.WsctlScriptPath))
        {
            SubprocessResult res = await _runner.RunAsync(
                _config.PwshExecutable,
                ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", _config.WsctlScriptPath, "info", "-Json"],
                _config.WorkspaceRoot,
                _config.WsctlTimeout,
                cancellationToken).ConfigureAwait(false);

            if (res.TimedOut)
            {
                infoStatus = ProviderStatus.Timeout;
                infoError = new ErrorDetail("WSCTL_TIMEOUT", $"WSCTL info timed out after {res.DurationMs} ms.", "wsctl", Retryable: true);
            }
            else if (res.ExitCode == 0 && !string.IsNullOrWhiteSpace(res.Stdout))
            {
                try
                {
                    using JsonDocument doc = JsonDocument.Parse(res.Stdout);
                    if (doc.RootElement.ValueKind == JsonValueKind.Object)
                    {
                        workspaceRoot = GetOptionalString(doc.RootElement, "workspaceRoot");
                        projectsCount = GetOptionalInt(doc.RootElement, "projectsCount");
                        infoStatus = ProviderStatus.Available;
                    }
                    else
                    {
                        infoStatus = ProviderStatus.Error;
                        infoError = new ErrorDetail("WSCTL_INVALID_JSON", "wsctl info JSON root is not an object.", "wsctl");
                    }
                }
                catch (JsonException ex)
                {
                    infoStatus = ProviderStatus.Error;
                    infoError = new ErrorDetail("WSCTL_INVALID_JSON", ex.Message, "wsctl");
                }
            }
            else
            {
                infoStatus = ProviderStatus.Error;
                infoError = new ErrorDetail("WSCTL_NONZERO_EXIT", FirstNonEmpty(res.Stderr, "wsctl info failed."), "wsctl", res.ExitCode);
            }
        }
        else
        {
            infoError = new ErrorDetail("WSCTL_UNAVAILABLE", "WSCTL script or pwsh executable unavailable.", "wsctl");
        }

        string docArtifact = Path.Combine(_config.WorkspaceRoot, "Shared", "artifacts", "doctor-latest.json");
        string docStatus = "UNAVAILABLE";
        string? tsRaw = null;
        double? ageSec = null;
        bool stale = true;
        int? okCount = null;
        int? totalChecks = null;

        if (File.Exists(docArtifact))
        {
            try
            {
                string raw = await File.ReadAllTextAsync(docArtifact, cancellationToken).ConfigureAwait(false);
                using JsonDocument ddoc = JsonDocument.Parse(raw);
                JsonElement root = ddoc.RootElement;
                docStatus = GetOptionalString(root, "status") ?? "UNKNOWN";
                tsRaw = GetOptionalString(root, "timestamp");
                if (tsRaw is not null && DateTimeOffset.TryParse(tsRaw, CultureInfo.InvariantCulture, DateTimeStyles.None, out DateTimeOffset parsedTs))
                {
                    ageSec = Math.Round(Math.Max(0, (DateTimeOffset.UtcNow - parsedTs.ToUniversalTime()).TotalSeconds), 1);
                    stale = ageSec > 3600.0;
                }
                if (root.TryGetProperty("summary", out JsonElement sum) && sum.ValueKind == JsonValueKind.Object)
                {
                    okCount = GetOptionalInt(sum, "okCount");
                    totalChecks = GetOptionalInt(sum, "totalChecks");
                }
            }
            catch
            {
                docStatus = "INVALID_ARTIFACT";
                stale = true;
            }
        }

        return new WsctlHealthSnapshot(
            InfoStatus: infoStatus,
            WorkspaceRoot: workspaceRoot,
            RegisteredProjectsCount: projectsCount,
            LastAuditTimestamp: tsRaw,
            DoctorSnapshotAgeSeconds: ageSec,
            DoctorSnapshotStale: stale,
            DoctorSnapshotStatus: docStatus,
            DoctorOkCount: okCount,
            DoctorTotalChecks: totalChecks,
            LiveDoctorPolicyNote: "Live 'wsctl doctor' skipped in Phase 1 (lacks -NoSave and mutates hardlinked Shared\\artifacts\\doctor-latest.json).",
            Error: infoError);
    }

    private static bool TryParseProject(JsonElement item, string workspaceRoot, out ProjectSummary? project, out string? error)
    {
        project = null;
        error = null;
        if (item.ValueKind != JsonValueKind.Object)
        {
            error = "Project entry is not a JSON object.";
            return false;
        }

        string? id = GetOptionalString(item, "id");
        string? name = GetOptionalString(item, "name");
        string? relPath = GetOptionalString(item, "path");
        if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(relPath))
        {
            error = "Project entry is missing required 'id', 'name', or 'path' string fields.";
            return false;
        }

        string fullPath;
        try
        {
            fullPath = Path.GetFullPath(Path.IsPathRooted(relPath) ? relPath : Path.Combine(workspaceRoot, relPath));
        }
        catch
        {
            fullPath = Path.Combine(workspaceRoot, relPath);
        }

        bool accessible = Directory.Exists(fullPath);

        var actions = new List<ProjectActionSummary>();
        if (item.TryGetProperty("commands", out JsonElement cmds) && cmds.ValueKind == JsonValueKind.Object)
        {
            foreach (JsonProperty prop in cmds.EnumerateObject())
            {
                if (prop.Value.ValueKind == JsonValueKind.Object)
                {
                    actions.Add(new ProjectActionSummary(
                        Name: prop.Name,
                        Risk: GetOptionalString(prop.Value, "risk") ?? "safe",
                        Executable: GetOptionalString(prop.Value, "executable"),
                        Description: GetOptionalString(prop.Value, "description"),
                        Structured: true));
                }
                else if (prop.Value.ValueKind == JsonValueKind.String)
                {
                    actions.Add(new ProjectActionSummary(
                        Name: prop.Name,
                        Risk: "unspecified",
                        Executable: null,
                        Description: null,
                        Structured: false));
                }
            }
        }

        project = new ProjectSummary(
            Id: id,
            Name: name,
            RelativePath: relPath,
            FullPath: fullPath,
            Category: GetOptionalString(item, "category") ?? "unknown",
            Status: GetOptionalString(item, "status") ?? "unknown",
            Accessible: accessible,
            Environment: GetOptionalString(item, "environment") ?? "unknown",
            Gpu: GetOptionalString(item, "gpu") ?? "unknown",
            Git: item.TryGetProperty("git", out JsonElement gitEl) && gitEl.ValueKind == JsonValueKind.True,
            Actions: actions,
            Languages: ReadStringArray(item, "languages"),
            Tags: ReadStringArray(item, "tags"),
            Documentation: GetOptionalString(item, "documentation"));
        return true;
    }

    private static IReadOnlyList<string>? ReadStringArray(JsonElement obj, string prop)
    {
        if (!obj.TryGetProperty(prop, out JsonElement el) || el.ValueKind != JsonValueKind.Array)
            return null;
        var list = new List<string>();
        foreach (JsonElement x in el.EnumerateArray())
        {
            if (x.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(x.GetString()))
                list.Add(x.GetString()!);
        }
        return list;
    }

    private static string? GetOptionalString(JsonElement obj, string prop)
        => obj.TryGetProperty(prop, out JsonElement el) && el.ValueKind == JsonValueKind.String ? el.GetString() : null;

    private static int? GetOptionalInt(JsonElement obj, string prop)
        => obj.TryGetProperty(prop, out JsonElement el) && el.ValueKind == JsonValueKind.Number && el.TryGetInt32(out int v) ? v : null;

    private static string FirstNonEmpty(string primary, string fallback)
        => string.IsNullOrWhiteSpace(primary) ? fallback : primary.Trim();
}
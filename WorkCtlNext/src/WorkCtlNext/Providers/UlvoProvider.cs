using System.Text.Json;
using WorkCtlNext.Core;

namespace WorkCtlNext.Providers;

/// <summary>
/// First-class read-only ULVO provider invoking only source-verified zero-write ULVO CLI commands
/// (status, ls, inspect, inventory, and explicit on-demand env status).
/// Never invokes full vault audits, process scans, gpu/doctor/vault loggers, or mutating commands.
/// </summary>
public sealed class UlvoProvider
{
    private readonly IProcessRunner _runner;
    private readonly WorkctlPathsConfig _config;

    public UlvoProvider(IProcessRunner runner, WorkctlPathsConfig config)
    {
        _runner = runner ?? throw new ArgumentNullException(nameof(runner));
        _config = config ?? throw new ArgumentNullException(nameof(config));
    }

    public async Task<UlvoStatusSummary> GetStatusAsync(CancellationToken cancellationToken)
    {
        (SubprocessResult? res, ErrorDetail? preErr) = await RunUlvoAsync(["status", "--json"], null, _config.UlvoFastTimeout, cancellationToken).ConfigureAwait(false);
        if (preErr is not null)
            return new UlvoStatusSummary(ProviderStatus.Unavailable, null, false, 0, null, null, 0, preErr);

        ErrorDetail? execErr = CheckFailure(res!, "ULVO status");
        if (execErr is not null)
            return new UlvoStatusSummary(ToFailureStatus(res!), null, false, 0, null, null, res!.DurationMs, execErr);

        try
        {
            using JsonDocument doc = JsonDocument.Parse(res!.Stdout);
            JsonElement root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                return new UlvoStatusSummary(ProviderStatus.Error, null, false, 0, null, null, res.DurationMs, new ErrorDetail("ULVO_INVALID_JSON", "ulvo status root is not an object.", "ulvo"));

            string? cur = GetString(root, "current_project");
            return new UlvoStatusSummary(
                Status: ProviderStatus.Available,
                Version: GetString(root, "version"),
                VaultExists: GetBool(root, "vault_exists"),
                RegisteredProjects: GetInt(root, "registered_projects"),
                CurrentProject: cur is null ? null : PathNormalizer.StripVerbatimPrefix(cur),
                ProjectDiagnostic: GetString(root, "project_diagnostic"),
                DurationMs: res.DurationMs);
        }
        catch (JsonException ex)
        {
            return new UlvoStatusSummary(ProviderStatus.Error, null, false, 0, null, null, res!.DurationMs, new ErrorDetail("ULVO_INVALID_JSON", ex.Message, "ulvo"));
        }
    }

    public async Task<(ProviderStatus Status, IReadOnlyList<UlvoListedProject> Projects, long DurationMs, ErrorDetail? Error)> ListProjectsAsync(CancellationToken cancellationToken)
    {
        (SubprocessResult? res, ErrorDetail? preErr) = await RunUlvoAsync(["ls", "--json"], null, _config.UlvoFastTimeout, cancellationToken).ConfigureAwait(false);
        if (preErr is not null)
            return (ProviderStatus.Unavailable, [], 0, preErr);

        ErrorDetail? execErr = CheckFailure(res!, "ULVO ls");
        if (execErr is not null)
            return (ToFailureStatus(res!), [], res!.DurationMs, execErr);

        try
        {
            using JsonDocument doc = JsonDocument.Parse(res!.Stdout);
            if (doc.RootElement.ValueKind != JsonValueKind.Array)
                return (ProviderStatus.Error, [], res.DurationMs, new ErrorDetail("ULVO_INVALID_JSON", "ulvo ls root is not an array.", "ulvo"));

            var list = new List<UlvoListedProject>();
            foreach (JsonElement el in doc.RootElement.EnumerateArray())
            {
                if (el.ValueKind != JsonValueKind.Object) continue;
                string rawPath = GetString(el, "canonical_path") ?? string.Empty;
                list.Add(new UlvoListedProject(
                    Id: GetString(el, "id") ?? string.Empty,
                    Name: GetString(el, "name") ?? string.Empty,
                    CanonicalPath: PathNormalizer.StripVerbatimPrefix(rawPath),
                    Ecosystem: GetString(el, "ecosystem") ?? "unknown",
                    RegistrationState: GetString(el, "registration_state") ?? "unknown",
                    HasConnector: GetBool(el, "has_connector"),
                    Classification: GetString(el, "classification") ?? "standard",
                    Manifests: ReadStrings(el, "manifests"),
                    EnvHealthChecked: false,
                    EnvHealthState: "not_checked_on_ls"));
            }

            return (ProviderStatus.Available, list, res.DurationMs, null);
        }
        catch (JsonException ex)
        {
            return (ProviderStatus.Error, [], res!.DurationMs, new ErrorDetail("ULVO_INVALID_JSON", ex.Message, "ulvo"));
        }
    }

    public async Task<UlvoProjectInspection> InspectProjectAsync(
        string projectPath,
        bool includeEnvStatus,
        CancellationToken cancellationToken)
    {
        string normalizedPath = PathNormalizer.StripVerbatimPrefix(projectPath);
        (SubprocessResult? res, ErrorDetail? preErr) = await RunUlvoAsync(["inspect", normalizedPath, "--json"], null, _config.UlvoFastTimeout, cancellationToken).ConfigureAwait(false);
        if (preErr is not null)
            return new UlvoProjectInspection(ProviderStatus.Unavailable, normalizedPath, false, null, null, null, null, null, null, null, null, [], [], false, null, 0, preErr);

        ErrorDetail? execErr = CheckFailure(res!, "ULVO inspect");
        if (execErr is not null)
            return new UlvoProjectInspection(ToFailureStatus(res!), normalizedPath, false, null, null, null, null, null, null, null, null, [], [], false, null, res!.DurationMs, execErr);

        long totalMs = res!.DurationMs;
        try
        {
            using JsonDocument doc = JsonDocument.Parse(res.Stdout);
            JsonElement root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                return new UlvoProjectInspection(ProviderStatus.Error, normalizedPath, false, null, null, null, null, null, null, null, null, [], [], false, null, totalMs, new ErrorDetail("ULVO_INVALID_JSON", "ulvo inspect root is not an object.", "ulvo"));

            string outPath = PathNormalizer.StripVerbatimPrefix(GetString(root, "path") ?? normalizedPath);
            IReadOnlyList<string> nativeManifests = ReadStrings(root, "native_manifests");
            IReadOnlyList<string> diagnostics = ReadStrings(root, "diagnostics");

            bool hasConnector = false;
            string? compliance = null;
            if (root.TryGetProperty("connector", out JsonElement conn) && conn.ValueKind == JsonValueKind.Object)
            {
                compliance = GetString(conn, "compliance_verdict");
                hasConnector = !string.Equals(compliance, "missing_manifest", StringComparison.OrdinalIgnoreCase);
            }

            string? manifestName = null;
            string? pyVer = null;
            string? pyMgr = null;
            string? envMode = null;
            bool? gpuReq = null;
            string? gpuFw = null;
            string? gpuCuda = null;

            if (root.TryGetProperty("ulvo_manifest", out JsonElement um) && um.ValueKind == JsonValueKind.Object)
            {
                hasConnector = true;
                manifestName = GetString(um, "name");
                if (um.TryGetProperty("runtimes", out JsonElement rt) && rt.ValueKind == JsonValueKind.Object)
                    pyVer = GetString(rt, "python");
                if (um.TryGetProperty("python", out JsonElement py) && py.ValueKind == JsonValueKind.Object)
                    pyMgr = GetString(py, "manager");
                if (um.TryGetProperty("environment", out JsonElement envObj) && envObj.ValueKind == JsonValueKind.Object)
                    envMode = GetString(envObj, "mode");
                if (um.TryGetProperty("gpu", out JsonElement gpuObj) && gpuObj.ValueKind == JsonValueKind.Object)
                {
                    if (gpuObj.TryGetProperty("required", out JsonElement reqEl) && reqEl.ValueKind is JsonValueKind.True or JsonValueKind.False)
                        gpuReq = reqEl.GetBoolean();
                    gpuFw = GetString(gpuObj, "framework");
                    gpuCuda = GetString(gpuObj, "cuda_version");
                }
            }

            UlvoEnvStatusSummary? envSummary = null;
            bool envChecked = false;
            ErrorDetail? envErr = null;
            if (includeEnvStatus)
            {
                envChecked = true;
                (envSummary, long envMs, envErr) = await GetEnvStatusAsync(normalizedPath, cancellationToken).ConfigureAwait(false);
                totalMs += envMs;
            }

            ProviderStatus finalStatus = envErr is not null ? ProviderStatus.Degraded : ProviderStatus.Available;
            return new UlvoProjectInspection(
                Status: finalStatus,
                ProjectPath: outPath,
                HasConnector: hasConnector,
                ManifestName: manifestName,
                ComplianceVerdict: compliance,
                PythonVersion: pyVer,
                PythonManager: pyMgr,
                EnvironmentMode: envMode,
                GpuRequired: gpuReq,
                GpuFramework: gpuFw,
                GpuCudaVersion: gpuCuda,
                NativeManifests: nativeManifests,
                Diagnostics: diagnostics,
                EnvStatusChecked: envChecked,
                EnvStatus: envSummary,
                DurationMs: totalMs,
                Error: envErr);
        }
        catch (JsonException ex)
        {
            return new UlvoProjectInspection(ProviderStatus.Error, normalizedPath, false, null, null, null, null, null, null, null, null, [], [], false, null, totalMs, new ErrorDetail("ULVO_INVALID_JSON", ex.Message, "ulvo"));
        }
    }

    public async Task<(UlvoEnvStatusSummary? Summary, long DurationMs, ErrorDetail? Error)> GetEnvStatusAsync(
        string projectPath,
        CancellationToken cancellationToken)
    {
        string normalizedPath = PathNormalizer.StripVerbatimPrefix(projectPath);
        (SubprocessResult? res, ErrorDetail? preErr) = await RunUlvoAsync(["env", "status", normalizedPath, "--json"], null, _config.UlvoEnvTimeout, cancellationToken).ConfigureAwait(false);
        if (preErr is not null)
            return (null, 0, preErr);

        ErrorDetail? execErr = CheckFailure(res!, "ULVO env status");
        if (execErr is not null)
            return (null, res!.DurationMs, execErr);

        try
        {
            using JsonDocument doc = JsonDocument.Parse(res!.Stdout);
            JsonElement root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                return (null, res.DurationMs, new ErrorDetail("ULVO_INVALID_JSON", "ulvo env status root is not an object.", "ulvo"));

            var summary = new UlvoEnvStatusSummary(
                EnvironmentId: GetString(root, "environment_id"),
                State: GetString(root, "state"),
                IsMaterialized: GetBool(root, "is_materialized"),
                IsQuiescent: GetBool(root, "is_quiescent"),
                CanReclaim: GetBool(root, "can_reclaim"),
                PythonVersion: GetString(root, "python_version"));
            return (summary, res.DurationMs, null);
        }
        catch (JsonException ex)
        {
            return (null, res!.DurationMs, new ErrorDetail("ULVO_INVALID_JSON", ex.Message, "ulvo"));
        }
    }

    private async Task<(SubprocessResult? Result, ErrorDetail? PreCheckError)> RunUlvoAsync(
        IReadOnlyList<string> args,
        string? workingDir,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        bool exists = !string.IsNullOrWhiteSpace(_config.UlvoExecutable)
            && (Path.IsPathRooted(_config.UlvoExecutable)
                ? File.Exists(_config.UlvoExecutable)
                : ProcessRunner.FindExecutableOnPath(_config.UlvoExecutable) is not null);

        if (!exists)
        {
            return (null, new ErrorDetail("ULVO_UNAVAILABLE", $"ULVO executable '{_config.UlvoExecutable}' was not found.", "ulvo"));
        }

        SubprocessResult res = await _runner.RunAsync(_config.UlvoExecutable, args, workingDir, timeout, cancellationToken).ConfigureAwait(false);
        return (res, null);
    }

    private static ErrorDetail? CheckFailure(SubprocessResult res, string opName)
    {
        if (res.StartFailed)
            return new ErrorDetail("ULVO_START_FAILED", res.StartError ?? $"{opName} failed to start.", "ulvo");
        if (res.TimedOut)
            return new ErrorDetail("ULVO_TIMEOUT", $"{opName} timed out after {res.DurationMs} ms.", "ulvo", Retryable: true);
        if (res.Cancelled)
            return new ErrorDetail("ULVO_CANCELLED", $"{opName} was cancelled.", "ulvo");
        if (res.ExitCode != 0)
        {
            string msg = TryExtractUlvoJsonError(res.Stdout) ?? (string.IsNullOrWhiteSpace(res.Stderr) ? $"{opName} exited with code {res.ExitCode}." : res.Stderr.Trim());
            return new ErrorDetail("ULVO_ERROR", msg, "ulvo", res.ExitCode);
        }
        if (string.IsNullOrWhiteSpace(res.Stdout))
            return new ErrorDetail("ULVO_EMPTY_OUTPUT", $"{opName} returned empty output.", "ulvo", res.ExitCode);

        return null;
    }

    private static ProviderStatus ToFailureStatus(SubprocessResult res)
        => res.StartFailed ? ProviderStatus.Unavailable
         : res.TimedOut ? ProviderStatus.Timeout
         : ProviderStatus.Error;

    private static string? TryExtractUlvoJsonError(string stdout)
    {
        if (string.IsNullOrWhiteSpace(stdout)) return null;
        try
        {
            using JsonDocument doc = JsonDocument.Parse(stdout);
            if (doc.RootElement.ValueKind == JsonValueKind.Object && doc.RootElement.TryGetProperty("error", out JsonElement err))
                return err.GetString();
        }
        catch { /* Ignore */ }
        return null;
    }

    private static string? GetString(JsonElement obj, string prop)
        => obj.TryGetProperty(prop, out JsonElement el) && el.ValueKind == JsonValueKind.String ? el.GetString() : null;

    private static bool GetBool(JsonElement obj, string prop)
        => obj.TryGetProperty(prop, out JsonElement el) && el.ValueKind == JsonValueKind.True;

    private static int GetInt(JsonElement obj, string prop)
        => obj.TryGetProperty(prop, out JsonElement el) && el.ValueKind == JsonValueKind.Number && el.TryGetInt32(out int v) ? v : 0;

    private static IReadOnlyList<string> ReadStrings(JsonElement obj, string prop)
    {
        if (!obj.TryGetProperty(prop, out JsonElement el) || el.ValueKind != JsonValueKind.Array)
            return [];
        var list = new List<string>();
        foreach (JsonElement x in el.EnumerateArray())
        {
            if (x.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(x.GetString()))
                list.Add(x.GetString()!);
        }
        return list;
    }
}
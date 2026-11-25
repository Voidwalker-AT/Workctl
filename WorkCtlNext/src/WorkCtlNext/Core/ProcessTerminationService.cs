using System.Diagnostics;
using WorkCtlNext.Providers;

namespace WorkCtlNext.Core;

public sealed class ProcessTerminationService
{
    private readonly WindowsTelemetryProvider _telemetry;

    public ProcessTerminationService(WindowsTelemetryProvider telemetry)
    {
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
    }

    public ProcessImpactAssessment AnalyzeImpact(
        int pid,
        long expectedCreationUtcTicks = 0,
        string? expectedName = null,
        string? expectedExecutablePath = null)
    {
        var fallbackIdentity = new ProcessIdentityToken(
            pid,
            expectedCreationUtcTicks,
            expectedName ?? $"PID {pid}",
            expectedExecutablePath);

        ProcessDetailedInspection? detail = _telemetry.InspectProcess(pid);
        if (detail is null)
        {
            return new ProcessImpactAssessment(
                ExpectedIdentity: fallbackIdentity,
                ProcessExists: false,
                PidReused: false,
                CanTerminate: false,
                BlockReason: $"Process PID {pid} is no longer running.",
                SupportsGracefulClose: false,
                GracefulExplanation: "Process already exited.",
                VerifiedRelationships: [$"PID {pid}: not found in live process snapshot."],
                PossibleConsequences: Array.Empty<string>(),
                UnknownEffects: Array.Empty<string>(),
                Detail: null);
        }

        ProcessEntrySnapshot live = detail.Process;
        bool timestampMismatch = expectedCreationUtcTicks != 0
            && live.CreationTimeUtcTicks != 0
            && live.CreationTimeUtcTicks != expectedCreationUtcTicks;
        bool exeMismatch = !string.IsNullOrWhiteSpace(expectedExecutablePath)
            && !string.IsNullOrWhiteSpace(live.ExecutablePath)
            && !string.Equals(expectedExecutablePath, live.ExecutablePath, StringComparison.OrdinalIgnoreCase);

        if (timestampMismatch || exeMismatch)
        {
            return new ProcessImpactAssessment(
                ExpectedIdentity: fallbackIdentity,
                ProcessExists: true,
                PidReused: true,
                CanTerminate: false,
                BlockReason: $"PID reuse detected on PID {pid}: live process '{live.Name}' (created {live.CreationTimeUtcTicks}) does not match selected identity '{fallbackIdentity.Name}'. Action aborted.",
                SupportsGracefulClose: false,
                GracefulExplanation: "Aborted due to PID reuse.",
                VerifiedRelationships: [$"Selected PID {pid} was reassigned by Windows to '{live.Name}'."],
                PossibleConsequences: ["Aborting prevents terminating an unrelated replacement process."],
                UnknownEffects: Array.Empty<string>(),
                Detail: detail);
        }

        var identity = new ProcessIdentityToken(live.Pid, live.CreationTimeUtcTicks, live.Name, live.ExecutablePath);

        var verified = new List<string>
        {
            $"Identity: {live.Name} (PID {live.Pid}, owner: {detail.OwnerStatus})",
            $"Started (UTC): {(live.CreationTimeUtcTicks > 0 ? new DateTime(live.CreationTimeUtcTicks, DateTimeKind.Utc).ToString("yyyy-MM-dd HH:mm:ss") : "unavailable")}"
        };
        if (!string.IsNullOrWhiteSpace(live.ExecutablePath))
            verified.Add($"Executable: {live.ExecutablePath}");
        else
            verified.Add("Executable: [unavailable / access denied]");

        if (detail.VerifiedParentPid.HasValue)
            verified.Add($"Parent: {detail.VerifiedParentName} (PID {detail.VerifiedParentPid.Value})");
        else if (detail.ParentExitedOrReused)
            verified.Add($"Parent PID {live.ParentPid}: exited or PID reused (no active parent link)");

        if (detail.VerifiedChildren.Count > 0)
            verified.Add($"Direct child processes ({detail.VerifiedChildren.Count}): {string.Join(", ", detail.VerifiedChildren.Take(4).Select(c => $"{c.Name}({c.Pid})"))}{(detail.VerifiedChildren.Count > 4 ? ", ..." : "")}");
        else
            verified.Add("Direct child processes: none observed");

        if (detail.AssociatedServices.Count > 0)
            verified.Add($"Hosted Windows services: {string.Join(", ", detail.AssociatedServices.Select(s => $"{s.ServiceName} [{s.State}]"))}");
        else
            verified.Add("Hosted Windows services: none detected");

        verified.Add($"WorkCtl owned: {(detail.IsWorkCtlOwned ? "Yes (launched by WorkCtl)" : "No (external user/system process)")}");

        var possible = new List<string>
        {
            $"Terminating '{live.Name}' discards unsaved in-memory state held by PID {live.Pid}."
        };
        if (detail.VerifiedChildren.Count > 0)
            possible.Add($"{detail.VerifiedChildren.Count} direct child process(es) are NOT auto-terminated and may become orphaned or fail when IPC closes.");
        if (!detail.SupportsGracefulClose)
            possible.Add("This process has no responsive top-level window for WM_CLOSE graceful shutdown; force termination is abrupt.");

        var unknown = new List<string>
        {
            "Open file handles, database transactions, temporary lock files, GPU allocations, or external IPC clients inside the target cannot be exhaustively predicted.",
            "External restart watchdogs or parent supervisors may respawn this workload."
        };

        string gracefulMsg = detail.SupportsGracefulClose
            ? "Supported: owns a visible main window (CloseMainWindow / WM_CLOSE attempted first without force)."
            : "Unavailable: console or background processes without a message-loop main window do not support universal graceful CloseMainWindow.";

        return new ProcessImpactAssessment(
            ExpectedIdentity: identity,
            ProcessExists: true,
            PidReused: false,
            CanTerminate: !detail.IsProtected,
            BlockReason: detail.BlockReason,
            SupportsGracefulClose: detail.SupportsGracefulClose,
            GracefulExplanation: gracefulMsg,
            VerifiedRelationships: verified,
            PossibleConsequences: possible,
            UnknownEffects: unknown,
            Detail: detail);
    }

    public async Task<ProcessTerminationResult> TryGracefulCloseAsync(
        ProcessIdentityToken expectedIdentity,
        CancellationToken cancellationToken)
    {
        ProcessImpactAssessment recheck = AnalyzeImpact(
            expectedIdentity.Pid,
            expectedIdentity.CreationTimeUtcTicks,
            expectedIdentity.Name,
            expectedIdentity.ExecutablePath);

        if (!recheck.ProcessExists)
            return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "graceful", recheck.BlockReason ?? "Process already exited.", "PROCESS_EXITED");
        if (recheck.PidReused)
            return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "graceful", recheck.BlockReason!, "PID_REUSED");
        if (!recheck.CanTerminate)
            return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "graceful", recheck.BlockReason ?? "Protected process.", "PROTECTED_PROCESS");
        if (!recheck.SupportsGracefulClose)
            return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "graceful", recheck.GracefulExplanation, "GRACEFUL_UNSUPPORTED");

        try
        {
            using Process proc = Process.GetProcessById(expectedIdentity.Pid);
            if (!proc.CloseMainWindow())
            {
                return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "graceful",
                    "Target declined or has no main message loop for CloseMainWindow.", "GRACEFUL_DECLINED");
            }

            using var waitCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            waitCts.CancelAfter(TimeSpan.FromMilliseconds(900));
            try
            {
                await proc.WaitForExitAsync(waitCts.Token).ConfigureAwait(false);
                int code = proc.ExitCode;
                return new ProcessTerminationResult(true, expectedIdentity.Pid, expectedIdentity.Name, "graceful",
                    $"Process {expectedIdentity.Name} (PID {expectedIdentity.Pid}) closed gracefully (exit {code}).", null, code);
            }
            catch (OperationCanceledException)
            {
                return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "graceful",
                    $"Sent graceful CloseMainWindow to PID {expectedIdentity.Pid}; still running (may have unsaved prompt or ignored close).", "GRACEFUL_TIMEOUT");
            }
        }
        catch (ArgumentException)
        {
            return new ProcessTerminationResult(true, expectedIdentity.Pid, expectedIdentity.Name, "graceful",
                $"Process PID {expectedIdentity.Pid} exited during graceful shutdown.", null, 0);
        }
        catch (Exception ex)
        {
            return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "graceful",
                ex.Message, "GRACEFUL_ERROR");
        }
    }

    public ProcessTerminationResult ForceTerminate(
        ProcessIdentityToken expectedIdentity,
        bool secondConfirmationExplicit)
    {
        if (!secondConfirmationExplicit)
        {
            return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "force",
                "Force termination requires explicit second confirmation.", "SECOND_CONFIRMATION_REQUIRED");
        }

        ProcessImpactAssessment recheck = AnalyzeImpact(
            expectedIdentity.Pid,
            expectedIdentity.CreationTimeUtcTicks,
            expectedIdentity.Name,
            expectedIdentity.ExecutablePath);

        if (!recheck.ProcessExists)
            return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "force", recheck.BlockReason ?? "Process already exited.", "PROCESS_EXITED");
        if (recheck.PidReused)
            return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "force", recheck.BlockReason!, "PID_REUSED");
        if (!recheck.CanTerminate)
            return new ProcessTerminationResult(false, expectedIdentity.Pid, expectedIdentity.Name, "force", recheck.BlockReason ?? "Protected process.", "PROTECTED_PROCESS");

        return Win32ProcessInterop.TerminateVerifiedPid(recheck.ExpectedIdentity);
    }
}

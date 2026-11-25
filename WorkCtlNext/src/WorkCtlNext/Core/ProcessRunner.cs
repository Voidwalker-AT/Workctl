using System.Diagnostics;
using System.Text;

namespace WorkCtlNext.Core;

public sealed record SubprocessResult(
    int ExitCode,
    string Stdout,
    string Stderr,
    long DurationMs,
    bool TimedOut,
    bool Cancelled,
    bool StartFailed,
    string? StartError = null);

public interface IProcessRunner
{
    Task<SubprocessResult> RunAsync(
        string executable,
        IReadOnlyList<string> arguments,
        string? workingDirectory,
        TimeSpan timeout,
        CancellationToken cancellationToken);
}

/// <summary>
/// Safe read-only subprocess runner: explicit executable + ArgumentList (no shell interpolation),
/// concurrent stdout/stderr draining, bounded timeout, and deterministic process-tree cleanup on timeout/cancel.
/// </summary>
public sealed class ProcessRunner : IProcessRunner
{
    public async Task<SubprocessResult> RunAsync(
        string executable,
        IReadOnlyList<string> arguments,
        string? workingDirectory,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(executable))
        {
            return new SubprocessResult(-1, string.Empty, string.Empty, 0, false, false, true, "Executable path cannot be empty.");
        }

        var sw = Stopwatch.StartNew();
        using var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = string.IsNullOrWhiteSpace(workingDirectory) || !Directory.Exists(workingDirectory)
                ? Environment.CurrentDirectory
                : workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };

        foreach (string arg in arguments)
        {
            process.StartInfo.ArgumentList.Add(arg);
        }

        try
        {
            if (!process.Start())
            {
                return new SubprocessResult(-1, string.Empty, string.Empty, sw.ElapsedMilliseconds, false, false, true, $"Failed to start '{executable}'.");
            }
        }
        catch (Exception ex)
        {
            return new SubprocessResult(-1, string.Empty, string.Empty, sw.ElapsedMilliseconds, false, false, true, ex.Message);
        }

        try
        {
            process.StandardInput.Close();
        }
        catch
        {
            // Ignore if child closed stdin immediately.
        }

        Task<string> stdoutTask = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
        Task<string> stderrTask = process.StandardError.ReadToEndAsync(CancellationToken.None);

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(timeout);

        bool timedOut = false;
        bool cancelled = false;

        try
        {
            await process.WaitForExitAsync(timeoutCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            timedOut = !cancellationToken.IsCancellationRequested;
            cancelled = cancellationToken.IsCancellationRequested;
            TryKillProcessTree(process);
        }

        string stdout = await SafeReadTaskAsync(stdoutTask).ConfigureAwait(false);
        string stderr = await SafeReadTaskAsync(stderrTask).ConfigureAwait(false);
        int exitCode = timedOut || cancelled ? -1 : SafeExitCode(process);
        sw.Stop();

        return new SubprocessResult(exitCode, stdout, stderr, sw.ElapsedMilliseconds, timedOut, cancelled, false);
    }

    public static string? FindExecutableOnPath(string commandName, IEnumerable<string>? fallbackFullPaths = null)
    {
        if (fallbackFullPaths is not null)
        {
            foreach (string candidate in fallbackFullPaths)
            {
                if (!string.IsNullOrWhiteSpace(candidate) && File.Exists(candidate))
                    return candidate;
            }
        }

        if (Path.IsPathRooted(commandName) && File.Exists(commandName))
            return commandName;

        string pathVar = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        string pathExt = Environment.GetEnvironmentVariable("PATHEXT") ?? ".COM;.EXE;.BAT;.CMD";
        string[] exts = pathExt.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        bool hasExt = !string.IsNullOrEmpty(Path.GetExtension(commandName));

        foreach (string dir in pathVar.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (hasExt)
            {
                string direct = Path.Combine(dir, commandName);
                if (File.Exists(direct))
                    return direct;
                continue;
            }

            foreach (string ext in exts)
            {
                string candidate = Path.Combine(dir, commandName + ext.ToLowerInvariant());
                if (File.Exists(candidate))
                    return candidate;
                string upper = Path.Combine(dir, commandName + ext.ToUpperInvariant());
                if (File.Exists(upper))
                    return upper;
            }
        }

        return null;
    }

    private static void TryKillProcessTree(Process process)
    {
        try
        {
            if (!process.HasExited)
                process.Kill(entireProcessTree: true);
        }
        catch
        {
            // Ignore race if child exited cleanly right before kill.
        }
    }

    private static async Task<string> SafeReadTaskAsync(Task<string> task)
    {
        try
        {
            return await task.WaitAsync(TimeSpan.FromMilliseconds(500)).ConfigureAwait(false);
        }
        catch
        {
            return string.Empty;
        }
    }

    private static int SafeExitCode(Process process)
    {
        try { return process.ExitCode; }
        catch { return -1; }
    }
}
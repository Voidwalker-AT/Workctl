using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using WorkCtlNext.Core;
using WorkCtlNext.Terminal;

namespace WorkCtlNext.Providers;

/// <summary>
/// Bounded read-only Windows machine provider using fast native Win32/BCL/Registry APIs.
/// Avoids slow startup CIM/WMI scans and never requires administrator privileges.
/// </summary>
public sealed class WindowsMachineProvider
{
    public MachineSnapshot GetSnapshot()
    {
        var errors = new List<string>();

        string cpuName = ReadCpuName(out string? cpuError);
        if (cpuError is not null)
            errors.Add($"cpu: {cpuError}");

        double totalRamMb = 0;
        double availableRamMb = 0;
        uint memoryLoadPercent = 0;
        string? memoryError = null;

        if (OperatingSystem.IsWindows())
        {
            if (ConsoleInterop.TryGetMemoryStatus(out var mem, out int win32Err))
            {
                totalRamMb = Math.Round(mem.ullTotalPhys / (1024.0 * 1024.0), 1);
                availableRamMb = Math.Round(mem.ullAvailPhys / (1024.0 * 1024.0), 1);
                memoryLoadPercent = mem.dwMemoryLoad;
            }
            else
            {
                memoryError = $"GlobalMemoryStatusEx failed (Win32={win32Err})";
                errors.Add($"memory: {memoryError}");
            }
        }
        else
        {
            memoryError = "Win32 memory API unavailable on non-Windows host.";
            errors.Add($"memory: {memoryError}");
        }

        var disks = ReadFixedDisks(errors);
        int processCount = ReadProcessCount(errors);

        string status = errors.Count == 0 ? "ok" : "degraded";
        return new MachineSnapshot(
            MachineName: Environment.MachineName,
            OsVersion: $"{RuntimeInformation.OSDescription.Trim()} ({RuntimeInformation.OSArchitecture})",
            CpuName: cpuName,
            LogicalCores: Environment.ProcessorCount,
            TotalRamMb: totalRamMb,
            AvailableRamMb: availableRamMb,
            MemoryLoadPercent: memoryLoadPercent,
            ProcessCount: processCount,
            FixedDisks: disks,
            Status: status,
            Errors: errors,
            CpuError: cpuError,
            MemoryError: memoryError);
    }

    private static string ReadCpuName(out string? error)
    {
        error = null;
        if (!OperatingSystem.IsWindows())
        {
            error = "Registry CPU probe requires Windows.";
            return "Unavailable";
        }

        try
        {
            object? val = Registry.GetValue(
                @"HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\CentralProcessor\0",
                "ProcessorNameString",
                null);
            if (val is string s && !string.IsNullOrWhiteSpace(s))
                return s.Trim();

            error = "ProcessorNameString registry value missing or empty.";
            return "Unknown CPU";
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return "Unavailable";
        }
    }

    private static IReadOnlyList<FixedDiskSummary> ReadFixedDisks(List<string> errors)
    {
        var result = new List<FixedDiskSummary>();
        try
        {
            foreach (DriveInfo drive in DriveInfo.GetDrives())
            {
                if (drive.DriveType != DriveType.Fixed)
                    continue;

                try
                {
                    if (!drive.IsReady)
                    {
                        result.Add(new FixedDiskSummary(drive.Name, null, null, 0, 0, false, "Drive not ready"));
                        continue;
                    }

                    double totalGb = Math.Round(drive.TotalSize / (1024.0 * 1024.0 * 1024.0), 2);
                    double freeGb = Math.Round(drive.AvailableFreeSpace / (1024.0 * 1024.0 * 1024.0), 2);
                    result.Add(new FixedDiskSummary(
                        Name: drive.Name.TrimEnd('\\'),
                        Label: string.IsNullOrWhiteSpace(drive.VolumeLabel) ? null : drive.VolumeLabel,
                        Format: drive.DriveFormat,
                        TotalGb: totalGb,
                        FreeGb: freeGb,
                        IsReady: true));
                }
                catch (Exception ex)
                {
                    result.Add(new FixedDiskSummary(drive.Name.TrimEnd('\\'), null, null, 0, 0, false, ex.Message));
                    errors.Add($"disk({drive.Name}): {ex.Message}");
                }
            }
        }
        catch (Exception ex)
        {
            errors.Add($"disks: {ex.Message}");
        }

        return result;
    }

    private static int ReadProcessCount(List<string> errors)
    {
        Process[]? procs = null;
        try
        {
            procs = Process.GetProcesses();
            return procs.Length;
        }
        catch (Exception ex)
        {
            errors.Add($"processes: {ex.Message}");
            return -1;
        }
        finally
        {
            if (procs is not null)
            {
                foreach (Process p in procs)
                {
                    try { p.Dispose(); } catch { /* Ignore */ }
                }
            }
        }
    }
}
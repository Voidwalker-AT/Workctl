namespace WorkCtlNext.Core;

public sealed record WorkctlPathsConfig(
    string WorkspaceRoot,
    string WsctlScriptPath,
    string PwshExecutable,
    string UlvoExecutable,
    TimeSpan WsctlTimeout,
    TimeSpan UlvoFastTimeout,
    TimeSpan UlvoEnvTimeout)
{
    public TimeSpan GitTimeout { get; init; } = TimeSpan.FromSeconds(3);
    public const string DefaultWorkspaceRoot = @"E:\Workspace";
    public const string DefaultWsctlScript = @"E:\Workspace\wsctl.ps1";
    public const string DefaultUlvoFallbackExe = @"E:\Workspace\Active\ULVO\bin\ulvo.exe";

    public static WorkctlPathsConfig FromEnvironment()
    {
        string workspaceRoot = EnvOrDefault("WORKCTL_NEXT_WORKSPACE_ROOT", DefaultWorkspaceRoot);
        string wsctlScript = EnvOrDefault("WORKCTL_NEXT_WSCTL_SCRIPT", Path.Combine(workspaceRoot, "wsctl.ps1"));
        string pwshExe = EnvOrDefault("WORKCTL_NEXT_PWSH_EXE",
            ProcessRunner.FindExecutableOnPath("pwsh", [@"C:\Users\hp\scoop\shims\pwsh.exe"]) ?? string.Empty);
        string ulvoExe = EnvOrDefault("WORKCTL_NEXT_ULVO_EXE",
            ProcessRunner.FindExecutableOnPath("ulvo", [DefaultUlvoFallbackExe]) ?? string.Empty);

        return new WorkctlPathsConfig(
            WorkspaceRoot: workspaceRoot,
            WsctlScriptPath: wsctlScript,
            PwshExecutable: pwshExe,
            UlvoExecutable: ulvoExe,
            WsctlTimeout: TimeSpan.FromSeconds(10),
            UlvoFastTimeout: TimeSpan.FromSeconds(5),
            UlvoEnvTimeout: TimeSpan.FromSeconds(15));
    }

    private static string EnvOrDefault(string name, string fallback)
    {
        string? raw = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(raw) ? fallback : raw.Trim();
    }
}
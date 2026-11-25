namespace WorkCtlNext.Core;

public enum FsOperationKind
{
    Read = 0,
    CopySource = 1,
    CopyDestination = 2,
    CreateDirectory = 3,
    MoveOrRename = 4,
    Delete = 5
}

public sealed class ProtectedPathPolicy
{
    private readonly string _workspaceRoot;
    private readonly string _wsctlScript;
    private readonly string _workspaceRegistry;
    private readonly string _sharedToolsDir;
    private readonly string _workstationControlDir;
    private readonly string? _ulvoDir;
    private readonly string _appBaseDir;
    private readonly string _scoopShimsDir;
    private readonly string _scoopWorkctlAppDir;
    private readonly string _userProfile;
    private readonly string _usersRoot;
    private readonly string _windowsDir;
    private readonly string _programFilesDir;
    private readonly string _programFilesX86Dir;
    private readonly string _programDataDir;
    private readonly string _systemDriveRoot;
    private readonly string? _ulvoExeFile;
    private readonly HashSet<string> _ulvoVaultRoots;

    public ProtectedPathPolicy(WorkctlPathsConfig config)
    {
        _workspaceRoot = PathNormalizer.NormalizeForCompare(config.WorkspaceRoot);
        _wsctlScript = PathNormalizer.NormalizeForCompare(config.WsctlScriptPath);
        _workspaceRegistry = PathNormalizer.NormalizeForCompare(Path.Combine(_workspaceRoot, "workspace.json"));
        _sharedToolsDir = PathNormalizer.NormalizeForCompare(Path.Combine(_workspaceRoot, "Shared"));
        _workstationControlDir = PathNormalizer.NormalizeForCompare(@"E:\TOOLS\WorkstationControl");

        _appBaseDir = PathNormalizer.NormalizeForCompare(AppContext.BaseDirectory);

        _userProfile = PathNormalizer.NormalizeForCompare(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        _usersRoot = !string.IsNullOrWhiteSpace(_userProfile)
            ? PathNormalizer.NormalizeForCompare(Path.GetDirectoryName(_userProfile) ?? @"C:\Users")
            : @"C:\Users";

        _windowsDir = PathNormalizer.NormalizeForCompare(Environment.GetFolderPath(Environment.SpecialFolder.Windows));
        _programFilesDir = PathNormalizer.NormalizeForCompare(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));
        _programFilesX86Dir = PathNormalizer.NormalizeForCompare(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86));
        _programDataDir = PathNormalizer.NormalizeForCompare(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData));
        _systemDriveRoot = PathNormalizer.NormalizeForCompare(Path.GetPathRoot(_windowsDir) ?? @"C:\");

        _scoopShimsDir = string.IsNullOrWhiteSpace(_userProfile)
            ? string.Empty
            : PathNormalizer.NormalizeForCompare(Path.Combine(_userProfile, "scoop", "shims"));
        _scoopWorkctlAppDir = string.IsNullOrWhiteSpace(_userProfile)
            ? string.Empty
            : PathNormalizer.NormalizeForCompare(Path.Combine(_userProfile, "scoop", "apps", "workctl"));

        string? resolvedUlvoDir = null;
        string? ulvoExeNorm = null;
        string tempRoot = PathNormalizer.NormalizeForCompare(Path.GetTempPath());
        if (!string.IsNullOrWhiteSpace(config.UlvoExecutable) && Path.IsPathRooted(config.UlvoExecutable))
        {
            ulvoExeNorm = PathNormalizer.NormalizeForCompare(config.UlvoExecutable);
            string candidate = PathNormalizer.NormalizeForCompare(Path.GetDirectoryName(config.UlvoExecutable) ?? string.Empty);
            if (!string.IsNullOrWhiteSpace(candidate) &&
                !IsDriveRoot(candidate) &&
                !EqualsNormalized(candidate, _workspaceRoot) &&
                !EqualsNormalized(candidate, tempRoot) &&
                !IsSameOrDescendant(candidate, _windowsDir))
            {
                resolvedUlvoDir = candidate;
            }
        }
        _ulvoDir = resolvedUlvoDir;
        _ulvoExeFile = ulvoExeNorm;

        _ulvoVaultRoots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string localAppData = PathNormalizer.NormalizeForCompare(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
        if (!string.IsNullOrWhiteSpace(localAppData))
            _ulvoVaultRoots.Add(PathNormalizer.NormalizeForCompare(Path.Combine(localAppData, "ulvo")));
        if (!string.IsNullOrWhiteSpace(_userProfile))
        {
            _ulvoVaultRoots.Add(PathNormalizer.NormalizeForCompare(Path.Combine(_userProfile, ".ulvo")));
            _ulvoVaultRoots.Add(PathNormalizer.NormalizeForCompare(Path.Combine(_userProfile, "ulvo")));
        }
        _ulvoVaultRoots.Add(PathNormalizer.NormalizeForCompare(@"E:\TOOLS\ulvo"));
        if (!string.IsNullOrWhiteSpace(_ulvoDir))
        {
            _ulvoVaultRoots.Add(_ulvoDir);
            string dirLeaf = Path.GetFileName(_ulvoDir);
            string parentDir = PathNormalizer.NormalizeForCompare(Path.GetDirectoryName(_ulvoDir) ?? string.Empty);
            if (dirLeaf.Equals("bin", StringComparison.OrdinalIgnoreCase) &&
                !string.IsNullOrWhiteSpace(parentDir) &&
                !IsDriveRoot(parentDir) &&
                !EqualsNormalized(parentDir, _workspaceRoot) &&
                !EqualsNormalized(parentDir, tempRoot) &&
                !IsSameOrDescendant(parentDir, _windowsDir) &&
                Path.GetFileName(parentDir).Contains("ulvo", StringComparison.OrdinalIgnoreCase))
            {
                _ulvoVaultRoots.Add(parentDir);
            }
        }
    }

    public ProtectionAssessment Assess(
        string rawPath,
        FsOperationKind operation,
        IReadOnlyCollection<string>? registeredProjectPaths = null)
    {
        if (string.IsNullOrWhiteSpace(rawPath))
            return new ProtectionAssessment(string.Empty, FsProtectionTier.Blocked, "Path is empty.", false);

        string norm = PathNormalizer.NormalizeForCompare(rawPath);
        if (string.IsNullOrWhiteSpace(norm))
            return new ProtectionAssessment(rawPath, FsProtectionTier.Blocked, "Path could not be normalized.", false);

        // Device namespace / malformed colon check (other than drive root X:)
        if (rawPath.StartsWith(@"\\.\", StringComparison.Ordinal))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Windows device namespace paths are blocked.", false);

        // Always detect ULVO vault/store directories regardless of Read vs Write so callers see badge,
        // and block ANY write/copy-source from ULVO vault.
        bool isUlvo = IsUlvoVaultPath(norm);
        if (operation == FsOperationKind.Read)
        {
            return AssessDisplayProtection(norm, isUlvo, registeredProjectPaths);
        }

        if (isUlvo)
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Protected ULVO vault/runtime location cannot be mutated or extracted.", true);

        // CopySource only reads source; non-ULVO readable sources are permitted unless device/empty.
        if (operation == FsOperationKind.CopySource)
            return AssessDisplayProtection(norm, isUlvo: false, registeredProjectPaths) with { Tier = FsProtectionTier.None };

        // Critical workstation registries and scripts (wsctl.ps1, workspace.json, Shared, WorkstationControl, Scoop shims, running binary dir)
        if (EqualsNormalized(norm, _wsctlScript) || IsSameOrDescendant(norm, _wsctlScript))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Protected legacy WSCTL entry script (wsctl.ps1).", false);

        if (EqualsNormalized(norm, _workspaceRegistry) || IsSameOrDescendant(norm, _workspaceRegistry))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Protected WSCTL registry (workspace.json).", false);

        if (IsSameOrDescendant(norm, _sharedToolsDir))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Protected Workspace Shared directory.", false);

        if (IsSameOrDescendant(norm, _workstationControlDir))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Protected WorkstationControl installation.", false);

        if (!string.IsNullOrWhiteSpace(_scoopShimsDir) && IsSameOrDescendant(norm, _scoopShimsDir))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Protected Scoop shims directory.", false);

        if (!string.IsNullOrWhiteSpace(_scoopWorkctlAppDir) && IsSameOrDescendant(norm, _scoopWorkctlAppDir))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Protected Scoop WorkCtl installation.", false);

        if (!string.IsNullOrWhiteSpace(_appBaseDir) && IsSameOrDescendant(norm, _appBaseDir))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Protected running WorkCtl Next application directory.", false);

        // Drive roots and critical OS directories
        if (IsDriveRoot(norm))
        {
            if (operation is FsOperationKind.Delete or FsOperationKind.MoveOrRename)
                return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Drive root cannot be deleted, moved, or renamed.", false);

            if (EqualsNormalized(norm, _systemDriveRoot))
                return new ProtectionAssessment(norm, FsProtectionTier.Warn, "OS system drive root requires explicit authorization.", false);
        }

        if (IsSameOrDescendant(norm, _windowsDir) ||
            IsSameOrDescendant(norm, _programFilesDir) ||
            IsSameOrDescendant(norm, _programFilesX86Dir) ||
            IsSameOrDescendant(norm, _programDataDir))
        {
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Protected Windows system directory.", false);
        }

        if (HasProtectedSystemSegment(norm))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Protected Windows system volume directory ($Recycle.Bin / System Volume Information / Recovery).", false);

        if (EqualsNormalized(norm, _usersRoot) || EqualsNormalized(norm, _userProfile))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "User profile root directory cannot be deleted, moved, or renamed.", false);

        // Registered project root protection or .git metadata protection
        if (EqualsNormalized(norm, _workspaceRoot) && operation is FsOperationKind.Delete or FsOperationKind.MoveOrRename)
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Primary Workspace root cannot be deleted, moved, or renamed.", false);

        if (HasSegment(norm, ".git"))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Git repository metadata (.git) is protected against direct filesystem mutation.", false);

        // Block Delete or MoveOrRename on any ancestor containing critical protected workstation, ULVO, Scoop, or OS targets.
        if (operation is FsOperationKind.Delete or FsOperationKind.MoveOrRename)
        {
            (string? Target, string Message, bool IsUlvo)[] protectedTargets =
            [
                (_wsctlScript, "Directory contains protected legacy WSCTL entry script (wsctl.ps1).", false),
                (_workspaceRegistry, "Directory contains protected WSCTL registry (workspace.json).", false),
                (_sharedToolsDir, "Directory contains protected Workspace Shared directory.", false),
                (_workstationControlDir, "Directory contains protected WorkstationControl installation.", false),
                (_scoopShimsDir, "Directory contains protected Scoop shims directory.", false),
                (_scoopWorkctlAppDir, "Directory contains protected Scoop WorkCtl installation.", false),
                (_appBaseDir, "Directory contains protected running WorkCtl Next application.", false),
                (_workspaceRoot, "Directory contains protected primary Workspace root.", false),
                (_ulvoExeFile, "Directory contains protected ULVO runtime executable.", true),
                (_windowsDir, "Directory contains Windows system directory.", false),
                (_programFilesDir, "Directory contains Program Files directory.", false),
                (_programFilesX86Dir, "Directory contains Program Files (x86) directory.", false),
                (_programDataDir, "Directory contains ProgramData directory.", false)
            ];

            foreach ((string? target, string message, bool isUlvoTarget) in protectedTargets)
            {
                if (!string.IsNullOrWhiteSpace(target) && IsSameOrDescendant(target, norm))
                    return new ProtectionAssessment(norm, FsProtectionTier.Blocked, message, isUlvoTarget);
            }

            foreach (string vaultRoot in _ulvoVaultRoots)
            {
                if (!string.IsNullOrWhiteSpace(vaultRoot) && IsSameOrDescendant(vaultRoot, norm))
                    return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Directory contains protected ULVO vault/runtime location.", true);
            }
        }

        if (registeredProjectPaths is not null)
        {
            foreach (string proj in registeredProjectPaths)
            {
                string normProj = PathNormalizer.NormalizeForCompare(proj);
                if (string.IsNullOrWhiteSpace(normProj))
                    continue;

                if (EqualsNormalized(norm, normProj) && operation is FsOperationKind.Delete or FsOperationKind.MoveOrRename)
                {
                    return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Registered project root cannot be deleted, moved, or renamed from browser.", false);
                }

                if (IsSameOrDescendant(norm, normProj))
                {
                    return new ProtectionAssessment(norm, FsProtectionTier.Warn, "Inside registered workspace project — requires explicit authorization.", false);
                }
            }
        }

        return new ProtectionAssessment(norm, FsProtectionTier.None, null, false);
    }

    private ProtectionAssessment AssessDisplayProtection(
        string norm,
        bool isUlvo,
        IReadOnlyCollection<string>? registeredProjectPaths)
    {
        if (isUlvo)
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "ULVO vault / runtime", true);
        if (EqualsNormalized(norm, _wsctlScript) || EqualsNormalized(norm, _workspaceRegistry) ||
            IsSameOrDescendant(norm, _sharedToolsDir) || IsSameOrDescendant(norm, _workstationControlDir))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Protected WSCTL asset", false);
        if (IsSameOrDescendant(norm, _windowsDir) || IsSameOrDescendant(norm, _programFilesDir) ||
            IsSameOrDescendant(norm, _programFilesX86Dir) || IsSameOrDescendant(norm, _programDataDir))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Windows system location", false);
        if (HasSegment(norm, ".git"))
            return new ProtectionAssessment(norm, FsProtectionTier.Blocked, "Git internal metadata", false);
        if (registeredProjectPaths is not null &&
            registeredProjectPaths.Any(p => EqualsNormalized(norm, PathNormalizer.NormalizeForCompare(p))))
            return new ProtectionAssessment(norm, FsProtectionTier.Warn, "Registered project root", false);

        return new ProtectionAssessment(norm, FsProtectionTier.None, null, false);
    }

    private bool IsUlvoVaultPath(string norm)
    {
        if (!string.IsNullOrWhiteSpace(_ulvoExeFile) && EqualsNormalized(norm, _ulvoExeFile))
            return true;

        foreach (string vaultRoot in _ulvoVaultRoots)
        {
            if (IsSameOrDescendant(norm, vaultRoot))
                return true;
        }

        return HasSegment(norm, ".ulvo") || HasSegment(norm, "ulvo-vault");
    }

    private static bool IsDriveRoot(string norm)
        => norm.Length == 3 && char.IsLetter(norm[0]) && norm[1] == ':' && norm[2] == '\\';

    private static bool EqualsNormalized(string a, string b)
        => !string.IsNullOrWhiteSpace(a) && !string.IsNullOrWhiteSpace(b) &&
           string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    public static bool IsSameOrDescendant(string candidate, string root)
    {
        if (string.IsNullOrWhiteSpace(candidate) || string.IsNullOrWhiteSpace(root))
            return false;

        if (string.Equals(candidate, root, StringComparison.OrdinalIgnoreCase))
            return true;

        string prefix = root.EndsWith(Path.DirectorySeparatorChar)
            ? root
            : root + Path.DirectorySeparatorChar;
        return candidate.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    private static bool HasSegment(string norm, string segment)
    {
        string[] parts = norm.Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries);
        return parts.Any(p => string.Equals(p, segment, StringComparison.OrdinalIgnoreCase));
    }

    private static bool HasProtectedSystemSegment(string norm)
    {
        string[] parts = norm.Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries);
        return parts.Any(p =>
            string.Equals(p, "$Recycle.Bin", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(p, "System Volume Information", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(p, "Recovery", StringComparison.OrdinalIgnoreCase));
    }
}

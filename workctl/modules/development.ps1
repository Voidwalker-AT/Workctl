# =================================================================
# WorkCtl v1.5 - Development Subsystem Engine
# =================================================================

$script:DevRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { "E:\TOOLS\WorkstationControl" }
$script:DevRuntimeDir = Join-Path $script:DevRoot "runtime"
$script:DevProjectsCacheFile = Join-Path $script:DevRuntimeDir "project-discovery.json"

$script:DevProjectsCache = $null
$script:DevProjectsCacheTime = [datetime]::MinValue
$script:DevWorkspaceRoot = "E:\Workspace"

# -----------------------------------------------------------------
# 1. PROJECT DISCOVERY & CACHING
# -----------------------------------------------------------------

function Get-WorkCtlProjects {
    param(
        [switch]$ForceRefresh
    )

    $now = [datetime]::Now
    if (!$ForceRefresh -and $script:DevProjectsCache -and (($now - $script:DevProjectsCacheTime).TotalSeconds -lt 60)) {
        return $script:DevProjectsCache
    }

    # Check file cache if in-memory cache is cold
    if (!$ForceRefresh -and (Test-Path -LiteralPath $script:DevProjectsCacheFile)) {
        try {
            $mtime = (Get-Item -LiteralPath $script:DevProjectsCacheFile).LastWriteTime
            if (($now - $mtime).TotalSeconds -lt 120) {
                $cachedJson = Get-Content -LiteralPath $script:DevProjectsCacheFile -Raw | ConvertFrom-Json
                if ($cachedJson) {
                    $script:DevProjectsCache = @($cachedJson)
                    $script:DevProjectsCacheTime = $mtime
                    return $script:DevProjectsCache
                }
            }
        } catch {}
    }

    $ignoredNames = @(
        'node_modules', '.git', 'temp', '.tmp', 'AI-Bridge.worktrees',
        'dist', 'build', 'target', 'bin', 'obj', 'venv', '.venv'
    )

    $projects = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $script:DevWorkspaceRoot) {
        $dirs = @(Get-ChildItem -Path $script:DevWorkspaceRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $ignoredNames -notcontains $_.Name })

        foreach ($d in $dirs) {
            $gitDir = Join-Path $d.FullName ".git"
            $hasGit = Test-Path -LiteralPath $gitDir
            $hasPackageJson = Test-Path -LiteralPath (Join-Path $d.FullName "package.json")
            $hasPyProject = (Test-Path -LiteralPath (Join-Path $d.FullName "pyproject.toml")) -or (Test-Path -LiteralPath (Join-Path $d.FullName "requirements.txt"))
            $hasCargo = Test-Path -LiteralPath (Join-Path $d.FullName "Cargo.toml")
            $hasDotNet = @(Get-ChildItem -Path $d.FullName -Filter "*.sln" -Depth 1 -ErrorAction SilentlyContinue).Count -gt 0 -or
                         @(Get-ChildItem -Path $d.FullName -Filter "*.csproj" -Depth 1 -ErrorAction SilentlyContinue).Count -gt 0

            $types = New-Object System.Collections.Generic.List[string]
            if ($hasPackageJson) { $types.Add("Node/TypeScript") }
            if ($hasPyProject) { $types.Add("Python") }
            if ($hasDotNet) { $types.Add(".NET") }
            if ($hasCargo) { $types.Add("Rust") }
            if ($types.Count -eq 0 -and $hasGit) { $types.Add("Git Repository") }

            if ($types.Count -gt 0 -or $hasGit) {
                $branch = ""
                if ($hasGit) {
                    $headPath = Join-Path $gitDir "HEAD"
                    if (Test-Path -LiteralPath $headPath) {
                        try {
                            $headContent = (Get-Content -LiteralPath $headPath -Raw).Trim()
                            if ($headContent -match "ref: refs/heads/(.+)") {
                                $branch = $matches[1]
                            } else {
                                $branch = "detached"
                            }
                        } catch { $branch = "unknown" }
                    }
                }

                $projects.Add([PSCustomObject]@{
                    Name = $d.Name
                    Path = $d.FullName
                    Types = $types.ToArray()
                    PrimaryType = if ($types.Count -gt 0) { $types[0] } else { "General" }
                    Git = $hasGit
                    Branch = $branch
                    LastModified = $d.LastWriteTime
                })
            }
        }
    }

    $script:DevProjectsCache = $projects.ToArray()
    $script:DevProjectsCacheTime = $now

    # Persist cache asynchronously/silently
    try {
        if (!(Test-Path -LiteralPath $script:DevRuntimeDir)) {
            New-Item -ItemType Directory -Force -Path $script:DevRuntimeDir | Out-Null
        }
        $script:DevProjectsCache | ConvertTo-Json -Depth 4 | Set-Content -Path $script:DevProjectsCacheFile -Encoding UTF8
    } catch {}

    return $script:DevProjectsCache
}

# -----------------------------------------------------------------
# 2. AI CODING AGENTS REGISTRY
# -----------------------------------------------------------------

$script:DevAiAgentsCache = $null
$script:DevAiAgentsCacheTime = [datetime]::MinValue

function Get-WorkCtlAiAgents {
    param(
        [switch]$ForceRefresh
    )

    $now = [datetime]::Now
    if (!$ForceRefresh -and $script:DevAiAgentsCache -and (($now - $script:DevAiAgentsCacheTime).TotalSeconds -lt 60)) {
        return $script:DevAiAgentsCache
    }

    $fbInstalled = (Get-Command freebuff -ErrorAction SilentlyContinue) -ne $null
    $fbVer = if ($fbInstalled) { "0.0.174" } else { "Not Installed" }

    $vscodeInstalled = (Get-Command code -ErrorAction SilentlyContinue) -ne $null

    $script:DevAiAgentsCache = @(
        [PSCustomObject]@{
            Id = "freebuff"
            Name = "Freebuff AI Coding Agent"
            Type = "Terminal Multi-Agent"
            Installed = $fbInstalled
            Version = $fbVer
            Executable = "freebuff"
            Runtime = "Node.js / Native Zig-Bun Engine"
            Policy = "LAUNCH"
            Capabilities = @("File Context", "Code Editing", "Terminal Execution", "Web Research", "Multi-Agent Planning")
            PrivacyNotice = "Cloud-backed; text ad-supported. See WorkCtl Guide for telemetry and data usage terms."
            Description = "Free, ad-supported terminal coding assistant with GLM 5.3 Flash & DeepSeek."
        },
        [PSCustomObject]@{
            Id = "antigravity"
            Name = "Google Antigravity Agent"
            Type = "Workstation Primary Agent"
            Installed = $true
            Version = "2.0 (Active)"
            Executable = "antigravity"
            Runtime = "DeepMind Agentic Architecture"
            Policy = "PROTECTED"
            Capabilities = @("Full Workstation Control", "TUI Navigation", "Pair Programming", "Safety Governance")
            PrivacyNotice = "Local orchestration with user-directed cloud intelligence."
            Description = "Protected workstation supervisor and primary pair programming environment."
        },
        [PSCustomObject]@{
            Id = "vscode"
            Name = "Visual Studio Code"
            Type = "Desktop IDE / Editor"
            Installed = $vscodeInstalled
            Version = "Current"
            Executable = "code"
            Runtime = "Electron"
            Policy = "LAUNCH"
            Capabilities = @("Rich IDE", "Extensions", "Git Integration", "Integrated Terminal")
            PrivacyNotice = "Standard Microsoft VS Code telemetry."
            Description = "Extensible code editor and workstation desktop development interface."
        }
    )
    $script:DevAiAgentsCacheTime = $now
    return $script:DevAiAgentsCache
}

# -----------------------------------------------------------------
# 3. RUNTIMES REGISTRY
# -----------------------------------------------------------------

function Get-WorkCtlRuntimes {
    param(
        [switch]$ForceRefresh
    )

    $now = [datetime]::Now
    if (!$ForceRefresh -and $script:DevRuntimesCache -and (($now - $script:DevRuntimesCacheTime).TotalSeconds -lt 60)) {
        return $script:DevRuntimesCache
    }

    $runtimes = New-Object System.Collections.Generic.List[object]

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        $runtimes.Add([PSCustomObject]@{
            Name = "Node.js"
            Version = (node -v 2>&1).Trim()
            Path = $nodeCmd.Source
            Category = "JavaScript/TypeScript"
        })
    }

    $pyCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pyCmd) {
        $runtimes.Add([PSCustomObject]@{
            Name = "Python"
            Version = (python --version 2>&1).Trim()
            Path = $pyCmd.Source
            Category = "Python"
        })
    }

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $runtimes.Add([PSCustomObject]@{
            Name = "Git"
            Version = (git --version 2>&1).Trim()
            Path = $gitCmd.Source
            Category = "Version Control"
        })
    }

    $script:DevRuntimesCache = $runtimes.ToArray()
    $script:DevRuntimesCacheTime = $now
    return $script:DevRuntimesCache
}

# -----------------------------------------------------------------
# 4. LAUNCH ACTIONS
# -----------------------------------------------------------------

function Invoke-WorkCtlLaunchFreebuff {
    param(
        [string]$ProjectPath = ""
    )

    $targetDir = if ($ProjectPath -and (Test-Path -LiteralPath $ProjectPath)) {
        $ProjectPath
    } else {
        $script:DevWorkspaceRoot
    }

    if (Get-Command Invoke-WorkCtlInteractiveTool -ErrorAction SilentlyContinue) {
        return (Invoke-WorkCtlInteractiveTool -Command "cmd.exe" -Arguments "/c freebuff" -WorkingDirectory $targetDir)
    } else {
        Write-Warning "Invoke-WorkCtlInteractiveTool not found"
        return -1
    }
}

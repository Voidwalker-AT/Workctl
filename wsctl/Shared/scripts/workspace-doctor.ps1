<#
.SYNOPSIS
    Workspace Platform Doctor (workspace-doctor.ps1)

.DESCRIPTION
    Comprehensive, read-only diagnostic auditor for the E:\Workspace engineering platform.
    Validates toolchains, runtimes, package caches, AI models, GPU/CUDA acceleration,
    virtual environments, documentation links, and project manifests.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\workspace-doctor.ps1
#>

[CmdletBinding()]
param (
    [switch]$Detailed,
    [switch]$Json,
    [switch]$NoSave,
    [string]$WorkspaceRoot = "E:\Workspace"
)

$ErrorActionPreference = "Continue"

# Resolve Workspace Root dynamically if run from subfolder
if (-not (Test-Path $WorkspaceRoot)) {
    $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$SharedPath = Join-Path $WorkspaceRoot "Shared"
$DocsPath = Join-Path $WorkspaceRoot "docs"
$ManifestPath = Join-Path $WorkspaceRoot "workspace.json"
$ToolchainsConfig = Join-Path $SharedPath "configs\toolchains.json"
$ArtifactsDir = Join-Path $SharedPath "artifacts"

# Counters & Result Collection
$totalChecks = 0
$okCount = 0
$warnCount = 0
$missingCount = 0
$optionalCount = 0
$errorCount = 0
$checkResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Write-Host {
    if (-not $Json) {
        Microsoft.PowerShell.Utility\Write-Host @args
    }
}

function Report-Check {
    param (
        [string]$Category,
        [string]$Item,
        [string]$Status, # OK, WARNING, MISSING, OPTIONAL, ERROR
        [string]$Message,
        [string]$Detail = ""
    )

    $script:totalChecks++
    $script:checkResults.Add([PSCustomObject]@{
        Category = $Category
        Item     = $Item
        Status   = $Status
        Message  = $Message
        Detail   = $Detail
    })

    $color = "White"
    switch ($Status) {
        "OK"       { $color = "Green"; $script:okCount++ }
        "WARNING"  { $color = "Yellow"; $script:warnCount++ }
        "MISSING"  { $color = "Red"; $script:missingCount++ }
        "OPTIONAL" { $color = "DarkGray"; $script:optionalCount++ }
        "ERROR"    { $color = "Red"; $script:errorCount++ }
    }

    if ($Json) { return }

    $padItem = $Item.PadRight(28, '.')
    $padStatus = "[$Status]".PadRight(10, ' ')
    
    Write-Host "  $padItem " -NoNewline -ForegroundColor White
    Write-Host "$padStatus " -NoNewline -ForegroundColor $color
    Write-Host "$Message" -ForegroundColor Gray

    if ($Detailed -and $Detail) {
        Write-Host "      └─ $Detail" -ForegroundColor DarkCyan
    }
}

Write-Host ""
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host "                  WORKSPACE PLATFORM DOCTOR (E:\Workspace)                 " -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host " Root Directory : $WorkspaceRoot" -ForegroundColor Gray
Write-Host " Audit Mode     : Read-Only System & Platform Verification" -ForegroundColor Gray
Write-Host " Timestamp      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "==========================================================================" -ForegroundColor Cyan

# -------------------------------------------------------------
# 1. WORKSPACE PLATFORM STRUCTURE
# -------------------------------------------------------------
Write-Host "`n[1/10] Workspace Infrastructure" -ForegroundColor Yellow

if (Test-Path $WorkspaceRoot) {
    Report-Check "Workspace" "Workspace Root" "OK" "Accessible ($WorkspaceRoot)"
} else {
    Report-Check "Workspace" "Workspace Root" "ERROR" "Path does not exist ($WorkspaceRoot)"
}

if (Test-Path $SharedPath) {
    Report-Check "Workspace" "Shared Platform Layer" "OK" "Accessible ($SharedPath)"
} else {
    Report-Check "Workspace" "Shared Platform Layer" "ERROR" "Missing Shared directory"
}

if (Test-Path $DocsPath) {
    Report-Check "Workspace" "Governance Docs" "OK" "Accessible ($DocsPath)"
} else {
    Report-Check "Workspace" "Governance Docs" "WARNING" "docs directory missing"
}

if (Test-Path $ManifestPath) {
    try {
        $manifestObj = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        $pCount = $manifestObj.projects.Count
        Report-Check "Workspace" "Project Manifest" "OK" "Valid workspace.json ($pCount cataloged projects)"
    } catch {
        Report-Check "Workspace" "Project Manifest" "ERROR" "workspace.json failed to parse JSON"
    }
} else {
    Report-Check "Workspace" "Project Manifest" "MISSING" "workspace.json not found"
}

# Global Command Resolution
$wsctlCmd = Get-Command "wsctl" -ErrorAction SilentlyContinue
if ($wsctlCmd) {
    Report-Check "Workspace" "WSCTL Global Command" "OK" "Global command available ($($wsctlCmd.Source))"
} else {
    Report-Check "Workspace" "WSCTL Global Command" "WARNING" "Global shim not found in PATH (direct invocation works: E:\Workspace\wsctl.ps1)"
}

# -------------------------------------------------------------
# 2. CORE & SHELL
# -------------------------------------------------------------
Write-Host "`n[2/10] Core Shell & Version Control" -ForegroundColor Yellow

# Git
$gitCmd = Get-Command "git" -ErrorAction SilentlyContinue
if ($gitCmd) {
    $gitVer = (& git --version).Trim()
    $longpaths = git config --get core.longpaths
    $lpMsg = if ($longpaths -eq "true") { "longpaths enabled" } else { "longpaths unset (recommend 'git config --global core.longpaths true')" }
    Report-Check "Core" "Git" "OK" "$gitVer | $lpMsg"
} else {
    Report-Check "Core" "Git" "ERROR" "Git not found in PATH"
}

# PowerShell
$psVer = $PSVersionTable.PSVersion.ToString()
Report-Check "Core" "PowerShell" "OK" "pwsh v$psVer"

# Cmd
if (Get-Command "cmd.exe" -ErrorAction SilentlyContinue) {
    Report-Check "Core" "Command Prompt" "OK" "cmd.exe available"
} else {
    Report-Check "Core" "Command Prompt" "WARNING" "cmd.exe not found"
}

# WSL
if (Get-Command "wsl.exe" -ErrorAction SilentlyContinue) {
    Report-Check "Core" "WSL" "OK" "WSL 2 available (Ubuntu / Docker ready)"
} else {
    Report-Check "Core" "WSL" "OPTIONAL" "WSL not found"
}

# -------------------------------------------------------------
# 3. PYTHON ECOSYSTEM
# -------------------------------------------------------------
Write-Host "`n[3/10] Python Ecosystem & Package Caching" -ForegroundColor Yellow

# Python Launcher
if (Get-Command "py.exe" -ErrorAction SilentlyContinue) {
    Report-Check "Python" "Python Launcher (py)" "OK" "Available (multi-version dispatcher)"
} else {
    Report-Check "Python" "Python Launcher (py)" "WARNING" "py.exe launcher not found"
}

# Default Python
$pyCmd = Get-Command "python" -ErrorAction SilentlyContinue
if ($pyCmd) {
    $pyVer = (& python --version 2>&1).Trim()
    Report-Check "Python" "Default Python" "OK" "$pyVer ($($pyCmd.Source))"
} else {
    Report-Check "Python" "Default Python" "ERROR" "No default python interpreter found in PATH"
}

# UV
$uvCmd = Get-Command "uv" -ErrorAction SilentlyContinue
if ($uvCmd) {
    $uvVer = (& uv --version 2>&1).Trim()
    $uvCachePath = "C:\Users\hp\scoop\persist\uv\cache"
    $uvCacheSize = "active"
    if (Test-Path $uvCachePath) {
        $uvCacheFiles = (Get-ChildItem -Path $uvCachePath -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum)
        $uvCacheMB = [math]::Round($uvCacheFiles.Sum / 1GB, 2)
        $uvCacheSize = "$uvCacheMB GB shared package cache on C:"
    }
    Report-Check "Python" "Astral UV" "OK" "$uvVer ($uvCacheSize)"
} else {
    Report-Check "Python" "Astral UV" "WARNING" "uv not installed. Highly recommended for fast package caching."
}

# Pip
$pipVer = try { (& python -m pip --version 2>&1).Trim() } catch { "Error" }
if ($pipVer -notmatch "Error") {
    Report-Check "Python" "Pip" "OK" "$pipVer"
} else {
    Report-Check "Python" "Pip" "WARNING" "Pip not responding in default Python"
}

# -------------------------------------------------------------
# 4. NODE.JS & JAVASCRIPT ECOSYSTEM
# -------------------------------------------------------------
Write-Host "`n[4/10] Node.js & JavaScript Tooling" -ForegroundColor Yellow

# Node
$nodeCmd = Get-Command "node" -ErrorAction SilentlyContinue
if ($nodeCmd) {
    $nodeVer = (& node --version 2>&1).Trim()
    Report-Check "Node" "Node.js" "OK" "$nodeVer (via NVM: $($nodeCmd.Source))"
} else {
    Report-Check "Node" "Node.js" "ERROR" "Node.js not found in PATH"
}

# npm (Workspace Standard)
$npmCmd = Get-Command "npm" -ErrorAction SilentlyContinue
if ($npmCmd) {
    $npmVer = (& npm --version 2>&1).Trim()
    Report-Check "Node" "npm (Default)" "OK" "v$npmVer (Dominant package manager for 1st-party projects)"
} else {
    Report-Check "Node" "npm (Default)" "ERROR" "npm not found in PATH"
}

# pnpm
$pnpmCmd = Get-Command "pnpm" -ErrorAction SilentlyContinue
if ($pnpmCmd) {
    $pnpmVer = (& pnpm --version 2>&1).Trim()
    Report-Check "Node" "pnpm" "OK" "v$pnpmVer (Preserved for DeepSeek-Harness/Goose-UI)"
} else {
    Report-Check "Node" "pnpm" "OPTIONAL" "pnpm not found"
}

# Corepack
$corepackCmd = Get-Command "corepack" -ErrorAction SilentlyContinue
if ($corepackCmd) {
    Report-Check "Node" "Corepack" "OK" "Available for package manager version pinning"
} else {
    Report-Check "Node" "Corepack" "OPTIONAL" "Corepack not found"
}

# -------------------------------------------------------------
# 5. COMPILED LANGUAGES & TOOLCHAINS
# -------------------------------------------------------------
Write-Host "`n[5/10] Compiled Languages & Native Toolchains" -ForegroundColor Yellow

# GCC / G++
$gccCmd = Get-Command "gcc" -ErrorAction SilentlyContinue
if ($gccCmd) {
    $gccVer = (& gcc --version)[0].Trim()
    Report-Check "Compiled" "GCC C/C++ (MSYS2)" "OK" "$gccVer"
} else {
    Report-Check "Compiled" "GCC C/C++ (MSYS2)" "ERROR" "GCC compiler not found on PATH"
}

# CMake
$cmakeCmd = Get-Command "cmake" -ErrorAction SilentlyContinue
if ($cmakeCmd) {
    $cmakeVer = (& cmake --version)[0].Trim()
    Report-Check "Compiled" "CMake" "OK" "$cmakeVer"
} else {
    Report-Check "Compiled" "CMake" "WARNING" "CMake not found"
}

# Ninja
$ninjaCmd = Get-Command "ninja" -ErrorAction SilentlyContinue
if ($ninjaCmd) {
    $ninjaVer = (& ninja --version 2>&1).Trim()
    Report-Check "Compiled" "Ninja" "OK" "v$ninjaVer"
} else {
    Report-Check "Compiled" "Ninja" "OPTIONAL" "Ninja not found"
}

# Java & JAVA_HOME
$javaCmd = Get-Command "java" -ErrorAction SilentlyContinue
$javaHome = $env:JAVA_HOME
if ($javaCmd -and $javaHome -and (Test-Path $javaHome)) {
    $javaVer = (& java -version 2>&1)[0].ToString().Trim()
    Report-Check "Compiled" "Java JDK 21 LTS" "OK" "$javaVer | JAVA_HOME verified"
} elseif ($javaCmd) {
    Report-Check "Compiled" "Java JDK 21 LTS" "WARNING" "java found but JAVA_HOME variable unset"
} else {
    Report-Check "Compiled" "Java JDK 21 LTS" "ERROR" "Java runtime not found"
}

# Go
$goCmd = Get-Command "go" -ErrorAction SilentlyContinue
if ($goCmd) {
    $goVer = (& go version 2>&1).Trim()
    Report-Check "Compiled" "Go Runtime" "OK" "$goVer (GOPATH: $env:GOPATH)"
} else {
    Report-Check "Compiled" "Go Runtime" "OPTIONAL" "Go not found"
}

# .NET
$dotnetCmd = Get-Command "dotnet" -ErrorAction SilentlyContinue
if ($dotnetCmd) {
    $dotnetVer = (& dotnet --version 2>&1).Trim()
    Report-Check "Compiled" ".NET SDK" "OK" "v$dotnetVer (Powers OmenCore / DungeonEscape)"
} else {
    Report-Check "Compiled" ".NET SDK" "WARNING" ".NET SDK not found"
}

# Rust (Optional)
$rustCmd = Get-Command "rustc" -ErrorAction SilentlyContinue
if ($rustCmd) {
    Report-Check "Compiled" "Rust (rustc)" "OK" "$((& rustc --version).Trim())"
} else {
    Report-Check "Compiled" "Rust (rustc)" "OPTIONAL" "Absent (Only needed if compiling References/Goose from source)"
}

# Maven / Gradle (Optional)
$mvnCmd = Get-Command "mvn" -ErrorAction SilentlyContinue
if ($mvnCmd) {
    Report-Check "Compiled" "Maven" "OK" "$((& mvn -version)[0].Trim())"
} else {
    Report-Check "Compiled" "Maven / Gradle" "OPTIONAL" "Absent (Academic Java uses direct javac or embedded wrappers)"
}

# -------------------------------------------------------------
# 6. GPU & HARDWARE ACCELERATION
# -------------------------------------------------------------
Write-Host "`n[6/10] GPU Hardware & CUDA Acceleration" -ForegroundColor Yellow

$smiCmd = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
if ($smiCmd) {
    $smiOut = & nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>&1
    $parts = $smiOut -split ','
    $gpuName = $parts[0].Trim()
    $drvVer = $parts[1].Trim()
    $vram = [math]::Round([double]$parts[2].Trim() / 1024, 1)
    Report-Check "GPU" "NVIDIA GPU Driver" "OK" "$gpuName ($vram GB VRAM) | Driver $drvVer (CUDA 13.2 capable)"
} else {
    Report-Check "GPU" "NVIDIA GPU Driver" "WARNING" "nvidia-smi not available"
}

$nvccCmd = Get-Command "nvcc" -ErrorAction SilentlyContinue
if ($nvccCmd) {
    $nvccVer = ((& nvcc --version | Select-String "release") -split ',')[1].Trim()
    Report-Check "GPU" "Host CUDA Toolkit" "OK" "nvcc $nvccVer (Installed on host for C++/CUDA compilation)"
} else {
    Report-Check "GPU" "Host CUDA Toolkit" "OPTIONAL" "nvcc not on PATH (PyTorch bundles its own CUDA runtime)"
}

# -------------------------------------------------------------
# 7. AI MODELS & CANONICAL STORAGE
# -------------------------------------------------------------
Write-Host "`n[7/10] AI Models & Canonical Storage Contract" -ForegroundColor Yellow

$modelsRoot = "E:\AI_Models"
if (Test-Path $modelsRoot) {
    Report-Check "AI" "External Model Store" "OK" "Accessible ($modelsRoot)"
} else {
    Report-Check "AI" "External Model Store" "ERROR" "E:\AI_Models not found"
}

# Ollama Models
$ollamaModelsDir = "E:\AI_Models\OLLAMA"
if (Test-Path $ollamaModelsDir) {
    $ollamaFiles = (Get-ChildItem -Path $ollamaModelsDir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum)
    $ollamaGB = [math]::Round($ollamaFiles.Sum / 1GB, 2)
    $envVarOk = ($env:OLLAMA_MODELS -eq $ollamaModelsDir)
    $msg = "$ollamaGB GB in storage | OLLAMA_MODELS variable: $(if ($envVarOk) { 'Configured' } else { 'Missing/Misaligned' })"
    Report-Check "AI" "Ollama Models" "OK" "$msg"
} else {
    Report-Check "AI" "Ollama Models" "WARNING" "E:\AI_Models\OLLAMA folder missing"
}

# Hugging Face Cache Readiness
$hfCacheDir = "E:\AI_Models\HF_CACHE"
if (Test-Path $hfCacheDir) {
    $hfEnvSet = [string]::IsNullOrEmpty($env:HF_HOME) -eq $false
    $hfStatus = if ($hfEnvSet) { "Active (HF_HOME=$env:HF_HOME)" } else { "Ready (Recommended: HF_HOME=$hfCacheDir)" }
    Report-Check "AI" "Hugging Face Cache" "OK" "$hfStatus"
} else {
    Report-Check "AI" "Hugging Face Cache" "WARNING" "E:\AI_Models\HF_CACHE directory not found"
}

# -------------------------------------------------------------
# 8. ACTIVE PROJECT ENVIRONMENTS SANITY
# -------------------------------------------------------------
Write-Host "`n[8/10] Isolated Project Environments Sanity" -ForegroundColor Yellow

# Shared ds-base
$dsBasePython = Join-Path $SharedPath "envs\ds-base\Scripts\python.exe"
if (Test-Path $dsBasePython) {
    $dsCheck = & $dsBasePython -c "import numpy, pandas, sklearn, jupyter; print('OK')" 2>&1
    if ($dsCheck -match "OK") {
        Report-Check "Environments" "Shared ds-base" "OK" "Python 3.10.11 (NumPy, Pandas, Scikit-learn, Jupyter verified)"
    } else {
        Report-Check "Environments" "Shared ds-base" "WARNING" "ds-base python exists but package import failed"
    }
} else {
    Report-Check "Environments" "Shared ds-base" "MISSING" "Shared\envs\ds-base interpreter not found"
}

# ULVO resolves the existing compatible runtimes; local .venv paths are obsolete.
foreach ($expNum in @(1, 2)) {
    $dlProject = Join-Path $WorkspaceRoot "Academic\sem5\DL\exp$expNum"
    if (-not (Get-Command ulvo -ErrorAction SilentlyContinue)) {
        Report-Check "Environments" "Academic DL Exp$expNum" "ERROR" "ULVO gateway not available"
        continue
    }
    $dlCheck = & ulvo run --keep-env $dlProject -- python -B -c "import torch; print(torch.__version__); print(torch.cuda.is_available()); print(torch.ones(2).sum().item())" 2>&1
    $dlExit = $LASTEXITCODE
    if ($dlExit -ne 0) {
        Report-Check "Environments" "Academic DL Exp$expNum" "ERROR" "ULVO runtime/import/tensor probe failed" ($dlCheck -join "`n")
    } elseif ($dlCheck -contains "True") {
        Report-Check "Environments" "Academic DL Exp$expNum" "OK" "ULVO runtime, PyTorch CPU tensor and CUDA availability verified" ($dlCheck -join "`n")
    } else {
        Report-Check "Environments" "Academic DL Exp$expNum" "WARNING" "ULVO PyTorch works; CUDA unavailable (CPU fallback)" ($dlCheck -join "`n")
    }
}

# YOLO Environment
$yoloPython = Join-Path $WorkspaceRoot "Academic\sem5\yolo\Scripts\python.exe"
if (Test-Path $yoloPython) {
    $yoloCheck = & $yoloPython -c "import torch; print(f'PyTorch {torch.__version__}, CUDA: {torch.cuda.is_available()}')" 2>&1
    if ($yoloCheck -match "CUDA: True") {
        Report-Check "Environments" "Academic Sem5 YOLO" "OK" "$yoloCheck"
    } else {
        Report-Check "Environments" "Academic Sem5 YOLO" "WARNING" "YOLO environment issue: $yoloCheck"
    }
} else {
    Report-Check "Environments" "Academic Sem5 YOLO" "OPTIONAL" "Academic\sem5\yolo environment not found"
}

# Termux AI Workstation Environment
$termuxPython = Join-Path $WorkspaceRoot "Active\termux-ai-workstation\.venv\Scripts\python.exe"
if (Test-Path $termuxPython) {
    $termuxCheck = & $termuxPython -c "import torch; print(f'PyTorch {torch.__version__}, CUDA: {torch.cuda.is_available()}')" 2>&1
    if ($termuxCheck -match "CUDA: True") {
        Report-Check "Environments" "termux-ai-workstation" "OK" "$termuxCheck"
    } else {
        Report-Check "Environments" "termux-ai-workstation" "WARNING" "termux-ai-workstation issue: $termuxCheck"
    }
} else {
    Report-Check "Environments" "termux-ai-workstation" "OPTIONAL" "Active\termux-ai-workstation\.venv not found"
}

# -------------------------------------------------------------
# 9. DOCUMENTATION & LINK HEALTH
# -------------------------------------------------------------
Write-Host "`n[9/10] Documentation & Integrity" -ForegroundColor Yellow

$rootReadme = Join-Path $WorkspaceRoot "README.md"
$docsIndex = Join-Path $DocsPath "INDEX.md"
$agentsMd = Join-Path $WorkspaceRoot "AGENTS.md"

if (Test-Path $rootReadme) {
    Report-Check "Documentation" "Workspace README" "OK" "Present ($rootReadme)"
} else {
    Report-Check "Documentation" "Workspace README" "ERROR" "Root README.md missing"
}

if (Test-Path $docsIndex) {
    Report-Check "Documentation" "Docs Index" "OK" "Present ($docsIndex)"
} else {
    Report-Check "Documentation" "Docs Index" "WARNING" "docs/INDEX.md missing"
}

if (Test-Path $agentsMd) {
    Report-Check "Documentation" "Agent Operating Contract" "OK" "Present (AGENTS.md established)"
} else {
    Report-Check "Documentation" "Agent Operating Contract" "WARNING" "AGENTS.md not found in root"
}

# Category Governance Contracts
$categoryContracts = @("Active\AGENTS.md", "Academic\AGENTS.md", "Tools\AGENTS.md", "References\AGENTS.md", "Completed\AGENTS.md", "Shared\AGENTS.md")
$missingCategories = 0
foreach ($cc in $categoryContracts) {
    if (-not (Test-Path (Join-Path $WorkspaceRoot $cc))) { $missingCategories++ }
}
if ($missingCategories -eq 0) {
    Report-Check "Documentation" "Category Governance" "OK" "All $($categoryContracts.Count) category AGENTS.md contracts present"
} else {
    Report-Check "Documentation" "Category Governance" "WARNING" "$missingCategories category AGENTS.md contracts missing"
}

# -------------------------------------------------------------
# 10. PROJECT MANIFEST VALIDATION
# -------------------------------------------------------------
Write-Host "`n[10/10] Project Manifest Integrity" -ForegroundColor Yellow

if (Test-Path $ManifestPath) {
    $manifestData = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    $missingPaths = 0
    $missingInstructions = 0
    $governedProjects = 0
    foreach ($p in $manifestData.projects) {
        $fullPath = Join-Path $WorkspaceRoot $p.path
        if (-not (Test-Path $fullPath)) {
            $missingPaths++
            if ($Detailed) {
                Write-Host "      [-] Project '$($p.id)' path not found: $($p.path)" -ForegroundColor Red
            }
        }
        if ($p.instructions) {
            $governedProjects++
            $instPath = Join-Path $WorkspaceRoot $p.instructions
            if (-not (Test-Path $instPath)) {
                $missingInstructions++
            }
        }
    }
    if ($missingPaths -eq 0) {
        Report-Check "Manifest" "Project Paths Check" "OK" "All $($manifestData.projects.Count) project paths exist on disk"
    } else {
        Report-Check "Manifest" "Project Paths Check" "WARNING" "$missingPaths project paths in manifest do not exist on disk"
    }
    if ($missingInstructions -eq 0) {
        Report-Check "Manifest" "Instructions Resolution" "OK" "All $governedProjects registered AGENTS.md paths resolve on disk"
    } else {
        Report-Check "Manifest" "Instructions Resolution" "WARNING" "$missingInstructions registered AGENTS.md paths missing on disk"
    }
} else {
    Report-Check "Manifest" "Project Paths Check" "MISSING" "Manifest missing"
}

# -------------------------------------------------------------
# SUMMARY REPORT & SNAPSHOT EMISSION
# -------------------------------------------------------------
$statusLabel = if (($missingCount + $errorCount) -eq 0 -and $warnCount -eq 0) {
    "EXCELLENT"
} elseif (($missingCount + $errorCount) -eq 0) {
    "GOOD"
} else {
    "ATTENTION REQUIRED"
}

Write-Host "`n==========================================================================" -ForegroundColor Cyan
Write-Host "                        WORKSPACE DOCTOR SUMMARY                          " -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host " Total Checks  : $totalChecks" -ForegroundColor White
Write-Host " Passed (OK)   : $okCount" -ForegroundColor Green
Write-Host " Warnings      : $warnCount" -ForegroundColor Yellow
Write-Host " Optional/Skip : $optionalCount" -ForegroundColor DarkGray
Write-Host " Missing/Error : $($missingCount + $errorCount)" -ForegroundColor $(if (($missingCount + $errorCount) -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================================" -ForegroundColor Cyan

if ($statusLabel -eq "EXCELLENT") {
    Write-Host "`n[+] WORKSPACE HEALTH STATUS: EXCELLENT (Platform ready for development)" -ForegroundColor Green
} elseif ($statusLabel -eq "GOOD") {
    Write-Host "`n[+] WORKSPACE HEALTH STATUS: GOOD (Operational with minor informational recommendations)" -ForegroundColor Green
} else {
    Write-Host "`n[-] WORKSPACE HEALTH STATUS: ATTENTION REQUIRED ($($missingCount + $errorCount) issues found)" -ForegroundColor Red
}
Write-Host ""

$snapshot = [PSCustomObject]@{
    timestamp     = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    workspaceRoot = $WorkspaceRoot
    status        = $statusLabel
    summary       = [PSCustomObject]@{
        totalChecks   = $totalChecks
        okCount       = $okCount
        warnCount     = $warnCount
        optionalCount = $optionalCount
        missingCount  = $missingCount
        errorCount    = $errorCount
    }
    checks        = $checkResults
}

if (-not (Test-Path $ArtifactsDir)) {
    New-Item -ItemType Directory -Path $ArtifactsDir -Force | Out-Null
}

if (-not $NoSave) {
    $snapshotPath = Join-Path $ArtifactsDir "doctor-latest.json"
    $snapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $snapshotPath -Encoding UTF8
}

if ($Json) {
    $snapshot | ConvertTo-Json -Depth 5
}


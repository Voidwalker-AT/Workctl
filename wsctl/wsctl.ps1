<#
.SYNOPSIS
    WSCTL — Workspace Control CLI (wsctl.ps1)
    Engineering Platform Management Frontend for E:\Workspace

.DESCRIPTION
    WSCTL is the dedicated command-line dispatcher and frontend management system
    for the E:\Workspace engineering platform. Provides unified access to platform
    diagnostics, project catalogs, task execution, repository observability,
    storage analysis, and the graphical WSCTL Panel.

    Note: This is strictly 'wsctl' (Workspace Control), distinct from the workstation-level
    'WorkCtl' system.

.EXAMPLE
    .\wsctl.ps1
    .\wsctl.ps1 doctor
    .\wsctl.ps1 projects
    .\wsctl.ps1 project dl-exp1
    .\wsctl.ps1 run dl-exp1 verify
    .\wsctl.ps1 git --dirty
    .\wsctl.ps1 storage --caches
    .\wsctl.ps1 panel
#>

[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Arg1,

    [Parameter(Position = 2)]
    [string]$Arg2,

    [switch]$Json,
    [switch]$Detailed,
    [switch]$Dirty,
    [switch]$Caches,
    [switch]$Environments,
    [int]$Top = 0,
    [string]$Category,
    [string]$Tag,
    [switch]$Force,
    [Alias("y")]
    [switch]$Yes,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Continue"

# Parse POSIX-style double-dash flags if passed
if ($RemainingArgs) {
    if ($RemainingArgs -icontains "--dirty" -or $RemainingArgs -icontains "-dirty") { $Dirty = $true }
    if ($RemainingArgs -icontains "--caches" -or $RemainingArgs -icontains "-caches") { $Caches = $true }
    if ($RemainingArgs -icontains "--envs" -or $RemainingArgs -icontains "-envs" -or $RemainingArgs -icontains "--environments") { $Environments = $true }
    if ($RemainingArgs -icontains "--json" -or $RemainingArgs -icontains "-json") { $Json = $true }
    if ($RemainingArgs -icontains "--detailed" -or $RemainingArgs -icontains "-detailed") { $Detailed = $true }
}

# Establish Workspace Root dynamically
$WorkspaceRoot = $PSScriptRoot
if (-not (Test-Path (Join-Path $WorkspaceRoot "workspace.json"))) {
    $WorkspaceRoot = "E:\Workspace"
}

$SharedDir    = Join-Path $WorkspaceRoot "Shared"
$ScriptsDir   = Join-Path $SharedDir "scripts"
$ArtifactsDir = Join-Path $SharedDir "artifacts"
$WsctlDir     = Join-Path $SharedDir "wsctl"
$ManifestFile = Join-Path $WorkspaceRoot "workspace.json"

function Write-WSHeader {
    Write-Host ""
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "                WSCTL — WORKSPACE CONTROL PLATFORM (v1.0)                 " -ForegroundColor Cyan
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host " Workspace Root : $WorkspaceRoot" -ForegroundColor Gray
    Write-Host " Platform Role  : Local Engineering, AI/ML, Academic & Tooling Hub" -ForegroundColor Gray
    Write-Host " Operating Host : $env:COMPUTERNAME ($([System.Environment]::OSVersion.VersionString))" -ForegroundColor Gray
    Write-Host " Global Command : wsctl (via $env:USERPROFILE\scoop\shims\wsctl.cmd)" -ForegroundColor Gray
    Write-Host "==========================================================================" -ForegroundColor Cyan
}

function Show-WSUsage {
    Write-WSHeader
    Write-Host ""
    Write-Host "Usage: wsctl <command> [arguments] [options]" -ForegroundColor Yellow
    Write-Host "       pwsh -File E:\Workspace\wsctl.ps1 <command>  (Direct script fallback)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Platform Commands:" -ForegroundColor White
    Write-Host "  info                  Display platform architecture, paths, and environment summary" -ForegroundColor Cyan
    Write-Host "  doctor                Run platform diagnostics (toolchains, CUDA, runtimes, caches)" -ForegroundColor Cyan
    Write-Host "  projects              Catalog all registered workspace projects (filter by category/tag)" -ForegroundColor Cyan
    Write-Host "  project <id>          Inspect a specific project manifest, environment & commands" -ForegroundColor Cyan
    Write-Host "  run <id> <cmd>        Execute a registered command inside a project environment" -ForegroundColor Cyan
    Write-Host "  git                   Scan all Git repositories (read-only tracking refs check)" -ForegroundColor Cyan
    Write-Host "  storage               Analyze workspace storage allocation and development caches" -ForegroundColor Cyan
    Write-Host "  bootstrap             Run non-destructive platform bootstrap & environment check" -ForegroundColor Cyan
    Write-Host "  panel, ui             Launch the graphical WSCTL Panel (Python Tkinter/ttk)" -ForegroundColor Cyan
    Write-Host "  help                  Show this help overview" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Options:" -ForegroundColor White
    Write-Host "  -Json, --json         Emit machine-readable JSON output (available on most commands)" -ForegroundColor Gray
    Write-Host "  -Detailed, --detailed Show expanded diagnostic details (used with 'doctor')" -ForegroundColor Gray
    Write-Host "  -Dirty, --dirty       Filter Git status to dirty repositories only" -ForegroundColor Gray
    Write-Host "  -Caches, --caches     Inspect centralized development & model caches (used with 'storage')" -ForegroundColor Gray
    Write-Host "  -Environments, --envs Inspect discovered virtual environments (used with 'storage')" -ForegroundColor Gray
    Write-Host "  -Force, -y            Bypass execution confirmation prompt on project commands" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Quick Examples:" -ForegroundColor DarkGray
    Write-Host "  wsctl doctor -Json              Get platform health snapshot in JSON" -ForegroundColor DarkGray
    Write-Host "  wsctl run dl-exp1 dashboard     Launch MNIST MLP Interactive Dashboard" -ForegroundColor DarkGray
    Write-Host "  wsctl panel                     Launch graphical management control center" -ForegroundColor DarkGray
    Write-Host ""
}

# -------------------------------------------------------------
# COMMAND DISPATCHER
# -------------------------------------------------------------
switch ($Command.ToLower()) {

    "" {
        # Default Overview
        Write-WSHeader
        
        # Load Manifest
        $projCount = 0
        if (Test-Path $ManifestFile) {
            try {
                $m = Get-Content $ManifestFile -Raw | ConvertFrom-Json
                $projCount = $m.projects.Count
            } catch {}
        }

        # Load Health Cache
        $healthStatus = "UNKNOWN"
        $healthColor = "Yellow"
        $doctorCache = Join-Path $ArtifactsDir "doctor-latest.json"
        if (Test-Path $doctorCache) {
            try {
                $doc = Get-Content $doctorCache -Raw | ConvertFrom-Json
                $healthStatus = $doc.status
                if ($healthStatus -eq "EXCELLENT" -or $healthStatus -eq "GOOD") { $healthColor = "Green" }
                else { $healthColor = "Red" }
            } catch {}
        }

        # Load Git Cache
        $gitSummary = "64 Repositories"
        $gitCache = Join-Path $ArtifactsDir "git-status-latest.json"
        if (Test-Path $gitCache) {
            try {
                $g = Get-Content $gitCache -Raw | ConvertFrom-Json
                $gitSummary = "$($g.summary.totalRepositories) Repos ($($g.summary.dirtyRepositories) dirty)"
            } catch {}
        }

        # Load Storage Cache
        $storageSummary = "~31.8 GB"
        $storageCache = Join-Path $ArtifactsDir "storage-latest.json"
        if (Test-Path $storageCache) {
            try {
                $s = Get-Content $storageCache -Raw | ConvertFrom-Json
                $storageSummary = $s.totalWorkspaceSize
            } catch {}
        }

        Write-Host " Status Overview:" -ForegroundColor Yellow
        Write-Host "  • Registered Projects : $projCount projects cataloged in workspace.json" -ForegroundColor White
        Write-Host "  • Platform Health     : " -NoNewline -ForegroundColor White
        Write-Host "[$healthStatus]" -ForegroundColor $healthColor
        Write-Host "  • Git Tracking        : $gitSummary" -ForegroundColor White
        Write-Host "  • Workspace Storage   : $storageSummary total usage" -ForegroundColor White
        Write-Host "  • GPU Architecture    : RTX 2050 (4 GB VRAM) | CUDA Toolkit 11.8 | Driver 596.49" -ForegroundColor White
        Write-Host ""
        Write-Host " Essential Commands:" -ForegroundColor Yellow
        Write-Host "  wsctl panel                     Launch graphical WSCTL Control Center" -ForegroundColor Cyan
        Write-Host "  wsctl doctor                    Run full 38-point platform diagnostic" -ForegroundColor Cyan
        Write-Host "  wsctl projects                  List all 26 cataloged projects" -ForegroundColor Cyan
        Write-Host "  wsctl run dl-exp1 dashboard     Open Deep Learning Exp 1 Dashboard" -ForegroundColor Cyan
        Write-Host "  wsctl help                      View complete command reference" -ForegroundColor Gray
        Write-Host ""
    }

    "help" {
        Show-WSUsage
    }

    "info" {
        if ($Json) {
            $manifestData = if (Test-Path $ManifestFile) { Get-Content $ManifestFile -Raw | ConvertFrom-Json } else { $null }
            $doctorData = $null
            $docCache = Join-Path $ArtifactsDir "doctor-latest.json"
            if (Test-Path $docCache) { $doctorData = Get-Content $docCache -Raw | ConvertFrom-Json }

            $infoObj = [PSCustomObject]@{
                workspaceName = "Workspace"
                workspaceRoot = $WorkspaceRoot
                canonicalDrive = "E:\"
                sharedDir     = $SharedDir
                docsDir       = Join-Path $WorkspaceRoot "docs"
                modelsDir     = "E:\AI_Models"
                uvCacheDir    = "C:\Users\hp\scoop\persist\uv\cache"
                operatingHost = $env:COMPUTERNAME
                operatingSystem = [System.Environment]::OSVersion.VersionString
                projectsCount = if ($manifestData) { $manifestData.projects.Count } else { 0 }
                healthStatus  = if ($doctorData) { $doctorData.status } else { "UNKNOWN" }
                lastAudit     = if ($doctorData) { $doctorData.timestamp } else { $null }
            }
            $infoObj | ConvertTo-Json -Depth 4
        } else {
            Write-WSHeader
            Write-Host "Platform Infrastructure Architecture:" -ForegroundColor Yellow
            Write-Host "  Workspace Root       : $WorkspaceRoot" -ForegroundColor White
            Write-Host "  Shared Layer         : $SharedDir" -ForegroundColor White
            Write-Host "  Governance Docs      : $(Join-Path $WorkspaceRoot 'docs')" -ForegroundColor White
            Write-Host "  Operating Contract   : $(Join-Path $WorkspaceRoot 'AGENTS.md')" -ForegroundColor White
            Write-Host "  External AI Models   : E:\AI_Models (OLLAMA, GGUF, HF_CACHE)" -ForegroundColor White
            Write-Host "  Astral UV Cache      : C:\Users\hp\scoop\persist\uv\cache (SSD)" -ForegroundColor White
            Write-Host "  VS Code Workspace    : $(Join-Path $WorkspaceRoot 'Workspace.code-workspace')" -ForegroundColor White
            Write-Host ""
            Write-Host "Run '.\wsctl.ps1 doctor' for full runtime diagnostic." -ForegroundColor DarkGray
            Write-Host ""
        }
    }

    "doctor" {
        $docScript = Join-Path $ScriptsDir "workspace-doctor.ps1"
        $params = @{ WorkspaceRoot = $WorkspaceRoot }
        if ($Detailed) { $params["Detailed"] = $true }
        if ($Json)     { $params["Json"] = $true }
        
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $docScript @params
    }

    "projects" {
        if ($Json) {
            if (Test-Path $ManifestFile) {
                $m = Get-Content $ManifestFile -Raw | ConvertFrom-Json
                $res = $m.projects
                if ($Category) { $res = $res | Where-Object { $_.category -ieq $Category } }
                if ($Tag) { $res = $res | Where-Object { $_.tags -icontains $Tag } }
                $res | ConvertTo-Json -Depth 5
            }
        } else {
            $projScript = Join-Path $ScriptsDir "workspace-projects.ps1"
            $params = @{ WorkspaceRoot = $WorkspaceRoot }
            if ($Category) { $params["Category"] = $Category }
            if ($Tag)      { $params["Tag"] = $Tag }
            
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $projScript @params
        }
    }

    "project" {
        $targetName = if ($Arg1) { $Arg1 } else {
            Write-Host "[-] Missing project ID. Usage: .\wsctl.ps1 project <id>" -ForegroundColor Red
            exit 1
        }

        if ($Json) {
            if (Test-Path $ManifestFile) {
                $m = Get-Content $ManifestFile -Raw | ConvertFrom-Json
                $target = $m.projects | Where-Object { $_.id -ieq $targetName -or $_.name -ilike "*$targetName*" } | Select-Object -First 1
                if ($target) {
                    $target | ConvertTo-Json -Depth 5
                } else {
                    Write-Error "Project '$targetName' not found"
                }
            }
        } else {
            $projScript = Join-Path $ScriptsDir "workspace-projects.ps1"
            & pwsh -NoProfile -ExecutionPolicy Bypass -File $projScript -WorkspaceRoot $WorkspaceRoot -Name $targetName
        }
    }

    "run" {
        $targetName = $Arg1
        $cmdName    = $Arg2

        if (-not $targetName -or -not $cmdName) {
            Write-Host "[-] Usage: .\wsctl.ps1 run <project-id> <command-name>" -ForegroundColor Red
            Write-Host "    Example: .\wsctl.ps1 run dl-exp1 dashboard" -ForegroundColor Gray
            exit 1
        }

        $projScript = Join-Path $ScriptsDir "workspace-projects.ps1"
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $projScript -WorkspaceRoot $WorkspaceRoot -Name $targetName -Run $cmdName
        exit $LASTEXITCODE
    }

    "git" {
        $gitScript = Join-Path $ScriptsDir "workspace-git-status.ps1"
        $params = @{ WorkspaceRoot = $WorkspaceRoot }
        if ($Dirty) { $params["DirtyOnly"] = $true }
        if ($Json)  { $params["Json"] = $true }

        & pwsh -NoProfile -ExecutionPolicy Bypass -File $gitScript @params
    }

    "storage" {
        $storageScript = Join-Path $ScriptsDir "workspace-storage.ps1"
        $params = @{ WorkspaceRoot = $WorkspaceRoot }
        if ($Caches)       { $params["Caches"] = $true }
        if ($Environments) { $params["Environments"] = $true }
        if ($Top -gt 0)    { $params["Top"] = $Top }
        if ($Json)         { $params["Json"] = $true }

        & pwsh -NoProfile -ExecutionPolicy Bypass -File $storageScript @params
    }

    "bootstrap" {
        $bootScript = Join-Path $ScriptsDir "bootstrap-workspace.ps1"
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $bootScript -WorkspaceRoot $WorkspaceRoot
    }

    { $_ -in @("panel", "ui") } {
        $panelScript = Join-Path $WsctlDir "panel.py"
        if (-not (Test-Path $panelScript)) {
            Write-Host "[-] WSCTL Panel script not found at: $panelScript" -ForegroundColor Red
            exit 1
        }

        # Find best Python interpreter with tkinter
        $pyCandidates = @(
            "C:\Users\hp\AppData\Local\Programs\Python\Python313\pythonw.exe",
            "C:\Users\hp\AppData\Local\Programs\Python\Python313\python.exe",
            (Join-Path $SharedDir "envs\ds-base\Scripts\pythonw.exe"),
            (Join-Path $SharedDir "envs\ds-base\Scripts\python.exe"),
            "pythonw",
            "python"
        )

        $pyExe = $null
        foreach ($c in $pyCandidates) {
            if (Test-Path $c -ErrorAction SilentlyContinue) {
                $pyExe = $c
                break
            }
        }

        if (-not $pyExe) {
            $pyExe = "python"
        }

        Write-Host "[*] Launching WSCTL Control Center via: $pyExe $panelScript ..." -ForegroundColor Cyan
        Start-Process -FilePath $pyExe -ArgumentList "`"$panelScript`"" -WorkingDirectory $WorkspaceRoot
    }

    default {
        Write-Host "[-] Unknown command '$Command'." -ForegroundColor Red
        Write-Host "    Run 'wsctl help' for list of available commands." -ForegroundColor Gray
        exit 1
    }
}

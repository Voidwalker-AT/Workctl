<#
.SYNOPSIS
    Interactively prepares and archives a project to the canonical E:\ARCHIVE destination.

.DESCRIPTION
    This script is designed for the manual, interactive archival of projects from
    E:\Workspace. It generates an inventory of the project, asks the user for confirmation
    before stripping heavy dependencies (node_modules, .venv, .gradle), and safely moves
    the project to E:\ARCHIVE.

.PARAMETER TargetProject
    The path to the project directory to archive.

.PARAMETER DryRun
    If set, the script will simulate the process without making any changes.
#>

param (
    [Parameter(Mandatory=$true, HelpMessage="Path to the project you want to archive.")]
    [string]$TargetProject,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$CanonicalArchive = "E:\ARCHIVE"
$HeavyDependencies = @("node_modules", ".venv", ".gradle", "build", "dist")

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Write-Pass {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

Write-Host "=============================================" -ForegroundColor Magenta
Write-Host "      Interactive Project Archiver           " -ForegroundColor Magenta
Write-Host "=============================================" -ForegroundColor Magenta

if ($DryRun) {
    Write-Warn ">>> RUNNING IN DRY-RUN MODE - NO CHANGES WILL BE MADE <<<"
}

# Validate Target
if (-Not (Test-Path $TargetProject)) {
    Write-Host "[-] Target project path does not exist: $TargetProject" -ForegroundColor Red
    exit
}

$projectItem = Get-Item $TargetProject
if (-Not $projectItem.PSIsContainer) {
    Write-Host "[-] Target must be a directory." -ForegroundColor Red
    exit
}

# 1. Generate Inventory
Write-Step "Generating Project Inventory..."
$heavyFoldersFound = @()

foreach ($dep in $HeavyDependencies) {
    $depPath = Join-Path $TargetProject $dep
    if (Test-Path $depPath) {
        $heavyFoldersFound += $depPath
    }
}

if ($heavyFoldersFound.Count -gt 0) {
    Write-Warn "Found heavy dependencies that should be stripped before archival:"
    foreach ($folder in $heavyFoldersFound) {
        Write-Host "    - $folder" -ForegroundColor DarkGray
    }
} else {
    Write-Pass "No standard heavy dependencies found in project."
}

# 2. Interactive Prompts
if (-Not $DryRun) {
    if ($heavyFoldersFound.Count -gt 0) {
        $response = Read-Host "Do you want to permanently DELETE these heavy dependencies before moving? (y/n)"
        if ($response -match "^y" -or $response -match "^Y") {
            Write-Step "Stripping heavy dependencies..."
            foreach ($folder in $heavyFoldersFound) {
                Remove-Item -Path $folder -Recurse -Force
                Write-Pass "Removed $folder"
            }
        } else {
            Write-Warn "Skipping dependency cleanup."
        }
    }

    # Select Sub-Archive
    Write-Host ""
    Write-Host ("Select the appropriate destination in {0}:" -f $CanonicalArchive)
    Write-Host "  1) LegacyProjects"
    Write-Host "  2) DormantProjects"
    Write-Host "  3) OldExperiments"
    Write-Host "  4) DeprecatedTools"
    $choice = Read-Host "Enter number (1-4)"

    $subDir = ""
    switch ($choice) {
        "1" { $subDir = "LegacyProjects" }
        "2" { $subDir = "DormantProjects" }
        "3" { $subDir = "OldExperiments" }
        "4" { $subDir = "DeprecatedTools" }
        default { 
            Write-Warn "Invalid choice. Aborting."
            exit
        }
    }

    $finalDest = Join-Path $CanonicalArchive $subDir
    if (-Not (Test-Path $finalDest)) {
        New-Item -Path $finalDest -ItemType Directory -Force | Out-Null
    }

    $destPath = Join-Path $finalDest $projectItem.Name

    if (Test-Path $destPath) {
        Write-Warn "Destination already exists: $destPath"
        $ovr = Read-Host "Do you want to overwrite it? (y/n)"
        if ($ovr -notmatch "^y" -and $ovr -notmatch "^Y") {
            Write-Warn "Aborting archive operation."
            exit
        }
    }

    Write-Step "Moving project to $destPath ..."
    Move-Item -Path $TargetProject -Destination $finalDest -Force
    Write-Pass "Project successfully archived to: $destPath"

} else {
    # Dry Run Output
    Write-Host ""
    Write-Host "[DRY RUN] Would prompt to delete heavy dependencies if any were found."
    Write-Host "[DRY RUN] Would prompt user to select a sub-directory in $CanonicalArchive."
    Write-Host "[DRY RUN] Would move $TargetProject to selected archive destination."
    Write-Pass "[DRY RUN] Completed without making changes."
}

Write-Host "=============================================" -ForegroundColor Magenta

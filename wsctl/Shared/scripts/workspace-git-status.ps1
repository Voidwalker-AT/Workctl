<#
.SYNOPSIS
    Workspace Git Status Scanner (workspace-git-status.ps1)

.DESCRIPTION
    Read-only repository scanner across E:\Workspace.
    Finds all Git repositories and reports branch, working tree state (clean/dirty),
    untracked file count, and local ahead/behind commits relative to existing tracking refs.
    
    CRITICAL: Does NOT execute 'git fetch', 'git pull', or modify any repository state.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\workspace-git-status.ps1
    powershell -ExecutionPolicy Bypass -File .\workspace-git-status.ps1 -DirtyOnly
#>

[CmdletBinding()]
param (
    [switch]$DirtyOnly,
    [switch]$Json,
    [switch]$NoSave,
    [string]$WorkspaceRoot = "E:\Workspace"
)

$ErrorActionPreference = "Continue"

function Write-Host {
    if (-not $Json) {
        Microsoft.PowerShell.Utility\Write-Host @args
    }
}

if (-not (Test-Path $WorkspaceRoot)) {
    $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

Write-Host ""
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host "                    WORKSPACE GIT REPOSITORY SCANNER                      " -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host " Root Directory: $WorkspaceRoot" -ForegroundColor Gray
Write-Host " Scan Mode     : Read-Only (Local tracking refs only; no network operations)" -ForegroundColor Gray
Write-Host " Timestamp     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host ""

# Fast discovery of .git directories excluding known heavy folders
$gitDirs = Get-ChildItem -Path $WorkspaceRoot -Recurse -Directory -Filter ".git" -Force -ErrorAction SilentlyContinue | Where-Object {
    $_.FullName -notmatch "node_modules|\.venv|venv|envs|Shared\\cache"
}

$repoSummaries = @()

foreach ($g in $gitDirs) {
    $repoPath = $g.Parent.FullName
    $relPath = if ($repoPath.Length -gt $WorkspaceRoot.Length) {
        $repoPath.Substring($WorkspaceRoot.Length).TrimStart('\', '/')
    } else {
        "."
    }

    Push-Location $repoPath
    try {
        # Current Branch
        $branch = (& git branch --show-current 2>$null).Trim()
        if ([string]::IsNullOrEmpty($branch)) {
            $branch = (& git rev-parse --short HEAD 2>$null).Trim()
            if ($branch) { $branch = "HEAD ($branch)" } else { $branch = "empty" }
        }

        # Status porcelain
        $statusOut = & git status --porcelain=v1 2>$null
        $modifiedCount = 0
        $untrackedCount = 0

        if ($statusOut) {
            foreach ($line in $statusOut) {
                if ($line -match "^\?\?") {
                    $untrackedCount++
                } else {
                    $modifiedCount++
                }
            }
        }

        $isDirty = ($modifiedCount -gt 0 -or $untrackedCount -gt 0)
        $cleanStatus = if ($isDirty) { "Dirty" } else { "Clean" }

        # Ahead / Behind
        $ahead = "0"
        $behind = "0"
        $upstream = & git rev-parse --abbrev-ref '@{u}' 2>$null
        if ($upstream -and $upstream -notmatch "fatal") {
            $counts = & git rev-list --left-right --count "$upstream...HEAD" 2>$null
            if ($counts -match "(\d+)\s+(\d+)") {
                $behind = $matches[1]
                $ahead = $matches[2]
            }
        } else {
            $ahead = "N/A"
            $behind = "N/A"
        }

        if ($DirtyOnly -and -not $isDirty) {
            continue
        }

        $repoSummaries += [PSCustomObject]@{
            Repository = $relPath
            Branch     = $branch
            State      = $cleanStatus
            Modified   = $modifiedCount
            Untracked  = $untrackedCount
            Ahead      = $ahead
            Behind     = $behind
        }
    } finally {
        Pop-Location
    }
}

$dirtyRepos = $repoSummaries | Where-Object { $_.State -eq "Dirty" }

if (-not $Json) {
    if ($repoSummaries.Count -gt 0) {
        $repoSummaries | Format-Table -AutoSize
    } else {
        Write-Host "No Git repositories matching criteria were found." -ForegroundColor Yellow
    }

    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host " Summary: $($repoSummaries.Count) repositories scanned | $($dirtyRepos.Count) dirty" -ForegroundColor Gray
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host ""
}

$ArtifactsDir = Join-Path $WorkspaceRoot "Shared\artifacts"
if (-not (Test-Path $ArtifactsDir)) {
    New-Item -ItemType Directory -Path $ArtifactsDir -Force | Out-Null
}

$snapshot = [PSCustomObject]@{
    timestamp     = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    workspaceRoot = $WorkspaceRoot
    summary       = [PSCustomObject]@{
        totalRepositories = $repoSummaries.Count
        dirtyRepositories = $dirtyRepos.Count
        cleanRepositories = ($repoSummaries.Count - $dirtyRepos.Count)
    }
    repositories  = $repoSummaries
}

if (-not $NoSave) {
    $snapshotPath = Join-Path $ArtifactsDir "git-status-latest.json"
    $snapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $snapshotPath -Encoding UTF8
}

if ($Json) {
    $snapshot | ConvertTo-Json -Depth 5
}


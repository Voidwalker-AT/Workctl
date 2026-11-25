<#
.SYNOPSIS
    Workspace Storage & Cache Observability Scanner (workspace-storage.ps1)

.DESCRIPTION
    Read-only storage analyzer for E:\Workspace and associated development caches.
    Reports top-level storage allocation, largest directories, isolated virtual environment sizes,
    and centralized package/model caches (UV, Ollama, Go, Pip).

.EXAMPLE
    # Default top-level storage overview
    .\workspace-storage.ps1

    # Show isolated environment sizes
    .\workspace-storage.ps1 -Environments

    # Show centralized package and model cache sizes
    .\workspace-storage.ps1 -Caches

    # Show top 15 largest project directories
    .\workspace-storage.ps1 -Top 15
#>

[CmdletBinding()]
param (
    [int]$Top = 0,
    [switch]$Environments,
    [switch]$Caches,
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

function Format-Size {
    param ([double]$Bytes)
    if ($Bytes -ge 1GB) {
        return "$([math]::Round($Bytes / 1GB, 2)) GB"
    } elseif ($Bytes -ge 1MB) {
        return "$([math]::Round($Bytes / 1MB, 2)) MB"
    } elseif ($Bytes -ge 1KB) {
        return "$([math]::Round($Bytes / 1KB, 2)) KB"
    } else {
        return "$Bytes B"
    }
}

Write-Host ""
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host "                 WORKSPACE STORAGE & CACHE OBSERVABILITY                  " -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host " Root Directory: $WorkspaceRoot" -ForegroundColor Gray
Write-Host " Timestamp     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------------------------
# MODE: CACHES
# -------------------------------------------------------------
if ($Caches) {
    Write-Host "Centralized Development Caches & Model Storage:" -ForegroundColor Yellow
    Write-Host ""

    $cacheTargets = @(
        @{ Name = "Astral UV Shared Cache"; Path = "C:\Users\hp\scoop\persist\uv\cache"; Type = "Python Wheels (SSD)"; Recommended = "Active Canonical" },
        @{ Name = "Ollama Foundation Models"; Path = "E:\AI_Models\OLLAMA"; Type = "AI Model Blobs (E:)"; Recommended = "Active Canonical" },
        @{ Name = "GGUF Standalone Models"; Path = "E:\AI_Models\GGUF"; Type = "llama.cpp Weights"; Recommended = "Ready" },
        @{ Name = "Hugging Face Cache"; Path = "E:\AI_Models\HF_CACHE"; Type = "Transformer Weights"; Recommended = "Designated (HF_HOME)" },
        @{ Name = "User Pip Cache"; Path = "$env:LOCALAPPDATA\pip\cache"; Type = "Pip Legacy Cache"; Recommended = "Active" },
        @{ Name = "Go Module Cache"; Path = "C:\Users\hp\go\pkg\mod"; Type = "Go Modules"; Recommended = "Active Canonical" },
        @{ Name = "npm Global Cache"; Path = "$env:LOCALAPPDATA\npm-cache"; Type = "npm Tarballs"; Recommended = "Active" }
    )

    $cacheResults = foreach ($ct in $cacheTargets) {
        $sizeBytes = 0
        $fileCount = 0
        if (Test-Path $ct.Path) {
            $files = Get-ChildItem -Path $ct.Path -Recurse -File -Force -ErrorAction SilentlyContinue
            $meas = $files | Measure-Object -Property Length -Sum
            if ($meas.Sum) { $sizeBytes = $meas.Sum }
            $fileCount = $files.Count
        }
        [PSCustomObject]@{
            CacheName     = $ct.Name
            StoragePath   = $ct.Path
            Files         = $fileCount
            Size          = Format-Size $sizeBytes
            Role          = $ct.Type
            Status        = $ct.Recommended
        }
    }

    if ($Json) {
        $cacheResults | ConvertTo-Json -Depth 5
    } else {
        $cacheResults | Format-Table -AutoSize
        Write-Host "==========================================================================" -ForegroundColor Cyan
    }
    exit 0
}

# -------------------------------------------------------------
# MODE: ENVIRONMENTS
# -------------------------------------------------------------
if ($Environments) {
    Write-Host "Discovered Project Virtual Environments:" -ForegroundColor Yellow
    Write-Host ""

    $cfgs = Get-ChildItem -Path $WorkspaceRoot -Recurse -Filter "pyvenv.cfg" -Force -ErrorAction SilentlyContinue
    $envResults = foreach ($c in $cfgs) {
        $parent = $c.Directory
        $pyVer = "Unknown"
        $lines = Get-Content $c.FullName -ErrorAction SilentlyContinue
        $vl = $lines | Where-Object { $_ -match "^version\s*=" }
        if ($vl) { $pyVer = ($vl -split '=', 2)[1].Trim() }
        
        $files = Get-ChildItem -Path $parent.FullName -Recurse -File -Force -ErrorAction SilentlyContinue
        $meas = $files | Measure-Object -Property Length -Sum
        $size = if ($meas.Sum) { $meas.Sum } else { 0 }

        $rel = $parent.FullName.Substring($WorkspaceRoot.Length).TrimStart('\', '/')
        [PSCustomObject]@{
            EnvironmentPath = $rel
            PythonVersion   = $pyVer
            Files           = $files.Count
            SizeBytes       = $size
            FormattedSize   = Format-Size $size
        }
    }

    if ($Json) {
        $envResults | ConvertTo-Json -Depth 5
    } else {
        $envResults | Sort-Object -Property SizeBytes -Descending | Select-Object EnvironmentPath, PythonVersion, Files, FormattedSize | Format-Table -AutoSize
        Write-Host "==========================================================================" -ForegroundColor Cyan
    }
    exit 0
}

# -------------------------------------------------------------
# MODE: TOP-LEVEL SUMMARY / TOP DIRECTORIES
# -------------------------------------------------------------
$dirs = Get-ChildItem -Path $WorkspaceRoot -Force
$topLevel = foreach ($d in $dirs) {
    if ($d.PSIsContainer) {
        $files = Get-ChildItem -Path $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue
        $meas = $files | Measure-Object -Property Length -Sum
        $size = if ($meas.Sum) { $meas.Sum } else { 0 }
        [PSCustomObject]@{
            Name      = $d.Name
            Type      = "Directory"
            Files     = $files.Count
            SizeBytes = $size
            Size      = Format-Size $size
            RawMB     = [math]::Round($size / 1MB, 2)
            RawGB     = [math]::Round($size / 1GB, 2)
        }
    } else {
        [PSCustomObject]@{
            Name      = $d.Name
            Type      = "File"
            Files     = 1
            SizeBytes = $d.Length
            Size      = Format-Size $d.Length
            RawMB     = [math]::Round($d.Length / 1MB, 4)
            RawGB     = [math]::Round($d.Length / 1GB, 6)
        }
    }
}

$totalWorkspaceBytes = ($topLevel | Measure-Object -Property SizeBytes -Sum).Sum

if (-not $Json) {
    if ($Top -gt 0) {
        Write-Host "Top $Top Largest Items in Workspace:" -ForegroundColor Yellow
        Write-Host ""
        $topLevel | Sort-Object -Property SizeBytes -Descending | Select-Object -First $Top | `
            Select-Object Name, Type, Files, Size | Format-Table -AutoSize
    } else {
        Write-Host "Top-Level Workspace Allocation:" -ForegroundColor Yellow
        Write-Host ""
        $topLevel | Sort-Object -Property SizeBytes -Descending | ForEach-Object {
            $pct = if ($totalWorkspaceBytes -gt 0) { [math]::Round(($_.SizeBytes / $totalWorkspaceBytes) * 100, 1) } else { 0 }
            [PSCustomObject]@{
                Name       = $_.Name
                Type       = $_.Type
                Files      = $_.Files
                Size       = $_.Size
                Percentage = "$pct %"
            }
        } | Format-Table -AutoSize
    }

    Write-Host "--------------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host " TOTAL WORKSPACE USAGE: $(Format-Size $totalWorkspaceBytes)" -ForegroundColor Green
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host ""
}

$ArtifactsDir = Join-Path $WorkspaceRoot "Shared\artifacts"
if (-not (Test-Path $ArtifactsDir)) {
    New-Item -ItemType Directory -Path $ArtifactsDir -Force | Out-Null
}

$snapshot = [PSCustomObject]@{
    timestamp           = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    workspaceRoot       = $WorkspaceRoot
    totalWorkspaceBytes = $totalWorkspaceBytes
    totalWorkspaceSize  = Format-Size $totalWorkspaceBytes
    topLevel            = $topLevel
}

if (-not $NoSave) {
    $snapshotPath = Join-Path $ArtifactsDir "storage-latest.json"
    $snapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $snapshotPath -Encoding UTF8
}

if ($Json) {
    $snapshot | ConvertTo-Json -Depth 5
}


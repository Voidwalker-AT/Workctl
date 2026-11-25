<#
.SYNOPSIS
    Generates an inventory report of the E:\Workspace directory.

.DESCRIPTION
    Scans the workspace for large directories, specifically identifying heavy 
    dependency folders like node_modules, .venv, and .gradle inside Experiments/ and Active/.
    Useful for identifying candidates for archival or cleanup.
#>

$ErrorActionPreference = "Stop"

$WorkspaceRoot = "E:\Workspace"
$TargetDirs = @("$WorkspaceRoot\Active", "$WorkspaceRoot\Experiments", "$WorkspaceRoot\Projects")
$HeavyFolderNames = @("node_modules", ".venv", ".gradle", "build", "dist")

function Write-Header {
    param([string]$Message)
    Write-Host ""
    Write-Host "--- $Message ---" -ForegroundColor Cyan
}

function Get-FolderCapabilities {
    param([string]$Path)
    $parent = Split-Path $Path -Parent
    $name = Split-Path $Path -Leaf
    
    if ($name -eq "node_modules") {
        $pkgPath = Join-Path $parent "package.json"
        if (Test-Path $pkgPath) {
            try {
                $pkg = Get-Content $pkgPath | ConvertFrom-Json
                $deps = @()
                if ($pkg.dependencies) { $deps += $pkg.dependencies.PSObject.Properties.Name }
                if ($pkg.devDependencies) { $deps += $pkg.devDependencies.PSObject.Properties.Name }
                if ($deps.Count -gt 0) {
                    return ($deps | Sort-Object -Unique) -join ", "
                }
            } catch {}
        }
    } elseif ($name -eq ".venv" -or $Path -like "*site-packages*") {
        $reqPath = Join-Path $parent "requirements.txt"
        if (-not (Test-Path $reqPath)) {
            $reqPath = Join-Path (Split-Path $parent -Parent) "requirements.txt"
        }
        if (Test-Path $reqPath) {
            $reqs = Get-Content $reqPath | Where-Object { $_ -match "^[a-zA-Z0-9_\-]+" } | ForEach-Object { $_.Split("=")[0].Split(">")[0].Split("<")[0].Trim() }
            if ($reqs.Count -gt 0) {
                return ($reqs | Sort-Object -Unique) -join ", "
            }
        }
        # Fallback: check pyproject.toml
        $pyProj = Join-Path $parent "pyproject.toml"
        if (Test-Path $pyProj) {
            return "Configured via pyproject.toml"
        }
    }
    return "Unknown capabilities (No metadata found)"
}

Write-Host "=============================================" -ForegroundColor Magenta
Write-Host "  Workspace Inventory & Disk Usage Auditor" -ForegroundColor Magenta
Write-Host "=============================================" -ForegroundColor Magenta

Write-Header "Scanning for Heavy Dependency Folders..."

$heavyFoldersFound = @()

foreach ($dir in $TargetDirs) {
    if (Test-Path $dir) {
        # Find all matching directories
        $found = Get-ChildItem -Path $dir -Directory -Recurse -ErrorAction SilentlyContinue | Where-Object { $HeavyFolderNames -contains $_.Name }
        
        # Filter out nested directories (e.g. node_modules inside node_modules)
        foreach ($item in $found) {
            $isNested = $false
            $parent = $item.Parent
            while ($parent -ne $null -and $parent.FullName.StartsWith($dir)) {
                if ($HeavyFolderNames -contains $parent.Name) {
                    $isNested = $true
                    break
                }
                $parent = $parent.Parent
            }
            if (-not $isNested) {
                $heavyFoldersFound += $item
            }
        }
    }
}

if ($heavyFoldersFound.Count -eq 0) {
    Write-Host "[+] No heavy dependency folders found. Workspace is clean." -ForegroundColor Green
} else {
    Write-Host "[!] Found $($heavyFoldersFound.Count) heavy dependency folders:" -ForegroundColor Yellow
    
    # Calculate sizes and get capabilities
    foreach ($folder in $heavyFoldersFound) {
        $sizeBytes = (Get-ChildItem -Path $folder.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $sizeMB = [math]::Round($sizeBytes / 1MB, 2)
        $caps = Get-FolderCapabilities -Path $folder.FullName
        
        if ($sizeMB -gt 100) {
            Write-Host "`n    [!] $($folder.FullName)" -ForegroundColor Red
        } else {
            Write-Host "`n    [*] $($folder.FullName)" -ForegroundColor Yellow
        }
        Write-Host "        Size: $sizeMB MB" -ForegroundColor Gray
        Write-Host "        Libs: $caps" -ForegroundColor DarkGray
    }
}

Write-Header "Checking Shared Envs..."
$envsPath = "$WorkspaceRoot\Shared\envs"
if (Test-Path $envsPath) {
    $envs = Get-ChildItem -Path $envsPath -Directory
    if ($envs.Count -gt 0) {
        Write-Host "Centralized Environments Found: $($envs.Count)" -ForegroundColor Cyan
        
        $showDetails = Read-Host "Show detailed environment information? (y/N)"
        if ($showDetails -eq "y") {
            foreach ($env in $envs) {
                Write-Host "`n--- [$($env.Name)] ---" -ForegroundColor Green
                Write-Host "Path:       $($env.FullName)" -ForegroundColor Gray
                
                # Try to extract description from README.md
                $readmePath = Join-Path $env.FullName "README.md"
                if (Test-Path $readmePath) {
                    $readme = Get-Content $readmePath -Raw
                    # Try to find Domain or first paragraph
                    if ($readme -match "(?m)^>\s*\*\*Domain:\*\*\s*(.*)$") {
                        Write-Host "Capabilities: $($Matches[1].Trim())" -ForegroundColor White
                    } elseif ($readme -match "(?m)^(?!\s*#|\s*>|\s*$)(.*)") {
                        Write-Host "Capabilities: $($Matches[1].Trim())" -ForegroundColor White
                    }
                } else {
                    Write-Host "Capabilities: No README.md found for this environment." -ForegroundColor DarkGray
                }
                
                # Extract library info for capabilities
                $reqPath = Join-Path $env.FullName "requirements.txt"
                if (Test-Path $reqPath) {
                    $reqs = Get-Content $reqPath | Where-Object { $_ -match "^[a-zA-Z0-9_\-]+" } | ForEach-Object { $_.Split("=")[0].Split(">")[0].Split("<")[0].Trim() }
                    $libSummary = ($reqs | Sort-Object -Unique) -join ", "
                    Write-Host "Libraries:   $libSummary" -ForegroundColor DarkCyan
                }

                # Activation instruction
                $activatePath = Join-Path $env.FullName "Scripts\Activate.ps1"
                if (Test-Path $activatePath) {
                    Write-Host "Activation:  & `"$activatePath`"" -ForegroundColor Yellow
                } else {
                    Write-Host "Activation:  Manual activation required (Scripts\Activate.ps1 not found)." -ForegroundColor DarkGray
                }
            }
        } else {
            foreach ($env in $envs) {
                Write-Host "    $($env.Name)" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "No centralized environments found in Shared\envs." -ForegroundColor DarkGray
    }
} else {
    Write-Host "Shared\envs directory does not exist." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Inventory scan complete. Review red items for potential archival." -ForegroundColor Magenta
Write-Host "=============================================" -ForegroundColor Magenta

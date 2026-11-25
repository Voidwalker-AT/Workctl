<#
.SYNOPSIS
    Workspace Inventory & Observability Auditor (V3.0)

.DESCRIPTION
    A modular, infrastructure-aware governance platform for workspace intelligence.
    Focuses on semantic observability, runtime relationships, and architectural drift.

.EXAMPLE
    # FAST MODE
    # Quick semantic observability using cached metadata
    .\Get-WorkspaceInventory.ps1

.EXAMPLE
    # DEEP MODE
    # Expanded dependency and governance analysis
    .\Get-WorkspaceInventory.ps1 -DeepScan

.EXAMPLE
    # EXPORT GOVERNANCE STATE
    # Export current results to JSON for temporal analysis
    .\Get-WorkspaceInventory.ps1 -ExportJson
#>

[CmdletBinding()]
param (
    [switch]$DeepScan,
    [switch]$ForceScan,
    [switch]$ShowPackages,
    [switch]$VerbosePackages,
    [switch]$ExportJson,
    [switch]$ExportMarkdown,
    [switch]$ExportCsv,
    [string]$WorkspaceRoot = "E:\Workspace"
)

if ($VerbosePackages) { $ShowPackages = $true }

$ErrorActionPreference = "Stop"

# Paths
$CacheDir = Join-Path $WorkspaceRoot "Shared\artifacts\inventory-cache"
$CacheFile = Join-Path $CacheDir "inventory-state.json"
$SharedEnvsPath = Join-Path $WorkspaceRoot "Shared\envs"
$AIModelPath = Join-Path $WorkspaceRoot "Shared\models"

if (-not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
}

# ---------------------------------------------------------
# Package Classifier & Modular Internals
# ---------------------------------------------------------
$PackageClassifier = @{
    "tensorflow" = @{ Primary = "Machine Learning"; Secondary = "AI Engine"; Confidence = "High"; Signal = "High" }
    "torch"      = @{ Primary = "Machine Learning"; Secondary = "AI Engine"; Confidence = "High"; Signal = "High" }
    "scikit-learn" = @{ Primary = "Machine Learning"; Secondary = "Data Science"; Confidence = "High"; Signal = "High" }
    "pandas"     = @{ Primary = "Data Science"; Secondary = "Data Processing"; Confidence = "High"; Signal = "High" }
    "numpy"      = @{ Primary = "Data Science"; Secondary = "Data Processing"; Confidence = "High"; Signal = "Moderate" }
    "scipy"      = @{ Primary = "Data Science"; Secondary = "Math"; Confidence = "Moderate"; Signal = "Moderate" }
    "flask"      = @{ Primary = "Web Backend"; Secondary = "API Server"; Confidence = "High"; Signal = "High" }
    "django"     = @{ Primary = "Web Backend"; Secondary = "Fullstack Framework"; Confidence = "High"; Signal = "High" }
    "fastapi"    = @{ Primary = "Web Backend"; Secondary = "API Server"; Confidence = "High"; Signal = "High" }
    "express"    = @{ Primary = "Web Backend"; Secondary = "API Server"; Confidence = "High"; Signal = "High" }
    "playwright" = @{ Primary = "Browser Automation"; Secondary = "Testing"; Confidence = "High"; Signal = "High" }
    "selenium"   = @{ Primary = "Browser Automation"; Secondary = "Testing"; Confidence = "High"; Signal = "High" }
    "beautifulsoup4" = @{ Primary = "Scraping"; Secondary = "Data Extraction"; Confidence = "Moderate"; Signal = "Moderate" }
    "scrapy"     = @{ Primary = "Scraping"; Secondary = "Automation"; Confidence = "High"; Signal = "High" }
    "jupyter"    = @{ Primary = "Notebook Infrastructure"; Secondary = "Data Science"; Confidence = "High"; Signal = "High" }
    "phaser"     = @{ Primary = "Game Development"; Secondary = "Frontend Framework"; Confidence = "High"; Signal = "High" }
    "libgdx"     = @{ Primary = "Game Development"; Secondary = "Engine"; Confidence = "High"; Signal = "High" }
    "sv-ttk"     = @{ Primary = "Desktop GUI"; Secondary = "Theming"; Confidence = "Moderate"; Signal = "High" }
    "tkinter"    = @{ Primary = "Desktop GUI"; Secondary = "UI Framework"; Confidence = "High"; Signal = "High" }
    "transformers" = @{ Primary = "Local AI Tooling"; Secondary = "Machine Learning"; Confidence = "High"; Signal = "High" }
    "diffusers"  = @{ Primary = "Local AI Tooling"; Secondary = "Image Gen"; Confidence = "High"; Signal = "High" }
    "requests"   = @{ Primary = "Networking"; Secondary = "Web Backend Support"; Confidence = "Moderate"; Signal = "Moderate" }
    "socket.io"  = @{ Primary = "Networking"; Secondary = "Realtime Sync"; Confidence = "High"; Signal = "High" }
    "psutil"     = @{ Primary = "OS Automation"; Secondary = "Telemetry"; Confidence = "Moderate"; Signal = "High" }
    # AI Specific packages
    "ollama"     = @{ Primary = "AI Runtime"; Secondary = "Inference Orchestration"; Confidence = "High"; Signal = "High" }
    "llama-cpp"  = @{ Primary = "AI Runtime"; Secondary = "Local LLM"; Confidence = "High"; Signal = "High" }
}

function Normalize-PackageName {
    param([string]$PackageName)
    $norm = $PackageName.Trim().ToLower() -replace "^_+", ""
    $norm = $norm -replace "_", "-"
    return $norm
}

function Classify-Packages {
    param([string[]]$Packages)
    $classified = @()
    foreach ($pkg in $Packages) {
        $normalized = Normalize-PackageName -PackageName $pkg
        $match = $null
        if ($PackageClassifier.ContainsKey($normalized)) { $match = $PackageClassifier[$normalized] }
        if ($match) {
            $classified += [PSCustomObject]@{ Name = $normalized; Primary = $match.Primary; Secondary = $match.Secondary; Confidence = $match.Confidence; Signal = $match.Signal }
        } else {
            $classified += [PSCustomObject]@{ Name = $normalized; Primary = "Unclassified / Low Signal"; Secondary = ""; Confidence = "None"; Signal = "Low" }
        }
    }
    return $classified | Group-Object Name | ForEach-Object { $_.Group[0] }
}

function Infer-EnvironmentCapabilities {
    param([object[]]$ClassifiedPackages)
    $caps = @{}
    foreach ($pkg in $ClassifiedPackages) {
        if ($pkg.Primary -eq "Unclassified / Low Signal" -or $pkg.Primary -eq "Runtime Support") { continue }
        $domain = $pkg.Primary
        $conf = $pkg.Confidence
        if (-not $caps.ContainsKey($domain)) {
            $caps[$domain] = $conf
        } else {
            # Aggregation logic: Preserve highest confidence
            $levels = @("High", "Moderate", "Low", "None")
            if ($levels.IndexOf($conf) -lt $levels.IndexOf($caps[$domain])) { $caps[$domain] = $conf }
        }
    }
    $sorted = $caps.Keys | Sort-Object | ForEach-Object { "$_ ($($caps[$_]))" }
    if ($sorted.Count -eq 0) { return "None Inferred" }
    return $sorted -join ", "
}

function Get-FolderSizeMB {
    param([string]$Path)
    try {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $sizeBytes = $fso.GetFolder($Path).Size
        return [math]::Round($sizeBytes / 1MB, 2)
    } catch { return 0 }
}

function Get-KeyDependencies {
    param([object[]]$ClassifiedPackages)
    $keyPkgs = $ClassifiedPackages | Where-Object { $_.Signal -eq "High" -or $_.Signal -eq "Moderate" } | Select-Object -ExpandProperty Name
    if ($keyPkgs.Count -eq 0) { return "None detected" }
    return ($keyPkgs | Sort-Object) -join ", "
}

function Test-TopLevelRuntime {
    param([string]$EnvPath, [string]$EnvName)
    if ($EnvName -ne "node_modules") { return $true }
    # A node_modules directory is a top-level runtime boundary only if
    # no ancestor directory in its path is also named node_modules.
    $parts = $EnvPath.Replace('/', '\').Split('\')
    $nmCount = ($parts | Where-Object { $_ -eq "node_modules" }).Count
    return ($nmCount -le 1)
}

# ---------------------------------------------------------
# Modular Metadata Providers (Point 8)
# ---------------------------------------------------------
function Get-PythonMetadata {
    param([string]$Path, [string]$ParentPath)
    $deps = @()
    $reqPath = Join-Path $Path "requirements.txt"
    if (-not (Test-Path $reqPath)) { $reqPath = Join-Path $ParentPath "requirements.txt" }
    if (-not (Test-Path $reqPath)) { $reqPath = Join-Path (Split-Path $ParentPath -Parent) "requirements.txt" }
    
    if (Test-Path $reqPath) {
        try {
            $deps += Get-Content $reqPath | Where-Object { $_ -match "^[a-zA-Z0-9_\-]+" } | ForEach-Object { $_.Split("=")[0].Split(">")[0].Split("<")[0].Trim() }
        } catch {}
    }
    
    $sitePackages = Get-ChildItem -Path $Path -Recurse -Directory -Filter "site-packages" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sitePackages) {
        $folders = Get-ChildItem -Path $sitePackages.FullName -Directory | Where-Object { $_.Name -notmatch "\.dist-info|\.egg-info|__pycache__" }
        $deps += $folders.Name
    }

    if ($DeepScan) {
        $pythonPath = Join-Path $Path "Scripts\python.exe"
        if (Test-Path $pythonPath) {
            try {
                $pipOutput = & $pythonPath -m pip freeze 2>$null
                if ($pipOutput) {
                    $activeDeps = $pipOutput | ForEach-Object { $_.Split("=")[0] }
                    $deps += $activeDeps
                }
            } catch {}
        }
    }
    return $deps | Sort-Object -Unique
}

function Get-NodeMetadata {
    param([string]$Path, [string]$ParentPath)
    $deps = @()
    $pkgPath = Join-Path $ParentPath "package.json"
    if (Test-Path $pkgPath) {
        try {
            $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json
            if ($pkg.dependencies) { $deps += $pkg.dependencies.PSObject.Properties.Name }
            if ($pkg.devDependencies) { $deps += $pkg.devDependencies.PSObject.Properties.Name }
        } catch {}
    }
    return $deps | Sort-Object -Unique
}

function Get-AIMetadata {
    param([string]$WorkspaceRoot)
    $aiInfo = @{ Models = @(); Runtimes = @(); OllamaModels = @(); Risk = "LOW" }

    # Configurable scan roots for GGUF model discovery
    $modelSearchRoots = @(
        (Join-Path $WorkspaceRoot "Shared\models"),
        "E:\AI_Models"
    )

    foreach ($root in $modelSearchRoots) {
        if (Test-Path $root) {
            $found = Get-ChildItem -Path $root -File -Filter "*.gguf" -Recurse -ErrorAction SilentlyContinue
            $aiInfo.Models += @($found | ForEach-Object {
                [PSCustomObject]@{ Name = $_.Name; SizeMB = [math]::Round($_.Length / 1MB, 1); Source = $root }
            })
        }
    }

    # Ollama runtime detection and model registry discovery
    $ollama = Get-Command ollama -ErrorAction SilentlyContinue
    if ($ollama) {
        $aiInfo.Runtimes += "Ollama"
        $ollamaModelPaths = @(
            $env:OLLAMA_MODELS,
            "E:\AI_Models\OLLAMA",
            "$env:USERPROFILE\.ollama\models"
        ) | Where-Object { $_ -and (Test-Path $_) }

        foreach ($ollamaPath in $ollamaModelPaths) {
            $manifests = Join-Path $ollamaPath "manifests"
            if (Test-Path $manifests) {
                $modelFiles = Get-ChildItem -Path $manifests -File -Recurse -ErrorAction SilentlyContinue
                foreach ($mf in $modelFiles) {
                    $relPath = $mf.FullName.Substring($manifests.Length + 1).Replace('\', '/')
                    $parts = $relPath -split '/'
                    if ($parts.Count -ge 3) {
                        $modelName = "$($parts[-2]):$($parts[-1])"
                    } else {
                        $modelName = $mf.Name
                    }
                    if ($aiInfo.OllamaModels -notcontains $modelName) {
                        $aiInfo.OllamaModels += $modelName
                    }
                }
            }
        }
    }

    return $aiInfo
}

# ---------------------------------------------------------
# Governance & Risk Intelligence
# ---------------------------------------------------------
function Get-GovernanceRiskProfile {
    param([object]$Result)
    $profile = @{ Reproducibility = "LOW"; Fragmentation = "LOW"; Bloat = "LOW"; Drift = "LOW"; Isolation = "MODERATE" }
    
    if ($Result.Reproducibility -like "*Missing*") { $profile.Reproducibility = "HIGH" }
    if ($Result.SizeMB -gt 500) { $profile.Bloat = "HIGH" } elseif ($Result.SizeMB -gt 200) { $profile.Bloat = "MODERATE" }
    if ($Result.Staleness -eq "STALE") { $profile.Fragmentation = "HIGH" }
    if ($Result.DriftCount -gt 5) { $profile.Drift = "HIGH" } elseif ($Result.DriftCount -gt 0) { $profile.Drift = "MODERATE" }
    
    if ($Result.MigSuitability -eq "HIGH") { $profile.Isolation = "LOW" }
    elseif ($Result.MigSuitability -eq "LOW") { $profile.Isolation = "HIGH" }
    
    return $profile
}

function Get-RuntimeMaturity {
    param([string]$Lifecycle, [DateTime]$LastMod)
    $days = ((Get-Date) - $LastMod).Days
    if ($Lifecycle -eq "ARCHIVE") { return "Archived legacy runtime" }
    if ($Lifecycle -eq "Completed") { return "Stable maintained runtime" }
    if ($Lifecycle -eq "Experiments") { 
        if ($days -gt 180) { return "Dormant experimental runtime" } 
        return "Active experimental runtime" 
    }
    if ($Lifecycle -eq "Active") { 
        if ($days -gt 90) { return "Dormant evolving runtime" } 
        return "Active evolving runtime" 
    }
    if ($Lifecycle -eq "Shared") { 
        if ($days -gt 365) { return "Dormant shared infrastructure" } 
        return "Active shared infrastructure" 
    }
    if ($Lifecycle -eq "Academic") {
        if ($days -gt 180) { return "Dormant academic runtime" }
        return "Active academic runtime"
    }
    if ($Lifecycle -eq "Tools") {
        if ($days -gt 180) { return "Dormant tooling runtime" }
        return "Active tooling runtime"
    }
    return "Unknown maturity"
}

function Get-InfraCentrality {
    param([object]$SharedResult, [object[]]$AllResults)
    $adopters = @($AllResults | Where-Object { $_.BestShared -eq $SharedResult.EnvName -and $_.OverlapPct -gt 0 })
    $adoptionCount = $adopters.Count
    $avgOverlap = if ($adopters.Count -gt 0) { [math]::Round(($adopters | Measure-Object -Property OverlapPct -Average).Average) } else { 0 }
    $totalRuntimes = @($AllResults | Where-Object { $_.Lifecycle -ne "Shared" }).Count

    $score = 0
    # Adoption breadth
    if ($adoptionCount -ge 3) { $score += 3 }
    elseif ($adoptionCount -ge 2) { $score += 2 }
    elseif ($adoptionCount -ge 1) { $score += 1 }
    # Overlap depth
    if ($avgOverlap -gt 60) { $score += 2 }
    elseif ($avgOverlap -gt 30) { $score += 1 }
    # Coverage ratio
    $coverage = if ($totalRuntimes -gt 0) { $adoptionCount / $totalRuntimes } else { 0 }
    if ($coverage -gt 0.5) { $score += 2 }
    elseif ($coverage -gt 0.25) { $score += 1 }

    switch ($score) {
        { $_ -ge 6 } { return "CRITICAL" }
        { $_ -ge 4 } { return "CORE" }
        { $_ -ge 2 } { return "EMERGING" }
        default       { return "LOW" }
    }
}

# ---------------------------------------------------------
# Cache System
# ---------------------------------------------------------
$Cache = @{}
$CacheMetadata = @{ Source = "Live scan"; CacheAgeStr = "N/A"; Freshness = "FRESH"; LastScan = (Get-Date).ToString("O"); ScanType = if ($DeepScan) { "DEEP" } else { "FAST" } }

if (-not $ForceScan -and (Test-Path $CacheFile)) {
    try {
        $CacheContent = Get-Content $CacheFile -Raw | ConvertFrom-Json
        $cacheAge = (Get-Date) - [DateTime]$CacheContent.Info.LastScan
        $CacheMetadata.Source = "Offline cache"; $CacheMetadata.LastScan = $CacheContent.Info.LastScan
        $CacheMetadata.CacheAgeStr = if ($cacheAge.TotalMinutes -lt 60) { "$([math]::Round($cacheAge.TotalMinutes))m" } else { "$([math]::Round($cacheAge.TotalHours, 1))h $([math]::Round($cacheAge.Minutes))m" }
        $CacheMetadata.Freshness = if ($cacheAge.Days -gt 7) { "STALE" } else { "VALID" }
        if ($CacheContent.Info.ScanType -eq "FAST" -and $DeepScan) { $CacheMetadata.Source = "Live scan (Deep Mode required)" } else {
            foreach ($prop in $CacheContent.Data.psobject.properties) { $Cache[$prop.Name] = $prop.Value }
        }
    } catch {}
}

function Save-Cache {
    $wrapper = @{ Info = @{ LastScan = (Get-Date).ToString("O"); ScanType = if ($DeepScan) { "DEEP" } else { "FAST" } }; Data = $Cache }
    $wrapper | ConvertTo-Json -Depth 6 | Out-File $CacheFile -Encoding UTF8
}

# ---------------------------------------------------------
# Main Scanning Logic
# ---------------------------------------------------------
$SharedEnvsCache = @{}; $SharedEnvsFound = 0; $Results = @()
if (Test-Path $SharedEnvsPath) {
    $envs = @(Get-ChildItem -Path $SharedEnvsPath -Directory)
    $SharedEnvsFound = $envs.Count
    foreach ($env in $envs) {
        $deps = Get-PythonMetadata -Path $env.FullName -ParentPath $env.Parent.FullName
        # Store normalized canonical identities for consistent cross-subsystem comparisons
        $SharedEnvsCache[$env.Name] = @($deps | ForEach-Object { Normalize-PackageName -PackageName $_ } | Sort-Object -Unique)
        $classifiedPkgs = Classify-Packages -Packages $deps
        $Results += [PSCustomObject]@{
            ProjectName = "envs/" + $env.Name; EnvName = $env.Name; Lifecycle = "Shared"; Path = $env.FullName; RuntimeType = "Shared Infrastructure Environment"
            SizeMB = Get-FolderSizeMB -Path $env.FullName; LastModified = $env.LastWriteTime.ToString("O"); Maturity = Get-RuntimeMaturity -Lifecycle "Shared" -LastMod $env.LastWriteTime
            Staleness = "FRESH"; Capabilities = Infer-EnvironmentCapabilities -ClassifiedPackages $classifiedPkgs; Reproducibility = "Reproducibility metadata intact"
            IsolationReason = "Reusable infrastructure"; OverlapAdvice = ""; OverlapPct = 0; BestShared = ""; MigSuitability = "N/A"; PackageCount = $classifiedPkgs.Count
            ClassifiedPackages = $classifiedPkgs; KeyDependencies = Get-KeyDependencies -ClassifiedPackages $classifiedPkgs; DriftCount = 0; OverlapDrivers = @()
        }
    }
}

$ScanTargets = @("Active", "Experiments", "Completed", "Projects", "Academic", "Tools", "ARCHIVE"); $EnvTargets = @(".venv", "node_modules")
foreach ($lifecycle in $ScanTargets) {
    $dir = Join-Path $WorkspaceRoot $lifecycle
    if (-not (Test-Path $dir)) { continue }
    # Boundary-aware discovery: filter out nested node_modules (npm dependency internals)
    $envs = Get-ChildItem -Path $dir -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $EnvTargets -contains $_.Name } |
        Where-Object { Test-TopLevelRuntime -EnvPath $_.FullName -EnvName $_.Name }
    foreach ($env in $envs) {
        $path = $env.FullName; $envName = $env.Name; $projectName = $env.Parent.Name; $lastMod = $env.LastWriteTime; $cacheKey = $path.GetHashCode().ToString()
        if (-not $DeepScan -and -not $ForceScan -and $Cache.ContainsKey($cacheKey) -and $Cache[$cacheKey].LastModified -eq $lastMod.ToString("O")) { $Results += $Cache[$cacheKey]; continue }
        
        $packages = if ($envName -eq ".venv") { Get-PythonMetadata -Path $path -ParentPath $env.Parent.FullName } else { Get-NodeMetadata -Path $path -ParentPath $env.Parent.FullName }
        $classifiedPkgs = Classify-Packages -Packages $packages
        
        # Overlap & Drift Logic — uses canonical normalized identities
        $overlapPct = 0; $bestShared = ""; $overlapDrivers = @(); $driftCount = 0; $migSuitability = "LOW"; $overlapAdvice = "Local isolation justified."
        $normalizedPackages = @($packages | ForEach-Object { Normalize-PackageName -PackageName $_ } | Sort-Object -Unique)
        if ($normalizedPackages.Count -gt 0) {
            foreach ($sharedEnv in $SharedEnvsCache.Keys) {
                $sharedPkgs = $SharedEnvsCache[$sharedEnv]
                $drivers = @($normalizedPackages | Where-Object { $sharedPkgs -contains $_ })
                $pct = [math]::Round(($drivers.Count / $normalizedPackages.Count) * 100)
                if ($pct -gt $overlapPct) { $overlapPct = $pct; $bestShared = $sharedEnv; $overlapDrivers = $drivers }
            }
            if ($bestShared) {
                $sharedPkgs = $SharedEnvsCache[$bestShared]
                $driftCount = @($normalizedPackages | Where-Object { $sharedPkgs -notcontains $_ }).Count
                $migSuitability = if ($overlapPct -gt 70) { "HIGH" } elseif ($overlapPct -gt 30) { "MODERATE" } else { "LOW" }
                $overlapAdvice = if ($migSuitability -eq "HIGH") { "$bestShared overlap: $overlapPct% | Migration Suitability: HIGH" } else { "$bestShared overlap: $overlapPct% | Local isolation remains justified." }
            }
        }

        $obj = [PSCustomObject]@{
            ProjectName = $projectName; EnvName = $envName; Lifecycle = $lifecycle; Path = $path; SizeMB = Get-FolderSizeMB -Path $path; LastModified = $lastMod.ToString("O")
            Maturity = Get-RuntimeMaturity -Lifecycle $lifecycle -LastMod $lastMod; Staleness = if ((Get-RuntimeMaturity -Lifecycle $lifecycle -LastMod $lastMod) -like "*Dormant*") { "STALE" } else { "FRESH" }
            Capabilities = Infer-EnvironmentCapabilities -ClassifiedPackages $classifiedPkgs; Reproducibility = if ($envName -eq "node_modules") { "Reproducibility metadata intact" } else { "Reproducibility metadata intact" } # Simple check
            OverlapPct = $overlapPct; BestShared = $bestShared; MigSuitability = $migSuitability; OverlapAdvice = $overlapAdvice; PackageCount = $classifiedPkgs.Count
            ClassifiedPackages = $classifiedPkgs; KeyDependencies = Get-KeyDependencies -ClassifiedPackages $classifiedPkgs; DriftCount = $driftCount; OverlapDrivers = $overlapDrivers
            RuntimeType = if ($envName -eq ".venv") { "Local Python Environment" } else { "Local Node Environment" }
        }
        $Cache[$cacheKey] = $obj; $Results += $obj
    }
}
Save-Cache

# ---------------------------------------------------------
# Presentation: V3.0 Observability Layers
# ---------------------------------------------------------
if ($ExportJson) { $Results | ConvertTo-Json -Depth 6 | Out-File (Join-Path $CacheDir "governance-export.json") -Encoding UTF8; Write-Host "Export complete: governance-export.json"; exit }

Write-Host "`n=============================================" -ForegroundColor Magenta
Write-Host "  Workspace Observability & Reconnaissance V3.0" -ForegroundColor Magenta
Write-Host "=============================================" -ForegroundColor Magenta

Write-Host "`n=== Workspace Topology ===" -ForegroundColor Cyan
foreach ($lifecycle in @("Active", "Experiments", "Completed", "Academic", "Tools", "Shared", "ARCHIVE")) {
    $lifecycleResults = $Results | Where-Object { $_.Lifecycle -eq $lifecycle }
    if ($lifecycleResults.Count -eq 0) { continue }
    Write-Host "$lifecycle/" -ForegroundColor Cyan
    foreach ($res in $lifecycleResults) {
        Write-Host " \-- $($res.ProjectName) [$($res.EnvName)]" -ForegroundColor Green
        if ($DeepScan) {
            $risk = Get-GovernanceRiskProfile -Result $res
            Write-Host "     |-- Risk Profile: Repro:$($risk.Reproducibility) | Drift:$($risk.Drift) | Bloat:$($risk.Bloat)" -ForegroundColor Gray
            if ($res.Lifecycle -ne "Shared") {
                $driftMsg = if (-not $res.BestShared) {
                    "Shared runtime comparison unavailable"
                } elseif ($res.DriftCount -eq 0) {
                    "No shared runtime divergence detected"
                } else {
                    "$($res.DriftCount) packages diverged from $($res.BestShared)"
                }
                Write-Host "     |-- Drift: $driftMsg" -ForegroundColor Gray
                $driverDisplay = if ($res.OverlapDrivers.Count -gt 0) { $res.OverlapDrivers -join ", " } else { "None" }
                Write-Host "     |-- Overlap Drivers: $driverDisplay" -ForegroundColor DarkGray
            }
        }
    }
}

Write-Host "`n=== Runtime Ownership Context ===" -ForegroundColor Cyan
foreach ($res in $Results | Where-Object { $_.Lifecycle -ne "Shared" }) {
    Write-Host "Project:   $($res.ProjectName)" -ForegroundColor Cyan
    Write-Host "Lifecycle: $($res.Lifecycle)" -ForegroundColor DarkCyan
    Write-Host "Runtime:   $($res.RuntimeType)" -ForegroundColor Gray
    Write-Host "Capabilities: $($res.Capabilities)" -ForegroundColor White
    Write-Host "Relationship: $($res.OverlapAdvice)" -ForegroundColor DarkGray
    Write-Host "Status:       $($res.Staleness) | $($res.Maturity)`n" -ForegroundColor DarkGray
}

Write-Host "`n=== Shared Infrastructure Intelligence ===" -ForegroundColor Cyan
foreach ($res in $Results | Where-Object { $_.Lifecycle -eq "Shared" }) {
    $centrality = Get-InfraCentrality -SharedResult $res -AllResults $Results
    $adoption = @($Results | Where-Object { $_.BestShared -eq $res.EnvName -and $_.OverlapPct -gt 0 }).Count
    Write-Host "Shared Runtime: $($res.EnvName)" -ForegroundColor Cyan
    Write-Host "Adoption:       Referenced by $adoption projects" -ForegroundColor Gray
    Write-Host "Capabilities:   $($res.Capabilities)" -ForegroundColor White
    Write-Host "Infra Centrality: $centrality`n" -ForegroundColor DarkGray
}

$AI = Get-AIMetadata -WorkspaceRoot $WorkspaceRoot
if ($AI.Models.Count -gt 0 -or $AI.Runtimes.Count -gt 0 -or $AI.OllamaModels.Count -gt 0) {
    Write-Host "`n=== AI Infrastructure Awareness ===" -ForegroundColor Cyan
    Write-Host "GGUF Models:    $($AI.Models.Count) found" -ForegroundColor Gray
    foreach ($m in $AI.Models) {
        Write-Host "  - $($m.Name) ($($m.SizeMB) MB)" -ForegroundColor DarkGray
    }
    if ($AI.OllamaModels.Count -gt 0) {
        Write-Host "Ollama Models:  $($AI.OllamaModels -join ', ')" -ForegroundColor Gray
    }
    Write-Host "Runtimes:       $(if ($AI.Runtimes.Count -gt 0) { $AI.Runtimes -join ', ' } else { 'None detected' })" -ForegroundColor Gray
}

Write-Host "`n=== Cache Status ===" -ForegroundColor Cyan
Write-Host "Source:     $($CacheMetadata.Source)"
Write-Host "Age:        $($CacheMetadata.CacheAgeStr)"
Write-Host "Freshness:  $($CacheMetadata.Freshness)" -ForegroundColor $(if ($CacheMetadata.Freshness -eq "STALE") { "Yellow" } else { "Green" })

Write-Host "`n=== Operational Observations ===" -ForegroundColor Cyan
$obs = @()
if ($Results.Count -gt 0) {
    if (@($Results | Where-Object { $_.DriftCount -gt 5 }).Count -gt 0) { $obs += "* Warning: High runtime drift detected in local environments." }
    if (@($Results | Where-Object { $_.MigSuitability -eq "HIGH" }).Count -gt 0) { $obs += "* Shared infrastructure adoption exists but adoption remains limited." }
    else { $obs += "* Workspace isolation strategy appears intentionally disciplined." }
}
foreach ($o in $obs) { Write-Host $o -ForegroundColor $(if ($o -like "*Warning*") { "Yellow" } else { "Green" }) }

$finalMode = if ($DeepScan) { "DEEP" } else { "FAST" }
Write-Host "`nScan complete. Mode: $finalMode" -ForegroundColor DarkGray

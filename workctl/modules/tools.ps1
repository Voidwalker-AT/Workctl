# =================================================================
# WorkCtl Tool Subsystem & External Application Registry
# =================================================================

$script:WorkCtlToolsConfigCache = $null
$script:WorkCtlToolsConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) "config\tools.json"
if (!(Test-Path -LiteralPath $script:WorkCtlToolsConfigPath)) {
    $script:WorkCtlToolsConfigPath = "E:\TOOLS\WorkstationControl\config\tools.json"
}

function Get-WorkCtlToolsConfig {
    if (!$script:WorkCtlToolsConfigCache) {
        if (Test-Path -LiteralPath $script:WorkCtlToolsConfigPath) {
            try {
                $script:WorkCtlToolsConfigCache = Get-Content -LiteralPath $script:WorkCtlToolsConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {
                $script:WorkCtlToolsConfigCache = [PSCustomObject]@{ version = 1; tools = [PSCustomObject]@{} }
            }
        } else {
            $script:WorkCtlToolsConfigCache = [PSCustomObject]@{ version = 1; tools = [PSCustomObject]@{} }
        }
    }
    return $script:WorkCtlToolsConfigCache
}

function Get-WorkCtlToolsRegistry {
    return Get-WorkCtlToolsConfig
}

function Get-WorkCtlTool([string]$Id) {
    $cfg = Get-WorkCtlToolsConfig
    if ($cfg -and $cfg.tools -and $cfg.tools.PSObject.Properties[$Id]) {
        return $cfg.tools.PSObject.Properties[$Id].Value
    }
    return $null
}

function Start-WorkCtlTool([string]$Id) {
    $tool = Get-WorkCtlTool $Id
    if (!$tool) { throw "Tool not found in registry: $Id" }

    $targetExe = $null
    if ($tool.installPath -and (Test-Path -LiteralPath $tool.installPath)) {
        $targetExe = $tool.installPath
    } elseif ($tool.command) {
        $cmd = Get-Command $tool.command -ErrorAction SilentlyContinue
        if ($cmd) { $targetExe = $cmd.Source }
    }

    if (!$targetExe) {
        throw "Tool executable not found on disk: $($tool.installPath)"
    }

    $wd = if ($tool.workingDirectory -and (Test-Path -LiteralPath $tool.workingDirectory)) {
        $tool.workingDirectory
    } else {
        Split-Path -Parent $targetExe
    }

    $proc = Start-Process -FilePath $targetExe -WorkingDirectory $wd -PassThru
    return [PSCustomObject]@{
        Id = $Id
        ProcessId = $proc.Id
        Started = $true
        Timestamp = (Get-Date).ToString("o")
    }
}

# =================================================================
# REAL TOOL ADAPTERS
# =================================================================

# 1. WinDirStat Adapter
function Invoke-WinDirStatScan {
    param([string]$TargetPath = "E:\")
    $tool = Get-WorkCtlTool "windirstat"
    $exe = if ($tool -and $tool.installPath) { $tool.installPath } else { "E:\TOOLS\Diagnostics\WinDirStat.exe" }
    if (!(Test-Path -LiteralPath $exe)) { throw "WinDirStat executable not found at $exe" }
    
    $cleanPath = $TargetPath.TrimEnd('\') + "\"
    Start-Process -FilePath $exe -ArgumentList "`"$cleanPath`"" -WorkingDirectory (Split-Path -Parent $exe)
    return [PSCustomObject]@{
        Tool = "windirstat"
        Target = $cleanPath
        Launched = $true
    }
}

# 2. FanControl Adapter (Read-Only Status & Safe Launcher)
function Get-FanControlStatus {
    $cfgPath = "E:\TOOLS\FanControl_267_net_10_0\Configurations\userConfig.json"
    $curvesCount = 0
    $sensorsCount = 0
    $version = "267"
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $json = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
            if ($json.__VERSION__) { $version = $json.__VERSION__ }
            if ($json.FanControl -and $json.FanControl.FanCurves) {
                $curvesCount = @($json.FanControl.FanCurves).Count
            }
            if ($json.Sensors) {
                $sensorsCount = 4 # CPU, GPU, Motherboard, EmbeddedEC enabled
            }
        } catch {}
    }
    
    $proc = Get-Process -Name "FanControl" -ErrorAction SilentlyContinue | Select-Object -First 1
    return [PSCustomObject]@{
        Installed = (Test-Path "E:\TOOLS\FanControl_267_net_10_0\FanControl.exe")
        Running = ($null -ne $proc)
        ProcessId = if ($proc) { $proc.Id } else { $null }
        Version = $version
        ActiveCurves = $curvesCount
        ConfigPath = $cfgPath
    }
}

# 3. qBittorrent Adapter (Read-Only & Safety Guarded)
function Get-QBittorrentStatus {
    $proc = Get-Process -Name "qbittorrent" -ErrorAction SilentlyContinue | Select-Object -First 1
    $iniPath = Join-Path $env:APPDATA "qBittorrent\qBittorrent.ini"
    $webUiEnabled = $false
    $webUiPort = 8080
    
    if (Test-Path -LiteralPath $iniPath) {
        try {
            $lines = Get-Content -LiteralPath $iniPath
            foreach ($l in $lines) {
                if ($l -match '^WebUI\\Enabled\s*=\s*(true|1)') { $webUiEnabled = $true }
                if ($l -match '^WebUI\\Port\s*=\s*(\d+)') { $webUiPort = [int]$matches[1] }
            }
        } catch {}
    }
    
    return [PSCustomObject]@{
        Installed = (Test-Path "E:\TOOLS\qBittorrent\qbittorrent.exe")
        Running = ($null -ne $proc)
        ProcessId = if ($proc) { $proc.Id } else { $null }
        WebUiEnabled = $webUiEnabled
        WebUiPort = $webUiPort
        SonarrIntegration = if ($webUiEnabled) { "CONFIGURABLE" } else { "NOT CONFIGURED (API DISABLED)" }
    }
}

# 4. Mounter Adapter (WinCDEmu Batch Mounter)
function Get-MounterMountedImages {
    $exe = "E:\TOOLS\Mounter\batchmnt64.exe"
    if (!(Test-Path -LiteralPath $exe)) {
        $exe = "E:\TOOLS\Mounter\batchmnt.exe"
    }
    $list = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $exe) {
        try {
            $raw = & $exe /list 2>&1
            foreach ($line in $raw) {
                if ($line -match '^([A-Z]):\s+(.+)$') {
                    $list.Add([PSCustomObject]@{
                        DriveLetter = $matches[1] + ":"
                        ImagePath = $matches[2].Trim()
                    })
                }
            }
        } catch {}
    }
    return $list.ToArray()
}

function Invoke-MounterMountImage([string]$ImagePath, [string]$DriveLetter = "") {
    $exe = "E:\TOOLS\Mounter\batchmnt64.exe"
    if (!(Test-Path -LiteralPath $exe)) { $exe = "E:\TOOLS\Mounter\batchmnt.exe" }
    if (!(Test-Path -LiteralPath $exe)) { throw "batchmnt not found" }
    if (!(Test-Path -LiteralPath $ImagePath)) { throw "Image file not found: $ImagePath" }
    
    $args = @("`"$ImagePath`"")
    if ($DriveLetter) { $args += $DriveLetter.TrimEnd(':') + ":" }
    
    $p = Start-Process -FilePath $exe -ArgumentList ($args -join " ") -Wait -PassThru -NoNewWindow
    return [PSCustomObject]@{
        Success = ($p.ExitCode -eq 0)
        ExitCode = $p.ExitCode
        ImagePath = $ImagePath
    }
}

function Invoke-MounterUnmountDrive([string]$DriveLetter) {
    $exe = "E:\TOOLS\Mounter\batchmnt64.exe"
    if (!(Test-Path -LiteralPath $exe)) { $exe = "E:\TOOLS\Mounter\batchmnt.exe" }
    if (!(Test-Path -LiteralPath $exe)) { throw "batchmnt not found" }
    
    $dl = $DriveLetter.TrimEnd(':') + ":"
    $p = Start-Process -FilePath $exe -ArgumentList "/unmount $dl" -Wait -PassThru -NoNewWindow
    return [PSCustomObject]@{
        Success = ($p.ExitCode -eq 0)
        ExitCode = $p.ExitCode
        DriveLetter = $dl
    }
}

# 5. Sonarr Detailed Status & Operational Audit
function Get-SonarrStatus {
    $proc = Get-Process -Name "*sonarr*" -ErrorAction SilentlyContinue | Select-Object -First 1
    $cfgPath = "C:\ProgramData\Sonarr\config.xml"
    $installed = (Test-Path "C:\ProgramData\Sonarr\bin\Sonarr.Console.exe") -or (Test-Path "C:\ProgramData\Sonarr\bin\Sonarr.exe")
    $running = ($null -ne $proc)
    
    $apiKey = ""
    $port = 8989
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            [xml]$xml = Get-Content -LiteralPath $cfgPath -ErrorAction SilentlyContinue
            if ($xml.Config.ApiKey) { $apiKey = $xml.Config.ApiKey }
            if ($xml.Config.Port) { $port = [int]$xml.Config.Port }
        } catch {}
    }
    
    $apiReachable = $false
    $version = "Unknown"
    $seriesCount = 0
    $rootCount = 0
    $indexersCount = 0
    $downloadClientsCount = 0
    $queueCount = 0
    $healthIssues = 0
    
    if ($running) {
        try {
            $headers = @{}
            if ($apiKey) { $headers["X-Api-Key"] = $apiKey }
            $statusRes = Invoke-RestMethod -Uri "http://localhost:$port/api/v3/system/status" -Headers $headers -TimeoutSec 1 -ErrorAction Stop
            if ($statusRes) {
                $apiReachable = $true
                $version = $statusRes.version
                
                try {
                    $sList = Invoke-RestMethod -Uri "http://localhost:$port/api/v3/series" -Headers $headers -TimeoutSec 1 -ErrorAction SilentlyContinue
                    if ($sList) { $seriesCount = @($sList).Count }
                } catch {}
                
                try {
                    $rList = Invoke-RestMethod -Uri "http://localhost:$port/api/v3/rootfolder" -Headers $headers -TimeoutSec 1 -ErrorAction SilentlyContinue
                    if ($rList) { $rootCount = @($rList).Count }
                } catch {}
                
                try {
                    $iList = Invoke-RestMethod -Uri "http://localhost:$port/api/v3/indexer" -Headers $headers -TimeoutSec 1 -ErrorAction SilentlyContinue
                    if ($iList) { $indexersCount = @($iList).Count }
                } catch {}
                
                try {
                    $dList = Invoke-RestMethod -Uri "http://localhost:$port/api/v3/downloadclient" -Headers $headers -TimeoutSec 1 -ErrorAction SilentlyContinue
                    if ($dList) { $downloadClientsCount = @($dList).Count }
                } catch {}
                
                try {
                    $qList = Invoke-RestMethod -Uri "http://localhost:$port/api/v3/queue" -Headers $headers -TimeoutSec 1 -ErrorAction SilentlyContinue
                    if ($qList) { $queueCount = [int]$qList.totalRecords }
                } catch {}
                
                try {
                    $hList = Invoke-RestMethod -Uri "http://localhost:$port/api/v3/health" -Headers $headers -TimeoutSec 1 -ErrorAction SilentlyContinue
                    if ($hList) { $healthIssues = @($hList).Count }
                } catch {}
            }
        } catch {}
    }
    
    $opState = if (!$installed) {
        "NOT INSTALLED"
    } elseif (!$running) {
        "INSTALLED (STOPPED)"
    } elseif (!$apiReachable) {
        "ERROR (API UNREACHABLE)"
    } elseif ($indexersCount -eq 0 -or $downloadClientsCount -eq 0) {
        "PARTIALLY CONFIGURED"
    } else {
        "OPERATIONAL"
    }
    
    return [PSCustomObject]@{
        Installed = $installed
        Running = $running
        ProcessId = if ($proc) { $proc.Id } else { $null }
        ProcessName = if ($proc) { $proc.ProcessName } else { "" }
        Version = $version
        Port = $port
        ApiReachable = $apiReachable
        SeriesCount = $seriesCount
        RootFoldersCount = $rootCount
        IndexersCount = $indexersCount
        DownloadClientsCount = $downloadClientsCount
        QueueCount = $queueCount
        HealthIssuesCount = $healthIssues
        OperationalState = $opState
        IsAvailableForDownload = ($opState -eq "OPERATIONAL")
    }
}

# =================================================================
# INTERACTIVE TTY TOOL HANDOFF PRIMITIVE
# =================================================================

function Invoke-WorkCtlInteractiveTool {
    param(
        [Parameter(Mandatory=$true)]
        [string]$CommandLine,
        [string]$WorkingDirectory = "E:\Workspace"
    )

    # 1. Suspend WorkCtl differential TUI renderer
    $script:UiActive = $false
    
    # 2. Restore console cursor visibility and normal buffer mode
    try {
        [Console]::CursorVisible = $true
        [Console]::ResetColor()
    } catch {}

    # 3. Clear console to hand over clean screen to external process
    try { Clear-Host } catch {}

    # 4. Launch external interactive process synchronously attached to current console
    $exitCode = 0
    try {
        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = "cmd.exe"
        $pinfo.Arguments = "/c $CommandLine"
        if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory)) {
            $pinfo.WorkingDirectory = $WorkingDirectory
        }
        $pinfo.UseShellExecute = $false
        
        $proc = [System.Diagnostics.Process]::Start($pinfo)
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
    } catch {
        Write-Warning "Failed to execute interactive tool: $($_.Exception.Message)"
        $exitCode = -1
    }

    # 5. Restore WorkCtl TUI environment
    try {
        [Console]::CursorVisible = $false
        [Console]::ResetColor()
    } catch {}

    # 6. Invalidate previous cached frame so WorkCtl fully redraws differential state
    $script:UiPreviousFrame = @()
    $script:UiActive = $true

    return $exitCode
}

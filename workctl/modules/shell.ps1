# =================================================================
# WorkCtl v1.5 - Interactive Workstation Shell Subsystem Engine
# =================================================================

$script:ShellRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) } else { "E:\TOOLS\WorkstationControl" }
if (!$script:ShellRoot -or !(Test-Path -LiteralPath $script:ShellRoot)) {
    $script:ShellRoot = "E:\TOOLS\WorkstationControl"
}
$script:ShellRuntimeDir = Join-Path $script:ShellRoot "runtime"
if (!(Test-Path -LiteralPath $script:ShellRuntimeDir)) {
    New-Item -ItemType Directory -Force -Path $script:ShellRuntimeDir | Out-Null
}

$script:LoadedSubsystems = @{
    "telemetry" = $true
    "storage"   = $true
    "tools"     = $true
}

function Import-WorkCtlSubsystem([string]$Name) {
    if (!$Name) { return }
    $key = $Name.ToLowerInvariant()
    if ($script:LoadedSubsystems.ContainsKey($key)) { return }
    $script:LoadedSubsystems[$key] = $true

    $modulesDir = Join-Path $script:ShellRoot "modules"
    $providersDir = Join-Path $modulesDir "providers"

    $targetFiles = switch ($key) {
        "guide"       { @((Join-Path $modulesDir "guide.ps1")) }
        "development" { @((Join-Path $modulesDir "development.ps1")) }
        "powertoys"   { @((Join-Path $modulesDir "powertoys.ps1")) }
        "media"       { @((Join-Path $modulesDir "media.ps1")) }
        "omencore"    { @((Join-Path $modulesDir "omencore.ps1")) }
        "services"    { @((Join-Path $providersDir "services.ps1")) }
        "processes"   { @((Join-Path $providersDir "processes.ps1")) }
        "hardware"    { @((Join-Path $providersDir "hardware.ps1"), (Join-Path $modulesDir "omencore.ps1")) }
        default       { @() }
    }

    foreach ($p in $targetFiles) {
        if (Test-Path -LiteralPath $p) {
            $raw = [System.IO.File]::ReadAllText($p)
            $transformed = [regex]::Replace($raw, "(?m)^function\s+([A-Za-z0-9_-]+)", "function global:`$1")
            $sb = [scriptblock]::Create($transformed)
            & $sb
        }
    }
}

# Only load lightweight core providers on startup (< 20KB total)
$providersDir = Join-Path (Join-Path $script:ShellRoot "modules") "providers"
$coreProviders = @("telemetry.ps1", "storage.ps1", "tools.ps1")
foreach ($cp in $coreProviders) {
    $pPath = Join-Path $providersDir $cp
    if (Test-Path -LiteralPath $pPath) { . $pPath }
}

$script:ShellHistoryFilePath = Join-Path $script:ShellRuntimeDir "history.jsonl"
$script:ShellHistory = New-Object System.Collections.Generic.List[string]

# Lightweight in-memory caches
$script:ShellWorkloadsConfigCache = $null
$script:ShellWorkloadsConfigMtime = $null
$script:ShellToolsConfigCache = $null
$script:ShellToolsConfigMtime = $null

$script:ShellProcessesCache = $null
$script:ShellProcessesCacheTime = [datetime]::MinValue

$script:ShellServicesCache = $null
$script:ShellServicesCacheTime = [datetime]::MinValue

$script:ShellNetworkCache = $null
$script:ShellNetworkCacheTime = [datetime]::MinValue

$script:ShellStorageCache = $null
$script:ShellStorageCacheTime = [datetime]::MinValue

$script:ShellProjectsCache = $null
$script:ShellProjectsCacheTime = [datetime]::MinValue

$script:ShellEntityIndexCache = $null
$script:ShellEntityIndexCacheTime = [datetime]::MinValue

# Discoverable Shell Aliases
$script:ShellAliases = [ordered]@{
    "r"     = "resources"
    "res"   = "resources"
    "wl"    = "workloads"
    "pt"    = "powertoys"
    "med"   = "media"
    "diag"  = "diagnostics"
    "doc"   = "doctor"
    "ps"    = "processes"
    "top"   = "processes"
    "net"   = "network"
    "ports" = "ports"
    "disk"  = "storage"
    "drives"= "storage"
    "proj"  = "projects"
    "cls"   = "clear"
    "q"     = "exit"
    "dir"   = "ls"
    "st"    = "status"
    "g"     = "guide"
    "docs"  = "guide"
    "learn" = "guide"
    "manual"= "guide"
    "dev"   = "dev"
    "devel" = "dev"
    "agents"= "agents"
    "agent" = "agents"
    "ai"    = "agents"
    "fb"    = "freebuff"
}

# Structured Command Registry for Discoverability, Help, and Safety Governance
$script:ShellCommandRegistry = [ordered]@{
    "status" = [PSCustomObject]@{
        Name = "status"
        Aliases = @("st")
        Usage = "status"
        Category = "System"
        Description = "Show current workstation status overview"
        Examples = @("status")
        Risk = "Safe"
    }
    "resources" = [PSCustomObject]@{
        Name = "resources"
        Aliases = @("r", "res")
        Usage = "resources [cpu|ram|gpu|net|disk]"
        Category = "Telemetry"
        Description = "Open live CPU/RAM/GPU/Disk telemetry screen"
        Examples = @("resources", "res")
        Risk = "Safe"
    }
    "workloads" = [PSCustomObject]@{
        Name = "workloads"
        Aliases = @("wl")
        Usage = "workloads [category]"
        Category = "Control"
        Description = "Browse and manage background workloads and services"
        Examples = @("workloads", "wl ai", "wl dev")
        Risk = "Safe"
    }
    "powertoys" = [PSCustomObject]@{
        Name = "powertoys"
        Aliases = @("pt")
        Usage = "powertoys [category|module]"
        Category = "Subsystems"
        Description = "Open Microsoft PowerToys control plane"
        Examples = @("powertoys", "pt Windowing", "pt Awake")
        Risk = "Safe"
    }
    "media" = [PSCustomObject]@{
        Name = "media"
        Aliases = @("med")
        Usage = "media [sonarr|torlink|downloads|movies|tv]"
        Category = "Subsystems"
        Description = "Open Smart Media & Automation control plane"
        Examples = @("media", "media sonarr", "media downloads")
        Risk = "Safe"
    }
    "tools" = [PSCustomObject]@{
        Name = "tools"
        Aliases = @()
        Usage = "tools"
        Category = "Tools"
        Description = "Browse and inspect external workstation applications & tools"
        Examples = @("tools")
        Risk = "Safe"
    }
    "processes" = [PSCustomObject]@{
        Name = "processes"
        Aliases = @("ps", "top")
        Usage = "processes"
        Category = "System"
        Description = "Inspect top processes and memory consumers"
        Examples = @("processes", "ps")
        Risk = "Safe"
    }
    "services" = [PSCustomObject]@{
        Name = "services"
        Aliases = @()
        Usage = "services"
        Category = "System"
        Description = "Inspect Windows services related to workstation tasks"
        Examples = @("services")
        Risk = "Safe"
    }
    "network" = [PSCustomObject]@{
        Name = "network"
        Aliases = @("net", "ports")
        Usage = "network"
        Category = "System"
        Description = "Inspect network adapters, IP config, and listening ports"
        Examples = @("network", "ports")
        Risk = "Safe"
    }
    "storage" = [PSCustomObject]@{
        Name = "storage"
        Aliases = @("disk", "drives")
        Usage = "storage"
        Category = "System"
        Description = "Inspect local storage drives, volumes, and free space"
        Examples = @("storage", "disk")
        Risk = "Safe"
    }
    "projects" = [PSCustomObject]@{
        Name = "projects"
        Aliases = @("proj")
        Usage = "projects"
        Category = "Workspace"
        Description = "Inspect workspace projects in E:\Workspace"
        Examples = @("projects", "proj")
        Risk = "Safe"
    }
    "project" = [PSCustomObject]@{
        Name = "project"
        Aliases = @()
        Usage = "project <name>"
        Category = "Workspace"
        Description = "Inspect a specific workspace project or open detail view"
        Examples = @("project termux-ai-workstation")
        Risk = "Safe"
    }
    "dev" = [PSCustomObject]@{
        Name = "dev"
        Aliases = @("devel", "development")
        Usage = "dev"
        Category = "Development"
        Description = "Workspace Development Hub, projects, runtimes & AI coding agents"
        Examples = @("dev", "devel")
        Risk = "Safe"
    }
    "agents" = [PSCustomObject]@{
        Name = "agents"
        Aliases = @("agent", "ai")
        Usage = "agents"
        Category = "Development"
        Description = "Inspect registered AI coding agents (Freebuff, Antigravity, VS Code)"
        Examples = @("agents", "agent")
        Risk = "Safe"
    }
    "freebuff" = [PSCustomObject]@{
        Name = "freebuff"
        Aliases = @("fb")
        Usage = "freebuff [project]"
        Category = "Development"
        Description = "Launch Freebuff interactive terminal AI coding agent session"
        Examples = @("freebuff", "freebuff termux-ai-workstation")
        Risk = "Safe"
    }
    "diagnostics" = [PSCustomObject]@{
        Name = "diagnostics"
        Aliases = @("diag", "doc", "doctor")
        Usage = "diagnostics"
        Category = "System"
        Description = "Run workstation health diagnostics and doctor checks"
        Examples = @("diagnostics", "doc")
        Risk = "Safe"
    }
    "start" = [PSCustomObject]@{
        Name = "start"
        Aliases = @()
        Usage = "start <workload>"
        Category = "Control"
        Description = "Start a registered workload or service (governed)"
        Examples = @("start mysql", "start ollama")
        Risk = "Governed"
    }
    "stop" = [PSCustomObject]@{
        Name = "stop"
        Aliases = @()
        Usage = "stop <workload>"
        Category = "Control"
        Description = "Stop a registered workload (safety modal for protected)"
        Examples = @("stop docker", "stop discord")
        Risk = "Governed"
    }
    "restart" = [PSCustomObject]@{
        Name = "restart"
        Aliases = @()
        Usage = "restart <workload>"
        Category = "Control"
        Description = "Restart a registered workload (governed)"
        Examples = @("restart mysql")
        Risk = "Governed"
    }
    "info" = [PSCustomObject]@{
        Name = "info"
        Aliases = @()
        Usage = "info <workload|tool>"
        Category = "Discovery"
        Description = "Show detailed inspection for a workload or tool"
        Examples = @("info ollama", "info vlc")
        Risk = "Safe"
    }
    "open" = [PSCustomObject]@{
        Name = "open"
        Aliases = @("launch")
        Usage = "open <tool>"
        Category = "Tools"
        Description = "Launch an external tool or open its Web UI"
        Examples = @("open vlc", "open sonarr")
        Risk = "Safe"
    }
    "cd" = [PSCustomObject]@{
        Name = "cd"
        Aliases = @()
        Usage = "cd [path]"
        Category = "Shell"
        Description = "Change current workspace directory"
        Examples = @("cd E:\Workspace", "cd ..", "cd ~")
        Risk = "Safe"
    }
    "pwd" = [PSCustomObject]@{
        Name = "pwd"
        Aliases = @()
        Usage = "pwd"
        Category = "Shell"
        Description = "Display current working directory and volume info"
        Examples = @("pwd")
        Risk = "Safe"
    }
    "ls" = [PSCustomObject]@{
        Name = "ls"
        Aliases = @("dir")
        Usage = "ls [path]"
        Category = "Shell"
        Description = "List directory contents in dedicated scrollable table"
        Examples = @("ls", "ls E:\Workspace", "ls ..")
        Risk = "Safe"
    }
    "help" = [PSCustomObject]@{
        Name = "help"
        Aliases = @("?")
        Usage = "help [command]"
        Category = "Discovery"
        Description = "Display command directory or detailed help for a command"
        Examples = @("help", "help start", "help ls")
        Risk = "Safe"
    }
    "guide" = [PSCustomObject]@{
        Name = "guide"
        Aliases = @("g", "docs", "learn", "manual")
        Usage = "guide [topic]"
        Category = "Discovery"
        Description = "Interactive structured workstation learning & reference guide"
        Examples = @("guide", "guide shell", "guide powertoys", "guide media")
        Risk = "Safe"
    }
    "clear" = [PSCustomObject]@{
        Name = "clear"
        Aliases = @("cls")
        Usage = "clear"
        Category = "Shell"
        Description = "Clear screen and force complete redraw"
        Examples = @("clear", "cls")
        Risk = "Safe"
    }
    "home" = [PSCustomObject]@{
        Name = "home"
        Aliases = @("overview")
        Usage = "home"
        Category = "Navigation"
        Description = "Return to WorkCtl Home Cockpit"
        Examples = @("home")
        Risk = "Safe"
    }
    "back" = [PSCustomObject]@{
        Name = "back"
        Aliases = @()
        Usage = "back"
        Category = "Navigation"
        Description = "Return to previous screen"
        Examples = @("back")
        Risk = "Safe"
    }
    "exit" = [PSCustomObject]@{
        Name = "exit"
        Aliases = @("q")
        Usage = "exit"
        Category = "Shell"
        Description = "Exit WorkCtl shell"
        Examples = @("exit", "q")
        Risk = "Safe"
    }
    "!" = [PSCustomObject]@{
        Name = "!"
        Aliases = @("exec")
        Usage = "! <powershell-command>"
        Category = "Shell"
        Description = "Execute native PowerShell command and capture scrollable output"
        Examples = @("! Get-Date", "! git status", "! ipconfig")
        Risk = "Native"
    }
}

# =================================================================
# 1. HISTORY MANAGEMENT
# =================================================================

function Get-ShellHistoryList {
    if ($script:ShellHistory.Count -eq 0 -and (Test-Path -LiteralPath $script:ShellHistoryFilePath)) {
        try {
            $lines = Get-Content -LiteralPath $script:ShellHistoryFilePath -Tail 500 -ErrorAction SilentlyContinue
            foreach ($line in @($lines)) {
                if ($line) {
                    try {
                        $entry = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($entry -and $entry.cmd) {
                            $script:ShellHistory.Add([string]$entry.cmd)
                        }
                    } catch {}
                }
            }
        } catch {}
    }
    return $script:ShellHistory.ToArray()
}

function Add-ShellHistoryEntry {
    param([string]$Command)

    $cmd = $Command.Trim()
    if (!$cmd) { return }

    # Never persist secrets or sensitive parameters
    if ($cmd -match '(?i)(password|secret|token|api_key|bearer|passwd|credential)') {
        return
    }

    # Avoid duplicate consecutive commands
    if ($script:ShellHistory.Count -gt 0 -and $script:ShellHistory[$script:ShellHistory.Count - 1] -ieq $cmd) {
        return
    }

    $script:ShellHistory.Add($cmd)
    if ($script:ShellHistory.Count -gt 500) {
        $script:ShellHistory.RemoveAt(0)
    }

    try {
        $record = [PSCustomObject]@{
            ts = [datetime]::UtcNow.ToString("o")
            cmd = $cmd
        }
        $json = ($record | ConvertTo-Json -Compress) + "`n"
        [System.IO.File]::AppendAllText($script:ShellHistoryFilePath, $json, [System.Text.Encoding]::UTF8)
    } catch {}
}

# =================================================================
# 2. CACHED SYSTEM & REGISTRY DATA PROVIDERS
# =================================================================

function Get-ShellCachedWorkloads {
    $cfgPath = Join-Path $script:ShellRoot "config\workloads.json"
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $item = Get-Item -LiteralPath $cfgPath -ErrorAction SilentlyContinue
            if (!$script:ShellWorkloadsConfigCache -or $script:ShellWorkloadsConfigMtime -ne $item.LastWriteTimeUtc) {
                $script:ShellWorkloadsConfigCache = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
                $script:ShellWorkloadsConfigMtime = $item.LastWriteTimeUtc
            }
        } catch {}
    }
    return $script:ShellWorkloadsConfigCache
}

function Get-ShellCachedTools {
    $cfgPath = Join-Path $script:ShellRoot "config\tools.json"
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $item = Get-Item -LiteralPath $cfgPath -ErrorAction SilentlyContinue
            if (!$script:ShellToolsConfigCache -or $script:ShellToolsConfigMtime -ne $item.LastWriteTimeUtc) {
                $script:ShellToolsConfigCache = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
                $script:ShellToolsConfigMtime = $item.LastWriteTimeUtc
            }
        } catch {}
    }
    return $script:ShellToolsConfigCache
}

function Get-ShellProcessesCached {
    $now = [datetime]::UtcNow
    if (!$script:ShellProcessesCache -or ($now - $script:ShellProcessesCacheTime).TotalSeconds -ge 3.0) {
        try {
            $procs = @(Get-Process -ErrorAction SilentlyContinue |
                Sort-Object WorkingSet64 -Descending |
                Select-Object -First 35 |
                ForEach-Object {
                    [PSCustomObject]@{
                        Id = $_.Id
                        Name = $_.Name
                        RAM_MB = [math]::Round($_.WorkingSet64 / 1MB, 1)
                        CPU_s = if ($_.CPU -ne $null) { [math]::Round($_.CPU, 1) } else { 0.0 }
                        Path = try { $_.Path } catch { "" }
                    }
                })
            $script:ShellProcessesCache = $procs
            $script:ShellProcessesCacheTime = $now
        } catch {}
    }
    return $script:ShellProcessesCache
}

function Get-ShellServicesCached {
    $now = [datetime]::UtcNow
    if (!$script:ShellServicesCache -or ($now - $script:ShellServicesCacheTime).TotalSeconds -ge 5.0) {
        try {
            $svcs = @(Get-Service -ErrorAction SilentlyContinue |
                Sort-Object Status, DisplayName |
                Select-Object -First 50 |
                ForEach-Object {
                    [PSCustomObject]@{
                        Name = $_.Name
                        DisplayName = $_.DisplayName
                        Status = [string]$_.Status
                        StartType = [string]$_.StartType
                    }
                })
            $script:ShellServicesCache = $svcs
            $script:ShellServicesCacheTime = $now
        } catch {}
    }
    return $script:ShellServicesCache
}

$script:ShellNetworkOverviewCache = $null
$script:ShellNetworkOverviewCacheTime = [datetime]::MinValue
$script:ShellNetworkCache = $null
$script:ShellNetworkCacheTime = [datetime]::MinValue
$script:ProcessNameCache = @{}
$script:ProcessNameCacheTime = [datetime]::MinValue

function Get-ShellProcessMap {
    $now = [datetime]::UtcNow
    if (!$script:ProcessNameCache -or ($now - $script:ProcessNameCacheTime).TotalSeconds -ge 4.0) {
        $map = @{}
        try {
            $procs = [System.Diagnostics.Process]::GetProcesses()
            foreach ($p in $procs) {
                $map[$p.Id] = $p.ProcessName
            }
        } catch {
            foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
                $map[$p.Id] = $p.ProcessName
            }
        }
        $script:ProcessNameCache = $map
        $script:ProcessNameCacheTime = $now
    }
    return $script:ProcessNameCache
}

function Get-ShellNetworkOverviewCached([switch]$Force) {
    $now = [datetime]::UtcNow
    if ($Force -or !$script:ShellNetworkOverviewCache -or ($now - $script:ShellNetworkOverviewCacheTime).TotalSeconds -ge 5.0) {
        $info = [PSCustomObject]@{
            AdapterName    = "Unknown"
            AdapterType    = "Ethernet/Wi-Fi"
            Status         = "Down"
            IPv4Address    = "Not Configured"
            SubnetMask     = ""
            Gateway        = "None"
            DnsServers     = "None"
            MacAddress     = ""
            LinkSpeed      = ""
            BytesReceived  = [int64]0
            BytesSent      = [int64]0
            ListeningPorts = 0
        }
        try {
            $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
            $active = $nics | Where-Object {
                $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up -and
                $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback -and
                $_.GetIPProperties().GatewayAddresses.Count -gt 0
            } | Select-Object -First 1

            if (!$active) {
                $active = $nics | Where-Object {
                    $_.OperationalStatus -eq [System.Net.NetworkInformation.OperationalStatus]::Up -and
                    $_.NetworkInterfaceType -ne [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback
                } | Select-Object -First 1
            }

            if ($active) {
                $info.AdapterName = $active.Name
                $info.AdapterType = $active.NetworkInterfaceType.ToString()
                $info.Status = $active.OperationalStatus.ToString()
                $info.MacAddress = ($active.GetPhysicalAddress().GetAddressBytes() | ForEach-Object { "{0:X2}" -f $_ }) -join "-"

                $speedBps = $active.Speed
                if ($speedBps -ge 1000000000) {
                    $info.LinkSpeed = "{0:N1} Gbps" -f ($speedBps / 1000000000.0)
                } elseif ($speedBps -ge 1000000) {
                    $info.LinkSpeed = "{0:N0} Mbps" -f ($speedBps / 1000000.0)
                }

                $ipProps = $active.GetIPProperties()
                $ipv4Obj = $ipProps.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
                if ($ipv4Obj) {
                    $info.IPv4Address = $ipv4Obj.Address.ToString()
                    if ($ipv4Obj.IPv4Mask) { $info.SubnetMask = $ipv4Obj.IPv4Mask.ToString() }
                }

                $gwObj = $ipProps.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
                if ($gwObj) {
                    $info.Gateway = $gwObj.Address.ToString()
                } elseif ($ipProps.GatewayAddresses.Count -gt 0) {
                    $info.Gateway = $ipProps.GatewayAddresses[0].Address.ToString()
                }

                $dnsList = @($ipProps.DnsAddresses | ForEach-Object { $_.ToString() })
                if ($dnsList.Count -gt 0) {
                    $info.DnsServers = ($dnsList | Select-Object -First 3) -join ", "
                }

                $stats = $active.GetIPStatistics()
                $info.BytesReceived = $stats.BytesReceived
                $info.BytesSent = $stats.BytesSent
            }

            $ports = Get-ShellNetworkPortsCached
            $info.ListeningPorts = $ports.Count
        } catch {}

        $script:ShellNetworkOverviewCache = $info
        $script:ShellNetworkOverviewCacheTime = $now
    }
    return $script:ShellNetworkOverviewCache
}

function Get-ShellNetworkPortsCached([string]$Filter = "ALL", [switch]$Force) {
    $now = [datetime]::UtcNow
    if ($Force -or !$script:ShellNetworkCache -or ($now - $script:ShellNetworkCacheTime).TotalSeconds -ge 5.0) {
        $ports = New-Object System.Collections.Generic.List[object]
        $procMap = Get-ShellProcessMap

        try {
            $lines = @(netstat -ano -p tcp | Select-String "LISTENING")
            foreach ($line in $lines) {
                $parts = ($line.ToString() -split '\s+') | Where-Object { $_ }
                if ($parts.Count -ge 4) {
                    $addrFull = $parts[1]
                    $lastColon = $addrFull.LastIndexOf(':')
                    $addr = if ($lastColon -ge 0) { $addrFull.Substring(0, $lastColon) } else { $addrFull }
                    $port = if ($lastColon -ge 0) { $addrFull.Substring($lastColon + 1) } else { "" }
                    $pidVal = $parts[$parts.Count - 1]
                    [int]$pidInt = 0
                    [int]::TryParse($pidVal, [ref]$pidInt) | Out-Null

                    $pName = if ($procMap.ContainsKey($pidInt)) { $procMap[$pidInt] } else { "" }
                    if (!$pName -and $pidInt -eq 4) { $pName = "System" }

                    $scope = if ($addr -in @("127.0.0.1", "::1", "[::1]")) {
                        "Localhost"
                    } elseif ($addr -in @("0.0.0.0", "::", "[::]")) {
                        "LAN"
                    } else {
                        "Private"
                    }

                    $knownService = switch ($port) {
                        "22"    { "SSH" }
                        "80"    { "HTTP" }
                        "443"   { "HTTPS" }
                        "445"   { "SMB / Lanman" }
                        "135"   { "RPC" }
                        "3306"  { "MySQL 8" }
                        "5432"  { "PostgreSQL" }
                        "6379"  { "Redis" }
                        "8080"  { "Dev Server" }
                        "8989"  { "Sonarr" }
                        "7878"  { "Radarr" }
                        "8085"  { "qBittorrent" }
                        "11434" { "Ollama" }
                        default { "" }
                    }

                    [int]$portInt = 0
                    [int]::TryParse($port, [ref]$portInt) | Out-Null

                    $ports.Add([PSCustomObject]@{
                        Port          = $portInt
                        PortText      = $port
                        LocalAddress  = $addr
                        Address       = $addr
                        FullAddress   = $addrFull
                        LocalPort     = $portInt
                        State         = "LISTENING"
                        PID           = $pidInt
                        OwningProcess = $pidInt
                        Process       = if ($pName) { $pName } else { "PID $pidInt" }
                        ProcessName   = $pName
                        Scope         = $scope
                        KnownService  = $knownService
                    })
                }
            }
        } catch {}

        $script:ShellNetworkCache = @($ports | Sort-Object Port)
        $script:ShellNetworkCacheTime = $now
    }

    $all = @($script:ShellNetworkCache)
    if (!$Filter -or $Filter -eq "ALL") {
        return $all
    }

    $res = switch ($Filter.ToUpperInvariant()) {
        "LOCALHOST" { @($all | Where-Object { $_.Scope -eq "Localhost" }) }
        "LAN"       { @($all | Where-Object { $_.Scope -eq "LAN" }) }
        "SYSTEM"    { @($all | Where-Object { $_.Process -match "^(System|svchost|lsass|services|spoolsv)$" }) }
        "WORKCTL"   { @($all | Where-Object { $_.Process -match "(sonarr|torrent|ollama|mysql|node|code|antigravity|freebuff)" -or $_.KnownService -ne "" }) }
        default     { $all }
    }
    return $res
}

function Get-ShellNetworkCached {
    return Get-ShellNetworkPortsCached -Filter "ALL"
}

function Get-ShellStorageCached {
    $now = [datetime]::UtcNow
    if (!$script:ShellStorageCache -or ($now - $script:ShellStorageCacheTime).TotalSeconds -ge 10.0) {
        try {
            $disks = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $totalGB = [math]::Round($_.Size / 1GB, 1)
                    $freeGB = [math]::Round($_.FreeSpace / 1GB, 1)
                    $usedGB = [math]::Max(0.0, [math]::Round(($totalGB - $freeGB), 1))
                    $usedPct = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100, 1) } else { 0 }
                    [PSCustomObject]@{
                        Drive = $_.DeviceID
                        VolumeName = $_.VolumeName
                        FileSystem = $_.FileSystem
                        TotalGB = $totalGB
                        UsedGB = $usedGB
                        FreeGB = $freeGB
                        UsedPercent = $usedPct
                    }
                })
            $script:ShellStorageCache = $disks
            $script:ShellStorageCacheTime = $now
        } catch {}
    }
    return $script:ShellStorageCache
}

function Get-ShellProjectsCached {
    $now = [datetime]::UtcNow
    if (!$script:ShellProjectsCache -or ($now - $script:ShellProjectsCacheTime).TotalSeconds -ge 20.0) {
        try {
            $roots = @("E:\Workspace", "E:\TOOLS\WorkstationControl")
            $projects = New-Object System.Collections.Generic.List[object]

            foreach ($r in $roots) {
                if (Test-Path -LiteralPath $r) {
                    # Top level inspection
                    $candidates = @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | Select-Object -First 25)
                    foreach ($c in $candidates) {
                        $pPath = $c.FullName
                        $marker = ""
                        if (Test-Path (Join-Path $pPath ".git")) { $marker = "git" }
                        elseif (Test-Path (Join-Path $pPath "package.json")) { $marker = "node" }
                        elseif (Test-Path (Join-Path $pPath "Cargo.toml")) { $marker = "rust" }
                        elseif (Test-Path (Join-Path $pPath "pyproject.toml")) { $marker = "python" }
                        elseif (Test-Path (Join-Path $pPath "requirements.txt")) { $marker = "python" }
                        elseif (Test-Path (Join-Path $pPath "CMakeLists.txt")) { $marker = "cmake" }

                        $branch = ""
                        $headPath = Join-Path $pPath ".git\HEAD"
                        if (Test-Path -LiteralPath $headPath) {
                            try {
                                $h = (Get-Content -LiteralPath $headPath -TotalCount 1 -ErrorAction SilentlyContinue).Trim()
                                if ($h -match 'ref: refs/heads/(.+)') { $branch = $matches[1] }
                            } catch {}
                        }

                        $projects.Add([PSCustomObject]@{
                            Name = $c.Name
                            Path = $pPath
                            Marker = if ($marker) { $marker } else { "directory" }
                            Branch = if ($branch) { $branch } else { "main" }
                            LastWrite = $c.LastWriteTime
                        })
                    }
                }
            }
            $script:ShellProjectsCache = $projects.ToArray()
            $script:ShellProjectsCacheTime = $now
        } catch {}
    }
    return $script:ShellProjectsCache
}

# =================================================================
# 3. GLOBAL ENTITY INDEX & AUTOCOMPLETION / SUGGESTIONS
# =================================================================

function Get-ShellEntityIndex {
    $now = [datetime]::UtcNow
    if (!$script:ShellEntityIndexCache -or ($now - $script:ShellEntityIndexCacheTime).TotalSeconds -ge 15.0) {
        $entities = New-Object System.Collections.Generic.List[object]

        # 1. Workloads
        $wReg = Get-ShellCachedWorkloads
        if ($wReg -and $wReg.components) {
            foreach ($p in $wReg.components.PSObject.Properties) {
                $entities.Add([PSCustomObject]@{
                    Kind = "WORKLOAD"
                    Key = $p.Name
                    Label = $p.Value.label
                    Target = $p.Name
                    Group = if ($p.Value.groups) { $p.Value.groups[0] } else { "workload" }
                    Policy = if ($p.Value.stopPolicy) { $p.Value.stopPolicy } else { "safe" }
                })
            }
        }

        # 2. Tools
        $tReg = Get-ShellCachedTools
        if ($tReg -and $tReg.tools) {
            foreach ($p in $tReg.tools.PSObject.Properties) {
                $entities.Add([PSCustomObject]@{
                    Kind = "TOOL"
                    Key = $p.Name
                    Label = $p.Value.label
                    Target = $p.Name
                    Group = $p.Value.category
                    Policy = "tool"
                })
            }
        }

        # 3. PowerToys Modules
        if (Get-Command Get-PowerToysRegistry -ErrorAction SilentlyContinue) {
            $ptReg = Get-PowerToysRegistry
            if ($ptReg -is [System.Collections.IDictionary]) {
                foreach ($k in $ptReg.Keys) {
                    $val = $ptReg[$k]
                    $entities.Add([PSCustomObject]@{
                        Kind = "POWERTOYS"
                        Key = [string]$k
                        Label = if ($val.Description) { "$k - $($val.Description)" } else { [string]$k }
                        Target = [string]$k
                        Group = "powertoys"
                        Policy = "read-only"
                    })
                }
            } elseif ($ptReg -and $ptReg.modules) {
                foreach ($p in $ptReg.modules.PSObject.Properties) {
                    $entities.Add([PSCustomObject]@{
                        Kind = "POWERTOYS"
                        Key = $p.Name
                        Label = $p.Value.label
                        Target = $p.Name
                        Group = "powertoys"
                        Policy = "read-only"
                    })
                }
            }
        } elseif ($script:PTModuleMetadata) {
            foreach ($k in $script:PTModuleMetadata.Keys) {
                $val = $script:PTModuleMetadata[$k]
                $entities.Add([PSCustomObject]@{
                    Kind = "POWERTOYS"
                    Key = [string]$k
                    Label = if ($val.Description) { "$k - $($val.Description)" } else { [string]$k }
                    Target = [string]$k
                    Group = "powertoys"
                    Policy = "read-only"
                })
            }
        }

        # 4. System Destinations
        $dests = @(
            @{ Key = "overview"; Label = "Overview Cockpit" },
            @{ Key = "resources"; Label = "Resource Telemetry" },
            @{ Key = "workloads"; Label = "Workload Engine" },
            @{ Key = "powertoys"; Label = "PowerToys Control Plane" },
            @{ Key = "media"; Label = "Smart Media Control" },
            @{ Key = "tools"; Label = "External Tools Browser" },
            @{ Key = "network"; Label = "Network & Ports Inspector" },
            @{ Key = "storage"; Label = "Drives & Storage" },
            @{ Key = "projects"; Label = "Workspace Projects" },
            @{ Key = "dev"; Label = "Development Hub & AI Coding Agents" },
            @{ Key = "agents"; Label = "AI Coding Agents & Runtimes" },
            @{ Key = "processes"; Label = "Processes & Top Memory" },
            @{ Key = "services"; Label = "System Services" },
            @{ Key = "diagnostics"; Label = "System Doctor & Protected Components" }
        )
        foreach ($d in $dests) {
            $entities.Add([PSCustomObject]@{
                Kind = "DESTINATION"
                Key = $d.Key
                Label = $d.Label
                Target = $d.Key
                Group = "navigation"
                Policy = "read"
            })
        }

        # 5. Core Actions
        $actions = @(
            @{ Key = "doctor"; Label = "Run Workstation Doctor" },
            @{ Key = "quiet"; Label = "Audit Quiet Mode" },
            @{ Key = "stop-all"; Label = "Stop All Managed Workloads" },
            @{ Key = "groups"; Label = "View Workload Groups" },
            @{ Key = "protected"; Label = "View Protected System Components" }
        )
        foreach ($a in $actions) {
            $entities.Add([PSCustomObject]@{
                Kind = "ACTION"
                Key = $a.Key
                Label = $a.Label
                Target = $a.Key
                Group = "action"
                Policy = "safe"
            })
        }

        $script:ShellEntityIndexCache = $entities.ToArray()
        $script:ShellEntityIndexCacheTime = $now
    }
    return $script:ShellEntityIndexCache
}

function Get-ShellCompletionCandidates {
    param(
        [string]$InputText,
        [string]$Context = "home"
    )

    $text = $InputText.TrimStart()
    $commands = @($script:ShellCommandRegistry.Keys)

    # Empty text -> complete commands
    if (!$text) {
        return $commands
    }

    # If typing first token (no space yet)
    if ($text.IndexOf(" ") -lt 0) {
        $matches = @($commands | Where-Object { $_.StartsWith($text, [System.StringComparison]::OrdinalIgnoreCase) })
        # Also check aliases
        foreach ($k in $script:ShellAliases.Keys) {
            if ($k.StartsWith($text, [System.StringComparison]::OrdinalIgnoreCase) -and $matches -notcontains $k) {
                $matches += $k
            }
        }
        return $matches
    }

    # Subcommand / entity completion
    $parts = $text -split '\s+'
    $origVerb = $parts[0]
    $verb = $parts[0].ToLowerInvariant()
    $argPrefix = if ($parts.Count -gt 1) { $parts[$parts.Count - 1] } else { "" }

    # Resolve alias for dispatch
    $canonicalVerb = $verb
    if ($script:ShellAliases.Contains($verb)) {
        $canonicalVerb = $script:ShellAliases[$verb]
    }

    $index = Get-ShellEntityIndex

    switch ($canonicalVerb) {
        { $_ -in @("help", "?") } {
            $cmdMatches = @($script:ShellCommandRegistry.Keys | Where-Object { $_.StartsWith($argPrefix, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { "$origVerb $_" })
            return $cmdMatches
        }
        { $_ -in @("start", "stop", "restart", "info") } {
            $wMatches = @($index | Where-Object { $_.Kind -eq "WORKLOAD" -and $_.Key.StartsWith($argPrefix, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { "$origVerb $($_.Key)" })
            return $wMatches
        }
        { $_ -in @("open", "launch") } {
            $tMatches = @($index | Where-Object { ($_.Kind -eq "TOOL" -or $_.Kind -eq "WORKLOAD") -and $_.Key.StartsWith($argPrefix, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { "$origVerb $($_.Key)" })
            return $tMatches
        }
        { $_ -in @("pt", "powertoys") } {
            $ptMatches = @($index | Where-Object { $_.Kind -eq "POWERTOYS" -and $_.Key.StartsWith($argPrefix, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { "$origVerb $($_.Key)" })
            return $ptMatches
        }
        { $_ -in @("media") } {
            $mSub = @("movies", "tv", "sonarr", "torlink", "downloads", "search")
            $mMatches = @($mSub | Where-Object { $_.StartsWith($argPrefix, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { "$origVerb $_" })
            return $mMatches
        }
        { $_ -in @("resources", "res") } {
            $rSub = @("cpu", "ram", "gpu", "net", "disk")
            return @($rSub | Where-Object { $_.StartsWith($argPrefix, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { "$origVerb $_" })
        }
        { $_ -in @("workloads", "wl") } {
            $wSub = @("ai", "dev", "cloud", "gaming", "quiet")
            return @($wSub | Where-Object { $_.StartsWith($argPrefix, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { "$origVerb $_" })
        }
        { $_ -in @("cd", "ls", "dir") } {
            $currentDir = if ($script:ShellCurrentDirectory) { $script:ShellCurrentDirectory } else { "E:\Workspace" }
            if (Test-Path -LiteralPath $currentDir) {
                $dirs = @(Get-ChildItem -LiteralPath $currentDir -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name.StartsWith($argPrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
                    ForEach-Object { "$origVerb $($_.Name)" })
                return $dirs
            }
        }
    }

    return @()
}

function Get-ShellGhostSuggestion {
    param(
        [string]$InputText,
        [string]$Context = "home"
    )

    $trimmed = $InputText.Trim()
    if (!$trimmed) { return "" }

    # 1. Check history first (Fish style)
    $hist = Get-ShellHistoryList
    for ($i = $hist.Count - 1; $i -ge 0; $i--) {
        $hCmd = [string]$hist[$i]
        if ($hCmd.StartsWith($trimmed, [System.StringComparison]::OrdinalIgnoreCase) -and $hCmd.Length -gt $trimmed.Length) {
            return $hCmd
        }
    }

    # 2. Check completions
    $candidates = @(Get-ShellCompletionCandidates -InputText $trimmed -Context $Context)
    if ($candidates.Count -gt 0) {
        $c0 = [string]$candidates[0]
        if ($c0.StartsWith($trimmed, [System.StringComparison]::OrdinalIgnoreCase) -and $c0.Length -gt $trimmed.Length) {
            return $c0
        }
    }

    return ""
}

# =================================================================
# 4. SHELL STATE MODEL
# =================================================================

function New-WorkCtlShellState {
    param(
        [string]$InitialScreen = "shell-home",
        [string]$CurrentDirectory = ""
    )

    $defaultDir = if ($CurrentDirectory) { $CurrentDirectory } else { "E:\Workspace" }
    if (!(Test-Path -LiteralPath $defaultDir)) {
        $defaultDir = [System.Environment]::CurrentDirectory
    }
    $script:ShellCurrentDirectory = $defaultDir

    [PSCustomObject]@{
        # Core Lifecycle & Navigation
        Screen = $InitialScreen
        PreviousScreen = "shell-home"
        FailingScreen = ""
        Running = $true
        Dirty = $true
        Context = "home"
        LastAction = "None"
        CurrentDirectory = $defaultDir

        # Selection & Scroll States
        SelectedHomeItem = 0
        SelectedWorkloadIndex = 0
        SelectedWorkload = ""
        WorkloadScroll = 0
        WorkloadFilter = "ALL"
        SelectedWorkloadCategory = "ALL"
        SelectedToolIndex = 0
        SelectedTool = ""
        ToolScroll = 0
        ToolFilter = "ALL"
        SelectedProcessIndex = 0
        SelectedProcess = ""
        ProcessScroll = 0
        SelectedProjectIndex = 0
        SelectedProject = ""
        ProjectScroll = 0
        SelectedStorageIndex = 0
        SelectedStorage = ""
        StorageScroll = 0
        SelectedServiceIndex = 0
        SelectedService = ""
        ServiceScroll = 0
        SelectedHardwareIndex = 0
        HardwareScroll = 0
        SelectedNetworkIndex = 0
        SelectedPortIndex = 0
        PortScroll = 0
        PortFilter = "ALL"

        # Search
        SearchQuery = ""
        SelectedSearchIndex = 0
        SearchScroll = 0
        PreSearchScreen = "shell-home"

        # Governance & Confirm Dialog Overlay
        ConfirmState = $null # @{ Title; MessageLines; Policy; Action; Target; Workload; ReturnScreen }

        # Notifications (Cockpit Toast)
        NotificationText = ""
        NotificationColor = [ConsoleColor]::Green
        NotificationUntil = [datetime]::MinValue

        # Cached Live Telemetry & Status
        CachedResSnapshot = $null
        LastResRefresh = [datetime]::MinValue
        ResIntervalMs = 1500

        # Dedicated Command Output State
        CommandOutput = $null # @{ Title; Command; Path; IsTable; Rows; Lines; Scroll; ReturnScreen }

        # Runtime Error State for Recovery Boundary
        LastError = $null
        LastErrorId = ""
        ShowErrorDetails = $false

        # Subsystem-Owned State (Nested)
        GuideState = $null
        DevelopmentState = $null
        ToolsState = $null

        # WCTL-3 Navigation Stack & Expanded Machine Control
        ScreenStack = New-Object System.Collections.Generic.Stack[object]
        SelectedAgentIndex = 0
        AgentScroll = 0
        SelectedCategory = "ALL"
        ExitRequested = $false
        ProfileStats = $null
        DirtyFlags = [ordered]@{ Navigation = $true; Status = $true; Content = $true; Layout = $true }
    }
}

function Test-WorkCtlShellState {
    param($State)

    $requiredProps = @(
        "Screen", "PreviousScreen", "FailingScreen", "Running", "Dirty", "Context", "LastAction", "CurrentDirectory",
        "SelectedHomeItem", "SelectedWorkloadIndex", "SelectedWorkload", "WorkloadScroll", "WorkloadFilter", "SelectedWorkloadCategory",
        "SelectedToolIndex", "SelectedTool", "ToolScroll", "ToolFilter", "SelectedProcessIndex", "SelectedProcess", "ProcessScroll",
        "SelectedProjectIndex", "SelectedProject", "ProjectScroll",
        "SearchQuery", "SelectedSearchIndex", "SearchScroll", "PreSearchScreen",
        "ConfirmState", "NotificationText", "NotificationColor", "NotificationUntil",
        "CachedResSnapshot", "LastResRefresh", "ResIntervalMs",
        "CommandOutput", "LastError", "LastErrorId", "ShowErrorDetails",
        "GuideState", "DevelopmentState", "ToolsState",
        "ScreenStack", "SelectedServiceIndex", "SelectedService", "ServiceScroll",
        "SelectedStorageIndex", "SelectedStorage", "StorageScroll",
        "SelectedHardwareIndex", "HardwareScroll", "SelectedCategory", "DirtyFlags"
    )

    $missing = New-Object System.Collections.Generic.List[string]
    $invalidTypes = New-Object System.Collections.Generic.List[string]

    if ($null -eq $State -or !($State -is [System.Management.Automation.PSCustomObject])) {
        return [PSCustomObject]@{
            Valid = $false
            Missing = @("StateObjectNullOrNotPSCustomObject")
            InvalidTypes = @()
        }
    }

    foreach ($p in $requiredProps) {
        $prop = $State.PSObject.Properties[$p]
        if ($null -eq $prop) {
            $missing.Add($p)
        }
    }

    # Type validation for critical fields
    if ($State.PSObject.Properties['Screen'] -and !($State.Screen -is [string])) {
        $invalidTypes.Add("Screen must be [string]")
    }
    if ($State.PSObject.Properties['Running'] -and !($State.Running -is [bool])) {
        $invalidTypes.Add("Running must be [bool]")
    }
    if ($State.PSObject.Properties['LastAction'] -and !($State.LastAction -is [string])) {
        $invalidTypes.Add("LastAction must be [string]")
    }
    if ($State.PSObject.Properties['SelectedHomeItem'] -and !($State.SelectedHomeItem -is [int])) {
        $invalidTypes.Add("SelectedHomeItem must be [int]")
    }
    if ($State.PSObject.Properties['SelectedToolIndex'] -and !($State.SelectedToolIndex -is [int])) {
        $invalidTypes.Add("SelectedToolIndex must be [int]")
    }
    if ($State.PSObject.Properties['SelectedWorkloadIndex'] -and !($State.SelectedWorkloadIndex -is [int])) {
        $invalidTypes.Add("SelectedWorkloadIndex must be [int]")
    }

    [PSCustomObject]@{
        Valid = ($missing.Count -eq 0 -and $invalidTypes.Count -eq 0)
        Missing = $missing.ToArray()
        InvalidTypes = $invalidTypes.ToArray()
    }
}

function Confirm-WorkCtlShellState {
    param($State)

    if ($null -eq $State) {
        return (New-WorkCtlShellState)
    }

    $defaultDir = "E:\Workspace"
    if (!(Test-Path -LiteralPath $defaultDir)) {
        $defaultDir = [System.Environment]::CurrentDirectory
    }

    $canonicalDefaults = [ordered]@{
        Screen                   = "shell-home"
        PreviousScreen           = "shell-home"
        FailingScreen            = ""
        Running                  = $true
        Dirty                    = $true
        Context                  = "home"
        LastAction               = "None"
        CurrentDirectory         = $defaultDir
        SelectedHomeItem         = 0
        SelectedWorkloadIndex    = 0
        SelectedWorkload         = ""
        WorkloadScroll           = 0
        WorkloadFilter           = "ALL"
        SelectedWorkloadCategory = "ALL"
        SelectedToolIndex        = 0
        SelectedTool             = ""
        ToolScroll               = 0
        ToolFilter               = "ALL"
        SelectedProcessIndex     = 0
        SelectedProcess          = ""
        ProcessScroll            = 0
        SelectedProjectIndex     = 0
        SelectedProject          = ""
        ProjectScroll            = 0
        SearchQuery              = ""
        SelectedSearchIndex      = 0
        SearchScroll             = 0
        PreSearchScreen          = "shell-home"
        ConfirmState             = $null
        NotificationText         = ""
        NotificationColor        = [ConsoleColor]::Green
        NotificationUntil        = [datetime]::MinValue
        CachedResSnapshot        = $null
        LastResRefresh           = [datetime]::MinValue
        ResIntervalMs            = 1500
        CommandOutput            = $null
        LastError                = $null
        LastErrorId              = ""
        ShowErrorDetails         = $false
        GuideState               = $null
        DevelopmentState         = $null
        ToolsState               = $null
        ScreenStack              = (New-Object System.Collections.Generic.Stack[object])
        SelectedServiceIndex     = 0
        SelectedService          = ""
        ServiceScroll            = 0
        SelectedStorageIndex     = 0
        SelectedStorage          = ""
        StorageScroll            = 0
        SelectedHardwareIndex    = 0
        HardwareScroll           = 0
        SelectedAgentIndex       = 0
        AgentScroll              = 0
        SelectedCategory         = "ALL"
        ExitRequested            = $false
        DirtyFlags               = [ordered]@{ Navigation = $true; Status = $true; Content = $true; Layout = $true }
    }

    foreach ($propName in $canonicalDefaults.Keys) {
        if ($null -eq $State.PSObject.Properties[$propName]) {
            $State | Add-Member -NotePropertyName $propName -NotePropertyValue $canonicalDefaults[$propName] -Force
        }
    }

    return $State
}

function Initialize-ShellAppState {
    param(
        [string]$InitialScreen = "shell-home",
        [string]$CurrentDirectory = ""
    )
    New-WorkCtlShellState -InitialScreen $InitialScreen -CurrentDirectory $CurrentDirectory
}

function Set-ShellNotification {
    param(
        $State,
        [string]$Message,
        $Color = [ConsoleColor]::Green,
        [int]$DurationSeconds = 4
    )

    $resolvedColor = [ConsoleColor]::Green
    if ($Color -is [System.ConsoleColor]) {
        $resolvedColor = $Color
    } elseif ($Color -ne $null) {
        $cStr = [string]$Color -replace '(?i)^(\[?consolecolor\]?::)', ''
        try {
            $resolvedColor = [System.Enum]::Parse([System.ConsoleColor], $cStr, $true)
        } catch {
            $resolvedColor = [ConsoleColor]::Green
        }
    }

    $State.NotificationText = $Message
    $State.NotificationColor = $resolvedColor
    $State.NotificationUntil = [datetime]::UtcNow.AddSeconds($DurationSeconds)
    $State.Dirty = $true
}

# =================================================================
# 5. COMMAND PARSER & EXECUTION ENGINE (MODE B)
# =================================================================

function Split-ShellCommandLine {
    param([string]$CommandLine)

    $tokens = New-Object System.Collections.Generic.List[string]
    if (!$CommandLine) { return $tokens.ToArray() }

    $inQuote = $false
    $quoteChar = [char]0
    $sb = New-Object System.Text.StringBuilder

    for ($i = 0; $i -lt $CommandLine.Length; $i++) {
        $c = $CommandLine[$i]

        if ($inQuote) {
            if ($c -eq $quoteChar) {
                $inQuote = $false
            } else {
                [void]$sb.Append($c)
            }
        } else {
            if ($c -eq '"' -or $c -eq "'") {
                $inQuote = $true
                $quoteChar = $c
            } elseif ([char]::IsWhiteSpace($c)) {
                if ($sb.Length -gt 0) {
                    $tokens.Add($sb.ToString())
                    $sb.Length = 0
                }
            } else {
                [void]$sb.Append($c)
            }
        }
    }

    if ($sb.Length -gt 0) {
        $tokens.Add($sb.ToString())
    }

    $tokens.ToArray()
}

function Invoke-ShellCommand {
    param(
        $State,
        [string]$RawCommand
    )

    try {
        $cmd = $RawCommand.Trim()
        if (!$cmd) { return }

        Add-ShellHistoryEntry $cmd

        # 1. Native PowerShell Execution: ! <cmd> or exec <cmd>
        if ($cmd.StartsWith("!") -or $cmd.StartsWith("exec ", [System.StringComparison]::OrdinalIgnoreCase)) {
            $nativeCmd = if ($cmd.StartsWith("!")) { $cmd.Substring(1).Trim() } else { $cmd.Substring(5).Trim() }
            if (!$nativeCmd) { return }

            $outLines = New-Object System.Collections.Generic.List[string]
            $outLines.Add("Directory: $($State.CurrentDirectory)")
            $outLines.Add("Command:   $nativeCmd")
            $outLines.Add("=" * 60)

            try {
                Push-Location $State.CurrentDirectory
                try {
                    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
                    $pinfo.FileName = "powershell.exe"
                    $pinfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$nativeCmd`""
                    $pinfo.WorkingDirectory = $State.CurrentDirectory
                    $pinfo.RedirectStandardOutput = $true
                    $pinfo.RedirectStandardError = $true
                    $pinfo.UseShellExecute = $false
                    $pinfo.CreateNoWindow = $true

                    $proc = [System.Diagnostics.Process]::Start($pinfo)
                    $stdout = $proc.StandardOutput.ReadToEnd()
                    $stderr = $proc.StandardError.ReadToEnd()
                    $null = $proc.WaitForExit(10000)

                    if ($stdout) {
                        foreach ($l in ($stdout -split "`r?`n")) {
                            $outLines.Add($l)
                        }
                    }
                    if ($stderr) {
                        $outLines.Add("--- STDERR ---")
                        foreach ($l in ($stderr -split "`r?`n")) {
                            if ($l) { $outLines.Add("[ERROR] $l") }
                        }
                    }
                    $outLines.Add("=" * 60)
                    $outLines.Add("Exit Code: $($proc.ExitCode)")
                } finally {
                    Pop-Location
                }
            } catch {
                $outLines.Add("[EXECUTION EXCEPTION]: $($_.Exception.Message)")
            }

            $State.CommandOutput = [PSCustomObject]@{
                Title = "EXEC: $nativeCmd"
                Command = $cmd
                Path = $State.CurrentDirectory
                IsTable = $false
                Lines = $outLines.ToArray()
                Scroll = 0
                ReturnScreen = $State.Screen
            }
            $State.PreviousScreen = $State.Screen
            $State.Screen = "shell-command-output"
            $State.Dirty = $true
            return
        }

        # 2. Tokenize command line
        $tokens = @(Split-ShellCommandLine $cmd)
        if ($tokens.Count -eq 0) { return }

        $verb = $tokens[0].ToLowerInvariant()
        $arg1 = if ($tokens.Count -gt 1) { $tokens[1] } else { "" }
        $arg2 = if ($tokens.Count -gt 2) { $tokens[2] } else { "" }

        # Resolve Alias
        if ($script:ShellAliases.Contains($verb)) {
            $verb = $script:ShellAliases[$verb]
        }

        switch ($verb) {

            # --- NAVIGATION & SYSTEM SCREENS ---
            "home" {
                $State.Screen = "shell-home"
                $State.Context = "home"
                $State.Dirty = $true
                return
            }

            "overview" {
                $State.Screen = "shell-home"
                $State.Context = "home"
                $State.Dirty = $true
                return
            }

            "guide" {
                $targetTopic = if ($arg1) { $arg1.ToLowerInvariant() } else { "overview" }
                $gState = Initialize-WorkCtlGuideState -InitialTopicId $targetTopic -PreviousScreen $State.Screen
                if ($arg1) {
                    $gState.ViewMode = "Section"
                }
                $State.GuideState = $gState
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-guide"
                $State.Dirty = $true
                return
            }

            "status" {
                $lines = New-Object System.Collections.Generic.List[string]
                $lines.Add("WORKSTATION CONTROL PLANE STATUS")
                $lines.Add("=" * 60)
                $lines.Add("Host Name:    $([Environment]::MachineName)")
                $lines.Add("OS Platform:  $([Environment]::OSVersion.VersionString)")
                $lines.Add("Current Dir:  $($State.CurrentDirectory)")
                $lines.Add("Timestamp:    $([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))")
                $lines.Add("")
                $lines.Add("TELEMETRY SNAPSHOT:")
                $snap = $State.CachedResSnapshot
                if ($snap) {
                    $lines.Add("  CPU Load:   $($snap.CpuTotal)%")
                    $lines.Add("  RAM Used:   $($snap.RamUsedGB) / $($snap.RamTotalGB) GB ($($snap.RamPct)%)")
                    if ($snap.GpuAvailable) {
                        $lines.Add("  GPU Engine: $($snap.GpuName) ($($snap.GpuLoad)%)")
                    }
                } else {
                    $lines.Add("  Telemetry snapshot initializing...")
                }
                $lines.Add("")
                $lines.Add("MANAGED WORKLOADS:")
                $wReg = Get-ShellCachedWorkloads
                if ($wReg -and $wReg.components) {
                    $wlStatuses = if (Get-Command Get-WorkloadStatus -ErrorAction SilentlyContinue) { @(Get-WorkloadStatus) } else { @() }
                    $runningCount = @($wlStatuses | Where-Object { $_.State -eq "RUNNING" }).Count
                    $totalCount = if ($wlStatuses.Count -gt 0) { $wlStatuses.Count } else { $wReg.components.PSObject.Properties.Count }
                    $lines.Add("  Active: $runningCount of $totalCount configured workloads")
                }
                $lines.Add("=" * 60)

                $State.CommandOutput = [PSCustomObject]@{
                    Title = "WORKSTATION STATUS"
                    Command = "status"
                    Path = $State.CurrentDirectory
                    IsTable = $false
                    Lines = $lines.ToArray()
                    Scroll = 0
                    ReturnScreen = $State.Screen
                }
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-command-output"
                $State.Dirty = $true
                return
            }

            "back" {
                $State.Screen = if ($State.PreviousScreen) { $State.PreviousScreen } else { "shell-home" }
                $State.Dirty = $true
                return
            }

            "clear" {
                $script:UiPreviousFrame = @()
                try { Clear-Host } catch {}
                $State.Dirty = $true
                return
            }

            "exit" {
                $State.Running = $false
                return
            }

            "resources" {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-resources"
                $State.Context = "resources"
                $State.Dirty = $true
                return
            }

            "workloads" {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-workloads-list"
                $State.Context = if ($arg1) { "workloads/$arg1" } else { "workloads" }
                if ($arg1) { $State.SelectedWorkloadCategory = $arg1.ToUpperInvariant() }
                $State.Dirty = $true
                return
            }

            "tools" {
                if ($arg1 -ieq "refresh") {
                    $script:ShellToolsConfigCache = $null
                    $script:ShellToolsConfigMtime = $null
                    Set-ShellNotification $State "Tools registry cache refreshed" [ConsoleColor]::Green
                    $State.Dirty = $true
                    return
                }
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-tools-list"
                $State.Context = "tools"
                $State.Dirty = $true
                return
            }

            "powertoys" {
                # Subsystem transition (lazy-load if needed)
                if (!(Get-Command Watch-PowerToys -ErrorAction SilentlyContinue)) {
                    $ptPath = Join-Path $script:ShellRoot "modules\powertoys.ps1"
                    if (Test-Path -LiteralPath $ptPath) { . $ptPath }
                }
                if (Get-Command Watch-PowerToys -ErrorAction SilentlyContinue) {
                    $initCat = ""
                    $initMod = ""
                    if ($arg1) {
                        $ptReg = if (Get-Command Get-PowerToysRegistry -ErrorAction SilentlyContinue) { Get-PowerToysRegistry } else { $null }
                        if ($ptReg -and $ptReg.modules -and $ptReg.modules.PSObject.Properties[$arg1]) {
                            $initMod = $arg1
                        } else {
                            $initCat = $arg1
                        }
                    }
                    Watch-PowerToys -Embedded -InitialCategory $initCat -InitialModule $initMod | Out-Null
                    $script:UiPreviousFrame = @()
                    $State.Dirty = $true
                } else {
                    Set-ShellNotification $State "PowerToys module not available." [ConsoleColor]::Red
                }
                return
            }

            "media" {
                # Subsystem transition (lazy-load if needed)
                if (!(Get-Command Watch-WorkCtlMedia -ErrorAction SilentlyContinue)) {
                    $medPath = Join-Path $script:ShellRoot "modules\media.ps1"
                    if (Test-Path -LiteralPath $medPath) { . $medPath }
                }
                if (Get-Command Watch-WorkCtlMedia -ErrorAction SilentlyContinue) {
                    $initScrn = ""
                    if ($arg1 -ieq "sonarr") { $initScrn = "media-sonarr" }
                    elseif ($arg1 -ieq "torlink") { $initScrn = "media-torlink" }
                    elseif ($arg1 -ieq "downloads") { $initScrn = "media-downloads" }
                    elseif ($arg1 -ieq "movies" -or $arg1 -ieq "tv") { $initScrn = "media-category" }

                    Watch-WorkCtlMedia -Embedded -InitialScreen $initScrn | Out-Null
                    $script:UiPreviousFrame = @()
                    $State.Dirty = $true
                } else {
                    Set-ShellNotification $State "Media module not available." [ConsoleColor]::Red
                }
                return
            }

            "diagnostics" {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-diagnostics"
                $State.Context = "diagnostics"
                $State.Dirty = $true
                return
            }

            "doctor" {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-diagnostics"
                $State.Context = "diagnostics"
                $State.Dirty = $true
                return
            }

            "processes" {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-processes"
                $State.Context = "system"
                $State.Dirty = $true
                return
            }

            "services" {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-services"
                $State.Context = "system"
                $State.Dirty = $true
                return
            }

            "network" {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-network"
                $State.Context = "network"
                $State.Dirty = $true
                return
            }

            "ports" {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-network"
                $State.Context = "network"
                $State.Dirty = $true
                return
            }

            "storage" {
                Push-WorkCtlScreen $State "shell-storage"
                $State.Context = "storage"
                $State.Dirty = $true
                return
            }

            "hardware" {
                Push-WorkCtlScreen $State "shell-hardware"
                $State.Context = "hardware"
                $State.Dirty = $true
                return
            }

            "windirstat" {
                try {
                    $target = if ($arg1) { $arg1 } else { $State.CurrentDirectory }
                    $res = Invoke-WinDirStatScan -TargetPath $target
                    Set-ShellNotification $State "Launched WinDirStat on $($res.Target)" [ConsoleColor]::Green
                } catch {
                    Set-ShellNotification $State "WinDirStat failed: $($_.Exception.Message)" [ConsoleColor]::Red
                }
                $State.Dirty = $true
                return
            }

            { $_ -in @("dev", "development") } {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-dev-menu"
                $State.Context = "development"
                $State.Dirty = $true
                return
            }

            "projects" {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-projects"
                $State.Context = "projects"
                $State.Dirty = $true
                return
            }

            "project" {
                if ($arg1) {
                    $projs = @(Get-WorkCtlProjects)
                    $matched = $projs | Where-Object { $_.Name -ieq $arg1 -or $_.Name -like "*$arg1*" } | Select-Object -First 1
                    if ($matched) {
                        $State.SelectedProject = $matched.Name
                        $State.PreviousScreen = $State.Screen
                        $State.Screen = "shell-project-detail"
                        $State.Context = "projects/$($matched.Name)"
                        $State.Dirty = $true
                        return
                    } else {
                        Set-ShellNotification $State "Project not found: $arg1" [ConsoleColor]::Yellow
                        return
                    }
                }
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-projects"
                $State.Context = "projects"
                $State.Dirty = $true
                return
            }

            { $_ -in @("agents", "agent") } {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-agents"
                $State.Context = "agents"
                $State.Dirty = $true
                return
            }

            { $_ -in @("freebuff", "fb") } {
                $targetPath = ""
                if ($arg1) {
                    $projs = @(Get-WorkCtlProjects)
                    $matched = $projs | Where-Object { $_.Name -ieq $arg1 -or $_.Name -like "*$arg1*" } | Select-Object -First 1
                    if ($matched) {
                        $targetPath = $matched.Path
                    }
                }
                if (!$targetPath) {
                    $targetPath = if ($State.Screen -eq "shell-project-detail" -and $State.SelectedProject) {
                        $projs = @(Get-WorkCtlProjects)
                        $m = $projs | Where-Object { $_.Name -ieq $State.SelectedProject } | Select-Object -First 1
                        if ($m) { $m.Path } else { "E:\Workspace" }
                    } else {
                        "E:\Workspace"
                    }
                }
                if (Get-Command Invoke-WorkCtlLaunchFreebuff -ErrorAction SilentlyContinue) {
                    Invoke-WorkCtlLaunchFreebuff -ProjectPath $targetPath | Out-Null
                    $script:UiPreviousFrame = @()
                    $State.Dirty = $true
                } else {
                    Set-ShellNotification $State "Freebuff launcher not available" [ConsoleColor]::Red
                }
                return
            }

            "help" {
                if ($arg1) {
                    $lookup = $arg1.ToLowerInvariant()
                    # Check command registry
                    $entry = $null
                    if ($script:ShellCommandRegistry.Contains($lookup)) {
                        $entry = $script:ShellCommandRegistry[$lookup]
                    } else {
                        foreach ($k in $script:ShellCommandRegistry.Keys) {
                            $e = $script:ShellCommandRegistry[$k]
                            if ($e.Aliases -contains $lookup) {
                                $entry = $e
                                break
                            }
                        }
                    }

                    if ($entry) {
                        $hLines = New-Object System.Collections.Generic.List[string]
                        $hLines.Add("COMMAND: $($entry.Name.ToUpperInvariant())")
                        $hLines.Add("=" * 60)
                        $hLines.Add("Category:    $($entry.Category)")
                        $hLines.Add("Risk Level:  $($entry.Risk)")
                        $aliasesStr = if ($entry.Aliases.Count -gt 0) { $entry.Aliases -join ", " } else { "None" }
                        $hLines.Add("Aliases:     $aliasesStr")
                        $hLines.Add("")
                        $hLines.Add("USAGE:")
                        $hLines.Add("  $($entry.Usage)")
                        $hLines.Add("")
                        $hLines.Add("DESCRIPTION:")
                        $hLines.Add("  $($entry.Description)")
                        $hLines.Add("")
                        $hLines.Add("EXAMPLES:")
                        foreach ($ex in @($entry.Examples)) {
                            $hLines.Add("  workctl > $ex")
                        }
                        $hLines.Add("=" * 60)

                        $State.CommandOutput = [PSCustomObject]@{
                            Title = "HELP: $($entry.Name.ToUpperInvariant())"
                            Command = "help $arg1"
                            Path = $State.CurrentDirectory
                            IsTable = $false
                            Lines = $hLines.ToArray()
                            Scroll = 0
                            ReturnScreen = $State.Screen
                        }
                        $State.PreviousScreen = $State.Screen
                        $State.Screen = "shell-command-output"
                        $State.Dirty = $true
                        return
                    } else {
                        Set-ShellNotification $State "Unknown command: '$arg1'. Type 'help' for directory." [ConsoleColor]::Yellow
                        return
                    }
                }

                # Directory of all commands from registry
                $hLines = New-Object System.Collections.Generic.List[string]
                $hLines.Add("WORKCTL COMMAND DIRECTORY")
                $hLines.Add("=" * 76)
                $hLines.Add(("{0,-14} {1,-12} {2,-24} {3}" -f "COMMAND", "CATEGORY", "USAGE", "DESCRIPTION"))
                $hLines.Add("-" * 76)

                $categories = @($script:ShellCommandRegistry.Values | ForEach-Object { $_.Category } | Select-Object -Unique)
                foreach ($cat in $categories) {
                    $cmds = @($script:ShellCommandRegistry.Values | Where-Object { $_.Category -eq $cat })
                    foreach ($c in $cmds) {
                        $aliasStr = if ($c.Aliases.Count -gt 0) { " (" + ($c.Aliases -join ",") + ")" } else { "" }
                        $nameWithAlias = $c.Name + $aliasStr
                        $hLines.Add(("{0,-14} {1,-12} {2,-24} {3}" -f $nameWithAlias, $c.Category, $c.Usage, $c.Description))
                    }
                }
                $hLines.Add("=" * 76)
                $hLines.Add("Tip: Type 'help <command>' for specific syntax and examples (e.g. 'help start').")

                $State.CommandOutput = [PSCustomObject]@{
                    Title = "COMMAND DIRECTORY"
                    Command = "help"
                    Path = $State.CurrentDirectory
                    IsTable = $false
                    Lines = $hLines.ToArray()
                    Scroll = 0
                    ReturnScreen = $State.Screen
                }
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-command-output"
                $State.Dirty = $true
                return
            }

            "aliases" {
                Set-ShellNotification $State "Aliases: r, res, wl, pt, med, diag, doc, ps, top, net, ports, disk, proj, cls, q" [ConsoleColor]::Cyan
                return
            }

            # --- DIRECTORY NAVIGATION ---
            "pwd" {
                $cur = $State.CurrentDirectory
                $dInfo = $null
                try {
                    $driveRoot = [System.IO.Path]::GetPathRoot($cur)
                    $d = [System.IO.DriveInfo]::new($driveRoot)
                    $freeGb = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
                    $totalGb = [math]::Round($d.TotalSize / 1GB, 1)
                    $dInfo = "$($d.VolumeLabel) (${freeGb}GB free / ${totalGb}GB total)"
                } catch {}

                $lines = New-Object System.Collections.Generic.List[string]
                $lines.Add("Current Working Directory:")
                $lines.Add("  $cur")
                $lines.Add("")
                if ($dInfo) {
                    $lines.Add("Storage Volume:")
                    $lines.Add("  $dInfo")
                    $lines.Add("")
                }
                $lines.Add("Parent Directory:")
                $lines.Add("  $(Split-Path -Parent $cur)")

                $State.CommandOutput = [PSCustomObject]@{
                    Title = "WORKING DIRECTORY"
                    Command = "pwd"
                    Path = $cur
                    IsTable = $false
                    Lines = $lines.ToArray()
                    Scroll = 0
                    ReturnScreen = $State.Screen
                }
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-command-output"
                $State.Dirty = $true
                Set-ShellNotification $State "PWD: $cur" [ConsoleColor]::Cyan
                return
            }

            "cd" {
                $target = $arg1
                if (!$target -or $target -eq "~") {
                    $userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
                    $target = if (Test-Path -LiteralPath "E:\Workspace") { "E:\Workspace" } else { $userHome }
                } elseif ($target -eq "..") {
                    $target = Split-Path -Parent $State.CurrentDirectory
                    if (!$target) { $target = $State.CurrentDirectory }
                } elseif (![System.IO.Path]::IsPathRooted($target)) {
                    $target = Join-Path $State.CurrentDirectory $target
                }

                try {
                    $target = [System.IO.Path]::GetFullPath($target)
                } catch {
                    Set-ShellNotification $State "Invalid path: $arg1" [ConsoleColor]::Red
                    return
                }

                if (Test-Path -LiteralPath $target -PathType Container) {
                    $State.CurrentDirectory = $target
                    $script:ShellCurrentDirectory = $target
                    Set-ShellNotification $State "Directory: $target" [ConsoleColor]::Green
                } else {
                    Set-ShellNotification $State "Directory not found: $arg1" [ConsoleColor]::Red
                }
                return
            }

            "ls" {
                $target = if ($arg1) { $arg1 } else { $State.CurrentDirectory }
                if (![System.IO.Path]::IsPathRooted($target)) {
                    $target = [System.IO.Path]::GetFullPath((Join-Path $State.CurrentDirectory $target))
                }
                if (!(Test-Path -LiteralPath $target)) {
                    Set-ShellNotification $State "Path not found: $target" [ConsoleColor]::Red
                    return
                }

                $rows = New-Object System.Collections.Generic.List[object]
                try {
                    $items = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction Stop)
                    # Sort directories first, then files
                    $sortedDirs = @($items | Where-Object { $_.PSIsContainer } | Sort-Object Name)
                    $sortedFiles = @($items | Where-Object { !$_.PSIsContainer } | Sort-Object Name)

                    foreach ($item in ($sortedDirs + $sortedFiles)) {
                        $isDir = $item.PSIsContainer
                        $typeStr = if ($isDir) { "[DIR]" } else { " FILE" }
                        $sizeStr = if ($isDir) { "-" } else {
                            $len = $item.Length
                            if ($len -ge 1GB) { "{0:N1} GB" -f ($len / 1GB) }
                            elseif ($len -ge 1MB) { "{0:N1} MB" -f ($len / 1MB) }
                            elseif ($len -ge 1KB) { "{0:N1} KB" -f ($len / 1KB) }
                            else { "$len B" }
                        }
                        $modStr = $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm")

                        $rows.Add([PSCustomObject]@{
                            IsDir = $isDir
                            Type = $typeStr
                            Name = $item.Name
                            Size = $sizeStr
                            Modified = $modStr
                        })
                    }
                } catch {
                    Set-ShellNotification $State "Failed to list directory: $($_.Exception.Message)" [ConsoleColor]::Red
                    return
                }

                $State.CommandOutput = [PSCustomObject]@{
                    Title = "DIRECTORY: $target"
                    Command = if ($arg1) { "ls $arg1" } else { "ls" }
                    Path = $target
                    IsTable = $true
                    Rows = $rows.ToArray()
                    Scroll = 0
                    ReturnScreen = $State.Screen
                }
                $State.PreviousScreen = $State.Screen
                $State.Screen = "shell-command-output"
                $State.Dirty = $true
                return
            }

            # --- WORKLOAD LIFECYCLE CONTROLS WITH STRICT GOVERNANCE ---
            "start" {
                if (!$arg1) {
                    Set-ShellNotification $State "Usage: start <workload-name>" [ConsoleColor]::Yellow
                    return
                }
                $wKey = $arg1.ToLowerInvariant()
                $wReg = Get-ShellCachedWorkloads
                if ($wReg -and $wReg.components -and $wReg.components.PSObject.Properties[$wKey]) {
                    $w = $wReg.components.PSObject.Properties[$wKey].Value
                    if ($w.stopPolicy -eq "explicit") {
                        Set-ShellNotification $State "START BLOCKED: $($w.label) is protected by dedicated subsystem." [ConsoleColor]::Magenta
                        return
                    }
                    try {
                        Start-Workload $wKey
                        Set-ShellNotification $State "Started workload: $($w.label)" [ConsoleColor]::Green
                    } catch {
                        Set-ShellNotification $State "Start failed: $($_.Exception.Message)" [ConsoleColor]::Red
                    }
                } else {
                    Set-ShellNotification $State "Unknown workload: $arg1" [ConsoleColor]::Red
                }
                return
            }

            "stop" {
                if (!$arg1) {
                    Set-ShellNotification $State "Usage: stop <workload-name>" [ConsoleColor]::Yellow
                    return
                }
                $wKey = $arg1.ToLowerInvariant()
                $wReg = Get-ShellCachedWorkloads
                if ($wReg -and $wReg.components -and $wReg.components.PSObject.Properties[$wKey]) {
                    $w = $wReg.components.PSObject.Properties[$wKey].Value

                    # Strict Governance: Explicit policy blocks stop!
                    if ($w.stopPolicy -eq "explicit") {
                        $State.ConfirmState = [PSCustomObject]@{
                            Title = "PROTECTED WORKLOAD: $($w.label)"
                            MessageLines = @(
                                "$($w.label) is marked with stopPolicy: EXPLICIT.",
                                "Governance strictly prohibits terminating this workload from the workload engine.",
                                "Consult the owning subsystem or terminate via dedicated control."
                            )
                            Policy = "EXPLICIT"
                            Action = "none"
                            Target = $wKey
                            WorkloadName = $w.label
                            ReturnScreen = $State.Screen
                        }
                        $State.PreviousScreen = $State.Screen
                        $State.Screen = "shell-confirm"
                        $State.Dirty = $true
                        return
                    }

                    # Confirmation policy requires modal verification!
                    if ($w.stopPolicy -eq "confirm") {
                        $State.ConfirmState = [PSCustomObject]@{
                            Title = "CONFIRM STOP: $($w.label)"
                            MessageLines = @(
                                "$($w.label) is marked with stopPolicy: CONFIRM.",
                                "Stopping this workload may disconnect active client sessions or background tasks.",
                                "Are you sure you want to terminate this workload?"
                            )
                            Policy = "CONFIRM"
                            Action = "stop"
                            Target = $wKey
                            WorkloadName = $wKey
                            ReturnScreen = $State.Screen
                        }
                        $State.PreviousScreen = $State.Screen
                        $State.Screen = "shell-confirm"
                        $State.Dirty = $true
                        return
                    }

                    # Safe policy executes immediately
                    try {
                        Stop-Workload $wKey
                        Set-ShellNotification $State "Stopped workload: $($w.label)" [ConsoleColor]::Green
                    } catch {
                        Set-ShellNotification $State "Stop failed: $($_.Exception.Message)" [ConsoleColor]::Red
                    }
                } else {
                    Set-ShellNotification $State "Unknown workload: $arg1" [ConsoleColor]::Red
                }
                return
            }

            "restart" {
                if (!$arg1) {
                    Set-ShellNotification $State "Usage: restart <workload-name>" [ConsoleColor]::Yellow
                    return
                }
                $wKey = $arg1.ToLowerInvariant()
                $wReg = Get-ShellCachedWorkloads
                if ($wReg -and $wReg.components -and $wReg.components.PSObject.Properties[$wKey]) {
                    $w = $wReg.components.PSObject.Properties[$wKey].Value
                    if ($w.stopPolicy -eq "explicit") {
                        Set-ShellNotification $State "RESTART BLOCKED: $($w.label) is protected (explicit policy)." [ConsoleColor]::Magenta
                        return
                    }
                    try {
                        Restart-Workload $wKey
                        Set-ShellNotification $State "Restarted workload: $($w.label)" [ConsoleColor]::Green
                    } catch {
                        Set-ShellNotification $State "Restart failed: $($_.Exception.Message)" [ConsoleColor]::Red
                    }
                } else {
                    Set-ShellNotification $State "Unknown workload: $arg1" [ConsoleColor]::Red
                }
                return
            }

            "info" {
                if (!$arg1) {
                    Set-ShellNotification $State "Usage: info <target>" [ConsoleColor]::Yellow
                    return
                }
                $target = $arg1.ToLowerInvariant()
                $wReg = Get-ShellCachedWorkloads
                if ($wReg -and $wReg.components -and $wReg.components.PSObject.Properties[$target]) {
                    $State.SelectedWorkload = $target
                    $State.PreviousScreen = $State.Screen
                    $State.Screen = "shell-workload-detail"
                    $State.Dirty = $true
                    return
                }
                $tReg = Get-ShellCachedTools
                if ($tReg -and $tReg.tools -and $tReg.tools.PSObject.Properties[$target]) {
                    $State.SelectedTool = $target
                    $State.PreviousScreen = $State.Screen
                    $State.Screen = "shell-tool-detail"
                    $State.Dirty = $true
                    return
                }
                Set-ShellNotification $State "No info found for: $arg1" [ConsoleColor]::Yellow
                return
            }

            { $_ -in @("open", "launch") } {
                if (!$arg1) {
                    Set-ShellNotification $State "Usage: open <tool-or-app>" [ConsoleColor]::Yellow
                    return
                }
                $target = $arg1.ToLowerInvariant()
                $tool = Get-WorkCtlTool $target
                if ($tool) {
                    if ($tool.kind -eq "terminal-agent" -or $tool.id -eq "freebuff") {
                        if (Get-Command Invoke-WorkCtlInteractiveTool -ErrorAction SilentlyContinue) {
                            $wdir = if ($tool.workingDirectory -and (Test-Path -LiteralPath $tool.workingDirectory)) { $tool.workingDirectory } else { "E:\Workspace" }
                            Invoke-WorkCtlInteractiveTool -Command "cmd.exe" -Arguments "/c $($tool.command)" -WorkingDirectory $wdir | Out-Null
                            $script:UiPreviousFrame = @()
                            $State.Dirty = $true
                            return
                        }
                    }
                    if ($tool.webUrl) {
                        Start-Process $tool.webUrl | Out-Null
                        Set-ShellNotification $State "Opened $($tool.label) in browser" [ConsoleColor]::Green
                    } elseif ($tool.installPath -and (Test-Path -LiteralPath $tool.installPath)) {
                        Start-Process -FilePath $tool.installPath -WorkingDirectory $tool.workingDirectory | Out-Null
                        Set-ShellNotification $State "Launched $($tool.label)" [ConsoleColor]::Green
                    } elseif ($tool.command -and (Get-Command $tool.command -ErrorAction SilentlyContinue)) {
                        if (Get-Command Invoke-WorkCtlInteractiveTool -ErrorAction SilentlyContinue) {
                            $wdir = if ($tool.workingDirectory -and (Test-Path -LiteralPath $tool.workingDirectory)) { $tool.workingDirectory } else { "E:\Workspace" }
                            Invoke-WorkCtlInteractiveTool -Command "cmd.exe" -Arguments "/c $($tool.command)" -WorkingDirectory $wdir | Out-Null
                            $script:UiPreviousFrame = @()
                            $State.Dirty = $true
                        } else {
                            Start-Process $tool.command | Out-Null
                            Set-ShellNotification $State "Launched $($tool.label)" [ConsoleColor]::Green
                        }
                    } else {
                        Set-ShellNotification $State "Tool not installed: $($tool.label)" [ConsoleColor]::Yellow
                    }
                    return
                }
                Set-ShellNotification $State "Unknown tool: $arg1" [ConsoleColor]::Red
                return
            }

            default {
                # Try fuzzy resolution through Global Entity Index
                $index = Get-ShellEntityIndex
                $match = $index | Where-Object { $_.Key -ieq $verb -or $_.Target -ieq $verb } | Select-Object -First 1

                if ($match) {
                    switch ($match.Kind) {
                        "DESTINATION" {
                            $State.PreviousScreen = $State.Screen
                            $State.Screen = "shell-$($match.Target)"
                            $State.Dirty = $true
                            return
                        }
                        "WORKLOAD" {
                            $State.SelectedWorkload = $match.Target
                            $State.PreviousScreen = $State.Screen
                            $State.Screen = "shell-workload-detail"
                            $State.Dirty = $true
                            return
                        }
                        "TOOL" {
                            $State.SelectedTool = $match.Target
                            $State.PreviousScreen = $State.Screen
                            $State.Screen = "shell-tool-detail"
                            $State.Dirty = $true
                            return
                        }
                        "POWERTOYS" {
                            if (!(Get-Command Watch-PowerToys -ErrorAction SilentlyContinue)) {
                                $ptPath = Join-Path $script:ShellRoot "modules\powertoys.ps1"
                                if (Test-Path -LiteralPath $ptPath) { . $ptPath }
                            }
                            if (Get-Command Watch-PowerToys -ErrorAction SilentlyContinue) {
                                Watch-PowerToys -Embedded -InitialModule $match.Target | Out-Null
                                $script:UiPreviousFrame = @()
                                $State.Dirty = $true
                            }
                            return
                        }
                    }
                }

                Set-ShellNotification $State "Unknown command: '$cmd'. Type 'help' or 'aliases'." [ConsoleColor]::Yellow
            }
        }
    } catch {
        Set-ShellNotification $State "Command error: $($_.Exception.Message)" [ConsoleColor]::Red
        $State.Dirty = $true
    }
}

# =================================================================
# 6. COCKPIT TUI FRAME BUILDERS (MODE A)
# =================================================================

function Get-HomePreviewCard([int]$Index) {
    $rule = [string][char]0x2500 * 42
    $dot = [string][char]0x00B7
    switch ($Index) {
        0 { # Hardware
            return @(
                "HARDWARE TOPOLOGY",
                $rule,
                "CPU",
                "Intel(R) Core(TM) i5-12450H (8C / 12T)",
                "GPU",
                "NVIDIA GeForce RTX 2050 $dot 4 GB VRAM",
                "MEMORY",
                "15.65 GB Physical DDR4",
                "FAN CONTROL",
                "BIOS / OMEN Profile $dot Locked",
                "",
                "[Enter] Inspect Hardware"
            )
        }
        1 { # Storage
            return @(
                "STORAGE & VOLUMES",
                $rule,
                "LOCAL VOLUMES (FIXED NVME)",
                "C:  42.1 GB free $dot Windows OS",
                "E:  44.5 GB free $dot Workspace & Data",
                "OTHER MOUNTS (CLOUD / VIRTUAL)",
                "G:  Google Drive $dot Cloud Mount",
                "H:  Google Drive $dot Cloud Mount",
                "",
                "[Enter] Inspect Storage & Mounts"
            )
        }
        2 { # Network
            return @(
                "NETWORK & PORTS",
                $rule,
                "ACTIVE ADAPTERS",
                "Wi-Fi $dot Loopback",
                "LISTENING WORKSTATION PORTS",
                "3306 (MySQL 8) $dot 11434 (Ollama)",
                "DIAGNOSTICS",
                "DNS & gateway health operational",
                "",
                "[Enter] Inspect Sockets & Ports"
            )
        }
        3 { # Services
            return @(
                "SERVICES EXPLORER",
                $rule,
                "WINDOWS SERVICE CONTROL MANAGER",
                "Pure SCM discovery $dot Zero synthetic services",
                "FILTERS",
                "All Services $dot Running $dot Stopped $dot Manual",
                "GOVERNANCE",
                "Safe read-only state inspection",
                "",
                "[Enter] Open Services Explorer"
            )
        }
        4 { # Processes
            return @(
                "PROCESS EXPLORER",
                $rule,
                "TOP PROCESSES",
                "Live top RAM & CPU consumers",
                "SAMPLING",
                "Zero third-party agent overhead",
                "SAFETY",
                "Strict read-only inspection",
                "",
                "[Enter] Open Process Explorer"
            )
        }
        5 { # Development
            return @(
                "DEVELOPMENT & AGENTS",
                $rule,
                "WORKSPACE",
                "Root: E:\Workspace (20+ repositories)",
                "AI AGENTS & RUNTIMES",
                "Freebuff CLI v0.0.174 $dot VS Code",
                "INTEGRATION",
                "Autonomous coding and git tracking",
                "",
                "[Enter] Open Development Menu"
            )
        }
        6 { # Media
            return @(
                "SMART MEDIA CONTROL",
                $rule,
                "AUTOMATION BACKENDS",
                "Sonarr: Running $dot Partially configured",
                "qBittorrent: Stopped $dot API disabled",
                "LOCAL PLAYBACK",
                "E:\Media $dot VLC Media Player ready",
                "",
                "[Enter] Open Media Control"
            )
        }
        7 { # PowerToys
            return @(
                "POWERTOYS CONTROL",
                $rule,
                "WINDOW & PRODUCTIVITY SUITE",
                "34 modules discovered via DSC/settings",
                "HOST RUNNER",
                "PowerToys.exe runner & DSC configuration",
                "CATEGORIES",
                "FancyZones, Awake, Measure Tool, etc.",
                "",
                "[Enter] Open PowerToys Control"
            )
        }
        8 { # Tools
            return @(
                "TOOLS & RUNTIMES",
                $rule,
                "EXTERNAL UTILITIES",
                "Audited directory: E:\TOOLS",
                "CONFIGURED TOOLS",
                "WinDirStat, Mounter, Docker, MySQL",
                "ISOLATION",
                "Explicit execution & configuration tracking",
                "",
                "[Enter] Open Tools Registry"
            )
        }
        9 { # Workloads
            return @(
                "WORKLOADS ENGINE",
                $rule,
                "MANAGED ENGINES",
                "2 Running $dot 10 Stopped",
                "ACTIVE WORKLOAD",
                "Dev Mode (MySQL80 + Docker Desktop)",
                "STOP POLICY",
                "Safe / confirmation required for protected",
                "",
                "[Enter] Manage Workloads"
            )
        }
        10 { # Guide
            return @(
                "WORKCTL GUIDE",
                $rule,
                "INTERACTIVE MANUAL",
                "Structured architecture & cheat sheets",
                "TOPICS",
                "Architecture, Recipes, Keybindings, FAQ",
                "",
                "[Enter] Open WorkCtl Guide"
            )
        }
        11 { # Diagnostics
            return @(
                "SYSTEM DIAGNOSTICS",
                $rule,
                "WORKSTATION HEALTH AUDIT",
                "Workstation Doctor & 6 protected shields",
                "RECOVERY BOUNDARY",
                "ONLINE $dot Isolated exception trapping",
                "",
                "[Enter] Run System Diagnostics"
            )
        }
        default {
            return @("WORKSTATION PREVIEW", $rule, "Select an item to inspect", "", "")
        }
    }
}

function New-ShellTelemetryLine($State, [int]$Width = 0) {
    [int]$w = if ($Width -gt 0) { $Width } else { Get-WorkCtlWindowWidth }
    $margin = Get-WorkCtlMargin -Width $w

    $snap = $State.CachedResSnapshot
    $cpuVal = if ($snap -and $snap.CPU -and $snap.CPU.Available) { [math]::Round($snap.CPU.UsagePercent) } else { $null }
    $cpuPct = if ($null -ne $cpuVal) { "$cpuVal%" } else { "..." }
    $cpuCol = if ($null -ne $cpuVal -and $cpuVal -gt 80) { [ConsoleColor]::Red }
              elseif ($null -ne $cpuVal -and $cpuVal -gt 50) { [ConsoleColor]::Yellow }
              else { [ConsoleColor]::White }

    $memUsed = if ($snap -and $snap.Memory -and $snap.Memory.Available) {
        ("{0:N1}/{1:N1}G" -f $snap.Memory.UsedGB, $snap.Memory.TotalGB)
    } else { "..." }
    $memPct = if ($snap -and $snap.Memory -and $snap.Memory.Available) { $snap.Memory.UsagePercent } else { 0 }
    $memCol = if ($memPct -gt 85) { [ConsoleColor]::Yellow } else { [ConsoleColor]::White }

    $gpuText = if ($snap -and $snap.GPU -and $snap.GPU.Available) {
        ("{0}% {1}C" -f [math]::Round($snap.GPU.UsagePercent), $snap.GPU.TemperatureC)
    } else { "..." }
    $gpuCol = if ($snap -and $snap.GPU -and $snap.GPU.TemperatureC -gt 80) { [ConsoleColor]::Red }
              elseif ($snap -and $snap.GPU -and $snap.GPU.TemperatureC -gt 70) { [ConsoleColor]::Yellow }
              else { [ConsoleColor]::White }

    $netDown = if ($snap -and $snap.Network -and $snap.Network.Available) {
        if ($snap.Network.DownloadMbps -lt 1) { ("{0:N0}K" -f ($snap.Network.DownloadMbps * 128)) }
        else { ("{0:N1}M" -f $snap.Network.DownloadMbps) }
    } else { "..." }
    $netUp = if ($snap -and $snap.Network -and $snap.Network.Available) {
        if ($snap.Network.UploadMbps -lt 1) { ("{0:N0}K" -f ($snap.Network.UploadMbps * 128)) }
        else { ("{0:N1}M" -f $snap.Network.UploadMbps) }
    } else { "..." }

    # Fast disk info
    $diskInfo = ""
    if ($w -ge 105) {
        try {
            $drives = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' -and $_.Name -match "^[CE]:" }
            $dParts = @()
            foreach ($d in $drives) {
                $letter = $d.Name.TrimEnd(':\')
                $freeGB = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
                $dParts += ("{0}: {1}G free" -f $letter, $freeGB)
            }
            $diskInfo = ($dParts -join "   ")
        } catch {
            $diskInfo = "C: ...   E: ..."
        }
    }

    $arrowDown = "$([char]0x2193)"
    $arrowUp = "$([char]0x2191)"
    if ($env:WORKCTL_ASCII_ONLY -eq "1") { $arrowDown = "v"; $arrowUp = "^" }

    $segs = New-Object System.Collections.Generic.List[object]
    $segs.Add((New-UiSegment $margin DarkGray))
    $segs.Add((New-UiSegment "CPU " DarkGray))
    $segs.Add((New-UiSegment $cpuPct $cpuCol))
    $segs.Add((New-UiSegment "   RAM " DarkGray))
    $segs.Add((New-UiSegment $memUsed $memCol))

    if ($w -ge 65) {
        $segs.Add((New-UiSegment "   GPU " DarkGray))
        $segs.Add((New-UiSegment $gpuText $gpuCol))
    }

    if ($w -ge 80) {
        $segs.Add((New-UiSegment "   NET " DarkGray))
        $segs.Add((New-UiSegment $arrowDown Cyan))
        $segs.Add((New-UiSegment $netDown White))
        $segs.Add((New-UiSegment " " DarkGray))
        $segs.Add((New-UiSegment $arrowUp Cyan))
        $segs.Add((New-UiSegment $netUp White))
    }

    if ($w -ge 105 -and $diskInfo) {
        $segs.Add((New-UiSegment "   " DarkGray))
        $segs.Add((New-UiSegment $diskInfo DarkGray))
    }

    return (New-UiLine $segs.ToArray())
}

function New-ShellHomeFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    # 1. Header Chrome (Rows 0 & 1) - Restrained Breadcrumbs
    $f.Add((New-WorkCtlHeaderLine @("HOME") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    # 2. Live Telemetry Bar (Row 2)
    $f.Add((New-ShellTelemetryLine $State -Width $width))

    # 3. Optional Toast or Blank Line (Row 3)
    if ($State.NotificationText -and [datetime]::UtcNow -lt $State.NotificationUntil) {
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment " >> " $State.NotificationColor),
            (New-UiSegment $State.NotificationText $State.NotificationColor)
        )))
    } else {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    # 4. Destinations Structured into Logical Groups
    $script:WorkCtlHomeItemRows = @(5, 6, 7, 8, 9, 11, 12, 13, 14, 16, 17, 18)

    $destinations = @(
        # WORKSTATION (Indices 0..4)
        @{ Key = "H"; Title = "Hardware";     Desc = "CPU, GPU, battery & fan control";       Target = "shell-hardware" },
        @{ Key = "B"; Title = "Storage";      Desc = "Volumes, mounts, images & analysis";    Target = "shell-storage" },
        @{ Key = "N"; Title = "Network";      Desc = "Interfaces, DNS, routes & ports";       Target = "shell-network" },
        @{ Key = "S"; Title = "Services";     Desc = "Windows services, states & startup";    Target = "shell-services" },
        @{ Key = "P"; Title = "Processes";    Desc = "Live top RAM/CPU workstation tasks";    Target = "shell-processes" },
        # WORK (Indices 5..8)
        @{ Key = "E"; Title = "Development";  Desc = "Projects, Git, runtimes & AI agents";   Target = "shell-dev-menu" },
        @{ Key = "V"; Title = "Media";        Desc = "Library, series, torrents & playback";  Target = "media" },
        @{ Key = "T"; Title = "PowerToys";    Desc = "Windows productivity utilities";        Target = "powertoys" },
        @{ Key = "O"; Title = "Tools";        Desc = "External workstation utilities";        Target = "shell-tools-list" },
        # CONTROL & LEARN (Indices 9..11)
        @{ Key = "W"; Title = "Workloads";    Desc = "Managed engines & runtime governance";  Target = "shell-workloads-list" },
        @{ Key = "G"; Title = "Guide";        Desc = "Interactive structured WorkCtl manual"; Target = "shell-guide" },
        @{ Key = "D"; Title = "Diagnostics";  Desc = "Health audit, doctor & recovery";       Target = "shell-diagnostics" }
    )

    $isWide = $canvas.IsWide
    $leftW = $canvas.LeftPaneWidth
    $gapW = $canvas.PaneGap
    $rightW = $canvas.RightPaneWidth
    $previewCard = if ($isWide) { Get-HomePreviewCard $State.SelectedHomeItem } else { $null }

    # Group headers and items
    $rowDefinitions = @(
        @{ Type = "Group"; Text = "WORKSTATION" },
        @{ Type = "Item";  Index = 0 },
        @{ Type = "Item";  Index = 1 },
        @{ Type = "Item";  Index = 2 },
        @{ Type = "Item";  Index = 3 },
        @{ Type = "Item";  Index = 4 },
        @{ Type = "Group"; Text = "WORK" },
        @{ Type = "Item";  Index = 5 },
        @{ Type = "Item";  Index = 6 },
        @{ Type = "Item";  Index = 7 },
        @{ Type = "Item";  Index = 8 },
        @{ Type = "Group"; Text = "CONTROL & LEARN" },
        @{ Type = "Item";  Index = 9 },
        @{ Type = "Item";  Index = 10 },
        @{ Type = "Item";  Index = 11 }
    )

    [int]$titleColW = 14
    [int]$descColW = [math]::Max(10, $leftW - 2 - 4 - $titleColW)

    for ($r = 0; $r -lt $rowDefinitions.Count; $r++) {
        $def = $rowDefinitions[$r]
        $rowSegs = New-Object System.Collections.Generic.List[object]
        $rowSegs.Add((New-UiSegment $margin DarkGray))

        if ($def.Type -eq "Group") {
            $rowSegs.Add((New-UiSegment "  " DarkGray))
            $rowSegs.Add((New-UiSegment ("{0,-$($leftW - 2)}" -f $def.Text) DarkGray))
        } else {
            $i = $def.Index
            $d = $destinations[$i]
            $isSel = ($i -eq $State.SelectedHomeItem)
            $cursor = if ($isSel) { "> " } else { "  " }
            $cursorCol = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::DarkGray }
            $keyCol = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::DarkGray }
            $titleCol = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::White }
            $descCol = if ($isSel) { [ConsoleColor]::White } else { [ConsoleColor]::Gray }

            $dText = [string]$d.Desc
            if ($dText.Length -gt $descColW) {
                $dText = if ($descColW -gt 2) { $dText.Substring(0, $descColW - 2) + ".." } else { $dText.Substring(0, $descColW) }
            }

            $rowSegs.Add((New-UiSegment $cursor $cursorCol))
            $rowSegs.Add((New-UiSegment ("[{0}] " -f $d.Key) $keyCol))
            $rowSegs.Add((New-UiSegment ("{0,-$titleColW}" -f $d.Title) $titleCol))
            $rowSegs.Add((New-UiSegment ("{0,-$descColW}" -f $dText) $descCol))
        }

        if ($isWide) {
            # Whitespace-only separation between panes (no isolated vertical rule)
            $rowSegs.Add((New-UiSegment (" " * $gapW) DarkGray))
            $pTxt = if ($previewCard -and $r -lt $previewCard.Count) { $previewCard[$r] } else { "" }
            if ($pTxt.Length -gt $rightW) {
                $pTxt = if ($rightW -gt 2) { $pTxt.Substring(0, $rightW - 2) + ".." } else { $pTxt.Substring(0, $rightW) }
            }
            $pCol = if ($r -eq 0) { [ConsoleColor]::White }
                    elseif ($r -eq 1) { [ConsoleColor]::DarkGray }
                    elseif ($pTxt -match "^\[Enter\]") { [ConsoleColor]::Cyan }
                    elseif ($r % 2 -eq 0) { [ConsoleColor]::DarkGray }
                    else { [ConsoleColor]::White }
            $rowSegs.Add((New-UiSegment ("{0,-$rightW}" -f $pTxt) $pCol))
        }

        $f.Add((New-UiLine $rowSegs.ToArray()))
    }

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 5. Quick Actions Row (Subtle, balanced spacing)
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  QUICK    " DarkGray),
        (New-UiSegment "[1] " Cyan), (New-UiSegment "Dev   " DarkGray),
        (New-UiSegment "[2] " Cyan), (New-UiSegment "AI   " DarkGray),
        (New-UiSegment "[3] " Cyan), (New-UiSegment "Local AI   " DarkGray),
        (New-UiSegment "[4] " Cyan), (New-UiSegment "Maintenance" DarkGray)
    )))

    # Pad lines strictly up to FooterSepRow to guarantee zero console scrolling
    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    # 6. Pinned Standardized Footer
    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooter `
        -Actions @("Move", "Open", "Search", "Command", "Help", "Exit") `
        -RightText ("{0} / 12" -f ($State.SelectedHomeItem + 1)) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellWorkloadListFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("WORKLOADS", "MANAGED ENGINES") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $wReg = Get-ShellCachedWorkloads
    $items = New-Object System.Collections.Generic.List[object]

    $now = [datetime]::UtcNow
    if (!$script:ShellWorkloadStatesCache -or ($now - $script:ShellWorkloadStatesTime).TotalSeconds -ge 5.0) {
        $states = @{}
        if ($wReg -and $wReg.components) {
            foreach ($p in $wReg.components.PSObject.Properties) {
                $wKey = $p.Name
                $st = "STOPPED"
                try {
                    if (Get-Command Get-WorkloadState -ErrorAction SilentlyContinue) {
                        $st = Get-WorkloadState $wKey
                    }
                } catch {}
                $states[$wKey] = $st
            }
        }
        $script:ShellWorkloadStatesCache = $states
        $script:ShellWorkloadStatesTime = $now
    }

    if ($wReg -and $wReg.components) {
        foreach ($p in $wReg.components.PSObject.Properties) {
            $w = $p.Value
            $wKey = $p.Name
            $st = if ($script:ShellWorkloadStatesCache -and $script:ShellWorkloadStatesCache.ContainsKey($wKey)) { $script:ShellWorkloadStatesCache[$wKey] } else { "STOPPED" }

            $items.Add([PSCustomObject]@{
                Key = $wKey
                Label = $w.label
                Type = $w.type
                State = $st
                Policy = if ($w.stopPolicy) { $w.stopPolicy } else { "safe" }
                Admin = [bool]$w.admin
            })
        }
    }

    $columns = @(
        @{ Header = "KEY";     Key = "Key";    MinWidth = 8;  PreferredWidth = 14; Priority = 1; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.Key; Color = [ConsoleColor]::White } } },
        @{ Header = "LABEL";   Key = "Label";  MinWidth = 16; PreferredWidth = 34; Priority = 1; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.Label; Color = [ConsoleColor]::Gray } } },
        @{ Header = "STATE";   Key = "State";  MinWidth = 9;  PreferredWidth = 11; Priority = 1; Align = "Left";
           Formatter = { param($row, $col)
               $c = switch ($row.State) {
                   "RUNNING" { [ConsoleColor]::Green }
                   "STOPPED" { [ConsoleColor]::Yellow }
                   default   { [ConsoleColor]::DarkGray }
               }
               @{ Text = [string]$row.State; Color = $c }
           } },
        @{ Header = "POLICY";  Key = "Policy"; MinWidth = 9;  PreferredWidth = 12; Priority = 2; Align = "Left";
           Formatter = { param($row, $col)
               $c = switch ($row.Policy) {
                   "explicit" { [ConsoleColor]::Cyan }
                   "confirm"  { [ConsoleColor]::Yellow }
                   default    { [ConsoleColor]::DarkCyan }
               }
               @{ Text = ("[{0}]" -f $row.Policy.ToUpperInvariant()); Color = $c }
           } },
        @{ Header = "ADMIN";   Key = "Admin";  MinWidth = 5;  PreferredWidth = 7;  Priority = 3; Align = "Left";
           Formatter = { param($row, $col)
               $t = if ($row.Admin) { "YES" } else { "NO" }
               @{ Text = $t; Color = [ConsoleColor]::DarkGray }
           } }
    )

    [int]$budget = if ($height -ge 35) {
        [int][math]::Max(5, [int]($height - 18))
    } else {
        [int][math]::Max(4, [int]($height - 8))
    }

    $tableModel = New-WorkCtlTableModel `
        -Columns $columns `
        -Rows $items `
        -SelectedIndex $State.SelectedWorkloadIndex `
        -ScrollOffset $State.WorkloadScroll `
        -ViewportHeight $budget `
        -Width $width `
        -ShowCursor $true

    $State.WorkloadScroll = $tableModel.Viewport.Offset
    $f.Add($tableModel.HeaderLine)
    $f.Add($tableModel.SeparatorLine)
    foreach ($dl in $tableModel.DataLines) {
        $f.Add($dl)
    }

    # Contextual Preview Card for tall viewports (clean presentation, no fake ASCII borders)
    [int]$remainingRows = [int]($canvas.FooterSepRow - $f.Count)
    if ($remainingRows -ge 5 -and $items.Count -gt 0 -and $State.SelectedWorkloadIndex -lt $items.Count) {
        $selItem = $items[$State.SelectedWorkloadIndex]
        $wFull = if ($wReg -and $wReg.components -and $wReg.components.PSObject.Properties[$selItem.Key]) { $wReg.components.PSObject.Properties[$selItem.Key].Value } else { $null }

        $f.Add((New-UiLine @((New-UiSegment ""))))
        $f.Add((New-WorkCtlSeparatorLine -Width $width))

        $desc = if ($wFull -and $wFull.description) { $wFull.description } else { "Managed workstation component." }
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "SELECTED WORKLOAD: " Cyan),
            (New-UiSegment $selItem.Label White),
            (New-UiSegment "  (Key: " DarkGray),
            (New-UiSegment $selItem.Key Yellow),
            (New-UiSegment ")" DarkGray)
        )))

        $groupsStr = if ($wFull -and $wFull.groups) { $wFull.groups -join ", " } else { "none" }
        $stCol = if ($selItem.State -eq "RUNNING") { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "State: " DarkGray), (New-UiSegment ("{0,-12}" -f $selItem.State) $stCol),
            (New-UiSegment "   Policy: " DarkGray), (New-UiSegment ("{0,-12}" -f $selItem.Policy) Cyan),
            (New-UiSegment "   Groups: " DarkGray), (New-UiSegment $groupsStr White)
        )))

        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "Desc:  " DarkGray),
            (New-UiSegment $desc DarkGray)
        )))
    }

    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "UP/DN"; Label = "Select" },
            @{ Key = "ENTER/I"; Label = "Inspect" },
            @{ Key = "S";     Label = "Start" },
            @{ Key = "K";     Label = "Stop (Protected)" },
            @{ Key = "R";     Label = "Restart" },
            @{ Key = "ESC/B"; Label = "Back" }
        ) `
        -RightText ("Workloads: " + $items.Count) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellWorkloadDetailFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $wKey = $State.SelectedWorkload
    $w = $null
    $wReg = Get-ShellCachedWorkloads
    if ($wReg -and $wReg.components -and $wReg.components.PSObject.Properties[$wKey]) {
        $w = $wReg.components.PSObject.Properties[$wKey].Value
    }

    $title = if ($w) { $w.label.ToUpperInvariant() } else { "WORKLOAD DETAILS" }
    $f.Add((New-WorkCtlHeaderLine @("WORKLOADS", $title) -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    if ($w) {
        $st = "STOPPED"
        try { if (Get-Command Get-WorkloadState -ErrorAction SilentlyContinue) { $st = Get-WorkloadState $wKey } } catch {}
        $stCol = if ($st -eq "RUNNING") { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }

        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "IDENTITY & RUNTIME" Cyan)
        )))
        $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Identifier:        " DarkGray), (New-UiSegment $wKey White))))
        $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Display Label:     " DarkGray), (New-UiSegment $w.label White))))
        $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Workload Type:     " DarkGray), (New-UiSegment $w.type Cyan))))
        $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Current State:     " DarkGray), (New-UiSegment $st $stCol))))

        $desc = if ($w.description) { $w.description } else { "No description configured." }
        $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Description:       " DarkGray), (New-UiSegment $desc DarkGray))))

        $groups = if ($w.groups) { $w.groups -join ", " } else { "none" }
        $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Groups:            " DarkGray), (New-UiSegment $groups White))))

        $f.Add((New-UiLine @((New-UiSegment ""))))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "GOVERNANCE & SAFETY POLICY" Cyan)
        )))
        $pol = if ($w.stopPolicy) { $w.stopPolicy } else { "safe" }
        $polCol = switch ($pol) {
            "explicit" { [ConsoleColor]::Cyan }
            "confirm"  { [ConsoleColor]::Yellow }
            default    { [ConsoleColor]::DarkCyan }
        }
        $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Stop Policy:       " DarkGray), (New-UiSegment $pol.ToUpperInvariant() $polCol))))

        $govNote = switch ($pol) {
            "explicit" { "PROTECTED: Workload is owned by a dedicated WorkCtl subsystem. Stop operations are strictly blocked here." }
            "confirm"  { "CONFIRMATION REQUIRED: Workload has active user state. TUI prompts with modal verification before stopping." }
            default    { "SAFE: Workload can be cleanly started and stopped through standard workstation management." }
        }
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  " DarkGray),
            (New-UiSegment $govNote Yellow)
        )))

        $adminText = if ($w.admin) { "YES (Administrator)" } else { "NO" }
        $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Admin Required:    " DarkGray), (New-UiSegment $adminText White))))

        $f.Add((New-UiLine @((New-UiSegment ""))))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "ACTIVE PROCESSES & MEMORY" Cyan)
        )))

        $procs = @()
        try {
            if (Get-Command Get-WorkloadProcesses -ErrorAction SilentlyContinue) {
                $procs = @(Get-WorkloadProcesses $wKey)
            }
        } catch {}

        if ($procs.Count -gt 0) {
            foreach ($p in $procs) {
                $pId = if ($p.ProcessId) { $p.ProcessId } else { $p.Id }
                $pName = $p.Name
                $f.Add((New-UiLine @(
                    (New-UiSegment $margin DarkGray),
                    (New-UiSegment "  Process: " DarkGray), (New-UiSegment ("{0,-20}" -f $pName) White),
                    (New-UiSegment "  PID: " DarkGray), (New-UiSegment ("{0,-8}" -f $pId) Green)
                )))
            }
        } else {
            $f.Add((New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment "  No resident processes running in memory." DarkGray)
            )))
        }
    }

    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "ESC / B"; Label = "Back" },
            @{ Key = "S";       Label = "Start" },
            @{ Key = "K";       Label = "Stop" },
            @{ Key = "R";       Label = "Restart" }
        ) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellToolsListFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("TOOLS", "EXTERNAL APPLICATIONS") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $tSnap = Get-WorkCtlToolsSnapshot
    if ($tSnap.Generation -eq 0 -or !$tSnap.Data -or $tSnap.Data.Tools.Count -eq 0) {
        Update-WorkCtlToolsSnapshot -Force
        $tSnap = Get-WorkCtlToolsSnapshot
    }
    $tools = @($tSnap.Data.Tools)

    $columns = @(
        @{ Header = "ID";     Key = "Id";         MinWidth = 6;  PreferredWidth = 10; Priority = 1; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.Id; Color = [ConsoleColor]::Cyan } } },
        @{ Header = "LABEL";  Key = "Label";      MinWidth = 16; PreferredWidth = 32; Priority = 1; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.Label; Color = [ConsoleColor]::White } } },
        @{ Header = "STATUS"; Key = "StatusText"; MinWidth = 10; PreferredWidth = 14; Priority = 1; Align = "Left";
           Formatter = { param($row, $col)
               $c = switch ($row.StatusText) {
                   "RUNNING"       { [ConsoleColor]::Green }
                   "STOPPED"       { [ConsoleColor]::Yellow }
                   "NOT INSTALLED" { [ConsoleColor]::DarkGray }
                   default         { [ConsoleColor]::DarkGray }
               }
               @{ Text = [string]$row.StatusText; Color = $c }
           } },
        @{ Header = "PORT";   Key = "Port";       MinWidth = 6;  PreferredWidth = 8;  Priority = 2; Align = "Right";
           Formatter = { param($row, $col)
               $p = if ($row.Port) { [string]$row.Port } else { "-" }
               @{ Text = $p; Color = [ConsoleColor]::Cyan }
           } },
        @{ Header = "KIND";   Key = "Kind";       MinWidth = 8;  PreferredWidth = 12; Priority = 3; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.Kind; Color = [ConsoleColor]::DarkGray } } }
    )

    [int]$budget = [int][math]::Max(4, [int]($height - 8))
    $tableModel = New-WorkCtlTableModel `
        -Columns $columns `
        -Rows $tools `
        -SelectedIndex $State.SelectedToolIndex `
        -ScrollOffset $State.ToolScroll `
        -ViewportHeight $budget `
        -Width $width `
        -ShowCursor $true

    $State.ToolScroll = $tableModel.Viewport.Offset
    $f.Add($tableModel.HeaderLine)
    $f.Add($tableModel.SeparatorLine)
    foreach ($dl in $tableModel.DataLines) {
        $f.Add($dl)
    }

    # Contextual Preview Card for tall viewports (clean presentation, no fake ASCII borders)
    [int]$remainingRows = [int]($canvas.FooterSepRow - $f.Count)
    if ($remainingRows -ge 5 -and $tools.Count -gt 0 -and $State.SelectedToolIndex -lt $tools.Count) {
        $selTool = $tools[$State.SelectedToolIndex]
        $stCol = switch ($selTool.StatusText) {
            "RUNNING" { [ConsoleColor]::Green }
            "STOPPED" { [ConsoleColor]::Yellow }
            default   { [ConsoleColor]::DarkGray }
        }
        $portStr = if ($selTool.Port) { [string]$selTool.Port } else { "N/A" }
        $targetInfo = if ($selTool.WebUrl) { "Web UI: $($selTool.WebUrl)" } elseif ($selTool.InstallPath) { "Path: $($selTool.InstallPath)" } else { "Standard executable" }

        $f.Add((New-UiLine @((New-UiSegment ""))))
        $f.Add((New-WorkCtlSeparatorLine -Width $width))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "SELECTED TOOL: " Cyan),
            (New-UiSegment $selTool.Label White),
            (New-UiSegment "  (ID: " DarkGray),
            (New-UiSegment $selTool.Id Yellow),
            (New-UiSegment ")" DarkGray)
        )))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Status: " DarkGray), (New-UiSegment ("{0,-14}" -f $selTool.StatusText) $stCol),
            (New-UiSegment "Kind: " DarkGray), (New-UiSegment ("{0,-12}" -f $selTool.Kind) White),
            (New-UiSegment "Port: " DarkGray), (New-UiSegment ("{0,-8}" -f $portStr) Cyan),
            (New-UiSegment "Target: " DarkGray), (New-UiSegment $targetInfo DarkGray)
        )))
    }

    # Reserve bottom footer
    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "UP/DN"; Label = "Select" },
            @{ Key = "ENTER"; Label = "Inspect" },
            @{ Key = "O";     Label = "Web UI" },
            @{ Key = "L";     Label = "Launch" },
            @{ Key = "W";     Label = "WinDirStat" },
            @{ Key = "F";     Label = "Freebuff" },
            @{ Key = "ESC/B"; Label = "Back" }
        ) `
        -RightText ("Registered: " + $tools.Count) `
        -Width $width
    ))

    $f.ToArray()
}

# =================================================================
# STORAGE, HARDWARE & SERVICES FRAME BUILDERS
# =================================================================

function New-ShellStorageFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("STORAGE", "LOCAL VOLUMES & PHYSICAL DISKS") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $sSnap = Get-WorkCtlStorageSnapshot
    if ($sSnap.Generation -eq 0 -or !$sSnap.Data -or $sSnap.Data.LocalVolumes.Count -eq 0) {
        Update-WorkCtlStorageSnapshot -Force
        $sSnap = Get-WorkCtlStorageSnapshot
    }
    $snapData = $sSnap.Data

    # Subheader / Badge metrics
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "STATUS: " DarkGray), (New-UiSegment $sSnap.StatusBadge Green),
        (New-UiSegment "   LOCAL VOLUMES: " DarkGray), (New-UiSegment ($snapData.LocalVolumes.Count.ToString()) White),
        (New-UiSegment "   OTHER MOUNTS: " DarkGray), (New-UiSegment ($snapData.OtherMounts.Count.ToString()) Cyan),
        (New-UiSegment "   PHYSICAL DISKS: " DarkGray), (New-UiSegment ($snapData.PhysicalDisks.Count.ToString()) Yellow)
    )))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    # Unified list for selection: LocalVolumes first, then OtherMounts
    $allMounts = New-Object System.Collections.Generic.List[object]
    foreach ($lv in $snapData.LocalVolumes) { $allMounts.Add($lv) }
    foreach ($om in $snapData.OtherMounts) { $allMounts.Add($om) }

    # Section 1: Local Fixed Volumes
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "LOCAL FIXED VOLUMES (PHYSICAL NVMe / SATA)" Cyan)
    )))
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  DRIVE  LABEL           FS     CAPACITY    USED / FREE BAR         PHYSICAL BACKING" DarkGray)
    )))

    for ($i = 0; $i -lt $snapData.LocalVolumes.Count; $i++) {
        $lv = $snapData.LocalVolumes[$i]
        $isSel = ($i -eq $State.SelectedStorageIndex)
        $cursor = if ($isSel) { "> " } else { "  " }
        $bar = New-WorkCtlBar -Percent (100 - $lv.PercentFree) -Width 14

        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment $cursor Cyan),
            (New-UiSegment ("{0}:   " -f $lv.DriveLetter) Cyan),
            (New-UiSegment ("{0,-15} " -f $lv.VolumeLabel) White),
            (New-UiSegment ("{0,-6} " -f $lv.FileSystem) DarkGray),
            (New-UiSegment ("{0,6:N1} GB  " -f $lv.TotalGB) White),
            (New-UiSegment $bar Green),
            (New-UiSegment (" {0,5:N1}G free ({1,2}%)  " -f $lv.FreeGB, $lv.PercentFree) White),
            (New-UiSegment $lv.PhysicalBacking DarkGray)
        )))
    }

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # Section 2: Other Mounts (Virtual / Cloud / Network)
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "OTHER MOUNTS (CLOUD VIRTUAL / IMAGE / NETWORK)" Cyan)
    )))

    for ($j = 0; $j -lt $snapData.OtherMounts.Count; $j++) {
        $om = $snapData.OtherMounts[$j]
        $overallIdx = $snapData.LocalVolumes.Count + $j
        $isSel = ($overallIdx -eq $State.SelectedStorageIndex)
        $cursor = if ($isSel) { "> " } else { "  " }

        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment $cursor Cyan),
            (New-UiSegment ("{0}:   " -f $om.DriveLetter) Yellow),
            (New-UiSegment ("{0,-32}" -f $om.VolumeLabel) White),
            (New-UiSegment ("{0,-8}" -f $om.FileSystem) DarkGray),
            (New-UiSegment ("{0,-16}" -f $om.MountKind) DarkCyan),
            (New-UiSegment $om.PhysicalBacking DarkGray)
        )))
    }

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # Section 3: Physical Disks
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "PHYSICAL STORAGE DEVICES" Cyan)
    )))
    foreach ($pd in $snapData.PhysicalDisks) {
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  * " DarkGray),
            (New-UiSegment ("Disk {0}: {1} " -f $pd.Number, $pd.FriendlyName) White),
            (New-UiSegment ("({0}, {1:N1} GB, {2}, {3})" -f $pd.BusType, $pd.SizeGB, $pd.Health, $pd.PartitionStyle) Cyan)
        )))
    }

    # Section 4: Mounter Utility
    if ($snapData.MountedImages.Count -gt 0) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "MOUNTER VIRTUAL DISK IMAGES" Cyan)
        )))
        foreach ($mi in $snapData.MountedImages) {
            $f.Add((New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment "  [VIRTUAL] " Yellow),
                (New-UiSegment ("{0} -> {1}" -f $mi.DriveLetter, $mi.ImagePath) White)
            )))
        }
    }

    # Contextual Card for tall terminals (clean presentation, no fake ASCII borders)
    [int]$remainingRows = [int]($canvas.FooterSepRow - $f.Count)
    if ($remainingRows -ge 5 -and $allMounts.Count -gt 0 -and $State.SelectedStorageIndex -lt $allMounts.Count) {
        $selMount = $allMounts[$State.SelectedStorageIndex]

        $f.Add((New-UiLine @((New-UiSegment ""))))
        $f.Add((New-WorkCtlSeparatorLine -Width $width))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "SELECTED DRIVE: " Cyan),
            (New-UiSegment ("{0}: ({1})" -f $selMount.DriveLetter, $selMount.VolumeLabel) White),
            (New-UiSegment "   Kind: " DarkGray),
            (New-UiSegment $selMount.MountKind Yellow)
        )))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "Backing: " DarkGray),
            (New-UiSegment $selMount.PhysicalBacking White),
            (New-UiSegment "   Capacity: " DarkGray),
            (New-UiSegment ("{0} GB" -f $selMount.TotalGB) Green)
        )))
    }

    # Reserve bottom footer
    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "UP/DN"; Label = "Select" },
            @{ Key = "ENTER"; Label = "Open Explorer" },
            @{ Key = "M";     Label = "Mount ISO" },
            @{ Key = "U";     Label = "Unmount" },
            @{ Key = "R";     Label = "Refresh" },
            @{ Key = "ESC/B"; Label = "Back" }
        ) `
        -RightText ("Drives: " + $allMounts.Count) `
        -Width $width
    ))

    return $f.ToArray()
}

function New-ShellHardwareFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("HARDWARE", "CPU, GPU & FAN CONTROL INTERLOCK") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $hSnap = Get-WorkCtlHardwareSnapshot
    if ($hSnap.Generation -eq 0 -or !$hSnap.Data) {
        Update-WorkCtlHardwareSnapshot -Force
        $hSnap = Get-WorkCtlHardwareSnapshot
    }
    $hd = $hSnap.Data

    $ownerCol = switch ($hd.ActiveFanOwner) {
        "BIOS AUTO"   { [ConsoleColor]::Cyan }
        "OMENCORE"    { [ConsoleColor]::Green }
        "FANCONTROL"  { [ConsoleColor]::Green }
        "CONFLICT"    { [ConsoleColor]::Red }
        default       { [ConsoleColor]::Yellow }
    }

    $conflictText = if ($hd.OwnerConflict) { "CONFLICT!" } else { "ENGAGED" }
    $conflictCol = if ($hd.OwnerConflict) { [ConsoleColor]::Red } else { [ConsoleColor]::Green }

    # Subheader / Badge metrics
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "STATUS: " DarkGray), (New-UiSegment $hSnap.StatusBadge Green),
        (New-UiSegment "   ACTIVE FAN OWNER: " DarkGray), (New-UiSegment $hd.ActiveFanOwner $ownerCol),
        (New-UiSegment "   INTERLOCK: " DarkGray), (New-UiSegment $conflictText $conflictCol)
    )))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    # Section 1: Processor & Graphics
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "COMPUTE ENGINE & GRAPHICS TELEMETRY" Cyan)
    )))
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  CPU: " DarkGray), (New-UiSegment $hd.CpuName White)
    )))
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  GPU: " DarkGray), (New-UiSegment $hd.GpuName White),
        (New-UiSegment "  (Driver: " DarkGray), (New-UiSegment $hd.GpuDriver Cyan), (New-UiSegment ")" DarkGray)
    )))

    # Live snapshot metrics if available
    $resSnap = $State.CachedResSnapshot
    if ($resSnap) {
        $cpuPct = if ($resSnap.CPU -and $resSnap.CPU.Available) { [string]("{0,4:N1}%" -f $resSnap.CPU.UsagePercent) } else { "N/A" }
        $memUsed = if ($resSnap.Memory -and $resSnap.Memory.Available) { [string]("{0,4:N1} / {1:N1} GB ({2}%)" -f $resSnap.Memory.UsedGB, $resSnap.Memory.TotalGB, $resSnap.Memory.UsagePercent) } else { "N/A" }
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Load: CPU " DarkGray), (New-UiSegment $cpuPct Yellow),
            (New-UiSegment "   RAM " DarkGray), (New-UiSegment $memUsed Green)
        )))
    }

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # Section 2: Fan Controllers & Mutual-Exclusion Interlock
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "FAN CONTROLLERS & MUTUAL-EXCLUSION INTERLOCK" Cyan)
    )))

    # FanControl Status
    $fcCol = if ($hd.FanControlRunning) { [ConsoleColor]::Green } else { [ConsoleColor]::DarkGray }
    $fcStatusText = if ($hd.FanControlRunning) { "RUNNING (Active)" } else { "STOPPED (Ready)" }
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  FanControl (v267): " White),
        (New-UiSegment $fcStatusText $fcCol),
        (New-UiSegment ("  Config: userConfig.json ({0} curve(s) defined)" -f $hd.FanControlCurvesCount) DarkGray)
    )))

    # OmenCore Status
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  OmenCore Daemon:   " White),
        (New-UiSegment "MONITORING ONLY " Yellow),
        (New-UiSegment ("(Hardware: {0}, ID: {1})" -f $hd.OmenModel, $hd.OmenProductId) DarkGray)
    )))
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  EC Firmware State: " DarkGray),
        (New-UiSegment $hd.OmenWarning DarkGray)
    )))

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # Section 3: Safety Interlock Policies
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "SAFETY INTERLOCK GOVERNANCE POLICY" Cyan)
    )))
    if ($hd.ActiveFanOwner -eq "FANCONTROL") {
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  [INTERLOCK ACTIVE] " Green),
            (New-UiSegment "FanControl has exclusive fan hardware ownership. OmenCore mutations are locked." White)
        )))
    } elseif ($hd.ActiveFanOwner -eq "OMENCORE") {
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  [INTERLOCK ACTIVE] " Green),
            (New-UiSegment "OmenCore has fan hardware ownership. FanControl launch is guarded." White)
        )))
    } elseif ($hd.ActiveFanOwner -eq "CONFLICT") {
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  [CONFLICT DETECTED] " Red),
            (New-UiSegment "Both FanControl and OmenCore are active! Close one to avoid fighting curves." White)
        )))
    } else {
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  [DEFAULT AUTO] " Cyan),
            (New-UiSegment "BIOS automatic EC hardware fan control is active. No external software overrides." White)
        )))
    }

    # Reserve bottom footer
    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "F";     Label = "Launch FanControl" },
            @{ Key = "O";     Label = "OmenCore Status" },
            @{ Key = "R";     Label = "Refresh" },
            @{ Key = "ESC/B"; Label = "Back" }
        ) `
        -RightText ("Owner: " + $hd.ActiveFanOwner) `
        -Width $width
    ))

    return $f.ToArray()
}

function New-ShellServicesFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("SYSTEM", "WINDOWS SERVICES EXPLORER") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $sSnap = Get-WorkCtlServicesSnapshot
    if ($sSnap.Generation -eq 0 -or !$sSnap.Data -or $sSnap.Data.TotalCount -eq 0) {
        Update-WorkCtlServicesSnapshot -Force
        $sSnap = Get-WorkCtlServicesSnapshot
    }
    $allServices = @($sSnap.Data.Services)

    $category = if ($State.SelectedCategory) { $State.SelectedCategory.ToUpperInvariant() } else { "WORKSTATION" }

    # Filter according to category
    $filtered = switch ($category) {
        "RUNNING" {
            @($allServices | Where-Object { $_.Status -eq "Running" })
        }
        "STOPPED" {
            @($allServices | Where-Object { $_.Status -eq "Stopped" })
        }
        "WORKSTATION" {
            @($allServices | Where-Object {
                $_.Name -match "mysql|docker|wsl|hyper|intel|hp|omen|audio|antigravity|defender|ssh|sonarr|torrent|lanman|wuauserv|bth|spooler" -or
                $_.DisplayName -match "mysql|docker|wsl|hyper|intel|hp|omen|audio|antigravity|defender|ssh|sonarr|torrent"
            })
        }
        default {
            $allServices
        }
    }

    # Tab bar
    $tabs = @("WORKSTATION", "RUNNING", "STOPPED", "ALL")
    $tabSegments = New-Object System.Collections.Generic.List[object]
    $tabSegments.Add((New-UiSegment $margin DarkGray))
    $tabSegments.Add((New-UiSegment "FILTER: " DarkGray))
    foreach ($t in $tabs) {
        $isAct = ($t -eq $category)
        $tCol = if ($isAct) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray }
        $tabSegments.Add((New-UiSegment ("[{0}] " -f $t) $tCol))
    }
    $tabSegments.Add((New-UiSegment ("   (Showing {0} of {1} services)" -f $filtered.Count, $allServices.Count) Cyan))
    $f.Add((New-UiLine $tabSegments.ToArray()))

    $columns = @(
        @{ Header = "SERVICE NAME"; Key = "Name";        MinWidth = 12; PreferredWidth = 20; Priority = 1; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.Name; Color = [ConsoleColor]::White } } },
        @{ Header = "DISPLAY NAME"; Key = "DisplayName"; MinWidth = 16; PreferredWidth = 36; Priority = 1; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.DisplayName; Color = [ConsoleColor]::Gray } } },
        @{ Header = "STATUS";       Key = "Status";      MinWidth = 9;  PreferredWidth = 11; Priority = 1; Align = "Left";
           Formatter = { param($row, $col)
               $c = if ($row.Status -eq "Running") { [ConsoleColor]::Green } else { [ConsoleColor]::DarkGray }
               @{ Text = [string]$row.Status; Color = $c }
           } },
        @{ Header = "STARTUP";      Key = "StartType";   MinWidth = 8;  PreferredWidth = 12; Priority = 2; Align = "Left";
           Formatter = { param($row, $col)
               $c = if ($row.StartType -eq "Automatic") { [ConsoleColor]::Cyan } else { [ConsoleColor]::DarkGray }
               @{ Text = [string]$row.StartType; Color = $c }
           } }
    )

    [int]$budget = if ($height -ge 35) {
        [int][math]::Max(5, [int]($height - 18))
    } else {
        [int][math]::Max(4, [int]($height - 8))
    }

    $tableModel = New-WorkCtlTableModel `
        -Columns $columns `
        -Rows $filtered `
        -SelectedIndex $State.SelectedServiceIndex `
        -ScrollOffset $State.ServiceScroll `
        -ViewportHeight $budget `
        -Width $width `
        -ShowCursor $true

    $State.ServiceScroll = $tableModel.Viewport.Offset
    $f.Add($tableModel.HeaderLine)
    $f.Add($tableModel.SeparatorLine)
    foreach ($dl in $tableModel.DataLines) {
        $f.Add($dl)
    }

    # Contextual Card for tall terminals (clean presentation, no fake ASCII borders)
    [int]$remainingRows = [int]($canvas.FooterSepRow - $f.Count)
    if ($remainingRows -ge 5 -and $filtered.Count -gt 0 -and $State.SelectedServiceIndex -lt $filtered.Count) {
        $selService = $filtered[$State.SelectedServiceIndex]
        $stCol = if ($selService.Status -eq "Running") { [ConsoleColor]::Green } else { [ConsoleColor]::DarkGray }

        $f.Add((New-UiLine @((New-UiSegment ""))))
        $f.Add((New-WorkCtlSeparatorLine -Width $width))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "SELECTED SERVICE: " Cyan),
            (New-UiSegment $selService.Name White),
            (New-UiSegment "  (Status: " DarkGray),
            (New-UiSegment $selService.Status $stCol),
            (New-UiSegment ")" DarkGray)
        )))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Display: " DarkGray),
            (New-UiSegment $selService.DisplayName White),
            (New-UiSegment "   Startup: " DarkGray),
            (New-UiSegment $selService.StartType Cyan)
        )))

        # Protected status notice
        if ($selService.Name -match "antigravity|powertoys") {
            $f.Add((New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment "  POLICY: [PROTECTED WORKSTATION SERVICE] Mutation blocked by safety rules." Yellow)
            )))
        }
    }

    # Reserve bottom footer
    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "UP/DN"; Label = "Select" },
            @{ Key = "TAB";   Label = "Cycle Filter" },
            @{ Key = "S";     Label = "Start" },
            @{ Key = "K";     Label = "Stop" },
            @{ Key = "R";     Label = "Refresh" },
            @{ Key = "ESC/B"; Label = "Back" }
        ) `
        -RightText ("Services: " + $filtered.Count) `
        -Width $width
    ))

    return $f.ToArray()
}

function New-ShellProcessesFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("SYSTEM", "PROCESS EXPLORER") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $procs = @(Get-ShellProcessesCached)

    $columns = @(
        @{ Header = "PID";      Key = "Id";     MinWidth = 6;  PreferredWidth = 8;  Priority = 1; Align = "Right";
           Formatter = { param($row, $col) @{ Text = [string]$row.Id; Color = [ConsoleColor]::Yellow } } },
        @{ Header = "PROCESS";  Key = "Name";   MinWidth = 12; PreferredWidth = 24; Priority = 1; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.Name; Color = [ConsoleColor]::White } } },
        @{ Header = "RAM (MB)"; Key = "RAM_MB"; MinWidth = 9;  PreferredWidth = 12; Priority = 1; Align = "Right";
           Formatter = { param($row, $col) @{ Text = ("{0,8:N1}" -f $row.RAM_MB); Color = [ConsoleColor]::Green } } },
        @{ Header = "CPU (s)";  Key = "CPU_s";  MinWidth = 8;  PreferredWidth = 11; Priority = 2; Align = "Right";
           Formatter = { param($row, $col) @{ Text = ("{0,8:N1}" -f $row.CPU_s); Color = [ConsoleColor]::Yellow } } },
        @{ Header = "PATH";     Key = "Path";   MinWidth = 14; PreferredWidth = 40; Priority = 3; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.Path; Color = [ConsoleColor]::DarkGray } } }
    )

    [int]$budget = if ($height -ge 35) {
        [int][math]::Max(5, [int]($height - 18))
    } else {
        [int][math]::Max(4, [int]($height - 8))
    }

    $tableModel = New-WorkCtlTableModel `
        -Columns $columns `
        -Rows $procs `
        -SelectedIndex $State.SelectedProcessIndex `
        -ScrollOffset $State.ProcessScroll `
        -ViewportHeight $budget `
        -Width $width `
        -ShowCursor $true

    $State.ProcessScroll = $tableModel.Viewport.Offset
    $f.Add($tableModel.HeaderLine)
    $f.Add($tableModel.SeparatorLine)
    foreach ($dl in $tableModel.DataLines) {
        $f.Add($dl)
    }

    # Contextual Preview Card for tall viewports (clean presentation, no fake ASCII borders)
    [int]$remainingRows = [int]($canvas.FooterSepRow - $f.Count)
    if ($remainingRows -ge 5 -and $procs.Count -gt 0 -and $State.SelectedProcessIndex -lt $procs.Count) {
        $selProc = $procs[$State.SelectedProcessIndex]
        $f.Add((New-UiLine @((New-UiSegment ""))))
        $f.Add((New-WorkCtlSeparatorLine -Width $width))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "SELECTED PROCESS: " Cyan),
            (New-UiSegment $selProc.Name White),
            (New-UiSegment "  (PID: " DarkGray),
            (New-UiSegment ("{0}" -f $selProc.Id) Yellow),
            (New-UiSegment ")" DarkGray)
        )))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  RAM: " DarkGray), (New-UiSegment ("{0:N1} MB" -f $selProc.RAM_MB) Green),
            (New-UiSegment "   CPU Time: " DarkGray), (New-UiSegment ("{0:N1} s" -f $selProc.CPU_s) Yellow),
            (New-UiSegment "   Path: " DarkGray), (New-UiSegment $(if ($selProc.Path) { $selProc.Path } else { "System / Protected" }) DarkGray)
        )))
    }

    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "UP/DN"; Label = "Select" },
            @{ Key = "R";     Label = "Refresh" },
            @{ Key = "ESC/B"; Label = "Back" }
        ) `
        -RightText ("Top Processes: " + $procs.Count) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellNetworkFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("NETWORK", "WORKSTATION OVERVIEW & INTERFACES") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $net = Get-ShellNetworkOverviewCached
    $isWide = $canvas.IsWide
    $leftW = $canvas.LeftPaneWidth
    $gapW = $canvas.PaneGap
    $rightW = $canvas.RightPaneWidth

    # Left Navigation Menu & Right Telemetry Pane
    $navItems = @(
        @{ Key = "P"; Label = "Listening Ports";   Desc = ("{0} active listening sockets" -f $net.ListeningPorts) },
        @{ Key = "I"; Label = "Interfaces";        Desc = ("{0} ({1})" -f $net.AdapterName, $net.AdapterType) },
        @{ Key = "C"; Label = "TCP Connections";   Desc = "Active workstation connections" },
        @{ Key = "D"; Label = "DNS Resolution";     Desc = "DNS servers & cache state" },
        @{ Key = "R"; Label = "Routing Table";      Desc = ("Gateway {0}" -f $net.Gateway) }
    )

    $rightLines = @(
        "PRIMARY ADAPTER TELEMETRY",
        ("Adapter:      {0} ({1})" -f $net.AdapterName, $net.AdapterType),
        ("Status:       [{0}] Connected" -f $net.Status),
        ("IPv4 Address: {0}" -f $net.IPv4Address),
        ("Subnet Mask:  {0}" -f $net.SubnetMask),
        ("Default GW:   {0}" -f $net.Gateway),
        ("DNS Servers:  {0}" -f $net.DnsServers),
        ("Link Speed:   {0}" -f $net.LinkSpeed),
        ("MAC Address:  {0}" -f $net.MacAddress),
        ("Throughput:   Rx {0:N1} MB  /  Tx {1:N1} MB" -f ($net.BytesReceived / 1MB), ($net.BytesSent / 1MB))
    )

    $rowCount = [math]::Max($navItems.Count + 2, $rightLines.Count)

    for ($r = 0; $r -lt $rowCount; $r++) {
        $rowSegs = New-Object System.Collections.Generic.List[object]
        $rowSegs.Add((New-UiSegment $margin DarkGray))

        # Left Column: Navigation items
        if ($r -eq 0) {
            $rowSegs.Add((New-UiSegment ("{0,-$leftW}" -f "MODULES & NAVIGATION") DarkGray))
        } elseif ($r -eq 1) {
            $rowSegs.Add((New-UiSegment (" " * $leftW) DarkGray))
        } else {
            $idx = $r - 2
            if ($idx -lt $navItems.Count) {
                $item = $navItems[$idx]
                $isPorts = ($item.Key -eq "P")
                $keyCol = if ($isPorts) { [ConsoleColor]::Cyan } else { [ConsoleColor]::DarkGray }
                $lblCol = if ($isPorts) { [ConsoleColor]::White } else { [ConsoleColor]::Gray }
                $descCol = [ConsoleColor]::DarkGray

                [int]$leftRem = [math]::Max(6, $leftW - 6 - 18)
                $descTxt = [string]$item.Desc
                if ($descTxt.Length -gt $leftRem) {
                    $descTxt = if ($leftRem -gt 2) { $descTxt.Substring(0, $leftRem - 2) + ".." } else { $descTxt.Substring(0, $leftRem) }
                }

                $rowSegs.Add((New-UiSegment "  " DarkGray))
                $rowSegs.Add((New-UiSegment ("[{0}] " -f $item.Key) $keyCol))
                $rowSegs.Add((New-UiSegment ("{0,-18}" -f $item.Label) $lblCol))
                $rowSegs.Add((New-UiSegment ("{0,-$leftRem}" -f $descTxt) $descCol))
            } else {
                $rowSegs.Add((New-UiSegment (" " * $leftW) DarkGray))
            }
        }

        # Right Column (Wide viewports)
        if ($isWide) {
            $rowSegs.Add((New-UiSegment (" " * $gapW) DarkGray))
            if ($r -lt $rightLines.Count) {
                $rTxt = $rightLines[$r]
                if ($rTxt.Length -gt $rightW) {
                    $rTxt = if ($rightW -gt 2) { $rTxt.Substring(0, $rightW - 2) + ".." } else { $rTxt.Substring(0, $rightW) }
                }
                $rCol = if ($r -eq 0) { [ConsoleColor]::White }
                        elseif ($rTxt -match "^Status:") { [ConsoleColor]::Green }
                        elseif ($rTxt -match "^IPv4 Address:") { [ConsoleColor]::Cyan }
                        else { [ConsoleColor]::Gray }
                $rowSegs.Add((New-UiSegment ("{0,-$rightW}" -f $rTxt) $rCol))
            } else {
                $rowSegs.Add((New-UiSegment (" " * $rightW) DarkGray))
            }
        }

        $f.Add((New-UiLine $rowSegs.ToArray()))
    }

    # Pad lines strictly to FooterSepRow
    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "P/ENTER"; Label = "Listening Ports" },
            @{ Key = "R";       Label = "Refresh Overview" },
            @{ Key = "ESC/B";   Label = "Back" }
        ) `
        -RightText ("Interface: " + $net.AdapterName) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellNetworkPortsFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("NETWORK", "LISTENING PORTS & SOCKETS") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $filter = if ($State.PortFilter) { $State.PortFilter.ToUpperInvariant() } else { "ALL" }
    $ports = @(Get-ShellNetworkPortsCached -Filter $filter)
    $allPorts = @(Get-ShellNetworkPortsCached -Filter "ALL")

    # Filter tab line
    $tabs = @("ALL", "LOCALHOST", "LAN", "SYSTEM", "WORKCTL")
    $tabSegs = New-Object System.Collections.Generic.List[object]
    $tabSegs.Add((New-UiSegment $margin DarkGray))
    $tabSegs.Add((New-UiSegment "FILTER: " DarkGray))
    foreach ($t in $tabs) {
        $isAct = ($t -eq $filter)
        $tCol = if ($isAct) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray }
        $tabSegs.Add((New-UiSegment ("[{0}] " -f $t) $tCol))
    }
    $tabSegs.Add((New-UiSegment ("   (Showing {0} of {1} sockets)" -f $ports.Count, $allPorts.Count) Cyan))
    $f.Add((New-UiLine $tabSegs.ToArray()))

    # Table columns definition
    $columns = @(
        @{ Header = "PORT";    Key = "Port";    MinWidth = 6;  PreferredWidth = 8;  Priority = 1; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.Port; Color = [ConsoleColor]::Cyan } } },
        @{ Header = "ADDRESS"; Key = "Address"; MinWidth = 10; PreferredWidth = 16; Priority = 1; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.Address; Color = [ConsoleColor]::White } } },
        @{ Header = "STATE";   Key = "State";   MinWidth = 9;  PreferredWidth = 11; Priority = 2; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.State; Color = [ConsoleColor]::Green } } },
        @{ Header = "PID";     Key = "PID";     MinWidth = 6;  PreferredWidth = 8;  Priority = 2; Align = "Right";
           Formatter = { param($row, $col) @{ Text = [string]$row.PID; Color = [ConsoleColor]::Yellow } } },
        @{ Header = "PROCESS"; Key = "Process"; MinWidth = 10; PreferredWidth = 22; Priority = 1; Align = "Left";
           Formatter = { param($row, $col) @{ Text = [string]$row.Process; Color = [ConsoleColor]::White } } },
        @{ Header = "SCOPE";   Key = "Scope";   MinWidth = 8;  PreferredWidth = 12; Priority = 3; Align = "Left";
           Formatter = { param($row, $col)
               $c = if ($row.Scope -eq "Localhost") { [ConsoleColor]::DarkCyan } elseif ($row.Scope -eq "LAN") { [ConsoleColor]::Gray } else { [ConsoleColor]::Yellow }
               @{ Text = [string]$row.Scope; Color = $c }
           } }
    )

    [int]$budget = if ($height -ge 35) {
        [int][math]::Max(5, [int]($height - 18))
    } else {
        [int][math]::Max(4, [int]($height - 8))
    }

    $tableModel = New-WorkCtlTableModel `
        -Columns $columns `
        -Rows $ports `
        -SelectedIndex $State.SelectedPortIndex `
        -ScrollOffset $State.PortScroll `
        -ViewportHeight $budget `
        -Width $width `
        -ShowCursor $true

    $State.PortScroll = $tableModel.Viewport.Offset
    $f.Add($tableModel.HeaderLine)
    $f.Add($tableModel.SeparatorLine)
    foreach ($dl in $tableModel.DataLines) {
        $f.Add($dl)
    }

    # Contextual Preview Card for tall viewports
    [int]$remainingRows = [int]($canvas.FooterSepRow - $f.Count)
    if ($remainingRows -ge 5 -and $ports.Count -gt 0 -and $State.SelectedPortIndex -lt $ports.Count) {
        $selPort = $ports[$State.SelectedPortIndex]
        $f.Add((New-UiLine @((New-UiSegment ""))))
        $f.Add((New-WorkCtlSeparatorLine -Width $width))
        $serviceDesc = if ($selPort.KnownService) { "  (Service: $($selPort.KnownService))" } else { "" }
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "SELECTED SOCKET: " Cyan),
            (New-UiSegment ("Port {0} ({1})" -f $selPort.Port, $selPort.Scope) White),
            (New-UiSegment $serviceDesc Yellow)
        )))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Process: " DarkGray), (New-UiSegment $selPort.Process White),
            (New-UiSegment "   PID: " DarkGray), (New-UiSegment ($selPort.PID.ToString()) Yellow),
            (New-UiSegment "   Bound Address: " DarkGray), (New-UiSegment $selPort.FullAddress Cyan)
        )))
    }

    # Pad lines strictly up to FooterSepRow
    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "UP/DN"; Label = "Select" },
            @{ Key = "TAB";   Label = "Cycle Filter" },
            @{ Key = "R";     Label = "Refresh Ports" },
            @{ Key = "ESC/B"; Label = "Back" }
        ) `
        -RightText ("Sockets: " + $ports.Count) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellDiagnosticsFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("DIAGNOSTICS", "HEALTH AUDIT & PROTECTED COMPONENTS") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "SYSTEM PRIVILEGES & INTEGRITY" White))))
    $isAdmin = $false
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        $isAdmin = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {}

    $admText = if ($isAdmin) { "ELEVATED (Administrator)" } else { "STANDARD (Non-Admin - Some operations require elevation)" }
    $admCol = if ($isAdmin) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Privilege Level:   " DarkGray), (New-UiSegment $admText $admCol))))

    $f.Add((New-UiLine @((New-UiSegment ""))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "PROTECTED SYSTEM COMPONENTS (GOVERNANCE SHIELDS)" White))))

    $protected = @("Google Drive", "Windows Defender", "NVIDIA Display Container", "Realtek Audio", "HP System Event Utility", "WSL", "Antigravity", "Microsoft PowerToys")
    foreach ($item in $protected) {
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  [SHIELDED] " Green),
            (New-UiSegment ("{0,-30}" -f $item) White),
            (New-UiSegment "Protected from automated termination" DarkGray)
        )))
    }

    # Pad lines strictly up to FooterSepRow
    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "ESC/B"; Label = "Back to Overview" }
        ) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellSearchFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("GLOBAL SEARCH", ("QUERY: " + $State.SearchQuery.ToUpperInvariant())) -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $index = Get-ShellEntityIndex
    $query = $State.SearchQuery
    $matches = @($index | Where-Object {
        $_.Key -like "*$query*" -or $_.Label -like "*$query*" -or $_.Group -like "*$query*"
    })

    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  TYPE            KEY               LABEL" DarkGray)
    )))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    [int]$budget = [int][math]::Max(4, [int]($height - 8))
    $vp = Get-WorkCtlViewport -Total $matches.Count -Selected $State.SelectedSearchIndex -Height $budget -CurrentOffset $State.SearchScroll
    $State.SearchScroll = $vp.Offset

    for ($i = $vp.Offset; $i -le $vp.End; $i++) {
        if ($i -ge $matches.Count) { break }
        $m = $matches[$i]
        $isSel = ($i -eq $State.SelectedSearchIndex)
        $cursor = if ($isSel) { "> " } else { "  " }

        $kindCol = switch ($m.Kind) {
            "WORKLOAD"    { [ConsoleColor]::Green }
            "TOOL"        { [ConsoleColor]::Cyan }
            "POWERTOYS"   { [ConsoleColor]::Cyan }
            "DESTINATION" { [ConsoleColor]::Yellow }
            default       { [ConsoleColor]::White }
        }

        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment $cursor Cyan),
            (New-UiSegment ("[{0,-12}]" -f $m.Kind) $kindCol),
            (New-UiSegment (" {0,-18}" -f $m.Key) White),
            (New-UiSegment $m.Label DarkGray)
        )))
    }

    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "UP/DN"; Label = "Select" },
            @{ Key = "ENTER"; Label = "Navigate" },
            @{ Key = "/";     Label = "New Search" },
            @{ Key = "ESC/B"; Label = "Back" }
        ) `
        -RightText ("Matches: " + $matches.Count) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellHelpFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("HELP", "HYBRID WORKSTATION SHELL GUIDE") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "MODE A - KEYBOARD-DRIVEN TUI NAVIGATION" Cyan))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Up / Down / Enter     " Cyan), (New-UiSegment "Move selection and navigate deeper into control planes" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Escape / B            " Cyan), (New-UiSegment "Return up one level in hierarchy (or back to Home)" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  / (Slash)             " Cyan), (New-UiSegment "Global cross-subsystem search (Workloads, PowerToys, Tools)" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  : (Colon)             " Cyan), (New-UiSegment "Enter Command Shell Mode (Fish/Zsh-inspired with Tab completion)" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Q / X                 " Cyan), (New-UiSegment "Exit WorkCtl shell cleanly to PowerShell prompt" White))))

    $f.Add((New-UiLine @((New-UiSegment ""))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "MODE B - WORKCTL COMMAND SHELL" Cyan))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  status / res / top    " Cyan), (New-UiSegment "Quick telemetry and top process inspection" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  workloads / tools     " Cyan), (New-UiSegment "Jump directly into workload or tool registries" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  start / stop <target> " Cyan), (New-UiSegment "Lifecycle management with safe/confirm/explicit governance" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  pt <module>           " Cyan), (New-UiSegment "Open PowerToys utility directly (e.g. pt fancyzones)" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  ! <native command>    " Cyan), (New-UiSegment "Execute underlying Windows PowerShell command in current directory" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  cd / pwd / ls         " Cyan), (New-UiSegment "Navigate local workstation filesystem and workspace roots" White))))

    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "ESC / Any Key"; Label = "Return to Previous Screen" }
        ) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellCommandOutputFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $out = $State.CommandOutput
    $title = if ($out -and $out.Title) { $out.Title } else { "COMMAND OUTPUT" }
    $f.Add((New-WorkCtlHeaderLine @("COMMAND OUTPUT", $title) -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $cmdText = if ($out -and $out.Command) { $out.Command } else { "-" }
    $pathText = if ($out -and $out.Path) { $out.Path } else { $State.CurrentDirectory }
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "Executed: " DarkGray),
        (New-UiSegment $cmdText Cyan),
        (New-UiSegment "   Path: " DarkGray),
        (New-UiSegment $pathText White)
    )))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    [int]$budget = [int](Get-WorkCtlContentBudget -ReservedHeaderRows 4 -ReservedFooterRows 2 -Height $height)

    if ($out -and $out.IsTable -and $out.Rows) {
        # Structured tabular output (e.g. ls)
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  TYPE   " Cyan),
            (New-UiSegment ("{0,-38}" -f "NAME") Cyan),
            (New-UiSegment ("{0,12}" -f "SIZE  ") Cyan),
            (New-UiSegment "LAST MODIFIED" Cyan)
        )))
        [int]$tableBudget = [math]::Max(2, [int]($budget - 1))
        [int]$total = [int]$out.Rows.Count

        $vp = Get-WorkCtlViewport -Total $total -Selected $out.Scroll -Height $tableBudget -CurrentOffset $out.Scroll
        $out.Scroll = $vp.Offset

        for ($i = $vp.Offset; $i -le $vp.End; $i++) {
            if ($i -ge $total) { break }
            $r = $out.Rows[$i]
            $typeCol = if ($r.IsDir) { [ConsoleColor]::Yellow } else { [ConsoleColor]::DarkGray }
            $nameCol = if ($r.IsDir) { [ConsoleColor]::Cyan } else { [ConsoleColor]::White }
            $nameTrunc = if ($r.Name.Length -gt 36) { $r.Name.Substring(0, 33) + "..." } else { $r.Name }

            $f.Add((New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment ("  {0,-7}" -f $r.Type) $typeCol),
                (New-UiSegment ("{0,-38}" -f $nameTrunc) $nameCol),
                (New-UiSegment ("{0,10}  " -f $r.Size) DarkGray),
                (New-UiSegment $r.Modified DarkGray)
            )))
        }

        for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
            $f.Add((New-UiLine @((New-UiSegment ""))))
        }

        $f.Add((New-WorkCtlSeparatorLine -Width $width))
        $f.Add((New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "UP/DN";     Label = "Scroll" },
                @{ Key = "PGUP/PGDN"; Label = "Page" },
                @{ Key = ":";         Label = "Command" },
                @{ Key = "ESC/ENTER"; Label = "Back" }
            ) `
            -RightText ("Items: {0}-{1} of {2}" -f ($vp.Offset + 1), ([math]::Min($total, $vp.Offset + $tableBudget)), $total) `
            -Width $width
        ))
    } else {
        # Raw lines output (e.g. !, help, pwd)
        $rawLines = if ($out -and $out.Lines) { @($out.Lines) } else { @("No output.") }
        [int]$total = [int]$rawLines.Count

        $vp = Get-WorkCtlViewport -Total $total -Selected $out.Scroll -Height $budget -CurrentOffset $out.Scroll
        $out.Scroll = $vp.Offset

        for ($i = $vp.Offset; $i -le $vp.End; $i++) {
            if ($i -ge $total) { break }
            $lineStr = [string]$rawLines[$i]

            # Colorize line based on prefixes
            $lineCol = [ConsoleColor]::White
            if ($lineStr.StartsWith("===") -or $lineStr.StartsWith("---")) {
                $lineCol = [ConsoleColor]::DarkCyan
            } elseif ($lineStr.StartsWith("[ERROR]") -or $lineStr.StartsWith("[EXECUTION EXCEPTION]")) {
                $lineCol = [ConsoleColor]::Red
            } elseif ($lineStr.StartsWith("USAGE:") -or $lineStr.StartsWith("COMMAND:") -or $lineStr.StartsWith("Current Working Directory:")) {
                $lineCol = [ConsoleColor]::Cyan
            } elseif ($lineStr.StartsWith("workctl >")) {
                $lineCol = [ConsoleColor]::Green
            }

            # Truncate line safely to viewport width
            [int]$maxTextLen = [math]::Max(10, [int]($width - ($margin.Length * 2) - 2))
            if ($lineStr.Length -gt $maxTextLen) {
                $lineStr = $lineStr.Substring(0, $maxTextLen - 3) + "..."
            }

            $f.Add((New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment "  " DarkGray),
                (New-UiSegment $lineStr $lineCol)
            )))
        }

        for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
            $f.Add((New-UiLine @((New-UiSegment ""))))
        }

        $f.Add((New-WorkCtlSeparatorLine -Width $width))
        $f.Add((New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "UP/DN";     Label = "Scroll" },
                @{ Key = "PGUP/PGDN"; Label = "Page" },
                @{ Key = ":";         Label = "Command" },
                @{ Key = "ESC/ENTER"; Label = "Back" }
            ) `
            -RightText ("Lines: {0}-{1} of {2}" -f ($vp.Offset + 1), ([math]::Min($total, $vp.Offset + $budget)), $total) `
            -Width $width
        ))
    }

    $f.ToArray()
}

function Initialize-WorkCtlDevState {
    return [ordered]@{
        SelectedMenuIndex = 0
        SelectedAgentIndex = 0
        AgentScroll = 0
        LastRefresh = [datetime]::MinValue
    }
}

function New-ShellDevMenuFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("DEVELOPMENT", "WORKSPACE & AI AGENTS COCKPIT") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    if (!(Get-Command Get-WorkCtlProjects -ErrorAction SilentlyContinue)) {
        if (Get-Command Import-WorkCtlSubsystem -ErrorAction SilentlyContinue) {
            Import-WorkCtlSubsystem "development"
        }
    }

    if (!$State.DevelopmentState) {
        $State.DevelopmentState = Initialize-WorkCtlDevState
    }

    $projs = @(Get-WorkCtlProjects)
    $agents = @(Get-WorkCtlAiAgents)
    $runtimes = @(Get-WorkCtlRuntimes)

    # Active Workspace Banner
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "WORKSPACE ROOT: " DarkGray),
        (New-UiSegment "E:\Workspace" Cyan),
        (New-UiSegment "   DISCOVERED: " DarkGray),
        (New-UiSegment ("{0} Projects" -f $projs.Count) Green),
        (New-UiSegment "   AI AGENTS: " DarkGray),
        (New-UiSegment ("{0} Registered" -f $agents.Count) Cyan)
    )))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    # Subsystem Menu Items
    $menuItems = @(
        @{ Key = "P"; Label = "Projects Explorer";     Desc = ("Browse & inspect {0} discovered workspace repositories" -f $projs.Count) },
        @{ Key = "A"; Label = "AI Coding Agents";      Desc = ("Freebuff CLI & AI developer assistants ({0} registered)" -f $agents.Count) },
        @{ Key = "F"; Label = "Launch Freebuff";       Desc = "Start terminal interactive coding loop in E:\Workspace" },
        @{ Key = "C"; Label = "Open VS Code";          Desc = "Launch Visual Studio Code in current workspace" },
        @{ Key = "R"; Label = "Refresh Discovery";     Desc = "Force rescanning of workspace repositories and agents" }
    )

    for ($i = 0; $i -lt $menuItems.Count; $i++) {
        $item = $menuItems[$i]
        $isSel = ($i -eq $State.DevelopmentState.SelectedMenuIndex)
        $cursor = if ($isSel) { "> " } else { "  " }
        $col = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::White }

        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment $cursor Cyan),
            (New-UiSegment ("[{0}] " -f $item.Key) Yellow),
            (New-UiSegment ("{0,-24}" -f $item.Label) $col),
            (New-UiSegment $item.Desc DarkGray)
        )))
    }

    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "ESC / B"; Label = "Back" },
            @{ Key = "ENTER";   Label = "Open" },
            @{ Key = "F";       Label = "Freebuff" },
            @{ Key = "C";       Label = "VS Code" },
            @{ Key = "R";       Label = "Refresh" }
        ) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellProjectsFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("DEVELOPMENT", "WORKSPACE PROJECTS (E:\Workspace)") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    if (!(Get-Command Get-WorkCtlProjects -ErrorAction SilentlyContinue)) {
        if (Get-Command Import-WorkCtlSubsystem -ErrorAction SilentlyContinue) {
            Import-WorkCtlSubsystem "development"
        }
    }

    $projects = @(Get-WorkCtlProjects)

    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  PROJECT NAME             PRIMARY TYPE       BRANCH       LAST MODIFIED" DarkGray)
    )))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    [int]$budget = [int][math]::Max(4, [int]($height - 10))
    $vp = Get-WorkCtlViewport -Total $projects.Count -Selected $State.SelectedProjectIndex -Height $budget -CurrentOffset $State.ProjectScroll
    $State.ProjectScroll = $vp.Offset

    for ($i = $vp.Offset; $i -le $vp.End; $i++) {
        if ($i -ge $projects.Count) { break }
        $p = $projects[$i]
        $isSel = ($i -eq $State.SelectedProjectIndex)
        $cursor = if ($isSel) { "> " } else { "  " }
        $nameCol = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::White }

        $branchStr = if ($p.Branch) { $p.Branch } else { "-" }
        $mtimeStr = if ($p.LastModified) { $p.LastModified.ToString("yyyy-MM-dd HH:mm") } else { "-" }

        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment $cursor Cyan),
            (New-UiSegment ("{0,-25}" -f $p.Name) $nameCol),
            (New-UiSegment ("{0,-19}" -f $p.PrimaryType) Yellow),
            (New-UiSegment ("{0,-13}" -f $branchStr) Green),
            (New-UiSegment $mtimeStr DarkGray)
        )))
    }

    # Contextual Preview Card (clean presentation, no fake ASCII borders)
    [int]$remainingRows = [int]($canvas.FooterSepRow - $f.Count)
    if ($remainingRows -ge 5 -and $projects.Count -gt 0 -and $State.SelectedProjectIndex -lt $projects.Count) {
        $selProj = $projects[$State.SelectedProjectIndex]

        $f.Add((New-UiLine @((New-UiSegment ""))))
        $f.Add((New-WorkCtlSeparatorLine -Width $width))

        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "SELECTED PROJECT: " Cyan),
            (New-UiSegment $selProj.Name White),
            (New-UiSegment "  (Path: " DarkGray),
            (New-UiSegment $selProj.Path DarkGray),
            (New-UiSegment ")" DarkGray)
        )))

        $typeList = if ($selProj.Types) { $selProj.Types -join ", " } else { "General" }
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "Stack: " DarkGray), (New-UiSegment $typeList Yellow),
            (New-UiSegment "   Branch: " DarkGray), (New-UiSegment $selProj.Branch Green)
        )))
    }

    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "ESC / B"; Label = "Back" },
            @{ Key = "ENTER";   Label = "Inspect" },
            @{ Key = "F";       Label = "Freebuff" },
            @{ Key = "C";       Label = "VS Code" },
            @{ Key = "E";       Label = "Explorer" },
            @{ Key = "R";       Label = "Refresh" }
        ) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellProjectDetailFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $projName = if ($State.SelectedProject) { $State.SelectedProject } else { "Unknown Project" }
    $f.Add((New-WorkCtlHeaderLine @("PROJECT DETAIL", $projName) -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    if (!(Get-Command Get-WorkCtlProjects -ErrorAction SilentlyContinue)) {
        if (Get-Command Import-WorkCtlSubsystem -ErrorAction SilentlyContinue) {
            Import-WorkCtlSubsystem "development"
        }
    }

    $projects = @(Get-WorkCtlProjects)
    $p = $projects | Where-Object { $_.Name -ieq $projName } | Select-Object -First 1

    if ($p) {
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Directory Path:  " DarkGray), (New-UiSegment $p.Path White)
        )))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Primary Stack:   " DarkGray), (New-UiSegment $p.PrimaryType Yellow),
            (New-UiSegment "   Detected: " DarkGray), (New-UiSegment ($p.Types -join ", ") DarkGray)
        )))
        $branchStr = if ($p.Branch) { $p.Branch } else { "none" }
        $gitText = if ($p.Git) { "YES" } else { "NO" }
        $gitCol = if ($p.Git) { [ConsoleColor]::Green } else { [ConsoleColor]::DarkGray }
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Git Repository:  " DarkGray), (New-UiSegment $gitText $gitCol),
            (New-UiSegment "   Branch: " DarkGray), (New-UiSegment $branchStr Green)
        )))

        $f.Add((New-UiLine @((New-UiSegment ""))))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "DIRECTORY CONTENTS (TOP ITEMS):" Cyan)
        )))

        try {
            $items = @(Get-ChildItem -LiteralPath $p.Path -ErrorAction SilentlyContinue | Select-Object -First 8)
            foreach ($it in $items) {
                $kind = if ($it.PSIsContainer) { "[DIR] " } else { "      " }
                $col = if ($it.PSIsContainer) { [ConsoleColor]::Yellow } else { [ConsoleColor]::White }
                $szStr = if (!$it.PSIsContainer) { ("{0,8:N0} B" -f $it.Length) } else { "        " }
                $f.Add((New-UiLine @(
                    (New-UiSegment $margin DarkGray),
                    (New-UiSegment ("  {0} " -f $kind) $col),
                    (New-UiSegment ("{0,-35}" -f $it.Name) $col),
                    (New-UiSegment $szStr DarkGray),
                    (New-UiSegment ("  {0:yyyy-MM-dd HH:mm}" -f $it.LastWriteTime) DarkGray)
                )))
            }
        } catch {}
    } else {
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Project not found or no longer available." Yellow)
        )))
    }

    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "ESC / B"; Label = "Back" },
            @{ Key = "F";       Label = "Launch Freebuff" },
            @{ Key = "C";       Label = "VS Code" },
            @{ Key = "E";       Label = "Explorer" },
            @{ Key = "D";       Label = "Set WorkCtl Dir" }
        ) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellAgentsFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    $f.Add((New-WorkCtlHeaderLine @("DEVELOPMENT", "AI CODING AGENTS & RUNTIMES") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    if (!(Get-Command Get-WorkCtlAiAgents -ErrorAction SilentlyContinue)) {
        if (Get-Command Import-WorkCtlSubsystem -ErrorAction SilentlyContinue) {
            Import-WorkCtlSubsystem "development"
        }
    }

    if (!$State.DevelopmentState) {
        $State.DevelopmentState = Initialize-WorkCtlDevState
    }

    $agents = @(Get-WorkCtlAiAgents)
    $runtimes = @(Get-WorkCtlRuntimes)

    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  AGENT ID       NAME                       TYPE                 POLICY       STATUS" DarkGray)
    )))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    for ($i = 0; $i -lt $agents.Count; $i++) {
        $a = $agents[$i]
        $isSel = ($i -eq $State.DevelopmentState.SelectedAgentIndex)
        $cursor = if ($isSel) { "> " } else { "  " }
        $nameCol = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::White }

        $stText = if ($a.Installed) { "READY" } else { "MISSING" }
        $stCol = if ($a.Installed) { [ConsoleColor]::Green } else { [ConsoleColor]::DarkGray }
        $polCol = if ($a.Policy -eq "PROTECTED") { [ConsoleColor]::Red } else { [ConsoleColor]::Yellow }

        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment $cursor Cyan),
            (New-UiSegment ("{0,-15}" -f $a.Id) $nameCol),
            (New-UiSegment ("{0,-27}" -f $a.Name) White),
            (New-UiSegment ("{0,-21}" -f $a.Type) Yellow),
            (New-UiSegment ("{0,-13}" -f $a.Policy) $polCol),
            (New-UiSegment $stText $stCol)
        )))
    }

    # Selected Agent Preview Card (clean presentation, no fake ASCII borders)
    [int]$remainingRows = [int]($canvas.FooterSepRow - $f.Count)
    if ($remainingRows -ge 5 -and $agents.Count -gt 0 -and $State.DevelopmentState.SelectedAgentIndex -lt $agents.Count) {
        $selAgent = $agents[$State.DevelopmentState.SelectedAgentIndex]

        $f.Add((New-UiLine @((New-UiSegment ""))))
        $f.Add((New-WorkCtlSeparatorLine -Width $width))

        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "DETAILS: " Cyan),
            (New-UiSegment $selAgent.Name White),
            (New-UiSegment "  (Version: " DarkGray),
            (New-UiSegment $selAgent.Version Yellow),
            (New-UiSegment ")" DarkGray)
        )))

        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "Runtime: " DarkGray), (New-UiSegment $selAgent.Runtime DarkGray),
            (New-UiSegment "   Policy: " DarkGray), (New-UiSegment $selAgent.Policy Cyan)
        )))

        $caps = if ($selAgent.Capabilities) { $selAgent.Capabilities -join ", " } else { "-" }
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "Caps: " DarkGray), (New-UiSegment $caps DarkGray)
        )))

        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "Notice: " DarkGray), (New-UiSegment $selAgent.PrivacyNotice DarkGray)
        )))
    }

    $f.Add((New-UiLine @((New-UiSegment ""))))
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "DEVELOPER RUNTIMES:" Cyan)
    )))
    foreach ($rt in $runtimes) {
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment ("  {0,-12}" -f $rt.Name) Cyan),
            (New-UiSegment ("{0,-16}" -f $rt.Version) Green),
            (New-UiSegment ("{0,-20}" -f $rt.Category) DarkGray),
            (New-UiSegment $rt.Path DarkGray)
        )))
    }

    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "ESC / B"; Label = "Back" },
            @{ Key = "F";       Label = "Freebuff" },
            @{ Key = "C";       Label = "VS Code" },
            @{ Key = "R";       Label = "Refresh" }
        ) `
        -Width $width
    ))

    $f.ToArray()
}

function New-ShellErrorFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    [int]$width = [int](Get-WorkCtlWindowWidth)
    [int]$height = [int](Get-WorkCtlWindowHeight)
    $canvas = Get-WorkCtlCanvas -Width $width -Height $height
    $margin = $canvas.Margin

    # Header Chrome
    $f.Add((New-WorkCtlHeaderLine @("SYSTEM ERROR RECOVERY") -Width $width))
    $f.Add((New-WorkCtlSeparatorLine -Width $width))

    $err = $State.LastError
    $errMsg = if ($err -and $err.Exception -and $err.Exception.Message) { $err.Exception.Message } else { "An unexpected error occurred." }
    $errPos = if ($err -and $err.InvocationInfo -and $err.InvocationInfo.PositionMessage) { $err.InvocationInfo.PositionMessage } else { "" }
    $errScript = if ($err -and $err.InvocationInfo -and $err.InvocationInfo.ScriptName) { $err.InvocationInfo.ScriptName } else { "" }
    $errLine = if ($err -and $err.InvocationInfo -and $err.InvocationInfo.ScriptLineNumber) { $err.InvocationInfo.ScriptLineNumber } else { "" }

    $failingScreen = if ($State.FailingScreen) { $State.FailingScreen } elseif ($State.PreviousScreen -and $State.PreviousScreen -ne "shell-error") { $State.PreviousScreen } else { "shell-home" }

    $subsystem = switch -Wildcard ($failingScreen) {
        "shell-tools*"     { "Tools" }
        "shell-workload*"  { "Workloads" }
        "shell-power*"     { "PowerToys" }
        "shell-media*"     { "Media" }
        "shell-process*"   { "Processes" }
        "shell-network*"   { "Network" }
        "shell-diag*"      { "Diagnostics" }
        "shell-guide*"     { "Guide" }
        "shell-dev*"       { "Development" }
        "shell-project*"   { "Development" }
        "shell-agent*"     { "Development" }
        "shell-command*"   { "Command Shell" }
        default            { "Core Shell" }
    }
    $lastAction = if ($State.LastAction -and $State.LastAction -ne "None") { $State.LastAction } else { "Interactive Navigation" }
    $errorId = if ($State.LastErrorId) { $State.LastErrorId } elseif ($err -and $err.Exception) {
        $errHash = [math]::Abs($err.Exception.Message.GetHashCode() % 1000).ToString("D3")
        "WCTL-UI-STATE-$errHash"
    } else { "WCTL-UI-STATE-001" }

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # Alert banner: calm, restrained
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  ! " Yellow),
        (New-UiSegment "WorkCtl recovered from an internal UI error." White)
    )))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # Context table (aligned with tokens)
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  Subsystem:   " DarkGray), (New-UiSegment ("{0,-24}" -f $subsystem) White),
        (New-UiSegment "Screen:      " DarkGray), (New-UiSegment $failingScreen Cyan)
    )))
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  Action:      " DarkGray), (New-UiSegment ("{0,-24}" -f $lastAction) White),
        (New-UiSegment "Error ID:    " DarkGray), (New-UiSegment $errorId Yellow)
    )))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # Clean error summary
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  Summary:     " DarkGray),
        (New-UiSegment $errMsg Yellow)
    )))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # Workloads reassurance (Green)
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  [OK] " Green),
        (New-UiSegment "Your managed workloads and background services are still running." Green)
    )))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # Technical details section (toggled by 'D')
    if ($State.ShowErrorDetails) {
        $f.Add((New-WorkCtlSeparatorLine -Width $width))
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  TECHNICAL DIAGNOSTICS & STACK TRACE" Cyan)
        )))
        if ($errScript) {
            $f.Add((New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment "  Location: " DarkGray),
                (New-UiSegment "$errScript : line $errLine" DarkGray)
            )))
        }
        if ($errPos) {
            $posLines = @($errPos -split "`r?`n")
            foreach ($pl in $posLines) {
                if ($pl) {
                    $f.Add((New-UiLine @(
                        (New-UiSegment $margin DarkGray),
                        (New-UiSegment ("    " + $pl) Red)
                    )))
                }
            }
        }
        if ($err -and $err.ScriptStackTrace) {
            $stLines = @($err.ScriptStackTrace -split "`r?`n")
            foreach ($stl in $stLines) {
                if ($stl) {
                    $f.Add((New-UiLine @(
                        (New-UiSegment $margin DarkGray),
                        (New-UiSegment ("    " + $stl) DarkGray)
                    )))
                }
            }
        }
    } else {
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Press [D] to view technical diagnostics & stack trace." DarkGray)
        )))
    }

    for ($pad = $f.Count; $pad -lt $canvas.FooterSepRow; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine -Width $width))
    $f.Add((New-WorkCtlFooterLine `
        -Items @(
            @{ Key = "ENTER / ESC"; Label = "Return Home" },
            @{ Key = "D";           Label = if ($State.ShowErrorDetails) { "Hide Details" } else { "Details" } },
            @{ Key = "R";           Label = "Redraw" },
            @{ Key = "Q";           Label = "Exit" }
        ) `
        -RightText "Status: RECOVERED" `
        -Width $width
    ))

    $f.ToArray()
}

# =================================================================
# 7. CANONICAL INPUT-FIRST SHELL EVENT LOOP
# =================================================================

function Watch-WorkCtlShell {
    param(
        [string]$InitialScreen = "shell-home",
        [switch]$TestMode,
        [object[]]$SyntheticKeys = @()
    )

    # Initialize resource engine
    if (Get-Command Initialize-WorkCtlResources -ErrorAction SilentlyContinue) {
        Initialize-WorkCtlResources
    }

    $state = Initialize-ShellAppState -InitialScreen $InitialScreen
    $state = Confirm-WorkCtlShellState $state

    # Start reference-counted shared background telemetry worker
    $telemetryWorker = Start-WorkCtlTelemetryWorker -IntervalMs $state.ResIntervalMs

    Start-WorkCtlUI

    # Flush stray keystrokes from PowerShell launch
    try {
        while ([Console]::KeyAvailable) {
            $null = [Console]::ReadKey($true)
        }
    } catch {}

    $keyQueue = New-Object System.Collections.Generic.Queue[object]
    if ($SyntheticKeys -and $SyntheticKeys.Count -gt 0) {
        foreach ($k in $SyntheticKeys) {
            $keyQueue.Enqueue($k)
        }
    }

    $isProfilingUI = ($env:WORKCTL_PROFILE_UI -eq "1" -or $script:WorkCtlProfileUI -eq $true)
    if ($isProfilingUI) {
        $script:WorkCtlUiProfileStats = [ordered]@{
            InputEvents     = 0
            LogicalMoves    = 0
            FastPathHits    = 0
            FastPathMisses  = 0
            FullFrameBuilds = 0
            Paints          = 0
            RowsWritten     = 0
            Latencies       = New-Object System.Collections.Generic.List[double]
        }
    }

    try {
        while ($state.Running) {
            try {
                # 1. Update live telemetry from shared background worker (decoupled from frame cache)
                if ($telemetryWorker -and $telemetryWorker.Sync -and $telemetryWorker.Sync.Snapshot) {
                    if ($telemetryWorker.Sync.LastUpdated -gt $state.LastResRefresh) {
                        $state.CachedResSnapshot = $telemetryWorker.Sync.Snapshot
                        $state.LastResRefresh = $telemetryWorker.Sync.LastUpdated
                        if ($state.Screen -eq "shell-home") {
                            $newTel = New-ShellTelemetryLine $state
                            $cachedF = Get-WorkCtlCachedFrame "shell-home"
                            if ($cachedF -and $cachedF.Count -gt 2) {
                                $cachedF[2] = $newTel
                            }
                            if ($script:UiActive) {
                                Write-UiLineAt -Row 2 -Line $newTel
                            }
                            if ($script:UiPreviousFrame -and $script:UiPreviousFrame.Count -gt 2) {
                                $script:UiPreviousFrame[2] = $newTel
                            }
                        } else {
                            $state.Dirty = $true
                        }
                    }
                }

                # 2. Render frame immediately if dirty
                if ($state.Dirty) {
                    $frame = $null
                    if ($script:WorkCtlFastPathEligible) {
                        $prevUpdater = switch ($state.Screen) {
                            "shell-home" {
                                {
                                    param($f, $nIdx)
                                    [int]$w = [int](Get-WorkCtlWindowWidth)
                                    if ($w -ge 110) {
                                        $pCard = Get-HomePreviewCard $nIdx
                                        for ($r = 0; $r -lt 15; $r++) {
                                            $targetRow = 4 + $r
                                            if ($f.Count -gt $targetRow -and $f[$targetRow].Segments -and $f[$targetRow].Segments.Count -ge 5) {
                                                $cloned = Clone-UiLine $f[$targetRow]
                                                $pTxt = if ($pCard -and $r -lt $pCard.Count) { $pCard[$r] } else { "" }
                                                $pCol = if ($r -eq 0) { [ConsoleColor]::White }
                                                        elseif ($r -eq 1) { [ConsoleColor]::DarkGray }
                                                        elseif ($pTxt -match "^\[Enter\]") { [ConsoleColor]::Cyan }
                                                        elseif ($r % 2 -eq 0) { [ConsoleColor]::DarkGray }
                                                        else { [ConsoleColor]::White }
                                                $lastSegIdx = $cloned.Segments.Count - 1
                                                $cloned.Segments[$lastSegIdx].Text = ("{0,-50}" -f $pTxt)
                                                $cloned.Segments[$lastSegIdx].Foreground = $pCol
                                                $f[$targetRow] = $cloned
                                                if ($script:UiActive) {
                                                    Write-UiLineAt -Row $targetRow -Line $cloned
                                                }
                                                if ($script:UiPreviousFrame -and $script:UiPreviousFrame.Count -gt $targetRow) {
                                                    $script:UiPreviousFrame[$targetRow] = $cloned
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            "shell-tools-list" {
                                {
                                    param($f, $nIdx)
                                    $tSnap = Get-WorkCtlToolsSnapshot
                                    if ($tSnap -and $tSnap.Data -and $tSnap.Data.Tools -and $nIdx -lt $tSnap.Data.Tools.Count) {
                                        $sel = $tSnap.Data.Tools[$nIdx]
                                        if ($f.Count -gt 16 -and $f[16].Segments.Count -ge 6) {
                                            $f[16].Segments[3].Text = $sel.Label
                                            $f[16].Segments[5].Text = $sel.Id
                                        }
                                    }
                                }
                            }
                            default { $null }
                        }
                        $frame = Update-WorkCtlSelectionFast `
                            -Screen $state.Screen `
                            -OldIndex $script:WorkCtlFastPathOldIndex `
                            -NewIndex $script:WorkCtlFastPathNewIndex `
                            -OldScrollOffset $script:WorkCtlFastPathOldScroll `
                            -NewScrollOffset $script:WorkCtlFastPathNewScroll `
                            -PreviewUpdater $prevUpdater

                        if ($frame -and $isProfilingUI -and $script:WorkCtlUiProfileStats) {
                            $script:WorkCtlUiProfileStats.FastPathHits++
                            $script:WorkCtlUiProfileStats.Paints++
                            $script:WorkCtlUiProfileStats.RowsWritten += 2
                        }
                    }

                    if (!$frame) {
                        if ($isProfilingUI -and $script:WorkCtlUiProfileStats) {
                            if ($script:WorkCtlFastPathEligible) {
                                $script:WorkCtlUiProfileStats.FastPathMisses++
                            }
                            $script:WorkCtlUiProfileStats.FullFrameBuilds++
                            $script:WorkCtlUiProfileStats.Paints++
                        }
                        $frame = switch ($state.Screen) {
                            "shell-home"            { New-ShellHomeFrame $state }
                            "shell-workloads-list"  { New-ShellWorkloadListFrame $state }
                            "shell-workload-detail" { New-ShellWorkloadDetailFrame $state }
                            "shell-tools-list"      { New-ShellToolsListFrame $state }
                            "shell-storage"         { New-ShellStorageFrame $state }
                            "shell-hardware"        { New-ShellHardwareFrame $state }
                            "shell-services"        { New-ShellServicesFrame $state }
                            "shell-processes"       { New-ShellProcessesFrame $state }
                            "shell-network"         { New-ShellNetworkFrame $state }
                            "shell-network-ports"   { New-ShellNetworkPortsFrame $state }
                            "shell-diagnostics"     { New-ShellDiagnosticsFrame $state }
                            "shell-search"          { New-ShellSearchFrame $state }
                            "shell-help"            { New-ShellHelpFrame $state }
                            "shell-guide"           { New-GuideFrame $state }
                            "shell-dev-menu"        { New-ShellDevMenuFrame $state }
                            "shell-projects"        { New-ShellProjectsFrame $state }
                            "shell-project-detail"  { New-ShellProjectDetailFrame $state }
                            "shell-agents"          { New-ShellAgentsFrame $state }
                            "shell-command-output"  { New-ShellCommandOutputFrame $state }
                            "shell-error"           { New-ShellErrorFrame $state }
                            "shell-confirm" {
                                if ($state.ConfirmState) {
                                    New-WorkCtlConfirmDialogFrame `
                                        -Title $state.ConfirmState.Title `
                                        -MessageLines $state.ConfirmState.MessageLines `
                                        -Policy $state.ConfirmState.Policy
                                } else {
                                    New-ShellHomeFrame $state
                                }
                            }
                            default                 { New-ShellHomeFrame $state }
                        }
                        Set-WorkCtlCachedFrame $state.Screen $frame
                        Write-WorkCtlDiffFrame -Frame $frame
                    }

                    $state.Dirty = $false
                    $script:WorkCtlFastPathEligible = $false
                }

                if ($TestMode -and $keyQueue.Count -eq 0) {
                    break
                }

                # 3. Non-blocking input poll (20ms cadence)
                $key = $null
                if ($keyQueue.Count -gt 0) {
                    $key = $keyQueue.Dequeue()
                } else {
                    $key = Read-WorkCtlKey -TimeoutMs 20
                }

                if ($key -ne $null) {
                    $keySw = if ($isProfilingUI) { [System.Diagnostics.Stopwatch]::StartNew() } else { $null }
                    $state.LastAction = $key.Key.ToString()

                    # --- CONFIRMATION MODAL HANDLING ---
                    if ($state.Screen -eq "shell-confirm") {
                        if ($key.Key -eq [ConsoleKey]::Y -and $state.ConfirmState.Policy -ieq "CONFIRM") {
                            # User confirmed!
                            if ($state.ConfirmState.Action -eq "stop") {
                                try {
                                    Stop-Workload $state.ConfirmState.WorkloadName
                                    Set-ShellNotification $state "Stopped: $($state.ConfirmState.WorkloadName)" [ConsoleColor]::Green
                                } catch {
                                    Set-ShellNotification $state "Stop failed: $($_.Exception.Message)" [ConsoleColor]::Red
                                }
                            }
                            $state.Screen = if ($state.ConfirmState.ReturnScreen) { $state.ConfirmState.ReturnScreen } else { "shell-home" }
                            $state.ConfirmState = $null
                            $state.Dirty = $true
                            continue
                        } else {
                            # Cancelled (N, Esc, or any other key for explicit protection notice)
                            Set-ShellNotification $state "Action cancelled." [ConsoleColor]::Yellow
                            $state.Screen = if ($state.ConfirmState.ReturnScreen) { $state.ConfirmState.ReturnScreen } else { "shell-home" }
                            $state.ConfirmState = $null
                            $state.Dirty = $true
                            continue
                        }
                    }

                    # --- MODE B: COMMAND SHELL PROMPT (Triggered by ':') ---
                    if ($key.KeyChar -eq ":") {
                        $prompt = "workctl:$($state.Context) > "
                        $hist = Get-ShellHistoryList
                        $res = Read-WorkCtlCommandLine `
                            -PromptText $prompt `
                            -History $hist `
                            -CompletionHook { param($in) Get-ShellCompletionCandidates $in $state.Context } `
                            -SuggestionHook { param($in) Get-ShellGhostSuggestion $in $state.Context }

                        if (!$res.Cancelled -and $res.Command) {
                            Invoke-ShellCommand $state $res.Command
                        }
                        $state.Dirty = $true
                        continue
                    }

                    # --- GLOBAL SEARCH (Triggered by '/') ---
                    if ($key.KeyChar -eq "/" -and $state.Screen -ne "shell-search" -and $state.Screen -ne "shell-guide") {
                        $res = Read-WorkCtlSearchInput -CurrentQuery $state.SearchQuery
                        if (!$res.Cancelled -and $res.Query) {
                            $state.SearchQuery = $res.Query
                            $state.SelectedSearchIndex = 0
                            $state.SearchScroll = 0
                            $state.PreSearchScreen = $state.Screen
                            $state.Screen = "shell-search"
                        }
                        $state.Dirty = $true
                        continue
                    }

                    # --- WORKCTL GUIDE INTERACTION ---
                    if ($state.Screen -eq "shell-guide") {
                        Handle-WorkCtlGuideKey $state $key
                        continue
                    }

                    # Key coalescing for fast repeats (BTOP / Torlink responsiveness)
                    $stepCount = 1
                    if ($key.Key -in @([ConsoleKey]::UpArrow, [ConsoleKey]::DownArrow, [ConsoleKey]::PageUp, [ConsoleKey]::PageDown)) {
                        while ($keyQueue.Count -gt 0 -and $keyQueue.Peek().Key -eq $key.Key) {
                            $null = $keyQueue.Dequeue()
                            $stepCount++
                        }
                        if ($keyQueue.Count -eq 0) {
                            try {
                                while ([Console]::KeyAvailable) {
                                    $peekK = [Console]::ReadKey($true)
                                    if ($peekK.Key -eq $key.Key) {
                                        $stepCount++
                                    } else {
                                        $keyQueue.Enqueue($peekK)
                                        break
                                    }
                                }
                            } catch {}
                        }
                        if ($isProfilingUI -and $script:WorkCtlUiProfileStats) {
                            $script:WorkCtlUiProfileStats.InputEvents += $stepCount
                            $script:WorkCtlUiProfileStats.LogicalMoves += $stepCount
                        }
                    }

                    # --- STANDARD KEY NAVIGATION ---
                    $fpOldIdx = switch ($state.Screen) {
                        "shell-home"           { $state.SelectedHomeItem }
                        "shell-storage"        { $state.SelectedStorageIndex }
                        "shell-services"       { $state.SelectedServiceIndex }
                        "shell-network-ports"  { $state.SelectedPortIndex }
                        "shell-workloads-list" { $state.SelectedWorkloadIndex }
                        "shell-tools-list"     { $state.SelectedToolIndex }
                        "shell-processes"      { $state.SelectedProcessIndex }
                        "shell-projects"       { $state.SelectedProjectIndex }
                        "shell-dev-menu"       { if ($state.DevelopmentState) { $state.DevelopmentState.SelectedMenuIndex } else { 0 } }
                        "shell-search"         { $state.SelectedSearchIndex }
                        default                { -1 }
                    }
                    $fpOldScroll = switch ($state.Screen) {
                        "shell-tools-list"     { $state.ToolScroll }
                        "shell-services"       { $state.ServiceScroll }
                        "shell-network-ports"  { $state.PortScroll }
                        default                { 0 }
                    }

                    switch ($key.Key) {
                        "UpArrow" {
                            switch ($state.Screen) {
                                "shell-home" {
                                    $state.SelectedHomeItem = Step-WorkCtlListSelection $state.SelectedHomeItem 12 "Up" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-storage" {
                                    $sSnap = Get-WorkCtlStorageSnapshot
                                    $cnt = if ($sSnap.Data) { $sSnap.Data.LocalVolumes.Count + $sSnap.Data.OtherMounts.Count } else { 0 }
                                    $state.SelectedStorageIndex = Step-WorkCtlListSelection $state.SelectedStorageIndex $cnt "Up" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-services" {
                                    $sSnap = Get-WorkCtlServicesSnapshot
                                    $cat = if ($state.SelectedCategory) { $state.SelectedCategory.ToUpperInvariant() } else { "WORKSTATION" }
                                    $cnt = 0
                                    if ($sSnap.Data -and $sSnap.Data.Services) {
                                        $cnt = switch ($cat) {
                                            "RUNNING"     { @($sSnap.Data.Services | Where-Object { $_.Status -eq "Running" }).Count }
                                            "STOPPED"     { @($sSnap.Data.Services | Where-Object { $_.Status -eq "Stopped" }).Count }
                                            "WORKSTATION" { @($sSnap.Data.Services | Where-Object { $_.Name -match "mysql|docker|wsl|hyper|intel|hp|omen|audio|antigravity|defender|ssh|sonarr|torrent|lanman|wuauserv|bth|spooler" -or $_.DisplayName -match "mysql|docker|wsl|hyper|intel|hp|omen|audio|antigravity|defender|ssh|sonarr|torrent" }).Count }
                                            default       { $sSnap.Data.Services.Count }
                                        }
                                    }
                                    $state.SelectedServiceIndex = Step-WorkCtlListSelection $state.SelectedServiceIndex $cnt "Up" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-workloads-list" {
                                    $wReg = Get-ShellCachedWorkloads
                                    $cnt = if ($wReg -and $wReg.components) { Get-WorkCtlCount $wReg.components.PSObject.Properties } else { 0 }
                                    $state.SelectedWorkloadIndex = Step-WorkCtlListSelection $state.SelectedWorkloadIndex $cnt "Up" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-tools-list" {
                                    $tSnap = Get-WorkCtlToolsSnapshot
                                    $cnt = if ($tSnap.Data -and $tSnap.Data.Tools) { $tSnap.Data.Tools.Count } else { 0 }
                                    $state.SelectedToolIndex = Step-WorkCtlListSelection $state.SelectedToolIndex $cnt "Up" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-processes" {
                                    $procs = @(Get-ShellProcessesCached)
                                    $state.SelectedProcessIndex = Step-WorkCtlListSelection $state.SelectedProcessIndex (Get-WorkCtlCount $procs) "Up" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-network-ports" {
                                    $ports = @(Get-ShellNetworkPortsCached -Filter $state.PortFilter)
                                    $state.SelectedPortIndex = Step-WorkCtlListSelection $state.SelectedPortIndex (Get-WorkCtlCount $ports) "Up" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-search" {
                                    $index = Get-ShellEntityIndex
                                    $q = $state.SearchQuery
                                    $matches = @($index | Where-Object { $_.Key -like "*$q*" -or $_.Label -like "*$q*" })
                                    $state.SelectedSearchIndex = Step-WorkCtlListSelection $state.SelectedSearchIndex (Get-WorkCtlCount $matches) "Up" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-command-output" {
                                    if ($state.CommandOutput -and $state.CommandOutput.Scroll -gt 0) {
                                        $state.CommandOutput.Scroll = [math]::Max(0, $state.CommandOutput.Scroll - $stepCount)
                                        $state.Dirty = $true
                                    }
                                }
                                "shell-guide" {
                                    if (Get-Command Step-GuideSelection -ErrorAction SilentlyContinue) {
                                        Step-GuideSelection $state "Up"
                                    }
                                }
                                "shell-dev-menu" {
                                    if (!$state.DevelopmentState) { $state.DevelopmentState = Initialize-WorkCtlDevState }
                                    $state.DevelopmentState.SelectedMenuIndex = Step-WorkCtlListSelection $state.DevelopmentState.SelectedMenuIndex 5 "Up" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-projects" {
                                    $projs = @(Get-WorkCtlProjects)
                                    $state.SelectedProjectIndex = Step-WorkCtlListSelection $state.SelectedProjectIndex (Get-WorkCtlCount $projs) "Up" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-agents" {
                                    if (!$state.DevelopmentState) { $state.DevelopmentState = Initialize-WorkCtlDevState }
                                    $agents = @(Get-WorkCtlAiAgents)
                                    $state.DevelopmentState.SelectedAgentIndex = Step-WorkCtlListSelection $state.DevelopmentState.SelectedAgentIndex (Get-WorkCtlCount $agents) "Up" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                            }
                        }

                        "DownArrow" {
                            switch ($state.Screen) {
                                "shell-home" {
                                    $state.SelectedHomeItem = Step-WorkCtlListSelection $state.SelectedHomeItem 12 "Down" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-storage" {
                                    $sSnap = Get-WorkCtlStorageSnapshot
                                    $cnt = if ($sSnap.Data) { $sSnap.Data.LocalVolumes.Count + $sSnap.Data.OtherMounts.Count } else { 0 }
                                    $state.SelectedStorageIndex = Step-WorkCtlListSelection $state.SelectedStorageIndex $cnt "Down" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-services" {
                                    $sSnap = Get-WorkCtlServicesSnapshot
                                    $cat = if ($state.SelectedCategory) { $state.SelectedCategory.ToUpperInvariant() } else { "WORKSTATION" }
                                    $cnt = 0
                                    if ($sSnap.Data -and $sSnap.Data.Services) {
                                        $cnt = switch ($cat) {
                                            "RUNNING"     { @($sSnap.Data.Services | Where-Object { $_.Status -eq "Running" }).Count }
                                            "STOPPED"     { @($sSnap.Data.Services | Where-Object { $_.Status -eq "Stopped" }).Count }
                                            "WORKSTATION" { @($sSnap.Data.Services | Where-Object { $_.Name -match "mysql|docker|wsl|hyper|intel|hp|omen|audio|antigravity|defender|ssh|sonarr|torrent|lanman|wuauserv|bth|spooler" -or $_.DisplayName -match "mysql|docker|wsl|hyper|intel|hp|omen|audio|antigravity|defender|ssh|sonarr|torrent" }).Count }
                                            default       { $sSnap.Data.Services.Count }
                                        }
                                    }
                                    $state.SelectedServiceIndex = Step-WorkCtlListSelection $state.SelectedServiceIndex $cnt "Down" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-workloads-list" {
                                    $wReg = Get-ShellCachedWorkloads
                                    $cnt = if ($wReg -and $wReg.components) { Get-WorkCtlCount $wReg.components.PSObject.Properties } else { 0 }
                                    $state.SelectedWorkloadIndex = Step-WorkCtlListSelection $state.SelectedWorkloadIndex $cnt "Down" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-tools-list" {
                                    $tSnap = Get-WorkCtlToolsSnapshot
                                    $cnt = if ($tSnap.Data -and $tSnap.Data.Tools) { $tSnap.Data.Tools.Count } else { 0 }
                                    $state.SelectedToolIndex = Step-WorkCtlListSelection $state.SelectedToolIndex $cnt "Down" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-processes" {
                                    $procs = @(Get-ShellProcessesCached)
                                    $state.SelectedProcessIndex = Step-WorkCtlListSelection $state.SelectedProcessIndex (Get-WorkCtlCount $procs) "Down" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-network-ports" {
                                    $ports = @(Get-ShellNetworkPortsCached -Filter $state.PortFilter)
                                    $state.SelectedPortIndex = Step-WorkCtlListSelection $state.SelectedPortIndex (Get-WorkCtlCount $ports) "Down" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-search" {
                                    $index = Get-ShellEntityIndex
                                    $q = $state.SearchQuery
                                    $matches = @($index | Where-Object { $_.Key -like "*$q*" -or $_.Label -like "*$q*" })
                                    $state.SelectedSearchIndex = Step-WorkCtlListSelection $state.SelectedSearchIndex (Get-WorkCtlCount $matches) "Down" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-command-output" {
                                    if ($state.CommandOutput) {
                                        [int]$total = if ($state.CommandOutput.IsTable) { Get-WorkCtlCount $state.CommandOutput.Rows } else { Get-WorkCtlCount $state.CommandOutput.Lines }
                                        if ($state.CommandOutput.Scroll -lt ($total - 1)) {
                                            $state.CommandOutput.Scroll = [math]::Min($total - 1, $state.CommandOutput.Scroll + $stepCount)
                                            $state.Dirty = $true
                                        }
                                    }
                                }
                                "shell-guide" {
                                    if (Get-Command Step-GuideSelection -ErrorAction SilentlyContinue) {
                                        Step-GuideSelection $state "Down"
                                    }
                                }
                                "shell-dev-menu" {
                                    if (!$state.DevelopmentState) { $state.DevelopmentState = Initialize-WorkCtlDevState }
                                    $state.DevelopmentState.SelectedMenuIndex = Step-WorkCtlListSelection $state.DevelopmentState.SelectedMenuIndex 5 "Down" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-projects" {
                                    $projs = @(Get-WorkCtlProjects)
                                    $state.SelectedProjectIndex = Step-WorkCtlListSelection $state.SelectedProjectIndex (Get-WorkCtlCount $projs) "Down" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-agents" {
                                    if (!$state.DevelopmentState) { $state.DevelopmentState = Initialize-WorkCtlDevState }
                                    $agents = @(Get-WorkCtlAiAgents)
                                    $state.DevelopmentState.SelectedAgentIndex = Step-WorkCtlListSelection $state.DevelopmentState.SelectedAgentIndex (Get-WorkCtlCount $agents) "Down" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                            }
                        }

                        "PageUp" {
                            switch ($state.Screen) {
                                "shell-command-output" {
                                    if ($state.CommandOutput) {
                                        [int]$h = [int](Get-WorkCtlWindowHeight)
                                        [int]$budget = [math]::Max(5, [int]($h - 8))
                                        $state.CommandOutput.Scroll = [math]::Max(0, [int]($state.CommandOutput.Scroll - $budget))
                                        $state.Dirty = $true
                                    }
                                }
                                "shell-storage" {
                                    $sSnap = Get-WorkCtlStorageSnapshot
                                    $cnt = if ($sSnap.Data) { $sSnap.Data.LocalVolumes.Count + $sSnap.Data.OtherMounts.Count } else { 0 }
                                    $state.SelectedStorageIndex = Step-WorkCtlListSelection $state.SelectedStorageIndex $cnt "PageUp" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-services" {
                                    $sSnap = Get-WorkCtlServicesSnapshot
                                    $cnt = if ($sSnap.Data -and $sSnap.Data.Services) { $sSnap.Data.Services.Count } else { 0 }
                                    $state.SelectedServiceIndex = Step-WorkCtlListSelection $state.SelectedServiceIndex $cnt "PageUp" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-workloads-list" {
                                    $wReg = Get-ShellCachedWorkloads
                                    $cnt = if ($wReg -and $wReg.components) { Get-WorkCtlCount $wReg.components.PSObject.Properties } else { 0 }
                                    $state.SelectedWorkloadIndex = Step-WorkCtlListSelection $state.SelectedWorkloadIndex $cnt "PageUp" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-tools-list" {
                                    $tSnap = Get-WorkCtlToolsSnapshot
                                    $cnt = if ($tSnap.Data -and $tSnap.Data.Tools) { $tSnap.Data.Tools.Count } else { 0 }
                                    $state.SelectedToolIndex = Step-WorkCtlListSelection $state.SelectedToolIndex $cnt "PageUp" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-processes" {
                                    $procs = @(Get-ShellProcessesCached)
                                    $state.SelectedProcessIndex = Step-WorkCtlListSelection $state.SelectedProcessIndex (Get-WorkCtlCount $procs) "PageUp" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-network-ports" {
                                    $ports = @(Get-ShellNetworkPortsCached -Filter $state.PortFilter)
                                    $state.SelectedPortIndex = Step-WorkCtlListSelection $state.SelectedPortIndex (Get-WorkCtlCount $ports) "PageUp" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-guide" {
                                    if (Get-Command Step-GuideSelection -ErrorAction SilentlyContinue) {
                                        Step-GuideSelection $state "PageUp"
                                    }
                                }
                                "shell-projects" {
                                    $projs = @(Get-WorkCtlProjects)
                                    $state.SelectedProjectIndex = Step-WorkCtlListSelection $state.SelectedProjectIndex (Get-WorkCtlCount $projs) "PageUp" 5
                                    $state.Dirty = $true
                                }
                            }
                        }

                        "PageDown" {
                            switch ($state.Screen) {
                                "shell-command-output" {
                                    if ($state.CommandOutput) {
                                        [int]$h = [int](Get-WorkCtlWindowHeight)
                                        [int]$budget = [math]::Max(5, [int]($h - 8))
                                        [int]$total = if ($state.CommandOutput.IsTable) { Get-WorkCtlCount $state.CommandOutput.Rows } else { Get-WorkCtlCount $state.CommandOutput.Lines }
                                        $state.CommandOutput.Scroll = [math]::Min([math]::Max(0, [int]($total - 1)), [int]($state.CommandOutput.Scroll + $budget))
                                        $state.Dirty = $true
                                    }
                                }
                                "shell-storage" {
                                    $sSnap = Get-WorkCtlStorageSnapshot
                                    $cnt = if ($sSnap.Data) { $sSnap.Data.LocalVolumes.Count + $sSnap.Data.OtherMounts.Count } else { 0 }
                                    $state.SelectedStorageIndex = Step-WorkCtlListSelection $state.SelectedStorageIndex $cnt "PageDown" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-services" {
                                    $sSnap = Get-WorkCtlServicesSnapshot
                                    $cnt = if ($sSnap.Data -and $sSnap.Data.Services) { $sSnap.Data.Services.Count } else { 0 }
                                    $state.SelectedServiceIndex = Step-WorkCtlListSelection $state.SelectedServiceIndex $cnt "PageDown" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-workloads-list" {
                                    $wReg = Get-ShellCachedWorkloads
                                    $cnt = if ($wReg -and $wReg.components) { Get-WorkCtlCount $wReg.components.PSObject.Properties } else { 0 }
                                    $state.SelectedWorkloadIndex = Step-WorkCtlListSelection $state.SelectedWorkloadIndex $cnt "PageDown" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-tools-list" {
                                    $tSnap = Get-WorkCtlToolsSnapshot
                                    $cnt = if ($tSnap.Data -and $tSnap.Data.Tools) { $tSnap.Data.Tools.Count } else { 0 }
                                    $state.SelectedToolIndex = Step-WorkCtlListSelection $state.SelectedToolIndex $cnt "PageDown" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-processes" {
                                    $procs = @(Get-ShellProcessesCached)
                                    $state.SelectedProcessIndex = Step-WorkCtlListSelection $state.SelectedProcessIndex (Get-WorkCtlCount $procs) "PageDown" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-network-ports" {
                                    $ports = @(Get-ShellNetworkPortsCached -Filter $state.PortFilter)
                                    $state.SelectedPortIndex = Step-WorkCtlListSelection $state.SelectedPortIndex (Get-WorkCtlCount $ports) "PageDown" -StepBy $stepCount
                                    $state.Dirty = $true
                                }
                                "shell-guide" {
                                    if (Get-Command Step-GuideSelection -ErrorAction SilentlyContinue) {
                                        Step-GuideSelection $state "PageDown"
                                    }
                                }
                                "shell-projects" {
                                    $projs = @(Get-WorkCtlProjects)
                                    $state.SelectedProjectIndex = Step-WorkCtlListSelection $state.SelectedProjectIndex (Get-WorkCtlCount $projs) "PageDown" 5
                                    $state.Dirty = $true
                                }
                            }
                        }

                        "Home" {
                            switch ($state.Screen) {
                                "shell-command-output" {
                                    if ($state.CommandOutput) {
                                        $state.CommandOutput.Scroll = 0
                                        $state.Dirty = $true
                                    }
                                }
                                "shell-storage" {
                                    $state.SelectedStorageIndex = 0
                                    $state.Dirty = $true
                                }
                                "shell-services" {
                                    $state.SelectedServiceIndex = 0
                                    $state.Dirty = $true
                                }
                                "shell-workloads-list" {
                                    $wReg = Get-ShellCachedWorkloads
                                    $cnt = if ($wReg -and $wReg.components) { Get-WorkCtlCount $wReg.components.PSObject.Properties } else { 0 }
                                    $state.SelectedWorkloadIndex = Step-WorkCtlListSelection $state.SelectedWorkloadIndex $cnt "Home"
                                    $state.Dirty = $true
                                }
                                "shell-tools-list" {
                                    $state.SelectedToolIndex = 0
                                    $state.Dirty = $true
                                }
                                "shell-processes" {
                                    $procs = @(Get-ShellProcessesCached)
                                    $state.SelectedProcessIndex = Step-WorkCtlListSelection $state.SelectedProcessIndex (Get-WorkCtlCount $procs) "Home"
                                    $state.Dirty = $true
                                }
                                "shell-network-ports" {
                                    $state.SelectedPortIndex = 0
                                    $state.Dirty = $true
                                }
                                "shell-guide" {
                                    if (Get-Command Step-GuideSelection -ErrorAction SilentlyContinue) {
                                        Step-GuideSelection $state "Home"
                                    }
                                }
                                "shell-dev-menu" {
                                    if (!$state.DevelopmentState) { $state.DevelopmentState = Initialize-WorkCtlDevState }
                                    $state.DevelopmentState.SelectedMenuIndex = 0
                                    $state.Dirty = $true
                                }
                                "shell-projects" {
                                    $state.SelectedProjectIndex = 0
                                    $state.Dirty = $true
                                }
                                "shell-agents" {
                                    if (!$state.DevelopmentState) { $state.DevelopmentState = Initialize-WorkCtlDevState }
                                    $state.DevelopmentState.SelectedAgentIndex = 0
                                    $state.Dirty = $true
                                }
                            }
                        }

                        "End" {
                            switch ($state.Screen) {
                                "shell-command-output" {
                                    if ($state.CommandOutput) {
                                        [int]$total = if ($state.CommandOutput.IsTable) { Get-WorkCtlCount $state.CommandOutput.Rows } else { Get-WorkCtlCount $state.CommandOutput.Lines }
                                        $state.CommandOutput.Scroll = [math]::Max(0, [int]($total - 1))
                                        $state.Dirty = $true
                                    }
                                }
                                "shell-storage" {
                                    $sSnap = Get-WorkCtlStorageSnapshot
                                    $cnt = if ($sSnap.Data) { $sSnap.Data.LocalVolumes.Count + $sSnap.Data.OtherMounts.Count } else { 0 }
                                    $state.SelectedStorageIndex = [math]::Max(0, $cnt - 1)
                                    $state.Dirty = $true
                                }
                                "shell-services" {
                                    $sSnap = Get-WorkCtlServicesSnapshot
                                    $cnt = if ($sSnap.Data -and $sSnap.Data.Services) { $sSnap.Data.Services.Count } else { 0 }
                                    $state.SelectedServiceIndex = [math]::Max(0, $cnt - 1)
                                    $state.Dirty = $true
                                }
                                "shell-workloads-list" {
                                    $wReg = Get-ShellCachedWorkloads
                                    $cnt = if ($wReg -and $wReg.components) { Get-WorkCtlCount $wReg.components.PSObject.Properties } else { 0 }
                                    $state.SelectedWorkloadIndex = Step-WorkCtlListSelection $state.SelectedWorkloadIndex $cnt "End"
                                    $state.Dirty = $true
                                }
                                "shell-tools-list" {
                                    $tSnap = Get-WorkCtlToolsSnapshot
                                    $cnt = if ($tSnap.Data -and $tSnap.Data.Tools) { $tSnap.Data.Tools.Count } else { 0 }
                                    $state.SelectedToolIndex = [math]::Max(0, $cnt - 1)
                                    $state.Dirty = $true
                                }
                                "shell-processes" {
                                    $procs = @(Get-ShellProcessesCached)
                                    $state.SelectedProcessIndex = [math]::Max(0, (Get-WorkCtlCount $procs) - 1)
                                    $state.Dirty = $true
                                }
                                "shell-network-ports" {
                                    $ports = @(Get-ShellNetworkPortsCached -Filter $state.PortFilter)
                                    $state.SelectedPortIndex = [math]::Max(0, (Get-WorkCtlCount $ports) - 1)
                                    $state.Dirty = $true
                                }
                                "shell-guide" {
                                    if (Get-Command Step-GuideSelection -ErrorAction SilentlyContinue) {
                                        Step-GuideSelection $state "End"
                                    }
                                }
                                "shell-dev-menu" {
                                    if (!$state.DevelopmentState) { $state.DevelopmentState = Initialize-WorkCtlDevState }
                                    $state.DevelopmentState.SelectedMenuIndex = 4
                                    $state.Dirty = $true
                                }
                                "shell-projects" {
                                    $projs = @(Get-WorkCtlProjects)
                                    $state.SelectedProjectIndex = [math]::Max(0, $projs.Count - 1)
                                    $state.Dirty = $true
                                }
                                "shell-agents" {
                                    if (!$state.DevelopmentState) { $state.DevelopmentState = Initialize-WorkCtlDevState }
                                    $agents = @(Get-WorkCtlAiAgents)
                                    $state.DevelopmentState.SelectedAgentIndex = [math]::Max(0, $agents.Count - 1)
                                    $state.Dirty = $true
                                }
                            }
                        }

                        "Enter" {
                            switch ($state.Screen) {
                                "shell-command-output" {
                                    $ret = if ($state.CommandOutput -and $state.CommandOutput.ReturnScreen) { $state.CommandOutput.ReturnScreen } else { "shell-home" }
                                    $state.Screen = $ret
                                    $state.Dirty = $true
                                }
                                "shell-error" {
                                    $state.Screen = "shell-home"
                                    $state.LastError = $null
                                    $state.ShowErrorDetails = $false
                                    $state.Dirty = $true
                                }
                                "shell-network" {
                                    Push-WorkCtlScreen $state "shell-network-ports"
                                    $state.Dirty = $true
                                }
                                "shell-home" {
                                    switch ($state.SelectedHomeItem) {
                                        0 { Push-WorkCtlScreen $state "shell-hardware" }
                                        1 { Push-WorkCtlScreen $state "shell-storage" }
                                        2 { Push-WorkCtlScreen $state "shell-network" }
                                        3 { Push-WorkCtlScreen $state "shell-services" }
                                        4 { Push-WorkCtlScreen $state "shell-processes" }
                                        5 { Push-WorkCtlScreen $state "shell-dev-menu" }
                                        6 { Invoke-ShellCommand $state "media" }
                                        7 { Invoke-ShellCommand $state "powertoys" }
                                        8 { Push-WorkCtlScreen $state "shell-tools-list" }
                                        9 { Push-WorkCtlScreen $state "shell-workloads-list" }
                                        10 { Push-WorkCtlScreen $state "shell-guide" }
                                        11 { Push-WorkCtlScreen $state "shell-diagnostics" }
                                    }
                                }
                                "shell-storage" {
                                    $sSnap = Get-WorkCtlStorageSnapshot
                                    $allMounts = New-Object System.Collections.Generic.List[object]
                                    if ($sSnap.Data) {
                                        foreach ($lv in $sSnap.Data.LocalVolumes) { $allMounts.Add($lv) }
                                        foreach ($om in $sSnap.Data.OtherMounts) { $allMounts.Add($om) }
                                    }
                                    if ($state.SelectedStorageIndex -lt $allMounts.Count) {
                                        $selM = $allMounts[$state.SelectedStorageIndex]
                                        $drivePath = "$($selM.DriveLetter):\"
                                        try {
                                            Invoke-Item $drivePath
                                            Set-ShellNotification $state "Opened $drivePath in File Explorer" [ConsoleColor]::Green
                                        } catch {
                                            Set-ShellNotification $state "Failed to open $($drivePath): $($_.Exception.Message)" [ConsoleColor]::Red
                                        }
                                        $state.Dirty = $true
                                    }
                                }
                                "shell-dev-menu" {
                                    $sel = if ($state.DevelopmentState) { $state.DevelopmentState.SelectedMenuIndex } else { 0 }
                                    switch ($sel) {
                                        0 { Invoke-ShellCommand $state "projects" }
                                        1 { Invoke-ShellCommand $state "agents" }
                                        2 { Invoke-ShellCommand $state "freebuff" }
                                        3 {
                                            Start-Process "code" -ArgumentList "E:\Workspace" -ErrorAction SilentlyContinue | Out-Null
                                            Set-ShellNotification $state "Launched VS Code in E:\Workspace" [ConsoleColor]::Green
                                        }
                                        4 {
                                            Get-WorkCtlProjects -ForceRefresh | Out-Null
                                            Set-ShellNotification $state "Project discovery cache refreshed" [ConsoleColor]::Green
                                            $state.Dirty = $true
                                        }
                                    }
                                }
                                "shell-projects" {
                                    $projs = @(Get-WorkCtlProjects)
                                    if ($state.SelectedProjectIndex -lt $projs.Count) {
                                        $state.SelectedProject = $projs[$state.SelectedProjectIndex].Name
                                        $state.PreviousScreen = "shell-projects"
                                        $state.Screen = "shell-project-detail"
                                        $state.Dirty = $true
                                    }
                                }
                                "shell-agents" {
                                    $agents = @(Get-WorkCtlAiAgents)
                                    $selA = if ($state.DevelopmentState) { $state.DevelopmentState.SelectedAgentIndex } else { 0 }
                                    if ($selA -lt $agents.Count) {
                                        $a = $agents[$selA]
                                        if ($a.Id -eq "freebuff") {
                                            Invoke-ShellCommand $state "freebuff"
                                        } elseif ($a.Id -eq "vscode") {
                                            Start-Process "code" -ArgumentList "E:\Workspace" -ErrorAction SilentlyContinue | Out-Null
                                            Set-ShellNotification $state "Launched VS Code" [ConsoleColor]::Green
                                        } else {
                                            Set-ShellNotification $state "$($a.Name) is $($a.Policy)" [ConsoleColor]::Yellow
                                        }
                                    }
                                }
                                "shell-workloads-list" {
                                    $wReg = Get-ShellCachedWorkloads
                                    if ($wReg -and $wReg.components) {
                                        $props = @($wReg.components.PSObject.Properties)
                                        if ($state.SelectedWorkloadIndex -lt $props.Count) {
                                            $state.SelectedWorkload = $props[$state.SelectedWorkloadIndex].Name
                                            $state.PreviousScreen = "shell-workloads-list"
                                            $state.Screen = "shell-workload-detail"
                                            $state.Dirty = $true
                                        }
                                    }
                                }
                                "shell-tools-list" {
                                    $tReg = Get-ShellCachedTools
                                    if ($tReg -and $tReg.tools) {
                                        $props = @($tReg.tools.PSObject.Properties)
                                        if ($state.SelectedToolIndex -lt $props.Count) {
                                            $t = $props[$state.SelectedToolIndex].Value
                                            if ($t.webUrl) {
                                                Start-Process $t.webUrl | Out-Null
                                                Set-ShellNotification $state "Opened $($t.label) web UI" [ConsoleColor]::Green
                                            }
                                        }
                                    }
                                }
                                "shell-search" {
                                    $index = Get-ShellEntityIndex
                                    $q = $state.SearchQuery
                                    $matches = @($index | Where-Object { $_.Key -like "*$q*" -or $_.Label -like "*$q*" })
                                    if ($state.SelectedSearchIndex -lt $matches.Count) {
                                        $m = $matches[$state.SelectedSearchIndex]
                                        Invoke-ShellCommand $state $m.Key
                                    }
                                }
                            }
                        }

                        "Escape" {
                            if ($state.Screen -eq "shell-command-output") {
                                $ret = if ($state.CommandOutput -and $state.CommandOutput.ReturnScreen) { $state.CommandOutput.ReturnScreen } else { "shell-home" }
                                $state.Screen = $ret
                                $state.Dirty = $true
                            } elseif ($state.Screen -eq "shell-error") {
                                $state.Screen = "shell-home"
                                $state.LastError = $null
                                $state.ShowErrorDetails = $false
                                $state.Dirty = $true
                            } elseif ($state.Screen -eq "shell-home") {
                                $state.Running = $false
                            } else {
                                $popped = Pop-WorkCtlScreen $state
                                if (!$popped) {
                                    $state.Screen = if ($state.PreviousScreen) { $state.PreviousScreen } else { "shell-home" }
                                }
                                $state.Dirty = $true
                            }
                        }

                        "B" {
                            if ($state.Screen -eq "shell-home") {
                                Push-WorkCtlScreen $state "shell-storage"
                                $state.Dirty = $true
                            } elseif ($state.Screen -eq "shell-command-output") {
                                $ret = if ($state.CommandOutput -and $state.CommandOutput.ReturnScreen) { $state.CommandOutput.ReturnScreen } else { "shell-home" }
                                $state.Screen = $ret
                                $state.Dirty = $true
                            } elseif ($state.Screen -eq "shell-error") {
                                $state.Screen = "shell-home"
                                $state.LastError = $null
                                $state.ShowErrorDetails = $false
                                $state.Dirty = $true
                            } else {
                                $popped = Pop-WorkCtlScreen $state
                                if (!$popped) {
                                    $state.Screen = if ($state.PreviousScreen) { $state.PreviousScreen } else { "shell-home" }
                                }
                                $state.Dirty = $true
                            }
                        }

                        "H" {
                            if ($state.Screen -eq "shell-home") {
                                Push-WorkCtlScreen $state "shell-hardware"
                                $state.Dirty = $true
                            }
                        }

                        "Tab" {
                            if ($state.Screen -eq "shell-services") {
                                $categories = @("WORKSTATION", "RUNNING", "STOPPED", "ALL")
                                $curCat = if ($state.SelectedCategory) { $state.SelectedCategory.ToUpperInvariant() } else { "WORKSTATION" }
                                $curIdx = [array]::IndexOf($categories, $curCat)
                                $nextIdx = ($curIdx + 1) % $categories.Count
                                $state.SelectedCategory = $categories[$nextIdx]
                                $state.SelectedServiceIndex = 0
                                $state.ServiceScroll = 0
                                $state.Dirty = $true
                            } elseif ($state.Screen -eq "shell-network-ports") {
                                $categories = @("ALL", "LOCALHOST", "LAN", "SYSTEM", "WORKCTL")
                                $curCat = if ($state.PortFilter) { $state.PortFilter.ToUpperInvariant() } else { "ALL" }
                                $curIdx = [array]::IndexOf($categories, $curCat)
                                $nextIdx = ($curIdx + 1) % $categories.Count
                                $state.PortFilter = $categories[$nextIdx]
                                $state.SelectedPortIndex = 0
                                $state.PortScroll = 0
                                $state.Dirty = $true
                            }
                        }

                        "M" {
                            if ($state.Screen -eq "shell-storage") {
                                $mGui = "E:\TOOLS\Mounter\WinCDEmu.exe"
                                if (Test-Path -LiteralPath $mGui) {
                                    Start-Process $mGui -ErrorAction SilentlyContinue | Out-Null
                                    Set-ShellNotification $state "Launched WinCDEmu Mounter GUI" [ConsoleColor]::Green
                                } else {
                                    Set-ShellNotification $state "Mounter GUI not found at $mGui" [ConsoleColor]::Yellow
                                }
                            }
                        }

                        "U" {
                            if ($state.Screen -eq "shell-storage") {
                                $sSnap = Get-WorkCtlStorageSnapshot
                                if ($sSnap.Data -and $sSnap.Data.MountedImages.Count -gt 0) {
                                    $img = $sSnap.Data.MountedImages[0]
                                    try {
                                        Invoke-MounterUnmountDrive $img.DriveLetter
                                        Update-WorkCtlStorageSnapshot -Force
                                        Set-ShellNotification $state "Unmounted virtual drive $($img.DriveLetter)" [ConsoleColor]::Green
                                        $state.Dirty = $true
                                    } catch {
                                        Set-ShellNotification $state "Unmount failed: $($_.Exception.Message)" [ConsoleColor]::Red
                                    }
                                } else {
                                    Set-ShellNotification $state "No virtual drive image currently mounted." [ConsoleColor]::Yellow
                                }
                            }
                        }

                        "Q" {
                            $state.Running = $false
                        }

                        "W" {
                            if ($state.Screen -eq "shell-home") {
                                Push-WorkCtlScreen $state "shell-workloads-list"
                                $state.Dirty = $true
                            } elseif ($state.Screen -eq "shell-tools-list") {
                                try {
                                    $res = Invoke-WinDirStatScan -TargetPath $state.CurrentDirectory
                                    Set-ShellNotification $state "Launched WinDirStat on $($res.Target)" [ConsoleColor]::Green
                                } catch {
                                    Set-ShellNotification $state "WinDirStat failed: $($_.Exception.Message)" [ConsoleColor]::Red
                                }
                                $state.Dirty = $true
                            }
                        }

                        "T" {
                            if ($state.Screen -eq "shell-home") { Invoke-ShellCommand $state "powertoys" }
                        }

                        "V" {
                            if ($state.Screen -eq "shell-home") { Invoke-ShellCommand $state "media" }
                        }

                        "O" {
                            if ($state.Screen -eq "shell-home") { Invoke-ShellCommand $state "tools" }
                        }

                        "E" {
                            if ($state.Screen -eq "shell-home") {
                                Invoke-ShellCommand $state "dev"
                            } elseif ($state.Screen -eq "shell-projects") {
                                $projs = @(Get-WorkCtlProjects)
                                if ($state.SelectedProjectIndex -lt $projs.Count) {
                                    Invoke-Item $projs[$state.SelectedProjectIndex].Path
                                    Set-ShellNotification $state "Opened $($projs[$state.SelectedProjectIndex].Name) in Explorer" [ConsoleColor]::Green
                                }
                            } elseif ($state.Screen -eq "shell-project-detail") {
                                $projs = @(Get-WorkCtlProjects)
                                $p = $projs | Where-Object { $_.Name -ieq $state.SelectedProject } | Select-Object -First 1
                                if ($p) {
                                    Invoke-Item $p.Path
                                    Set-ShellNotification $state "Opened $($p.Name) in Explorer" [ConsoleColor]::Green
                                }
                            }
                        }

                        "J" {
                            if ($state.Screen -eq "shell-home") { Invoke-ShellCommand $state "projects" }
                        }

                        "A" {
                            if ($state.Screen -eq "shell-dev-menu") { Invoke-ShellCommand $state "agents" }
                        }

                        "F" {
                            if ($state.Screen -in @("shell-dev-menu", "shell-agents")) {
                                Invoke-ShellCommand $state "freebuff"
                            } elseif ($state.Screen -eq "shell-projects") {
                                $projs = @(Get-WorkCtlProjects)
                                if ($state.SelectedProjectIndex -lt $projs.Count) {
                                    Invoke-ShellCommand $state "freebuff $($projs[$state.SelectedProjectIndex].Name)"
                                }
                            } elseif ($state.Screen -eq "shell-project-detail") {
                                Invoke-ShellCommand $state "freebuff $($state.SelectedProject)"
                            }
                        }

                        "C" {
                            if ($state.Screen -in @("shell-dev-menu", "shell-agents")) {
                                Start-Process "code" -ArgumentList "E:\Workspace" -ErrorAction SilentlyContinue | Out-Null
                                Set-ShellNotification $state "Launched VS Code in E:\Workspace" [ConsoleColor]::Green
                            } elseif ($state.Screen -eq "shell-projects") {
                                $projs = @(Get-WorkCtlProjects)
                                if ($state.SelectedProjectIndex -lt $projs.Count) {
                                    Start-Process "code" -ArgumentList $projs[$state.SelectedProjectIndex].Path -ErrorAction SilentlyContinue | Out-Null
                                    Set-ShellNotification $state "Launched VS Code for $($projs[$state.SelectedProjectIndex].Name)" [ConsoleColor]::Green
                                }
                            } elseif ($state.Screen -eq "shell-project-detail") {
                                $projs = @(Get-WorkCtlProjects)
                                $p = $projs | Where-Object { $_.Name -ieq $state.SelectedProject } | Select-Object -First 1
                                if ($p) {
                                    Start-Process "code" -ArgumentList $p.Path -ErrorAction SilentlyContinue | Out-Null
                                    Set-ShellNotification $state "Launched VS Code for $($p.Name)" [ConsoleColor]::Green
                                }
                            }
                        }

                        "P" {
                            if ($state.Screen -eq "shell-home") {
                                Invoke-ShellCommand $state "processes"
                            } elseif ($state.Screen -eq "shell-dev-menu") {
                                Invoke-ShellCommand $state "projects"
                            } elseif ($state.Screen -eq "shell-network") {
                                Push-WorkCtlScreen $state "shell-network-ports"
                                $state.Dirty = $true
                            }
                        }

                        "S" {
                            if ($state.Screen -eq "shell-home") {
                                Invoke-ShellCommand $state "services"
                            } elseif ($state.Screen -eq "shell-workloads-list") {
                                $wReg = Get-ShellCachedWorkloads
                                if ($wReg -and $wReg.components) {
                                    $props = @($wReg.components.PSObject.Properties)
                                    if ($state.SelectedWorkloadIndex -lt $props.Count) {
                                        Invoke-ShellCommand $state "start $($props[$state.SelectedWorkloadIndex].Name)"
                                    }
                                }
                            }
                        }

                        "K" {
                            if ($state.Screen -eq "shell-workloads-list") {
                                $wReg = Get-ShellCachedWorkloads
                                if ($wReg -and $wReg.components) {
                                    $props = @($wReg.components.PSObject.Properties)
                                    if ($state.SelectedWorkloadIndex -lt $props.Count) {
                                        Invoke-ShellCommand $state "stop $($props[$state.SelectedWorkloadIndex].Name)"
                                    }
                                }
                            }
                        }

                        "R" {
                            if ($state.Screen -eq "shell-error") {
                                $state.Screen = "shell-home"
                                $state.LastError = $null
                                $state.Dirty = $true
                            } elseif ($state.Screen -eq "shell-network") {
                                $script:ShellNetworkOverviewCache = $null
                                Set-ShellNotification $state "Network overview refreshed" [ConsoleColor]::Green
                                $state.Dirty = $true
                            } elseif ($state.Screen -eq "shell-network-ports") {
                                $script:ShellNetworkCache = $null
                                Set-ShellNotification $state "Listening ports refreshed" [ConsoleColor]::Green
                                $state.Dirty = $true
                            } elseif ($state.Screen -eq "shell-workloads-list") {
                                $wReg = Get-ShellCachedWorkloads
                                if ($wReg -and $wReg.components) {
                                    $props = @($wReg.components.PSObject.Properties)
                                    if ($state.SelectedWorkloadIndex -lt $props.Count) {
                                        Invoke-ShellCommand $state "restart $($props[$state.SelectedWorkloadIndex].Name)"
                                    }
                                }
                            } elseif ($state.Screen -in @("shell-dev-menu", "shell-projects", "shell-agents")) {
                                Get-WorkCtlProjects -ForceRefresh | Out-Null
                                Set-ShellNotification $state "Development and project discovery refreshed" [ConsoleColor]::Green
                                $state.Dirty = $true
                            } else {
                                $state.Dirty = $true
                            }
                        }

                        "D" {
                            if ($state.Screen -eq "shell-home") {
                                Invoke-ShellCommand $state "diagnostics"
                            } elseif ($state.Screen -eq "shell-error") {
                                $state.ShowErrorDetails = -not $state.ShowErrorDetails
                                $state.Dirty = $true
                            } elseif ($state.Screen -eq "shell-project-detail") {
                                $projs = @(Get-WorkCtlProjects)
                                $p = $projs | Where-Object { $_.Name -ieq $state.SelectedProject } | Select-Object -First 1
                                if ($p) {
                                    $state.CurrentDirectory = $p.Path
                                    Set-ShellNotification $state "Set WorkCtl directory to $($p.Name)" [ConsoleColor]::Green
                                    $state.Dirty = $true
                                }
                            }
                        }

                        "N" {
                            if ($state.Screen -eq "shell-home") { Invoke-ShellCommand $state "network" }
                        }

                        "1" {
                            if ($state.Screen -eq "shell-home") {
                                Invoke-ShellCommand $state "start mysql"
                                Invoke-ShellCommand $state "start docker"
                                Set-ShellNotification $state "Activated DEV MODE (MySQL + Docker)" [ConsoleColor]::Green
                            }
                        }

                        "2" {
                            if ($state.Screen -eq "shell-home") {
                                Invoke-ShellCommand $state "start ollama"
                                Invoke-ShellCommand $state "start openclaw"
                                Set-ShellNotification $state "Activated AI MODE (Ollama + OpenClaw)" [ConsoleColor]::Green
                            }
                        }

                        "3" {
                            if ($state.Screen -eq "shell-home") {
                                Invoke-ShellCommand $state "start ollama"
                                Invoke-ShellCommand $state "start omniroute"
                                Set-ShellNotification $state "Activated LOCAL AI MODE (Ollama + OmniRoute)" [ConsoleColor]::Green
                            }
                        }

                        "4" {
                            if ($state.Screen -eq "shell-home") {
                                Invoke-ShellCommand $state "start dsa"
                                Set-ShellNotification $state "Activated MAINTENANCE MODE (Intel DSA)" [ConsoleColor]::Green
                            }
                        }

                        "Oem2" { # slash or question mark
                            if ($key.KeyChar -eq "?") {
                                if ($key.Modifiers -band [ConsoleModifiers]::Shift) {
                                    Open-WorkCtlGuideContextual $state $state.Screen
                                } else {
                                    $state.PreviousScreen = $state.Screen
                                    $state.Screen = "shell-help"
                                    $state.Dirty = $true
                                }
                            }
                        }

                        "F1" {
                            Open-WorkCtlGuideContextual $state $state.Screen
                        }

                        "G" {
                            if ($state.Screen -eq "shell-home") {
                                Invoke-ShellCommand $state "guide"
                            }
                        }
                    }

                    if ($key.Key -in @([ConsoleKey]::UpArrow, [ConsoleKey]::DownArrow, [ConsoleKey]::PageUp, [ConsoleKey]::PageDown)) {
                        $fpNewIdx = switch ($state.Screen) {
                            "shell-home"           { $state.SelectedHomeItem }
                            "shell-storage"        { $state.SelectedStorageIndex }
                            "shell-services"       { $state.SelectedServiceIndex }
                            "shell-network-ports"  { $state.SelectedPortIndex }
                            "shell-workloads-list" { $state.SelectedWorkloadIndex }
                            "shell-tools-list"     { $state.SelectedToolIndex }
                            "shell-processes"      { $state.SelectedProcessIndex }
                            "shell-projects"       { $state.SelectedProjectIndex }
                            "shell-dev-menu"       { if ($state.DevelopmentState) { $state.DevelopmentState.SelectedMenuIndex } else { 0 } }
                            "shell-search"         { $state.SelectedSearchIndex }
                            default                { -1 }
                        }
                        $fpNewScroll = switch ($state.Screen) {
                            "shell-tools-list"     { $state.ToolScroll }
                            "shell-services"       { $state.ServiceScroll }
                            "shell-network-ports"  { $state.PortScroll }
                            default                { 0 }
                        }
                        if ($fpOldIdx -ge 0 -and $fpNewIdx -ge 0 -and $fpNewIdx -ne $fpOldIdx) {
                            $script:WorkCtlFastPathEligible = $true
                            $script:WorkCtlFastPathOldIndex = $fpOldIdx
                            $script:WorkCtlFastPathNewIndex = $fpNewIdx
                            $script:WorkCtlFastPathOldScroll = $fpOldScroll
                            $script:WorkCtlFastPathNewScroll = $fpNewScroll
                        }
                        if ($isProfilingUI -and $keySw -and $script:WorkCtlUiProfileStats) {
                            $script:WorkCtlUiProfileStats.Latencies.Add($keySw.Elapsed.TotalMilliseconds)
                        }
                    }
                }
            } catch {
                if ($state.Screen -eq "shell-error") {
                    $state.Running = $false
                    break
                }
                $errHash = if ($_.Exception) { [math]::Abs($_.Exception.Message.GetHashCode() % 1000).ToString("D3") } else { "001" }
                $state.LastError = $_
                $state.LastErrorId = "WCTL-UI-STATE-$errHash"
                $state.FailingScreen = $state.Screen
                $state.PreviousScreen = $state.Screen
                $state.Screen = "shell-error"
                $state.Dirty = $true
                Set-ShellNotification $state "Recovered: $($_.Exception.Message)" [ConsoleColor]::Red
            }
        }
    } finally {
        Stop-WorkCtlTelemetryWorker $telemetryWorker
        Stop-WorkCtlUI
        if ($isProfilingUI -and $script:WorkCtlUiProfileStats) {
            $stats = $script:WorkCtlUiProfileStats
            $state.ProfileStats = $stats
            if ($stats.Latencies -and $stats.Latencies.Count -gt 0) {
                $sorted = @($stats.Latencies | Sort-Object)
                $med = $sorted[[int]($sorted.Count * 0.5)]
                $p95 = $sorted[[int]($sorted.Count * 0.95)]
                $avg = ($sorted | Measure-Object -Average).Average
                Write-Host "`n=== WORKCTL UI PROFILE RESULTS ===" -ForegroundColor Cyan
                Write-Host ("  InputEvents:         {0}" -f $stats.InputEvents)
                Write-Host ("  LogicalMoves:        {0}" -f $stats.LogicalMoves)
                Write-Host ("  FastPathHits:        {0}" -f $stats.FastPathHits)
                Write-Host ("  FastPathMisses:      {0}" -f $stats.FastPathMisses)
                Write-Host ("  FullFrameBuilds:     {0}" -f $stats.FullFrameBuilds)
                Write-Host ("  Paints:              {0}" -f $stats.Paints)
                Write-Host ("  RowsWritten:         {0}" -f $stats.RowsWritten)
                Write-Host ("  AverageLoopMs:       {0:N2} ms" -f $avg)
                Write-Host ("  MedianInputToPaint:  {0:N2} ms" -f $med)
                Write-Host ("  P95InputToPaint:     {0:N2} ms" -f $p95)
            }
        }
    }
    if ($TestMode) {
        return $state
    }
}

function Get-WorkCtlUiProfileStats {
    return $script:WorkCtlUiProfileStats
}

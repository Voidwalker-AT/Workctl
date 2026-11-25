# =================================================================
# WorkCtl Data Provider: Truthful Windows Services
# =================================================================
# Rule: DISCOVERY CREATES ENTITIES. METADATA ENRICHES ENTITIES.
# METADATA NEVER MANUFACTURES ENTITIES.
# Every displayed service must correspond to an actual discovered Windows service.

if (!$script:WorkCtlServicesState) {
    $script:WorkCtlServicesState = [ordered]@{
        Generation = 0
        LastUpdated = [datetime]::MinValue
        Refreshing = $false
        Error = $null
        Snapshot = [PSCustomObject]@{
            Services = @()
            RunningCount = 0
            StoppedCount = 0
            AutoCount = 0
            TotalCount = 0
            Categories = @{}
        }
    }
}

# Known metadata lookup dictionary (used to ENRICH discovered services, NEVER to create them)
$script:WorkCtlKnownServiceMeta = @{
    # Virtualization / Containers
    "WSLService"                      = @{ Category = "Virtualization / Containers"; Description = "Windows Subsystem for Linux Service"; Governance = "GUARDED" }
    "com.docker.service"              = @{ Category = "Virtualization / Containers"; Description = "Docker Desktop Core Management Service"; Governance = "GUARDED" }
    "LxssManager"                     = @{ Category = "Virtualization / Containers"; Description = "Legacy Linux Subsystem Manager"; Governance = "GUARDED" }
    "vmcompute"                       = @{ Category = "Virtualization / Containers"; Description = "Hyper-V Host Compute Service"; Governance = "GUARDED" }
    "HvHost"                          = @{ Category = "Virtualization / Containers"; Description = "Hyper-V Host Service"; Governance = "GUARDED" }
    
    # Core System
    "BITS"                            = @{ Category = "Core System"; Description = "Background Intelligent Transfer Service"; Governance = "SAFE" }
    "Winmgmt"                         = @{ Category = "Core System"; Description = "Windows Management Instrumentation (WMI)"; Governance = "PROTECTED" }
    "EventLog"                        = @{ Category = "Core System"; Description = "Windows Event Log Core Service"; Governance = "PROTECTED" }
    "PlugPlay"                        = @{ Category = "Core System"; Description = "Hardware Plug and Play Subsystem"; Governance = "PROTECTED" }
    "RpcSs"                           = @{ Category = "Core System"; Description = "Remote Procedure Call Service"; Governance = "PROTECTED" }
    "LanmanWorkstation"               = @{ Category = "Core System"; Description = "SMB Network Client Workstation Service"; Governance = "SAFE" }
    "Dnscache"                        = @{ Category = "Core System"; Description = "DNS Client Resolver Cache"; Governance = "PROTECTED" }
    "wuauserv"                        = @{ Category = "Core System"; Description = "Windows Update Service"; Governance = "SAFE" }
    "mpssvc"                          = @{ Category = "Core System"; Description = "Windows Defender Firewall"; Governance = "PROTECTED" }
    "Dhcp"                            = @{ Category = "Core System"; Description = "DHCP Client Service"; Governance = "PROTECTED" }

    # Hardware & Power
    "HPOmenCap"                       = @{ Category = "Hardware & Power"; Description = "HP Omen Gaming Hub HSA Service"; Governance = "SAFE" }
    "HPAppHelperCap"                  = @{ Category = "Hardware & Power"; Description = "HP Application Helper Hardware Support"; Governance = "SAFE" }
    "HPDiagsCap"                      = @{ Category = "Hardware & Power"; Description = "HP System Diagnostics Hardware Support"; Governance = "SAFE" }
    "HPNetworkCap"                    = @{ Category = "Hardware & Power"; Description = "HP Network Optimizer Hardware Support"; Governance = "SAFE" }
    "HPSysInfoCap"                    = @{ Category = "Hardware & Power"; Description = "HP System Information Hardware Support"; Governance = "SAFE" }
    "hpqcaslwmiex"                    = @{ Category = "Hardware & Power"; Description = "HP CASL Framework Hardware WMI Service"; Governance = "SAFE" }
    "HpTouchpointAnalyticsService"    = @{ Category = "Hardware & Power"; Description = "HP Touchpoint Analytics Service"; Governance = "SAFE" }
    "IntelAudioService"               = @{ Category = "Hardware & Power"; Description = "Intel Audio Hardware Service"; Governance = "SAFE" }
    "IntelGraphicsSoftwareService"    = @{ Category = "Hardware & Power"; Description = "Intel Graphics Management Service"; Governance = "SAFE" }
    "ipfsvc"                          = @{ Category = "Hardware & Power"; Description = "Intel Innovation Platform Framework"; Governance = "SAFE" }
    "jhi_service"                     = @{ Category = "Hardware & Power"; Description = "Intel Dynamic Application Loader Host"; Governance = "SAFE" }
    "cplspcon"                        = @{ Category = "Hardware & Power"; Description = "Intel Content Protection HDCP Service"; Governance = "SAFE" }
    "NvContainerLocalSystem"          = @{ Category = "Hardware & Power"; Description = "NVIDIA LocalSystem Container Service"; Governance = "SAFE" }
    "NVDisplay.ContainerLocalSystem"  = @{ Category = "Hardware & Power"; Description = "NVIDIA Display Driver Container LS"; Governance = "SAFE" }
    "FvSvc"                           = @{ Category = "Hardware & Power"; Description = "NVIDIA FrameView SDK Service"; Governance = "SAFE" }

    # Background Assistants
    "DiscordSystemHelper"             = @{ Category = "Background Assistants"; Description = "Discord Voice & System Helper Service"; Governance = "SAFE" }
    "GoogleChromeElevationService"    = @{ Category = "Background Assistants"; Description = "Google Chrome Elevation Helper"; Governance = "SAFE" }
    "GoogleUpdaterInternalService152.0.7933.0" = @{ Category = "Background Assistants"; Description = "Google Updater Internal Maintenance Service"; Governance = "SAFE" }
    "GoogleUpdaterService152.0.7933.0"         = @{ Category = "Background Assistants"; Description = "Google Updater Service"; Governance = "SAFE" }

    # Development & Tools
    "ssh-agent"                       = @{ Category = "Development / Database"; Description = "OpenSSH Authentication Agent"; Governance = "SAFE" }
}

function Get-WorkCtlServicesSnapshot {
    [OutputType([PSCustomObject])]
    param()
    
    $st = $script:WorkCtlServicesState
    $now = [datetime]::UtcNow
    $ageSec = ($now - $st.LastUpdated).TotalSeconds
    
    $badge = if ($st.Generation -eq 0) {
        "INIT"
    } elseif ($ageSec -le 5.0) {
        "LIVE"
    } elseif ($ageSec -le 30.0) {
        "$([int]$ageSec)s"
    } else {
        "STALE"
    }
    
    return [PSCustomObject]@{
        Generation = $st.Generation
        LastUpdated = $st.LastUpdated
        AgeSeconds = $ageSec
        StatusBadge = $badge
        Data = $st.Snapshot
        Error = $st.Error
    }
}

function Update-WorkCtlServicesSnapshot {
    param([switch]$Force)
    
    $st = $script:WorkCtlServicesState
    $now = [datetime]::UtcNow
    if (!$Force -and ($now - $st.LastUpdated).TotalSeconds -lt 15) {
        return
    }
    
    $st.Refreshing = $true
    try {
        # 1. Authoritative SCM Discovery
        $rawServices = @(Get-Service -ErrorAction SilentlyContinue)
        if (!$rawServices -or $rawServices.Count -eq 0) {
            throw "Windows Service Control Manager returned 0 services"
        }

        # 2. Fast Registry Property Lookup for ImagePath & Description
        $regInfo = @{}
        try {
            $baseKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services")
            if ($baseKey) {
                foreach ($s in $rawServices) {
                    try {
                        $sk = $baseKey.OpenSubKey($s.Name)
                        if ($sk) {
                            $regInfo[$s.Name] = @{
                                ImagePath = [string]$sk.GetValue("ImagePath")
                                Description = [string]$sk.GetValue("Description")
                            }
                            $sk.Close()
                        }
                    } catch {}
                }
                $baseKey.Close()
            }
        } catch {}

        # 3. Workload configuration check
        $managedNames = @{}
        try {
            $wCfgPath = "E:\TOOLS\WorkstationControl\config\workloads.json"
            if (Test-Path -LiteralPath $wCfgPath) {
                $wCfg = Get-Content -LiteralPath $wCfgPath -Raw | ConvertFrom-Json
                if ($wCfg.components) {
                    foreach ($p in $wCfg.components.PSObject.Properties) {
                        if ($p.Value.service) { $managedNames[$p.Value.service] = $true }
                        if ($p.Value.services) {
                            foreach ($sn in $p.Value.services) { $managedNames[$sn] = $true }
                        }
                    }
                }
            }
        } catch {}

        $list = New-Object System.Collections.Generic.List[object]
        $categoriesMap = @{
            "All" = 0
            "Core System" = 0
            "Virtualization / Containers" = 0
            "Hardware & Power" = 0
            "Development / Database" = 0
            "Media / Automation" = 0
            "Background Assistants" = 0
            "Other System" = 0
        }

        $running = 0
        $stopped = 0
        $auto = 0

        foreach ($s in $rawServices) {
            $stText = $s.Status.ToString()
            if ($stText -eq "Running") { $running++ }
            elseif ($stText -eq "Stopped") { $stopped++ }

            $stType = "Unknown"
            try { $stType = $s.StartType.ToString() } catch {}
            if ($stType -eq "Automatic") { $auto++ }

            # Metadata enrichment
            $meta = $script:WorkCtlKnownServiceMeta[$s.Name]
            $cat = "Other System"
            $desc = $s.DisplayName
            $gov = "SAFE"

            if ($meta) {
                $cat = $meta.Category
                if ($meta.Description) { $desc = $meta.Description }
                if ($meta.Governance) { $gov = $meta.Governance }
            } else {
                # Heuristic categorization based on name/display
                $nl = $s.Name.ToLower()
                $dl = $s.DisplayName.ToLower()

                if ($nl -match "^(hp|intel|nv|nvidia|realtek|audio)" -or $dl -match "(graphics|display|audio|hardware|thermal)") {
                    $cat = "Hardware & Power"
                } elseif ($nl -match "(wsl|docker|hyper-v|container|vmcompute|lxss)" -or $dl -match "(docker|hyper-v|virtual machine)") {
                    $cat = "Virtualization / Containers"
                } elseif ($nl -match "(sql|mongo|redis|postgres|oracle|git|ssh|code)" -or $dl -match "(database|server|developer)") {
                    $cat = "Development / Database"
                } elseif ($nl -match "(sonarr|radarr|plex|jellyfin|torrent|media|vlc)" -or $dl -match "(media|streaming|torrent)") {
                    $cat = "Media / Automation"
                } elseif ($nl -match "(google|discord|steam|epic|spotify|onedrive|dropbox)" -or $dl -match "(assistant|updater|sync)") {
                    $cat = "Background Assistants"
                } else {
                    $cat = "Core System"
                }
            }

            # Safety governance
            if ($s.Name -in @("Winmgmt", "RpcSs", "EventLog", "PlugPlay", "Dnscache", "mpssvc")) {
                $gov = "PROTECTED"
            } elseif ($s.Name -in @("WSLService", "com.docker.service", "vmcompute")) {
                $gov = "GUARDED"
            }

            $binPath = ""
            $regDesc = ""
            if ($regInfo.ContainsKey($s.Name)) {
                $binPath = $regInfo[$s.Name].ImagePath
                $regDesc = $regInfo[$s.Name].Description
            }
            if (!$desc -or $desc -eq $s.DisplayName) {
                if ($regDesc) { $desc = $regDesc }
            }

            $isManaged = [bool]$managedNames.ContainsKey($s.Name)

            $categoriesMap["All"]++
            if ($categoriesMap.ContainsKey($cat)) {
                $categoriesMap[$cat]++
            } else {
                $categoriesMap["Other System"]++
            }

            $list.Add([PSCustomObject]@{
                Name = $s.Name
                ServiceName = $s.Name
                DisplayName = $s.DisplayName
                Status = $stText
                StartType = $stType
                PID = $null
                BinaryPath = $binPath
                Description = $desc
                Category = $cat
                IsManagedWorkload = $isManaged
                Governance = $gov
            })
        }

        # Sort: Running first, then by DisplayName
        $sortedList = @($list | Sort-Object -Property @{ Expression = { if ($_.Status -eq "Running") { 0 } else { 1 } } }, "DisplayName")

        $st.Snapshot = [PSCustomObject]@{
            Services = $sortedList
            RunningCount = $running
            StoppedCount = $stopped
            AutoCount = $auto
            TotalCount = $sortedList.Count
            Categories = $categoriesMap
        }
        $st.Generation++
        $st.LastUpdated = [datetime]::UtcNow
        $st.Error = $null
    } catch {
        $st.Error = $_.Exception.Message
    } finally {
        $st.Refreshing = $false
    }
}

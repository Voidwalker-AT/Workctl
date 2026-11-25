# =================================================================
# WorkCtl Data Provider: Hardware & Fan Control Interlock
# =================================================================
# Authoritative live hardware telemetry: CPU, GPU cross-check,
# memory, physical disks, machine model, and thermal interlock.

if (!$script:WorkCtlHardwareState) {
    $script:WorkCtlHardwareState = [ordered]@{
        Generation = 0
        LastUpdated = [datetime]::MinValue
        Refreshing = $false
        Error = $null
        Snapshot = [PSCustomObject]@{
            CpuName = "Unknown CPU"
            CpuCores = 0
            CpuThreads = 0
            RamTotalGB = 0.0
            Model = "HP Victus by HP Gaming Laptop 15-fa1xxx"
            Manufacturer = "HP"
            GpuName = "Unknown GPU"
            GpuVramMB = 0
            GpuDriver = ""
            GpuPnpId = ""
            GpuSource = "None"
            GpuDiscrepancy = $false
            IgpuName = ""
            IgpuDriver = ""
            PhysicalDisks = @()
            Diagnostics = "Not initialized"
            OmenModel = "Victus by HP Gaming Laptop 15-fa1xxx"
            OmenProductId = "8C3F"
            OmenEcAvailable = $false
            OmenFanBackend = "None (monitoring only)"
            OmenWarning = "Secure Boot enabled - monitoring via WMI"
            FanControlRunning = $false
            FanControlVersion = "267"
            FanControlCurvesCount = 0
            ActiveFanOwner = "BIOS AUTO" # BIOS AUTO | OMENCORE | FANCONTROL | UNKNOWN
            OwnerConflict = $false
        }
    }
}

function Get-WorkCtlHardwareSnapshot {
    [OutputType([PSCustomObject])]
    param()
    
    $st = $script:WorkCtlHardwareState
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

function Update-WorkCtlHardwareSnapshot {
    param([switch]$Force)
    
    $st = $script:WorkCtlHardwareState
    $now = [datetime]::UtcNow
    if (!$Force -and ($now - $st.LastUpdated).TotalSeconds -lt 10) {
        return
    }
    
    $st.Refreshing = $true
    try {
        # 1. System Model, CPU & RAM
        $csModel = "Victus by HP Gaming Laptop 15-fa1xxx"
        $csMfr = "HP"
        $ramGB = 16.0
        try {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cs) {
                if ($cs.Model) { $csModel = $cs.Model.Trim() }
                if ($cs.Manufacturer) { $csMfr = $cs.Manufacturer.Trim() }
                if ($cs.TotalPhysicalMemory) { $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2) }
            }
        } catch {}

        $cpuName = "Intel Core Processor"
        $cpuCores = 8
        $cpuThreads = 12
        try {
            $cpuObj = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cpuObj) {
                if ($cpuObj.Name) { $cpuName = $cpuObj.Name.Trim() }
                if ($cpuObj.NumberOfCores) { $cpuCores = [int]$cpuObj.NumberOfCores }
                if ($cpuObj.NumberOfLogicalProcessors) { $cpuThreads = [int]$cpuObj.NumberOfLogicalProcessors }
            }
        } catch {}
        
        # 2. Authoritative GPU Cross-Check (nvidia-smi + Win32_VideoController)
        $gpuName = ""
        $gpuVram = 0
        $gpuDriver = ""
        $gpuPnp = ""
        $gpuSource = "None"
        $gpuDiscrepancy = $false
        $igpuName = ""
        $igpuDriver = ""
        $diagMsg = "OK"

        # Check nvidia-smi first (authoritative dGPU runtime query)
        $smiName = ""
        $smiVram = 0
        $smiDriver = ""
        try {
            $smiOut = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>$null
            if ($smiOut) {
                $parts = ($smiOut -split ",").Trim()
                if ($parts.Count -ge 3) {
                    $smiName = $parts[0]
                    $smiVram = [int]$parts[1]
                    $smiDriver = $parts[2]
                }
            }
        } catch {}

        # Check Win32_VideoController
        $wmiNvName = ""
        $wmiNvVram = 0
        $wmiNvDriver = ""
        $wmiNvPnp = ""
        try {
            $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
            foreach ($g in $gpus) {
                if ($g.Name -match "NVIDIA") {
                    $wmiNvName = $g.Name.Trim()
                    $wmiNvDriver = $g.DriverVersion
                    $wmiNvPnp = $g.PNPDeviceID
                    if ($g.AdapterRAM) { $wmiNvVram = [int][math]::Round($g.AdapterRAM / 1MB, 0) }
                } elseif ($g.Name -match "Intel") {
                    $igpuName = $g.Name.Trim()
                    $igpuDriver = $g.DriverVersion
                }
            }
        } catch {}

        # Reconcile GPU identity
        if ($smiName) {
            $gpuName = $smiName
            $gpuVram = $smiVram
            $gpuDriver = $smiDriver
            $gpuPnp = $wmiNvPnp
            $gpuSource = "nvidia-smi (live dGPU)"

            if ($wmiNvName -and ($wmiNvName -ne $smiName)) {
                $gpuDiscrepancy = $true
                $diagMsg = "DISCREPANCY: nvidia-smi reports '$smiName' ($smiVram MB) but WMI reports '$wmiNvName'"
            } else {
                $diagMsg = "Authoritative GPU: $gpuName | Driver $gpuDriver | VRAM $gpuVram MB"
            }
        } elseif ($wmiNvName) {
            $gpuName = $wmiNvName
            $gpuVram = $wmiNvVram
            $gpuDriver = $wmiNvDriver
            $gpuPnp = $wmiNvPnp
            $gpuSource = "Win32_VideoController"
            $diagMsg = "WMI GPU: $gpuName | Driver $gpuDriver"
        } else {
            $gpuName = "Integrated / Standard Display"
            $gpuSource = "Fallback"
            $diagMsg = "No dedicated NVIDIA GPU discovered"
        }

        # 3. Physical Disks
        $pDisks = New-Object System.Collections.Generic.List[object]
        try {
            $disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
            foreach ($pd in $disks) {
                $pDisks.Add([PSCustomObject]@{
                    DeviceId = $pd.DeviceId
                    FriendlyName = $pd.FriendlyName
                    MediaType = $pd.MediaType
                    BusType = $pd.BusType
                    SizeGB = [math]::Round($pd.Size / 1GB, 1)
                    OperationalStatus = $pd.OperationalStatus
                })
            }
        } catch {}
        
        # 4. FanControl State
        $fcProc = Get-Process -Name "FanControl" -ErrorAction SilentlyContinue | Select-Object -First 1
        $fcRunning = ($null -ne $fcProc)
        $fcCurves = 0
        $fcConfigPath = "E:\TOOLS\FanControl_267_net_10_0\Configurations\userConfig.json"
        if (Test-Path -LiteralPath $fcConfigPath) {
            try {
                $fcJson = Get-Content -LiteralPath $fcConfigPath -Raw | ConvertFrom-Json
                if ($fcJson.FanControl -and $fcJson.FanControl.FanCurves) {
                    $fcCurves = @($fcJson.FanControl.FanCurves).Count
                }
            } catch {}
        }
        
        # 5. OmenCore State (read-only)
        $omenEc = $false
        $omenBackend = "None (monitoring only)"
        $omenModel = $csModel
        $omenPid = "8C3F"
        $omenWarning = "Secure Boot enabled - monitoring via WMI"
        $omenDaemonRunning = $false
        
        $omenProc = Get-Process -Name "omencore-cli" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($omenProc) { $omenDaemonRunning = $true }
        
        # 6. Hardware Fan Ownership Interlock Determination
        $fanOwner = "BIOS AUTO"
        $conflict = $false
        
        if ($fcRunning -and $omenDaemonRunning) {
            $fanOwner = "CONFLICT"
            $conflict = $true
        } elseif ($fcRunning) {
            $fanOwner = "FANCONTROL"
        } elseif ($omenDaemonRunning) {
            $fanOwner = "OMENCORE"
        } else {
            $fanOwner = "BIOS AUTO"
        }
        
        $st.Snapshot = [PSCustomObject]@{
            CpuName = $cpuName
            CpuCores = $cpuCores
            CpuThreads = $cpuThreads
            RamTotalGB = $ramGB
            Model = $csModel
            Manufacturer = $csMfr
            GpuName = $gpuName
            GpuVramMB = $gpuVram
            GpuDriver = $gpuDriver
            GpuPnpId = $gpuPnp
            GpuSource = $gpuSource
            GpuDiscrepancy = $gpuDiscrepancy
            IgpuName = $igpuName
            IgpuDriver = $igpuDriver
            PhysicalDisks = $pDisks.ToArray()
            Diagnostics = $diagMsg
            OmenModel = $omenModel
            OmenProductId = $omenPid
            OmenEcAvailable = $omenEc
            OmenFanBackend = $omenBackend
            OmenWarning = $omenWarning
            FanControlRunning = $fcRunning
            FanControlVersion = "267"
            FanControlCurvesCount = $fcCurves
            ActiveFanOwner = $fanOwner
            OwnerConflict = $conflict
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

function Test-WorkCtlFanOwnershipAllowed {
    param(
        [ValidateSet("OMENCORE", "FANCONTROL", "BIOS")][string]$RequestedController,
        $MockFanControlRunning = $null,
        $MockActiveFanOwner = $null
    )
    
    $snap = (Get-WorkCtlHardwareSnapshot).Data
    $fcRunning = if ($null -ne $MockFanControlRunning) { [bool]$MockFanControlRunning } else { $snap.FanControlRunning }
    $activeOwner = if ($null -ne $MockActiveFanOwner) { [string]$MockActiveFanOwner } else { $snap.ActiveFanOwner }
    
    if ($RequestedController -eq "OMENCORE") {
        if ($fcRunning) {
            return [PSCustomObject]@{
                Allowed = $false
                Reason = "INTERLOCK BLOCKED: FanControl is currently running. Close FanControl before starting OmenCore daemon control."
            }
        }
        return [PSCustomObject]@{ Allowed = $true; Reason = "OK" }
    } elseif ($RequestedController -eq "FANCONTROL") {
        if ($activeOwner -eq "OMENCORE") {
            return [PSCustomObject]@{
                Allowed = $false
                Reason = "INTERLOCK BLOCKED: OmenCore daemon is actively controlling fan curves. Stop OmenCore daemon first."
            }
        }
        return [PSCustomObject]@{ Allowed = $true; Reason = "OK" }
    }
    return [PSCustomObject]@{ Allowed = $true; Reason = "OK" }
}

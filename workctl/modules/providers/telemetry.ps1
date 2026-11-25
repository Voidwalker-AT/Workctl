# =================================================================
# WorkCtl Data Provider: Telemetry
# =================================================================
# Provides CPU, RAM, Battery, and basic system load snapshots.
# Decoupled from the UI rendering thread.

if (!$script:WorkCtlTelemetryState) {
    $script:WorkCtlTelemetryState = [ordered]@{
        Generation = 0
        LastUpdated = [datetime]::MinValue
        Refreshing = $false
        Error = $null
        Snapshot = [PSCustomObject]@{
            CpuPercent = 0
            RamUsedGB = 0.0
            RamTotalGB = 0.0
            RamFreeGB = 0.0
            RamPercent = 0
            BatteryPercent = $null
            IsCharging = $false
            UptimeText = "0h 0m"
        }
    }
}

function Get-WorkCtlTelemetrySnapshot {
    [OutputType([PSCustomObject])]
    param()
    
    $st = $script:WorkCtlTelemetryState
    $now = [datetime]::UtcNow
    $ageSec = ($now - $st.LastUpdated).TotalSeconds
    
    $badge = if ($st.Generation -eq 0) {
        "INIT"
    } elseif ($ageSec -le 2.0) {
        "LIVE"
    } elseif ($ageSec -le 10.0) {
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

function Update-WorkCtlTelemetrySnapshot {
    param([switch]$Force)
    
    $st = $script:WorkCtlTelemetryState
    $now = [datetime]::UtcNow
    if (!$Force -and ($now - $st.LastUpdated).TotalMilliseconds -lt 500) {
        return
    }
    
    $st.Refreshing = $true
    try {
        # RAM via GC / OS memory status
        $os = $null
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        } catch {}
        
        $totalGB = 0.0
        $freeGB = 0.0
        $usedGB = 0.0
        $ramPct = 0
        if ($os) {
            $totalGB = [math]::Round([double]$os.TotalVisibleMemorySize / 1MB, 1)
            $freeGB = [math]::Round([double]$os.FreePhysicalMemory / 1MB, 1)
            $usedGB = [math]::Round($totalGB - $freeGB, 1)
            if ($totalGB -gt 0) {
                $ramPct = [int][math]::Round(($usedGB / $totalGB) * 100)
            }
        }
        
        # CPU approximation or performance counter
        $cpuPct = 0
        try {
            $cpuSample = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue
            if ($cpuSample) {
                $cpuPct = [int]$cpuSample.PercentProcessorTime
            }
        } catch {}
        
        # Battery status
        $batPct = $null
        $charging = $false
        try {
            $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
            if ($bat) {
                $batPct = [int]$bat.EstimatedChargeRemaining
                $charging = ($bat.BatteryStatus -eq 2)
            }
        } catch {}
        
        $uptime = "Unknown"
        if ($os -and $os.LastBootUpTime) {
            $span = [datetime]::Now - $os.LastBootUpTime
            $uptime = "{0}d {1}h {2}m" -f $span.Days, $span.Hours, $span.Minutes
        }
        
        $st.Snapshot = [PSCustomObject]@{
            CpuPercent = $cpuPct
            RamUsedGB = $usedGB
            RamTotalGB = $totalGB
            RamFreeGB = $freeGB
            RamPercent = $ramPct
            BatteryPercent = $batPct
            IsCharging = $charging
            UptimeText = $uptime
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

# =================================================================
# WorkCtl Data Provider: Processes
# =================================================================
# Caches top processes to eliminate Get-Process calls during UI navigation.

if (!$script:WorkCtlProcessesState) {
    $script:WorkCtlProcessesState = [ordered]@{
        Generation = 0
        LastUpdated = [datetime]::MinValue
        Refreshing = $false
        Error = $null
        Snapshot = [PSCustomObject]@{
            Processes = @()
            TotalCount = 0
        }
    }
}

function Get-WorkCtlProcessesSnapshot {
    [OutputType([PSCustomObject])]
    param()
    
    $st = $script:WorkCtlProcessesState
    $now = [datetime]::UtcNow
    $ageSec = ($now - $st.LastUpdated).TotalSeconds
    
    $badge = if ($st.Generation -eq 0) {
        "INIT"
    } elseif ($ageSec -le 2.0) {
        "LIVE"
    } elseif ($ageSec -le 5.0) {
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

function Update-WorkCtlProcessesSnapshot {
    param([switch]$Force)
    
    $st = $script:WorkCtlProcessesState
    $now = [datetime]::UtcNow
    if (!$Force -and ($now - $st.LastUpdated).TotalSeconds -lt 2) {
        return
    }
    
    $st.Refreshing = $true
    try {
        $all = Get-Process -ErrorAction SilentlyContinue
        $top = $all | Sort-Object CPU -Descending | Select-Object -First 35
        
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($p in $top) {
            $wsMB = [math]::Round([double]$p.WorkingSet64 / 1MB, 1)
            $cpuVal = if ($p.CPU) { [math]::Round([double]$p.CPU, 1) } else { 0.0 }
            $list.Add([PSCustomObject]@{
                Id = $p.Id
                ProcessName = $p.ProcessName
                CPU = $cpuVal
                WS_MB = $wsMB
                Responding = $p.Responding
            })
        }
        
        $st.Snapshot = [PSCustomObject]@{
            Processes = $list.ToArray()
            TotalCount = $all.Count
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

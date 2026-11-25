# =================================================================
# WorkCtl Data Provider: Tools
# =================================================================
# Caches status of registered external tools.
# Eliminates synchronous TCP port connects and CIM queries during UI navigation.

if (!$script:WorkCtlToolsState) {
    $script:WorkCtlToolsState = [ordered]@{
        Generation = 0
        LastUpdated = [datetime]::MinValue
        Refreshing = $false
        Error = $null
        Snapshot = [PSCustomObject]@{
            Tools = @()
            RunningCount = 0
            TotalCount = 0
        }
    }
}

function Get-WorkCtlToolsSnapshot {
    [OutputType([PSCustomObject])]
    param()
    
    $st = $script:WorkCtlToolsState
    $now = [datetime]::UtcNow
    $ageSec = ($now - $st.LastUpdated).TotalSeconds
    
    $badge = if ($st.Generation -eq 0) {
        "INIT"
    } elseif ($ageSec -le 3.0) {
        "LIVE"
    } elseif ($ageSec -le 15.0) {
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

function Update-WorkCtlToolsSnapshot {
    param([switch]$Force)
    
    $st = $script:WorkCtlToolsState
    $now = [datetime]::UtcNow
    if (!$Force -and ($now - $st.LastUpdated).TotalSeconds -lt 2) {
        return
    }
    
    $st.Refreshing = $true
    try {
        $tReg = Get-WorkCtlToolsConfig
        $toolsList = New-Object System.Collections.Generic.List[object]
        $runningCount = 0
        
        # Batch query all running processes once to avoid per-tool Get-Process calls
        $runningProcessNames = @{}
        foreach ($proc in (Get-Process -ErrorAction SilentlyContinue)) {
            $runningProcessNames[$proc.ProcessName.ToLower()] = $true
        }
        
        if ($tReg -and $tReg.tools) {
            foreach ($p in $tReg.tools.PSObject.Properties) {
                $id = $p.Name
                $t = $p.Value
                
                $installed = $false
                if ($t.installPath -and (Test-Path -LiteralPath $t.installPath)) {
                    $installed = $true
                } elseif ($t.command) {
                    if (Get-Command $t.command -ErrorAction SilentlyContinue) {
                        $installed = $true
                    }
                }
                
                $running = $false
                if ($t.processNames) {
                    foreach ($pn in $t.processNames) {
                        if ($runningProcessNames.ContainsKey($pn.ToLower())) {
                            $running = $true
                            break
                        }
                    }
                }
                
                if ($running) { $runningCount++ }
                
                $statusText = if (!$installed) {
                    "NOT INSTALLED"
                } elseif ($running) {
                    "RUNNING"
                } else {
                    "STOPPED"
                }
                
                $toolsList.Add([PSCustomObject]@{
                    Id = $id
                    Label = $t.label
                    Description = $t.description
                    Category = if ($t.category) { $t.category } else { "Utilities" }
                    StatusText = $statusText
                    Installed = $installed
                    Running = $running
                    Port = $t.defaultPort
                    Kind = $t.kind
                    InstallPath = $t.installPath
                    Command = $t.command
                })
            }
        }
        
        $st.Snapshot = [PSCustomObject]@{
            Tools = $toolsList.ToArray()
            RunningCount = $runningCount
            TotalCount = $toolsList.Count
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

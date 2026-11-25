# =================================================================
# WorkCtl Data Provider: Storage
# =================================================================
# Implements a normalized storage model distinguishing between:
# 1. Local Fixed Volumes (Physical local disks only)
# 2. Other Mounts (Google Drive, Virtual Drives, ISOs, Network, Subst)
# 3. Physical Devices (NVMe / SATA / USB disks)

if (!$script:WorkCtlStorageState) {
    $script:WorkCtlStorageState = [ordered]@{
        Generation = 0
        LastUpdated = [datetime]::MinValue
        Refreshing = $false
        Error = $null
        Snapshot = [PSCustomObject]@{
            LocalVolumes = @()
            OtherMounts = @()
            PhysicalDisks = @()
            MountedImages = @()
        }
    }
}

function Get-WorkCtlStorageSnapshot {
    [OutputType([PSCustomObject])]
    param()
    
    $st = $script:WorkCtlStorageState
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

function Update-WorkCtlStorageSnapshot {
    param([switch]$Force)
    
    $st = $script:WorkCtlStorageState
    $now = [datetime]::UtcNow
    if (!$Force -and ($now - $st.LastUpdated).TotalSeconds -lt 15) {
        return
    }
    
    $st.Refreshing = $true
    try {
        $localVolumes = New-Object System.Collections.Generic.List[object]
        $otherMounts = New-Object System.Collections.Generic.List[object]
        $physicalDisks = New-Object System.Collections.Generic.List[object]
        $mountedImages = New-Object System.Collections.Generic.List[object]
        
        # 1. Query Physical Disks
        try {
            $disks = Get-Disk -ErrorAction SilentlyContinue
            foreach ($d in $disks) {
                $physicalDisks.Add([PSCustomObject]@{
                    Number = $d.Number
                    FriendlyName = $d.FriendlyName
                    BusType = $d.BusType.ToString()
                    PartitionStyle = $d.PartitionStyle.ToString()
                    SizeGB = [math]::Round([double]$d.Size / 1GB, 1)
                    Health = $d.HealthStatus.ToString()
                })
            }
        } catch {}
        
        # 2. Query Partitions with Drive Letters
        $partitionLetters = @{}
        try {
            $partitions = Get-Partition -ErrorAction SilentlyContinue
            foreach ($p in $partitions) {
                if ($p.DriveLetter) {
                    $letter = ("" + $p.DriveLetter).ToUpper()
                    $partitionLetters[$letter] = [PSCustomObject]@{
                        DiskNumber = $p.DiskNumber
                        PartitionNumber = $p.PartitionNumber
                        Type = $p.Type
                    }
                }
            }
        } catch {}
        
        # 3. Query Logical Disks via CIM
        $logicalDisks = @()
        try {
            $logicalDisks = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue
        } catch {}
        
        foreach ($ld in $logicalDisks) {
            $letter = $ld.DeviceID.TrimEnd(':').ToUpper()
            $totalGB = if ($ld.Size) { [math]::Round([double]$ld.Size / 1GB, 1) } else { 0.0 }
            $freeGB = if ($ld.FreeSpace) { [math]::Round([double]$ld.FreeSpace / 1GB, 1) } else { 0.0 }
            $usedGB = [math]::Round([math]::Max(0.0, $totalGB - $freeGB), 1)
            $pctFree = if ($totalGB -gt 0) { [int][math]::Round(($freeGB / $totalGB) * 100) } else { 0 }
            
            $volLabel = if ($ld.VolumeName) { $ld.VolumeName } else { "" }
            $fs = if ($ld.FileSystem) { $ld.FileSystem } else { "Unknown" }
            $driveType = $ld.DriveType
            
            # Classification
            $isLocalFixed = $false
            $mountKind = "OTHER"
            $physicalBacking = "None"
            
            if ($partitionLetters.ContainsKey($letter)) {
                # Backed by a real physical disk partition!
                $isLocalFixed = ($driveType -eq 3)
                $mountKind = "LOCAL_FIXED"
                $pInfo = $partitionLetters[$letter]
                $physicalBacking = "Disk $($pInfo.DiskNumber), Partition $($pInfo.PartitionNumber)"
            } elseif ($volLabel -match "Google Drive" -or $volLabel -match "@") {
                $mountKind = "CLOUD_VIRTUAL"
                $physicalBacking = "Google Drive Desktop Virtual Client"
            } elseif ($driveType -eq 4) {
                $mountKind = "NETWORK"
                $physicalBacking = if ($ld.ProviderName) { $ld.ProviderName } else { "SMB / Network" }
            } elseif ($driveType -eq 5) {
                $mountKind = "OPTICAL_OR_IMAGE"
                $physicalBacking = "Virtual Optical / CD"
            } else {
                $mountKind = "VIRTUAL_OR_OTHER"
                $physicalBacking = "Virtual Mount Point"
            }
            
            $isCloud = ($mountKind -eq "CLOUD_VIRTUAL")
            $isNet = ($driveType -eq 4)
            $isRem = ($driveType -eq 2)
            $isOpt = ($driveType -eq 5)
            $isVirt = ($isCloud -or $isOpt -or !$isLocalFixed)

            $item = [PSCustomObject]@{
                DriveLetter = $letter
                VolumeLabel = $volLabel
                FileSystem = $fs
                TotalGB = $totalGB
                FreeGB = $freeGB
                UsedGB = $usedGB
                PercentFree = $pctFree
                DriveType = $driveType
                MountKind = $mountKind
                PhysicalBacking = $physicalBacking
                Capacity = [int64]$ld.Size
                FreeSpace = [int64]$ld.FreeSpace
                IsLocalFixed = $isLocalFixed
                IsRemovable = $isRem
                IsNetwork = $isNet
                IsVirtual = $isVirt
                IsMountedImage = $isOpt
                IsSubst = $false
                IsCloudOrOther = ($isCloud -or !$isLocalFixed)
                Classification = if ($isCloud) { "Virtual Client / Cloud Mount (Google Drive)" } else { "Virtual / Other Mount" }
            }
            
            if ($isLocalFixed) {
                $localVolumes.Add($item)
            } else {
                $otherMounts.Add($item)
            }
        }
        
        # 4. Query Mounter (WinCDEmu) virtual images if batchmnt64 is available
        $mounterExe = "E:\TOOLS\Mounter\batchmnt64.exe"
        if (Test-Path -LiteralPath $mounterExe) {
            try {
                $listOutput = & $mounterExe /list 2>&1
                foreach ($line in $listOutput) {
                    if ($line -match '^([A-Z]):\s+(.+)$') {
                        $mountedImages.Add([PSCustomObject]@{
                            DriveLetter = $matches[1]
                            ImagePath = $matches[2].Trim()
                        })
                    }
                }
            } catch {}
        }
        
        $st.Snapshot = [PSCustomObject]@{
            LocalVolumes = $localVolumes.ToArray()
            OtherMounts = $otherMounts.ToArray()
            PhysicalDisks = $physicalDisks.ToArray()
            MountedImages = $mountedImages.ToArray()
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

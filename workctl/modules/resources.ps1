# =================================================================
# WorkCtl v1.5 - Resource / Telemetry Engine
# =================================================================

$script:ResInitialized=$false
$script:CpuCounter=$null

$script:NetPrevRx=$null
$script:NetPrevTx=$null
$script:NetPrevTime=$null

$script:Cache=@{
    Memory=$null
    MemoryAt=[datetime]::MinValue

    Battery=$null
    BatteryAt=[datetime]::MinValue

    Disks=$null
    DisksAt=[datetime]::MinValue
}

function Initialize-WorkCtlResources {

    if($script:ResInitialized){
        return
    }

    # -------------------------------------------------------------
    # Persistent CPU counter
    # -------------------------------------------------------------

    try{
        $script:CpuCounter=New-Object System.Diagnostics.PerformanceCounter(
            "Processor",
            "% Processor Time",
            "_Total"
        )

        # Prime counter. First value is not meaningful.
        $null=$script:CpuCounter.NextValue()

    }catch{
        $script:CpuCounter=$null
    }

    # -------------------------------------------------------------
    # Prime network counters
    # -------------------------------------------------------------

    try{
        $n=Get-WorkCtlNetworkRaw

        $script:NetPrevRx=$n.Rx
        $script:NetPrevTx=$n.Tx
        $script:NetPrevTime=[datetime]::UtcNow
    }catch{
        $script:NetPrevRx=$null
        $script:NetPrevTx=$null
        $script:NetPrevTime=$null
    }

    $script:ResInitialized=$true
}

function Get-WorkCtlCPU {

    if(!$script:ResInitialized){
        Initialize-WorkCtlResources
    }

    if(!$script:CpuCounter){

        return [PSCustomObject]@{
            Available=$false
            UsagePercent=$null
        }
    }

    try{

        $v=$script:CpuCounter.NextValue()

        if($v -lt 0){$v=0}
        if($v -gt 100){$v=100}

        [PSCustomObject]@{
            Available=$true
            UsagePercent=[math]::Round($v,1)
        }

    }catch{

        [PSCustomObject]@{
            Available=$false
            UsagePercent=$null
        }
    }
}

function Get-WorkCtlMemory {

    # Memory changes quickly enough to be useful live, but CIM is
    # relatively expensive. Cache for 1 second.

    $now=[datetime]::UtcNow

    if(
        $script:Cache.Memory -and
        ($now-$script:Cache.MemoryAt).TotalMilliseconds -lt 1000
    ){
        return $script:Cache.Memory
    }

    try{

        $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop

        $total=$os.TotalVisibleMemorySize*1KB
        $free=$os.FreePhysicalMemory*1KB
        $used=$total-$free

        $r=[PSCustomObject]@{
            Available=$true
            TotalGB=[math]::Round($total/1GB,2)
            UsedGB=[math]::Round($used/1GB,2)
            FreeGB=[math]::Round($free/1GB,2)
            UsedPercent=[math]::Round(($used/$total)*100,1)
        }

    }catch{

        $r=[PSCustomObject]@{
            Available=$false
            TotalGB=$null
            UsedGB=$null
            FreeGB=$null
            UsedPercent=$null
        }
    }

    $script:Cache.Memory=$r
    $script:Cache.MemoryAt=$now

    $r
}

function Get-WorkCtlGPU {

    if(!(Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue)){

        return [PSCustomObject]@{
            Available=$false
        }
    }

    try{

        $raw=& nvidia-smi.exe `
            --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw `
            --format=csv,noheader,nounits `
            2>$null

        if(!$raw){
            throw "No NVIDIA telemetry returned."
        }

        $a=@($raw -split "," | ForEach-Object {$_.Trim()})

        if($a.Count -lt 6){
            throw "Unexpected NVIDIA telemetry format."
        }

        [PSCustomObject]@{
            Available=$true
            Name=$a[0]
            UsagePercent=[double]$a[1]
            VRAMUsedMB=[double]$a[2]
            VRAMTotalMB=[double]$a[3]
            TemperatureC=[double]$a[4]
            PowerW=[double]$a[5]
        }

    }catch{

        [PSCustomObject]@{
            Available=$false
        }
    }
}

function Get-WorkCtlNetworkRaw {

    $active=@(
        Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object {$_.Status -eq "Up"}
    )

    $rx=[int64]0
    $tx=[int64]0

    foreach($a in $active){

        try{

            $s=Get-NetAdapterStatistics `
                -Name $a.Name `
                -ErrorAction Stop

            $rx += [int64]$s.ReceivedBytes
            $tx += [int64]$s.SentBytes

        }catch{}
    }

    [PSCustomObject]@{
        Rx=$rx
        Tx=$tx
    }
}

function Get-WorkCtlNetwork {

    if(!$script:ResInitialized){
        Initialize-WorkCtlResources
    }

    try{

        $now=[datetime]::UtcNow
        $n=Get-WorkCtlNetworkRaw

        if(
            $script:NetPrevRx -eq $null -or
            $script:NetPrevTx -eq $null -or
            $script:NetPrevTime -eq $null
        ){

            $script:NetPrevRx=$n.Rx
            $script:NetPrevTx=$n.Tx
            $script:NetPrevTime=$now

            return [PSCustomObject]@{
                Available=$true
                DownloadMbps=0
                UploadMbps=0
            }
        }

        $sec=($now-$script:NetPrevTime).TotalSeconds

        if($sec -le 0){
            $sec=0.001
        }

        $drx=$n.Rx-$script:NetPrevRx
        $dtx=$n.Tx-$script:NetPrevTx

        if($drx -lt 0){$drx=0}
        if($dtx -lt 0){$dtx=0}

        $down=($drx*8)/$sec/1MB
        $up=($dtx*8)/$sec/1MB

        $script:NetPrevRx=$n.Rx
        $script:NetPrevTx=$n.Tx
        $script:NetPrevTime=$now

        [PSCustomObject]@{
            Available=$true
            DownloadMbps=[math]::Round($down,2)
            UploadMbps=[math]::Round($up,2)
        }

    }catch{

        [PSCustomObject]@{
            Available=$false
            DownloadMbps=$null
            UploadMbps=$null
        }
    }
}

function Get-WorkCtlBattery {

    $now=[datetime]::UtcNow

    if(
        $script:Cache.Battery -and
        ($now-$script:Cache.BatteryAt).TotalSeconds -lt 3
    ){
        return $script:Cache.Battery
    }

    try{

        $b=Get-CimInstance Win32_Battery `
            -ErrorAction Stop |
            Select-Object -First 1

        if(!$b){
            throw "No battery."
        }

        # Common BatteryStatus values:
        # 1 = discharging
        # 2 = AC / fully charged
        # 6-9 = charging variants

        $ac=$b.BatteryStatus -ne 1

        $r=[PSCustomObject]@{
            Available=$true
            Percent=[int]$b.EstimatedChargeRemaining
            AC=$ac
            StatusCode=[int]$b.BatteryStatus
        }

    }catch{

        $r=[PSCustomObject]@{
            Available=$false
            Percent=$null
            AC=$null
            StatusCode=$null
        }
    }

    $script:Cache.Battery=$r
    $script:Cache.BatteryAt=$now

    $r
}

function Get-WorkCtlDisks {

    $now=[datetime]::UtcNow

    if(
        $script:Cache.Disks -and
        ($now-$script:Cache.DisksAt).TotalSeconds -lt 15
    ){
        return $script:Cache.Disks
    }

    $r=@()

    try{

        $d=@(
            Get-CimInstance Win32_LogicalDisk `
                -Filter "DriveType=3" `
                -ErrorAction Stop
        )

        foreach($x in $d){

            if(!$x.Size -or $x.Size -le 0){
                continue
            }

            $used=$x.Size-$x.FreeSpace

            $r += [PSCustomObject]@{
                Drive=$x.DeviceID
                TotalGB=[math]::Round($x.Size/1GB,1)
                UsedGB=[math]::Round($used/1GB,1)
                FreeGB=[math]::Round($x.FreeSpace/1GB,1)
                UsedPercent=[math]::Round(($used/$x.Size)*100,1)
            }
        }

    }catch{}

    $script:Cache.Disks=$r
    $script:Cache.DisksAt=$now

    $r
}

function Get-WorkCtlTopProcesses(
    [int]$Count=10
){

    @(
        Get-Process -ErrorAction SilentlyContinue |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First $Count |
        ForEach-Object {

            [PSCustomObject]@{
                Name=$_.Name
                PID=$_.Id
                RAM_MB=[math]::Round($_.WorkingSet64/1MB,1)
                CPU_s=if($_.CPU -ne $null){
                    [math]::Round($_.CPU,1)
                }else{
                    $null
                }
            }
        }
    )
}

function Get-WorkCtlSnapshot {

    if(!$script:ResInitialized){
        Initialize-WorkCtlResources
    }

    $cpu=Get-WorkCtlCPU
    $mem=Get-WorkCtlMemory
    $gpu=Get-WorkCtlGPU
    $net=Get-WorkCtlNetwork
    $bat=Get-WorkCtlBattery
    $disks=@(Get-WorkCtlDisks)

    [PSCustomObject]@{
        Timestamp=Get-Date
        CPU=$cpu
        Memory=$mem
        GPU=$gpu
        Network=$net
        Battery=$bat
        Disks=$disks
    }
}

function Write-WorkCtlResourceScreen {

    param(
        $Snapshot,
        [int]$Top=8
    )

    $s=$Snapshot

    Write-Host "===============================================================" -ForegroundColor DarkCyan
    Write-Host "                    WORKCTL LIVE RESOURCES" -ForegroundColor Cyan
    Write-Host "===============================================================" -ForegroundColor DarkCyan

    Write-Host (" {0}" -f $s.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")) `
        -ForegroundColor DarkGray

    Write-Host ""

    # CPU
    if($s.CPU.Available){
        Write-Host (" CPU   {0,5:N1}%" -f $s.CPU.UsagePercent) `
            -ForegroundColor Green
    }else{
        Write-Host " CPU     N/A" -ForegroundColor Yellow
    }

    # RAM
    if($s.Memory.Available){

        Write-Host (
            " RAM   {0,5:N2} / {1:N2} GB   FREE {2:N2} GB   {3:N1}%" -f
            $s.Memory.UsedGB,
            $s.Memory.TotalGB,
            $s.Memory.FreeGB,
            $s.Memory.UsedPercent
        ) -ForegroundColor Green

    }else{
        Write-Host " RAM     N/A" -ForegroundColor Yellow
    }

    # GPU
    if($s.GPU.Available){

        Write-Host (
            " GPU   {0,5:N1}%   {1:N0} C   VRAM {2:N0}/{3:N0} MB   {4:N1} W" -f
            $s.GPU.UsagePercent,
            $s.GPU.TemperatureC,
            $s.GPU.VRAMUsedMB,
            $s.GPU.VRAMTotalMB,
            $s.GPU.PowerW
        ) -ForegroundColor Green

    }else{
        Write-Host " GPU     N/A" -ForegroundColor Yellow
    }

    # Network
    if($s.Network.Available){

        Write-Host (
            " NET   DOWN {0,8:N2} Mbps   UP {1,8:N2} Mbps" -f
            $s.Network.DownloadMbps,
            $s.Network.UploadMbps
        ) -ForegroundColor Green
    }

    # Battery
    if($s.Battery.Available){

        $power=if($s.Battery.AC){"AC"}else{"BATTERY"}

        Write-Host (
            " PWR   {0,3}%   {1}" -f
            $s.Battery.Percent,
            $power
        ) -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "-- STORAGE ----------------------------------------------------" `
        -ForegroundColor DarkGray

    foreach($d in @($s.Disks)){

        Write-Host (
            " {0,-3} {1,6:N1} GB free / {2,6:N1} GB   {3,5:N1}% used" -f
            $d.Drive,
            $d.FreeGB,
            $d.TotalGB,
            $d.UsedPercent
        )
    }

    Write-Host ""
    Write-Host "-- TOP MEMORY -------------------------------------------------" `
        -ForegroundColor DarkGray

    $topRows=@(Get-WorkCtlTopProcesses -Count $Top)

    foreach($p in $topRows){

        Write-Host (
            " {0,-24} {1,8:N1} MB   PID {2}" -f
            $p.Name,
            $p.RAM_MB,
            $p.PID
        )
    }

    Write-Host ""
    Write-Host " [Q] Exit live resources" -ForegroundColor Yellow
}

function Get-WorkCtlResourceFrame {

    param(
        $Snapshot,
        [int]$Top=8
    )

    $s=$Snapshot
    $lines=New-Object System.Collections.Generic.List[string]

    $lines.Add("===============================================================")
    $lines.Add("                    WORKCTL LIVE RESOURCES")
    $lines.Add("===============================================================")
    $lines.Add((" {0}" -f $s.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")))
    $lines.Add("")

    if($s.CPU.Available){
        $lines.Add((" CPU   {0,5:N1}%" -f $s.CPU.UsagePercent))
    }else{
        $lines.Add(" CPU     N/A")
    }

    if($s.Memory.Available){

        $lines.Add((
            " RAM   {0,5:N2} / {1:N2} GB   FREE {2:N2} GB   {3:N1}%" -f
            $s.Memory.UsedGB,
            $s.Memory.TotalGB,
            $s.Memory.FreeGB,
            $s.Memory.UsedPercent
        ))

    }else{
        $lines.Add(" RAM     N/A")
    }

    if($s.GPU.Available){

        $lines.Add((
            " GPU   {0,5:N1}%   {1:N0} C   VRAM {2:N0}/{3:N0} MB   {4:N1} W" -f
            $s.GPU.UsagePercent,
            $s.GPU.TemperatureC,
            $s.GPU.VRAMUsedMB,
            $s.GPU.VRAMTotalMB,
            $s.GPU.PowerW
        ))

    }else{
        $lines.Add(" GPU     N/A")
    }

    if($s.Network.Available){

        # Use KB/s for low traffic so 0.00 Mbps doesn't hide activity.
        if($s.Network.DownloadMbps -lt 1){
            $down="{0:N0} KB/s" -f ($s.Network.DownloadMbps*128)
        }else{
            $down="{0:N2} Mbps" -f $s.Network.DownloadMbps
        }

        if($s.Network.UploadMbps -lt 1){
            $up="{0:N0} KB/s" -f ($s.Network.UploadMbps*128)
        }else{
            $up="{0:N2} Mbps" -f $s.Network.UploadMbps
        }

        $lines.Add((
            " NET   DOWN {0,12}   UP {1,12}" -f $down,$up
        ))
    }

    if($s.Battery.Available){

        $power=if($s.Battery.AC){"AC"}else{"BATTERY"}

        $lines.Add((
            " PWR   {0,3}%   {1}" -f
            $s.Battery.Percent,
            $power
        ))
    }

    $lines.Add("")
    $lines.Add("-- STORAGE ----------------------------------------------------")

    foreach($d in @($s.Disks)){

        $lines.Add((
            " {0,-3} {1,6:N1} GB free / {2,6:N1} GB   {3,5:N1}% used" -f
            $d.Drive,
            $d.FreeGB,
            $d.TotalGB,
            $d.UsedPercent
        ))
    }

    $lines.Add("")
    $lines.Add("-- TOP MEMORY -------------------------------------------------")

    $topRows=@(Get-WorkCtlTopProcesses -Count $Top)

    foreach($p in $topRows){

        $lines.Add((
            " {0,-24} {1,8:N1} MB   PID {2}" -f
            $p.Name,
            $p.RAM_MB,
            $p.PID
        ))
    }

    $lines.Add("")
    $lines.Add(" [Q] Exit live resources")

    return @($lines)
}

function Write-WorkCtlFrame {

    param(
        [string[]]$Lines,
        [int]$Top,
        [int]$PreviousHeight
    )

    try{
        [Console]::SetCursorPosition(0,$Top)
    }catch{
        return $PreviousHeight
    }

    $width=[math]::Max(20,[Console]::BufferWidth-1)

    $height=[math]::Max(
        $Lines.Count,
        $PreviousHeight
    )

    for($i=0;$i -lt $height;$i++){

        if($i -lt $Lines.Count){
            $line=$Lines[$i]
        }else{
            $line=""
        }

        # Prevent wrapping, which would destroy cursor positioning.
        if($line.Length -gt $width){
            $line=$line.Substring(0,$width)
        }

        Write-Host $line.PadRight($width) -NoNewline

        if($i -lt ($height-1)){
            Write-Host ""
        }
    }

    return $Lines.Count
}

function Watch-WorkCtlResources {

    param(
        [double]$Interval=1.0,
        [int]$Top=8
    )

    if($Interval -lt 0.5){
        $Interval=0.5
    }

    Initialize-WorkCtlResources

    Start-Sleep -Milliseconds 500

    Clear-Host

    $originTop=[Console]::CursorTop
    $previousHeight=0

    try{

        try{
            [Console]::CursorVisible=$false
        }catch{}

        while($true){

            $started=[datetime]::UtcNow

            $snapshot=Get-WorkCtlSnapshot
            $frame=@(
                Get-WorkCtlResourceFrame `
                    -Snapshot $snapshot `
                    -Top $Top
            )

            $previousHeight=Write-WorkCtlFrame `
                -Lines $frame `
                -Top $originTop `
                -PreviousHeight $previousHeight

            $elapsed=(
                [datetime]::UtcNow-$started
            ).TotalMilliseconds

            $wait=[math]::Max(
                0,
                ($Interval*1000)-$elapsed
            )

            $until=[datetime]::UtcNow.AddMilliseconds($wait)

            while([datetime]::UtcNow -lt $until){

                if([Console]::KeyAvailable){

                    $k=[Console]::ReadKey($true)

                    if($k.Key -eq [ConsoleKey]::Q){
                        return
                    }
                }

                Start-Sleep -Milliseconds 25
            }
        }

    }finally{

        try{
            [Console]::CursorVisible=$true
        }catch{}

        try{
            [Console]::SetCursorPosition(
                0,
                $originTop+$previousHeight
            )
        }catch{}

        Write-Host ""
    }
}
function Stop-WorkCtlResources {

    if($script:CpuCounter){

        try{
            $script:CpuCounter.Dispose()
        }catch{}

        $script:CpuCounter=$null
    }

    $script:ResInitialized=$false
}

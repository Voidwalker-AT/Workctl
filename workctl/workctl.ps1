param(
    [Parameter(Position=0)]
    [ValidateSet(
        "menu","status","list","info","help",
        "start","stop","restart",
        "start-group","stop-group","restart-group",
        "groups","protected","doctor","quiet","stop-all",
        "powertoys","pt","resources","res","monitor","media",
        "shell","workloads","wl","tools","processes","ps","services","network","storage","projects"
    )]
    [string]$Action="menu",

    [Parameter(Position=1)]
    [string]$Target,

    [switch]$Apply
)

$ErrorActionPreference="Stop"

$Version="1.5.0"
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir=Join-Path $Root "logs"

if(!(Test-Path $LogDir)){
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
}

$Log=Join-Path $LogDir ("workctl_{0}.log" -f (Get-Date -Format "yyyy-MM"))

# ================================================================
# COMPONENT REGISTRY
# ================================================================

$Components=[ordered]@{

    mysql=@{
        Label="MySQL 8"
        Type="service"
        Service="MySQL80"
        Mode="Manual"
        Groups=@("dev","database","quiet")
        Description="Local MySQL database server."
        Admin=$true
    }

    docker=@{
        Label="Docker Desktop"
        Type="docker"
        StartPath="C:\Program Files\Docker\Docker\Docker Desktop.exe"
        Mode="On-demand"
        Groups=@("dev","containers","quiet")
        Description="Docker Desktop, Docker Engine, Compose and WSL2 container backend."
        Admin=$false
    }

    ollama=@{
        Label="Ollama"
        Type="app"
        StartPath="E:\OllamaApp\ollama app.exe"
        Processes=@("ollama","ollama app")
        Mode="On-demand"
        Groups=@("ai","local-ai","quiet")
        Description="Local AI model runtime."
        Admin=$false
    }

    openclaw=@{
        Label="OpenClaw Gateway"
        Type="openclaw"
        TaskPath="\"
        TaskName="OpenClaw Gateway"
        Mode="Autostart OFF"
        Groups=@("ai","agents","quiet")
        Description="Local OpenClaw agent gateway."
        Admin=$true
    }

    omniroute=@{
        Label="OmniRoute"
        Type="omniroute"
        Mode="On-demand"
        Groups=@("local-ai","routing","quiet")
        Description="Local AI router and provider fallback server."
        Admin=$false
    }

    onedrive=@{
        Label="Microsoft OneDrive"
        Type="app"
        StartPath="C:\Program Files\Microsoft OneDrive\OneDrive.exe"
        Processes=@("OneDrive","OneDrive.Sync.Service")
        Mode="On-demand"
        Groups=@("cloud","quiet")
        Description="Microsoft OneDrive synchronization client."
        Admin=$false
    }

    discord=@{
        Label="Discord"
        Type="app"
        StartPath="C:\Users\hp\AppData\Local\Discord\Update.exe"
        StartArgs=@("--processStart","Discord.exe")
        Processes=@("Discord")
        Mode="On-demand"
        Groups=@("social","quiet")
        Description="Discord desktop client."
        Admin=$false
    }

    steam=@{
        Label="Steam"
        Type="app"
        StartPath="C:\Program Files (x86)\Steam\steam.exe"
        Processes=@("steam","steamwebhelper","GameOverlayUI")
        Mode="On-demand"
        Groups=@("gaming","quiet")
        Description="Steam client and its helper processes."
        Admin=$false
    }

    screenrec=@{
        Label="ScreenRec"
        Type="app"
        StartPath="C:\Users\hp\AppData\Local\StreamingVideoProvider\ScreenRec_app\screenrec.exe"
        Processes=@("screenrec")
        Mode="On-demand"
        Groups=@("capture","quiet")
        Description="Screen recording and capture application."
        Admin=$false
    }

    dsa=@{
        Label="Intel Driver & Support Assistant"
        Type="service-group"
        Services=@("DSAService","DSAUpdateService")
        Mode="Manual"
        Groups=@("maintenance")
        Description="Intel driver/update maintenance services."
        Admin=$true
    }

    monect=@{
        Label="Monect Remote"
        Type="service"
        Service="MonectServerService"
        Mode="Manual"
        Groups=@("remote","quiet")
        Description="PC Remote Receiver / Monect remote-control server."
        Admin=$true
    }
}

$Protected=@(
    "Google Drive",
    "Windows Defender",
    "NVIDIA Display Container",
    "Realtek Audio",
    "HP System Event Utility",
    "WSL"
)

# ================================================================
# UI HELPERS
# ================================================================

function H1($Text){
    Write-Host ""
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * $Text.Length) -ForegroundColor DarkCyan
}

function H2($Text){
    Write-Host ""
    Write-Host ("-- {0} " -f $Text) -NoNewline -ForegroundColor Magenta
    Write-Host ("-" * [math]::Max(1,52-$Text.Length)) -ForegroundColor DarkGray
}

function Write-State($State){

    switch($State){
        "RUNNING"     {Write-Host $State -ForegroundColor Green}
        "STOPPED"     {Write-Host $State -ForegroundColor Yellow}
        "DEGRADED"    {Write-Host $State -ForegroundColor Red}
        "UNAVAILABLE" {Write-Host $State -ForegroundColor Red}
        default       {Write-Host $State -ForegroundColor White}
    }
}

function Cmd($Command,$Description,$Risk="SAFE"){

    switch($Risk){
        "SAFE"  {$col="Green"}
        "WRITE" {$col="Yellow"}
        "FORCE" {$col="Red"}
        default {$col="White"}
    }

    Write-Host ("  [{0,-5}] " -f $Risk) -NoNewline -ForegroundColor $col
    Write-Host $Command -ForegroundColor White
    Write-Host "          $Description" -ForegroundColor DarkGray
}

function Write-Log($Message){
    Add-Content -LiteralPath $Log -Value (
        "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$Message
    )
}

function Test-Admin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=New-Object Security.Principal.WindowsPrincipal($id)

    return $p.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Require-Admin($Reason){
    if(!(Test-Admin)){
        throw "$Reason requires Administrator PowerShell."
    }
}

function Get-Component($Name){

    if(!$Name){
        throw "Component name required."
    }

    $key=$Name.ToLowerInvariant()

    if(!$Components.Contains($key)){
        throw "Unknown component: $Name"
    }

    @{
        Key=$key
        Data=$Components[$key]
    }
}

function Get-AppProcesses($Component){

    $r=@()

    foreach($pn in @($Component.Processes)){
        $r += @(Get-Process -Name $pn -ErrorAction SilentlyContinue)
    }

    @($r | Sort-Object Id -Unique)
}

function Get-OpenClawProcesses {

    @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq "node.exe" -and
            $_.CommandLine -like "*openclaw*dist*index.js*gateway*"
        }
    )
}

function Get-OmniProcesses {

    @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq "node.exe" -and (
                $_.CommandLine -like "*omniroute.mjs*" -or
                $_.CommandLine -like "*omniroute*server-ws.mjs*"
            )
        }
    )
}

function Get-GroupMembers($Group){

    $r=@()

    foreach($key in $Components.Keys){
        if(@($Components[$key].Groups) -contains $Group){
            $r += $key
        }
    }

    $r
}

# ================================================================
# STATE
# ================================================================

function Get-State($Key,$Component){

    switch($Component.Type){

        "service" {
            $s=Get-Service $Component.Service -ErrorAction SilentlyContinue

            if(!$s){return "UNAVAILABLE"}
            if($s.Status -eq "Running"){return "RUNNING"}

            return "STOPPED"
        }

        "service-group" {

            $found=0
            $running=0

            foreach($sn in $Component.Services){

                $s=Get-Service $sn -ErrorAction SilentlyContinue

                if($s){
                    $found++

                    if($s.Status -eq "Running"){
                        $running++
                    }
                }
            }

            if($found -eq 0){return "UNAVAILABLE"}
            if($running -gt 0){return "RUNNING"}

            return "STOPPED"
        }

        "docker" {

            if(!(Get-Command docker -ErrorAction SilentlyContinue)){
                return "UNAVAILABLE"
            }

            if(Get-Process "Docker Desktop" -ErrorAction SilentlyContinue){
                return "RUNNING"
            }

            return "STOPPED"
        }

        "openclaw" {

            if(!(Get-Command openclaw -ErrorAction SilentlyContinue)){
                return "UNAVAILABLE"
            }

            if((Get-OpenClawProcesses).Count -gt 0){
                return "RUNNING"
            }

            return "STOPPED"
        }

        "omniroute" {

            if(!(Get-Command omniroute -ErrorAction SilentlyContinue)){
                return "UNAVAILABLE"
            }

            if((Get-OmniProcesses).Count -gt 0){
                return "RUNNING"
            }

            return "STOPPED"
        }

        "app" {

            if(!(Test-Path -LiteralPath $Component.StartPath)){
                return "UNAVAILABLE"
            }

            if((Get-AppProcesses $Component).Count -gt 0){
                return "RUNNING"
            }

            return "STOPPED"
        }

        default {
            return "UNAVAILABLE"
        }
    }
}

# ================================================================
# RESOURCE INFO
# ================================================================

function Get-SystemSummary {

    $os=Get-CimInstance Win32_OperatingSystem

    [PSCustomObject]@{
        TotalRAM=[math]::Round($os.TotalVisibleMemorySize/1MB,1)
        UsedRAM=[math]::Round(
            ($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/1MB,1
        )
        FreeRAM=[math]::Round($os.FreePhysicalMemory/1MB,1)
        CFree=[math]::Round((Get-PSDrive C).Free/1GB,1)
        Admin=(Test-Admin)
    }
}

function Get-ManagedCounts {

    $run=0
    $stop=0
    $warn=0

    foreach($k in $Components.Keys){

        switch(Get-State $k $Components[$k]){
            "RUNNING" {$run++}
            "STOPPED" {$stop++}
            default   {$warn++}
        }
    }

    @{
        Running=$run
        Stopped=$stop
        Warnings=$warn
    }
}

# ================================================================
# STATUS
# ================================================================

function Show-Status($Only){

    if($Only){
        Show-Info $Only
        return
    }

    H1 "WORKSTATION STATUS"

    $sys=Get-SystemSummary
    $cnt=Get-ManagedCounts

    Write-Host "RAM  " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($sys.UsedRAM)/$($sys.TotalRAM) GB" -NoNewline -ForegroundColor White
    Write-Host "   FREE " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($sys.FreeRAM) GB" -NoNewline -ForegroundColor Green
    Write-Host "   C: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($sys.CFree) GB free" -ForegroundColor White

    Write-Host "RUNNING " -NoNewline -ForegroundColor DarkGray
    Write-Host $cnt.Running -NoNewline -ForegroundColor Green
    Write-Host "   STOPPED " -NoNewline -ForegroundColor DarkGray
    Write-Host $cnt.Stopped -NoNewline -ForegroundColor Yellow
    Write-Host "   WARN " -NoNewline -ForegroundColor DarkGray
    Write-Host $cnt.Warnings -ForegroundColor Red

    H2 "MANAGED WORKLOADS"

    Write-Host ("{0,-12}{1,-14}{2,-16}{3}" -f `
        "COMPONENT","STATE","MODE","GROUPS") -ForegroundColor White

    foreach($key in $Components.Keys){

        $c=$Components[$key]
        $state=Get-State $key $c

        Write-Host ("{0,-12}" -f $key) -NoNewline

        switch($state){
            "RUNNING" {
                Write-Host ("{0,-14}" -f $state) -NoNewline -ForegroundColor Green
            }
            "STOPPED" {
                Write-Host ("{0,-14}" -f $state) -NoNewline -ForegroundColor Yellow
            }
            default {
                Write-Host ("{0,-14}" -f $state) -NoNewline -ForegroundColor Red
            }
        }

        Write-Host ("{0,-16}" -f $c.Mode) -NoNewline -ForegroundColor DarkGray
        Write-Host (@($c.Groups) -join ",") -ForegroundColor Magenta
    }
}

# ================================================================
# START
# ================================================================

function Start-Component($Name){

    $x=Get-Component $Name
    $key=$x.Key
    $c=$x.Data

    $state=Get-State $key $c

    if($state -eq "RUNNING"){
        Write-Host "$($c.Label) already running." -ForegroundColor Green
        return
    }

    if($state -eq "UNAVAILABLE"){
        throw "$($c.Label) is unavailable."
    }

    if($c.Admin){
        Require-Admin "Starting $key"
    }

    switch($c.Type){

        "service" {
            Start-Service $c.Service
        }

        "service-group" {
            foreach($sn in $c.Services){
                Start-Service $sn
            }
        }

        "docker" {

            & docker desktop start

            if($LASTEXITCODE -ne 0){
                throw "Docker Desktop start failed."
            }
        }

        "openclaw" {

            $t=Get-ScheduledTask `
                -TaskPath $c.TaskPath `
                -TaskName $c.TaskName `
                -ErrorAction SilentlyContinue

            $disabled=$false

            if($t -and $t.State -eq "Disabled"){
                $disabled=$true

                Enable-ScheduledTask `
                    -TaskPath $c.TaskPath `
                    -TaskName $c.TaskName |
                    Out-Null
            }

            & openclaw gateway start

            $ec=$LASTEXITCODE

            Start-Sleep -Milliseconds 600

            if($disabled){
                Disable-ScheduledTask `
                    -TaskPath $c.TaskPath `
                    -TaskName $c.TaskName |
                    Out-Null
            }

            if($ec -ne 0){
                throw "OpenClaw start failed."
            }
        }

        "omniroute" {

            Start-Process `
                -FilePath "C:\Program Files\nodejs\omniroute.cmd" `
                -ArgumentList @("serve","--daemon","--no-open") `
                -WindowStyle Hidden

            Start-Sleep -Seconds 2

            if((Get-OmniProcesses).Count -eq 0){
                throw "OmniRoute did not start."
            }
        }

        "app" {

            if($c.ContainsKey("StartArgs")){
                Start-Process `
                    -FilePath $c.StartPath `
                    -ArgumentList $c.StartArgs
            }else{
                Start-Process -FilePath $c.StartPath
            }
        }
    }

    Write-Log "START $key"
    Write-Host "START requested: $($c.Label)" -ForegroundColor Green
}

# ================================================================
# STOP
# ================================================================

function Stop-Component($Name,[switch]$ForceApply){

    $x=Get-Component $Name
    $key=$x.Key
    $c=$x.Data

    if((Get-State $key $c) -eq "STOPPED"){
        Write-Host "$($c.Label) already stopped." -ForegroundColor DarkGray
        return
    }

    if($c.Admin){
        Require-Admin "Stopping $key"
    }

    switch($c.Type){

        "service" {
            Stop-Service $c.Service
        }

        "service-group" {
            foreach($sn in $c.Services){

                $s=Get-Service $sn -ErrorAction SilentlyContinue

                if($s -and $s.Status -ne "Stopped"){
                    Stop-Service $sn
                }
            }
        }

        "docker" {

            & docker desktop stop

            if($LASTEXITCODE -ne 0){
                throw "Docker Desktop stop failed."
            }
        }

        "openclaw" {

            & openclaw gateway stop

            if($LASTEXITCODE -ne 0){
                throw "OpenClaw stop failed."
            }

            $t=Get-ScheduledTask `
                -TaskPath $c.TaskPath `
                -TaskName $c.TaskName `
                -ErrorAction SilentlyContinue

            if($t -and $t.State -ne "Disabled"){
                Disable-ScheduledTask `
                    -TaskPath $c.TaskPath `
                    -TaskName $c.TaskName |
                    Out-Null
            }
        }

        "omniroute" {

            # Kill only an old tray supervisor if one somehow exists.
            $tray=@(
                Get-CimInstance Win32_Process |
                Where-Object {
                    $_.Name -eq "node.exe" -and
                    $_.CommandLine -like "*omniroute.mjs*" -and
                    $_.CommandLine -like "*--tray*"
                }
            )

            foreach($p in $tray){
                Stop-Process -Id $p.ProcessId -Force
            }

            & omniroute stop

            if($LASTEXITCODE -ne 0){
                throw "OmniRoute stop failed."
            }

            Start-Sleep -Seconds 1
        }

        "app" {

            $ps=Get-AppProcesses $c

            foreach($p in $ps){
                if($p.MainWindowHandle -ne 0){
                    $null=$p.CloseMainWindow()
                }
            }

            Start-Sleep -Seconds 2

            $left=Get-AppProcesses $c

            if($left.Count -gt 0){

                if($ForceApply){

                    foreach($p in $left){
                        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                    }

                    Write-Host "Forced remaining $key processes closed." `
                        -ForegroundColor Red

                }else{

                    Write-Host "$key still has $($left.Count) process(es)." `
                        -ForegroundColor Yellow

                    Write-Host "Force if required:" -ForegroundColor DarkGray
                    Write-Host "  workctl stop $key -Apply" -ForegroundColor Red
                }
            }
        }
    }

    Write-Log "STOP $key FORCE=$ForceApply"
    Write-Host "STOP requested: $($c.Label)" -ForegroundColor Green
}

# ================================================================
# RESTART
# ================================================================

function Restart-Component($Name){

    $x=Get-Component $Name
    $key=$x.Key
    $c=$x.Data

    if($c.Admin){
        Require-Admin "Restarting $key"
    }

    switch($c.Type){

        "docker" {
            & docker desktop restart
            if($LASTEXITCODE -ne 0){throw "Docker restart failed."}
        }

        "openclaw" {
            Stop-Component openclaw
            Start-Sleep -Seconds 1
            Start-Component openclaw
        }

        "omniroute" {
            Stop-Component omniroute
            Start-Sleep -Seconds 1
            Start-Component omniroute
        }

        default {

            Stop-Component $key -ForceApply:$Apply
            Start-Sleep -Seconds 1

            if(
                $c.Type -eq "app" -and
                !$Apply -and
                (Get-State $key $c) -eq "RUNNING"
            ){
                throw "$($c.Label) did not stop. Use restart $key -Apply if appropriate."
            }

            Start-Component $key
        }
    }

    Write-Log "RESTART $key"
    Write-Host "RESTART requested: $($c.Label)" -ForegroundColor Green
}

# ================================================================
# GROUPS
# ================================================================

function Test-Group($Group,$Operation){

    $members=@(Get-GroupMembers $Group)

    if($members.Count -eq 0){
        throw "Unknown group: $Group"
    }

    $problems=@()

    foreach($m in $members){

        $c=$Components[$m]
        $state=Get-State $m $c

        if($Operation -in @("start","restart")){

            if($state -eq "UNAVAILABLE"){
                $problems += "$m unavailable"
            }

            if($c.Admin -and !(Test-Admin)){
                $problems += "$m requires Administrator PowerShell"
            }
        }

        if(
            $Operation -eq "stop" -and
            $state -eq "RUNNING" -and
            $c.Admin -and
            !(Test-Admin)
        ){
            $problems += "$m requires Administrator PowerShell"
        }
    }

    @{
        Members=$members
        Problems=$problems
    }
}

function Invoke-Group($Group,$Operation){

    $p=Test-Group $Group $Operation

    if($p.Problems.Count -gt 0){

        Write-Host "`nGROUP PREFLIGHT FAILED" -ForegroundColor Red

        foreach($e in $p.Problems){
            Write-Host "  $e" -ForegroundColor Red
        }

        Write-Host "Nothing changed." -ForegroundColor Yellow
        return
    }

    H2 "$($Operation.ToUpperInvariant()) GROUP :: $Group"

    foreach($m in $p.Members){

        switch($Operation){
            "start"   {Start-Component $m}
            "stop"    {Stop-Component $m}
            "restart" {Restart-Component $m}
        }
    }
}

# ================================================================
# QUIET
# ================================================================

function Invoke-Quiet {

    $members=@(Get-GroupMembers "quiet")

    H1 "QUIET MODE"

    foreach($m in $members){

        $state=Get-State $m $Components[$m]

        Write-Host ("  {0,-14}" -f $m) -NoNewline

        if($state -eq "RUNNING"){
            Write-Host $state -ForegroundColor Green
        }else{
            Write-Host $state -ForegroundColor Yellow
        }
    }

    if(!$Apply){

        Write-Host ""
        Write-Host "PREVIEW ONLY" -ForegroundColor Green
        Write-Host "Apply with: workctl quiet -Apply" -ForegroundColor Yellow
        return
    }

    foreach($m in $members){

        if((Get-State $m $Components[$m]) -ne "RUNNING"){
            continue
        }

        if($Components[$m].Admin -and !(Test-Admin)){
            Write-Host "[SKIP] $m requires Administrator" -ForegroundColor Yellow
            continue
        }

        try{
            Stop-Component $m
        }catch{
            Write-Host "[WARN] $m : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Log "QUIET APPLY"
}

# ================================================================
# STOP ALL
# ================================================================

function Invoke-StopAll {

    $running=@()

    foreach($k in $Components.Keys){
        if((Get-State $k $Components[$k]) -eq "RUNNING"){
            $running += $k
        }
    }

    H1 "STOP ALL MANAGED WORKLOADS"

    if($running.Count -eq 0){
        Write-Host "Nothing managed is currently running." -ForegroundColor Green
        return
    }

    Write-Host "Currently running:" -ForegroundColor Yellow

    foreach($k in $running){
        Write-Host "  $k" -ForegroundColor White
    }

    H2 "PROTECTED / UNTOUCHED"

    foreach($p in $Protected){
        Write-Host "  $p" -ForegroundColor Green
    }

    if(!$Apply){

        Write-Host ""
        $ans=(Read-Host "Stop $($running.Count) managed workload(s)? [y/N]").Trim()

        if($ans -notmatch "^[Yy]$"){
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }
    }

    foreach($k in $running){

        $c=$Components[$k]

        if($c.Admin -and !(Test-Admin)){
            Write-Host "[SKIP] $k requires Administrator" -ForegroundColor Yellow
            continue
        }

        try{
            # Never force from Stop All.
            Stop-Component $k
        }catch{
            Write-Host "[WARN] $k : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Log "STOP-ALL"
}

# ================================================================
# DOCTOR
# ================================================================

function Show-Doctor {

    H1 "WORKCTL DOCTOR"

    $counts=@{
        PASS=0
        WARN=0
        FAIL=0
    }

    function Check($Level,$Name,$Detail){

        $counts[$Level]++

        switch($Level){
            "PASS" {$col="Green"}
            "WARN" {$col="Yellow"}
            "FAIL" {$col="Red"}
        }

        Write-Host ("  [{0,-4}] " -f $Level) -NoNewline -ForegroundColor $col
        Write-Host $Name

        if($Detail){
            Write-Host "         $Detail" -ForegroundColor DarkGray
        }
    }

    $shim="$env:USERPROFILE\scoop\shims\workctl.cmd"

    if(Test-Path $shim){
        Check PASS "Global workctl" $shim
    }else{
        Check FAIL "Global workctl" "Shim missing"
    }

    foreach($key in $Components.Keys){

        $c=$Components[$key]
        $state=Get-State $key $c

        if($state -eq "UNAVAILABLE"){
            Check FAIL $c.Label "Component dependency/executable unavailable"
        }else{
            Check PASS $c.Label "State=$state; Mode=$($c.Mode)"
        }
    }

    $startup="$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"

    $omniStartup=@(
        Get-ChildItem $startup -Force -ErrorAction SilentlyContinue |
        Where-Object {$_.Name -match "OmniRoute"}
    )

    if($omniStartup.Count -eq 0){
        Check PASS "OmniRoute autostart" "No Startup-folder launcher"
    }else{
        Check WARN "OmniRoute autostart" "Startup launcher still exists"
    }

    $ot=Get-ScheduledTask `
        -TaskName "OpenClaw Gateway" `
        -ErrorAction SilentlyContinue

    if($ot -and $ot.State -eq "Disabled"){
        Check PASS "OpenClaw autostart" "Registered and disabled"
    }elseif($ot){
        Check WARN "OpenClaw autostart" "Task state=$($ot.State)"
    }else{
        Check FAIL "OpenClaw autostart" "Task missing"
    }

    $mon=Get-CimInstance Win32_Service `
        -Filter "Name='MonectServerService'" `
        -ErrorAction SilentlyContinue

    if(!$mon){
        Check FAIL "Monect startup mode" "Service missing"
    }elseif($mon.StartMode -eq "Manual"){
        Check PASS "Monect startup mode" "Manual"
    }else{
        Check WARN "Monect startup mode" "Current=$($mon.StartMode)"
    }

    $tera="E:\TeraBoxDownload\TeraBox\TeraBox\TeraBox.exe"

    if(Test-Path $tera){
        Check PASS "TeraBox installation" $tera
    }else{
        Check WARN "TeraBox stale installation" "Registered installation target is missing"
    }

    if(!$Components.Contains("googledrive")){
        Check PASS "Google Drive protection" "Not in managed registry"
    }else{
        Check FAIL "Google Drive protection" "Unexpectedly managed"
    }

    H2 "SUMMARY"

    Write-Host "  PASS : $($counts.PASS)" -ForegroundColor Green
    Write-Host "  WARN : $($counts.WARN)" -ForegroundColor Yellow
    Write-Host "  FAIL : $($counts.FAIL)" -ForegroundColor Red

    Write-Host ""
    Write-Host "Doctor is READ-ONLY." -ForegroundColor Green
}

# ================================================================
# INFO / GROUPS / PROTECTED
# ================================================================

function Show-Info($Name){

    $x=Get-Component $Name
    $key=$x.Key
    $c=$x.Data
    $state=Get-State $key $c

    H1 "WORKCTL :: $($key.ToUpperInvariant())"

    Write-Host "Label       : $($c.Label)"
    Write-Host "State       : " -NoNewline
    Write-State $state
    Write-Host "Mode        : $($c.Mode)" -ForegroundColor Cyan
    Write-Host "Groups      : $(@($c.Groups) -join ', ')" -ForegroundColor Magenta
    Write-Host "Purpose     : $($c.Description)" -ForegroundColor DarkGray

    if($c.Admin){
        Write-Host "Privileges  : Administrator required" -ForegroundColor Yellow
    }else{
        Write-Host "Privileges  : Normal PowerShell" -ForegroundColor Green
    }

    if($c.Type -eq "docker"){
        Write-Host "Lifecycle   : docker desktop start/stop/restart" -ForegroundColor DarkGray
    }

    if($c.Type -eq "openclaw"){
        Write-Host "Lifecycle   : openclaw gateway start/stop" -ForegroundColor DarkGray
        Write-Host "Autostart   : OFF" -ForegroundColor Green
    }

    if($c.Type -eq "omniroute"){
        Write-Host "Start       : omniroute serve --daemon --no-open" -ForegroundColor DarkGray
        Write-Host "Stop        : omniroute stop" -ForegroundColor DarkGray
        Write-Host "Autostart   : OFF" -ForegroundColor Green
    }

    H2 "COMMANDS"

    Cmd "workctl start $key" "Start this workload." WRITE
    Cmd "workctl stop $key" "Gracefully stop this workload." WRITE
    Cmd "workctl restart $key" "Restart this workload." WRITE

    if($c.Type -eq "app"){
        Cmd "workctl stop $key -Apply" `
            "Force remaining managed processes if normal stop fails." FORCE
    }
}

function Show-Groups {

    H1 "WORKCTL GROUPS"

    foreach($g in @(
        "ai","local-ai","dev","database","containers",
        "agents","routing","cloud","social","gaming",
        "capture","maintenance","remote","quiet"
    )){
        Write-Host ("  {0,-14}" -f $g) -NoNewline -ForegroundColor Magenta
        Write-Host ((Get-GroupMembers $g) -join ", ") -ForegroundColor DarkGray
    }
}

function Show-Protected {

    H1 "PROTECTED / UNMANAGED"

    foreach($p in $Protected){
        Write-Host "  [PROTECTED] " -NoNewline -ForegroundColor Green
        Write-Host $p
    }

    Write-Host ""
    Write-Host "WorkCtl will never target these through group/stop-all operations." `
        -ForegroundColor DarkGray
}

# ================================================================
# HELP
# ================================================================

function Show-Help {

    H1 "WORKSTATION CONTROL v$Version"

    Write-Host "Global on-demand workload controller." -ForegroundColor DarkGray

    H2 "INTERACTIVE DASHBOARD & TUIS"

    Cmd "workctl" "Open the interactive dashboard." SAFE
    Cmd "workctl pt (powertoys)" "PowerToys 34-utility keyboard-driven TUI control plane." SAFE
    Cmd "workctl media" "Smart Media & Tool Control Plane (VLC, Sonarr, Torlink)." SAFE
    Cmd "workctl res (resources, monitor)" "Real-time CPU/RAM/GPU/Network resource monitor." SAFE

    H2 "INSPECTION"

    Cmd "workctl status" "Show managed workload status and resource summary." SAFE
    Cmd "workctl status <component>" "Show one component in detail." SAFE
    Cmd "workctl info <component>" "Show lifecycle and purpose." SAFE
    Cmd "workctl doctor" "Read-only configuration/dependency audit." SAFE
    Cmd "workctl groups" "Show workload groups." SAFE
    Cmd "workctl protected" "Show components WorkCtl never manages." SAFE

    H2 "CONTROL"

    Cmd "workctl start <component>" "Start one workload." WRITE
    Cmd "workctl stop <component>" "Gracefully stop one workload." WRITE
    Cmd "workctl restart <component>" "Restart one workload." WRITE

    Cmd "workctl start-group ai" "Start Ollama + OpenClaw." WRITE
    Cmd "workctl start-group local-ai" "Start Ollama + OmniRoute." WRITE
    Cmd "workctl start-group dev" "Start MySQL + Docker." WRITE

    H2 "RESOURCE CONTROL"

    Cmd "workctl quiet" "Preview Quiet Mode." SAFE
    Cmd "workctl quiet -Apply" "Gracefully stop quiet-group workloads." WRITE
    Cmd "workctl stop-all" "Review and confirm stopping all managed workloads." WRITE
    Cmd "workctl stop-all -Apply" "Stop all managed workloads without prompt." WRITE

    Write-Host ""
    Write-Host "NOTE: stop-all -Apply does NOT mean force-kill." -ForegroundColor Green
    Write-Host "Force remains component-specific." -ForegroundColor DarkGray
}

# ================================================================
# MENU
# ================================================================

function Pause-Menu {
    Write-Host ""
    $null=Read-Host "Press Enter to continue"
}

function Invoke-ComponentMenu($Key){

    while($true){

        Clear-Host

        $c=$Components[$Key]
        $state=Get-State $Key $c

        H1 "$($c.Label.ToUpperInvariant())"

        Write-Host " STATUS      " -NoNewline -ForegroundColor DarkGray
        Write-State $state

        Write-Host " MODE        $($c.Mode)" -ForegroundColor DarkGray
        Write-Host " GROUPS      $(@($c.Groups) -join ', ')" -ForegroundColor Magenta
        Write-Host " PURPOSE     $($c.Description)" -ForegroundColor DarkGray

        H2 "CONTROLS"

        Write-Host "  [1] Start" -ForegroundColor Green
        Write-Host "  [2] Stop normally" -ForegroundColor Yellow
        Write-Host "  [3] Restart" -ForegroundColor Yellow

        if($c.Type -eq "app"){
            Write-Host "  [4] Force stop" -ForegroundColor Red
            Write-Host "  [I] Detailed info" -ForegroundColor Cyan
        }else{
            Write-Host "  [I] Detailed info" -ForegroundColor Cyan
        }

        Write-Host "  [B] Back" -ForegroundColor DarkGray

        $sel=(Read-Host "Select").Trim().ToUpperInvariant()

        try{

            switch($sel){
                "1" {Start-Component $Key;Pause-Menu}
                "2" {Stop-Component $Key;Pause-Menu}
                "3" {Restart-Component $Key;Pause-Menu}
                "4" {
                    if($c.Type -eq "app"){
                        Stop-Component $Key -ForceApply
                        Pause-Menu
                    }
                }
                "I" {Show-Info $Key;Pause-Menu}
                "B" {return}
            }

        }catch{
            Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
            Pause-Menu
        }
    }
}

function Invoke-ModeMenu($Group,$Label){

    while($true){

        Clear-Host
        H1 "$Label MODE"

        foreach($m in @(Get-GroupMembers $Group)){

            $state=Get-State $m $Components[$m]

            Write-Host ("  {0,-14}" -f $Components[$m].Label) -NoNewline

            if($state -eq "RUNNING"){
                Write-Host $state -ForegroundColor Green
            }else{
                Write-Host $state -ForegroundColor Yellow
            }
        }

        H2 "CONTROLS"

        Write-Host "  [1] Start mode" -ForegroundColor Green
        Write-Host "  [2] Stop mode" -ForegroundColor Yellow
        Write-Host "  [3] Restart mode" -ForegroundColor Yellow
        Write-Host "  [B] Back" -ForegroundColor DarkGray

        $sel=(Read-Host "Select").Trim().ToUpperInvariant()

        try{
            switch($sel){
                "1" {Invoke-Group $Group start;Pause-Menu}
                "2" {Invoke-Group $Group stop;Pause-Menu}
                "3" {Invoke-Group $Group restart;Pause-Menu}
                "B" {return}
            }
        }catch{
            Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
            Pause-Menu
        }
    }
}

function Invoke-PowerToysTUI {
    $uiModule = Join-Path $Root "modules\ui.ps1"
    $resModule = Join-Path $Root "modules\resources.ps1"
    $ptModule = Join-Path $Root "modules\powertoys.ps1"
    if (Test-Path -LiteralPath $uiModule) { . $uiModule }
    if (Test-Path -LiteralPath $resModule) { . $resModule }
    if (Test-Path -LiteralPath $ptModule) { . $ptModule }
    Watch-PowerToys
}

function Invoke-ResourcesTUI {
    $uiModule = Join-Path $Root "modules\ui.ps1"
    $resModule = Join-Path $Root "modules\resources.ps1"
    if (Test-Path -LiteralPath $uiModule) { . $uiModule }
    if (Test-Path -LiteralPath $resModule) { . $resModule }
    Watch-WorkCtlResources
}

function Invoke-MediaTUI {
    $uiModule = Join-Path $Root "modules\ui.ps1"
    $resModule = Join-Path $Root "modules\resources.ps1"
    $ptModule = Join-Path $Root "modules\powertoys.ps1"
    $toolsModule = Join-Path $Root "modules\tools.ps1"
    $mediaModule = Join-Path $Root "modules\media.ps1"
    if (Test-Path -LiteralPath $uiModule) { . $uiModule }
    if (Test-Path -LiteralPath $resModule) { . $resModule }
    if (Test-Path -LiteralPath $ptModule) { . $ptModule }
    if (Test-Path -LiteralPath $toolsModule) { . $toolsModule }
    if (Test-Path -LiteralPath $mediaModule) { . $mediaModule }
    Watch-WorkCtlMedia
}

function Invoke-Shell {
    param(
        [string]$InitialScreen = "shell-home"
    )

    $uiModule = Join-Path $Root "modules\ui.ps1"
    $resModule = Join-Path $Root "modules\resources.ps1"
    $wlModule = Join-Path $Root "modules\workloads.ps1"
    $toolsModule = Join-Path $Root "modules\tools.ps1"
    $shellModule = Join-Path $Root "modules\shell.ps1"

    if (Test-Path -LiteralPath $uiModule) { . $uiModule }
    if (Test-Path -LiteralPath $resModule) { . $resModule }
    if (Test-Path -LiteralPath $wlModule) { . $wlModule }
    if (Test-Path -LiteralPath $toolsModule) { . $toolsModule }
    if (Test-Path -LiteralPath $shellModule) { . $shellModule }

    Watch-WorkCtlShell -InitialScreen $InitialScreen
}

function Invoke-Menu {
    Invoke-Shell
}

function Invoke-LegacyMenu {

    $map=@{
        "1"="mysql"
        "2"="docker"
        "3"="ollama"
        "4"="openclaw"
        "5"="omniroute"
        "6"="onedrive"
        "7"="discord"
        "8"="steam"
        "9"="screenrec"
        "0"="dsa"
        "R"="monect"
    }

    while($true){

        Clear-Host

        $sys=Get-SystemSummary
        $cnt=Get-ManagedCounts

        Write-Host "===============================================================" `
            -ForegroundColor DarkCyan
        Write-Host "                 WORKSTATION CONTROL" `
            -ForegroundColor Cyan
        Write-Host "                         v$Version" `
            -ForegroundColor DarkGray
        Write-Host "===============================================================" `
            -ForegroundColor DarkCyan

        Write-Host ""
        Write-Host " RAM " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($sys.UsedRAM)/$($sys.TotalRAM) GB" -NoNewline
        Write-Host "   FREE " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($sys.FreeRAM) GB" -NoNewline -ForegroundColor Green
        Write-Host "   C: " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($sys.CFree) GB free" -NoNewline
        Write-Host "   ADMIN " -NoNewline -ForegroundColor DarkGray

        if($sys.Admin){
            Write-Host "YES" -ForegroundColor Green
        }else{
            Write-Host "NO" -ForegroundColor Yellow
        }

        Write-Host " RUNNING " -NoNewline -ForegroundColor DarkGray
        Write-Host $cnt.Running -NoNewline -ForegroundColor Green
        Write-Host "   STOPPED " -NoNewline -ForegroundColor DarkGray
        Write-Host $cnt.Stopped -NoNewline -ForegroundColor Yellow
        Write-Host "   WARN " -NoNewline -ForegroundColor DarkGray
        Write-Host $cnt.Warnings -ForegroundColor Red

        H2 "WORKLOADS"

        foreach($key in @(
            "mysql","docker","ollama","openclaw","omniroute",
            "onedrive","discord","steam","screenrec","dsa","monect"
        )){

            $button=(
                $map.GetEnumerator() |
                Where-Object {$_.Value -eq $key} |
                Select-Object -First 1
            ).Key

            $c=$Components[$key]
            $state=Get-State $key $c

            Write-Host ("  [{0}] {1,-34}" -f $button,$c.Label) -NoNewline

            if($state -eq "RUNNING"){
                Write-Host "RUNNING" -ForegroundColor Green
            }elseif($state -eq "STOPPED"){
                Write-Host "STOPPED" -ForegroundColor Yellow
            }else{
                Write-Host $state -ForegroundColor Red
            }
        }

        H2 "WORK MODES"

        Write-Host "  [A] AI MODE       " -NoNewline -ForegroundColor Magenta
        Write-Host "Ollama + OpenClaw" -ForegroundColor DarkGray

        Write-Host "  [L] LOCAL AI      " -NoNewline -ForegroundColor Magenta
        Write-Host "Ollama + OmniRoute" -ForegroundColor DarkGray

        Write-Host "  [D] DEV MODE      " -NoNewline -ForegroundColor Magenta
        Write-Host "MySQL + Docker" -ForegroundColor DarkGray

        Write-Host "  [M] MAINTENANCE   " -NoNewline -ForegroundColor Magenta
        Write-Host "Intel DSA" -ForegroundColor DarkGray

        H2 "INTERACTIVE CONTROL PLANES"

        Write-Host "  [T] PowerToys TUI " -NoNewline -ForegroundColor Cyan
        Write-Host "PowerToys 34-utility TUI control plane" -ForegroundColor DarkGray

        Write-Host "  [V] Media Control " -NoNewline -ForegroundColor Cyan
        Write-Host "Smart media library, VLC, Sonarr & Torlink" -ForegroundColor DarkGray

        Write-Host "  [U] Resource Mon  " -NoNewline -ForegroundColor Cyan
        Write-Host "Real-time CPU/RAM/GPU/Network telemetry" -ForegroundColor DarkGray

        H2 "RESOURCE CONTROL"

        Write-Host "  [Q] Quiet Mode" -ForegroundColor Yellow
        Write-Host "  [Z] STOP ALL MANAGED WORKLOADS" -ForegroundColor Red

        H2 "SYSTEM"

        Write-Host "  [S] Status     " -NoNewline -ForegroundColor Cyan
        Write-Host "[C] Doctor     " -NoNewline -ForegroundColor Cyan
        Write-Host "[G] Groups" -ForegroundColor Cyan

        Write-Host "  [P] Protected  " -NoNewline -ForegroundColor Green
        Write-Host "[H] Help       " -NoNewline -ForegroundColor Cyan
        Write-Host "[X] Exit" -ForegroundColor DarkGray

        Write-Host ""

        $sel=(Read-Host "Select").Trim().ToUpperInvariant()

        if($map.ContainsKey($sel)){
            Invoke-ComponentMenu $map[$sel]
            continue
        }

        switch($sel){

            "T" {Invoke-PowerToysTUI}
            "V" {Invoke-MediaTUI}
            "U" {Invoke-ResourcesTUI}

            "A" {Invoke-ModeMenu ai "AI"}
            "L" {Invoke-ModeMenu local-ai "LOCAL AI"}
            "D" {Invoke-ModeMenu dev "DEVELOPMENT"}
            "M" {Invoke-ModeMenu maintenance "MAINTENANCE"}

            "Q" {
                Clear-Host
                Invoke-Quiet

                Write-Host ""
                Write-Host "[A] Apply Quiet Mode" -ForegroundColor Yellow
                Write-Host "[B] Back" -ForegroundColor DarkGray

                $q=(Read-Host "Select").Trim().ToUpperInvariant()

                if($q -eq "A"){
                    $old=$script:Apply
                    $script:Apply=$true
                    Invoke-Quiet
                    $script:Apply=$old
                    Pause-Menu
                }
            }

            "Z" {
                Clear-Host
                Invoke-StopAll
                Pause-Menu
            }

            "S" {
                Clear-Host
                Show-Status
                Pause-Menu
            }

            "C" {
                Clear-Host
                Show-Doctor
                Pause-Menu
            }

            "G" {
                Clear-Host
                Show-Groups
                Pause-Menu
            }

            "P" {
                Clear-Host
                Show-Protected
                Pause-Menu
            }

            "H" {
                Clear-Host
                Show-Help
                Pause-Menu
            }

            "X" {
                return
            }
        }
    }
}

# ================================================================
# ROUTER
# ================================================================

try{

    switch($Action){

        "menu" {
            Invoke-Menu
        }

        "status" {
            Show-Status $Target
        }

        "list" {
            Show-Status
        }

        "info" {
            Show-Info $Target
        }

        "help" {
            if($Target){
                Show-Info $Target
            }else{
                Show-Help
            }
        }

        "start" {
            Start-Component $Target
        }

        "stop" {
            Stop-Component $Target -ForceApply:$Apply
        }

        "restart" {
            Restart-Component $Target
        }

        "start-group" {
            Invoke-Group $Target start
        }

        "stop-group" {
            Invoke-Group $Target stop
        }

        "restart-group" {
            Invoke-Group $Target restart
        }

        "groups" {
            Show-Groups
        }

        "protected" {
            Show-Protected
        }

        "doctor" {
            Show-Doctor
        }

        "quiet" {
            Invoke-Quiet
        }

        "stop-all" {
            Invoke-StopAll
        }

        "powertoys" {
            Invoke-PowerToysTUI
        }

        "pt" {
            Invoke-PowerToysTUI
        }

        "resources" {
            Invoke-ResourcesTUI
        }

        "res" {
            Invoke-ResourcesTUI
        }

        "monitor" {
            Invoke-ResourcesTUI
        }

        "media" {
            Invoke-MediaTUI
        }

        "shell" {
            Invoke-Shell
        }

        "workloads" {
            Invoke-Shell -InitialScreen "shell-workloads-list"
        }

        "wl" {
            Invoke-Shell -InitialScreen "shell-workloads-list"
        }

        "tools" {
            Invoke-Shell -InitialScreen "shell-tools-list"
        }

        "processes" {
            Invoke-Shell -InitialScreen "shell-processes"
        }

        "ps" {
            Invoke-Shell -InitialScreen "shell-processes"
        }

        "services" {
            Invoke-Shell -InitialScreen "shell-services"
        }

        "network" {
            Invoke-Shell -InitialScreen "shell-network"
        }

        "storage" {
            Invoke-Shell -InitialScreen "shell-storage"
        }

        "projects" {
            Invoke-Shell -InitialScreen "shell-projects"
        }
    }

}catch{

    Write-Host ""
    Write-Host "WORKCTL ERROR" -ForegroundColor Red
    Write-Host $($_.Exception.Message) -ForegroundColor Red

    Write-Log "ERROR $Action $Target :: $($_.Exception.Message)"
    exit 1
}
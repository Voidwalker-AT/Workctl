# =================================================================
# WorkCtl v1.5 - Workload Engine
# =================================================================

$script:WorkCtlRoot=Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:WorkloadConfigPath=Join-Path $script:WorkCtlRoot "config\workloads.json"
$script:WorkloadLogDir=Join-Path $script:WorkCtlRoot "logs"

if(!(Test-Path -LiteralPath $script:WorkloadLogDir)){
    New-Item -ItemType Directory -Force -Path $script:WorkloadLogDir | Out-Null
}

$script:WorkloadLog=Join-Path $script:WorkloadLogDir (
    "workctl_{0}.log" -f (Get-Date -Format "yyyy-MM")
)

function Import-WorkloadRegistry {

    if(!(Test-Path -LiteralPath $script:WorkloadConfigPath)){
        throw "Workload registry missing: $script:WorkloadConfigPath"
    }

    try{
        $j=Get-Content -LiteralPath $script:WorkloadConfigPath -Raw |
            ConvertFrom-Json
    }catch{
        throw "Invalid workload registry: $($_.Exception.Message)"
    }

    if(!$j.components){
        throw "Workload registry contains no components."
    }

    $script:WorkloadRegistry=$j
}

function Write-WorkloadLog($Message){

    Add-Content -LiteralPath $script:WorkloadLog -Value (
        "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$Message
    )
}

function Test-WorkloadAdmin {

    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=New-Object Security.Principal.WindowsPrincipal($id)

    return $p.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Require-WorkloadAdmin($Reason){

    if(!(Test-WorkloadAdmin)){
        throw "$Reason requires Administrator PowerShell."
    }
}

function Get-Workload($Name){

    if(!$Name){
        throw "Workload name required."
    }

    $key=$Name.ToLowerInvariant()

    $p=$script:WorkloadRegistry.components.PSObject.Properties |
        Where-Object {$_.Name -eq $key} |
        Select-Object -First 1

    if(!$p){
        throw "Unknown workload: $Name"
    }

    [PSCustomObject]@{
        Key=$key
        Data=$p.Value
    }
}

function Get-WorkloadKeys {

    @(
        $script:WorkloadRegistry.components.PSObject.Properties |
        ForEach-Object {$_.Name}
    )
}

function Get-GenericAppProcesses($Component){

    $r=@()

    foreach($pn in @($Component.processes)){

        $r += @(
            Get-Process -Name $pn -ErrorAction SilentlyContinue
        )
    }

    @($r | Sort-Object Id -Unique)
}

function Get-OpenClawWorkloadProcesses {

    @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq "node.exe" -and
            $_.CommandLine -like "*openclaw*dist*index.js*gateway*"
        }
    )
}

function Get-OmniRouteWorkloadProcesses {

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

function Get-AntigravityWorkloadProcesses {

    $x=Get-Workload "antigravity"
    $base=$x.Data.installRoot

    @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            (
                $_.Name -eq "Antigravity.exe" -or
                $_.Name -eq "language_server.exe"
            ) -and
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith(
                $base,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
    )
}

function Get-TorlinkRootProcesses {

    # Identify npm start processes whose child tree contains
    # the Torlink "node dist/index.js" server.
    $all=@(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    )

    $servers=@(
        $all |
        Where-Object {
            $_.Name -eq "node.exe" -and
            $_.CommandLine -match '(^|\s)node(\.exe)?\s+.*dist[\\/]index\.js'
        }
    )

    $roots=@()

    foreach($srv in $servers){

        $cur=$srv
        $chain=@($srv)

        for($i=0;$i -lt 8;$i++){

            if(!$cur -or $cur.ParentProcessId -eq 0){
                break
            }

            $par=$all |
                Where-Object {$_.ProcessId -eq $cur.ParentProcessId} |
                Select-Object -First 1

            if(!$par){
                break
            }

            $chain += $par

            if(
                $par.Name -eq "node.exe" -and
                $par.CommandLine -match 'npm-cli\.js.*\sstart(\s|$)'
            ){
                $roots += $par
                break
            }

            $cur=$par
        }
    }

    @($roots | Sort-Object ProcessId -Unique)
}

function Get-TorlinkWorkloadProcesses {

    $all=@(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    )

    $roots=@(Get-TorlinkRootProcesses)

    if($roots.Count -eq 0){
        return @()
    }

    $ids=@($roots | ForEach-Object {$_.ProcessId})
    $changed=$true

    while($changed){

        $changed=$false

        foreach($p in $all){

            if(
                $p.ParentProcessId -in $ids -and
                $p.ProcessId -notin $ids
            ){
                $ids += $p.ProcessId
                $changed=$true
            }
        }
    }

    @(
        $all |
        Where-Object {$_.ProcessId -in $ids} |
        Sort-Object ProcessId -Unique
    )
}

function Get-PowerToysWorkloadProcesses {

    $x=Get-Workload "powertoys"
    $base=Split-Path -Parent $x.Data.startPath

    @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith(
                $base,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
    )
}

function Get-WorkloadProcesses($Name){

    $x=Get-Workload $Name
    $key=$x.Key
    $c=$x.Data

    switch($c.type){

        "app" {
            return @(Get-GenericAppProcesses $c)
        }

        "ollama" {
            return @(Get-GenericAppProcesses $c)
        }

        "openclaw" {
            return @(Get-OpenClawWorkloadProcesses)
        }

        "omniroute" {
            return @(Get-OmniRouteWorkloadProcesses)
        }

        "torlink" {
            return @(Get-TorlinkWorkloadProcesses)
        }

        "antigravity" {
            return @(Get-AntigravityWorkloadProcesses)
        }

        "powertoys-host" {
            return @(Get-PowerToysWorkloadProcesses)
        }

        "docker" {
            return @(
                Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match "^(Docker Desktop|com\.docker\..*)\.exe$"
                }
            )
        }

        default {
            return @()
        }
    }
}

function Get-WorkloadState($Name){

    $x=Get-Workload $Name
    $key=$x.Key
    $c=$x.Data

    switch($c.type){

        "service" {

            $s=Get-Service $c.service -ErrorAction SilentlyContinue

            if(!$s){return "UNAVAILABLE"}
            if($s.Status -eq "Running"){return "RUNNING"}

            return "STOPPED"
        }

        "service-group" {

            $found=0
            $running=0

            foreach($sn in @($c.services)){

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

            if((Get-OpenClawWorkloadProcesses).Count -gt 0){
                return "RUNNING"
            }

            return "STOPPED"
        }

        "omniroute" {

            if(!(Get-Command omniroute -ErrorAction SilentlyContinue)){
                return "UNAVAILABLE"
            }

            if((Get-OmniRouteWorkloadProcesses).Count -gt 0){
                return "RUNNING"
            }

            return "STOPPED"
        }

        "torlink" {

            if(!(Test-Path -LiteralPath $c.workingDirectory)){
                return "UNAVAILABLE"
            }

            if(!(Get-Command npm -ErrorAction SilentlyContinue)){
                return "UNAVAILABLE"
            }

            if((Get-TorlinkWorkloadProcesses).Count -gt 0){
                return "RUNNING"
            }

            return "STOPPED"
        }

        "antigravity" {

            if(!(Test-Path -LiteralPath $c.startPath)){
                return "UNAVAILABLE"
            }

            if((Get-AntigravityWorkloadProcesses).Count -gt 0){
                return "RUNNING"
            }

            return "STOPPED"
        }

        "powertoys-host" {

            if(!(Test-Path -LiteralPath $c.startPath)){
                return "UNAVAILABLE"
            }

            if((Get-PowerToysWorkloadProcesses).Count -gt 0){
                return "RUNNING"
            }

            return "STOPPED"
        }

        "ollama" {

            if(!(Test-Path -LiteralPath $c.startPath)){
                return "UNAVAILABLE"
            }

            if((Get-GenericAppProcesses $c).Count -gt 0){
                return "RUNNING"
            }

            return "STOPPED"
        }

        "app" {

            if(!(Test-Path -LiteralPath $c.startPath)){
                return "UNAVAILABLE"
            }

            if((Get-GenericAppProcesses $c).Count -gt 0){
                return "RUNNING"
            }

            return "STOPPED"
        }

        default {
            return "UNAVAILABLE"
        }
    }
}

function Get-WorkloadResources($Name){

    $x=Get-Workload $Name
    $c=$x.Data
    $state=Get-WorkloadState $Name

    $count=0
    $ram=0
    $ports=@()

    if($c.type -in @("service","service-group")){

        $services=@()

        if($c.type -eq "service"){
            $services=@($c.service)
        }else{
            $services=@($c.services)
        }

        $ids=@()

        foreach($sn in $services){

            $s=Get-CimInstance Win32_Service `
                -Filter "Name='$sn'" `
                -ErrorAction SilentlyContinue

            if($s -and $s.ProcessId -gt 0){
                $ids += [int]$s.ProcessId
            }
        }

        foreach($id in @($ids | Sort-Object -Unique)){

            $p=Get-Process -Id $id -ErrorAction SilentlyContinue

            if($p){
                $count++
                $ram += $p.WorkingSet64
            }
        }

    }else{

        $ps=@(Get-WorkloadProcesses $Name)
        $count=$ps.Count

        foreach($p0 in $ps){

            $id=[int]$p0.ProcessId

            if(!$id -and $p0.Id){
                $id=[int]$p0.Id
            }

            if($id){

                $gp=Get-Process -Id $id -ErrorAction SilentlyContinue

                if($gp){
                    $ram += $gp.WorkingSet64
                }
            }
        }
    }

    if($count -gt 0){

        $ids=@()

        $ps=@(Get-WorkloadProcesses $Name)

        foreach($p0 in $ps){

            if($p0.ProcessId){
                $ids += [int]$p0.ProcessId
            }elseif($p0.Id){
                $ids += [int]$p0.Id
            }
        }

        if($ids.Count -gt 0){

            $ports=@(
                Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                Where-Object {$_.OwningProcess -in $ids} |
                Select-Object -ExpandProperty LocalPort -Unique |
                Sort-Object
            )
        }
    }

    [PSCustomObject]@{
        Component=$x.Key
        Label=$c.label
        State=$state
        Processes=$count
        RAM_MB=[math]::Round($ram/1MB,1)
        Ports=($ports -join ",")
    }
}

function Get-WorkloadGroupMembers($Group){

    $r=@()

    foreach($p in $script:WorkloadRegistry.components.PSObject.Properties){

        if(@($p.Value.groups) -contains $Group){
            $r += $p.Name
        }
    }

    $r
}

function Start-Workload($Name){

    $x=Get-Workload $Name
    $key=$x.Key
    $c=$x.Data

    $state=Get-WorkloadState $key

    if($c.stopPolicy -eq "explicit"){
        throw "$($c.label) is owned by a dedicated WorkCtl subsystem and cannot be started through the workload engine."
    }

    if($state -eq "RUNNING"){
        Write-Host "$($c.label) already running." -ForegroundColor Green
        return
    }

    if($state -eq "UNAVAILABLE"){
        throw "$($c.label) is unavailable."
    }

    if($c.admin){
        Require-WorkloadAdmin "Starting $key"
    }

    switch($c.type){

        "service" {
            Start-Service $c.service
        }

        "service-group" {

            foreach($sn in @($c.services)){
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

            $taskPath="\"
            $taskName="OpenClaw Gateway"

            $t=Get-ScheduledTask `
                -TaskPath $taskPath `
                -TaskName $taskName `
                -ErrorAction SilentlyContinue

            $disabled=$false

            if($t -and $t.State -eq "Disabled"){

                $disabled=$true

                Enable-ScheduledTask `
                    -TaskPath $taskPath `
                    -TaskName $taskName |
                    Out-Null
            }

            try{

                & openclaw gateway start
                $ec=$LASTEXITCODE

            }finally{

                Start-Sleep -Milliseconds 600

                if($disabled){

                    Disable-ScheduledTask `
                        -TaskPath $taskPath `
                        -TaskName $taskName |
                        Out-Null
                }
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

            if((Get-OmniRouteWorkloadProcesses).Count -eq 0){
                throw "OmniRoute did not start."
            }
        }

        "torlink" {

            Start-Process `
                -FilePath "cmd.exe" `
                -ArgumentList @(
                    "/d",
                    "/s",
                    "/c",
                    "npm start"
                ) `
                -WorkingDirectory $c.workingDirectory `
                -WindowStyle Hidden

            Start-Sleep -Seconds 3

            if((Get-TorlinkWorkloadProcesses).Count -eq 0){
                throw "Torlink did not start."
            }
        }

        "antigravity" {
            Start-Process -FilePath $c.startPath
        }

        "powertoys-host" {
            Start-Process -FilePath $c.startPath
        }

        "ollama" {
            Start-Process -FilePath $c.startPath
        }

        "app" {

            if($c.startArgs){

                Start-Process `
                    -FilePath $c.startPath `
                    -ArgumentList @($c.startArgs)

            }else{

                Start-Process -FilePath $c.startPath
            }
        }

        default {
            throw "Unsupported workload type: $($c.type)"
        }
    }

    Write-WorkloadLog "START $key"
    Write-Host "START requested: $($c.label)" -ForegroundColor Green
}

function Stop-GenericAppWorkload($Key,$Component,[switch]$Apply){

    $ps=@(Get-GenericAppProcesses $Component)

    foreach($p in $ps){

        if($p.MainWindowHandle -ne 0){
            $null=$p.CloseMainWindow()
        }
    }

    Start-Sleep -Seconds 2

    $left=@(Get-GenericAppProcesses $Component)

    if($left.Count -eq 0){
        return
    }

    if(!$Apply){

        Write-Host "$Key still has $($left.Count) process(es)." `
            -ForegroundColor Yellow

        Write-Host "Force if required:" -ForegroundColor DarkGray
        Write-Host "  workctl stop $Key -Apply" -ForegroundColor Red

        return
    }

    foreach($p in $left){

        Stop-Process `
            -Id $p.Id `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Host "Forced remaining $Key processes closed." `
        -ForegroundColor Red
}

function Stop-AntigravityWorkload([switch]$Apply){

    $ps=@(Get-AntigravityWorkloadProcesses)

    $ids=@($ps | ForEach-Object {$_.ProcessId})

    $roots=@(
        $ps |
        Where-Object {
            $_.Name -eq "Antigravity.exe" -and
            $_.ParentProcessId -notin $ids
        }
    )

    foreach($r in $roots){

        $gp=Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue

        if($gp -and $gp.MainWindowHandle -ne 0){
            $null=$gp.CloseMainWindow()
        }
    }

    Start-Sleep -Seconds 5

    $left=@(Get-AntigravityWorkloadProcesses)

    if($left.Count -eq 0){
        return
    }

    if(!$Apply){

        Write-Host "antigravity still has $($left.Count) process(es)." `
            -ForegroundColor Yellow

        Write-Host "Force if required:" -ForegroundColor DarkGray
        Write-Host "  workctl stop antigravity -Apply" -ForegroundColor Red

        return
    }

    # Only processes whose executable lives inside the verified
    # Antigravity installation root reach this function.
    foreach($p in $left){

        Stop-Process `
            -Id $p.ProcessId `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 1

    if((Get-AntigravityWorkloadProcesses).Count -gt 0){
        throw "Antigravity processes remain after forced shutdown."
    }

    Write-Host "Forced remaining Antigravity processes closed." `
        -ForegroundColor Red
}

function Stop-TorlinkWorkload([switch]$Apply){

    $ps=@(Get-TorlinkWorkloadProcesses)

    if($ps.Count -eq 0){
        return
    }

    # First attempt to stop only the Torlink npm process tree.
    # Console processes generally do not expose a closeable main window.
    # Without -Apply we report the tree instead of killing it.

    if(!$Apply){

        Write-Host "Torlink has $($ps.Count) managed process(es)." `
            -ForegroundColor Yellow

        Write-Host "Torlink is a console workload; force-stop its verified tree with:" `
            -ForegroundColor DarkGray

        Write-Host "  workctl stop torlink -Apply" -ForegroundColor Red

        return
    }

    # Kill children before parents.
    $ordered=@(
        $ps |
        Sort-Object ProcessId -Descending
    )

    foreach($p in $ordered){

        Stop-Process `
            -Id $p.ProcessId `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 1

    if((Get-TorlinkWorkloadProcesses).Count -gt 0){
        throw "Torlink process tree remains after shutdown."
    }

    Write-Host "Torlink managed process tree stopped." `
        -ForegroundColor Red
}

function Stop-PowerToysWorkload([switch]$Apply){

    $ps=@(Get-PowerToysWorkloadProcesses)

    if($ps.Count -eq 0){
        return
    }

    $main=@(
        $ps |
        Where-Object {$_.Name -eq "PowerToys.exe"}
    )

    foreach($p in $main){

        $gp=Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue

        if($gp -and $gp.MainWindowHandle -ne 0){
            $null=$gp.CloseMainWindow()
        }
    }

    Start-Sleep -Seconds 2

    $left=@(Get-PowerToysWorkloadProcesses)

    if($left.Count -eq 0){
        return
    }

    if(!$Apply){

        Write-Host "powertoys still has $($left.Count) process(es)." `
            -ForegroundColor Yellow

        Write-Host "Force if required:" -ForegroundColor DarkGray
        Write-Host "  workctl stop powertoys -Apply" -ForegroundColor Red

        return
    }

    foreach($p in $left){

        Stop-Process `
            -Id $p.ProcessId `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Host "Forced remaining PowerToys processes closed." `
        -ForegroundColor Red
}

function Stop-Workload(
    $Name,
    [switch]$Apply
){

    $x=Get-Workload $Name
    $key=$x.Key
    $c=$x.Data

    $state=Get-WorkloadState $key

    if($c.stopPolicy -eq "explicit"){
        throw "$($c.label) is owned by a dedicated WorkCtl subsystem and cannot be stopped through the workload engine."
    }

    if($state -eq "STOPPED"){

        Write-Host "$($c.label) already stopped." `
            -ForegroundColor DarkGray

        return
    }

    if($state -eq "UNAVAILABLE"){
        throw "$($c.label) is unavailable."
    }

    if($c.admin){
        Require-WorkloadAdmin "Stopping $key"
    }

    switch($c.type){

        "service" {
            Stop-Service $c.service
        }

        "service-group" {

            foreach($sn in @($c.services)){

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
                -TaskPath "\" `
                -TaskName "OpenClaw Gateway" `
                -ErrorAction SilentlyContinue

            if($t -and $t.State -ne "Disabled"){

                Disable-ScheduledTask `
                    -TaskPath "\" `
                    -TaskName "OpenClaw Gateway" |
                    Out-Null
            }
        }

        "omniroute" {

            $tray=@(
                Get-CimInstance Win32_Process |
                Where-Object {
                    $_.Name -eq "node.exe" -and
                    $_.CommandLine -like "*omniroute.mjs*" -and
                    $_.CommandLine -like "*--tray*"
                }
            )

            foreach($p in $tray){

                Stop-Process `
                    -Id $p.ProcessId `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

            & omniroute stop

            if($LASTEXITCODE -ne 0){
                throw "OmniRoute stop failed."
            }

            Start-Sleep -Seconds 1
        }

        "torlink" {
            Stop-TorlinkWorkload -Apply:$Apply
        }

        "antigravity" {
            Stop-AntigravityWorkload -Apply:$Apply
        }

        "powertoys-host" {
            Stop-PowerToysWorkload -Apply:$Apply
        }

        "ollama" {
            Stop-GenericAppWorkload $key $c -Apply:$Apply
        }

        "app" {
            Stop-GenericAppWorkload $key $c -Apply:$Apply
        }

        default {
            throw "Unsupported workload type: $($c.type)"
        }
    }

    Write-WorkloadLog "STOP $key FORCE=$Apply"
    Write-Host "STOP requested: $($c.label)" -ForegroundColor Green
}

function Restart-Workload(
    $Name,
    [switch]$Apply
){

    $x=Get-Workload $Name
    $key=$x.Key
    $c=$x.Data

    if($c.stopPolicy -eq "explicit"){
        throw "$($c.label) is owned by a dedicated WorkCtl subsystem and cannot be restarted through the workload engine."
    }

    if($c.admin){
        Require-WorkloadAdmin "Restarting $key"
    }

    if($c.type -eq "docker"){

        & docker desktop restart

        if($LASTEXITCODE -ne 0){
            throw "Docker restart failed."
        }

    }else{

        Stop-Workload $key -Apply:$Apply

        Start-Sleep -Seconds 1

        if(
            !$Apply -and
            (Get-WorkloadState $key) -eq "RUNNING"
        ){
            throw "$($c.label) did not stop. Use restart $key -Apply if appropriate."
        }

        Start-Workload $key
    }

    Write-WorkloadLog "RESTART $key"
    Write-Host "RESTART requested: $($c.label)" -ForegroundColor Green
}

function Test-WorkloadGroup($Group,$Operation){

    $members=@(Get-WorkloadGroupMembers $Group)

    if($members.Count -eq 0){
        throw "Unknown group: $Group"
    }

    $problems=@()

    foreach($m in $members){

        $x=Get-Workload $m
        $c=$x.Data
        $state=Get-WorkloadState $m

        if($Operation -in @("start","restart")){

            if($state -eq "UNAVAILABLE"){
                $problems += "$m unavailable"
            }

            if($c.admin -and !(Test-WorkloadAdmin)){
                $problems += "$m requires Administrator PowerShell"
            }
        }

        if(
            $Operation -eq "stop" -and
            $state -eq "RUNNING" -and
            $c.admin -and
            !(Test-WorkloadAdmin)
        ){
            $problems += "$m requires Administrator PowerShell"
        }
    }

    [PSCustomObject]@{
        Members=$members
        Problems=$problems
    }
}

function Invoke-WorkloadGroup(
    $Group,
    $Operation,
    [switch]$Apply
){

    if($Operation -notin @("start","stop","restart")){
        throw "Invalid group operation: $Operation"
    }

    $p=Test-WorkloadGroup $Group $Operation

    if($p.Problems.Count -gt 0){

        Write-Host "`nGROUP PREFLIGHT FAILED" -ForegroundColor Red

        foreach($e in $p.Problems){
            Write-Host "  $e" -ForegroundColor Red
        }

        Write-Host "Nothing changed." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "$($Operation.ToUpperInvariant()) GROUP :: $Group" `
        -ForegroundColor Magenta

    foreach($m in $p.Members){

        switch($Operation){

            "start" {
                Start-Workload $m
            }

            "stop" {
                Stop-Workload $m -Apply:$Apply
            }

            "restart" {
                Restart-Workload $m -Apply:$Apply
            }
        }
    }
}

function Invoke-WorkloadQuiet([switch]$Apply){

    $members=@(Get-WorkloadGroupMembers "quiet")
    $safe=@()

    Write-Host "`nQUIET MODE" -ForegroundColor Cyan
    Write-Host "==========" -ForegroundColor DarkCyan

    foreach($m in $members){

        $x=Get-Workload $m
        $state=Get-WorkloadState $m
        $policy=$x.Data.stopPolicy

        Write-Host ("  {0,-14}" -f $m) -NoNewline

        if($state -eq "RUNNING"){
            Write-Host ("{0,-12}" -f $state) -NoNewline -ForegroundColor Green
        }elseif($state -eq "STOPPED"){
            Write-Host ("{0,-12}" -f $state) -NoNewline -ForegroundColor Yellow
        }else{
            Write-Host ("{0,-12}" -f $state) -NoNewline -ForegroundColor Red
        }

        if($policy -eq "safe"){
            Write-Host "AUTO" -ForegroundColor Green
            $safe += $m
        }else{
            Write-Host ("SKIP ({0})" -f $policy) -ForegroundColor Yellow
        }
    }

    if(!$Apply){

        Write-Host ""
        Write-Host "PREVIEW ONLY" -ForegroundColor Green
        Write-Host "Only SAFE workloads are eligible for automatic stop." `
            -ForegroundColor DarkGray
        Write-Host "Apply with: workctl quiet -Apply" `
            -ForegroundColor Yellow

        return
    }

    foreach($m in $safe){

        if((Get-WorkloadState $m) -ne "RUNNING"){
            continue
        }

        $x=Get-Workload $m

        if($x.Data.admin -and !(Test-WorkloadAdmin)){

            Write-Host "[SKIP] $m requires Administrator" `
                -ForegroundColor Yellow

            continue
        }

        try{
            Stop-Workload $m
        }catch{
            Write-Host "[WARN] $m : $($_.Exception.Message)" `
                -ForegroundColor Yellow
        }
    }

    Write-WorkloadLog "QUIET APPLY POLICY=SAFE"
}

function Invoke-WorkloadStopAll([switch]$Apply){

    $safe=@()
    $guarded=@()

    foreach($k in Get-WorkloadKeys){

        if((Get-WorkloadState $k) -ne "RUNNING"){
            continue
        }

        $x=Get-Workload $k
        $policy=$x.Data.stopPolicy

        if($policy -eq "safe"){
            $safe += $k
        }else{
            $guarded += [PSCustomObject]@{
                Component=$k
                Policy=$policy
            }
        }
    }

    Write-Host "`nSTOP ALL SAFE WORKLOADS" -ForegroundColor Cyan
    Write-Host "=======================" -ForegroundColor DarkCyan

    if($safe.Count -eq 0){
        Write-Host "No SAFE managed workloads are currently running." `
            -ForegroundColor Green
    }else{

        Write-Host "`nEligible:" -ForegroundColor Green

        foreach($k in $safe){
            Write-Host "  $k" -ForegroundColor White
        }
    }

    if($guarded.Count -gt 0){

        Write-Host "`nProtected from bulk stop:" -ForegroundColor Yellow

        foreach($g in $guarded){

            Write-Host (
                "  {0,-14} {1}" -f $g.Component,$g.Policy
            ) -ForegroundColor Yellow
        }
    }

    Write-Host "`nSystem protected:" -ForegroundColor Magenta

    foreach($p in @($script:WorkloadRegistry.protected)){
        Write-Host "  $p" -ForegroundColor Green
    }

    if(!$Apply){

        Write-Host ""
        Write-Host "PREVIEW ONLY" -ForegroundColor Green
        Write-Host "Apply with: workctl stop-all -Apply" `
            -ForegroundColor Yellow

        return
    }

    foreach($k in $safe){

        $x=Get-Workload $k

        if($x.Data.admin -and !(Test-WorkloadAdmin)){

            Write-Host "[SKIP] $k requires Administrator" `
                -ForegroundColor Yellow

            continue
        }

        try{
            Stop-Workload $k
        }catch{
            Write-Host "[WARN] $k : $($_.Exception.Message)" `
                -ForegroundColor Yellow
        }
    }

    Write-WorkloadLog "STOP-ALL APPLY POLICY=SAFE"
}
function Get-WorkloadStatus {

    $rows=@()

    foreach($k in Get-WorkloadKeys){

        $x=Get-Workload $k
        $r=Get-WorkloadResources $k

        $rows += [PSCustomObject]@{
            Component=$k
            Label=$x.Data.label
            State=$r.State
            Mode=$x.Data.mode
            Processes=$r.Processes
            RAM_MB=$r.RAM_MB
            Ports=$r.Ports
            Groups=(@($x.Data.groups) -join ",")
        }
    }

    $rows
}

function Get-WorkloadProtected {

    @($script:WorkloadRegistry.protected)
}

Import-WorkloadRegistry




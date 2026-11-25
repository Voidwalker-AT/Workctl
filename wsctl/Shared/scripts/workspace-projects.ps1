<#
.SYNOPSIS
    Workspace Projects Explorer & Command Dispatcher (workspace-projects.ps1)

.DESCRIPTION
    Read-only catalog explorer and safe command executor based on E:\Workspace\workspace.json.
    By default, displays registered projects in a clean summary table.
    Allows inspection of specific projects, environment configurations, and documentation.
    Command execution requires explicit parameters and displays the exact command prior to execution.

.EXAMPLE
    # List all projects
    .\workspace-projects.ps1

    # Filter by category
    .\workspace-projects.ps1 -Category active
    .\workspace-projects.ps1 -Category academic

    # View project details
    .\workspace-projects.ps1 -Name dl-exp1

    # Safely execute a registered command
    .\workspace-projects.ps1 -Name dl-exp1 -Run dashboard
#>

[CmdletBinding()]
param (
    [string]$Name,
    [string]$Category,
    [string]$Tag,
    [string]$Run,
    [string]$WorkspaceRoot = "E:\Workspace"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $WorkspaceRoot)) {
    $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$ManifestPath = Join-Path $WorkspaceRoot "workspace.json"
if (-not (Test-Path $ManifestPath)) {
    Write-Error "Project manifest not found at: $ManifestPath"
}

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$projects = $manifest.projects

# -------------------------------------------------------------
# SPECIFIC PROJECT INSPECTION OR EXECUTION
# -------------------------------------------------------------
if ($Name) {
    $target = $projects | Where-Object { 
        $_.id -ieq $Name -or $_.name -ilike "*$Name*" -or $_.path -ilike "*$Name*" 
    } | Select-Object -First 1

    if (-not $target) {
        Write-Host "[-] Project matching '$Name' not found in workspace manifest." -ForegroundColor Red
        Write-Host "    Run 'workspace-projects.ps1' to list available project IDs." -ForegroundColor Gray
        exit 1
    }

    $projFullPath = Join-Path $WorkspaceRoot $target.path

    Write-Host ""
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host "PROJECT: $($target.name) [$($target.id)]" -ForegroundColor White
    Write-Host "==========================================================================" -ForegroundColor Cyan
    Write-Host " Path           : $($target.path) ($(if (Test-Path $projFullPath) { 'Exists on disk' } else { 'MISSING on disk' }))" -ForegroundColor $(if (Test-Path $projFullPath) { "Green" } else { "Red" })
    Write-Host " Category       : $($target.category)" -ForegroundColor Gray
    Write-Host " Status         : $($target.status)" -ForegroundColor Gray
    Write-Host " Languages      : $($target.languages -join ', ')" -ForegroundColor Gray
    Write-Host " Frameworks     : $($target.frameworks -join ', ')" -ForegroundColor Gray
    Write-Host " Package Manager: $($target.packageManager)" -ForegroundColor Gray
    Write-Host " Environment    : $($target.environment)" -ForegroundColor Gray
    Write-Host " GPU Required   : $($target.gpu)" -ForegroundColor Gray
    Write-Host " Git Repository : $($target.git)" -ForegroundColor Gray
    Write-Host " Documentation  : $($target.documentation)" -ForegroundColor Gray
    if ($target.instructions) {
        $instFullPath = Join-Path $WorkspaceRoot $target.instructions
        $instStatus = if (Test-Path $instFullPath) { "Exists" } else { "MISSING" }
        Write-Host " Instructions   : $($target.instructions) ($instStatus)" -ForegroundColor $(if (Test-Path $instFullPath) { "Cyan" } else { "DarkGray" })
    }
    Write-Host " Tags           : $($target.tags -join ', ')" -ForegroundColor Gray

    # Registered Commands
    Write-Host "`nRegistered Commands:" -ForegroundColor Yellow
    $cmdProps = $target.commands.PSObject.Properties
    if ($cmdProps.Count -gt 0) {
        foreach ($cp in $cmdProps) {
            if ($cp.Value -is [PSCustomObject]) {
                $cmdObj = $cp.Value
                $riskTag = if ($cmdObj.risk) { "[$($cmdObj.risk)]" } else { "[safe]" }
                $descTag = if ($cmdObj.description) { " - $($cmdObj.description)" } else { "" }
                $cmdStr = "$($cmdObj.executable) $($cmdObj.args -join ' ')".Trim()
                Write-Host "  • $($cp.Name.PadRight(12, ' ')) : $cmdStr $riskTag$descTag" -ForegroundColor Cyan
            } else {
                Write-Host "  • $($cp.Name.PadRight(12, ' ')) : $($cp.Value)" -ForegroundColor Cyan
            }
        }
    } else {
        Write-Host "  (No specific commands registered)" -ForegroundColor DarkGray
    }

    # Handle Command Execution Request
    if ($Run) {
        $matchingCmd = $cmdProps | Where-Object { $_.Name -ieq $Run }
        if (-not $matchingCmd) {
            Write-Host "`n[-] Command '$Run' is not registered for project '$($target.id)'." -ForegroundColor Red
            Write-Host "    Available commands: $($cmdProps.Name -join ', ')" -ForegroundColor Gray
            exit 1
        }

        $execCwd = $projFullPath
        $execCmdStr = ""
        $execRisk = "safe"

        if ($matchingCmd.Value -is [PSCustomObject]) {
            $cmdObj = $matchingCmd.Value
            if ($cmdObj.cwd) {
                $execCwd = Join-Path $WorkspaceRoot $cmdObj.cwd
            }
            $formattedArgs = foreach ($arg in $cmdObj.args) {
                if ($arg -match '\s' -and -not ($arg.StartsWith('"') -and $arg.EndsWith('"'))) {
                    "`"$arg`""
                } else {
                    $arg
                }
            }
            $execCmdStr = "$($cmdObj.executable) $($formattedArgs -join ' ')".Trim()
            if ($cmdObj.risk) { $execRisk = $cmdObj.risk }
        } else {
            $execCmdStr = $matchingCmd.Value
        }

        Write-Host "`n--------------------------------------------------------------------------" -ForegroundColor Yellow
        Write-Host "EXECUTION PREVIEW" -ForegroundColor Yellow
        Write-Host " Working Directory : $execCwd" -ForegroundColor White
        Write-Host " Executed Command  : $execCmdStr" -ForegroundColor Green
        Write-Host " Risk Level        : $execRisk" -ForegroundColor $(if ($execRisk -eq "destructive") { "Red" } elseif ($execRisk -eq "compute") { "Cyan" } else { "Green" })
        Write-Host "--------------------------------------------------------------------------" -ForegroundColor Yellow

        $commandExitCode = 1
        Push-Location $execCwd
        try {
            Write-Host "[*] Executing command in $execCwd ...`n" -ForegroundColor Cyan
            cmd.exe /c "$execCmdStr"
            $commandExitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        exit $commandExitCode
    } else {
        if ($cmdProps.Count -gt 0) {
            Write-Host "`nTo run a command, execute:" -ForegroundColor DarkGray
            Write-Host "  .\workspace-projects.ps1 -Name $($target.id) -Run <command>`n" -ForegroundColor DarkCyan
        }
    }
    exit 0
}

# -------------------------------------------------------------
# FILTERING
# -------------------------------------------------------------
if ($Category) {
    $projects = $projects | Where-Object { $_.category -ieq $Category }
}
if ($Tag) {
    $projects = $projects | Where-Object { $_.tags -icontains $Tag }
}

# -------------------------------------------------------------
# SUMMARY TABLE
# -------------------------------------------------------------
Write-Host ""
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host "                         WORKSPACE PROJECTS CATALOG                       " -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host " Total Projects Listed: $($projects.Count)" -ForegroundColor Gray
Write-Host " Use '-Name <id>' for detailed inspection and available commands." -ForegroundColor DarkGray
Write-Host " Use '-Category <active|academic|tools|references|completed|shared>' to filter." -ForegroundColor DarkGray
Write-Host ""

$projects | Select-Object `
    @{Name="ID"; Expression={$_.id}}, `
    @{Name="Name"; Expression={$_.name}}, `
    @{Name="Category"; Expression={$_.category}}, `
    @{Name="Languages"; Expression={$_.languages -join ', '}}, `
    @{Name="Environment"; Expression={$_.environment}}, `
    @{Name="Status"; Expression={$_.status}} | Format-Table -AutoSize

Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host ""

<#
.SYNOPSIS
    Workspace Guided Bootstrap Validator (bootstrap-workspace.ps1)

.DESCRIPTION
    Diagnostic and guided onboarding assistant for setting up a developer workstation for E:\Workspace.
    Reads Shared\configs\toolchains.json, checks installed toolchains against project requirements,
    and provides clear, non-invasive installation instructions.

    SAFETY: This script is strictly DIAGNOSTIC by default and will NOT modify or install software.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\bootstrap-workspace.ps1
#>

[CmdletBinding()]
param (
    [string]$WorkspaceRoot = "E:\Workspace"
)

$ErrorActionPreference = "Continue"

if (-not (Test-Path $WorkspaceRoot)) {
    $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

$ToolchainsFile = Join-Path $WorkspaceRoot "Shared\configs\toolchains.json"
$PathsFile = Join-Path $WorkspaceRoot "Shared\configs\workspace-paths.json"

Write-Host ""
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host "                WORKSPACE GUIDED BOOTSTRAP VALIDATOR                      " -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host " Workspace Root : $WorkspaceRoot" -ForegroundColor Gray
Write-Host " Mode           : Non-Destructive Diagnostic Verification" -ForegroundColor Gray
Write-Host " Timestamp      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $ToolchainsFile)) {
    Write-Error "Toolchains configuration not found: $ToolchainsFile"
}

$toolchainsData = Get-Content $ToolchainsFile -Raw | ConvertFrom-Json
$toolchains = $toolchainsData.toolchains

$readyCount = 0
$actionCount = 0
$optionalCount = 0

foreach ($t in $toolchains) {
    $cmd = Get-Command $t.command -ErrorAction SilentlyContinue
    $isInstalled = ($cmd -ne $null)

    if ($isInstalled) {
        $readyCount++
        Write-Host "  [+] $($t.name.PadRight(35, ' ')) : " -NoNewline -ForegroundColor Green
        Write-Host "INSTALLED" -ForegroundColor White
        Write-Host "      Command   : $($cmd.Source)" -ForegroundColor DarkGray
        Write-Host "      Consumers : $($t.consumers -join ', ')" -ForegroundColor DarkCyan
    } else {
        if ($t.required) {
            $actionCount++
            Write-Host "  [-] $($t.name.PadRight(35, ' ')) : " -NoNewline -ForegroundColor Red
            Write-Host "MISSING (REQUIRED)" -ForegroundColor Red
            Write-Host "      Consumers : $($t.consumers -join ', ')" -ForegroundColor Yellow
            if ($t.recommendations) {
                $recProps = $t.recommendations.PSObject.Properties
                foreach ($rp in $recProps) {
                    Write-Host "      Guidance  : $($rp.Value)" -ForegroundColor Gray
                }
            }
        } else {
            $optionalCount++
            Write-Host "  [?] $($t.name.PadRight(35, ' ')) : " -NoNewline -ForegroundColor DarkGray
            Write-Host "OPTIONAL (NOT INSTALLED)" -ForegroundColor DarkGray
            Write-Host "      Consumers : $($t.consumers -join ', ')" -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n==========================================================================" -ForegroundColor Cyan
Write-Host "                        BOOTSTRAP HEALTH ASSESSMENT                       " -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host " Verified Ready     : $readyCount" -ForegroundColor Green
Write-Host " Required & Missing : $actionCount" -ForegroundColor $(if ($actionCount -eq 0) { "Green" } else { "Red" })
Write-Host " Optional Tools     : $optionalCount" -ForegroundColor DarkGray
Write-Host "==========================================================================" -ForegroundColor Cyan

if ($actionCount -eq 0) {
    Write-Host "`n[+] SUCCESS: All required engineering toolchains are active and verified." -ForegroundColor Green
    Write-Host "    This machine is fully configured to develop all primary first-party projects." -ForegroundColor Green
} else {
    Write-Host "`n[!] ATTENTION: $actionCount required toolchains are missing." -ForegroundColor Yellow
    Write-Host "    Review the highlighted consumers above and install via Scoop, Winget, or official installers." -ForegroundColor Gray
}
Write-Host ""

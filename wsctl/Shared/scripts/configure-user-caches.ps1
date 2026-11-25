<#
.SYNOPSIS
    User Cache Configuration Helper (configure-user-caches.ps1)

.DESCRIPTION
    Non-destructive helper script to inspect and optionally configure User-level development cache variables.
    Target recommendations:
      - HF_HOME       -> E:\AI_Models\HF_CACHE  (Centralize Hugging Face transformer weights on E:)
      - OLLAMA_MODELS -> E:\AI_Models\OLLAMA    (Already set; verifies persistence)
      - UV_CACHE_DIR  -> Retained on C:\Users\hp\scoop\persist\uv\cache for SSD throughput

    SAFETY:
    - Runs in DRY-RUN mode by default.
    - Requires explicit '-Apply' parameter and user confirmation to alter environment variables.
    - NEVER touches machine/system registry or secret variables.

.EXAMPLE
    # Inspect current status (Dry-Run, 100% safe)
    .\configure-user-caches.ps1

    # Apply proposed User environment variable after manual review
    .\configure-user-caches.ps1 -Apply
#>

[CmdletBinding()]
param (
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host "                  DEVELOPMENT USER CACHE CONFIGURATOR                     " -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host " Execution Mode: $(if ($Apply) { 'APPLY (Modifications Enabled)' } else { 'DRY-RUN (Inspection Only)' })" -ForegroundColor $(if ($Apply) { "Yellow" } else { "Green" })
Write-Host " Timestamp     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host ""

$cacheSpecs = @(
    @{
        Variable = "OLLAMA_MODELS"
        Current  = [System.Environment]::GetEnvironmentVariable("OLLAMA_MODELS", "User")
        Proposed = "E:\AI_Models\OLLAMA"
        Reason   = "Directs Ollama local models to canonical high-capacity storage on E:"
        Status   = ""
    },
    @{
        Variable = "HF_HOME"
        Current  = [System.Environment]::GetEnvironmentVariable("HF_HOME", "User")
        Proposed = "E:\AI_Models\HF_CACHE"
        Reason   = "Directs Hugging Face model downloads and tokenizers to canonical storage on E:"
        Status   = ""
    },
    @{
        Variable = "UV_CACHE_DIR"
        Current  = [System.Environment]::GetEnvironmentVariable("UV_CACHE_DIR", "User")
        Proposed = "C:\Users\hp\scoop\persist\uv\cache"
        Reason   = "Preserved on fast NVMe system SSD (C:) for maximum wheel build and install speed"
        Status   = ""
    }
)

foreach ($c in $cacheSpecs) {
    Write-Host "VARIABLE: $($c.Variable)" -ForegroundColor White
    Write-Host "  Current Value : $(if ($c.Current) { $c.Current } else { '<not set (defaults to user home profile)>' })" -ForegroundColor DarkGray
    Write-Host "  Proposed Value: $($c.Proposed)" -ForegroundColor Cyan
    Write-Host "  Rationale     : $($c.Reason)" -ForegroundColor Gray

    $isAligned = ($c.Current -eq $c.Proposed)
    if ($isAligned) {
        Write-Host "  Alignment     : [ALREADY CONFIGURED CORRECTLY]" -ForegroundColor Green
    } else {
        Write-Host "  Alignment     : [RECOMMENDED UPDATE AVAILABLE]" -ForegroundColor Yellow
        
        if ($Apply) {
            Write-Host "  [*] Updating User environment variable $($c.Variable)..." -ForegroundColor Yellow
            [System.Environment]::SetEnvironmentVariable($c.Variable, $c.Proposed, "User")
            Write-Host "  [+] Set $($c.Variable) = $($c.Proposed)" -ForegroundColor Green
        }
    }
    Write-Host ""
}

Write-Host "==========================================================================" -ForegroundColor Cyan
if (-not $Apply) {
    Write-Host "DRY-RUN COMPLETE: No environment variables were modified." -ForegroundColor Green
    Write-Host "To apply the recommended User environment variables, run:" -ForegroundColor DarkGray
    Write-Host "  .\configure-user-caches.ps1 -Apply`n" -ForegroundColor DarkCyan
} else {
    Write-Host "UPDATE COMPLETE: User environment variables updated successfully." -ForegroundColor Green
    Write-Host "Note: Newly spawned shells and applications will automatically pick up the changes.`n" -ForegroundColor Gray
}

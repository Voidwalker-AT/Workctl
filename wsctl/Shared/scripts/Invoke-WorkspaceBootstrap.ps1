<#
.SYNOPSIS
    Bootstraps the workspace environment and validates required external infrastructure.

.DESCRIPTION
    This script asserts the system state for the E:\Workspace personal engineering platform.
    It verifies that necessary environment variables (JAVA_HOME, OLLAMA_MODELS) are set and 
    that critical CLI tools (nvm, java) are available in the PATH.

    It does NOT forcefully modify the system path unless explicitly requested.
#>

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[-] $Message" -ForegroundColor Red
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

Write-Host "=============================================" -ForegroundColor Magenta
Write-Host "  Workspace Operational Bootstrap Validator" -ForegroundColor Magenta
Write-Host "=============================================" -ForegroundColor Magenta
Write-Host ""

$failedChecks = 0

# 1. Check AI Infrastructure
Write-Step "Validating AI Infrastructure environment..."
if ([string]::IsNullOrEmpty($env:OLLAMA_MODELS)) {
    Write-Warn "OLLAMA_MODELS environment variable is not set."
    Write-Host "    Expected: E:\AI_Models\OLLAMA" -ForegroundColor Gray
    Write-Host "    You should set this globally to ensure active AI projects map to external storage." -ForegroundColor Gray
    $failedChecks++
} elseif ($env:OLLAMA_MODELS -ne "E:\AI_Models\OLLAMA") {
    Write-Warn "OLLAMA_MODELS is set to '$($env:OLLAMA_MODELS)', but expected 'E:\AI_Models\OLLAMA'."
    $failedChecks++
} else {
    Write-Pass "OLLAMA_MODELS points to correct canonical path ($env:OLLAMA_MODELS)."
}

# 2. Check NVM / Node
Write-Step "Validating Node.js Environment (nvm-windows)..."
if (Get-Command "nvm" -ErrorAction SilentlyContinue) {
    Write-Pass "nvm is installed and available in PATH."
} else {
    Write-Warn "nvm-windows is not found in PATH."
    Write-Host "    [Informational] Node.js tooling is treated as reusable shared infrastructure." -ForegroundColor Gray
    Write-Host "    Recommended Source: https://github.com/coreybutler/nvm-windows" -ForegroundColor Gray
    Write-Host "    Expected Behavior: The installer will automatically add NVM_HOME and NVM_SYMLINK to your system PATH." -ForegroundColor Gray
    Write-Host "    You may install this manually when Node.js workflows are required." -ForegroundColor Gray
    # Missing nvm is considered an informational warning, not a workspace infrastructure failure.
}

# 3. Check Java / Gradle assumptions
Write-Step "Validating Java Environment..."
if ([string]::IsNullOrEmpty($env:JAVA_HOME)) {
    Write-Warn "JAVA_HOME environment variable is not set."
    Write-Host "    Consider using SDKMAN! or a local script to manage JDK paths." -ForegroundColor Gray
    $failedChecks++
} else {
    Write-Pass "JAVA_HOME is set to: $env:JAVA_HOME"
}

# 4. Canonical Archive Check
Write-Step "Validating External Archival Path..."
if (Test-Path "E:\ARCHIVE") {
    Write-Pass "Canonical archive E:\ARCHIVE exists."
} else {
    Write-Warn "Canonical archive E:\ARCHIVE does not exist. (Creating it now...)"
    try {
        New-Item -Path "E:\ARCHIVE" -ItemType Directory -Force | Out-Null
        Write-Pass "Created E:\ARCHIVE"
    } catch {
        Write-Fail "Failed to create E:\ARCHIVE. Check permissions."
    }
}

Write-Host ""
if ($failedChecks -gt 0) {
    Write-Warn "Bootstrap validation completed with $failedChecks warnings/failures."
} else {
    Write-Pass "Workspace environment is correctly bootstrapped and ready!"
}

Write-Host "=============================================" -ForegroundColor Magenta

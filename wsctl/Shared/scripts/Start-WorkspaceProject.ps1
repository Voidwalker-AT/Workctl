<##
.SYNOPSIS
    Opens a workspace project and interactively selects a Python environment.

.DESCRIPTION
    This is an opt-in helper for projects that use Python. It discovers the
    shared ds-base environment and common local environments, allows the user
    to skip activation, or guides creation of a new local .venv.

    Dot-source this script from PowerShell if you want activation to persist:
        . E:\Workspace\Shared\scripts\Start-WorkspaceProject.ps1
##>

[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$project = (Resolve-Path -LiteralPath $ProjectPath).Path
$sharedEnvs = 'E:\Workspace\Shared\envs'
$candidates = [System.Collections.Generic.List[object]]::new()

if (Test-Path -LiteralPath $sharedEnvs) {
    Get-ChildItem -LiteralPath $sharedEnvs -Directory -Force | ForEach-Object {
        $candidates.Add([pscustomobject]@{ Name = "Shared: $($_.Name)"; Path = $_.FullName; Kind = 'Shared' })
    }
}

$localNames = @('.venv', 'venv', 'ENV', 'env', '.conda', 'conda', 'myenv', 'llm_env')
Get-ChildItem -LiteralPath $project -Directory -Force | Where-Object { $localNames -contains $_.Name } | ForEach-Object {
    $candidates.Add([pscustomobject]@{ Name = "Local: $($_.Name)"; Path = $_.FullName; Kind = 'Local' })
}

Write-Host "Project: $project" -ForegroundColor Cyan
Write-Host 'Choose a Python environment:' -ForegroundColor Cyan
for ($i = 0; $i -lt $candidates.Count; $i++) {
    Write-Host ("[{0}] {1} -> {2}" -f ($i + 1), $candidates[$i].Name, $candidates[$i].Path)
}
$skipNumber = $candidates.Count + 1
$newNumber = $candidates.Count + 2
Write-Host "[$skipNumber] Skip environment activation"
Write-Host "[$newNumber] Create a new local environment"

$choice = Read-Host 'Selection'
if ($choice -eq $skipNumber) {
    Set-Location -LiteralPath $project
    Write-Host 'Environment activation skipped.' -ForegroundColor Yellow
    return
}

if ($choice -eq $newNumber) {
    $name = Read-Host 'Environment folder name (default: .venv)'
    if ([string]::IsNullOrWhiteSpace($name)) { $name = '.venv' }
    $newPath = Join-Path $project $name
    if (Test-Path -LiteralPath $newPath) { throw "Environment path already exists: $newPath" }
    Write-Host 'Recommended: Python venv (local and isolated). Choose conda only if the project needs compiled/data-science packages.' -ForegroundColor Yellow
    $kind = Read-Host 'Type venv or conda (default: venv)'
    if ([string]::IsNullOrWhiteSpace($kind) -or $kind -eq 'venv') {
        if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw 'Python was not found on PATH. Install/configure Python, then retry.' }
        python -m venv $newPath
        $selected = $newPath
    } elseif ($kind -eq 'conda') {
        if (-not (Get-Command conda -ErrorAction SilentlyContinue)) { throw 'Conda was not found on PATH. Install/configure Conda, then retry.' }
        conda create --prefix $newPath python -y
        $selected = $newPath
    } else {
        throw "Unknown environment type '$kind'. Choose venv or conda."
    }
    Write-Host "Created: $selected" -ForegroundColor Green
} elseif ($choice -as [int] -and [int]$choice -ge 1 -and [int]$choice -le $candidates.Count) {
    $selected = $candidates[[int]$choice - 1].Path
} else {
    throw 'Invalid selection.'
}

Set-Location -LiteralPath $project
$activate = Join-Path $selected 'Scripts\Activate.ps1'
if (Test-Path -LiteralPath $activate) {
    . $activate
    Write-Host "Activated: $selected" -ForegroundColor Green
} else {
    Write-Host "Selected environment: $selected" -ForegroundColor Green
    Write-Host 'This environment does not expose a PowerShell activation script. Use its native activation command if needed.' -ForegroundColor Yellow
}

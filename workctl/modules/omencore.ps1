# =================================================================
# WorkCtl Subsystem: OmenCore & HP Hardware Management
# =================================================================
# Integrates HP Victus 15-fa1xxx (Product ID 8C3F) laptop control.
# Enforces mutual-exclusion fan-control interlock with FanControl.

$script:OmenCliDllPath = "E:\Workspace\Tools\OmenCore\src\OmenCore.Cli\bin\Release\net8.0-windows10.0.19041.0\win-x64\omencore-cli.dll"

function Get-OmenCoreCliPath {
    if (Test-Path -LiteralPath $script:OmenCliDllPath) {
        return $script:OmenCliDllPath
    }
    return $null
}

function Get-OmenCoreStatus {
    $dll = Get-OmenCoreCliPath
    if (!$dll) {
        return [PSCustomObject]@{
            Installed = $false
            Error = "omencore-cli.dll not found at $script:OmenCliDllPath"
        }
    }
    
    try {
        $raw = & dotnet $dll status -j 2>&1
        $jsonStr = $raw -join "`n"
        $statusObj = $jsonStr | ConvertFrom-Json
        return [PSCustomObject]@{
            Installed = $true
            Version = $statusObj.version
            Model = $statusObj.model.modelName
            ProductId = $statusObj.model.productId
            BoardId = $statusObj.model.boardId
            EcAvailable = $statusObj.ecAccess.available
            FanBackend = $statusObj.fanController.backend
            FanStatus = $statusObj.fanController.status
            CapabilityWarning = $statusObj.capabilityWarning
            Raw = $statusObj
        }
    } catch {
        return [PSCustomObject]@{
            Installed = $true
            Error = $_.Exception.Message
            Model = "Victus by HP Gaming Laptop 15-fa1xxx"
            ProductId = "8C3F"
            EcAvailable = $false
            FanBackend = "None (monitoring only)"
            CapabilityWarning = "Secure Boot enabled - WMI monitoring active"
        }
    }
}

function Get-WorkCtlHardwareFanOwner {
    # Check if FanControl is running
    $fcProc = Get-Process -Name "FanControl" -ErrorAction SilentlyContinue | Select-Object -First 1
    $fcRunning = ($null -ne $fcProc)
    
    # Check if OmenCore daemon is running
    $omenProc = Get-Process -Name "omencore-cli" -ErrorAction SilentlyContinue | Select-Object -First 1
    $omenRunning = ($null -ne $omenProc)
    
    if ($fcRunning -and $omenRunning) {
        return "CONFLICT"
    } elseif ($fcRunning) {
        return "FANCONTROL"
    } elseif ($omenRunning) {
        return "OMENCORE"
    } else {
        return "BIOS AUTO"
    }
}

function Assert-WorkCtlFanMutationAllowed {
    param(
        [ValidateSet("OMENCORE", "FANCONTROL")][string]$TargetController,
        $MockOwner = $null
    )
    
    $owner = if ($MockOwner) { $MockOwner } else { Get-WorkCtlHardwareFanOwner }
    if ($owner -eq "CONFLICT") {
        throw "CRITICAL HARDWARE CONFLICT: Both FanControl and OmenCore are running. Terminate one before modifying fan curves."
    }
    
    if ($TargetController -eq "OMENCORE" -and $owner -eq "FANCONTROL") {
        throw "INTERLOCK BLOCKED: FanControl currently owns fan controls. Close FanControl first."
    }
    
    if ($TargetController -eq "FANCONTROL" -and $owner -eq "OMENCORE") {
        throw "INTERLOCK BLOCKED: OmenCore daemon currently owns fan controls. Stop OmenCore daemon first."
    }
    
    return
}

# =================================================================
# WorkCtl v1.5 - PowerToys Subsystem & Interactive Control Plane
# Hierarchical Category Architecture & Responsive TUI Engine
# =================================================================

$script:PTRoot = "$env:LOCALAPPDATA\PowerToys"
$script:PTConfigRoot = "$env:LOCALAPPDATA\Microsoft\PowerToys"
$script:PTGlobalConfig = Join-Path $script:PTConfigRoot "settings.json"
$script:PTDscRoot = Join-Path $script:PTRoot "DSCModules"

# =================================================================
# Process Mappings
# =================================================================

$script:PTProcessMap = [ordered]@{
    "AdvancedPaste"          = @("PowerToys.AdvancedPaste.exe")
    "AlwaysOnTop"            = @("PowerToys.AlwaysOnTop.exe")
    "Awake"                  = @("PowerToys.Awake.exe")
    "CmdPal"                 = @("Microsoft.CmdPal.UI.exe", "Microsoft.CmdPal.Ext.*")
    "ColorPicker"            = @("PowerToys.ColorPickerUI.exe")
    "CropAndLock"            = @("PowerToys.CropAndLock.exe")
    "EnvironmentVariables"   = @("PowerToys.EnvironmentVariables.exe")
    "FancyZones"             = @("PowerToys.FancyZones.exe")
    "File Locksmith"         = @("PowerToys.FileLocksmithUI.exe")
    "FindMyMouse"            = @("PowerToys.FindMyMouse.exe")
    "GrabAndMove"            = @("PowerToys.GrabAndMove.exe")
    "Hosts"                  = @("PowerToys.Hosts.exe")
    "Image Resizer"          = @("PowerToys.ImageResizer.exe")
    "Keyboard Manager"       = @("PowerToys.KeyboardManagerEngine.exe", "PowerToys.KeyboardManagerEditor.exe")
    "LightSwitch"            = @("PowerToys.LightSwitchService.exe")
    "Measure Tool"           = @("PowerToys.MeasureToolUI.exe")
    "MouseHighlighter"       = @("PowerToys.MouseHighlighter.exe")
    "MouseJump"              = @("PowerToys.MouseJumpUI.exe")
    "MousePointerCrosshairs" = @("PowerToys.MousePointerCrosshairs.exe")
    "MouseWithoutBorders"    = @("PowerToys.MouseWithoutBorders.exe")
    "NewPlus"                = @("PowerToys.NewPlus.exe")
    "Peek"                   = @("PowerToys.Peek.UI.exe")
    "PowerDisplay"           = @("PowerToys.PowerDisplay.exe")
    "PowerRename"            = @("PowerToys.PowerRename.exe")
    "PowerToys Run"          = @("PowerToys.PowerLauncher.exe")
    "QuickAccent"            = @("PowerToys.PowerAccent.exe")
    "RegistryPreview"        = @("PowerToys.RegistryPreview.exe")
    "Shortcut Guide"         = @("PowerToys.ShortcutGuide.exe")
    "TextExtractor"          = @("PowerToys.PowerOCR.exe")
    "Workspaces"             = @("PowerToys.WorkspacesLauncher.exe", "PowerToys.WorkspacesEditor.exe")
    "ZoomIt"                 = @("PowerToys.ZoomIt.exe")
}

# =================================================================
# Hierarchical Category Taxonomy
# =================================================================

$script:PTCategories = [ordered]@{
    "Window & Desktop"   = @("FancyZones", "AlwaysOnTop", "CropAndLock", "Workspaces", "Peek")
    "Productivity"       = @("AdvancedPaste", "ColorPicker", "TextExtractor", "Measure Tool", "QuickAccent", "NewPlus")
    "Mouse & Input"      = @("Keyboard Manager", "FindMyMouse", "MouseHighlighter", "MouseJump", "MousePointerCrosshairs", "MouseWithoutBorders", "CursorWrap", "GrabAndMove")
    "Files & Explorer"   = @("File Explorer Preview", "File Locksmith", "Image Resizer", "PowerRename", "RegistryPreview")
    "System & Utilities" = @("Awake", "EnvironmentVariables", "Hosts", "LightSwitch", "PowerDisplay", "Shortcut Guide", "ZoomIt")
    "Launchers"          = @("CmdPal", "PowerToys Run")
    "Developer / Shell"  = @("CmdNotFound")
}

# =================================================================
# Educational Metadata for all 34 PowerToys Modules
# =================================================================

$script:PTModuleMetadata = [ordered]@{
    "AdvancedPaste" = [PSCustomObject]@{
        Name = "AdvancedPaste"
        Category = "Productivity"
        Description = "AI-powered clipboard formatting and text transformation utility."
        Shortcut = "Win + Shift + V"
        Residency = "On-Demand (Hotkey Hook)"
        DisableImpact = "Advanced paste window disabled; native Windows clipboard (Win+V) remains active."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "AdvancedPaste"
        DSCResource = "microsoft.powertoys.AdvancedPaste.settings.dsc.resource.json"
    }

    "AlwaysOnTop" = [PSCustomObject]@{
        Name = "AlwaysOnTop"
        Category = "Window & Desktop"
        Description = "Pins any active application window to stay floating on top of all others."
        Shortcut = "Win + Ctrl + T"
        Residency = "On-Demand (Hotkey Hook)"
        DisableImpact = "Pinned windows will unpin and behave with standard z-order."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "AlwaysOnTop"
        DSCResource = "microsoft.powertoys.AlwaysOnTop.settings.dsc.resource.json"
    }

    "Awake" = [PSCustomObject]@{
        Name = "Awake"
        Category = "System & Utilities"
        Description = "Keeps the workstation awake on-demand without altering Windows power plans."
        Shortcut = "System Tray Icon / CLI"
        Residency = "Resident (Background Process)"
        DisableImpact = "System sleep and screen timeout revert to Windows power settings."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "Awake"
        DSCResource = "microsoft.powertoys.Awake.settings.dsc.resource.json"
    }

    "CmdNotFound" = [PSCustomObject]@{
        Name = "CmdNotFound"
        Category = "Developer / Shell"
        Description = "PowerShell predictor that suggests winget package installations for missing commands."
        Shortcut = "Automatic on PowerShell command error"
        Residency = "PowerShell Module Extension"
        DisableImpact = "Missing command suggestions will not appear in PowerShell sessions."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "CmdNotFound"
        DSCResource = "microsoft.powertoys.CmdNotFound.settings.dsc.resource.json"
    }

    "CmdPal" = [PSCustomObject]@{
        Name = "CmdPal"
        Category = "Launchers"
        Description = "Next-generation Command Palette extension and quick-launcher for Windows."
        Shortcut = "Win + Alt + Space"
        Residency = "Resident (Background Service Host)"
        DisableImpact = "Command Palette interface cannot be summoned."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "CmdPal"
        DSCResource = "microsoft.powertoys.CmdPal.settings.dsc.resource.json"
    }

    "ColorPicker" = [PSCustomObject]@{
        Name = "ColorPicker"
        Category = "Productivity"
        Description = "System-wide screen color picker and palette inspector for designers and developers."
        Shortcut = "Win + Shift + C"
        Residency = "On-Demand (Hotkey Hook)"
        DisableImpact = "Color picker overlay will not summon."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "ColorPicker"
        DSCResource = "microsoft.powertoys.ColorPicker.settings.dsc.resource.json"
    }

    "CropAndLock" = [PSCustomObject]@{
        Name = "CropAndLock"
        Category = "Window & Desktop"
        Description = "Crops an application window into an interactive mini-view or thumbnail."
        Shortcut = "Win + Ctrl + Shift + T (Thumbnail) / R (Reparent)"
        Residency = "On-Demand (Hotkey Hook)"
        DisableImpact = "Window cropping shortcuts will not respond."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "CropAndLock"
        DSCResource = "microsoft.powertoys.CropAndLock.settings.dsc.resource.json"
    }

    "CursorWrap" = [PSCustomObject]@{
        Name = "CursorWrap"
        Category = "Mouse & Input"
        Description = "Wraps mouse cursor movement around display edges across multi-monitor setups."
        Shortcut = "Automatic on screen boundary crossing"
        Residency = "On-Demand (Mouse Hook)"
        DisableImpact = "Cursor stops at display borders normally."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "CursorWrap"
        DSCResource = "microsoft.powertoys.CursorWrap.settings.dsc.resource.json"
    }

    "EnvironmentVariables" = [PSCustomObject]@{
        Name = "EnvironmentVariables"
        Category = "System & Utilities"
        Description = "Manager for user and system environment variables with profile management."
        Shortcut = "PowerToys Settings or Win + R 'env'"
        Residency = "On-Demand (GUI Tool)"
        DisableImpact = "Environment variable editor interface is disabled."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "EnvironmentVariables"
        DSCResource = "microsoft.powertoys.EnvironmentVariables.settings.dsc.resource.json"
    }

    "FancyZones" = [PSCustomObject]@{
        Name = "FancyZones"
        Category = "Window & Desktop"
        Description = "Window tiling manager for creating custom grid layouts and snapping windows efficiently."
        Shortcut = "Win + Shift + ` (Editor) / Shift + Drag Window"
        Residency = "On-Demand (Window Drag Hook)"
        DisableImpact = "Zone grid snapping ceases; standard Windows snap remains."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "FancyZones"
        DSCResource = "microsoft.powertoys.FancyZones.settings.dsc.resource.json"
    }

    "File Explorer Preview" = [PSCustomObject]@{
        Name = "File Explorer Preview"
        Category = "Files & Explorer"
        Description = "Preview pane handlers for Markdown, SVG, PDF, G-code, and developer files in File Explorer."
        Shortcut = "File Explorer Preview Pane (Alt + P)"
        Residency = "Shell Extension (In-Process DLL)"
        DisableImpact = "Rich preview for developer formats in File Explorer is disabled."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "File Explorer"
        DSCResource = "microsoft.powertoys.FileExplorerPreview.settings.dsc.resource.json"
    }

    "File Locksmith" = [PSCustomObject]@{
        Name = "File Locksmith"
        Category = "Files & Explorer"
        Description = "Windows shell extension to discover which processes are locking a selected file."
        Shortcut = "Right-click file > 'What is using this file?'"
        Residency = "Shell Extension / On-Demand"
        DisableImpact = "Context menu option to inspect locking processes is removed."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "File Locksmith"
        DSCResource = "microsoft.powertoys.FileLocksmith.settings.dsc.resource.json"
    }

    "FindMyMouse" = [PSCustomObject]@{
        Name = "FindMyMouse"
        Category = "Mouse & Input"
        Description = "Focuses a spotlight on the mouse cursor position when shaking mouse or double-pressing Ctrl."
        Shortcut = "Double-press Left Ctrl or Shake Mouse"
        Residency = "On-Demand (Mouse Hook)"
        DisableImpact = "Spotlight indicator will not trigger."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "FindMyMouse"
        DSCResource = "microsoft.powertoys.FindMyMouse.settings.dsc.resource.json"
    }

    "GrabAndMove" = [PSCustomObject]@{
        Name = "GrabAndMove"
        Category = "Mouse & Input"
        Description = "Allows dragging and moving windows by clicking anywhere within their client area."
        Shortcut = "Alt + Left Click Drag"
        Residency = "On-Demand (Mouse Hook)"
        DisableImpact = "Client area window dragging will not respond."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "GrabAndMove"
        DSCResource = "microsoft.powertoys.GrabAndMove.settings.dsc.resource.json"
    }

    "Hosts" = [PSCustomObject]@{
        Name = "Hosts"
        Category = "System & Utilities"
        Description = "Modern editor for the Windows Hosts file (domain-to-IP local overrides)."
        Shortcut = "PowerToys Settings > Hosts"
        Residency = "On-Demand (GUI Tool)"
        DisableImpact = "Hosts file GUI editor cannot be launched."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "Hosts"
        DSCResource = "microsoft.powertoys.Hosts.settings.dsc.resource.json"
    }

    "Image Resizer" = [PSCustomObject]@{
        Name = "Image Resizer"
        Category = "Files & Explorer"
        Description = "Context menu shell extension for batch resizing image files directly in File Explorer."
        Shortcut = "Right-click image(s) > 'Resize pictures'"
        Residency = "Shell Extension / On-Demand"
        DisableImpact = "Image resizing entry removed from Explorer context menu."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "Image Resizer"
        DSCResource = "microsoft.powertoys.ImageResizer.settings.dsc.resource.json"
    }

    "Keyboard Manager" = [PSCustomObject]@{
        Name = "Keyboard Manager"
        Category = "Mouse & Input"
        Description = "Keyboard remapper for individual keys and global multi-key shortcut combinations."
        Shortcut = "Global key remap engine"
        Residency = "Resident (Engine Process)"
        DisableImpact = "Custom key and shortcut remaps are deactivated."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "Keyboard Manager"
        DSCResource = "microsoft.powertoys.KeyboardManager.settings.dsc.resource.json"
    }

    "LightSwitch" = [PSCustomObject]@{
        Name = "LightSwitch"
        Category = "System & Utilities"
        Description = "Automates switching between light and dark Windows system themes on a schedule."
        Shortcut = "Scheduled / Sunrise & Sunset"
        Residency = "Resident Background Service"
        DisableImpact = "Automated theme switching is disabled."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "LightSwitch"
        DSCResource = "microsoft.powertoys.LightSwitch.settings.dsc.resource.json"
    }

    "Measure Tool" = [PSCustomObject]@{
        Name = "Measure Tool"
        Category = "Productivity"
        Description = "Screen ruler to measure on-screen pixel dimensions, spacing, and bounding boxes."
        Shortcut = "Win + Shift + M"
        Residency = "On-Demand (Hotkey Hook)"
        DisableImpact = "Screen ruler overlay will not summon."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "Measure Tool"
        DSCResource = "microsoft.powertoys.MeasureTool.settings.dsc.resource.json"
    }

    "MouseHighlighter" = [PSCustomObject]@{
        Name = "MouseHighlighter"
        Category = "Mouse & Input"
        Description = "Highlights left and right mouse clicks with colored visual circles for presentations."
        Shortcut = "Win + Shift + H"
        Residency = "On-Demand (Mouse Hook)"
        DisableImpact = "Mouse click visual highlights stop appearing."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "MouseHighlighter"
        DSCResource = "microsoft.powertoys.MouseHighlighter.settings.dsc.resource.json"
    }

    "MouseJump" = [PSCustomObject]@{
        Name = "MouseJump"
        Category = "Mouse & Input"
        Description = "Allows jumping the pointer across large or multi-screen setups via a thumbnail overlay."
        Shortcut = "Win + Shift + D"
        Residency = "On-Demand (Hotkey Hook)"
        DisableImpact = "Thumbnail screen jump overlay will not summon."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "MouseJump"
        DSCResource = "microsoft.powertoys.MouseJump.settings.dsc.resource.json"
    }

    "MousePointerCrosshairs" = [PSCustomObject]@{
        Name = "MousePointerCrosshairs"
        Category = "Mouse & Input"
        Description = "Draws full-screen crosshairs centered on the mouse pointer for visual accessibility."
        Shortcut = "Win + Alt + P"
        Residency = "On-Demand (Mouse Hook)"
        DisableImpact = "Mouse crosshairs overlay will not summon."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "MousePointerCrosshairs"
        DSCResource = "microsoft.powertoys.MousePointerCrosshairs.settings.dsc.resource.json"
    }

    "MouseWithoutBorders" = [PSCustomObject]@{
        Name = "MouseWithoutBorders"
        Category = "Mouse & Input"
        Description = "Share keyboard and mouse seamlessly between up to four Windows PCs across a local network."
        Shortcut = "Edge crossing / Ctrl + Alt + F1..F4"
        Residency = "Resident (Background Service)"
        DisableImpact = "Multi-PC mouse and keyboard sharing stops."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "MouseWithoutBorders"
        DSCResource = "microsoft.powertoys.MouseWithoutBorders.settings.dsc.resource.json"
    }

    "NewPlus" = [PSCustomObject]@{
        Name = "NewPlus"
        Category = "Productivity"
        Description = "Creates custom files and directory structures from user templates in File Explorer."
        Shortcut = "File Explorer Context Menu > New+"
        Residency = "Shell Extension"
        DisableImpact = "New+ entry removed from File Explorer context menu."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "NewPlus"
        DSCResource = "microsoft.powertoys.NewPlus.settings.dsc.resource.json"
    }

    "Peek" = [PSCustomObject]@{
        Name = "Peek"
        Category = "Window & Desktop"
        Description = "Instant quick-look file preview for images, code, and documents directly in Explorer."
        Shortcut = "Ctrl + Space"
        Residency = "On-Demand (Hotkey Hook)"
        DisableImpact = "Instant file preview window will not summon."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "Peek"
        DSCResource = "microsoft.powertoys.Peek.settings.dsc.resource.json"
    }

    "PowerDisplay" = [PSCustomObject]@{
        Name = "PowerDisplay"
        Category = "System & Utilities"
        Description = "Display management tool for quick adjustments to brightness, color profiles, and rotation."
        Shortcut = "PowerToys Settings"
        Residency = "On-Demand (GUI Tool)"
        DisableImpact = "Display management shortcuts and controls are disabled."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "PowerDisplay"
        DSCResource = "microsoft.powertoys.PowerDisplay.settings.dsc.resource.json"
    }

    "PowerRename" = [PSCustomObject]@{
        Name = "PowerRename"
        Category = "Files & Explorer"
        Description = "Batch file renaming utility supporting regex pattern matching, search/replace, and live preview."
        Shortcut = "Right-click file(s) > 'PowerRename'"
        Residency = "Shell Extension / On-Demand"
        DisableImpact = "PowerRename action removed from File Explorer context menu."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "PowerRename"
        DSCResource = "microsoft.powertoys.PowerRename.settings.dsc.resource.json"
    }

    "PowerToys Run" = [PSCustomObject]@{
        Name = "PowerToys Run"
        Category = "Launchers"
        Description = "Quick application launcher and search bar with plugins for calc, shell, windows, and units."
        Shortcut = "Alt + Space"
        Residency = "Resident (Launcher Engine Process)"
        DisableImpact = "Alt+Space launcher overlay stops responding."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "PowerToys Run"
        DSCResource = "microsoft.powertoys.PowerToysRun.settings.dsc.resource.json"
    }

    "QuickAccent" = [PSCustomObject]@{
        Name = "QuickAccent"
        Category = "Productivity"
        Description = "Quick accented character selector when holding a letter key and pressing Space or arrows."
        Shortcut = "Hold letter key + Space / Left / Right"
        Residency = "On-Demand (Keyboard Hook)"
        DisableImpact = "Accented character selector overlay stops appearing."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "QuickAccent"
        DSCResource = "microsoft.powertoys.QuickAccent.settings.dsc.resource.json"
    }

    "RegistryPreview" = [PSCustomObject]@{
        Name = "RegistryPreview"
        Category = "Files & Explorer"
        Description = "Visualizer and editor for Windows Registry (.reg) files with before-and-after tree diff."
        Shortcut = "Right-click .reg file > 'Preview'"
        Residency = "On-Demand (GUI Tool)"
        DisableImpact = "Registry preview context menu option removed."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "RegistryPreview"
        DSCResource = "microsoft.powertoys.RegistryPreview.settings.dsc.resource.json"
    }

    "Shortcut Guide" = [PSCustomObject]@{
        Name = "Shortcut Guide"
        Category = "System & Utilities"
        Description = "Full-screen overlay showing available Windows key shortcuts for the active application context."
        Shortcut = "Win + Shift + /"
        Residency = "On-Demand (Hotkey Hook)"
        DisableImpact = "Shortcut guide overlay will not summon."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "Shortcut Guide"
        DSCResource = "microsoft.powertoys.ShortcutGuide.settings.dsc.resource.json"
    }

    "TextExtractor" = [PSCustomObject]@{
        Name = "TextExtractor"
        Category = "Productivity"
        Description = "Optical character recognition (OCR) utility to extract and copy text from any screen region."
        Shortcut = "Win + Shift + T"
        Residency = "On-Demand (Hotkey Hook)"
        DisableImpact = "Screen text OCR capture tool stops responding."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "TextExtractor"
        DSCResource = "microsoft.powertoys.TextExtractor.settings.dsc.resource.json"
    }

    "Workspaces" = [PSCustomObject]@{
        Name = "Workspaces"
        Category = "Window & Desktop"
        Description = "Captures and restores arrangements of multiple desktop applications with a single click."
        Shortcut = "Win + Ctrl + ` / Workspaces Editor"
        Residency = "On-Demand (Launcher / Editor)"
        DisableImpact = "Workspaces trigger hotkeys and launch actions cease."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "Workspaces"
        DSCResource = "microsoft.powertoys.Workspaces.settings.dsc.resource.json"
    }

    "ZoomIt" = [PSCustomObject]@{
        Name = "ZoomIt"
        Category = "System & Utilities"
        Description = "Screen zoom, annotation, and countdown timer utility for technical presentations."
        Shortcut = "Ctrl + 1 (Zoom) / Ctrl + 2 (Draw)"
        Residency = "Resident (Background Utility)"
        DisableImpact = "Screen zoom and drawing shortcuts stop responding."
        SafetyNote = "Safe read-only utility. Managed by PowerToys."
        ConfigSubdir = "ZoomIt"
        DSCResource = "microsoft.powertoys.ZoomIt.settings.dsc.resource.json"
    }
}

# =================================================================
# Backend Discovery Functions (READ-ONLY)
# =================================================================

function Get-PowerToysConfig {

    if (!(Test-Path -LiteralPath $script:PTGlobalConfig)) {
        throw "PowerToys global configuration not found: $script:PTGlobalConfig"
    }

    try {
        Get-Content -LiteralPath $script:PTGlobalConfig -Raw |
            ConvertFrom-Json
    } catch {
        throw "PowerToys configuration is invalid: $($_.Exception.Message)"
    }
}

function Get-PowerToysProcesses {

    @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith(
                $script:PTRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
    )
}

function Test-PTProcessMatch($ProcessName, $Patterns) {

    foreach ($pattern in @($Patterns)) {
        if ($ProcessName -like $pattern) {
            return $true
        }
    }

    return $false
}

# Optimized PowerToys Snapshot Engine (PRESERVED & CANONICAL)
function Get-PowerToysSnapshot {

    $cfg = Get-PowerToysConfig

    # ONE process enumeration for the entire snapshot
    $all = @(Get-PowerToysProcesses)

    # Build RAM lookup once
    $procInfo = @{}

    foreach ($x in $all) {
        $ram = [int64]0
        try {
            $gp = Get-Process -Id $x.ProcessId -ErrorAction Stop
            $ram = $gp.WorkingSet64
        } catch {}

        $procInfo[[int]$x.ProcessId] = [PSCustomObject]@{
            Process = $x
            RAMBytes = $ram
        }
    }

    $mods = New-Object System.Collections.Generic.List[object]

    foreach ($p in $cfg.enabled.PSObject.Properties) {

        $name = $p.Name
        $enabled = [bool]$p.Value

        $patterns = @()
        if ($script:PTProcessMap.Contains($name)) {
            $patterns = @($script:PTProcessMap[$name])
        }

        $matched = @()
        if ($patterns.Count -gt 0) {
            foreach ($x in $all) {
                if (Test-PTProcessMatch $x.Name $patterns) {
                    $matched += $x
                }
            }
        }

        $ram = [int64]0
        foreach ($x in $matched) {
            $id = [int]$x.ProcessId
            if ($procInfo.ContainsKey($id)) {
                $ram += $procInfo[$id].RAMBytes
            }
        }

        $runtime = if ($matched.Count -gt 0) {
            "RUNNING"
        } elseif ($enabled) {
            "IDLE"
        } else {
            "OFF"
        }

        $mods.Add(
            [PSCustomObject]@{
                Module = $name
                Enabled = $enabled
                Runtime = $runtime
                Processes = $matched.Count
                RAM_MB = [math]::Round($ram / 1MB, 1)
                Mapped = ($patterns.Count -gt 0)
            }
        )
    }

    $totalRam = [int64]0
    foreach ($pi in $procInfo.Values) {
        $totalRam += $pi.RAMBytes
    }

    $ptHost = @(
        $all | Where-Object { $_.Name -eq "PowerToys.exe" }
    )

    $modsArray = $mods.ToArray()

    $status = [PSCustomObject]@{
        Version = $cfg.powertoys_version
        Startup = [bool]$cfg.startup
        Host = if ($ptHost.Count -gt 0) { "RUNNING" } else { "STOPPED" }
        Processes = $all.Count
        RAM_MB = [math]::Round($totalRam / 1MB, 1)
        EnabledModules = @($modsArray | Where-Object { $_.Enabled }).Count
        DisabledModules = @($modsArray | Where-Object { !$_.Enabled }).Count
        RunningModules = @($modsArray | Where-Object { $_.Runtime -eq "RUNNING" }).Count
    }

    [PSCustomObject]@{
        Timestamp = Get-Date
        Status = $status
        Modules = $modsArray
        Processes = $all
    }
}

# Public API wrappers for compatibility
function Get-PowerToysModules {
    (Get-PowerToysSnapshot).Modules
}

function Get-PowerToysModule($Name) {
    $mods = @((Get-PowerToysSnapshot).Modules)
    $r = @($mods | Where-Object { $_.Module -ieq $Name })
    if ($r.Count -eq 0) {
        throw "Unknown PowerToys module: $Name"
    }
    $r[0]
}

function Get-PowerToysStatus {
    (Get-PowerToysSnapshot).Status
}

function Get-PowerToysResources {
    $snap = Get-PowerToysSnapshot
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($x in $snap.Processes) {
        $ram = 0
        try {
            $gp = Get-Process -Id $x.ProcessId -ErrorAction Stop
            $ram = [math]::Round($gp.WorkingSet64 / 1MB, 1)
        } catch {}

        $rows.Add(
            [PSCustomObject]@{
                Name = $x.Name
                PID = $x.ProcessId
                ParentPID = $x.ParentProcessId
                RAM_MB = $ram
            }
        )
    }

    $rows.ToArray() | Sort-Object RAM_MB -Descending
}

# Read-only configuration & DSC discovery for detail screens
function Get-PowerToysModuleConfig($Name) {

    $meta = $null
    if ($script:PTModuleMetadata.Contains($Name)) {
        $meta = $script:PTModuleMetadata[$Name]
    }

    $dirName = if ($meta -and $meta.ConfigSubdir) { $meta.ConfigSubdir } else { $Name }
    $localConfigDir = Join-Path $script:PTConfigRoot $dirName
    $localConfigFile = Join-Path $localConfigDir "settings.json"

    $hasSettings = $false
    $props = [ordered]@{}

    if (Test-Path -LiteralPath $localConfigFile) {
        try {
            $json = Get-Content -LiteralPath $localConfigFile -Raw | ConvertFrom-Json
            $hasSettings = $true

            if ($json.properties) {
                foreach ($p in $json.properties.PSObject.Properties) {
                    $val = $p.Value
                    if ($val -and $val.value -ne $null) {
                        $props[$p.Name] = $val.value
                    } else {
                        $props[$p.Name] = $val
                    }
                }
            }
        } catch {}
    }

    # Check for DSC module
    $dscName = if ($meta -and $meta.DSCResource) {
        $meta.DSCResource
    } else {
        "microsoft.powertoys.${Name}.settings.dsc.resource.json"
    }

    $dscPath = Join-Path $script:PTDscRoot $dscName
    $dscAvailable = Test-Path -LiteralPath $dscPath

    [PSCustomObject]@{
        Name = $Name
        HasSettings = $hasSettings
        SettingsFile = if ($hasSettings) { $localConfigFile } else { $null }
        Properties = $props
        DSCAvailable = $dscAvailable
        DSCFile = if ($dscAvailable) { $dscPath } else { $null }
    }
}

# =================================================================
# Background Telemetry Worker (Zero-Hitch UI Decoupling)
# =================================================================

function Start-PTTelemetryWorker {
    param([int]$IntervalMs = 1500)

    if (Get-Command Start-WorkCtlTelemetryWorker -ErrorAction SilentlyContinue) {
        return (Start-WorkCtlTelemetryWorker -IntervalMs $IntervalMs)
    }

    try {
        $sync = [hashtable]::Synchronized(@{
            Running = $true
            Snapshot = $null
            Error = $null
            IntervalMs = $IntervalMs
            LastUpdated = [datetime]::MinValue
        })

        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable("sync", $sync)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs

        $scriptBlock = {
            if (Test-Path "E:\TOOLS\WorkstationControl\modules\resources.ps1") {
                . "E:\TOOLS\WorkstationControl\modules\resources.ps1"
            }
            while ($sync.Running) {
                try {
                    $s = Get-WorkCtlSnapshot
                    $sync.Snapshot = $s
                    $sync.LastUpdated = [datetime]::UtcNow
                    $sync.Error = $null
                } catch {
                    $sync.Error = $_.Exception.Message
                }

                $slept = 0
                while ($slept -lt $sync.IntervalMs -and $sync.Running) {
                    [System.Threading.Thread]::Sleep(50)
                    $slept += 50
                }
            }
        }

        $asyncResult = $ps.AddScript($scriptBlock).BeginInvoke()

        [PSCustomObject]@{
            Sync = $sync
            Runspace = $rs
            PowerShell = $ps
            AsyncResult = $asyncResult
        }
    } catch {
        $null
    }
}

function Stop-PTTelemetryWorker($Worker) {
    if (!$Worker) { return }

    if (Get-Command Stop-WorkCtlTelemetryWorker -ErrorAction SilentlyContinue) {
        Stop-WorkCtlTelemetryWorker $Worker
        return
    }

    try {
        if ($Worker.Sync) {
            $Worker.Sync.Running = $false
        }
    } catch {}

    Start-Sleep -Milliseconds 100

    try {
        if ($Worker.PowerShell) {
            $Worker.PowerShell.Dispose()
        }
    } catch {}

    try {
        if ($Worker.Runspace) {
            $Worker.Runspace.Close()
            $Worker.Runspace.Dispose()
        }
    } catch {}
}

# =================================================================
# Category Helpers & Dynamic Counts
# =================================================================

function Get-PTCategoryNames {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($k in $script:PTCategories.Keys) {
        $names.Add($k)
    }
    $names.Add("All Modules")
    $names.ToArray()
}

function Get-PTModuleCategory($ModuleName) {
    if ($script:PTModuleMetadata.Contains($ModuleName)) {
        return $script:PTModuleMetadata[$ModuleName].Category
    }
    return "Other"
}

function Get-PTCategorySummary($CategoryName, $Snapshot) {
    if (!$Snapshot -or !$Snapshot.Modules) {
        return [PSCustomObject]@{
            Category = $CategoryName
            Total = 0
            Enabled = 0
            Disabled = 0
            Running = 0
        }
    }

    $mods = @($Snapshot.Modules)

    $catMods = if ($CategoryName -eq "All Modules") {
        $mods
    } elseif ($script:PTCategories.Contains($CategoryName)) {
        $allowed = @($script:PTCategories[$CategoryName])
        @($mods | Where-Object { $_.Module -in $allowed })
    } else {
        # Other / Unknown future modules
        $known = @()
        foreach ($k in $script:PTCategories.Keys) {
            $known += $script:PTCategories[$k]
        }
        @($mods | Where-Object { $_.Module -notin $known })
    }

    $enabled = @($catMods | Where-Object { $_.Enabled }).Count
    $disabled = @($catMods | Where-Object { !$_.Enabled }).Count
    $running = @($catMods | Where-Object { $_.Runtime -eq "RUNNING" }).Count

    [PSCustomObject]@{
        Category = $CategoryName
        Total = $catMods.Count
        Enabled = $enabled
        Disabled = $disabled
        Running = $running
    }
}

function Get-PTCategoryModules($CategoryName, $State) {
    if (!$State.CachedPTSnapshot -or !$State.CachedPTSnapshot.Modules) {
        return @()
    }

    $mods = @($State.CachedPTSnapshot.Modules)

    $catMods = if ($CategoryName -eq "All Modules") {
        $mods
    } elseif ($script:PTCategories.Contains($CategoryName)) {
        $allowed = @($script:PTCategories[$CategoryName])
        @($mods | Where-Object { $_.Module -in $allowed })
    } else {
        $known = @()
        foreach ($k in $script:PTCategories.Keys) {
            $known += $script:PTCategories[$k]
        }
        @($mods | Where-Object { $_.Module -notin $known })
    }

    switch ($State.Filter) {
        "ENABLED"  { $catMods = @($catMods | Where-Object { $_.Enabled }) }
        "DISABLED" { $catMods = @($catMods | Where-Object { !$_.Enabled }) }
        "RUNNING"  { $catMods = @($catMods | Where-Object { $_.Runtime -eq "RUNNING" }) }
    }

    @($catMods | Sort-Object Module)
}

function Get-PTSearchMatches($Query, $Snapshot) {
    if (!$Snapshot -or !$Snapshot.Modules -or !$Query) {
        return @()
    }

    $mods = @($Snapshot.Modules)
    @($mods | Where-Object { $_.Module -like "*$Query*" } | Sort-Object Module)
}

# =================================================================
# Application State Model & Navigation
# =================================================================

function Initialize-PTAppState {

    [PSCustomObject]@{
        Screen = "powertoys-home"
        PreviousScreen = "powertoys-home"
        PreSearchScreen = "powertoys-home"
        SelectedCategory = 0
        CategoryScroll = 0
        CurrentCategory = "Window & Desktop"
        SelectedModuleIndex = 0
        ModuleScroll = 0
        SelectedModule = $null
        Filter = "ALL"
        Search = ""
        CachedPTSnapshot = $null
        CachedResSnapshot = $null
        LastPTRefresh = [datetime]::MinValue
        LastResRefresh = [datetime]::MinValue
        PTIntervalMs = 2000
        ResIntervalMs = 1500
        Dirty = $true
        Running = $true
    }
}

function Handle-PTKeyInput($State, $KeyInfo) {

    if (!$KeyInfo) {
        return
    }

    $categories = @(Get-PTCategoryNames)
    $viewHeight = [math]::Max(5, (Get-WorkCtlWindowHeight) - 15)

    switch ($KeyInfo.Key) {

        "UpArrow" {
            switch ($State.Screen) {
                "powertoys-home" {
                    if ($State.SelectedCategory -gt 0) {
                        $State.SelectedCategory--
                        $State.Dirty = $true
                    }
                }
                "powertoys-category" {
                    if ($State.SelectedModuleIndex -gt 0) {
                        $State.SelectedModuleIndex--
                        $State.Dirty = $true
                    }
                }
                "powertoys-search" {
                    if ($State.SelectedModuleIndex -gt 0) {
                        $State.SelectedModuleIndex--
                        $State.Dirty = $true
                    }
                }
            }
        }

        "DownArrow" {
            switch ($State.Screen) {
                "powertoys-home" {
                    if ($State.SelectedCategory -lt ($categories.Count - 1)) {
                        $State.SelectedCategory++
                        $State.Dirty = $true
                    }
                }
                "powertoys-category" {
                    $catMods = @(Get-PTCategoryModules $State.CurrentCategory $State)
                    if ($catMods.Count -gt 0 -and $State.SelectedModuleIndex -lt ($catMods.Count - 1)) {
                        $State.SelectedModuleIndex++
                        $State.Dirty = $true
                    }
                }
                "powertoys-search" {
                    $matches = @(Get-PTSearchMatches $State.Search $State.CachedPTSnapshot)
                    if ($matches.Count -gt 0 -and $State.SelectedModuleIndex -lt ($matches.Count - 1)) {
                        $State.SelectedModuleIndex++
                        $State.Dirty = $true
                    }
                }
            }
        }

        "PageUp" {
            switch ($State.Screen) {
                "powertoys-home" {
                    $State.SelectedCategory = [math]::Max(0, $State.SelectedCategory - $viewHeight)
                    $State.Dirty = $true
                }
                "powertoys-category" {
                    $State.SelectedModuleIndex = [math]::Max(0, $State.SelectedModuleIndex - $viewHeight)
                    $State.Dirty = $true
                }
                "powertoys-search" {
                    $State.SelectedModuleIndex = [math]::Max(0, $State.SelectedModuleIndex - $viewHeight)
                    $State.Dirty = $true
                }
            }
        }

        "PageDown" {
            switch ($State.Screen) {
                "powertoys-home" {
                    $State.SelectedCategory = [math]::Min($categories.Count - 1, $State.SelectedCategory + $viewHeight)
                    $State.Dirty = $true
                }
                "powertoys-category" {
                    $catMods = @(Get-PTCategoryModules $State.CurrentCategory $State)
                    if ($catMods.Count -gt 0) {
                        $State.SelectedModuleIndex = [math]::Min($catMods.Count - 1, $State.SelectedModuleIndex + $viewHeight)
                        $State.Dirty = $true
                    }
                }
                "powertoys-search" {
                    $matches = @(Get-PTSearchMatches $State.Search $State.CachedPTSnapshot)
                    if ($matches.Count -gt 0) {
                        $State.SelectedModuleIndex = [math]::Min($matches.Count - 1, $State.SelectedModuleIndex + $viewHeight)
                        $State.Dirty = $true
                    }
                }
            }
        }

        "Home" {
            switch ($State.Screen) {
                "powertoys-home"     { $State.SelectedCategory = 0; $State.Dirty = $true }
                "powertoys-category" { $State.SelectedModuleIndex = 0; $State.Dirty = $true }
                "powertoys-search"   { $State.SelectedModuleIndex = 0; $State.Dirty = $true }
            }
        }

        "End" {
            switch ($State.Screen) {
                "powertoys-home" {
                    $State.SelectedCategory = $categories.Count - 1
                    $State.Dirty = $true
                }
                "powertoys-category" {
                    $catMods = @(Get-PTCategoryModules $State.CurrentCategory $State)
                    if ($catMods.Count -gt 0) {
                        $State.SelectedModuleIndex = $catMods.Count - 1
                        $State.Dirty = $true
                    }
                }
                "powertoys-search" {
                    $matches = @(Get-PTSearchMatches $State.Search $State.CachedPTSnapshot)
                    if ($matches.Count -gt 0) {
                        $State.SelectedModuleIndex = $matches.Count - 1
                        $State.Dirty = $true
                    }
                }
            }
        }

        "Enter" {
            switch ($State.Screen) {
                "powertoys-home" {
                    if ($State.SelectedCategory -ge 0 -and $State.SelectedCategory -lt $categories.Count) {
                        $State.CurrentCategory = $categories[$State.SelectedCategory]
                        $State.SelectedModuleIndex = 0
                        $State.ModuleScroll = 0
                        $State.Filter = "ALL"
                        $State.PreviousScreen = "powertoys-home"
                        $State.Screen = "powertoys-category"
                        $State.Dirty = $true
                    }
                }
                "powertoys-category" {
                    $catMods = @(Get-PTCategoryModules $State.CurrentCategory $State)
                    if ($catMods.Count -gt 0 -and $State.SelectedModuleIndex -ge 0 -and $State.SelectedModuleIndex -lt $catMods.Count) {
                        $State.SelectedModule = $catMods[$State.SelectedModuleIndex]
                        $State.PreviousScreen = "powertoys-category"
                        $State.Screen = "powertoys-detail"
                        $State.Dirty = $true
                    }
                }
                "powertoys-search" {
                    $matches = @(Get-PTSearchMatches $State.Search $State.CachedPTSnapshot)
                    if ($matches.Count -gt 0 -and $State.SelectedModuleIndex -ge 0 -and $State.SelectedModuleIndex -lt $matches.Count) {
                        $State.SelectedModule = $matches[$State.SelectedModuleIndex]
                        $State.PreviousScreen = "powertoys-search"
                        $State.Screen = "powertoys-detail"
                        $State.Dirty = $true
                    }
                }
            }
        }

        "Escape" {
            switch ($State.Screen) {
                "powertoys-detail" {
                    $State.Screen = if ($State.PreviousScreen) { $State.PreviousScreen } else { "powertoys-category" }
                    $State.Dirty = $true
                }
                "powertoys-category" {
                    $State.Screen = "powertoys-home"
                    $State.Dirty = $true
                }
                "powertoys-search" {
                    $State.Search = ""
                    $State.Screen = if ($State.PreSearchScreen) { $State.PreSearchScreen } else { "powertoys-home" }
                    $State.Dirty = $true
                }
                "powertoys-help" {
                    $State.Screen = if ($State.PreviousScreen) { $State.PreviousScreen } else { "powertoys-home" }
                    $State.Dirty = $true
                }
                "powertoys-home" {
                    $State.Running = $false
                }
            }
        }

        "B" {
            switch ($State.Screen) {
                "powertoys-detail" {
                    $State.Screen = if ($State.PreviousScreen) { $State.PreviousScreen } else { "powertoys-category" }
                    $State.Dirty = $true
                }
                "powertoys-category" {
                    $State.Screen = "powertoys-home"
                    $State.Dirty = $true
                }
                "powertoys-search" {
                    $State.Search = ""
                    $State.Screen = if ($State.PreSearchScreen) { $State.PreSearchScreen } else { "powertoys-home" }
                    $State.Dirty = $true
                }
                "powertoys-home" {
                    $State.Running = $false
                }
            }
        }

        "Q" {
            $State.Running = $false
            $State.ExitRequested = $true
        }

        "F" {
            if ($State.Screen -eq "powertoys-category") {
                switch ($State.Filter) {
                    "ALL"      { $State.Filter = "ENABLED" }
                    "ENABLED"  { $State.Filter = "DISABLED" }
                    "DISABLED" { $State.Filter = "RUNNING" }
                    default    { $State.Filter = "ALL" }
                }
                $State.SelectedModuleIndex = 0
                $State.ModuleScroll = 0
                $State.Dirty = $true
            }
        }

        "Oem2" { # Forward slash "/" or question mark "?" with shift
            if ($KeyInfo.KeyChar -eq "?") {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "powertoys-help"
                $State.Dirty = $true
            } else {
                $res = Read-WorkCtlSearchInput -CurrentQuery $State.Search
                if (!$res.Cancelled) {
                    $State.Search = $res.Query
                    $State.SelectedModuleIndex = 0
                    $State.ModuleScroll = 0
                    $State.PreSearchScreen = $State.Screen
                    $State.PreviousScreen = $State.Screen
                    if ($res.Query) {
                        $State.Screen = "powertoys-search"
                    } else {
                        $State.Screen = "powertoys-home"
                    }
                }
                $State.Dirty = $true
            }
        }

        "I" {
            if ($State.Screen -eq "powertoys-category") {
                $catMods = @(Get-PTCategoryModules $State.CurrentCategory $State)
                if ($catMods.Count -gt 0 -and $State.SelectedModuleIndex -ge 0 -and $State.SelectedModuleIndex -lt $catMods.Count) {
                    $State.SelectedModule = $catMods[$State.SelectedModuleIndex]
                    $State.PreviousScreen = "powertoys-category"
                    $State.Screen = "powertoys-detail"
                    $State.Dirty = $true
                }
            } elseif ($State.Screen -eq "powertoys-search") {
                $matches = @(Get-PTSearchMatches $State.Search $State.CachedPTSnapshot)
                if ($matches.Count -gt 0 -and $State.SelectedModuleIndex -ge 0 -and $State.SelectedModuleIndex -lt $matches.Count) {
                    $State.SelectedModule = $matches[$State.SelectedModuleIndex]
                    $State.PreviousScreen = "powertoys-search"
                    $State.Screen = "powertoys-detail"
                    $State.Dirty = $true
                }
            }
        }

        "R" {
            try {
                $State.CachedPTSnapshot = Get-PowerToysSnapshot
                $State.LastPTRefresh = [datetime]::UtcNow
            } catch {}

            if (Get-Command Get-WorkCtlSnapshot -ErrorAction SilentlyContinue) {
                try {
                    $State.CachedResSnapshot = Get-WorkCtlSnapshot
                    $State.LastResRefresh = [datetime]::UtcNow
                } catch {}
            }
            $State.Dirty = $true
        }

        default {
            if ($KeyInfo.KeyChar -eq "?") {
                $State.PreviousScreen = $State.Screen
                $State.Screen = "powertoys-help"
                $State.Dirty = $true
            }
        }
    }
}

# =================================================================
# Screen Frame Builders (Hierarchical & Responsive Layout)
# =================================================================

function New-PTTelemetryLine($ResSnapshot) {

    $width = Get-WorkCtlWindowWidth
    $margin = Get-WorkCtlMargin

    if ($ResSnapshot) {
        if ($width -ge 90) {
            New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment "CPU  " DarkGray),
                (New-UiSegment ("{0,5:N1}%" -f $ResSnapshot.CPU.UsagePercent) Green),
                (New-UiSegment "     RAM  " DarkGray),
                (New-UiSegment ("{0:N2} / {1:N2} GB" -f $ResSnapshot.Memory.UsedGB, $ResSnapshot.Memory.TotalGB) Green),
                (New-UiSegment "     GPU  " DarkGray),
                (New-UiSegment ("{0:N0}%  {1:N0}C" -f $ResSnapshot.GPU.UsagePercent, $ResSnapshot.GPU.TemperatureC) Green)
            )
        } else {
            New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment "CPU " DarkGray),
                (New-UiSegment ("{0:N0}%" -f $ResSnapshot.CPU.UsagePercent) Green),
                (New-UiSegment "  RAM " DarkGray),
                (New-UiSegment ("{0:N1}/{1:N1}G" -f $ResSnapshot.Memory.UsedGB, $ResSnapshot.Memory.TotalGB) Green),
                (New-UiSegment "  GPU " DarkGray),
                (New-UiSegment ("{0:N0}% {1:N0}C" -f $ResSnapshot.GPU.UsagePercent, $ResSnapshot.GPU.TemperatureC) Green)
            )
        }
    } else {
        New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "Telemetry initializing..." Yellow)
        )
    }
}

function New-PTHomeFrame($State) {

    $f = New-Object System.Collections.Generic.List[object]
    $width = [math]::Max(20, (Get-WorkCtlWindowWidth) - 1)
    $margin = Get-WorkCtlMargin

    # 1. Header
    $f.Add((New-WorkCtlHeaderLine @("POWERTOYS")))
    $f.Add((New-WorkCtlSeparatorLine))

    # 2. Telemetry
    $f.Add((New-PTTelemetryLine $State.CachedResSnapshot))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 3. Host & Status Overview
    $snap = $State.CachedPTSnapshot
    if ($snap -and $snap.Status) {
        $st = $snap.Status
        $hostColor = if ($st.Host -eq "RUNNING") { "Green" } else { "Yellow" }

        $f.Add(
            (New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment "HOST  " DarkGray),
                (New-UiSegment ("{0,-9}" -f $st.Host) $hostColor),
                (New-UiSegment "   MODULES  " DarkGray),
                (New-UiSegment ("{0} ON / {1} OFF" -f $st.EnabledModules, $st.DisabledModules) Green),
                (New-UiSegment "   VERSION  " DarkGray),
                (New-UiSegment $st.Version Cyan)
            ))
        )
    } else {
        $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "PowerToys status initializing..." Yellow))))
    }

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 4. Section Title
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "CATEGORIES" Magenta)
        ))
    )
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment ("-" * [math]::Min(66, $width - 8)) DarkGray)
        ))
    )

    # 5. Category Rows
    $categories = @(Get-PTCategoryNames)
    $viewHeight = [math]::Max(5, (Get-WorkCtlWindowHeight) - 16)

    # Clamp category selection
    if ($State.SelectedCategory -ge $categories.Count) {
        $State.SelectedCategory = $categories.Count - 1
    }
    if ($State.SelectedCategory -lt 0) {
        $State.SelectedCategory = 0
    }

    $vp = Get-WorkCtlViewport -Total $categories.Count -Selected $State.SelectedCategory -Height $viewHeight -CurrentOffset $State.CategoryScroll
    $State.CategoryScroll = $vp.Offset

    for ($i = $vp.Offset; $i -le $vp.End; $i++) {
        $catName = $categories[$i]
        $sel = ($i -eq $State.SelectedCategory)

        $sum = Get-PTCategorySummary $catName $snap

        $bg = if ($sel) { "DarkCyan" } else { "Black" }
        $marker = if ($sel) { ">" } else { " " }

        $catLabel = if ($catName -eq "All Modules") { "All Modules" } else { $catName }
        $catColor = if ($catName -eq "All Modules") { "Cyan" } else { "White" }

        $f.Add(
            (New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment (" {0} " -f $marker) White $bg),
                (New-UiSegment ("{0,-24}" -f $catLabel) $catColor $bg),
                (New-UiSegment ("{0,3} enabled    " -f $sum.Enabled) Green $bg),
                (New-UiSegment ("{0,3} disabled    " -f $sum.Disabled) DarkGray $bg),
                (New-UiSegment ("{0,3} running" -f $sum.Running) Cyan $bg),
                (New-UiSegment " " White $bg)
            ))
        )
    }

    # Pad remaining lines
    $renderedCount = $vp.End - $vp.Offset + 1
    for ($i = $renderedCount; $i -lt $viewHeight; $i++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    # 6. Separator & Footer
    $f.Add((New-WorkCtlSeparatorLine))

    $posText = "{0}/{1}" -f ($State.SelectedCategory + 1), $categories.Count
    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "UP/DOWN"; Label = "Move" },
                @{ Key = "ENTER";   Label = "Open" },
                @{ Key = "/";       Label = "Search" },
                @{ Key = "?";       Label = "Help" },
                @{ Key = "Q";       Label = "Exit" }
            ) `
            -RightText $posText
        )
    )

    $f.ToArray()
}

function New-PTCategoryModuleFrame($State) {

    $f = New-Object System.Collections.Generic.List[object]
    $width = [math]::Max(20, (Get-WorkCtlWindowWidth) - 1)
    $margin = Get-WorkCtlMargin
    $catName = $State.CurrentCategory

    # 1. Header with breadcrumbs
    $f.Add((New-WorkCtlHeaderLine @("POWERTOYS", $catName)))
    $f.Add((New-WorkCtlSeparatorLine))

    # 2. Telemetry
    $f.Add((New-PTTelemetryLine $State.CachedResSnapshot))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 3. Category Summary
    $sum = Get-PTCategorySummary $catName $State.CachedPTSnapshot
    $filterLabel = if ($State.Filter -ne "ALL") { " [FILTER: " + $State.Filter + "]" } else { "" }

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "CATEGORY  " DarkGray),
            (New-UiSegment ("{0} modules    " -f $sum.Total) White),
            (New-UiSegment ("{0} enabled    " -f $sum.Enabled) Green),
            (New-UiSegment ("{0} disabled    " -f $sum.Disabled) DarkGray),
            (New-UiSegment ("{0} running" -f $sum.Running) Cyan),
            (New-UiSegment $filterLabel Yellow)
        ))
    )

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 4. Table Header (Responsive)
    $isWide = ($width -ge 100)
    $isCompact = ($width -lt 75)

    if ($isCompact) {
        $f.Add(
            (New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment " MODULE                 CONFIG     RUNTIME     RAM" DarkGray)
            ))
        )
    } else {
        $f.Add(
            (New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment " MODULE                         CONFIG       RUNTIME       PROC        RAM" DarkGray)
            ))
        )
    }

    $ruleWidth = [math]::Min($width - 8, 76)
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment ("-" * $ruleWidth) DarkGray)
        ))
    )

    # 5. Viewport Rows
    $catMods = @(Get-PTCategoryModules $catName $State)
    $viewHeight = [math]::Max(5, (Get-WorkCtlWindowHeight) - 15)

    if ($catMods.Count -eq 0) {
        $State.SelectedModuleIndex = 0
        $State.ModuleScroll = 0
        $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "   No modules matching current filter in this category." Yellow))))
        for ($i = 1; $i -lt $viewHeight; $i++) {
            $f.Add((New-UiLine @((New-UiSegment ""))))
        }
    } else {
        if ($State.SelectedModuleIndex -ge $catMods.Count) {
            $State.SelectedModuleIndex = $catMods.Count - 1
        }
        if ($State.SelectedModuleIndex -lt 0) {
            $State.SelectedModuleIndex = 0
        }

        $vp = Get-WorkCtlViewport -Total $catMods.Count -Selected $State.SelectedModuleIndex -Height $viewHeight -CurrentOffset $State.ModuleScroll
        $State.ModuleScroll = $vp.Offset

        for ($i = $vp.Offset; $i -le $vp.End; $i++) {
            $m = $catMods[$i]
            $sel = ($i -eq $State.SelectedModuleIndex)

            $bg = if ($sel) { "DarkCyan" } else { "Black" }
            $marker = if ($sel) { ">" } else { " " }

            $cfgColor = if ($m.Enabled) { "Green" } else { "DarkGray" }
            $cfgText = if ($m.Enabled) { "ENABLED" } else { "DISABLED" }

            $runColor = switch ($m.Runtime) {
                "RUNNING" { "Green" }
                "IDLE"    { "Yellow" }
                "OFF"     { "DarkGray" }
                default   { "Gray" }
            }

            $ram = if ($m.RAM_MB -gt 0) {
                "{0,8:N1} MB" -f $m.RAM_MB
            } else {
                "         -"
            }

            $procText = if ($m.Processes -gt 0) { "{0,4}" -f $m.Processes } else { "   -" }

            if ($isCompact) {
                $f.Add(
                    (New-UiLine @(
                        (New-UiSegment $margin DarkGray),
                        (New-UiSegment (" {0} " -f $marker) White $bg),
                        (New-UiSegment ("{0,-20}" -f $m.Module) White $bg),
                        (New-UiSegment ("{0,-10}" -f $cfgText) $cfgColor $bg),
                        (New-UiSegment ("{0,-11}" -f $m.Runtime) $runColor $bg),
                        (New-UiSegment $ram White $bg)
                    ))
                )
            } else {
                $f.Add(
                    (New-UiLine @(
                        (New-UiSegment $margin DarkGray),
                        (New-UiSegment (" {0} " -f $marker) White $bg),
                        (New-UiSegment ("{0,-29}" -f $m.Module) White $bg),
                        (New-UiSegment ("{0,-12}" -f $cfgText) $cfgColor $bg),
                        (New-UiSegment ("{0,-13}" -f $m.Runtime) $runColor $bg),
                        (New-UiSegment ("{0,4} " -f $procText) White $bg),
                        (New-UiSegment $ram White $bg),
                        (New-UiSegment " " White $bg)
                    ))
                )
            }
        }

        # Blank pad
        $renderedCount = $vp.End - $vp.Offset + 1
        for ($i = $renderedCount; $i -lt $viewHeight; $i++) {
            $f.Add((New-UiLine @((New-UiSegment ""))))
        }
    }

    # 6. Separator & Footer
    $f.Add((New-WorkCtlSeparatorLine))

    $posText = if ($catMods.Count -gt 0) { "{0}/{1}" -f ($State.SelectedModuleIndex + 1), $catMods.Count } else { "0/0" }

    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "UP/DOWN"; Label = "Move" },
                @{ Key = "ENTER";   Label = "Details" },
                @{ Key = "F";       Label = "Filter" },
                @{ Key = "/";       Label = "Search" },
                @{ Key = "B/ESC";   Label = "Back" },
                @{ Key = "Q";       Label = "Exit" }
            ) `
            -RightText $posText
        )
    )

    $f.ToArray()
}

function New-PTSearchFrame($State) {

    $f = New-Object System.Collections.Generic.List[object]
    $width = [math]::Max(20, (Get-WorkCtlWindowWidth) - 1)
    $margin = Get-WorkCtlMargin
    $query = $State.Search

    # 1. Header
    $f.Add((New-WorkCtlHeaderLine @("POWERTOYS", "SEARCH")))
    $f.Add((New-WorkCtlSeparatorLine))

    # 2. Telemetry
    $f.Add((New-PTTelemetryLine $State.CachedResSnapshot))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 3. Query overview
    $matches = @(Get-PTSearchMatches $query $State.CachedPTSnapshot)

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "QUERY: " DarkGray),
            (New-UiSegment ("[{0}]" -f $query) Yellow),
            (New-UiSegment ("     MATCHES: {0} found" -f $matches.Count) Cyan)
        ))
    )

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 4. Table Header with Category Column
    $isWide = ($width -ge 100)

    if ($isWide) {
        $f.Add(
            (New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment " MODULE                     CATEGORY              CONFIG       RUNTIME       RAM" DarkGray)
            ))
        )
    } else {
        $f.Add(
            (New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment " MODULE                 CATEGORY              CONFIG     RUNTIME" DarkGray)
            ))
        )
    }

    $ruleWidth = [math]::Min($width - 8, 86)
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment ("-" * $ruleWidth) DarkGray)
        ))
    )

    # 5. Viewport Rows
    $viewHeight = [math]::Max(5, (Get-WorkCtlWindowHeight) - 15)

    if ($matches.Count -eq 0) {
        $State.SelectedModuleIndex = 0
        $State.ModuleScroll = 0
        $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "   No modules matching search query." Yellow))))
        for ($i = 1; $i -lt $viewHeight; $i++) {
            $f.Add((New-UiLine @((New-UiSegment ""))))
        }
    } else {
        if ($State.SelectedModuleIndex -ge $matches.Count) {
            $State.SelectedModuleIndex = $matches.Count - 1
        }
        if ($State.SelectedModuleIndex -lt 0) {
            $State.SelectedModuleIndex = 0
        }

        $vp = Get-WorkCtlViewport -Total $matches.Count -Selected $State.SelectedModuleIndex -Height $viewHeight -CurrentOffset $State.ModuleScroll
        $State.ModuleScroll = $vp.Offset

        for ($i = $vp.Offset; $i -le $vp.End; $i++) {
            $m = $matches[$i]
            $sel = ($i -eq $State.SelectedModuleIndex)
            $cat = Get-PTModuleCategory $m.Module

            $bg = if ($sel) { "DarkCyan" } else { "Black" }
            $marker = if ($sel) { ">" } else { " " }

            $cfgColor = if ($m.Enabled) { "Green" } else { "DarkGray" }
            $cfgText = if ($m.Enabled) { "ENABLED" } else { "DISABLED" }

            $runColor = switch ($m.Runtime) {
                "RUNNING" { "Green" }
                "IDLE"    { "Yellow" }
                "OFF"     { "DarkGray" }
                default   { "Gray" }
            }

            $ram = if ($m.RAM_MB -gt 0) {
                "{0,8:N1} MB" -f $m.RAM_MB
            } else {
                "         -"
            }

            if ($isWide) {
                $f.Add(
                    (New-UiLine @(
                        (New-UiSegment $margin DarkGray),
                        (New-UiSegment (" {0} " -f $marker) White $bg),
                        (New-UiSegment ("{0,-25}" -f $m.Module) White $bg),
                        (New-UiSegment ("{0,-21}" -f $cat) Cyan $bg),
                        (New-UiSegment ("{0,-12}" -f $cfgText) $cfgColor $bg),
                        (New-UiSegment ("{0,-13}" -f $m.Runtime) $runColor $bg),
                        (New-UiSegment $ram White $bg),
                        (New-UiSegment " " White $bg)
                    ))
                )
            } else {
                $f.Add(
                    (New-UiLine @(
                        (New-UiSegment $margin DarkGray),
                        (New-UiSegment (" {0} " -f $marker) White $bg),
                        (New-UiSegment ("{0,-21}" -f $m.Module) White $bg),
                        (New-UiSegment ("{0,-21}" -f $cat) Cyan $bg),
                        (New-UiSegment ("{0,-10}" -f $cfgText) $cfgColor $bg),
                        (New-UiSegment $m.Runtime $runColor $bg)
                    ))
                )
            }
        }

        # Blank pad
        $renderedCount = $vp.End - $vp.Offset + 1
        for ($i = $renderedCount; $i -lt $viewHeight; $i++) {
            $f.Add((New-UiLine @((New-UiSegment ""))))
        }
    }

    # 6. Separator & Footer
    $f.Add((New-WorkCtlSeparatorLine))

    $posText = if ($matches.Count -gt 0) { "{0}/{1}" -f ($State.SelectedModuleIndex + 1), $matches.Count } else { "0/0" }

    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "UP/DOWN"; Label = "Move" },
                @{ Key = "ENTER";   Label = "Details" },
                @{ Key = "/";       Label = "New Search" },
                @{ Key = "ESC";     Label = "Clear/Back" },
                @{ Key = "Q";       Label = "Exit" }
            ) `
            -RightText $posText
        )
    )

    $f.ToArray()
}

function New-PTDetailFrame($State) {

    $f = New-Object System.Collections.Generic.List[object]
    $m = $State.SelectedModule
    $name = if ($m) { $m.Module } else { "UNKNOWN" }
    $margin = Get-WorkCtlMargin

    $meta = $null
    if ($script:PTModuleMetadata.Contains($name)) {
        $meta = $script:PTModuleMetadata[$name]
    }

    $categoryText = if ($meta) { $meta.Category } else { (Get-PTModuleCategory $name) }
    $cfgDiscovery = Get-PowerToysModuleConfig $name

    # 1. Header with 3-tier breadcrumb
    $f.Add((New-WorkCtlHeaderLine @("POWERTOYS", $categoryText, $name)))
    $f.Add((New-WorkCtlSeparatorLine))

    # 2. Telemetry bar
    $f.Add((New-PTTelemetryLine $State.CachedResSnapshot))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 3. Status card
    $cfgColor = if ($m -and $m.Enabled) { "Green" } else { "DarkGray" }
    $cfgText = if ($m -and $m.Enabled) { "ENABLED" } else { "DISABLED" }

    $runColor = switch ($m.Runtime) {
        "RUNNING" { "Green" }
        "IDLE"    { "Yellow" }
        "OFF"     { "DarkGray" }
        default   { "Gray" }
    }

    $ramText = if ($m -and $m.RAM_MB -gt 0) { "{0:N1} MB" -f $m.RAM_MB } else { "-" }
    $residencyText = if ($meta) { $meta.Residency } else { "On-Demand" }

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "STATUS" Magenta)
        ))
    )

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Config:       " DarkGray),
            (New-UiSegment ("{0,-12}" -f $cfgText) $cfgColor),
            (New-UiSegment " Category:    " DarkGray),
            (New-UiSegment $categoryText White)
        ))
    )

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Runtime:      " DarkGray),
            (New-UiSegment ("{0,-12}" -f $m.Runtime) $runColor),
            (New-UiSegment " Residency:   " DarkGray),
            (New-UiSegment $residencyText Yellow)
        ))
    )

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Processes:    " DarkGray),
            (New-UiSegment ("{0,-12}" -f $m.Processes) White),
            (New-UiSegment " RAM Usage:   " DarkGray),
            (New-UiSegment $ramText White)
        ))
    )

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 4. Educational guide
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "WHAT IS THIS?" Magenta)
        ))
    )

    $descText = if ($meta) { $meta.Description } else { "Utility information unavailable for this module." }
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment ("  {0}" -f $descText) White)
        ))
    )

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 5. Activation & Shortcut
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "ACTIVATION & SHORTCUT" Magenta)
        ))
    )

    $shortcutText = if ($meta) { $meta.Shortcut } else { "Consult PowerToys settings" }
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Trigger:      " DarkGray),
            (New-UiSegment $shortcutText Cyan)
        ))
    )

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 6. Configuration & DSC discovery
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "DISCOVERED CONFIGURATION" Magenta)
        ))
    )

    if ($cfgDiscovery.HasSettings) {
        $f.Add(
            (New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment "  Local Config: " DarkGray),
                (New-UiSegment "Discovered (settings.json)" Green)
            ))
        )

        $shownProps = 0
        foreach ($k in $cfgDiscovery.Properties.Keys) {
            if ($shownProps -ge 3) { break }
            $valStr = [string]$cfgDiscovery.Properties[$k]
            if ($valStr.Length -gt 45) { $valStr = $valStr.Substring(0, 42) + "..." }
            $f.Add(
                (New-UiLine @(
                    (New-UiSegment $margin DarkGray),
                    (New-UiSegment ("    {0,-28} : " -f $k) DarkGray),
                    (New-UiSegment $valStr White)
                ))
            )
            $shownProps++
        }
    } else {
        $f.Add(
            (New-UiLine @(
                (New-UiSegment $margin DarkGray),
                (New-UiSegment "  Local Config: None (configured via global settings.json)" DarkGray)
            ))
        )
    }

    $dscStatusText = if ($cfgDiscovery.DSCAvailable) { "Available (JSON v3 resource detected)" } else { "Not mapped" }
    $dscColor = if ($cfgDiscovery.DSCAvailable) { "Green" } else { "DarkGray" }

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  DSC Resource: " DarkGray),
            (New-UiSegment $dscStatusText $dscColor)
        ))
    )

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 7. Safety & Governance Notice
    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "GOVERNANCE & SAFETY INVARIANT" Magenta)
        ))
    )

    $impactText = if ($meta) { $meta.DisableImpact } else { "Consult utility documentation." }

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Control Mode: " DarkGray),
            (New-UiSegment "LOCKED / READ-ONLY" Yellow),
            (New-UiSegment " (Mutations blocked in this version)" DarkGray)
        ))
    )

    $f.Add(
        (New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment "  Impact Note:  " DarkGray),
            (New-UiSegment $impactText DarkGray)
        ))
    )

    # Pad remaining lines
    $curLines = $f.Count
    $targetHeight = [math]::Max(20, (Get-WorkCtlWindowHeight) - 2)
    for ($i = $curLines; $i -lt ($targetHeight - 2); $i++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    # Separator & Footer
    $f.Add((New-WorkCtlSeparatorLine))
    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "ESC / B"; Label = "Back" },
                @{ Key = "?";       Label = "Help" },
                @{ Key = "R";       Label = "Refresh" },
                @{ Key = "Q";       Label = "Exit" }
            )
        )
    )

    $f.ToArray()
}

function New-PTHelpFrame($State) {

    $f = New-Object System.Collections.Generic.List[object]
    $margin = Get-WorkCtlMargin

    # 1. Header
    $f.Add((New-WorkCtlHeaderLine @("POWERTOYS", "HELP & GUIDE")))
    $f.Add((New-WorkCtlSeparatorLine))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 2. Navigation
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "NAVIGATION & KEYBINDS" Magenta))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Up / Down        " Cyan), (New-UiSegment "Move selection up / down" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  PgUp / PgDn      " Cyan), (New-UiSegment "Jump selection by full page viewport" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Home / End       " Cyan), (New-UiSegment "Jump directly to the first or last item" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Enter            " Cyan), (New-UiSegment "Open selected category or module details" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  / (Slash)        " Cyan), (New-UiSegment "Global search across all 34 PowerToys modules" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  F                " Cyan), (New-UiSegment "Cycle filters: ALL -> ENABLED -> DISABLED -> RUNNING" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  I                " Cyan), (New-UiSegment "Open details / information directly for highlighted module" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  R                " Cyan), (New-UiSegment "Force immediate telemetry and PowerToys cache refresh" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Escape / B       " Cyan), (New-UiSegment "Navigate up one level in the hierarchy, or exit from home" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  Q                " Cyan), (New-UiSegment "Exit PowerToys subsystem immediately" White))))

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 3. Hierarchy Model
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "HIERARCHY MODEL" Magenta))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  WORKCTL > POWERTOYS                       " Cyan), (New-UiSegment "Category overview with dynamic counts" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  WORKCTL > POWERTOYS > <CATEGORY>          " Cyan), (New-UiSegment "Filtered utility browser within category" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  WORKCTL > POWERTOYS > <CAT> > <MODULE>    " Cyan), (New-UiSegment "Contextual utility details, shortcuts & DSC" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  WORKCTL > POWERTOYS > SEARCH              " Cyan), (New-UiSegment "Global cross-category matching results" White))))

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 4. State Model
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "RUNTIME STATE MODEL" Magenta))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  ENABLED          " Green), (New-UiSegment "Configured on in PowerToys global settings" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  IDLE             " Yellow), (New-UiSegment "Enabled on-demand utility (no resident background process needed)" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  RUNNING          " Green), (New-UiSegment "Resident background process actively running in memory" White))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  DISABLED         " DarkGray), (New-UiSegment "Configured off in PowerToys global settings" White))))

    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 5. Safety Invariants
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "SAFETY INVARIANTS" Magenta))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  - PowerToys control is strictly READ-ONLY in this version." DarkGray))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  - No PowerToys settings are edited or overwritten." DarkGray))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  - No processes are killed or restarted." DarkGray))))
    $f.Add((New-UiLine @((New-UiSegment $margin DarkGray), (New-UiSegment "  - Host state != Module state distinction is preserved." DarkGray))))

    # Pad remaining lines
    $curLines = $f.Count
    $targetHeight = [math]::Max(20, (Get-WorkCtlWindowHeight) - 2)
    for ($i = $curLines; $i -lt ($targetHeight - 2); $i++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    $f.Add((New-WorkCtlSeparatorLine))
    $f.Add(
        (New-WorkCtlFooterLine `
            -Items @(
                @{ Key = "ESC / Any Key"; Label = "Return to Previous Screen" }
            )
        )
    )

    $f.ToArray()
}

# =================================================================
# Main Canonical TUI Entry Point (INPUT-FIRST DECOUPLED LOOP)
# =================================================================

function Get-PowerToysRegistry {
    return $script:PTModuleMetadata
}

function Watch-PowerToys {

    param(
        [double]$Interval = 2.0,
        [switch]$Embedded,
        [string]$InitialCategory = "",
        [string]$InitialModule = "",
        [switch]$TestMode,
        [object[]]$SyntheticKeys = @()
    )

    # Initialize resource engine if available
    if (Get-Command Initialize-WorkCtlResources -ErrorAction SilentlyContinue) {
        Initialize-WorkCtlResources
    }

    $state = Initialize-PTAppState
    $state.PTIntervalMs = [int]($Interval * 1000)
    if ($state.PTIntervalMs -lt 1000) { $state.PTIntervalMs = 1000 }

    if ($InitialCategory) {
        $state.CurrentCategory = $InitialCategory
        $state.PreviousScreen = "powertoys-home"
        $state.Screen = "powertoys-category"
    }

    if ($InitialModule) {
        $state.SelectedModule = $InitialModule
        $state.PreviousScreen = if ($InitialCategory) { "powertoys-category" } else { "powertoys-home" }
        $state.Screen = "powertoys-detail"
    }

    # Start non-blocking background telemetry worker for silky smooth 0-hitch updates
    $telemetryWorker = Start-PTTelemetryWorker -IntervalMs $state.ResIntervalMs

    if (!$Embedded) {
        Start-WorkCtlUI
    } else {
        $script:UiPreviousFrame = @()
    }

    $keyQueue = New-Object System.Collections.Generic.Queue[object]
    if ($SyntheticKeys -and $SyntheticKeys.Count -gt 0) {
        foreach ($k in $SyntheticKeys) {
            $keyQueue.Enqueue($k)
        }
    }

    try {
        # Initial data seeding
        try {
            $state.CachedPTSnapshot = Get-PowerToysSnapshot
            $state.LastPTRefresh = [datetime]::UtcNow
        } catch {
            $state.CachedPTSnapshot = $null
        }

        # Main Input-First Loop (~20ms polling)
        while ($state.Running) {

            # 1. Check background telemetry worker for completed updates (instant 0.06ms check)
            if ($telemetryWorker -and $telemetryWorker.Sync -and $telemetryWorker.Sync.Snapshot) {
                if ($telemetryWorker.Sync.LastUpdated -gt $state.LastResRefresh) {
                    $state.CachedResSnapshot = $telemetryWorker.Sync.Snapshot
                    $state.LastResRefresh = $telemetryWorker.Sync.LastUpdated
                    $state.Dirty = $true
                }
            }

            # 2. Render immediately if dirty
            if ($state.Dirty) {
                $frame = switch ($state.Screen) {
                    "powertoys-category" { New-PTCategoryModuleFrame $state }
                    "powertoys-search"   { New-PTSearchFrame $state }
                    "powertoys-detail"   { New-PTDetailFrame $state }
                    "powertoys-help"     { New-PTHelpFrame $state }
                    default              { New-PTHomeFrame $state }
                }

                Write-WorkCtlDiffFrame -Frame $frame
                $state.Dirty = $false
            }

            if ($TestMode -and $keyQueue.Count -eq 0) {
                break
            }

            # 3. Check input immediately (non-blocking 20ms cadence)
            $key = $null
            if ($keyQueue.Count -gt 0) {
                $key = $keyQueue.Dequeue()
            } else {
                $key = Read-WorkCtlKey -TimeoutMs 20
            }

            if ($key -ne $null) {
                Handle-PTKeyInput $state $key
                # Input handled! Immediately continue to render loop without delay
                continue
            }

            # 4. If no key was pressed, check scheduled refresh timers
            $now = [datetime]::UtcNow

            # Fallback synchronous telemetry check only if background worker is unavailable
            if (!$telemetryWorker -or !$telemetryWorker.Sync) {
                if (($now - $state.LastResRefresh).TotalMilliseconds -ge $state.ResIntervalMs) {
                    $state.LastResRefresh = $now
                    if (Get-Command Get-WorkCtlSnapshot -ErrorAction SilentlyContinue) {
                        try {
                            $state.CachedResSnapshot = Get-WorkCtlSnapshot
                            $state.Dirty = $true
                        } catch {}
                    }
                }
            }

            # PowerToys snapshot refresh timer
            if (($now - $state.LastPTRefresh).TotalMilliseconds -ge $state.PTIntervalMs) {
                $state.LastPTRefresh = $now
                try {
                    $state.CachedPTSnapshot = Get-PowerToysSnapshot
                    $state.Dirty = $true
                } catch {}
            }
        }

        return $state

    } finally {
        Stop-PTTelemetryWorker $telemetryWorker
        if (!$Embedded) {
            Stop-WorkCtlUI
        }
    }
}

# Compatibility alias for callers of Watch-PowerToysV2
function Watch-PowerToysV2 {
    param([double]$Interval = 2.0)
    Watch-PowerToys -Interval $Interval
}

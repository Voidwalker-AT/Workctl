# =================================================================
# WorkCtl v1.5 - Interactive Workstation Guide Subsystem Engine
# =================================================================

$script:GuideRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) } else { "E:\TOOLS\WorkstationControl" }
if (!$script:GuideRoot -or !(Test-Path -LiteralPath $script:GuideRoot)) {
    $script:GuideRoot = "E:\TOOLS\WorkstationControl"
}
$script:GuideRuntimeDir = Join-Path $script:GuideRoot "runtime"
if (!(Test-Path -LiteralPath $script:GuideRuntimeDir)) {
    New-Item -ItemType Directory -Force -Path $script:GuideRuntimeDir | Out-Null
}
$script:GuideStateFile = Join-Path $script:GuideRuntimeDir "guide-state.json"

# -----------------------------------------------------------------
# Reading Progress Persistence
# -----------------------------------------------------------------

function Get-WorkCtlGuideProgress {
    if (Test-Path -LiteralPath $script:GuideStateFile) {
        try {
            $raw = Get-Content -LiteralPath $script:GuideStateFile -Raw | ConvertFrom-Json
            $completed = @{}
            if ($raw -and $raw.CompletedSections) {
                foreach ($s in $raw.CompletedSections) {
                    $completed[$s] = $true
                }
            }
            return @{
                CompletedSections = $completed
                LastTopicId = if ($raw.LastTopicId) { [string]$raw.LastTopicId } else { "overview" }
                LastSectionIndex = if ($raw.LastSectionIndex) { [int]$raw.LastSectionIndex } else { 0 }
            }
        } catch {}
    }
    return @{
        CompletedSections = @{}
        LastTopicId = "overview"
        LastSectionIndex = 0
    }
}

function Save-WorkCtlGuideProgress($Progress) {
    try {
        $secList = New-Object System.Collections.Generic.List[string]
        if ($Progress -and $Progress.CompletedSections) {
            foreach ($k in $Progress.CompletedSections.Keys) {
                if ($Progress.CompletedSections[$k]) {
                    $secList.Add([string]$k)
                }
            }
        }
        $obj = [ordered]@{
            Version = 1
            LastUpdated = (Get-Date).ToString("o")
            LastTopicId = if ($Progress.LastTopicId) { $Progress.LastTopicId } else { "overview" }
            LastSectionIndex = if ($Progress.LastSectionIndex) { [int]$Progress.LastSectionIndex } else { 0 }
            CompletedSections = $secList.ToArray()
        }
        $json = $obj | ConvertTo-Json -Depth 4
        Set-Content -LiteralPath $script:GuideStateFile -Value $json -Force -Encoding UTF8
    } catch {}
}

function Set-WorkCtlGuideSectionCompleted($TopicId, $SectionId) {
    $prog = Get-WorkCtlGuideProgress
    $key = "$TopicId`:$SectionId"
    $prog.CompletedSections[$key] = $true
    $prog.LastTopicId = $TopicId
    Save-WorkCtlGuideProgress $prog
}

# -----------------------------------------------------------------
# Feature Status Badge Helpers
# -----------------------------------------------------------------

function Get-WorkCtlBadgeColor($badge) {
    switch ($badge) {
        "AVAILABLE"    { return [ConsoleColor]::Green }
        "READ ONLY"    { return [ConsoleColor]::Cyan }
        "GUARDED"      { return [ConsoleColor]::Yellow }
        "EXPERIMENTAL" { return [ConsoleColor]::Magenta }
        "PLANNED"      { return [ConsoleColor]::DarkGray }
        default        { return [ConsoleColor]::Gray }
    }
}

# -----------------------------------------------------------------
# Dynamic Content Providers
# -----------------------------------------------------------------

function Get-GuideDynamicCommandsContent {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("WorkCtl includes a rich registry of native shell commands, categorized by function.")
    $lines.Add("")
    $lines.Add("[NOTE] Live Dynamic Registry: The commands below are automatically discovered from the active shell engine.")
    $lines.Add("")

    if ($script:ShellCommandRegistry) {
        $cats = @($script:ShellCommandRegistry.Values | ForEach-Object { $_.Category } | Select-Object -Unique)
        foreach ($c in $cats) {
            $lines.Add("=== CATEGORY: $($c.ToUpperInvariant()) ===")
            $cmds = @($script:ShellCommandRegistry.Values | Where-Object { $_.Category -eq $c })
            foreach ($cmd in $cmds) {
                $aliasStr = if ($cmd.Aliases -and $cmd.Aliases.Count -gt 0) { " [alias: " + ($cmd.Aliases -join ", ") + "]" } else { "" }
                $lines.Add("  * $($cmd.Name)$aliasStr - $($cmd.Description)")
                $lines.Add("    Usage: $($cmd.Usage)  |  Risk: $($cmd.Risk)")
            }
            $lines.Add("")
        }
    } else {
        $lines.Add("  ShellCommandRegistry not currently loaded in memory.")
    }
    return ($lines -join "`n")
}

function Get-GuideDynamicWorkloadsContent {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("WorkCtl manages background services, AI models, developer runtimes, and system tools.")
    $lines.Add("")
    $lines.Add("[NOTE] Live Workload Discovery: The inventory below is parsed directly from config\workloads.json.")
    $lines.Add("")

    $wReg = if (Get-Command Get-ShellCachedWorkloads -ErrorAction SilentlyContinue) { Get-ShellCachedWorkloads } else { $null }
    if (!$wReg -and (Get-Command Get-WorkloadsRegistry -ErrorAction SilentlyContinue)) { $wReg = Get-WorkloadsRegistry }

    if ($wReg -and $wReg.components) {
        $props = @($wReg.components.PSObject.Properties)
        $lines.Add(("{0,-14} {1,-10} {2,-8} {3,-14} {4}" -f "NAME", "CATEGORY", "PORT", "STOP POLICY", "DESCRIPTION"))
        $lines.Add("-" * 76)
        foreach ($p in $props) {
            $comp = $p.Value
            $portStr = if ($comp.port) { [string]$comp.port } else { "N/A" }
            $policy = if ($comp.stopPolicy) { [string]$comp.stopPolicy } else { "STANDARD" }
            $lines.Add(("{0,-14} {1,-10} {2,-8} {3,-14} {4}" -f $p.Name, $comp.category, $portStr, $policy, $comp.description))
        }
    } else {
        $lines.Add("  No workloads loaded from config\workloads.json.")
    }
    return ($lines -join "`n")
}

function Get-GuideDynamicToolsContent {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("WorkCtl tracks installed external applications, development tools, and diagnostic utilities.")
    $lines.Add("")
    $lines.Add("[NOTE] Live Tool Discovery: The table below reflects configured tools from config\tools.json.")
    $lines.Add("")

    $tReg = if (Get-Command Get-WorkCtlToolsRegistry -ErrorAction SilentlyContinue) { Get-WorkCtlToolsRegistry } else { $null }
    if ($tReg -and $tReg.tools) {
        $props = @($tReg.tools.PSObject.Properties)
        $lines.Add(("{0,-14} {1,-12} {2,-8} {3}" -f "TOOL ID", "CATEGORY", "STATUS", "LABEL / PATH"))
        $lines.Add("-" * 76)
        foreach ($p in $props) {
            $t = $p.Value
            $present = if ($t.installPath) { Test-Path -LiteralPath $t.installPath } elseif ($t.exePath) { Test-Path -LiteralPath $t.exePath } elseif ($t.command) { [bool](Get-Command $t.command -ErrorAction SilentlyContinue) } else { $false }
            $statusStr = if ($present) { "INSTALLED" } else { "MISSING" }
            $lines.Add(("{0,-14} {1,-12} {2,-8} {3}" -f $p.Name, $t.category, $statusStr, $t.label))
        }
    } else {
        $lines.Add("  No tools loaded from config\tools.json.")
    }
    return ($lines -join "`n")
}

function Get-GuideDynamicPowerToysContent {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Microsoft PowerToys control plane provides 34 system productivity utilities.")
    $lines.Add("")
    $lines.Add("[NOTE] Live PowerToys Discovery: Modules and metadata discovered via DSC and registry.")
    $lines.Add("")

    if ($script:PTModuleMetadata) {
        $cats = @($script:PTModuleMetadata.Values | ForEach-Object { $_.Category } | Select-Object -Unique)
        foreach ($cat in $cats) {
            $lines.Add("=== CATEGORY: $($cat.ToUpperInvariant()) ===")
            $mods = @($script:PTModuleMetadata.Values | Where-Object { $_.Category -eq $cat })
            foreach ($m in $mods) {
                $lines.Add("  * $($m.Name) - $($m.Description)")
            }
            $lines.Add("")
        }
    } else {
        $lines.Add("  PowerToys module metadata not loaded.")
    }
    return ($lines -join "`n")
}

function Get-GuideDynamicMediaContent {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Smart Media Control Plane coordinates media libraries, VLC player, and Sonarr automation.")
    $lines.Add("")
    $lines.Add("[NOTE] Live Media Roots: Configured roots from config\media.json.")
    $lines.Add("")

    $mPath = Join-Path $script:GuideRoot "config\media.json"
    if (Test-Path -LiteralPath $mPath) {
        try {
            $mJson = Get-Content -LiteralPath $mPath -Raw | ConvertFrom-Json
            if ($mJson -and $mJson.roots) {
                $lines.Add(("{0,-20} {1,-12} {2,-8} {3}" -f "LABEL", "CATEGORY", "EXISTS", "PATH"))
                $lines.Add("-" * 76)
                foreach ($r in $mJson.roots) {
                    $exists = if (Test-Path -LiteralPath $r.path) { "YES" } else { "NO" }
                    $lines.Add(("{0,-20} {1,-12} {2,-8} {3}" -f $r.label, $r.category, $exists, $r.path))
                }
            }
            if ($mJson.supportedExtensions) {
                $lines.Add("")
                $lines.Add("Supported Formats: " + ($mJson.supportedExtensions -join ", "))
            }
        } catch {}
    } else {
        $lines.Add("  config\media.json not found.")
    }
    return ($lines -join "`n")
}

function Get-GuideDynamicDevelopmentContent {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Workstation Development Hub coordinates projects, runtimes, and AI coding agents.")
    $lines.Add("")
    $lines.Add("[NOTE] Live Project & Agent Discovery: Automatically scanned from E:\Workspace and PATH.")
    $lines.Add("")

    $lines.Add("=== DISCOVERED WORKSPACE PROJECTS (E:\Workspace) ===")
    $projs = if (Get-Command Get-WorkCtlProjects -ErrorAction SilentlyContinue) { Get-WorkCtlProjects } else { @() }
    if ($projs -and $projs.Count -gt 0) {
        $lines.Add(("{0,-24} {1,-18} {2,-12} {3}" -f "PROJECT NAME", "PRIMARY TYPE", "GIT BRANCH", "PATH"))
        $lines.Add("-" * 76)
        foreach ($p in $projs) {
            $branchStr = if ($p.Branch) { $p.Branch } else { "none" }
            $lines.Add(("{0,-24} {1,-18} {2,-12} {3}" -f $p.Name, $p.PrimaryType, $branchStr, $p.Path))
        }
    } else {
        $lines.Add("  No projects found in E:\Workspace.")
    }
    $lines.Add("")

    $lines.Add("=== AI CODING AGENTS & RUNTIMES ===")
    $agents = if (Get-Command Get-WorkCtlAiAgents -ErrorAction SilentlyContinue) { Get-WorkCtlAiAgents } else { @() }
    if ($agents -and $agents.Count -gt 0) {
        $lines.Add(("{0,-14} {1,-12} {2,-10} {3}" -f "AGENT ID", "POLICY", "STATUS", "RUNTIME / MODEL"))
        $lines.Add("-" * 76)
        foreach ($a in $agents) {
            $st = if ($a.Installed) { "READY" } else { "MISSING" }
            $lines.Add(("{0,-14} {1,-12} {2,-10} {3}" -f $a.Id, $a.Policy, $st, $a.Runtime))
        }
    } else {
        $lines.Add("  No AI agents registered.")
    }

    return ($lines -join "`n")
}

function Get-GuideDynamicStorageContent {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Workstation storage architecture normalizes physical drives, local volumes, and virtual mounts.")
    $lines.Add("")
    $lines.Add("[NOTE] Live Normalized Storage Topology: Queried via Get-WorkCtlStorageSnapshot.")
    $lines.Add("")

    $snap = if (Get-Command Get-WorkCtlStorageSnapshot -ErrorAction SilentlyContinue) { Get-WorkCtlStorageSnapshot } else { $null }
    if ($snap -and $snap.Generation -eq 0 -and (Get-Command Update-WorkCtlStorageSnapshot -ErrorAction SilentlyContinue)) {
        Update-WorkCtlStorageSnapshot -Force
        $snap = Get-WorkCtlStorageSnapshot
    }
    $topo = if ($snap) { $snap.Data } else { $null }

    if ($topo) {
        $lines.Add("=== PHYSICAL STORAGE DEVICES ===")
        if ($topo.PhysicalDisks) {
            foreach ($d in $topo.PhysicalDisks) {
                $capGB = [math]::Round($d.Size / 1GB, 1)
                $lines.Add("  * Disk $($d.Number): $($d.FriendlyName) ($($d.BusType), $capGB GB) - Status: $($d.OperationalStatus)")
            }
        }
        $lines.Add("")

        $lines.Add("=== LOCAL FIXED VOLUMES (PHYSICAL BACKING) ===")
        if ($topo.LocalVolumes) {
            $lines.Add(("{0,-6} {1,-14} {2,-10} {3,-12} {4,-12} {5}" -f "DRIVE", "LABEL", "FS", "CAPACITY", "FREE SPACE", "HEALTH"))
            $lines.Add("-" * 76)
            foreach ($v in $topo.LocalVolumes) {
                $capGB = [math]::Round($v.Capacity / 1GB, 1)
                $freeGB = [math]::Round($v.FreeSpace / 1GB, 1)
                $lines.Add(("{0,-6} {1,-14} {2,-10} {3,-12} {4,-12} {5}" -f "$($v.DriveLetter):", $v.VolumeLabel, $v.FileSystem, "$capGB GB", "$freeGB GB", $v.HealthStatus))
            }
        }
        $lines.Add("")

        $lines.Add("=== OTHER MOUNTS (VIRTUAL / CLOUD) ===")
        if ($topo.OtherMounts -and $topo.OtherMounts.Count -gt 0) {
            $lines.Add(("{0,-6} {1,-20} {2,-10} {3}" -f "DRIVE", "LABEL", "FS", "CLASSIFICATION"))
            $lines.Add("-" * 76)
            foreach ($m in $topo.OtherMounts) {
                $lines.Add(("{0,-6} {1,-20} {2,-10} {3}" -f "$($m.DriveLetter):", $m.VolumeLabel, $m.FileSystem, $m.Classification))
            }
        } else {
            $lines.Add("  No other mounts detected.")
        }
        $lines.Add("")

        $lines.Add("=== WINCDEMU VIRTUAL DISK IMAGES ===")
        if ($topo.MountedImages -and $topo.MountedImages.Count -gt 0) {
            foreach ($img in $topo.MountedImages) {
                $lines.Add("  * Drive $($img.DriveLetter): mounted from $($img.ImagePath)")
            }
        } else {
            $lines.Add("  No virtual disk images currently mounted.")
        }
    } else {
        $lines.Add("  Storage snapshot not available.")
    }

    return ($lines -join "`n")
}

function Get-GuideDynamicHardwareContent {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Workstation hardware telemetry, thermal profiles, and cooling controller status.")
    $lines.Add("")
    $lines.Add("[NOTE] Live Hardware Metrics: Queried via Get-WorkCtlHardwareSnapshot.")
    $lines.Add("")

    $snap = if (Get-Command Get-WorkCtlHardwareSnapshot -ErrorAction SilentlyContinue) { Get-WorkCtlHardwareSnapshot } else { $null }
    if ($snap -and $snap.Generation -eq 0 -and (Get-Command Update-WorkCtlHardwareSnapshot -ErrorAction SilentlyContinue)) {
        Update-WorkCtlHardwareSnapshot -Force
        $snap = Get-WorkCtlHardwareSnapshot
    }
    $hw = if ($snap) { $snap.Data } else { $null }

    if ($hw) {
        $lines.Add("=== PROCESSOR & GRAPHICS HARDWARE ===")
        if ($hw.CpuName) {
            $lines.Add("  * CPU: $($hw.CpuName)")
        }
        if ($hw.GpuName) {
            $lines.Add("  * GPU: $($hw.GpuName)")
        }
        if ($hw.GpuDriver) {
            $lines.Add("  * GPU Driver: $($hw.GpuDriver)")
        }
        $lines.Add("")

        $lines.Add("=== HP VICTUS THERMAL & FAN CONTROL SUBSYSTEM ===")
        $model = if ($hw.OmenModel) { $hw.OmenModel } else { "HP Victus Gaming Laptop" }
        $activeOwner = if ($hw.ActiveFanOwner) { $hw.ActiveFanOwner } else { "BIOS AUTO" }
        $lines.Add("  * System Platform   : $model")
        $lines.Add("  * Active Controller : $activeOwner")
        $lines.Add("  * Safety Interlock  : ENFORCED (FanControl & OmenCore mutually exclusive)")
        $lines.Add("")

        $lines.Add("=== FAN CONTROLLER INVENTORY ===")
        $fcVer = if ($hw.FanControlVersion) { "v$($hw.FanControlVersion)" } else { "Unknown" }
        $lines.Add("  * FanControl.exe    : Installed ($fcVer) | Running: $($hw.FanControlRunning) | Curves: $($hw.FanControlCurvesCount)")
        $ocEc = if ($hw.OmenEcAvailable) { "Available" } else { "Locked (Secure Boot)" }
        $lines.Add("  * OmenCore CLI      : Mode: $($hw.OmenFanBackend) (EC access: $ocEc)")
    } else {
        $lines.Add("  Hardware snapshot not available.")
    }

    return ($lines -join "`n")
}

function Get-GuideDynamicServicesContent {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Workstation Services Explorer tracks filtered, categorized Windows services.")
    $lines.Add("")
    $lines.Add("[NOTE] Live Service Status: Queried via Get-WorkCtlServicesSnapshot.")
    $lines.Add("")

    $snap = if (Get-Command Get-WorkCtlServicesSnapshot -ErrorAction SilentlyContinue) { Get-WorkCtlServicesSnapshot } else { $null }
    if ($snap -and $snap.Generation -eq 0 -and (Get-Command Update-WorkCtlServicesSnapshot -ErrorAction SilentlyContinue)) {
        Update-WorkCtlServicesSnapshot -Force
        $snap = Get-WorkCtlServicesSnapshot
    }
    $data = if ($snap) { $snap.Data } else { $null }

    if ($data) {
        $lines.Add("=== SERVICE INVENTORY SUMMARY ===")
        $lines.Add("  * Total System Services Monitored : $($data.TotalCount)")
        $lines.Add("  * Workstation Filtered Services   : $(if ($data.Services) { $data.Services.Count } else { 0 })")
        $lines.Add("  * Active Running Services         : $($data.RunningCount)")
        $lines.Add("  * Stopped Services                : $($data.StoppedCount)")
        $lines.Add("  * Automatic Startup Services      : $($data.AutoCount)")
        $lines.Add("")

        $lines.Add("=== KEY WORKSTATION SERVICES ===")
        $lines.Add(("{0,-20} {1,-10} {2,-12} {3}" -f "SERVICE NAME", "STATUS", "STARTUP", "DISPLAY NAME"))
        $lines.Add("-" * 76)
        if ($data.Services) {
            $workstationSvcs = @($data.Services | Select-Object -First 10)
            foreach ($s in $workstationSvcs) {
                $lines.Add(("{0,-20} {1,-10} {2,-12} {3}" -f $s.Name, $s.Status, $s.StartupType, $s.DisplayName))
            }
            if ($data.Services.Count -gt 10) {
                $lines.Add("  ... and $(($data.Services.Count - 10)) more workstation services (View in Services Explorer [S])")
            }
        }
    } else {
        $lines.Add("  Services snapshot not available.")
    }

    return ($lines -join "`n")
}

# -----------------------------------------------------------------
# Guide Topic & Section Catalog Definition
# -----------------------------------------------------------------

function Get-WorkCtlGuideCatalog {
    $topics = @(
        # 1. OVERVIEW
        [PSCustomObject]@{
            Id = "overview"
            Title = "Workstation Architecture"
            Icon = "[ARCH]"
            Status = "AVAILABLE"
            Summary = "Philosophy, control planes vs execution backends, and directory topology"
            Sections = @(
                [PSCustomObject]@{
                    Id = "intro"
                    Title = "Philosophy & Core Tenet"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl is the central Windows Workstation Control Plane.

THE ARCHITECTURAL PRINCIPLE:
  * WorkCtl = Central Control Plane (discovery, inspection, launch, governance, telemetry)
  * External Applications = Execution / Rendering Backends

Examples:
  * WorkCtl controls and indexes the media library -> VLC renders the video.
  * WorkCtl displays automation state and calendar -> Sonarr handles TV series scheduling.
  * WorkCtl monitors Docker and MySQL -> Docker Engine runs containerized workloads.

The terminal serves as your cockpit, unifying separate workstation utilities into a cohesive, fast interface.
"@
                    Syntax = "workctl [subcommand] [arguments]"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "subsystems"
                    Title = "Integrated Subsystems"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl consists of modular subsystems cooperating through a shared event and telemetry bus:

  1. Core Shell (shell.ps1) - Hybrid TUI cockpit, Fish/Zsh-inspired command line, and history.
  2. UI Engine (ui.ps1) - Differential terminal renderer, direct console stream, ANSI themes.
  3. Workloads (workloads.ps1) - Background service management, port probes, stop policy governance.
  4. Tools & Runtimes (tools.ps1) - Registry of external desktop and CLI tools (config\tools.json).
  5. PowerToys Control (powertoys.ps1) - 34 Windows productivity utilities and resident runner.
  6. Smart Media (media.ps1) - VLC player backend, Sonarr series automation, and library indexer.
  7. Storage Subsystem (providers\storage.ps1) - Normalized physical NVMe, fixed volumes, and virtual mounts.
  8. Hardware & Cooling (providers\hardware.ps1) - CPU/GPU specs, thermal metrics, and fan interlock.
  9. Services Explorer (providers\services.ps1) - Workstation-filtered service inspection and startup modes.
  10. Telemetry & Hardware (providers\telemetry.ps1) - Real-time CPU, RAM, GPU, network, and disk metrics.
  11. Diagnostics & Doctor - Automated self-checks, port availability, and health audits.
"@
                    Syntax = "workctl doctor"
                    Example = "! Get-Date"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "filesystem"
                    Title = "Workstation File Topology"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl follows a strict, predictable directory structure under E:\TOOLS\WorkstationControl:

  E:\TOOLS\WorkstationControl\
    |-- workctl.ps1           # Main entry point and CLI router
    |-- modules\              # Subsystem implementations (ui, shell, workloads, tools, etc.)
    |     \-- providers\      # High-performance cached data providers (storage, hardware, etc.)
    |-- config\               # Declarative JSON configs (workloads.json, tools.json, media.json)
    |-- runtime\              # Runtime caches, locks, history, and guide state
    |-- backups\              # Automated pre-flight snapshots before modifications
    |-- tests\ / scratch\     # Unit, integration, and regression test suites

[TIP] Always keep configurations in config\ and transient data in runtime\. Never hardcode machine-specific paths outside config files.
"@
                    Syntax = "ls E:\TOOLS\WorkstationControl"
                    Example = "ls"
                    ExampleRisk = "Safe"
                }
            )
        },

        # 2. SHELL & NAVIGATION
        [PSCustomObject]@{
            Id = "shell"
            Title = "Hybrid Shell & Navigation"
            Icon = "[SHLL]"
            Status = "AVAILABLE"
            Summary = "Cockpit navigation, Command Mode (:), file operations, completions, and history"
            Sections = @(
                [PSCustomObject]@{
                    Id = "cockpit"
                    Title = "Cockpit & Keyboard Navigation"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl shell blends mouse-free keyboard navigation with immediate visual feedback:

GLOBAL KEYBINDINGS:
  * Up / Down Arrow   : Move selection cursor across menus and lists (instant key coalescing)
  * PageUp / PageDown : Jump selection by 5 or 10 items
  * Home / End        : Jump immediately to first or last item
  * Enter             : Activate selected destination, workload, or action
  * : (Colon)         : Enter Command Mode (Fish/Zsh-inspired shell prompt)
  * / (Slash)         : Open fast full-text search modal across all entities
  * ? (Question Mark) : Open contextual Quick Help reference
  * Shift+?           : Jump directly to the relevant WorkCtl Guide chapter
  * Esc / B           : Return to previous screen via navigation stack
  * Q                 : Exit WorkCtl cleanly back to PowerShell

[NOTE] Fast hotkeys on Home: W=Workloads, T=PowerToys, V=Media, O=Tools, B=Storage, H=Hardware, S=Services, P=Processes, N=Network, D=Diagnostics, G=Guide.
"@
                    Syntax = ": [command]"
                    Example = "pwd"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "command-mode"
                    Title = "Command Mode & Prompt Syntax"
                    Status = "AVAILABLE"
                    Content = @"
Pressing `:` from any screen opens the WorkCtl command prompt:

  workctl:home >

FEATURES OF COMMAND MODE:
  * Command Registry: Execute registered commands (e.g. `status`, `workloads`, `tools`, `storage`, `hardware`, `services`, `doctor`).
  * File System Commands: Native `ls`, `cd`, `pwd` with tabular output and drive stats.
  * Native PowerShell (!): Prefix any command with `!` to run raw PowerShell:
      workctl:home > ! Get-Process -Name code
  * Auto-Completion (Tab): Press Tab to complete command names, arguments, and filesystem paths.
  * History (Up/Down): Recall previously typed commands persisted across sessions.
  * Safe Execution: Exceptions are caught by the inner recovery boundary, preventing shell crashes.
"@
                    Syntax = "! <PowerShellExpression>"
                    Example = "! (Get-Item .).FullName"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "fs-navigation"
                    Title = "File System Navigation"
                    Status = "AVAILABLE"
                    Content = @"
Navigate directories directly inside the WorkCtl shell without dropping to Windows Explorer:

  * `pwd` : Displays current working directory and volume free space.
  * `ls [path]` : Formatted tabular view of directory contents with sizes and modification times.
  * `cd <path>` : Change current shell directory (supports relative, absolute, and `..`).
  * `cd ~` : Jump to User Profile root.

[TIP] Output from `ls` and `pwd` is rendered in a scrollable, inspectable table view. Press `Esc` or `B` to return to the previous screen.
"@
                    Syntax = "ls [path]  |  cd <path>  |  pwd"
                    Example = "ls"
                    ExampleRisk = "Safe"
                }
            )
        },

        # 3. WORKLOADS
        [PSCustomObject]@{
            Id = "workloads"
            Title = "Workloads & Services Engine"
            Icon = "[WORK]"
            Status = "AVAILABLE"
            Summary = "Managing background services, presets, ports, and stopPolicy governance"
            Sections = @(
                [PSCustomObject]@{
                    Id = "lifecycle"
                    Title = "Workload Lifecycle & Operations"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl monitors background workloads such as MySQL 8, Docker Desktop, Ollama, and OpenClaw.

OPERATIONS:
  * `workloads`          : Open interactive Workloads cockpit.
  * `start <name>`       : Start workload and verify service/process launch.
  * `stop <name>`        : Stop workload according to governance stopPolicy.
  * `restart <name>`     : Graceful restart of workload components.
  * `info <name>`        : Display ports, health endpoints, log paths, and process PID.

HEALTH PROBES:
WorkCtl performs automated socket and HTTP health checks on configured ports (e.g. 3306 for MySQL, 11434 for Ollama, 18789 for OpenClaw).
"@
                    Syntax = "start <workload>  |  stop <workload>  |  info <workload>"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "presets"
                    Title = "Work Modes & Presets"
                    Status = "AVAILABLE"
                    Content = @"
Presets allow one-click activation of multi-workload developer configurations:

  * [1] DEV MODE     : Starts MySQL 8 + Docker Desktop for containerized software development.
  * [2] AI MODE      : Starts Ollama + OpenClaw Gateway for local AI agent workflows.
  * [3] LOCAL AI     : Starts Ollama + OmniRoute for local model routing.
  * [4] MAINTENANCE  : Launches Intel Driver & Support Assistant for system driver updates.

[NOTE] Work modes can be triggered from the Home screen using number keys 1, 2, 3, 4 or via command mode: `mode dev`, `mode ai`.
"@
                    Syntax = "mode [dev|ai|localai|maint]"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "live-inventory"
                    Title = "Live Workload Directory"
                    Status = "AVAILABLE"
                    Content = ""
                    Syntax = "workloads"
                    Example = "status"
                    ExampleRisk = "Safe"
                    DynamicProvider = { Get-GuideDynamicWorkloadsContent }
                }
            )
        },

        # 4. TOOLS & RUNTIMES
        [PSCustomObject]@{
            Id = "tools"
            Title = "External Applications & Tools"
            Icon = "[TOOL]"
            Status = "AVAILABLE"
            Summary = "Curated E:\TOOLS registry, WinDirStat scanning, and external app launch"
            Sections = @(
                [PSCustomObject]@{
                    Id = "registry"
                    Title = "E:\TOOLS Ecosystem Registry"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl integrates and audits the full workstation toolchain in E:\TOOLS:

CURATED TOOL SET:
  * WinDirStat  : Advanced disk usage visualization and tree scanning (runs on C: or E:).
  * FanControl  : Hardware fan curve tuning and thermal monitoring suite (v267).
  * OmenCore    : HP Victus / OMEN embedded controller telemetry tool.
  * qBittorrent : High-performance BitTorrent client (native desktop backend).
  * Torlink     : CLI torrent scraper, downloader, and watcher tool.
  * WinCDEmu    : Optical disc image mounter (ISO/CUE/BIN).
  * Freebuff    : Multi-agent interactive terminal coding assistant.
"@
                    Syntax = "tools  |  open <tool>"
                    Example = "tools"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "launching"
                    Title = "WinDirStat & Targeted Tools"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl provides direct launchers and scanners for workstation tools:

WINDIRSTAT TARGETED SCANS:
  * `windirstat C:` : Launch WinDirStat scanning primary OS volume.
  * `windirstat E:` : Launch WinDirStat scanning secondary tools/workspace volume.
  * In the Tools menu, pressing [S] triggers targeted WinDirStat scan on the current drive.

CACHED LAUNCH METRICS:
Tool definitions, executable paths, and port probes are cached via `modules\providers\tools.ps1`, eliminating navigation freezes.
"@
                    Syntax = "windirstat [drive]  |  open <tool>"
                    Example = "tools"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "live-tools"
                    Title = "Live Configured Tools"
                    Status = "AVAILABLE"
                    Content = ""
                    Syntax = "tools"
                    Example = "tools"
                    ExampleRisk = "Safe"
                    DynamicProvider = { Get-GuideDynamicToolsContent }
                }
            )
        },

        # 5. MICROSOFT POWERTOYS
        [PSCustomObject]@{
            Id = "powertoys"
            Title = "Microsoft PowerToys Control"
            Icon = "[PWTY]"
            Status = "AVAILABLE"
            Summary = "34 system utilities, FancyZones, ColorPicker, Text Extractor, and DSC configuration"
            Sections = @(
                [PSCustomObject]@{
                    Id = "architecture"
                    Title = "PowerToys Control Architecture"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl interfaces directly with Microsoft PowerToys v0.97+:

CONTROL PLANE CAPABILITIES:
  * Process State: Detects whether `PowerToys.exe` runner is active in the current user session.
  * Module Discovery: 34 system utilities categorized by function (Window Management, System, Input, Content, Diagnostics).
  * Module Toggles: Enable or disable individual modules dynamically via registry and JSON settings.
  * Settings App: Press [O] from the PowerToys screen to launch `PowerToys.Settings.exe`.
  * Restart Runner: Press [R] to gracefully restart the PowerToys background runner.

[IMPORTANT] The PowerToys runner is protected by WorkCtl governance: standard workload termination is blocked to prevent breaking hotkeys.
"@
                    Syntax = "powertoys  |  pt"
                    Example = "powertoys"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "categories"
                    Title = "Utility Categories"
                    Status = "AVAILABLE"
                    Content = @"
PowerToys modules are organized into 5 functional categories:

  1. Window Management: FancyZones, Always on Top, Workspaces, Crop And Lock.
  2. System Utilities : PowerToys Run, Awake, File Locksmith, Keyboard Manager, Registry Preview.
  3. Input Enhancers  : Mouse Without Borders, Mouse Utilities, Shortcut Guide, Paste as Plain Text.
  4. Content & Screen : Color Picker, Text Extractor, Screen Ruler, Peek, Image Resizer.
  5. Diagnostics & Dev: Hosts File Editor, Environment Variables, File Explorer Add-ons, Light Command Palette.
"@
                    Syntax = "powertoys"
                    Example = "powertoys"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "live-modules"
                    Title = "Live PowerToys Modules"
                    Status = "AVAILABLE"
                    Content = ""
                    Syntax = "powertoys"
                    Example = "powertoys"
                    ExampleRisk = "Safe"
                    DynamicProvider = { Get-GuideDynamicPowerToysContent }
                }
            )
        },

        # 6. SMART MEDIA CONTROL PLANE
        [PSCustomObject]@{
            Id = "media"
            Title = "Smart Media & Automation"
            Icon = "[MEDA]"
            Status = "AVAILABLE"
            Summary = "VLC backend, Sonarr series automation, library indexing, and capability matrix"
            Sections = @(
                [PSCustomObject]@{
                    Id = "architecture"
                    Title = "Smart Media Philosophy"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl provides a terminal control plane for your workstation media ecosystem:

CONTROL PLANE VS RENDERER:
  * WorkCtl indexes local media (`E:\Media`, `E:\TorlinkDownloads`), monitors download queues, and schedules series.
  * VLC Media Player renders video and audio streams with hardware acceleration.
  * Sonarr manages episode release dates, automated torrent grabs, and file organization.

This separation keeps the terminal lightweight and responsive while leveraging dedicated playback tools.
"@
                    Syntax = "media [sonarr|downloads|library]"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "sonarr"
                    Title = "Sonarr Automation & Queue"
                    Status = "AVAILABLE"
                    Content = @"
Sonarr integration provides:
  * Series Discovery: View monitored TV series, total episodes, and season status.
  * Episode Calendar: Upcoming airings in the next 7 to 14 days.
  * Activity Queue: Current active downloads and import progress.
  * System Health: Sonarr service connectivity, database integrity, and disk space warnings.

[TIP] Open Sonarr web UI directly via `open sonarr` or through the Media TUI screen.
"@
                    Syntax = "media sonarr"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "matrix"
                    Title = "Media Capability Matrix"
                    Status = "AVAILABLE"
                    Content = @"
The workstation media ecosystem is governed by a capability taxonomy across independent and pipeline tools:

1. DISCOVER:
   * Torlink: Interactive terminal torrent search across curated reputable sources.
   * WorkCtl Library Scanner: Discovers multimedia files across configured workspace roots.

2. AUTOMATE:
   * Sonarr: Episode calendar, season management, release monitoring, and metadata tracking.
   * Status: PARTIALLY CONFIGURED (1 Series tracked, 1 Root folder, 0 Indexers, 0 Download clients).

3. DOWNLOAD:
   * qBittorrent: Native BitTorrent client. API = DISABLED (WebUI disabled in configuration).
   * Torlink: Standalone CLI torrent downloader with local WebTorrent daemon engine.

4. IMPORT_ORGANIZE:
   * Sonarr: Automated series folder creation, episode renaming, file reorganization, and hardlinks.

5. METADATA:
   * FFprobe: Binary stream inspector extracting audio/video codecs, bitrates, resolutions, durations.
   * Sonarr: Series information, episode air dates, season poster art, and overview metadata.

6. PLAY:
   * VLC Media Player: High-performance playback engine launched directly from WorkCtl.

7. DISK_IMAGE_MOUNT:
   * WinCDEmu / Mounter: Independent optical disk image utility (ISO, CUE, BIN mounting and drive unmounting).
"@
                    Syntax = "media"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "live-roots"
                    Title = "Configured Media Roots"
                    Status = "AVAILABLE"
                    Content = ""
                    Syntax = "media"
                    Example = "status"
                    ExampleRisk = "Safe"
                    DynamicProvider = { Get-GuideDynamicMediaContent }
                }
            )
        },

        # 7. STORAGE & DRIVE TOPOLOGY
        [PSCustomObject]@{
            Id = "storage"
            Title = "Storage & Drive Topology"
            Icon = "[STOR]"
            Status = "AVAILABLE"
            Summary = "Normalized storage model, physical NVMe, local C:/E: volumes, and cloud virtual mounts"
            Sections = @(
                [PSCustomObject]@{
                    Id = "topology"
                    Title = "Physical NVMe & Local Volumes"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl implements a strict normalized storage model distinguishing real physical hardware from virtual mounts:

PHYSICAL STORAGE BACKING:
  * Disk 0: `WD PC SN740 SDDPNQD-512G-2006` NVMe SSD (512 GB).
  * Bus Type: NVMe (High-speed PCIe bus).
  * Operational Status: Healthy / Online.

LOCAL FIXED VOLUMES:
  * Partition 3 -> Drive `C:` (Label: `Windows`)
      Size: ~268.7 GB | Purpose: Operating System, Program Files, User Profiles.
  * Partition 4 -> Drive `E:` (Label: `New Volume`)
      Size: ~207.9 GB | Purpose: Developer Workspace (`E:\Workspace`), Workstation Tools (`E:\TOOLS`), Media (`E:\Media`).

[IMPORTANT] WorkCtl Home storage overview displays ONLY real local fixed volumes (C: and E:). Cloud mounts and virtual drives are classified separately.
"@
                    Syntax = "storage  |  cd [drive]:"
                    Example = "pwd"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "cloud-mounts"
                    Title = "Virtual Client Mounts (G:, H:)"
                    Status = "READ ONLY"
                    Content = @"
Under Windows Explorer, additional drive letters may appear that are not physical disks:

GOOGLE DRIVE VIRTUAL CLIENT MOUNTS:
  * Drive `G:` : `anmol392005@gmail.com - Google Drive`
  * Drive `H:` : `aarna7039@gmail.com - Google Drive`
  * File System: Virtual FAT32 volume managed by GoogleDriveFS.exe.
  * Capacity: Synchronized cloud quota (~15 GB each), backed by network streaming.

WORKCTL NORMALIZATION:
  * WorkCtl classifies G: and H: under `OTHER MOUNTS (VIRTUAL / CLOUD)`.
  * They are never counted in local workstation disk space health probes.
  * They are safely browseable via WorkCtl `ls G:\` or `cd H:\`.
"@
                    Syntax = "storage  |  ls G:\"
                    Example = "pwd"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "wincdemu"
                    Title = "WinCDEmu Virtual Disk Mounter"
                    Status = "GUARDED"
                    Content = @"
WinCDEmu provides lightweight, open-source optical image mounting:

INTEGRATION CAPABILITIES:
  * Driver: `mounter.exe` (installed in `E:\TOOLS\WinCDEmu`).
  * Supported Formats: ISO, CUE, BIN, RAW, NRG, IMG.
  * Live Inspection: WorkCtl queries active virtual drive mounts via `Get-MounterMountedImages`.
  * Mount Action: Mount an ISO image directly to an available drive letter via `Invoke-MounterMountImage`.
  * Unmount Action: Cleanly release mounted drive letters via `Invoke-MounterUnmountDrive`.
"@
                    Syntax = "storage  |  mount <path.iso>"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "live-storage"
                    Title = "Live Storage Directory"
                    Status = "AVAILABLE"
                    Content = ""
                    Syntax = "storage"
                    Example = "status"
                    ExampleRisk = "Safe"
                    DynamicProvider = { Get-GuideDynamicStorageContent }
                }
            )
        },

        # 8. HARDWARE & COOLING TELEMETRY
        [PSCustomObject]@{
            Id = "hardware"
            Title = "Hardware & Cooling Telemetry"
            Icon = "[HARD]"
            Status = "GUARDED"
            Summary = "CPU/GPU specs, HP Victus EC status, and FanControl vs OmenCore mutual exclusion"
            Sections = @(
                [PSCustomObject]@{
                    Id = "specs"
                    Title = "CPU, GPU & Platform Specifications"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl monitors workstation hardware architecture in real time:

PROCESSOR & CHIPSET:
  * CPU: `12th Gen Intel(R) Core(TM) i5-12450H`
  * Topology: 8 physical cores (4 Performance + 4 Efficient), 12 threads.
  * Base Frequency: 2.0 GHz | Max Turbo: 4.4 GHz.

GRAPHICS ACCELERATORS:
  * GPU 0 (Integrated): Intel(R) UHD Graphics (Display rasterizer, low power).
  * GPU 1 (Discrete): NVIDIA GeForce RTX 2050 (4 GB GDDR6 VRAM, CUDA/OptiX compute).

CHASSIS & BATTERY:
  * Platform: `HP Victus Gaming Laptop 15-fa1xxx`
  * Battery: Monitored via WMI battery status (Charge %, AC Power online).
"@
                    Syntax = "hardware"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "victus-ec"
                    Title = "HP Victus EC & Thermal Subsystem"
                    Status = "READ ONLY"
                    Content = @"
The HP Victus 15-fa1xxx chassis uses a proprietary Embedded Controller (EC):

THERMAL ARCHITECTURE:
  * Dual-fan cooling assembly (CPU fan + GPU fan with shared heatpipes).
  * EC Firmware: Enforces hardware-level thermal profiles (Quiet, Default, Performance).
  * Secure Boot Constraint: Under Windows 11 with Secure Boot enabled, direct kernel port I/O (EC write operations) is locked by Windows Kernel DMA Protection.
  * OmenCore Mode: Operates in read-only WMI telemetry mode.
  * Default Fan Ownership: Managed by motherboard BIOS Auto logic.
"@
                    Syntax = "hardware"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "fan-interlock"
                    Title = "OmenCore vs FanControl Interlock"
                    Status = "GUARDED"
                    Content = @"
WorkCtl enforces strict MUTUAL EXCLUSION between fan control software:

THE SAFETY HAZARD:
Running FanControl.exe and OmenCore simultaneously risks conflicting EC writes, fan oscillation, and unexpected thermal throttling.

WORKCTL SAFETY INTERLOCK POLICY:
  * Allowed Fan Owners: `BIOS AUTO`, `FANCONTROL`, or `OMENCORE`.
  * Mutual Exclusion Invariant: If FanControl is running, OmenCore mutations are explicitly BLOCKED.
  * If OmenCore is active, FanControl launch is guarded.
  * Baseline Safe State: BIOS AUTO ownership allows safe operation without any third-party background software.
  * Automated testing and telemetry queries are strictly non-mutating.
"@
                    Syntax = "hardware"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "live-hardware"
                    Title = "Live Hardware Telemetry"
                    Status = "AVAILABLE"
                    Content = ""
                    Syntax = "hardware"
                    Example = "status"
                    ExampleRisk = "Safe"
                    DynamicProvider = { Get-GuideDynamicHardwareContent }
                }
            )
        },

        # 9. WINDOWS SERVICES EXPLORER
        [PSCustomObject]@{
            Id = "services"
            Title = "Windows Services Explorer"
            Icon = "[SERV]"
            Status = "AVAILABLE"
            Summary = "Filtered workstation view, running/stopped tabs, startup types, and protected services"
            Sections = @(
                [PSCustomObject]@{
                    Id = "explorer"
                    Title = "Services Explorer & Categories"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl provides a dedicated Services Explorer ([S] from Home or `:services`):

FILTERED WORKSTATION VIEW:
Windows runs 300+ background services, most of which are OS internals. WorkCtl curates a high-signal filter of 57 developer, hardware, and media services:
  * Database: MySQL80, Redis, PostgreSQL.
  * Virtualization: Docker Desktop Service, WSLService, Hyper-V Host Compute.
  * Hardware & Audio: HP OMEN HSA, Realtek Audio, NVIDIA Display Container.
  * Network & Remote: OpenSSH Server, Windows Remote Management, DNS Client.

VIEW TABS:
  * `[WORKSTATION]` : Curated high-signal developer and hardware services.
  * `[RUNNING]`     : All actively running system services.
  * `[STOPPED]`     : All currently stopped system services.
  * `[ALL]`         : Complete unfiltered inventory (311 services).
"@
                    Syntax = "services"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "lifecycle"
                    Title = "Startup Types & Lifecycle Governance"
                    Status = "GUARDED"
                    Content = @"
WorkCtl displays real-time service configuration:

STARTUP MODES:
  * `Automatic` : Service starts automatically on Windows boot.
  * `Manual`    : Service starts on demand when requested by an application.
  * `Disabled`  : Service is blocked from starting.

NAVIGATION & INSPECTION:
  * Press [Tab] to switch view categories (`[WORKSTATION]`, `[RUNNING]`, `[STOPPED]`, `[ALL]`).
  * Press [Up] / [Down] to scroll through services.
  * Press [Enter] on a service to inspect its service description, binary path, and dependencies.
"@
                    Syntax = "services"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "protection"
                    Title = "Shielded System Services"
                    Status = "GUARDED"
                    Content = @"
WorkCtl protects core workstation infrastructure from accidental disruption:

SHIELDED SERVICES:
  * Docker Desktop Backend (`com.docker.service`): Guarded against accidental stop during build pipelines.
  * Windows Audio (`Audiosrv`): Protected to prevent loss of workstation sound.
  * Windows Event Log (`EventLog`): Protected system telemetry infrastructure.
  * Antigravity & PowerToys runners: Explicitly shielded against process termination.

[CAUTION] Stopping or modifying protected services requires explicit confirmation and elevated administrative privileges.
"@
                    Syntax = "services"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "live-services"
                    Title = "Live Workstation Services"
                    Status = "AVAILABLE"
                    Content = ""
                    Syntax = "services"
                    Example = "status"
                    ExampleRisk = "Safe"
                    DynamicProvider = { Get-GuideDynamicServicesContent }
                }
            )
        },

        # 10. GOVERNANCE & SAFETY
        [PSCustomObject]@{
            Id = "governance"
            Title = "Safety & Governance Invariants"
            Icon = "[SAFE]"
            Status = "GUARDED"
            Summary = "Protected workloads, confirmation modals, process safeguards, and stop policies"
            Sections = @(
                [PSCustomObject]@{
                    Id = "shields"
                    Title = "Protected Shields (Invariants)"
                    Status = "GUARDED"
                    Content = @"
WorkCtl enforces strict workstation governance to protect critical development and system components:

EXPLICIT TERMINATION BLOCKS:
  * `antigravity` : Explicitly BLOCKED from stopping or killing. Antigravity is the primary AI agent and workstation orchestrator. Terminating it would abort your active development session.
  * `powertoys`   : Explicitly BLOCKED from stopping or killing via standard workload actions. Managed strictly through the PowerToys subsystem.

Attempting `stop antigravity` or `kill powertoys` immediately triggers a non-dismissible safety block modal.
"@
                    Syntax = "stop <workload> [Blocked for Antigravity & PowerToys]"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "confirmations"
                    Title = "Confirmation Modals & Policies"
                    Status = "GUARDED"
                    Content = @"
DESTRUCTIVE ACTION SAFEGUARDS:
  * `discord` : Configured with `stopPolicy = 'CONFIRM'`. Stopping or killing Discord presents an explicit [Y/N] confirmation modal to prevent accidental communication loss during team calls.
  * Standard Workloads: Workloads marked `stopPolicy = 'STANDARD'` stop without modal prompt when explicitly requested by the user.

[CAUTION] Governance policies cannot be bypassed via aliases (`kill`, `terminate`). They are evaluated at the kernel dispatch layer of the shell.
"@
                    Syntax = "stop discord -> [Y/N Confirmation Modal]"
                    Example = "status"
                    ExampleRisk = "Safe"
                }
            )
        },

        # 11. DIAGNOSTICS & TROUBLESHOOTING
        [PSCustomObject]@{
            Id = "diagnostics"
            Title = "Diagnostics & Error Recovery"
            Icon = "[DIAG]"
            Status = "AVAILABLE"
            Summary = "Workstation doctor, inner recovery boundary, Error IDs, and telemetry worker"
            Sections = @(
                [PSCustomObject]@{
                    Id = "doctor"
                    Title = "Workstation Doctor & Health Probes"
                    Status = "AVAILABLE"
                    Content = @"
Run `doctor` or `diagnostics` to audit your workstation environment:

AUTOMATED AUDIT CHECKS:
  * Core directories (E:\TOOLS\WorkstationControl, config\, runtime\)
  * Configuration files integrity (workloads.json, tools.json, media.json)
  * Port occupancy: Checks whether ports 3306 (MySQL), 11434 (Ollama), 8989 (Sonarr) are responding
  * Hardware thresholds: Flags RAM usage > 85%, CPU > 90%, or Drive C: free space < 10 GB
  * Subsystem modules syntax and dot-sourcing status
"@
                    Syntax = "doctor  |  diagnostics"
                    Example = "status"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "recovery"
                    Title = "Inner Recovery Boundary & Error IDs"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl implements an Inner Recovery Boundary protecting the interactive event loop:

CRASH PROTECTION:
  * If an unexpected exception occurs inside a screen renderer or key handler, WorkCtl catches it safely.
  * Rather than dumping raw stack traces and terminating PowerShell, WorkCtl displays the dedicated Recovery Screen (`shell-error`).
  * Displays Subsystem, Screen, Action, and a unique Error ID (e.g. `WCTL-UI-STATE-482`).
  * Pressing `Esc` or `Enter` resets state cleanly and returns to the Home cockpit.
"@
                    Syntax = "WCTL-UI-STATE-###"
                    Example = "pwd"
                    ExampleRisk = "Safe"
                }
            )
        },

        # 12. COMMAND DIRECTORY
        [PSCustomObject]@{
            Id = "commands"
            Title = "Command Reference & Syntax"
            Icon = "[CMDS]"
            Status = "AVAILABLE"
            Summary = "Live dynamically-generated catalog of all registered shell commands and examples"
            Sections = @(
                [PSCustomObject]@{
                    Id = "live-directory"
                    Title = "Complete Live Command Catalog"
                    Status = "AVAILABLE"
                    Content = ""
                    Syntax = "help  |  help <command>"
                    Example = "help"
                    ExampleRisk = "Safe"
                    DynamicProvider = { Get-GuideDynamicCommandsContent }
                },
                [PSCustomObject]@{
                    Id = "common-syntax"
                    Title = "Common Syntax & Execution Rules"
                    Status = "AVAILABLE"
                    Content = @"
COMMAND EXECUTION RULES:
  * Verbs: `start`, `stop`, `restart`, `info`, `open`, `launch`, `storage`, `hardware`, `services`, `help`, `cd`, `ls`, `pwd`.
  * Aliases: Shorthand shortcuts like `st` for status, `wl` for workloads, `pt` for powertoys, `r` for resources.
  * Native Escapes: Prefix with `!` to pass expressions directly to Windows PowerShell.
  * Quoting: Paths with spaces should be wrapped in quotes (e.g. `cd "E:\Workspace\My Project"`).
  * Auto-complete: Press `Tab` anywhere to complete commands or paths.
"@
                    Syntax = "help <command>"
                    Example = "help start"
                    ExampleRisk = "Safe"
                }
            )
        },

        # 13. CUSTOMIZATION
        [PSCustomObject]@{
            Id = "customization"
            Title = "Extending & Customizing WorkCtl"
            Icon = "[CUST]"
            Status = "AVAILABLE"
            Summary = "Adding workloads, registering custom tools, creating presets, and configuring keys"
            Sections = @(
                [PSCustomObject]@{
                    Id = "add-workload"
                    Title = "Adding a Custom Workload"
                    Status = "AVAILABLE"
                    Content = @"
To add a new background workload:

1. Open E:\TOOLS\WorkstationControl\config\workloads.json.
2. Under `"components"`, add a new key for your service:
    "redis": {
        "description": "Redis In-Memory Cache",
        "category": "database",
        "port": 6379,
        "healthEndpoint": "http://localhost:6379",
        "serviceName": "Redis",
        "stopPolicy": "STANDARD"
    }
3. Save the file. The workload immediately appears in `WORKCTL > WORKLOADS` and responds to `start redis`, `stop redis`.
"@
                    Syntax = "edit config\workloads.json"
                    Example = "workloads"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "add-tool"
                    Title = "Adding an External Tool"
                    Status = "AVAILABLE"
                    Content = @"
To register a new tool or executable:

1. Open E:\TOOLS\WorkstationControl\config\tools.json.
2. Under `"tools"`, add your tool configuration:
    "postman": {
        "label": "Postman API Client",
        "category": "Development",
        "exePath": "C:\\Users\\hp\\AppData\\Local\\Postman\\Postman.exe",
        "args": []
    }
3. Save the file. The tool appears in `WORKCTL > TOOLS` and can be launched with `open postman`.
"@
                    Syntax = "edit config\tools.json"
                    Example = "tools"
                    ExampleRisk = "Safe"
                }
            )
        },

        # 14. DEVELOPMENT & AI AGENTS
        [PSCustomObject]@{
            Id = "development"
            Title = "Development & AI Coding Agents"
            Icon = "[DEVL]"
            Status = "AVAILABLE"
            Summary = "Projects discovery, runtimes, AI coding agents (Freebuff, Antigravity), and console handoff"
            Sections = @(
                [PSCustomObject]@{
                    Id = "projects"
                    Title = "Workspace Projects Discovery"
                    Status = "AVAILABLE"
                    Content = @"
WorkCtl provides first-class awareness of active codebases in E:\Workspace:

AUTOMATIC DISCOVERY:
  * Automatically scans top-level directories in E:\Workspace.
  * Detects project types: Node.js/TypeScript (package.json), Python (pyproject/requirements), .NET (*.sln/*.csproj), Rust (Cargo.toml).
  * Inspects Git repositories, detecting active branch and dirty status.
  * Caches discovery metadata in runtime\project-discovery.json (TTL: 60s in-memory, 120s disk).
  * Excludes non-project artifacts (node_modules, .git, bin, obj, dist, venv).

NAVIGATION & COMMANDS:
  * Press [E] or [J] from Shell Home to open the Development Subsystem menu.
  * In Command Mode, run `projects` or `project <name>` to inspect details or cd.
"@
                    Syntax = "projects"
                    Example = "projects"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "agents"
                    Title = "AI Agent Topology & Governance"
                    Status = "GUARDED"
                    Content = @"
WorkCtl classifies AI coding tools and enforces strict governance boundaries:

AGENT TOPOLOGY:
  1. Google Antigravity (SUPERVISOR / PROTECTED)
     - Primary workstation pair-programming agent and architectural control plane.
     - Governance: SHIELDED against automated termination or reset.
  2. Freebuff (ON-DEMAND / EPHEMERAL)
     - Multi-agent terminal coding assistant (freebuff@0.0.174).
     - Execution model: Ephemeral process, 0 resident daemons, 0 idle RAM/ports.
  3. Visual Studio Code (DESKTOP IDE / LAUNCH)
     - Standard desktop IDE interface and extension host.

SAFETY GOVERNANCE:
  * WorkCtl shields primary agents from accidental process killing.
  * Subordinate agents run strictly on-demand in isolated console sessions.
"@
                    Syntax = "agents"
                    Example = "agents"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "freebuff"
                    Title = "Freebuff Architecture & Privacy"
                    Status = "AVAILABLE"
                    Content = @"
Freebuff is an ad-supported, free terminal AI coding assistant (v0.0.174):

TECHNICAL PROFILE:
  * Package: npm install -g freebuff (wrapper downloads native binary to ~/.config/manicode/freebuff.exe).
  * Default Engine: GLM 5.3 Flash (unmetered, fast code generation).
  * Alternative Models: DeepSeek-V3 / R1, MiniMax, Kimi (usage tier limits apply).
  * Process Model: Ephemeral process. Zero background daemons, zero idle RAM, zero network listeners when inactive.
  * Pricing & Usage: Ad-supported terminal interface; 6 daily 1-hour sessions for limited tiers in India.

PRIVACY & DATA SAFETY:
  * Terminal prompts and selected context files are transmitted to Codebuff/cloud providers.
  * Sensitive files (.env, credentials, secrets) should be excluded via .gitignore / prompt rules.
  * WorkCtl never passes private workstation credentials to external agent runtimes.
"@
                    Syntax = "freebuff [project]"
                    Example = "freebuff"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "handoff"
                    Title = "Interactive Console Handoff"
                    Status = "AVAILABLE"
                    Content = @"
Terminal AI agents (like Freebuff) require raw TTY interaction, ANSI escapes, and keyboard focus.

THE WORKCTL HANDOFF PRIMITIVE:
  When launching an interactive terminal tool:
  1. WorkCtl flushes any pending UI updates and suspends differential rendering.
  2. Restores cursor visibility and native console buffer attributes.
  3. Launches the child process (cmd /c freebuff) directly on the active console host.
  4. Waits synchronously for process exit without polling or CPU consumption.
  5. Upon exit, restores WorkCtl console settings, invalidates previous render state, and redraws the UI cleanly.

This guarantees seamless switching between WorkCtl's TUI cockpit and interactive CLI agent sessions.
"@
                    Syntax = "open freebuff"
                    Example = "tools"
                    ExampleRisk = "Safe"
                },
                [PSCustomObject]@{
                    Id = "live-development"
                    Title = "Live Projects & Agent Inventory"
                    Status = "AVAILABLE"
                    DynamicProvider = { Get-GuideDynamicDevelopmentContent }
                    Syntax = "dev"
                    Example = "dev"
                    ExampleRisk = "Safe"
                }
            )
        }
    )

    return $topics
}

# -----------------------------------------------------------------
# Guide State Initialization & Management
# -----------------------------------------------------------------

function Initialize-WorkCtlGuideState {
    param(
        [string]$InitialTopicId = "overview",
        [int]$InitialSectionIndex = 0,
        [string]$PreviousScreen = "shell-home"
    )

    $topics = Get-WorkCtlGuideCatalog
    $topicIdx = 0
    for ($i = 0; $i -lt $topics.Count; $i++) {
        if ($topics[$i].Id -ieq $InitialTopicId) {
            $topicIdx = $i
            break
        }
    }

    $progress = Get-WorkCtlGuideProgress

    [PSCustomObject]@{
        Topics = $topics
        SelectedTopicIndex = $topicIdx
        SelectedSectionIndex = [math]::Max(0, $InitialSectionIndex)
        ViewMode = "Topics" # "Topics", "Section", "Search"
        ScrollOffset = 0
        PreviousScreen = $PreviousScreen
        SearchQuery = ""
        SearchResults = @()
        SelectedSearchIndex = 0
        Progress = $progress
        LastExampleOutput = $null
        LastExampleCommand = ""
        Dirty = $true
    }
}

# -----------------------------------------------------------------
# Contextual Guide Mapper (Shift+?)
# -----------------------------------------------------------------

function Get-GuideTopicForScreen($ScreenId) {
    if (!$ScreenId) { return "overview" }
    switch -Wildcard ($ScreenId) {
        "shell-workload*"   { return "workloads" }
        "shell-tool*"       { return "tools" }
        "powertoys*"        { return "powertoys" }
        "media*"            { return "media" }
        "shell-storage*"    { return "storage" }
        "shell-hardware*"   { return "hardware" }
        "shell-service*"    { return "services" }
        "shell-process*"    { return "diagnostics" }
        "shell-network*"    { return "diagnostics" }
        "shell-diag*"       { return "diagnostics" }
        "shell-dev*"        { return "development" }
        "shell-project*"    { return "development" }
        "shell-agent*"      { return "development" }
        "shell-command*"    { return "shell" }
        "shell-search*"     { return "shell" }
        "shell-help*"       { return "commands" }
        default             { return "overview" }
    }
}

function Open-WorkCtlGuideContextual($State, $ScreenId) {
    $topicId = Get-GuideTopicForScreen $ScreenId
    $gState = Initialize-WorkCtlGuideState -InitialTopicId $topicId -InitialSectionIndex 0 -PreviousScreen $ScreenId
    $gState.ViewMode = "Section"
    $State.GuideState = $gState
    $State.Screen = "shell-guide"
    $State.Dirty = $true
}

# -----------------------------------------------------------------
# Search Engine across Guide
# -----------------------------------------------------------------

function Search-WorkCtlGuide($Query) {
    $results = New-Object System.Collections.Generic.List[object]
    if (!$Query -or $Query.Trim().Length -lt 2) { return @() }

    $q = $Query.Trim().ToLowerInvariant()
    $topics = Get-WorkCtlGuideCatalog
    $qWords = $q -split "\s+"

    foreach ($t in $topics) {
        for ($si = 0; $si -lt $t.Sections.Count; $si++) {
            $s = $t.Sections[$si]
            $score = 0
            $matchContext = ""

            $tTitleMatch = $true
            foreach ($w in $qWords) {
                if (!$t.Title.ToLowerInvariant().Contains($w)) { $tTitleMatch = $false; break }
            }
            if ($tTitleMatch) { $score += 50 }

            $sTitleMatch = $true
            foreach ($w in $qWords) {
                if (!$s.Title.ToLowerInvariant().Contains($w)) { $sTitleMatch = $false; break }
            }
            if ($sTitleMatch) { $score += 100 }

            $raw = if ($s.DynamicProvider) { & $s.DynamicProvider } else { $s.Content }
            if ($raw) {
                $rawLower = $raw.ToLowerInvariant()
                $allWordsPresent = $true
                foreach ($w in $qWords) {
                    if (!$rawLower.Contains($w)) { $allWordsPresent = $false; break }
                }
                if ($allWordsPresent) {
                    $score += 20
                    $firstW = $qWords[0]
                    $idx = $rawLower.IndexOf($firstW)
                    if ($idx -ge 0) {
                        $start = [math]::Max(0, $idx - 30)
                        $len = [math]::Min(80, $raw.Length - $start)
                        $matchContext = "..." + $raw.Substring($start, $len).Replace("`r", " ").Replace("`n", " ") + "..."
                    }
                }
            }

            if ($score -gt 0) {
                if (!$matchContext -and $raw) {
                    $trimRaw = $raw.Trim().Replace("`r", " ").Replace("`n", " ")
                    $len = [math]::Min(80, $trimRaw.Length)
                    $matchContext = "..." + $trimRaw.Substring(0, $len) + "..."
                }
                $results.Add([PSCustomObject]@{
                    TopicId = $t.Id
                    TopicTitle = $t.Title
                    SectionIndex = $si
                    SectionId = $s.Id
                    SectionTitle = $s.Title
                    Score = $score
                    Snippet = $matchContext
                    Status = $s.Status
                })
            }
        }
    }

    return @($results | Sort-Object Score -Descending)
}

# -----------------------------------------------------------------
# Interactive Code & Command Runner for Guide
# -----------------------------------------------------------------

function Invoke-WorkCtlGuideExample($State) {
    $g = $State.GuideState
    if (!$g) { return }
    $topic = $g.Topics[$g.SelectedTopicIndex]
    $sec = $topic.Sections[$g.SelectedSectionIndex]

    if (!$sec.Example) { return }

    if ($sec.ExampleRisk -ne "Safe") {
        $g.LastExampleCommand = $sec.Example
        $g.LastExampleOutput = @("Execution blocked for safety: Example is marked $($sec.ExampleRisk).")
        $g.Dirty = $true
        if (Get-Command Set-ShellNotification -ErrorAction SilentlyContinue) {
            Set-ShellNotification $State "Execution blocked for safety: Example is marked $($sec.ExampleRisk)." [ConsoleColor]::Yellow
        }
        return
    }

    $cmd = $sec.Example.Trim()
    $output = New-Object System.Collections.Generic.List[string]

    try {
        if ($cmd.StartsWith("!")) {
            $psCode = $cmd.Substring(1).Trim()
            $res = Invoke-Expression $psCode | Out-String
            foreach ($line in ($res -split "`n")) {
                if ($line.Trim().Length -gt 0) { $output.Add($line.TrimEnd()) }
            }
        } else {
            $parts = $cmd -split "\s+", 2
            $verb = $parts[0].ToLowerInvariant()
            $argsStr = if ($parts.Count -gt 1) { $parts[1] } else { "" }

            if ($script:ShellCommandRegistry -and $script:ShellCommandRegistry.ContainsKey($verb)) {
                $cDef = $script:ShellCommandRegistry[$verb]
                if ($cDef.Handler) {
                    & $cDef.Handler $argsStr
                    $output.Add("Command '$cmd' executed successfully.")
                }
            } else {
                $output.Add("Executed '$cmd'. (Output rendered on main workstation display)")
            }
        }
    } catch {
        $output.Add("Error executing example: $($_.Exception.Message)")
    }

    if ($output.Count -eq 0) {
        $output.Add("(Command executed cleanly with no stdout returned)")
    }

    $g.LastExampleCommand = $sec.Example
    $g.LastExampleOutput = $output.ToArray()
    $g.Dirty = $true
}

# -----------------------------------------------------------------
# Guide UI Rendering Frames
# -----------------------------------------------------------------

function New-GuideFrame($State) {
    $g = $State.GuideState
    if (!$g) {
        $State.GuideState = Initialize-WorkCtlGuideState
        $g = $State.GuideState
    }

    switch ($g.ViewMode) {
        "Topic"   { return New-GuideTopicFrame $State }
        "Section" { return New-GuideSectionReaderFrame $State }
        "Reader"  { return New-GuideSectionReaderFrame $State }
        "Search"  { return New-GuideSearchFrame $State }
        default   { return New-GuideCatalogFrame $State }
    }
}

function New-GuideCatalogFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    $canvas = Get-WorkCtlCanvas
    $margin = $canvas.Margin
    $g = $State.GuideState
    $topics = $g.Topics

    # 1. Canonical Header & Separator
    $f.Add((New-WorkCtlHeaderLine @("GUIDE", "WORKSTATION MANUAL")))
    $f.Add((New-WorkCtlSeparatorLine))

    # 2. Reading Progress Metric
    $totalSections = 0
    $completedCount = 0
    foreach ($t in $topics) {
        foreach ($s in $t.Sections) {
            $totalSections++
            $k = "$($t.Id):$($s.Id)"
            if ($g.Progress.CompletedSections[$k]) { $completedCount++ }
        }
    }
    $pct = if ($totalSections -gt 0) { [int][math]::Round(($completedCount / $totalSections) * 100) } else { 0 }
    $bar = New-WorkCtlBar -Current $completedCount -Total $totalSections -Width 24

    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "Progress  " Gray),
        $bar,
        (New-UiSegment ("   {0,3}% " -f $pct) Yellow),
        (New-UiSegment ("({0}/{1} sections completed)" -f $completedCount, $totalSections) DarkGray)
    )))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 3. Heading
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  LEARN" Gray)
    )))

    # 4. Content Area
    [int]$contentHeight = [math]::Max(5, $canvas.AvailableContentRows - 5)
    [int]$leftColWidth = $canvas.LeftPaneWidth
    [int]$rightColWidth = $canvas.RightPaneWidth
    $isWide = $canvas.IsWide

    $selTopic = if ($g.SelectedTopicIndex -lt $topics.Count) { $topics[$g.SelectedTopicIndex] } else { $topics[0] }

    for ($i = 0; $i -lt $topics.Count -and $i -lt $contentHeight; $i++) {
        $t = $topics[$i]
        $isSel = ($i -eq $g.SelectedTopicIndex)
        $cursor = if ($isSel) { "> " } else { "  " }
        $cursorCol = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::DarkGray }
        $titleCol = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::White }

        $tCompleted = $true
        foreach ($sec in $t.Sections) {
            if (!$g.Progress.CompletedSections["$($t.Id):$($sec.Id)"]) {
                $tCompleted = $false
                break
            }
        }
        $chkStr = if ($tCompleted) { "[x]" } else { "[ ]" }
        $chkCol = if ($tCompleted) { [ConsoleColor]::Green } else { [ConsoleColor]::DarkGray }

        $leftSegs = New-Object System.Collections.Generic.List[object]
        $leftSegs.Add((New-UiSegment $margin DarkGray))
        $leftSegs.Add((New-UiSegment $cursor $cursorCol))
        $leftSegs.Add((New-UiSegment ("{0} " -f $chkStr) $chkCol))
        $leftSegs.Add((New-UiSegment ("{0,-28}" -f $t.Title) $titleCol))

        if ($isWide) {
            $leftSegs.Add((New-UiSegment (" " * $canvas.PaneGap) DarkGray))

            # Right column: Topic Preview card
            if ($i -eq 0) {
                $leftSegs.Add((New-UiSegment "TOPIC" Gray))
            } elseif ($i -eq 1) {
                $leftSegs.Add((New-UiSegment $selTopic.Title Cyan))
            } elseif ($i -eq 2) {
                $sumTxt = $selTopic.Summary
                if ($sumTxt.Length -gt ($rightColWidth - 2)) { $sumTxt = $sumTxt.Substring(0, $rightColWidth - 4) + ".." }
                $leftSegs.Add((New-UiSegment $sumTxt Gray))
            } elseif ($i -eq 4) {
                $badgeCol = Get-WorkCtlBadgeColor $selTopic.Status
                $badgeStr = if ($selTopic.Status) { "[$($selTopic.Status)]" } else { "[AVAILABLE]" }
                $leftSegs.Add((New-UiSegment ("{0} sections  " -f $selTopic.Sections.Count) Yellow))
                $leftSegs.Add((New-UiSegment $badgeStr $badgeCol))
            } elseif ($i -eq 6) {
                $leftSegs.Add((New-UiSegment "Enter  Open Topic" DarkCyan))
            }
        }

        $f.Add((New-UiLine $leftSegs.ToArray()))
    }

    # Pad lines
    [int]$targetRows = [math]::Max(0, [int]($canvas.Height - 3))
    for ($pad = $f.Count; $pad -lt $targetRows; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    # 5. Pinned Canonical Footer
    $f.Add((New-WorkCtlSeparatorLine))
    $f.Add((New-WorkCtlFooter `
        -Actions @("Move", "Open", "Search", "Help", "Back") `
        -RightText ("Topic {0}/{1}" -f ($g.SelectedTopicIndex + 1), $topics.Count) `
        -Width $canvas.Width
    ))

    return $f.ToArray()
}

function New-GuideTopicFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    $canvas = Get-WorkCtlCanvas
    $margin = $canvas.Margin
    $g = $State.GuideState
    $selTopic = $g.Topics[$g.SelectedTopicIndex]
    $sections = $selTopic.Sections

    # 1. Canonical Header & Separator
    $f.Add((New-WorkCtlHeaderLine @("GUIDE", $selTopic.Title.ToUpperInvariant())))
    $f.Add((New-WorkCtlSeparatorLine))

    # 2. Topic Description Line
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  " DarkGray),
        (New-UiSegment $selTopic.Summary Gray)
    )))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 3. Heading
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "  SECTIONS" Gray)
    )))

    # 4. Content Area
    [int]$contentHeight = [math]::Max(4, $canvas.AvailableContentRows - 5)
    [int]$leftColWidth = $canvas.LeftPaneWidth
    [int]$rightColWidth = $canvas.RightPaneWidth
    $isWide = $canvas.IsWide

    $selSection = if ($g.SelectedSectionIndex -lt $sections.Count) { $sections[$g.SelectedSectionIndex] } else { $sections[0] }

    for ($i = 0; $i -lt $sections.Count -and $i -lt $contentHeight; $i++) {
        $s = $sections[$i]
        $isSel = ($i -eq $g.SelectedSectionIndex)
        $cursor = if ($isSel) { "> " } else { "  " }
        $cursorCol = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::DarkGray }
        $titleCol = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::White }

        $sRead = if ($g.Progress.CompletedSections["$($selTopic.Id):$($s.Id)"]) { "[x]" } else { "[ ]" }
        $sCol = if ($sRead -eq "[x]") { [ConsoleColor]::Green } else { [ConsoleColor]::DarkGray }
        $sBadgeCol = Get-WorkCtlBadgeColor $s.Status
        $sBadgeText = if ($s.Status) { "[$($s.Status)]" } else { "[AVAILABLE]" }

        $leftSegs = New-Object System.Collections.Generic.List[object]
        $leftSegs.Add((New-UiSegment $margin DarkGray))
        $leftSegs.Add((New-UiSegment $cursor $cursorCol))
        $leftSegs.Add((New-UiSegment ("{0} {1}. " -f $sRead, ($i + 1)) $sCol))
        $leftSegs.Add((New-UiSegment ("{0,-30}" -f $s.Title) $titleCol))
        $leftSegs.Add((New-UiSegment (" " * 2) DarkGray))
        $leftSegs.Add((New-UiSegment ("{0,-12}" -f $sBadgeText) $sBadgeCol))

        if ($isWide) {
            $leftSegs.Add((New-UiSegment (" " * $canvas.PaneGap) DarkGray))

            if ($i -eq 0) {
                $leftSegs.Add((New-UiSegment "SECTION" Gray))
            } elseif ($i -eq 1) {
                $leftSegs.Add((New-UiSegment $selSection.Title Cyan))
            } elseif ($i -eq 2) {
                $rawContent = if ($selSection.DynamicProvider) { & $selSection.DynamicProvider } else { $selSection.Content }
                $lines = Split-WorkCtlText -Text $rawContent -MaxWidth ($rightColWidth - 4)
                $firstLine = if ($lines.Count -gt 0) { $lines[0] } else { "" }
                $leftSegs.Add((New-UiSegment $firstLine Gray))
            } elseif ($i -eq 4) {
                $leftSegs.Add((New-UiSegment "Enter  Read Section" DarkCyan))
            }
        }

        $f.Add((New-UiLine $leftSegs.ToArray()))
    }

    # Pad lines
    [int]$targetRows = [math]::Max(0, [int]($canvas.Height - 3))
    for ($pad = $f.Count; $pad -lt $targetRows; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    # 5. Pinned Canonical Footer
    $f.Add((New-WorkCtlSeparatorLine))
    $f.Add((New-WorkCtlFooter `
        -Actions @("Move", "Read", "Catalog", "Search", "Help") `
        -RightText ("Section {0}/{1}" -f ($g.SelectedSectionIndex + 1), $sections.Count) `
        -Width $canvas.Width
    ))

    return $f.ToArray()
}

function New-GuideSectionReaderFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    $canvas = Get-WorkCtlCanvas
    $margin = $canvas.Margin
    $g = $State.GuideState

    $topic = $g.Topics[$g.SelectedTopicIndex]
    $sec = $topic.Sections[$g.SelectedSectionIndex]

    # Auto-mark section as completed
    Set-WorkCtlGuideSectionCompleted $topic.Id $sec.Id

    # 1. Canonical Header & Separator
    $f.Add((New-WorkCtlHeaderLine @("GUIDE", $topic.Title.ToUpperInvariant(), $sec.Title.ToUpperInvariant())))
    $f.Add((New-WorkCtlSeparatorLine))

    # 2. Section Tabs Indicator
    $tabSegs = New-Object System.Collections.Generic.List[object]
    $tabSegs.Add((New-UiSegment $margin DarkGray))
    $tabSegs.Add((New-UiSegment "SECTIONS: " Gray))
    for ($si = 0; $si -lt $topic.Sections.Count; $si++) {
        $isCurr = ($si -eq $g.SelectedSectionIndex)
        $tabTitle = "$($si + 1). $($topic.Sections[$si].Title)"
        $tabCol = if ($isCurr) { [ConsoleColor]::Cyan } else { [ConsoleColor]::DarkGray }
        $prefix = if ($isCurr) { "[" } else { " " }
        $suffix = if ($isCurr) { "] " } else { "  " }
        $tabSegs.Add((New-UiSegment "$prefix$tabTitle$suffix" $tabCol))
    }
    $f.Add((New-UiLine $tabSegs))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 3. Content Text Lines (Wrapped via Split-WorkCtlText)
    [int]$contentWidth = [math]::Max(20, $canvas.UsableContentWidth - 4)
    $rawContent = if ($sec.DynamicProvider) { & $sec.DynamicProvider } else { $sec.Content }
    $contentLines = Split-WorkCtlText -Text $rawContent -MaxWidth $contentWidth

    $displayLines = New-Object System.Collections.Generic.List[object]
    foreach ($cl in $contentLines) {
        $displayLines.Add(@{ Text = $cl; Type = "Content" })
    }

    if ($sec.Syntax) {
        $displayLines.Add(@{ Text = ""; Type = "Blank" })
        $displayLines.Add(@{ Text = "SYNTAX & USAGE:"; Type = "Heading" })
        $displayLines.Add(@{ Text = "  " + $sec.Syntax; Type = "Syntax" })
    }

    if ($sec.Example) {
        $displayLines.Add(@{ Text = ""; Type = "Blank" })
        $runText = if ($sec.ExampleRisk -eq "Safe") { "RUNNABLE EXAMPLE: Press [R] to execute -> " + $sec.Example } else { "[MUTATING EXAMPLE - EXECUTION BLOCKED FOR SAFETY] " + $sec.Example }
        $displayLines.Add(@{ Text = $runText; Type = "Example" })
    }

    if ($g.LastExampleOutput -and $g.LastExampleCommand -eq $sec.Example) {
        $displayLines.Add(@{ Text = ""; Type = "Blank" })
        $displayLines.Add(@{ Text = "=== LIVE WORKSTATION OUTPUT ==="; Type = "OutputHeader" })
        foreach ($outLine in $g.LastExampleOutput) {
            $displayLines.Add(@{ Text = "  " + $outLine; Type = "Output" })
        }
    }

    # Scrolling bounds
    [int]$visibleRows = [math]::Max(4, $canvas.AvailableContentRows - 5)
    [int]$totalLines = $displayLines.Count
    [int]$maxScroll = [math]::Max(0, $totalLines - $visibleRows)
    $g.ScrollOffset = [math]::Max(0, [math]::Min($maxScroll, $g.ScrollOffset))

    # Render visible slice
    for ($row = 0; $row -lt $visibleRows; $row++) {
        $lineIdx = $g.ScrollOffset + $row
        if ($lineIdx -lt $totalLines) {
            $item = $displayLines[$lineIdx]
            $txt = $item.Text

            $segs = New-Object System.Collections.Generic.List[object]
            $segs.Add((New-UiSegment $margin DarkGray))
            $segs.Add((New-UiSegment "  " DarkGray))

            if ($item.Type -eq "Heading") {
                $segs.Add((New-UiSegment $txt Yellow))
            } elseif ($item.Type -eq "Syntax") {
                $segs.Add((New-UiSegment $txt Cyan))
            } elseif ($item.Type -eq "Example") {
                $eCol = if ($txt.Contains("BLOCKED")) { [ConsoleColor]::DarkYellow } else { [ConsoleColor]::Green }
                $segs.Add((New-UiSegment $txt $eCol))
            } elseif ($item.Type -eq "OutputHeader") {
                $segs.Add((New-UiSegment $txt Magenta))
            } elseif ($item.Type -eq "Output") {
                $segs.Add((New-UiSegment $txt White))
            } else {
                if ($txt -match "^\s*\[TIP\]") {
                    $segs.Add((New-UiSegment $txt Green))
                } elseif ($txt -match "^\s*\[NOTE\]") {
                    $segs.Add((New-UiSegment $txt Cyan))
                } elseif ($txt -match "^\s*\[CAUTION\]|^\s*\[WARNING\]") {
                    $segs.Add((New-UiSegment $txt Red))
                } elseif ($txt -match "^\s*\[IMPORTANT\]") {
                    $segs.Add((New-UiSegment $txt Yellow))
                } elseif ($txt -match "^\s*===|^\s*---") {
                    $segs.Add((New-UiSegment $txt DarkCyan))
                } elseif ($txt -match "^\s*\*") {
                    $segs.Add((New-UiSegment $txt White))
                } else {
                    $segs.Add((New-UiSegment $txt Gray))
                }
            }

            $f.Add((New-UiLine $segs))
        } else {
            $f.Add((New-UiLine @((New-UiSegment ""))))
        }
    }

    # Pad remaining lines
    [int]$targetRows = [math]::Max(0, [int]($canvas.Height - 3))
    for ($pad = $f.Count; $pad -lt $targetRows; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    # 4. Pinned Canonical Footer
    $f.Add((New-WorkCtlSeparatorLine))
    $f.Add((New-WorkCtlFooter `
        -Actions @("Scroll", "Page", "Section", "Topic", "Help") `
        -RightText ("Line {0}/{1}" -f ($g.ScrollOffset + 1), [math]::Max(1, $totalLines)) `
        -Width $canvas.Width
    ))

    return $f.ToArray()
}

function New-GuideSearchFrame($State) {
    $f = New-Object System.Collections.Generic.List[object]
    $canvas = Get-WorkCtlCanvas
    $margin = $canvas.Margin
    $g = $State.GuideState

    # 1. Canonical Header & Separator
    $f.Add((New-WorkCtlHeaderLine @("GUIDE", "SEARCH DOCUMENTATION")))
    $f.Add((New-WorkCtlSeparatorLine))

    # 2. Search Query Bar
    $f.Add((New-UiLine @(
        (New-UiSegment $margin DarkGray),
        (New-UiSegment "SEARCH: " Yellow),
        (New-UiSegment $g.SearchQuery White),
        (New-UiSegment "_" Cyan),
        (New-UiSegment "  (Type to search, [ENTER] to open section, [ESC] to cancel)" DarkGray)
    )))
    $f.Add((New-UiLine @((New-UiSegment ""))))

    # 3. Search Results List
    [int]$contentHeight = [math]::Max(5, $canvas.AvailableContentRows - 5)
    $results = $g.SearchResults

    if ($results -and $results.Count -gt 0) {
        for ($i = 0; $i -lt $results.Count -and $i -lt $contentHeight; $i++) {
            $r = $results[$i]
            $isSel = ($i -eq $g.SelectedSearchIndex)
            $cursor = if ($isSel) { "> " } else { "  " }
            $cursorCol = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::DarkGray }
            $titleCol = if ($isSel) { [ConsoleColor]::Cyan } else { [ConsoleColor]::White }
            $badgeCol = Get-WorkCtlBadgeColor $r.Status

            $lineSegs = New-Object System.Collections.Generic.List[object]
            $lineSegs.Add((New-UiSegment $margin DarkGray))
            $lineSegs.Add((New-UiSegment "$cursor$($r.TopicTitle) > " $cursorCol))
            $lineSegs.Add((New-UiSegment $r.SectionTitle $titleCol))
            if ($r.Status) {
                $lineSegs.Add((New-UiSegment " [$($r.Status)]" $badgeCol))
            }
            if ($r.Snippet) {
                $lineSegs.Add((New-UiSegment " : $($r.Snippet)" Gray))
            }

            $f.Add((New-UiLine $lineSegs))
        }
    } else {
        $f.Add((New-UiLine @(
            (New-UiSegment $margin DarkGray),
            (New-UiSegment $(if ($g.SearchQuery.Length -gt 0) { "  No matching sections found for '$($g.SearchQuery)'." } else { "  Type keywords to search all guide chapters and commands." }) Gray)
        )))
    }

    # Pad remaining lines
    [int]$targetRows = [math]::Max(0, [int]($canvas.Height - 3))
    for ($pad = $f.Count; $pad -lt $targetRows; $pad++) {
        $f.Add((New-UiLine @((New-UiSegment ""))))
    }

    # 4. Pinned Canonical Footer
    $f.Add((New-WorkCtlSeparatorLine))
    $resCount = if ($results) { $results.Count } else { 0 }
    $f.Add((New-WorkCtlFooter `
        -Actions @("Move", "Open", "Back", "Help") `
        -RightText ("{0} results" -f $resCount) `
        -Width $canvas.Width
    ))

    return $f.ToArray()
}

function Step-GuideSelection($State, $Direction, $PageSize = 10) {
    $g = $State.GuideState
    if (!$g) { return }

    if ($g.ViewMode -eq "Topics") {
        [int]$maxIdx = [math]::Max(0, $g.Topics.Count - 1)
        switch ($Direction) {
            "Up"       { $g.SelectedTopicIndex = [math]::Max(0, $g.SelectedTopicIndex - 1) }
            "Down"     { $g.SelectedTopicIndex = [math]::Min($maxIdx, $g.SelectedTopicIndex + 1) }
            "PageUp"   { $g.SelectedTopicIndex = [math]::Max(0, $g.SelectedTopicIndex - $PageSize) }
            "PageDown" { $g.SelectedTopicIndex = [math]::Min($maxIdx, $g.SelectedTopicIndex + $PageSize) }
            "Home"     { $g.SelectedTopicIndex = 0 }
            "End"      { $g.SelectedTopicIndex = $maxIdx }
        }
        $g.SelectedSectionIndex = 0
        $g.ScrollOffset = 0
        $g.Dirty = $true
    } elseif ($g.ViewMode -eq "Topic") {
        $selTopic = $g.Topics[$g.SelectedTopicIndex]
        [int]$maxIdx = [math]::Max(0, $selTopic.Sections.Count - 1)
        switch ($Direction) {
            "Up"       { $g.SelectedSectionIndex = [math]::Max(0, $g.SelectedSectionIndex - 1) }
            "Down"     { $g.SelectedSectionIndex = [math]::Min($maxIdx, $g.SelectedSectionIndex + 1) }
            "PageUp"   { $g.SelectedSectionIndex = [math]::Max(0, $g.SelectedSectionIndex - $PageSize) }
            "PageDown" { $g.SelectedSectionIndex = [math]::Min($maxIdx, $g.SelectedSectionIndex + $PageSize) }
            "Home"     { $g.SelectedSectionIndex = 0 }
            "End"      { $g.SelectedSectionIndex = $maxIdx }
        }
        $g.ScrollOffset = 0
        $g.Dirty = $true
    } elseif ($g.ViewMode -eq "Search") {
        [int]$maxIdx = [math]::Max(0, (if ($g.SearchResults) { $g.SearchResults.Count - 1 } else { 0 }))
        switch ($Direction) {
            "Up"       { $g.SelectedSearchIndex = [math]::Max(0, $g.SelectedSearchIndex - 1) }
            "Down"     { $g.SelectedSearchIndex = [math]::Min($maxIdx, $g.SelectedSearchIndex + 1) }
            "PageUp"   { $g.SelectedSearchIndex = [math]::Max(0, $g.SelectedSearchIndex - $PageSize) }
            "PageDown" { $g.SelectedSearchIndex = [math]::Min($maxIdx, $g.SelectedSearchIndex + $PageSize) }
            "Home"     { $g.SelectedSearchIndex = 0 }
            "End"      { $g.SelectedSearchIndex = $maxIdx }
        }
        $g.Dirty = $true
    } elseif ($g.ViewMode -eq "Section") {
        switch ($Direction) {
            "Up"       { $g.ScrollOffset = [math]::Max(0, $g.ScrollOffset - 1) }
            "Down"     { $g.ScrollOffset = $g.ScrollOffset + 1 }
            "PageUp"   { $g.ScrollOffset = [math]::Max(0, $g.ScrollOffset - 8) }
            "PageDown" { $g.ScrollOffset = $g.ScrollOffset + 8 }
            "Home"     { $g.ScrollOffset = 0 }
        }
        $g.Dirty = $true
    }
}

function Handle-WorkCtlGuideKey($State, $Key) {
    $g = $State.GuideState
    if (!$g) {
        $State.GuideState = Initialize-WorkCtlGuideState
        $g = $State.GuideState
    }

    $k = $Key.Key
    $c = $Key.KeyChar

    # Search Mode Key Routing
    if ($g.ViewMode -eq "Search") {
        if ($k -eq [ConsoleKey]::Escape) {
            $g.ViewMode = if ($g.PreviousViewMode) { $g.PreviousViewMode } else { "Topics" }
            $g.Dirty = $true
            return
        }
        if ($k -eq [ConsoleKey]::Enter) {
            if ($g.SearchResults -and $g.SearchResults.Count -gt 0 -and $g.SelectedSearchIndex -lt $g.SearchResults.Count) {
                $sel = $g.SearchResults[$g.SelectedSearchIndex]
                for ($ti = 0; $ti -lt $g.Topics.Count; $ti++) {
                    if ($g.Topics[$ti].Id -eq $sel.TopicId) {
                        $g.SelectedTopicIndex = $ti
                        $g.SelectedSectionIndex = $sel.SectionIndex
                        $g.PreviousViewMode = "Topics"
                        $g.ViewMode = "Section"
                        $g.ScrollOffset = 0
                        $g.Dirty = $true
                        break
                    }
                }
            }
            return
        }
        if ($k -eq [ConsoleKey]::UpArrow) {
            Step-GuideSelection $State "Up"
            return
        }
        if ($k -eq [ConsoleKey]::DownArrow) {
            Step-GuideSelection $State "Down"
            return
        }
        if ($k -eq [ConsoleKey]::Backspace) {
            if ($g.SearchQuery.Length -gt 0) {
                $g.SearchQuery = $g.SearchQuery.Substring(0, $g.SearchQuery.Length - 1)
                $g.SearchResults = Search-WorkCtlGuide $g.SearchQuery
                $g.SelectedSearchIndex = 0
                $g.Dirty = $true
            }
            return
        }
        if (![char]::IsControl($c)) {
            $g.SearchQuery += [string]$c
            $g.SearchResults = Search-WorkCtlGuide $g.SearchQuery
            $g.SelectedSearchIndex = 0
            $g.Dirty = $true
            return
        }
        return
    }

    # Reader (Section) View Key Routing
    if ($g.ViewMode -eq "Section") {
        if ($k -eq [ConsoleKey]::Escape -or $k -eq [ConsoleKey]::B) {
            $g.ViewMode = if ($g.PreviousViewMode) { $g.PreviousViewMode } else { "Topics" }
            $g.Dirty = $true
            return
        }
        if ($k -eq [ConsoleKey]::LeftArrow) {
            if ($g.SelectedSectionIndex -gt 0) {
                $g.SelectedSectionIndex--
                $g.ScrollOffset = 0
                $g.Dirty = $true
            }
            return
        }
        if ($k -eq [ConsoleKey]::RightArrow -or $k -eq [ConsoleKey]::Tab) {
            $topic = $g.Topics[$g.SelectedTopicIndex]
            if ($g.SelectedSectionIndex -lt ($topic.Sections.Count - 1)) {
                $g.SelectedSectionIndex++
                $g.ScrollOffset = 0
                $g.Dirty = $true
            }
            return
        }
        if ($k -eq [ConsoleKey]::UpArrow) {
            Step-GuideSelection $State "Up"
            return
        }
        if ($k -eq [ConsoleKey]::DownArrow) {
            Step-GuideSelection $State "Down"
            return
        }
        if ($k -eq [ConsoleKey]::PageUp) {
            Step-GuideSelection $State "PageUp"
            return
        }
        if ($k -eq [ConsoleKey]::PageDown) {
            Step-GuideSelection $State "PageDown"
            return
        }
        if ($k -eq [ConsoleKey]::Home) {
            Step-GuideSelection $State "Home"
            return
        }
        if ($k -eq [ConsoleKey]::R) {
            Invoke-WorkCtlGuideExample $State
            return
        }
        if ($c -eq '/') {
            $g.PreviousViewMode = $g.ViewMode
            $g.ViewMode = "Search"
            $g.SearchQuery = ""
            $g.SearchResults = @()
            $g.SelectedSearchIndex = 0
            $g.Dirty = $true
            return
        }
        return
    }

    # Topic View Key Routing
    if ($g.ViewMode -eq "Topic") {
        if ($k -eq [ConsoleKey]::Escape -or $k -eq [ConsoleKey]::B) {
            $g.ViewMode = "Topics"
            $g.Dirty = $true
            return
        }
        if ($k -eq [ConsoleKey]::Enter) {
            $g.PreviousViewMode = "Topic"
            $g.ViewMode = "Section"
            $g.ScrollOffset = 0
            $g.Dirty = $true
            return
        }
        if ($k -eq [ConsoleKey]::UpArrow) {
            Step-GuideSelection $State "Up"
            return
        }
        if ($k -eq [ConsoleKey]::DownArrow) {
            Step-GuideSelection $State "Down"
            return
        }
        if ($k -eq [ConsoleKey]::PageUp) {
            Step-GuideSelection $State "PageUp"
            return
        }
        if ($k -eq [ConsoleKey]::PageDown) {
            Step-GuideSelection $State "PageDown"
            return
        }
        if ($k -eq [ConsoleKey]::Home) {
            Step-GuideSelection $State "Home"
            return
        }
        if ($k -eq [ConsoleKey]::End) {
            Step-GuideSelection $State "End"
            return
        }
        if ($c -eq '/') {
            $g.PreviousViewMode = $g.ViewMode
            $g.ViewMode = "Search"
            $g.SearchQuery = ""
            $g.SearchResults = @()
            $g.SelectedSearchIndex = 0
            $g.Dirty = $true
            return
        }
        return
    }

    # Topics (Catalog) View Key Routing
    if ($k -eq [ConsoleKey]::Escape -or $k -eq [ConsoleKey]::B) {
        $prev = if ($g.PreviousScreen -and $g.PreviousScreen -ne "shell-guide") { $g.PreviousScreen } else { "shell-home" }
        $State.Screen = $prev
        $State.Dirty = $true
        return
    }
    if ($k -eq [ConsoleKey]::Enter) {
        $g.PreviousViewMode = "Topics"
        $g.ViewMode = "Section"
        $g.SelectedSectionIndex = 0
        $g.ScrollOffset = 0
        $g.Dirty = $true
        return
    }
    if ($k -eq [ConsoleKey]::UpArrow) {
        Step-GuideSelection $State "Up"
        return
    }
    if ($k -eq [ConsoleKey]::DownArrow) {
        Step-GuideSelection $State "Down"
        return
    }
    if ($k -eq [ConsoleKey]::PageUp) {
        Step-GuideSelection $State "PageUp"
        return
    }
    if ($k -eq [ConsoleKey]::PageDown) {
        Step-GuideSelection $State "PageDown"
        return
    }
    if ($k -eq [ConsoleKey]::Home) {
        Step-GuideSelection $State "Home"
        return
    }
    if ($k -eq [ConsoleKey]::End) {
        Step-GuideSelection $State "End"
        return
    }
    if ($c -eq '/') {
        $g.PreviousViewMode = "Topics"
        $g.ViewMode = "Search"
        $g.SearchQuery = ""
        $g.SearchResults = @()
        $g.SelectedSearchIndex = 0
        $g.Dirty = $true
        return
    }

    return
}


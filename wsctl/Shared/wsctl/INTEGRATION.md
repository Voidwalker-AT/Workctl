# WorkCtl ↔ WSCTL Integration Contract

> **Target Audience**: WorkCtl developers, automated tooling agents, system maintainers  
> **Status**: APPROVED  
> **Last Verified**: 2026-09-22  

---

## 1. System Separation & Boundary Definition

| Metric / Dimension | WorkCtl (Host System) | WSCTL (Workspace Platform) |
| :--- | :--- | :--- |
| **Scope** | Entire Windows workstation (`LAPTOP-UE0PTA5H`) | Dedicated development drive `E:\Workspace\` |
| **Domain** | Hardware, Storage, Network, Services, Processes, Media, Diagnostics | Projects, Virtual Environments, Toolchains, AI Models, Git Repos |
| **Invocation** | Global Scoop shim: `workctl` (`C:\Users\hp\scoop\shims\workctl.cmd`) | Global Scoop shim: `wsctl` (`C:\Users\hp\scoop\shims\wsctl.cmd` -> `E:\Workspace\wsctl.ps1`) |
| **GUI Frontend** | WorkCtl Main Menu / Terminal HUD | WSCTL Panel (`wsctl panel`, Tkinter/ttk) |
| **Data Artifacts** | Host telemetry, event logs, service registry | `Shared/artifacts/` (`doctor-latest.json`, `git-status-latest.json`, etc.) |

---

## 2. Integration Principle

1. **Non-Destructive Coexistence**:
   - `WSCTL` must never shadow, alias, or overwrite `WorkCtl`.
   - `WorkCtl` retains ownership of the `workctl` command.
   - `WSCTL` owns the `wsctl` command.
2. **WorkCtl "Development" Subsystem**:
   - WorkCtl features a **Development** menu. When the user navigates to Development in WorkCtl, WorkCtl can seamlessly invoke or embed `WSCTL` without reimplementing workspace logic.

---

## 3. Communication Interfaces

### Interface A: Programmatic CLI Delegation
WorkCtl can invoke WSCTL globally or via direct script fallback:

```powershell
# Preferred global invocation:
wsctl panel                 # Open graphical control center
wsctl doctor -Json          # Retrieve health diagnostics in JSON
wsctl projects -Json        # List registered projects in JSON
wsctl git --dirty -Json     # Inspect dirty repositories in JSON
wsctl storage -Json         # Inspect workspace storage in JSON

# Fallback direct script invocation (if PATH unavailable):
pwsh -NoProfile -ExecutionPolicy Bypass -File E:\Workspace\wsctl.ps1 panel
pwsh -NoProfile -ExecutionPolicy Bypass -File E:\Workspace\wsctl.ps1 doctor -Json
pwsh -NoProfile -ExecutionPolicy Bypass -File E:\Workspace\wsctl.ps1 projects -Json
```

### Interface B: Shared Static Snapshots
For zero-overhead, non-blocking telemetry inside WorkCtl, WorkCtl can read pre-computed JSON snapshots from `E:\Workspace\Shared\artifacts\`:

| Snapshot File | Description | Key Fields |
| :--- | :--- | :--- |
| `Shared/artifacts/doctor-latest.json` | Latest 38-point health check | `status`, `summary.okCount`, `summary.errorCount`, `checks[]` |
| `Shared/artifacts/git-status-latest.json` | Workspace-wide Git status | `summary.totalRepositories`, `summary.dirtyRepositories`, `repositories[]` |
| `Shared/artifacts/storage-latest.json` | Disk usage and top folders | `totalWorkspaceSize`, `topLevel[]` |

---

## 4. WorkCtl Implementation Blueprint (PowerShell Snippet)

Inside WorkCtl's Development module (`workctl-dev.ps1`):

```powershell
function Invoke-WorkCtlWorkspace {
    param([string]$SubCommand = "panel")
    
    # 1. Try global command first
    if (Get-Command wsctl -ErrorAction SilentlyContinue) {
        switch ($SubCommand) {
            "panel"   { Start-Process wsctl -ArgumentList "panel" }
            "doctor"  { & wsctl doctor }
            "summary" {
                $docPath = "E:\Workspace\Shared\artifacts\doctor-latest.json"
                if (Test-Path $docPath) { Get-Content $docPath -Raw | ConvertFrom-Json }
            }
        }
        return
    }

    # 2. Fallback to direct script path
    $wsctlPath = "E:\Workspace\wsctl.ps1"
    if (Test-Path $wsctlPath) {
        switch ($SubCommand) {
            "panel"   { Start-Process pwsh -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$wsctlPath`"", "panel" -WorkingDirectory "E:\Workspace" }
            "doctor"  { & pwsh -NoProfile -ExecutionPolicy Bypass -File $wsctlPath doctor }
            "summary" {
                $docPath = "E:\Workspace\Shared\artifacts\doctor-latest.json"
                if (Test-Path $docPath) { Get-Content $docPath -Raw | ConvertFrom-Json }
            }
        }
    }
}
```

---

## 5. Security & Isolation Assurances

- **Zero-Secret Guarantee**: WSCTL never exposes API keys, credentials, or personal tokens in CLI outputs or snapshot artifacts.
- **Read-Only Inspection**: All status, storage, git, and doctor commands are strictly non-destructive.
- **Environment Containment**: Project command execution runs within each project's isolated environment directory.

# WSCTL — Workspace Control Subsystem

> **Scope**: Frontend control and management system for `E:\Workspace`  
> **Status**: PRODUCTION READY  
> **Version**: 1.0.0  
> **Last Verified**: 2026-09-22  

---

## 1. Overview

**WSCTL (Workspace Control)** is the primary frontend control interface for the `E:\Workspace` local engineering platform. It provides unified, non-destructive management of:

- **26 Cataloged Projects** across Active, Academic, Tools, References, Experiments, Completed, and Shared layers.
- **Isolated Virtual Environments** (`.venv`, `venv`, `node_modules`, `.net sdk`) without cross-contamination.
- **Shared Package Caches** (Astral UV on SSD, npm, Go, Pip) and **Centralized AI Models** (`E:\AI_Models\`).
- **37-Point Platform Health Diagnostics** (CUDA, toolchains, package managers, path integrity).
- **64 Git Repositories** with read-only tracking reference auditing.
- **Graphical Control Center** (`WSCTL Panel`) powered by Python Tkinter/ttk.

> [!IMPORTANT]
> **WSCTL vs. WorkCtl Architectural Boundary**:  
> `WorkCtl` (`C:\Users\hp\scoop\shims\workctl.cmd`) manages the **entire workstation** (Hardware, Windows Services, Network, Processes, Media, Storage).  
> `WSCTL` (`E:\Workspace\wsctl.ps1`) manages the **development platform** (`E:\Workspace`).  
> They are strictly decoupled and never collide. See [INTEGRATION.md](file:///E:/Workspace/Shared/wsctl/INTEGRATION.md) for the WorkCtl integration contract.

---

## 2. Platform Architecture

```
E:\Workspace\
├── wsctl.ps1                     <-- Primary CLI entry point
├── workspace.json                <-- Platform manifest (26 projects, commands, runtimes)
├── AGENTS.md                     <-- Workspace operating contract (nearest rule precedence)
├── Workspace.code-workspace      <-- Curated multi-root VS Code configuration
│
└── Shared\
    ├── wsctl\
    │   ├── panel.py              <-- Graphical Control Panel (Tkinter/ttk)
    │   ├── README.md             <-- This manual
    │   └── INTEGRATION.md        <-- WorkCtl integration specifications
    │
    ├── artifacts\
    │   ├── doctor-latest.json    <-- Cached diagnostic snapshot
    │   ├── git-status-latest.json<-- Cached Git observability snapshot
    │   └── storage-latest.json   <-- Cached disk usage breakdown
    │
    ├── configs\
    │   ├── toolchains.json       <-- Toolchain definitions & paths
    │   ├── workspace-paths.json  <-- Canonical drive abstractions
    │   └── workspace-schema.json <-- JSON Schema validation
    │
    └── scripts\
        ├── workspace-doctor.ps1     <-- 37-point read-only platform auditor
        ├── workspace-projects.ps1   <-- Project catalog & command runner
        ├── workspace-git-status.ps1 <-- 64-repo tracking ref scanner
        ├── workspace-storage.ps1    <-- Storage & cache observer
        └── bootstrap-workspace.ps1  <-- Non-destructive workspace validator
```

---

## 3. CLI Command Reference

`wsctl` is exposed globally across all directories in PowerShell, Windows Terminal, and CMD via `C:\Users\hp\scoop\shims\wsctl.cmd`.

### Basic Usage
```powershell
# Display formatted workspace summary header
wsctl

# Display help and command usage
wsctl help

# Display platform architecture & paths
wsctl info
wsctl info -Json
```

### Health & Diagnostics
```powershell
# Run full 38-point platform diagnostic
wsctl doctor

# Run with detailed check messages
wsctl doctor -Detailed

# Retrieve diagnostic results in machine-readable JSON
wsctl doctor -Json
```

### Project Catalog & Task Execution
```powershell
# List all 26 cataloged projects
wsctl projects

# Filter by category or tag
wsctl projects -Category academic
wsctl projects -Tag pytorch

# Inspect a specific project manifest and registered commands
wsctl project dl-exp1
wsctl project dl-exp1 -Json

# Run a project command with execution preview and risk check
wsctl run dl-exp1 dashboard     # Launch interactive GUI
wsctl run dl-exp1 verify        # Run test-set evaluation
wsctl run dl-exp1 train         # Train neural network (5 epochs)
wsctl run sem5-yolo inspect     # Check CUDA in YOLO venv
wsctl run shared-ds-base verify # Check imports in ds-base
```

### Git Observability
```powershell
# Scan all 64 repositories (read-only, local tracking refs)
wsctl git

# Filter to dirty repositories only
wsctl git --dirty

# Export git status snapshot to JSON
wsctl git -Json
```

### Storage & Caches
```powershell
# Display workspace directory disk usage
wsctl storage

# Inspect centralized package caches (UV, Pip, Go, npm) and AI models (Ollama, HF)
wsctl storage --caches

# Inspect discovered project virtual environments
wsctl storage --envs

# Show top 15 largest workspace items
wsctl storage -Top 15
```

### Graphical Control Center
```powershell
# Launch the WSCTL Panel from any directory
wsctl panel
wsctl ui       # Convenient alias
```

### Advanced / Direct Script Invocation
Direct PowerShell script invocation remains fully supported if PATH resolution is ever unavailable:
```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File E:\Workspace\wsctl.ps1 [command] [args]
```

---

## 4. WSCTL Panel (Workstation-Console GUI)

The **WSCTL Panel** (`Shared\wsctl\panel.py`) is a zero-dependency, lightweight workstation-console control center implemented in Python standard library `tkinter` and `ttk`. Its aesthetic, ergonomics, and keyboard-first workflow are directly aligned with **WorkCtl** (`E:\TOOLS\WorkstationControl`).

Detailed design specifications and architectural contracts are documented in [DESIGN.md](file:///E:/Workspace/Shared/wsctl/DESIGN.md).

### Visual Language & Ergonomics:
- **Design Tokens**: Console near-black canvas (`#0c0c0c`), cyan identity accent (`#00f0ff`), 1px structural dividers (`#262626`), monospace typography (`Consolas`), and clean ASCII box drawings.
- **Top Telemetry Strip**: Live key-value strip showing health status, cataloged projects, Git repository clean/dirty ratio, total disk usage, UV cache size, and GPU status.
- **Toast Notification Bar**: Single-line real-time status and shortcut feedback.
- **Split-Pane Projects Explorer**: Left searchable table with category filters (`ALL`, `ACTIVE`, `ACADEMIC`, `TOOLS`, etc.) and right detail card with action launchers and risk-tagged project commands (`[SAFE]`, `[COMPUTE]`).
- **Quick Action Strip**: One-touch access to Quick Slots 1–4, Platform Doctor, Windows Terminal, and VS Code.
- **Pinned Monospace Footer**: Instant keyboard shortcut hints and active view indicator.

### Keyboard Shortcuts Reference:
| Key | Action |
| :--- | :--- |
| `[P]` | Projects Explorer & Action Panel |
| `[E]` | Virtual Environments Inspection |
| `[G]` | Git Observability Table |
| `[S]` | Storage Capacity Breakdown |
| `[T]` | Development Toolchains & Runtimes |
| `[M]` | AI Models & GPU Acceleration |
| `[C]` | Centralized Package Caches |
| `[D]` | Platform Doctor Diagnostics |
| `[I]` | WorkCtl Integration & Governance |
| `[H]` / `[Esc]` | Return to Home Overview |
| `[1]` – `[4]` | Quick Slots 1–4 (`dl-exp1`, `ai-bridge`, `server-nexusnode`, `termux-ai-workstation`) |
| `[/]` | Focus project search entry |
| `[↑]` / `[↓]` or `[j]` / `[k]` | Move row selection in active table |
| `[Enter]` | Open folder in Explorer or inspect project |
| `[?]` | Toggle Help modal cheatsheet |
| `[Q]` | Cleanly quit panel |

### Performance Benchmarks:
- **Cold Startup**: ~214 ms
- **Memory Footprint (RSS)**: ~28.2 MB (vs. ~200+ MB for Electron)
- **Asynchronous Execution**: Audits (`workspace-doctor.ps1`) and external command runners execute non-blockingly via daemon threads, preserving UI responsiveness.


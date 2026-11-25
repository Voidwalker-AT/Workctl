# E:\TOOLS Dependency & Architecture Map

## Overview
The `E:\TOOLS` directory serves as the workstation's dedicated local software, tool, and control substrate. It hosts standalone binaries, hardware control utilities, disk diagnostics, virtual disk mounters, and the central control plane (`WorkstationControl`).

---

## Component Taxonomy & Dependency Relationships

```mermaid
graph TD
    subgraph HostSystem["Windows Workstation Host"]
        PSHost["Windows PowerShell 5.1 Host"]
        NodeRuntime["Node.js v24.15.0 Runtime"]
        DotNetRuntime[".NET 10.0 Desktop Runtime"]
        WinDrivers["BazisVirtualCDBus Driver"]
    end

    subgraph ETOOLS["E:\\TOOLS Substrate"]
        WorkCtl["WorkstationControl (workctl)"]
        WinDirStat["Diagnostics\\WinDirStat.exe"]
        FanControl["FanControl_267_net_10_0\\FanControl.exe"]
        QBit["qBittorrent\\qbittorrent.exe"]
        Mounter["Mounter\\batchmnt64.exe"]
    end

    subgraph GlobalRuntimes["Global Tools & Agents"]
        Freebuff["Freebuff CLI (0.0.174)"]
        FreebuffBin["~/.config/manicode/freebuff.exe"]
        VSCode["Visual Studio Code"]
        Antigravity["Google Antigravity Agent"]
    end

    PSHost --> WorkCtl
    NodeRuntime --> Freebuff
    Freebuff --> FreebuffBin
    DotNetRuntime --> FanControl
    WinDrivers --> Mounter

    WorkCtl -.->|Interactive Handoff| Freebuff
    WorkCtl -.->|Process Launch| WinDirStat
    WorkCtl -.->|Process Launch| FanControl
    WorkCtl -.->|Process Launch| QBit
    WorkCtl -.->|CLI Mount| Mounter
```

---

## Detailed Component Dependency Specifications

| Component | Physical Path | Runtime Dependency | Network / Ports | Governance Policy |
|---|---|---|---|:---:|
| **WorkCtl** | `E:\TOOLS\WorkstationControl\workctl.ps1` | Windows PowerShell 5.1 | None | `PROTECTED` |
| **WinDirStat** | `E:\TOOLS\Diagnostics\WinDirStat.exe` | Native Win32/x64 | None | `LAUNCH` |
| **FanControl** | `E:\TOOLS\FanControl_267_net_10_0\FanControl.exe` | .NET 10.0 Desktop | Named Pipes (IPC) | `LAUNCH` |
| **qBittorrent** | `E:\TOOLS\qBittorrent\qbittorrent.exe` | Qt6 / C++ | TCP 8080 (optional WebUI) | `LAUNCH` |
| **WinCDEmu Mounter** | `E:\TOOLS\Mounter\batchmnt64.exe` | Native Driver (`bazisvirtualcdbus`) | None | `LAUNCH` |
| **Freebuff** | `C:\Program Files\nodejs\freebuff.ps1` | Node >= 16 + Zig-Bun engine | Cloud LLM Gateway (HTTPS) | `LAUNCH` |

---

## Lifecycle Governance Boundaries
1. **PROTECTED**: WorkCtl itself and Antigravity. WorkCtl never allows stopping, killing, or destabilizing its own supervisor or host process.
2. **MANAGED**: Workloads and services with health probes, start/stop hooks, and port monitoring (e.g. Sonarr, Torlink, MySQL, Redis).
3. **LAUNCH**: Standalone desktop GUIs and on-demand interactive CLIs. WorkCtl initiates process or handles terminal handoff, but leaves execution lifecycle to the operator.
4. **CONFIRM**: Mutating lifecycle operations that require operator acknowledgment before stopping.

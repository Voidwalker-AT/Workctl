# Architectural Decision Record (ADR): WorkCtl State Stabilization, E:\TOOLS Audit & Freebuff Integration

- **Status**: APPROVED & VERIFIED
- **Date**: 2026-09-15
- **Phase**: WCTL-2
- **Author**: Antigravity Machine Control Subsystem
- **Target Workstation**: Windows 11 Pro / PowerShell 5.1 / `E:\TOOLS`

---

## 1. Executive Summary & Context

WorkCtl experienced a critical runtime exception during interactive navigation (`WCTL-UI-STATE-145`):
```
Exception setting "LastAction":
"The property 'LastAction' cannot be found on this object."
at E:\TOOLS\WorkstationControl\modules\shell.ps1:2877 char:21
```
Although WorkCtl's inner recovery boundary caught the fault and rendered the recovery screen without crashing the process, the failure degraded user experience and indicated a lack of formal state schema governance.

Concurrently, a workstation expansion task was requested:
1. Conduct a comprehensive, forensic audit of the entire `E:\TOOLS` directory (binaries, managers, wrappers, runtimes, overlaps).
2. Deep-audit `CodebuffAI/freebuff` (v0.0.174) for local safety, telemetry, daemon footprints, and resource impact.
3. Formulate the correct abstraction for Freebuff inside WorkCtl and integrate it without disturbing existing managed workloads or the VS Agent system.
4. Generalize development and agent management within WorkCtl.
5. Dynamically wire the Guide subsystem to reflect all discovered tools and developer workflows.

All 5 sequential phases (P0 to P4) have been executed, verified, and backed up with complete SHA-256 baseline tracking.

---

## 2. P0: State Schema Runtime Hardening

### 2.1 Root Cause
In `modules\shell.ps1`, `Initialize-ShellAppState` constructed an ad-hoc `[PSCustomObject]` using a hashtable literal (`[PSCustomObject]@{ ... }`). In Windows PowerShell 5.1, `[PSCustomObject]` instances created this way have fixed note properties unless explicitly augmented. When new event handlers or subroutines attempted to write to newly introduced properties (such as `$state.LastAction = $key.Key.ToString()`), PowerShell threw `SetValueInvocationException` because the member did not exist on the object.

### 2.2 Solution Architecture
1. **Schema Definition (`New-WorkCtlShellState`)**:
   Constructed a strict canonical factory defining all 42 required properties initialized to safe defaults, including navigation state, selection indices, command buffers, scroll offsets, modal states, and diagnostic caches.
2. **Schema Validator (`Test-WorkCtlShellState`)**:
   Verifies whether an object conforms to the 42-field contract and reports missing properties.
3. **Safe State Normalizer (`Confirm-WorkCtlShellState`)**:
   Acts as a runtime safety barrier. Prior to entering the event loop or error frame, it inspects the state object and uses `Add-Member -NotePropertyName $prop -NotePropertyValue $default -Force` to backfill any missing member dynamically, preventing `SetValueInvocationException` under all circumstances.
4. **Error Frame Polish**:
   Refactored `New-ShellErrorFrame` to match the exact visual language of the fault recovery screen, displaying actionable remediation cues.

---

## 3. P1: `E:\TOOLS` Ecosystem Audit & Governance

Forensic inspection of `E:\` revealed 5 core tooling directories alongside `WorkstationControl`:
- `E:\TOOLS\WinDirStat`: Portable Win32 disk visualization utility.
- `E:\TOOLS\FanControl`: .NET desktop hardware sensor/fan curve manager.
- `E:\TOOLS\qBittorrent`: High-performance libtorrent media client.
- `E:\TOOLS\Mounter`: WinCDEmu portable ISO virtual drive emulator.
- `E:\TOOLS\WorkstationControl`: The centralized TUI cockpit and management layer.

### Architectural Classification
- **Workloads (`config\workloads.json`)**: Long-running background daemons with TCP listening ports, Windows service bindings, and resident RAM (`mysql`, `docker`, `ollama`, `openclaw`, `omniroute`).
- **Tools (`config\tools.json`)**: On-demand interactive GUI utilities, disk visualizers, hardware control panels, and ephemeral CLI agents (`windirstat`, `fancontrol`, `qbittorrent`, `mounter`, `freebuff`).

`config\tools.json` was augmented with accurate executable paths, categories, descriptions, and process signatures to enable native launch and telemetry from the WorkCtl Tools screen.

---

## 4. P2: Freebuff Deep Audit & Abstraction Model

### 4.1 Upstream & Binary Profile
- **Package**: `freebuff@0.0.174` (npm global wrapper `C:\Users\hp\AppData\Roaming\npm\node_modules\freebuff`).
- **Core Binary**: Self-contained Rust/Node executable located at `C:\Users\hp\.config\manicode\freebuff.exe` (126.3 MB) + `tree-sitter.wasm` (164 KB).
- **Default Model**: `glm-5.3-flash-2026-09-05` (unmetered tier, free community access provided by upstream).
- **Session Limits**: 6 daily 1-hour sessions (Indian/APAC tier).

### 4.2 Resource Footprint & Daemon Analysis
- **Resident Services**: **0**. Freebuff does NOT register a Windows service, scheduled task, or background daemon.
- **Idle RAM**: **0 MB**. When not active in a terminal, no processes reside in memory.
- **Idle Ports**: **0**. Freebuff listens on no TCP or UDP ports.
- **Active Memory**: ~180 MB to 260 MB during interactive generation runs.

### 4.3 Network & Telemetry Governance
- Outbound traffic is restricted to HTTPS calls to `api.manicode.ai` / `api.codebuff.com` for LLM completions.
- No local files outside the designated project root are read or transmitted.
- Ephemeral execution guarantees that closing the CLI immediately frees all resources.

### 4.4 WorkCtl Abstraction Decision
**Decision**: Freebuff is strictly categorized as an **Interactive On-Demand Tool (`LAUNCH`)**, NOT a managed background workload.
- It must NEVER be added to `workloads.json` or started as a background daemon.
- It is integrated via an **Interactive Handoff Primitive** (`Invoke-WorkCtlInteractiveTool`) in `modules\tools.ps1`:
  1. WorkCtl pauses its differential screen rendering engine.
  2. The terminal cursor is unhidden (`[Console]::CursorVisible = $true`).
  3. A clean subshell executes `cmd.exe /c freebuff` within the target project directory.
  4. WorkCtl synchronously waits for the process to terminate.
  5. Upon exit, terminal state is restored, the cursor is hidden, differential cache is invalidated, and WorkCtl redraws seamlessly.

---

## 5. P3: WorkCtl Development Subsystem

To elevate workstation control from raw utilities to development workflow orchestration, a dedicated subsystem was implemented:
- **Module**: `modules\development.ps1`
- **Key Functions**:
  - `Get-WorkCtlProjects`: Discovers local git repositories and development directories under `E:\Workspace` and `E:\TOOLS`. Caches scan results in `runtime\project-discovery.json` for rapid subsequent loads.
  - `Get-WorkCtlAiAgents`: Queries installed AI coding agents (Freebuff, Antigravity, VS Code) and reports their health, binary locations, and execution modes.
  - `Get-WorkCtlRuntimes`: Audits installed language environments (Node.js, Python, Git) and verifies environment paths.
  - `Invoke-WorkCtlLaunchFreebuff`: Launches Freebuff against a selected project directory using the interactive handoff primitive.
- **TUI Integration (`modules\shell.ps1`)**:
  - Added shortcut `[E]` on Home Screen (`New-ShellHomeFrame`) to enter Development & Agents.
  - Added screens: `shell-dev` (Overview), `shell-projects` (Project Navigator), `shell-project-detail` (Project Context & Action Deck), `shell-agents` (Agent Inventory).
  - Registered CLI commands: `dev`, `projects`, `project`, `agents`, `freebuff`.
  - Added full keyboard event handling (`Enter` to inspect/launch, `F` to launch Freebuff, `C` to open in VS Code, `R` to refresh cache, `B`/`Esc` to navigate back).

---

## 6. P4: Guide Subsystem Dynamic Update

`modules\guide.ps1` was updated to provide contextual, interactive documentation:
- Added Topic 11: `development` ("Development & AI Coding Agents").
- Implemented dynamic sections:
  1. `overview`: Overview of workstation dev tools and AI pairing models.
  2. `projects`: Project discovery, cache management, and repository navigation.
  3. `agents`: Available agents (Antigravity architecture vs Freebuff ephemeral assistant).
  4. `freebuff`: Freebuff installation, unmetered GLM-5.3 access, session limits, and handoff mechanics.
  5. `handoff`: Technical explanation of differential renderer suspension and terminal yield.
- Registered dynamic content provider `Get-GuideDynamicDevelopmentContent` to inject real-time runtime versions (Node, Python, Git) and detected agent statuses directly into the Guide cards.
- Screen-to-Guide mapper updated to route `shell-dev*`, `shell-project*`, and `shell-agent*` to the `development` topic when `?` or `guide` is pressed.

---

## 7. Workstation Safety Shields & Governance

The integrity of critical workstation systems was strictly maintained:
1. **Core Workloads Untouched**:
   `mysql`, `docker`, `ollama`, `openclaw`, and `omniroute` were not restarted or interrupted during installation, auditing, or test execution.
2. **Safety Shields Preserved**:
   - `antigravity`: Explicitly blocked from termination (`Policy: EXPLICIT`).
   - `powertoys`: Explicitly blocked from termination (`Policy: EXPLICIT`).
   - `discord`: Requires explicit interactive confirmation modal (`Policy: CONFIRM`).
3. **VS Agent Isolation**:
   No modifications were made to `C:\Users\hp\.agents` or Copilot workspace files.

---

## 8. Verification & Test Metrics

A 5-suite comprehensive regression harness (`scratch\run_all_regressions.ps1`) was executed against the modified codebase:
- **Suite 1: P0 State Schema & Recovery**: 11 / 11 PASSED (9.2s)
- **Suite 2: Tools Subsystem Regression**: 18 / 18 PASSED (19.1s)
- **Suite 3: Guide Subsystem Engine**: 22 / 22 PASSED (2.7s)
- **Suite 4: Development & Freebuff Subsystem**: 13 / 13 PASSED (16.7s)
- **Suite 5: Command Mode & Multi-Viewport Sweeps**: 48 / 48 PASSED (236.8s)
- **Grand Total**: **112 / 112 PASSED (100% Success Rate)**

---

## 9. Rollback Readiness

In the event of an unforeseen regression:
- Pre-change backup directory: `E:\TOOLS\WorkstationControl\backups\pre_freebuff_state_fix_2026-09-14_23-05-22`
- Manifest: `E:\TOOLS\WorkstationControl\audit\WORKCTL_rollback_manifest.json`
- Single-command restoration:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Copy-Item -Path 'E:\TOOLS\WorkstationControl\backups\pre_freebuff_state_fix_2026-09-14_23-05-22\*' -Destination 'E:\TOOLS\WorkstationControl' -Recurse -Force; Remove-Item -Path 'E:\TOOLS\WorkstationControl\modules\development.ps1' -Force -ErrorAction SilentlyContinue"
```

---

## 10. Conclusion

The WorkCtl control plane is now fully stabilized against state schema regressions, equipped with a comprehensive inventory of workstation utilities, enhanced with an ephemeral AI agent handoff mechanism for Freebuff, and documented within the interactive Guide.

**Status Declaration**: `WORKCTL_FREEBUFF_INTEGRATION_READY`

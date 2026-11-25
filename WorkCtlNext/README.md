# WorkCtl Next (Phase 2.1 — Command Shell, Navigation Repair & Task Manager)

> **Status:** Interactive Workstation Command Shell, Task Manager & Structured Agent CLI (`E:\Workspace\Active\WorkCtlNext`).  
> Preserves Phase 1/1.5 alt-screen stability, Read-Only Agent CLI JSON security guarantees, and existing `workctl`, `wsctl`, and `ulvo` installations untouched.

## Build and Run (Exact Commands)

```powershell
# Offline-capable restore from local NuGet cache (only needed once for xUnit test dependencies)
dotnet restore E:\Workspace\Active\WorkCtlNext\WorkCtlNext.slnx --source "$env:USERPROFILE\.nuget\packages"

# Build Release binary (WorkCtlNext itself has zero external NuGet dependencies)
dotnet build E:\Workspace\Active\WorkCtlNext\WorkCtlNext.slnx --no-restore -c Release

# Launch Interactive Phase 2.1 Human Workstation Shell inside Windows Terminal / PowerShell
E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe
# Optional visual flags: --no-anim | --reduced-motion | --no-color | --ascii (or env NO_COLOR=1, WORKCTL_NO_ANIM=1, WORKCTL_ASCII=1)

# Run Read-Only Agent CLI structured JSON queries (valid from any working directory, zero ANSI)
E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe --help
E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe capabilities --json
E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe context --project dl-exp1 --json
E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe ls --path E:\Workspace --json
E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe stat --path E:\Workspace\Active\WorkCtlNext\README.md --json
E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe preview --path E:\Workspace\Active\WorkCtlNext\README.md --limit 25 --json
E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe resolve --path .\src --cwd E:\Workspace\Active\WorkCtlNext --json
E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe tasks --sort mem --limit 10 --json
E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe tasks inspect --pid $PID --json
E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe git --path E:\Workspace --json

# Run full verification suite
dotnet test E:\Workspace\Active\WorkCtlNext\tests\WorkCtlNext.Tests\WorkCtlNext.Tests.csproj -c Release --no-restore --verbosity normal
```

## Phase 2.1 Architecture & Guardrails
- **Command-First Workstation Shell**: Launches directly with the bottom Command Editor focused (`FocusRegion.CommandLine`), visible reverse-video cursor, inline ghost suggestion, `Tab` / `Shift+Tab` completion inside the editor, and a scrollable `[1] Console` Shell Transcript replacing idle whitespace. Region switching uses predictable, non-trapping shortcuts (`Ctrl+N` Navigation Tree, `Ctrl+Tab` / `F6` cycle regions, `Ctrl+L` / `Ctrl+K` / `Esc` return to Command Editor, `Ctrl+Q` / `exit` / `quit` exit cleanly).
- **4-Way Shell Command Execution (`ShellCommandRouter`)**: Cleanly distinguishes **WorkCtl Native** commands (`open`, `tasks`, `kill`, `cd`, `ls`, `:...`), **Captured PowerShell** (`pwsh <cmd>`, `ps1 <cmd>`, `Verb-Noun`, `$var`, external dev tools), **Captured CMD** (`cmd <cmd>`, `ver`, `whoami`, `ipconfig`, `where`), and **Interactive Foreground TTY Handoff** (`!<cmd>`, `fg <cmd>`, `run <cmd>`, bare `pwsh`/`cmd`/`python`/`vim`) using raw command syntax without WorkCtl parser rejection.
- **UTF-8 & Safe Glyph Rendering**: `TerminalSession` saves and configures UTF-8 console code pages (`CP 65001`) on entry and restores them on exit, while automatically falling back to clean 7-bit ASCII glyphs (`v`, `>`, `-`, `+`, `x`) whenever UTF-8 is unavailable or `--ascii` / `WORKCTL_ASCII=1` is set — preventing `?` and missing-glyph tofu boxes.
- **Integrated Windows Task Manager & 10-Step Process Guard (`WindowsTelemetryProvider` + `ProcessTerminationService`)**: Collects live PID, causal Parent PID (rejecting PID-reuse parent links where parent creation timestamp exceeds child creation timestamp), owner SID lookup, CPU%, RAM, threads, executable path, window state, and Windows service associations (`OpenSCManagerW`/`EnumServicesStatusExW`). Supports sorting (`Cpu`, `Memory`, `Pid`, `Name`, `Tree`), causal tree hierarchy, `/` search, split/full inspection, and a human-only 2-step termination workflow (`Step 1` Impact Preview separating Verified/Possible/Unknown + graceful `WM_CLOSE` when windowed -> `Step 2` explicit `KILL <PID>` confirmation with TOCTOU handle revalidation prior to `TerminateProcess`).
- **Filesystem Safety & Agent CLI Isolation**: `FileSystemService` + `ProtectedPathPolicy` enforce Win32 Recycle Bin deletion, junction/reparse safety, NTFS hardlink checks, zero silent overwrite, and strict protected-path blocking (`POLICY_BLOCKED`). Agent CLI remains strictly `ReadOnly`, enabling `tasks` and `tasks inspect` JSON queries while blocking `kill`, `pwsh`, `cmd`, and all mutating actions with exit code `2`.

## Documentation Index
- [`docs/DESIGN_SYSTEM.md`](docs/DESIGN_SYSTEM.md)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/CAPABILITY_CONTRACTS.md`](docs/CAPABILITY_CONTRACTS.md)
- [`docs/AGENT_CLI.md`](docs/AGENT_CLI.md)
- [`docs/MANUAL_TERMINAL_ACCEPTANCE.md`](docs/MANUAL_TERMINAL_ACCEPTANCE.md)

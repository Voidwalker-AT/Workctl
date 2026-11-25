# WorkCtl Next Phase 2.1 — Architecture & Provider Contracts

## 1. Dual-Interface Single-Core Architecture
```text
Human (Windows Terminal / pwsh) ──► TuiApp (Alt-Screen ?1049h/l, CP 65001 UTF-8, 3-Region Shell, DiffRenderer) ─┐
                                                                                                                  ├──► CapabilityDispatcher ──► Shared CapabilityRegistry
AI Coding Agent (CLI / JSON)   ──► AgentCli (stdout JSON, stderr diagnostics, Strict ReadOnly) ───────────────────┘           │
                                                                                                                              ├── WorkspaceSessionContext (shared CWD/proj/history/clipboard/transcript)
                                                                                                                              ├── ShellCommandRouter (Native / pwsh / cmd / Interactive TTY handoff)
                                                                                                                              ├── CommandLineParser + DeterministicCompletionEngine
                                                                                                                              ├── FileSystemService + ProtectedPathPolicy + Win32FsInterop
                                                                                                                              ├── ProcessTerminationService + Win32ProcessInterop (Toolhelp32/SCM/TOCTOU)
                                                                                                                              ├── WindowsMachineProvider & WindowsTelemetryProvider
                                                                                                                              ├── GitProvider (read-only --no-optional-locks)
                                                                                                                              ├── WsctlProvider (no-write wsctl.ps1 CLI + doctor cache check)
                                                                                                                              └── UlvoProvider (fast zero-write ulvo CLI + \\?\ normalization)
```

## 2. Policy & Surface Separation
- `DispatcherPolicyMode.ReadOnly` (default / `AgentCli`): registers `20` `ReadOnly` capabilities (`core`, `windows`, `tasks.inspect`, `wsctl`, `ulvo`, `git`, `fs` read). Any mutating invocation (`fs.*` writes, `tasks.terminate`) fails with exit `2` (`POLICY_BLOCKED`). Shell commands (`pwsh`, `cmd`, `!`, `fg`, `run`) are also blocked on `AgentCli`.
- `DispatcherPolicyMode.InteractivePhase2` (`HumanTui`): adds `5` guarded filesystem mutations and `tasks.terminate`. Requires `CallerSurface.HumanTui`, `Confirmed == true`, protected-target rules (`ProtectedPathPolicy` or `ProcessDetailedInspection.IsProtected`), PID-reuse identity validation (`ProcessIdentityToken`), and for force process termination explicit second confirmation (`KILL <PID>`).
- `WorkspaceSessionContext` holds `ActiveDirectory`, `Transcript`, `Clipboard`, and `Focus` (`FocusRegion.CommandLine` at startup) entirely in managed state without mutating `Environment.CurrentDirectory`.

## 3. Navigation Hierarchy & Honest Deferrals
- **Machine**: `Console` (Shell Transcript + System Summary), `Tasks` (Integrated Process Manager), `Services` (`off`), `Performance`, `Storage`, `Network`
- **Files**: `This PC`, `Quick Access`, `Workspace`, `Downloads`
- **Development**: `Projects`, `Git`, `ULVO`, `Toolchains`
- **Applications**: `Installed` (`off`), `Running`, `Startup` (`off`)
- Navigation tree skips disabled (`off`) items during keyboard cursor traversal and opens an honest `[DEFERRED]` view with zero synthetic data if invoked directly via `:open services` / `open installed` / `open startup`.

## 4. Terminal Lifecycle, Foreground Handoff & `Ctrl+C` Arbitration
- Uses `\u001b[?1049h\u001b[?25l`, UTF-8 CP `65001` (with automatic `--ascii` fallback when unsupported), and synchronized output (`\u001b[?2026h...\u001b[?2026l`).
- Interactive foreground launches (`!cmd`, `fg ...`, `run ...`, bare `pwsh`/`cmd`/`python`/`vim`) invoke `TerminalSession.SuspendForForegroundChild()` (restoring original console modes, code pages, main screen, cursor), wait for child exit inside the real attached console, then call `ResumeAfterForegroundChild()` and append the exit result to the Shell Transcript.
- `Ctrl+C` triggers internal clipboard copy ONLY when `Focus == MainPane` inside the `Files` browser outside modals/inputs (`SetTreatControlCAsInput(true)`). Everywhere else (`CommandLine`, `Console`, `Tasks`, `NavigationTree`, modals), `Ctrl+C` cleanly exits WorkCtl Next with full restoration.

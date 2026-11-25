# WorkCtl Next — Shared Capability Registry & Safety Contracts (Phase 2.1)

All capabilities live in `CapabilityRegistry` and pass through `CapabilityDispatcher.DispatchAsync`.

## Read-Only Capabilities (20 total — enabled on BOTH Agent CLI and Human TUI)
| Capability ID | Provider | Risk | Required Args | CLI Mapping | Bounded Timeout |
| --- | --- | --- | --- | --- | --- |
| `workctl.capabilities` | `core` | `ReadOnly` | none | `capabilities --json` | in-process |
| `workctl.context` | `core` | `ReadOnly` | none | `context [--project <id>] --json` | 10s / 5s |
| `workctl.health` | `core` | `ReadOnly` | none | `health --json` | 10s / 5s concurrent |
| `workctl.suggest` | `core` | `ReadOnly` | none | `suggest [--query <text>] --json` | in-process |
| `windows.machine` | `windows` | `ReadOnly` | none | included in `context`/`health` | in-process (<10 ms) |
| `windows.processes` | `windows` | `ReadOnly` | none | `tasks [--sort <cpu\|mem\|pid\|name>] [--filter <t>] [--limit <n>] --json` / `processes` | in-process |
| `tasks.inspect` | `windows` | `ReadOnly` | `pid` | `tasks inspect --pid <pid> --json` | in-process (Toolhelp32/SCM) |
| `windows.performance` | `windows` | `ReadOnly` | none | TUI live performance view | in-process (80ms prime) |
| `windows.storage` | `windows` | `ReadOnly` | none | `storage --json` | in-process |
| `windows.network` | `windows` | `ReadOnly` | none | `network --json` | in-process |
| `apps.running` | `windows` | `ReadOnly` | none | TUI windowed apps view | in-process |
| `wsctl.projects` | `wsctl` | `ReadOnly` | none | `projects --json` | 10s |
| `wsctl.project.inspect` | `wsctl` | `ReadOnly` | `project` | `context --project <id> --json` | 10s |
| `ulvo.runtimes` | `ulvo` | `ReadOnly` | none | `runtimes [--include-projects] --json` | 5s |
| `ulvo.project.inspect` | `ulvo` | `ReadOnly` | `projectPath` | included in `context --project <id>` | 5s / 15s |
| `git.status` | `git` | `ReadOnly` | none | `git [--path <dir>] --json` | 3s (`--no-optional-locks`) |
| `fs.list` | `fs` | `ReadOnly` | none | `ls [--path <dir>] --json` | in-process (bounded) |
| `fs.inspect` | `fs` | `ReadOnly` | `path` | `stat --path <target> --json` | in-process |
| `fs.preview` | `fs` | `ReadOnly` | `path` | `preview --path <file> --json` | in-process (64KB/120 lines max) |
| `fs.resolve` | `fs` | `ReadOnly` | `path` | `resolve --path <target> --json` | in-process |

## Guarded Human-Only Capabilities (6 total — blocked on Agent CLI & `ReadOnly` mode)
| Capability ID | Provider | Risk | Required Args | Safety Guards |
| --- | --- | --- | --- | --- |
| `fs.mkdir` | `fs` | `Modifying` | `path` + `Confirmed` | `ProtectedPathPolicy`, conflict check (`DESTINATION_EXISTS`), valid filename check |
| `fs.copy` | `fs` | `Modifying` | `sourcePaths` + `Confirmed` | `ProtectedPathPolicy`, zero silent overwrite, self-descendant guard, no junction recursion |
| `fs.move` | `fs` | `Modifying` | `sourcePaths` + `Confirmed` | `ProtectedPathPolicy`, conflict check, cross-volume copy + SHA-256 verify before source delete |
| `fs.rename` | `fs` | `Modifying` | `path` + `newName` + `Confirmed` | `ProtectedPathPolicy`, DOS reserved name rejection, atomic two-step NTFS case-only rename |
| `fs.delete` | `fs` | `Destructive` | `sourcePaths` + `Confirmed` | `ProtectedPathPolicy`, non-recursive reparse/junction unlink, Recycle Bin via `SHFileOperationW` |
| `tasks.terminate` | `windows` | `Destructive` | `pid` + `Confirmed` (+ `ForceTerminate`) | Critical OS/self/ancestor/ULVO/service protection, PID+creationTicks+exe TOCTOU validation, graceful WM_CLOSE vs typed `KILL <PID>` 2nd confirmation |

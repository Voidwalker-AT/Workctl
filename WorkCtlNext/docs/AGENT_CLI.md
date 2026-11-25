# WorkCtl Next — Agent-First Structured CLI Contract (Phase 2.1)

AI coding agents invoke `workctl-next.exe` directly without entering interactive TUI alt-screen. Agent CLI always initializes `CapabilityDispatcher` with `DispatcherPolicyMode.ReadOnly` and `CallerSurface.AgentCli`.

## Commands
- `workctl-next --help`
- `workctl-next capabilities --json`
- `workctl-next context [--project <id>] [--detailed] [--include-env-status] --json`
- `workctl-next projects [--category <cat>] [--tag <tag>] [--detailed] [--limit <n>] --json`
- `workctl-next runtimes [--include-projects] [--limit <n>] --json`
- `workctl-next health --json`
- `workctl-next suggest [--query <text>] [--project <id>] [--limit <n>] --json`
- `workctl-next ls [--path <dir>] [--limit <n>] --json` (alias: `dir`)
- `workctl-next stat --path <target> --json` (alias: `inspect-file`)
- `workctl-next preview --path <file> [--limit <lines>] --json`
- `workctl-next resolve --path <target> [--cwd <dir>] --json`
- `workctl-next tasks [--sort <cpu|mem|pid|name>] [--filter <text>] [--limit <n>] --json`
- `workctl-next tasks inspect --pid <pid> --json`
- `workctl-next processes [--limit <n>] --json`
- `workctl-next storage --json`
- `workctl-next network --json`
- `workctl-next git [--path <dir>] --json`

## Blocked Operations on Agent CLI
- Filesystem mutating verbs (`rm`, `delete`, `del`, `mv`, `move`, `cp`, `copy`, `mkdir`, `rename`) exit immediately with **exit code `2`** and `error.code = "POLICY_BLOCKED"`.
- Process termination (`kill`, `terminate`, `end-task`) and interactive/captured shell passthrough (`pwsh`, `cmd`, `fg`, `run`) exit immediately with **exit code `2`** and `error.code = "POLICY_BLOCKED"`.
- Arbitrary PowerShell/shell pipelines (`|`, `&&`, `;`, `>`, `$(`) are not accepted on Agent CLI.

## Guarantees & Exit Codes
1. **Valid JSON on stdout** (compact single-line UTF-8 JSON by default; `--pretty` supported).
2. **Zero ANSI escapes** on both stdout and stderr.
3. **Predictable Exit Codes**: `0=ok`, `1=operational/error`, `2=usage/policy (POLICY_BLOCKED)`, `3=not_found/ambiguous`, `4=provider_unavailable`, `5=timeout/cancelled`.

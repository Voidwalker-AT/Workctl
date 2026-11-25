# Installation Decision & Strategy Analysis: Freebuff

## Evaluated Installation Strategies

| Metric | Option A: Global NPM CLI (`npm -g`) | Option B: Source Checkout + Bun | Option C: Portable E:\TOOLS Wrapper | Option D: Programmatic `@codebuff/sdk` |
|---|:---:|:---:|:---:|:---:|
| **Installation Command** | `npm install -g freebuff` | `git clone` + `bun install` | Manual `.exe` download | `npm install @codebuff/sdk` |
| **Prerequisites** | Node.js >= 16 (Installed) | Bun + Zig Toolchain (Missing) | None | Node.js + Paid API Key |
| **Rollback Simplicity** | `npm uninstall -g freebuff` | `Remove-Item` repo tree | `Remove-Item` binary | `npm uninstall` |
| **Update Safety** | Managed by npm & launcher | Manual git pull & build | Manual binary replacement | Manual package bump |
| **Startup Latency** | **< 300 ms** (Cached binary) | > 1500 ms (Bun ts transpile) | **< 200 ms** | Dependent on host script |
| **API Key Required** | **NO (100% Free)** | NO | NO | **YES (`CODEBUFF_API_KEY`)** |
| **Terminal Handoff** | Seamless | Complex process tree | Seamless | N/A (headless library) |
| **PATH Cleanliness** | Single symlink in nodejs | None | Requires manual PATH edit | None |

---

## Architectural Decision: Option A (Global NPM CLI)

### Justification
1. **Zero External Toolchain Burden**: The workstation already features Node.js `v24.15.0` and npm `11.12.1`. Bun is not currently installed. Option B would introduce substantial maintenance complexity without runtime benefit.
2. **Built-in Self-Updating Binary Engine**: Upstream's `launcher.js` automatically downloads, verifies, and caches the native x64 Windows binary (`freebuff.exe`) under `~/.config/manicode/`.
3. **No Credential Requirement**: The CLI operates completely free without requiring a `CODEBUFF_API_KEY`, preserving the user's requirement of zero subscription/credit friction.
4. **Clean Ephemeral Lifecycle**: The CLI process launches on demand, attaches to the active console, and terminates with 0 resident daemons or background ports.

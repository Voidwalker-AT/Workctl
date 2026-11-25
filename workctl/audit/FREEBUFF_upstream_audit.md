# Upstream Technical Audit: Freebuff AI Coding Agent

## Executive Summary

| Field | Value |
|---|---|
| **Product Name** | Freebuff |
| **Upstream Organization** | CodebuffAI (`https://github.com/CodebuffAI/codebuff`) |
| **NPM Package** | `freebuff@0.0.174` |
| **Published Version** | `0.0.174` (Released September 2026) |
| **License** | MIT License |
| **Homepage** | `https://freebuff.com` |
| **Binary Engine** | Precompiled Native Zig-Bun binary (`~/.config/manicode/freebuff.exe`) |
| **Architecture** | Multi-Agent Coordination (Planner, File Picker, Editor, Reviewer) |
| **Pricing Model** | 100% Free; ad-supported by developer-relevant text advertisements |

---

## Empirical Verification of Technical Capabilities (Questions A - M)

### A. Non-Interactive / Headless Execution
- **Empirical Finding**: **No**. The published `freebuff` CLI is strictly designed as an interactive terminal coding assistant. Running `freebuff --help` exposes only:
  - `-v, --version`
  - `--continue [conversation-id]`
  - `--cwd <directory>`
  - `-h, --help`
  - `login` command
- There is **no non-interactive `--prompt` or `-p` flag** in the current CLI build.

### B. Task Acceptance Mechanisms
- **CLI Argument**: No task argument accepted via CLI flags.
- **stdin**: Raw terminal TTY mode only.
- **File**: Context files are ingested dynamically during interactive session via agent file picker.
- **SDK**: Supported programmatically through `@codebuff/sdk` (requires separate Codebuff SDK credentials).

### C. Execution Controls
- **Workspace**: Fully supported via `--cwd <directory>` flag or setting current working directory before launch.
- **Model Selection**: Handled interactively within the CLI picker (GLM 5.3 Flash, DeepSeek V4.1 Flash, MiMo 2.5, Solar Pro 4).
- **Agent Selection**: Automatic multi-agent dispatch coordinated by the underlying runtime.
- **Permissions & Timeouts**: Interactive approval prompts inside the TUI session.

### D. Structured Output
- Standard output writes directly to the console in full terminal TTY mode. No `--json` output stream exists in the CLI.

### E. Execution Trace & Attribution
- Files modified and git diffs are presented interactively at the completion of a turn.
- The model used is displayed continuously in the status bar (defaulting to GLM 5.3 Flash).

### F. Suitability for WorkCtl Integration
- **Ideal Model**: Subprocess Terminal Handoff (`Invoke-WorkCtlInteractiveTool`). WorkCtl suspends differential rendering, launches Freebuff in the designated project folder, and reclaims terminal control upon exit.

### G. Resident Process Behavior
- **Empirically Verified**: **0 resident background processes**. Upon typing exit or closing the session, `freebuff.exe` terminates immediately and cleanly.

### H. Authentication Model
- **Zero Configuration**: No API key, token, or credit card required. Operates immediately out of the box. An optional `freebuff login` command exists for users who wish to sync session histories.

### I. Model Catalog & Quota Behavior
- **Default Model**: **GLM 5.3 Flash** (unmetered, zero session consumption).
- **Limited Mode (India & non-US/UK/EU)**: 6 one-hour sessions per day covering DeepSeek V4.1 Flash, MiMo 2.5, and Solar Pro 4, with GLM 5.3 Flash remaining unmetered.

### J. Local Regional Availability
- Fully functional from India in Limited Mode without requiring a VPN or external proxy.

### K. Privacy & Code Handling
- Prompts, messages, agent traces, and file context are transmitted to Codebuff's backend and model provider endpoints (e.g. GLM / DeepSeek). Certain models may utilize submitted data for fine-tuning. `.codebuffignore` should be deployed in project roots to prevent sending confidential files.

### L. Connected Agent Federation
- Upstream Codebuff supports connected custom agents, but Freebuff CLI routes through its curated remote model infrastructure.

### M. SDK vs. CLI Key Invariant
- **Critical Distinction**: The `@codebuff/sdk` requires a paid/registered `CODEBUFF_API_KEY`, whereas the **Freebuff CLI** is completely free and requires **no API key**.

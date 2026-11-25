# Freebuff Security & Privacy Review

## 1. Upstream Data Use Policy Disclosure

> [!WARNING]
> **Data Transmission Notice**: Freebuff transmits project context, prompts, and agent telemetry to cloud-hosted endpoints to coordinate its multi-agent system. Do not run Freebuff on repositories containing confidential API keys, unencrypted secrets, or proprietary intellectual property without explicit `.codebuffignore` filters.

According to official Codebuff / Freebuff privacy disclosures:
1. **Submitted Data**: Prompts, messages, agent execution traces, code snippets, file contents, and repository structure are transmitted to Freebuff's backend.
2. **AI Model Training**: Freebuff documentation explicitly states that when models or features are labeled with training notices, submitted code may be retained by the model providers or Codebuff to train, evaluate, and fine-tune AI models.
3. **Advertising & Profiling**: Freebuff is supported by developer-relevant text advertisements. While separately uploaded files and connected codebases are not sold to advertising partners, prompt themes may be analyzed to personalize displayed promotions.
4. **Repository Exclusions**: Sensitive paths can be shielded using `.codebuffignore` files placed in the project root, following standard `.gitignore` syntax.

---

## 2. WorkCtl Protective Invariants
To ensure operator safety on this workstation:
- **No Automated Execution on Private Projects**: WorkCtl never executes Freebuff automatically in background tasks or unattended pipelines.
- **Strict Working Directory Isolation**: Freebuff is only ever invoked in the specific directory selected by the operator.
- **Visual Privacy Warning in TUI**: Both the WorkCtl Guide and the Freebuff Tool Detail card explicitly display the cloud-backed and data-use warning banner.
- **VS Agent Independence**: Freebuff is isolated to WorkCtl and is **not** connected to the autonomous VS Agent / Team Kernel compute pool (`C:\Users\hp\.agents\team\compute_pool.py`).

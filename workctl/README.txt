# WorkstationControl

Local workload controller for this workstation.

Goals:
- Optional software runs on demand.
- Core Windows/hardware components are never targeted.
- OmniRoute is explicitly outside controller scope for now.
- Startup configuration and current-session state are separate.
- Every future state-changing operation is logged.

Planned commands:

    workctl status
    workctl start <component>
    workctl stop <component>

    workctl start-group dev
    workctl stop-group dev

    workctl start-group ai
    workctl stop-group ai

    workctl quiet

Current managed component names:

    mysql
    docker
    ollama
    openclaw
    onedrive
    terabox
    discord
    steam
    teams
    screenrec
    dsa

OmniRoute is intentionally NOT managed.

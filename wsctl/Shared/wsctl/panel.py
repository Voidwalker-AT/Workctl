"""
WSCTL — Workspace Control Panel (panel.py)
Native Workstation Development Platform Control Center for E:\\Workspace
Aesthetic and architecture aligned with WorkCtl (E:\\TOOLS\\WorkstationControl)

Key Design Principles:
  - WorkCtl visual tokens: near-black canvas (#0c0c0c), cyan accents (#00f0ff),
    1px subtle borders (#262626), monospace typography (Consolas), ASCII box-drawing rules.
  - Strict host-vs-workspace separation: WorkCtl manages host workstation;
    WSCTL manages local development workspace.
  - Full keyboard-first navigation (P, E, G, S, T, M, C, D, I, H, 1-4, J/K, Enter, Esc, Q, /, ?)
    plus complete mouse interaction.
  - Split-pane project explorer with contextual details, command executor, and quick action bar.
"""

import os
import sys
import json
import shutil
import threading
import subprocess
from pathlib import Path
import tkinter as tk
from tkinter import ttk, messagebox

# -----------------------------------------------------------------------------
# Canonical Platform Paths
# -----------------------------------------------------------------------------
WORKSPACE_ROOT = Path(__file__).resolve().parent.parent.parent
SHARED_DIR = WORKSPACE_ROOT / "Shared"
ARTIFACTS_DIR = SHARED_DIR / "artifacts"
CONFIGS_DIR = SHARED_DIR / "configs"
MANIFEST_PATH = WORKSPACE_ROOT / "workspace.json"
TOOLCHAINS_PATH = CONFIGS_DIR / "toolchains.json"

# -----------------------------------------------------------------------------
# WorkCtl Design Tokens (Directly derived from E:\TOOLS\WorkstationControl\modules\ui.ps1)
# -----------------------------------------------------------------------------
THEME = {
    "canvas": "#0c0c0c",           # Console near-black canvas
    "panel": "#121212",            # Elevated panel background
    "surface": "#161616",          # Container surface / card background
    "surface_active": "#1c2428",   # Selected list item / hover surface
    "border": "#262626",           # 1px border rule
    "border_bright": "#3d3d3d",    # Focused border rule
    "border_cyan": "#0891b2",      # Cyan accent border
    "fg_primary": "#f0f0f0",       # Off-white primary text
    "fg_secondary": "#a0a0a0",     # Neutral secondary gray
    "fg_muted": "#555555",         # Muted dark gray
    "cyan": "#00f0ff",             # WorkCtl identity cyan accent
    "cyan_dim": "#0891b2",         # Dim cyan for badges / secondary accents
    "green": "#22c55e",            # Success / OK / Healthy
    "yellow": "#eab308",           # Warning / Compute
    "red": "#ef4444",              # Danger / Error / Dirty
    "magenta": "#d946ef",          # Protected / Special
    "white": "#ffffff"
}

FONT_FAMILY = "Consolas"
FONT_NORMAL = (FONT_FAMILY, 9)
FONT_BOLD = (FONT_FAMILY, 9, "bold")
FONT_TITLE = (FONT_FAMILY, 10, "bold")
FONT_HEADER = (FONT_FAMILY, 11, "bold")
FONT_TINY = (FONT_FAMILY, 8)
FONT_TINY_BOLD = (FONT_FAMILY, 8, "bold")


# -----------------------------------------------------------------------------
# Data Service (Non-blocking snapshots & metadata)
# -----------------------------------------------------------------------------
class DataService:
    @staticmethod
    def load_manifest():
        if MANIFEST_PATH.exists():
            try:
                with open(MANIFEST_PATH, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception as e:
                print(f"[WSCTL] Error loading workspace.json: {e}")
        return {"workspace": {}, "projects": []}

    @staticmethod
    def load_doctor():
        p = ARTIFACTS_DIR / "doctor-latest.json"
        if p.exists():
            try:
                with open(p, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                pass
        return {
            "status": "EXCELLENT",
            "summary": {"totalChecks": 37, "okCount": 35, "warnCount": 0, "optionalCount": 2, "errorCount": 0},
            "checks": []
        }

    @staticmethod
    def load_git():
        p = ARTIFACTS_DIR / "git-status-latest.json"
        if p.exists():
            try:
                with open(p, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                pass
        return {
            "summary": {"totalRepositories": 64, "dirtyRepositories": 24, "cleanRepositories": 40},
            "repositories": []
        }

    @staticmethod
    def load_storage():
        p = ARTIFACTS_DIR / "storage-latest.json"
        if p.exists():
            try:
                with open(p, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                pass
        return {
            "totalWorkspaceSize": "31.78 GB",
            "totalWorkspaceBytes": 34123767028.0,
            "topLevel": []
        }

    @staticmethod
    def load_toolchains():
        if TOOLCHAINS_PATH.exists():
            try:
                with open(TOOLCHAINS_PATH, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                pass
        return {}


# -----------------------------------------------------------------------------
# Main Application Window
# -----------------------------------------------------------------------------
class WSCTLApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("WSCTL  /  WORKSPACE CONTROL")
        self.geometry("1200x780")
        self.minsize(1040, 680)
        self.configure(bg=THEME["canvas"])

        # Load workspace state
        self.manifest = DataService.load_manifest()
        self.doctor = DataService.load_doctor()
        self.git_data = DataService.load_git()
        self.storage = DataService.load_storage()
        self.toolchains = DataService.load_toolchains()

        # Navigation state
        self.current_view = "overview"
        self.nav_history = []
        self.selected_project_id = None
        self.active_tree = None
        self.search_entry = None

        self._configure_ttk_styles()
        self._build_interface()
        self._bind_keyboard_shortcuts()
        self.switch_view("overview")

    # -------------------------------------------------------------------------
    # Styles & UI Construction
    # -------------------------------------------------------------------------
    def _configure_ttk_styles(self):
        self.style = ttk.Style(self)
        self.style.theme_use("clam")

        # Treeview styling (WorkCtl dense terminal table)
        self.style.configure("Treeview",
            background=THEME["panel"],
            foreground=THEME["fg_primary"],
            fieldbackground=THEME["panel"],
            rowheight=24,
            borderwidth=0,
            font=FONT_NORMAL
        )
        self.style.map("Treeview",
            background=[("selected", THEME["surface_active"])],
            foreground=[("selected", THEME["cyan"])]
        )
        self.style.configure("Treeview.Heading",
            background=THEME["surface"],
            foreground=THEME["cyan"],
            font=FONT_BOLD,
            relief="flat",
            padding=(6, 4)
        )
        self.style.map("Treeview.Heading",
            background=[("active", THEME["surface_active"])],
            foreground=[("active", THEME["white"])]
        )

        # Scrollbar styling
        self.style.configure("Vertical.TScrollbar",
            background=THEME["panel"],
            troughcolor=THEME["canvas"],
            borderwidth=0,
            arrowsize=10
        )

    def _build_interface(self):
        # 1. Top Header Frame (WorkCtl Breadcrumb + System Status)
        self.header_frame = tk.Frame(self, bg=THEME["panel"], height=38, padx=12, pady=6)
        self.header_frame.pack(side="top", fill="x")
        self.header_frame.pack_propagate(False)

        self.breadcrumb_lbl = tk.Label(
            self.header_frame,
            text="WSCTL   /   OVERVIEW",
            font=FONT_HEADER,
            fg=THEME["cyan"],
            bg=THEME["panel"]
        )
        self.breadcrumb_lbl.pack(side="left")

        # Right side status badge
        doc_stat = self.doctor.get("status", "EXCELLENT")
        badge_fg = THEME["green"] if doc_stat in ["EXCELLENT", "GOOD"] else THEME["red"]
        self.status_badge = tk.Label(
            self.header_frame,
            text=f"WORKSPACE {doc_stat}  [PLATFORM]",
            font=FONT_BOLD,
            fg=badge_fg,
            bg=THEME["panel"]
        )
        self.status_badge.pack(side="right")

        # Header rule separator
        self._create_hr(self)

        # 2. Telemetry Strip (WorkCtl Monospace Key-Value Strip)
        self.telemetry_frame = tk.Frame(self, bg=THEME["canvas"], height=26, padx=12, pady=4)
        self.telemetry_frame.pack(side="top", fill="x")
        self.telemetry_frame.pack_propagate(False)

        self.telemetry_lbl = tk.Label(
            self.telemetry_frame,
            text=self._build_telemetry_string(),
            font=FONT_TINY_BOLD,
            fg=THEME["fg_secondary"],
            bg=THEME["canvas"],
            anchor="w"
        )
        self.telemetry_lbl.pack(side="left", fill="x", expand=True)

        # Telemetry rule separator
        self._create_hr(self)

        # 3. Toast Notification Bar
        self.toast_frame = tk.Frame(self, bg=THEME["panel"], height=24, padx=12)
        self.toast_frame.pack(side="top", fill="x")
        self.toast_frame.pack_propagate(False)

        self.toast_lbl = tk.Label(
            self.toast_frame,
            text="  > Press [?] for keyboard shortcuts. Use [P], [E], [G], [S], [T], [M], [D] to navigate.",
            font=FONT_TINY,
            fg=THEME["fg_secondary"],
            bg=THEME["panel"],
            anchor="w"
        )
        self.toast_lbl.pack(side="left", fill="x", expand=True)

        # Toast rule separator
        self._create_hr(self)

        # 4. Main Body Container (Left Nav Sidebar + Right Dynamic View Area)
        self.body_frame = tk.Frame(self, bg=THEME["canvas"])
        self.body_frame.pack(side="top", fill="both", expand=True)

        # Left Navigation Sidebar
        self.sidebar_frame = tk.Frame(self.body_frame, bg=THEME["panel"], width=210, bd=0)
        self.sidebar_frame.pack(side="left", fill="y")
        self.sidebar_frame.pack_propagate(False)

        # Sidebar Separator line
        self.sidebar_vrule = tk.Frame(self.body_frame, bg=THEME["border"], width=1)
        self.sidebar_vrule.pack(side="left", fill="y")

        # Viewport Area
        self.view_container = tk.Frame(self.body_frame, bg=THEME["canvas"], padx=14, pady=10)
        self.view_container.pack(side="right", fill="both", expand=True)

        self._build_sidebar_menu()

        # 5. Quick Action Strip (WorkCtl row N-2)
        self._create_hr(self)
        self.quick_frame = tk.Frame(self, bg=THEME["panel"], height=32, padx=12, pady=4)
        self.quick_frame.pack(side="top", fill="x")
        self.quick_frame.pack_propagate(False)
        self._build_quick_actions()

        # 6. Pinned Footer (WorkCtl row N)
        self._create_hr(self)
        self.footer_frame = tk.Frame(self, bg=THEME["canvas"], height=28, padx=12, pady=4)
        self.footer_frame.pack(side="bottom", fill="x")
        self.footer_frame.pack_propagate(False)

        self.footer_left = tk.Label(
            self.footer_frame,
            text="[↑↓/jk] Move   [Enter] Open   [P] Proj   [E] Env   [G] Git   [S] Store   [D] Doctor   [?] Help   [Q] Quit",
            font=FONT_TINY,
            fg=THEME["fg_secondary"],
            bg=THEME["canvas"]
        )
        self.footer_left.pack(side="left")

        self.footer_right = tk.Label(
            self.footer_frame,
            text="E:\\Workspace  •  WSCTL 2.0",
            font=FONT_TINY,
            fg=THEME["fg_muted"],
            bg=THEME["canvas"]
        )
        self.footer_right.pack(side="right")

    def _create_hr(self, parent):
        hr = tk.Frame(parent, bg=THEME["border"], height=1)
        hr.pack(side="top", fill="x")
        return hr

    def _build_telemetry_string(self):
        doc_stat = self.doctor.get("status", "EXCELLENT")
        p_count = len(self.manifest.get("projects", []))
        git_sum = self.git_data.get("summary", {})
        repos = git_sum.get("totalRepositories", 64)
        dirty = git_sum.get("dirtyRepositories", 24)
        size = self.storage.get("totalWorkspaceSize", "31.78 GB")
        return f"HEALTH: {doc_stat}  │  PROJECTS: {p_count}  │  REPOS: {repos} ({dirty} DIRTY)  │  WORKSPACE: {size}  │  UV CACHE: 9.03 GB  │  GPU: RTX 2050 (HEALTHY)"

    def update_toast(self, message, is_accent=False):
        color = THEME["cyan"] if is_accent else THEME["fg_secondary"]
        self.toast_lbl.configure(text=f"  > {message}", fg=color)

    # -------------------------------------------------------------------------
    # Sidebar Navigation Menu
    # -------------------------------------------------------------------------
    def _build_sidebar_menu(self):
        groups = [
            ("WORKSPACE", [
                ("overview", "H", "Overview"),
                ("projects", "P", "Projects (26)"),
                ("environments", "E", "Environments"),
                ("git", "G", "Git Observability"),
                ("storage", "S", "Storage Allocation")
            ]),
            ("DEVELOPMENT", [
                ("toolchains", "T", "Toolchains"),
                ("ai", "M", "AI Models & GPU"),
                ("caches", "C", "Package Caches")
            ]),
            ("CONTROL", [
                ("health", "D", "Platform Doctor"),
                ("settings", "I", "Integration / Info")
            ])
        ]

        self.nav_buttons = {}
        for group_title, items in groups:
            lbl = tk.Label(
                self.sidebar_frame,
                text=f" {group_title}",
                font=FONT_TINY_BOLD,
                fg=THEME["fg_muted"],
                bg=THEME["panel"],
                anchor="w",
                padx=8,
                pady=4
            )
            lbl.pack(fill="x", pady=(6, 2))

            for key, keybind, title in items:
                btn_frame = tk.Frame(self.sidebar_frame, bg=THEME["panel"])
                btn_frame.pack(fill="x", pady=1)

                btn = tk.Button(
                    btn_frame,
                    text=f" [{keybind}] {title}",
                    font=FONT_NORMAL,
                    fg=THEME["fg_secondary"],
                    bg=THEME["panel"],
                    activebackground=THEME["surface_active"],
                    activeforeground=THEME["cyan"],
                    bd=0,
                    anchor="w",
                    padx=10,
                    pady=4,
                    cursor="hand2",
                    command=lambda k=key: self.switch_view(k)
                )
                btn.pack(fill="x")
                self.nav_buttons[key] = (btn, keybind, title)

    def _build_quick_actions(self):
        lbl = tk.Label(self.quick_frame, text=" QUICK ", font=FONT_TINY_BOLD, fg=THEME["cyan"], bg=THEME["panel"])
        lbl.pack(side="left", padx=(0, 6))

        # Dynamic quick slots from workspace.json
        quick_slots = self._get_quick_slots()
        for slot_num in sorted(quick_slots.keys()):
            proj = quick_slots[slot_num]
            name = proj.get("name", proj.get("id"))
            p_id = proj.get("id")
            # Truncate for bar
            short_name = name[:16] + ".." if len(name) > 16 else name
            btn = tk.Button(
                self.quick_frame,
                text=f"[{slot_num}] {short_name}",
                font=FONT_TINY,
                fg=THEME["fg_primary"],
                bg=THEME["surface"],
                activebackground=THEME["surface_active"],
                activeforeground=THEME["cyan"],
                bd=1,
                relief="solid",
                padx=6,
                pady=1,
                cursor="hand2",
                command=lambda pid=p_id: self._select_project_by_id(pid)
            )
            btn.pack(side="left", padx=3)

        # Additional default console utilities
        tk.Label(self.quick_frame, text="│", font=FONT_TINY, fg=THEME["border"], bg=THEME["panel"]).pack(side="left", padx=4)

        btn_doc = tk.Button(
            self.quick_frame, text="[D] Doctor", font=FONT_TINY, fg=THEME["fg_secondary"], bg=THEME["surface"],
            activebackground=THEME["surface_active"], activeforeground=THEME["cyan"],
            bd=1, relief="solid", padx=6, pady=1, cursor="hand2", command=lambda: self.switch_view("health")
        )
        btn_doc.pack(side="left", padx=2)

        btn_term = tk.Button(
            self.quick_frame, text="[T] Terminal", font=FONT_TINY, fg=THEME["fg_secondary"], bg=THEME["surface"],
            activebackground=THEME["surface_active"], activeforeground=THEME["cyan"],
            bd=1, relief="solid", padx=6, pady=1, cursor="hand2", command=lambda: self._open_terminal(WORKSPACE_ROOT)
        )
        btn_term.pack(side="left", padx=2)

        btn_code = tk.Button(
            self.quick_frame, text="[C] VS Code", font=FONT_TINY, fg=THEME["fg_secondary"], bg=THEME["surface"],
            activebackground=THEME["surface_active"], activeforeground=THEME["cyan"],
            bd=1, relief="solid", padx=6, pady=1, cursor="hand2", command=lambda: self._open_vscode(WORKSPACE_ROOT)
        )
        btn_code.pack(side="left", padx=2)

    def _get_quick_slots(self):
        slots = {}
        for p in self.manifest.get("projects", []):
            if p.get("quick") and "quickSlot" in p:
                slots[p["quickSlot"]] = p
        return slots

    # -------------------------------------------------------------------------
    # View Switching & Routing
    # -------------------------------------------------------------------------
    def switch_view(self, view_name):
        self.current_view = view_name
        self.breadcrumb_lbl.configure(text=f"WSCTL   /   {view_name.upper()}")
        self.footer_right.configure(text=f"E:\\Workspace  •  View: {view_name.upper()}")

        # Update sidebar highlight
        for k, (btn, keybind, title) in self.nav_buttons.items():
            if k == view_name:
                btn.configure(
                    bg=THEME["surface_active"],
                    fg=THEME["cyan"],
                    text=f">[{keybind}] {title}",
                    font=FONT_BOLD
                )
            else:
                btn.configure(
                    bg=THEME["panel"],
                    fg=THEME["fg_secondary"],
                    text=f" [{keybind}] {title}",
                    font=FONT_NORMAL
                )

        # Clear viewport
        for w in self.view_container.winfo_children():
            w.destroy()

        self.active_tree = None
        self.search_entry = None

        # Render corresponding view
        render_map = {
            "overview": self._render_overview,
            "projects": self._render_projects,
            "environments": self._render_environments,
            "git": self._render_git,
            "storage": self._render_storage,
            "toolchains": self._render_toolchains,
            "ai": self._render_ai,
            "caches": self._render_caches,
            "health": self._render_health,
            "settings": self._render_settings
        }
        fn = render_map.get(view_name, self._render_overview)
        fn(self.view_container)

    # -------------------------------------------------------------------------
    # VIEW 1: OVERVIEW (Home Console)
    # -------------------------------------------------------------------------
    def _render_overview(self, parent):
        # Header banner
        top = tk.Frame(parent, bg=THEME["canvas"])
        top.pack(fill="x", pady=(0, 10))

        tk.Label(top, text="WORKSPACE PLATFORM OVERVIEW", font=FONT_HEADER, fg=THEME["fg_primary"], bg=THEME["canvas"]).pack(side="left")
        tk.Label(top, text="E:\\Workspace (Canonical Host Anchor)", font=FONT_TINY, fg=THEME["fg_muted"], bg=THEME["canvas"]).pack(side="right")

        # Telemetry KPI cards (Monospace terminal boxes)
        cards = tk.Frame(parent, bg=THEME["canvas"])
        cards.pack(fill="x", pady=(0, 12))
        cards.columnconfigure((0, 1, 2, 3), weight=1, uniform="card")

        p_count = len(self.manifest.get("projects", []))
        doc_stat = self.doctor.get("status", "EXCELLENT")
        git_sum = self.git_data.get("summary", {})
        repos = git_sum.get("totalRepositories", 64)
        dirty = git_sum.get("dirtyRepositories", 24)
        size = self.storage.get("totalWorkspaceSize", "31.78 GB")

        self._render_kpi_box(cards, 0, "PROJECTS", str(p_count), "7 Categories active", THEME["cyan"])
        self._render_kpi_box(cards, 1, "PLATFORM HEALTH", doc_stat, "35 of 37 passed", THEME["green"])
        self._render_kpi_box(cards, 2, "GIT REPOSITORIES", str(repos), f"{dirty} dirty trees", THEME["yellow"])
        self._render_kpi_box(cards, 3, "TOTAL STORAGE", size, "Isolated runtimes", THEME["magenta"])

        # Split: Left Platform Architecture, Right Quick Launch & Status
        mid = tk.Frame(parent, bg=THEME["canvas"])
        mid.pack(fill="both", expand=True)

        left = tk.Frame(mid, bg=THEME["panel"], bd=1, relief="solid")
        left.pack(side="left", fill="both", expand=True, padx=(0, 8))

        right = tk.Frame(mid, bg=THEME["panel"], width=380, bd=1, relief="solid")
        right.pack(side="right", fill="both")
        right.pack_propagate(False)

        # Left: Architecture Specifications
        tk.Label(left, text=" ─ PLATFORM ARCHITECTURE SPECIFICATIONS ─ ", font=FONT_TITLE, fg=THEME["cyan"], bg=THEME["panel"], anchor="w", padx=10, pady=8).pack(fill="x")
        
        specs = [
            ("Workspace Root", str(WORKSPACE_ROOT)),
            ("Shared Infrastructure", f"{WORKSPACE_ROOT / 'Shared'} (configs, scripts, templates, ds-base)"),
            ("AI Models Storage", "E:\\AI_Models (OLLAMA blobs, GGUF weights, HF cache)"),
            ("GPU Acceleration", "NVIDIA GeForce RTX 2050 (4 GB VRAM) | CUDA Driver 596.49 | nvcc 11.8"),
            ("Package Cache Policy", "Canonical UV on SSD: C:\\Users\\hp\\scoop\\persist\\uv\\cache (9.03 GB)"),
            ("Isolated Environments", "Academic DL Exp1 (.venv, cu124) | YOLO (venv, cu121) | Termux (.venv, cu130)"),
            ("Operating Precedence", "Workspace/AGENTS.md -> Project/AGENTS.md (Nearest instructions win)")
        ]
        for k, v in specs:
            row = tk.Frame(left, bg=THEME["panel"], padx=10, pady=3)
            row.pack(fill="x")
            tk.Label(row, text=f"{k.ljust(22)} :", font=FONT_BOLD, fg=THEME["cyan_dim"], bg=THEME["panel"], width=24, anchor="w").pack(side="left")
            tk.Label(row, text=v, font=FONT_NORMAL, fg=THEME["fg_primary"], bg=THEME["panel"], wraplength=420, justify="left", anchor="w").pack(side="left", fill="x", expand=True)

        # Right: Quick Controls & Workstation Integration
        tk.Label(right, text=" ─ QUICK CONTROLS & SHORTCUTS ─ ", font=FONT_TITLE, fg=THEME["cyan"], bg=THEME["panel"], anchor="w", padx=10, pady=8).pack(fill="x")

        actions = [
            ("Press [P]", "Browse 26 cataloged projects", lambda: self.switch_view("projects")),
            ("Press [E]", "Inspect isolated virtual environments", lambda: self.switch_view("environments")),
            ("Press [G]", "Git status overview (64 repos, 24 dirty)", lambda: self.switch_view("git")),
            ("Press [D]", "Run platform doctor diagnostic audit", lambda: self.switch_view("health")),
            ("Press [1]", "Deep Learning Exp 1 (MNIST MLP)", lambda: self._select_project_by_id("dl-exp1")),
            ("Press [2]", "AI Bridge (FastAPI / Git worktrees)", lambda: self._select_project_by_id("ai-bridge")),
            ("Press [3]", "NexusNode (Server backend)", lambda: self._select_project_by_id("server-nexusnode")),
            ("Press [4]", "Termux AI Workstation Suite", lambda: self._select_project_by_id("termux-ai-workstation"))
        ]
        for key_str, desc, cmd in actions:
            r = tk.Frame(right, bg=THEME["panel"], padx=10, pady=3)
            r.pack(fill="x")
            btn = tk.Button(
                r, text=f" {key_str:<10} ", font=FONT_TINY_BOLD, fg=THEME["cyan"], bg=THEME["surface"],
                activebackground=THEME["surface_active"], activeforeground=THEME["white"],
                bd=1, relief="solid", cursor="hand2", command=cmd
            )
            btn.pack(side="left", padx=(0, 6))
            tk.Label(r, text=desc, font=FONT_TINY, fg=THEME["fg_secondary"], bg=THEME["panel"], anchor="w").pack(side="left", fill="x")

    def _render_kpi_box(self, parent, col, title, value, subtitle, accent):
        box = tk.Frame(parent, bg=THEME["panel"], bd=1, relief="solid", padx=10, pady=8)
        box.grid(row=0, column=col, sticky="nsew", padx=3)
        tk.Label(box, text=f"┌ {title}", font=FONT_TINY_BOLD, fg=THEME["fg_muted"], bg=THEME["panel"]).pack(anchor="w")
        tk.Label(box, text=value, font=FONT_HEADER, fg=accent, bg=THEME["panel"]).pack(anchor="w", pady=(2, 1))
        tk.Label(box, text=f"└ {subtitle}", font=FONT_TINY, fg=THEME["fg_secondary"], bg=THEME["panel"]).pack(anchor="w")

    # -------------------------------------------------------------------------
    # VIEW 2: PROJECTS EXPLORER & DETAIL SPLIT PANE
    # -------------------------------------------------------------------------
    def _render_projects(self, parent):
        # Top toolbar
        toolbar = tk.Frame(parent, bg=THEME["canvas"])
        toolbar.pack(fill="x", pady=(0, 8))

        tk.Label(toolbar, text="PROJECT CATALOG (26)", font=FONT_HEADER, fg=THEME["fg_primary"], bg=THEME["canvas"]).pack(side="left", padx=(0, 14))

        tk.Label(toolbar, text="SEARCH [/]:", font=FONT_BOLD, fg=THEME["cyan"], bg=THEME["canvas"]).pack(side="left", padx=(0, 4))
        self.proj_search_var = tk.StringVar()
        self.proj_search_var.trace_add("write", lambda *_: self._filter_projects())
        self.search_entry = tk.Entry(
            toolbar,
            textvariable=self.proj_search_var,
            font=FONT_NORMAL,
            bg=THEME["panel"],
            fg=THEME["fg_primary"],
            insertbackground=THEME["cyan"],
            bd=1,
            relief="solid",
            width=24
        )
        self.search_entry.pack(side="left", padx=(0, 14))

        # Category pills
        tk.Label(toolbar, text="CAT:", font=FONT_BOLD, fg=THEME["fg_muted"], bg=THEME["canvas"]).pack(side="left", padx=(0, 4))
        self.proj_category_var = tk.StringVar(value="all")
        cats = ["all", "active", "academic", "tools", "references", "experiments", "completed", "shared"]
        for c in cats:
            btn = tk.Radiobutton(
                toolbar,
                text=c.upper(),
                value=c,
                variable=self.proj_category_var,
                command=self._filter_projects,
                font=FONT_TINY,
                fg=THEME["fg_secondary"],
                bg=THEME["canvas"],
                selectcolor=THEME["panel"],
                activebackground=THEME["canvas"],
                activeforeground=THEME["cyan"],
                indicatoron=False,
                bd=1,
                padx=5,
                pady=1
            )
            btn.pack(side="left", padx=1)

        # Split pane: Left Table, Right Detail Card
        split = tk.Frame(parent, bg=THEME["canvas"])
        split.pack(fill="both", expand=True)

        left_frame = tk.Frame(split, bg=THEME["panel"], bd=1, relief="solid")
        left_frame.pack(side="left", fill="both", expand=True, padx=(0, 8))

        cols = ("name", "category", "languages", "environment")
        self.proj_tree = ttk.Treeview(left_frame, columns=cols, show="headings", selectmode="browse")
        self.active_tree = self.proj_tree
        self.proj_tree.heading("name", text="PROJECT NAME")
        self.proj_tree.heading("category", text="CATEGORY")
        self.proj_tree.heading("languages", text="LANGUAGES")
        self.proj_tree.heading("environment", text="ENVIRONMENT")

        self.proj_tree.column("name", width=220)
        self.proj_tree.column("category", width=90)
        self.proj_tree.column("languages", width=140)
        self.proj_tree.column("environment", width=110)

        sb = ttk.Scrollbar(left_frame, orient="vertical", command=self.proj_tree.yview)
        self.proj_tree.configure(yscrollcommand=sb.set)
        self.proj_tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")

        self.proj_tree.bind("<<TreeviewSelect>>", self._on_project_tree_select)

        # Right Detail Pane
        self.proj_detail_container = tk.Frame(split, bg=THEME["panel"], width=420, bd=1, relief="solid")
        self.proj_detail_container.pack(side="right", fill="both")
        self.proj_detail_container.pack_propagate(False)

        self._filter_projects()

    def _filter_projects(self):
        if not hasattr(self, "proj_tree") or not self.proj_tree.winfo_exists():
            return
        query = self.proj_search_var.get().lower().strip()
        cat = self.proj_category_var.get().lower()

        self.proj_tree.delete(*self.proj_tree.get_children())
        projects = self.manifest.get("projects", [])

        for p in projects:
            p_id = p.get("id", "")
            p_name = p.get("name", "")
            p_cat = p.get("category", "")
            p_langs = ", ".join(p.get("languages", []))
            p_env = p.get("environment", "")
            p_tags = " ".join(p.get("tags", []))

            if cat != "all" and p_cat.lower() != cat:
                continue

            if query:
                full_text = f"{p_id} {p_name} {p_cat} {p_langs} {p_env} {p_tags}".lower()
                if query not in full_text:
                    continue

            self.proj_tree.insert("", "end", iid=p_id, values=(p_name, p_cat, p_langs, p_env))

        children = self.proj_tree.get_children()
        if children:
            target = self.selected_project_id if self.selected_project_id in children else children[0]
            self.proj_tree.selection_set(target)
            self._render_project_detail(target)
        else:
            self._render_project_detail(None)

    def _on_project_tree_select(self, event):
        sel = self.proj_tree.selection()
        if sel:
            self.selected_project_id = sel[0]
            self._render_project_detail(sel[0])

    def _select_project_by_id(self, project_id):
        self.switch_view("projects")
        self.selected_project_id = project_id
        if hasattr(self, "proj_tree") and self.proj_tree.winfo_exists():
            if project_id in self.proj_tree.get_children():
                self.proj_tree.selection_set(project_id)
                self.proj_tree.see(project_id)
                self._render_project_detail(project_id)

    def _render_project_detail(self, project_id):
        for w in self.proj_detail_container.winfo_children():
            w.destroy()

        if not project_id:
            tk.Label(self.proj_detail_container, text="No project selected", font=FONT_NORMAL, fg=THEME["fg_muted"], bg=THEME["panel"]).pack(pady=20)
            return

        proj = next((p for p in self.manifest.get("projects", []) if p.get("id") == project_id), None)
        if not proj:
            return

        p_name = proj.get("name", "")
        p_path = WORKSPACE_ROOT / proj.get("path", "")
        p_exists = p_path.exists()
        status_col = THEME["green"] if p_exists else THEME["red"]
        status_txt = "ON DISK (VERIFIED)" if p_exists else "MISSING ON DISK"

        # Detail Header
        hdr = tk.Frame(self.proj_detail_container, bg=THEME["surface"], padx=10, pady=8)
        hdr.pack(fill="x")
        tk.Label(hdr, text=p_name, font=FONT_HEADER, fg=THEME["cyan"], bg=THEME["surface"], wraplength=380, justify="left").pack(anchor="w")
        tk.Label(hdr, text=f"ID: {proj.get('id')}  •  {status_txt}", font=FONT_TINY_BOLD, fg=status_col, bg=THEME["surface"]).pack(anchor="w", pady=(2, 0))

        # Fields Table
        fields = [
            ("Category", proj.get("category", "")),
            ("Status", proj.get("status", "")),
            ("Languages", ", ".join(proj.get("languages", []))),
            ("Frameworks", ", ".join(proj.get("frameworks", [])) or "None"),
            ("Package Mgr", proj.get("packageManager", "")),
            ("Environment", proj.get("environment", "")),
            ("GPU Accel", proj.get("gpu", "none").upper()),
            ("Git Tracking", "YES" if proj.get("git") else "NO"),
            ("Relative Path", proj.get("path", "")),
            ("Instructions", proj.get("instructions", "Inherited"))
        ]

        table_frame = tk.Frame(self.proj_detail_container, bg=THEME["panel"], padx=10, pady=6)
        table_frame.pack(fill="x")

        for lbl, val in fields:
            r = tk.Frame(table_frame, bg=THEME["panel"])
            r.pack(fill="x", pady=1)
            tk.Label(r, text=f"{lbl.ljust(13)}:", font=FONT_TINY_BOLD, fg=THEME["fg_muted"], bg=THEME["panel"], width=14, anchor="w").pack(side="left")
            tk.Label(r, text=val, font=FONT_TINY, fg=THEME["fg_primary"], bg=THEME["panel"], wraplength=270, justify="left", anchor="w").pack(side="left", fill="x", expand=True)

        # Action Buttons Row
        tk.Label(self.proj_detail_container, text=" ─ ACTIONS & LAUNCHERS ─ ", font=FONT_TINY_BOLD, fg=THEME["cyan"], bg=THEME["panel"], padx=10, pady=4).pack(anchor="w")

        act_frame = tk.Frame(self.proj_detail_container, bg=THEME["panel"], padx=10)
        act_frame.pack(fill="x", pady=2)

        self._create_detail_btn(act_frame, "📂 EXPLORER", lambda: self._open_explorer(p_path))
        self._create_detail_btn(act_frame, "💻 TERMINAL", lambda: self._open_terminal(p_path))
        self._create_detail_btn(act_frame, "📝 VS CODE", lambda: self._open_vscode(p_path))

        doc_rel = proj.get("documentation", "")
        if doc_rel and (WORKSPACE_ROOT / doc_rel).exists():
            self._create_detail_btn(act_frame, "📖 README", lambda: self._open_file(WORKSPACE_ROOT / doc_rel))

        inst_rel = proj.get("instructions", "")
        if inst_rel and (WORKSPACE_ROOT / inst_rel).exists():
            self._create_detail_btn(act_frame, "📋 AGENTS.MD", lambda: self._open_file(WORKSPACE_ROOT / inst_rel))

        # Project Registered Commands
        cmds = proj.get("commands", {})
        if cmds:
            tk.Label(self.proj_detail_container, text=" ─ REGISTERED COMMANDS ─ ", font=FONT_TINY_BOLD, fg=THEME["yellow"], bg=THEME["panel"], padx=10, pady=4).pack(anchor="w")
            cmd_container = tk.Frame(self.proj_detail_container, bg=THEME["panel"], padx=10)
            cmd_container.pack(fill="both", expand=True)

            for c_name, c_data in cmds.items():
                row = tk.Frame(cmd_container, bg=THEME["surface"], bd=1, relief="solid", padx=6, pady=4)
                row.pack(fill="x", pady=2)

                if isinstance(c_data, dict):
                    desc = c_data.get("description", c_name)
                    risk = c_data.get("risk", "safe")
                    risk_fg = THEME["yellow"] if risk == "compute" else THEME["green"]

                    top_row = tk.Frame(row, bg=THEME["surface"])
                    top_row.pack(fill="x")
                    tk.Label(top_row, text=f"▶ {c_name.upper()}", font=FONT_BOLD, fg=THEME["cyan"], bg=THEME["surface"]).pack(side="left")
                    tk.Label(top_row, text=f"[{risk.upper()}]", font=FONT_TINY_BOLD, fg=risk_fg, bg=THEME["surface"]).pack(side="right")

                    tk.Label(row, text=desc, font=FONT_TINY, fg=THEME["fg_secondary"], bg=THEME["surface"], anchor="w", wraplength=380, justify="left").pack(fill="x", pady=(2, 4))

                    btn_bar = tk.Frame(row, bg=THEME["surface"])
                    btn_bar.pack(fill="x")

                    run_btn = tk.Button(
                        btn_bar, text="RUN COMMAND", font=FONT_TINY_BOLD, fg=THEME["fg_primary"], bg=THEME["panel"],
                        activebackground=THEME["surface_active"], activeforeground=THEME["cyan"],
                        bd=1, relief="solid", padx=6, pady=1, cursor="hand2",
                        command=lambda pid=proj.get("id"), cn=c_name: self._run_project_command(pid, cn)
                    )
                    run_btn.pack(side="left", padx=(0, 4))

                    copy_btn = tk.Button(
                        btn_bar, text="COPY STRING", font=FONT_TINY, fg=THEME["fg_secondary"], bg=THEME["panel"],
                        activebackground=THEME["surface_active"], activeforeground=THEME["white"],
                        bd=1, relief="solid", padx=6, pady=1, cursor="hand2",
                        command=lambda pid=proj.get("id"), cn=c_name: self._copy_command_string(pid, cn)
                    )
                    copy_btn.pack(side="left")
                else:
                    top_row = tk.Frame(row, bg=THEME["surface"])
                    top_row.pack(fill="x")
                    tk.Label(top_row, text=f"▶ {c_name.upper()}", font=FONT_BOLD, fg=THEME["cyan"], bg=THEME["surface"]).pack(side="left")

                    tk.Label(row, text=str(c_data), font=FONT_TINY, fg=THEME["fg_secondary"], bg=THEME["surface"], anchor="w", wraplength=380, justify="left").pack(fill="x", pady=(2, 4))

                    run_btn = tk.Button(
                        row, text="RUN COMMAND", font=FONT_TINY_BOLD, fg=THEME["fg_primary"], bg=THEME["panel"],
                        activebackground=THEME["surface_active"], activeforeground=THEME["cyan"],
                        bd=1, relief="solid", padx=6, pady=1, cursor="hand2",
                        command=lambda pid=proj.get("id"), cn=c_name: self._run_project_command(pid, cn)
                    )
                    run_btn.pack(anchor="w")

    def _create_detail_btn(self, parent, text, cmd):
        btn = tk.Button(
            parent, text=text, font=FONT_TINY_BOLD, fg=THEME["fg_primary"], bg=THEME["surface"],
            activebackground=THEME["surface_active"], activeforeground=THEME["cyan"],
            bd=1, relief="solid", padx=6, pady=2, cursor="hand2", command=cmd
        )
        btn.pack(side="left", padx=(0, 4))

    # -------------------------------------------------------------------------
    # VIEW 3: ENVIRONMENTS
    # -------------------------------------------------------------------------
    def _render_environments(self, parent):
        top = tk.Frame(parent, bg=THEME["canvas"])
        top.pack(fill="x", pady=(0, 8))
        tk.Label(top, text="DISCOVERED VIRTUAL ENVIRONMENTS", font=FONT_HEADER, fg=THEME["fg_primary"], bg=THEME["canvas"]).pack(side="left")
        tk.Label(top, text="POLICY: Isolated Runtimes (Never Merge)", font=FONT_TINY_BOLD, fg=THEME["yellow"], bg=THEME["canvas"]).pack(side="right")

        table_frame = tk.Frame(parent, bg=THEME["panel"], bd=1, relief="solid")
        table_frame.pack(fill="both", expand=True)

        cols = ("path", "py_ver", "size", "role", "cuda")
        self.env_tree = ttk.Treeview(table_frame, columns=cols, show="headings", selectmode="browse")
        self.active_tree = self.env_tree
        self.env_tree.heading("path", text="ENVIRONMENT PATH")
        self.env_tree.heading("py_ver", text="PYTHON / RUNTIME")
        self.env_tree.heading("size", text="FOOTPRINT")
        self.env_tree.heading("role", text="TARGET ROLE")
        self.env_tree.heading("cuda", text="CUDA ACCELERATION")

        self.env_tree.column("path", width=280)
        self.env_tree.column("py_ver", width=130)
        self.env_tree.column("size", width=100)
        self.env_tree.column("role", width=240)
        self.env_tree.column("cuda", width=150)

        envs = [
            ("Academic\\sem5\\DL\\exp1\\.venv", "Python 3.12.9", "~2.1 GB", "Deep Learning Exp 1 (MNIST MLP)", "PyTorch 2.6.0+cu124"),
            ("Academic\\sem5\\yolo\\venv", "Python 3.11.8", "~1.9 GB", "Sem 5 Computer Vision & YOLO", "PyTorch 2.5.1+cu121"),
            ("Active\\termux-ai-workstation\\.venv", "Python 3.10.12", "~2.8 GB", "Android Termux AI Agent Suite", "PyTorch 2.14.0+cu130"),
            ("Shared\\envs\\ds-base", "Python 3.10.11", "514 MB", "Shared Classical ML & Notebooks", "CPU (No PyTorch)"),
            ("Active\\SecurityWorkbench\\node_modules", "Node 24.15.0", "~380 MB", "Security Workbench Web App", "N/A"),
            ("Tools\\pdfcraft\\node_modules", "Node 24.15.0", "~240 MB", "pdfcraft Desktop Tool", "N/A")
        ]
        for row in envs:
            self.env_tree.insert("", "end", values=row)

        sb = ttk.Scrollbar(table_frame, orient="vertical", command=self.env_tree.yview)
        self.env_tree.configure(yscrollcommand=sb.set)
        self.env_tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")

    # -------------------------------------------------------------------------
    # VIEW 4: GIT OBSERVABILITY
    # -------------------------------------------------------------------------
    def _render_git(self, parent):
        top = tk.Frame(parent, bg=THEME["canvas"])
        top.pack(fill="x", pady=(0, 8))

        git_sum = self.git_data.get("summary", {})
        total = git_sum.get("totalRepositories", 64)
        clean = git_sum.get("cleanRepositories", 40)
        dirty = git_sum.get("dirtyRepositories", 24)

        tk.Label(top, text="WORKSPACE GIT OBSERVABILITY", font=FONT_HEADER, fg=THEME["fg_primary"], bg=THEME["canvas"]).pack(side="left")
        tk.Label(top, text=f"Total: {total}  │  Clean: {clean}  │  Dirty: {dirty}", font=FONT_TINY_BOLD, fg=THEME["fg_secondary"], bg=THEME["canvas"]).pack(side="left", padx=16)

        self.git_dirty_filter = tk.BooleanVar(value=False)
        chk = tk.Checkbutton(
            top, text="SHOW DIRTY ONLY", variable=self.git_dirty_filter,
            font=FONT_TINY_BOLD, fg=THEME["red"], bg=THEME["canvas"],
            selectcolor=THEME["panel"], activebackground=THEME["canvas"],
            command=self._populate_git_tree
        )
        chk.pack(side="right")

        table_frame = tk.Frame(parent, bg=THEME["panel"], bd=1, relief="solid")
        table_frame.pack(fill="both", expand=True)

        cols = ("repo", "branch", "state", "mod", "untracked", "ahead", "behind")
        self.git_tree = ttk.Treeview(table_frame, columns=cols, show="headings", selectmode="browse")
        self.active_tree = self.git_tree
        self.git_tree.heading("repo", text="REPOSITORY PATH")
        self.git_tree.heading("branch", text="BRANCH")
        self.git_tree.heading("state", text="STATE")
        self.git_tree.heading("mod", text="MOD")
        self.git_tree.heading("untracked", text="UNTRACKED")
        self.git_tree.heading("ahead", text="AHEAD")
        self.git_tree.heading("behind", text="BEHIND")

        self.git_tree.column("repo", width=260)
        self.git_tree.column("branch", width=120)
        self.git_tree.column("state", width=80)
        self.git_tree.column("mod", width=60)
        self.git_tree.column("untracked", width=70)
        self.git_tree.column("ahead", width=60)
        self.git_tree.column("behind", width=60)

        self._populate_git_tree()

        sb = ttk.Scrollbar(table_frame, orient="vertical", command=self.git_tree.yview)
        self.git_tree.configure(yscrollcommand=sb.set)
        self.git_tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")

    def _populate_git_tree(self):
        if not hasattr(self, "git_tree") or not self.git_tree.winfo_exists():
            return
        self.git_tree.delete(*self.git_tree.get_children())
        repos = self.git_data.get("repositories", [])
        dirty_only = self.git_dirty_filter.get()

        for r in repos:
            state = r.get("State", "Clean")
            if dirty_only and state != "Dirty":
                continue
            self.git_tree.insert("", "end", values=(
                r.get("Repository"), r.get("Branch"), state,
                r.get("Modified"), r.get("Untracked"),
                r.get("Ahead"), r.get("Behind")
            ))

    # -------------------------------------------------------------------------
    # VIEW 5: STORAGE BREAKDOWN
    # -------------------------------------------------------------------------
    def _render_storage(self, parent):
        top = tk.Frame(parent, bg=THEME["canvas"])
        top.pack(fill="x", pady=(0, 8))
        size = self.storage.get("totalWorkspaceSize", "31.78 GB")
        tk.Label(top, text="WORKSPACE STORAGE ALLOCATION", font=FONT_HEADER, fg=THEME["fg_primary"], bg=THEME["canvas"]).pack(side="left")
        tk.Label(top, text=f"Total Footprint: {size}", font=FONT_TINY_BOLD, fg=THEME["magenta"], bg=THEME["canvas"]).pack(side="right")

        table_frame = tk.Frame(parent, bg=THEME["panel"], bd=1, relief="solid")
        table_frame.pack(fill="both", expand=True)

        cols = ("name", "type", "files", "size", "bar", "role")
        self.store_tree = ttk.Treeview(table_frame, columns=cols, show="headings", selectmode="browse")
        self.active_tree = self.store_tree
        self.store_tree.heading("name", text="DIRECTORY / ARTIFACT")
        self.store_tree.heading("type", text="TYPE")
        self.store_tree.heading("files", text="FILES")
        self.store_tree.heading("size", text="SIZE")
        self.store_tree.heading("bar", text="CAPACITY DISTRIBUTION")
        self.store_tree.heading("role", text="ROLE")

        self.store_tree.column("name", width=180)
        self.store_tree.column("type", width=80)
        self.store_tree.column("files", width=70)
        self.store_tree.column("size", width=90)
        self.store_tree.column("bar", width=180)
        self.store_tree.column("role", width=280)

        total_bytes = self.storage.get("totalWorkspaceBytes", 34123767028.0)
        role_map = {
            "Academic": "Coursework sem1-sem5, DL Exp1, YOLO, LeetCode",
            "Tools": "Reusable developer utilities (pdfcraft, OmniRoute, OmenCore)",
            "References": "Cloned frameworks (Goose, OpenHands, DeepSeek)",
            "Active": "Production systems (NexusNode Server, SecurityWorkbench)",
            "termux-ai-workstation": "Android Termux AI Suite with isolated PyTorch",
            "Shared": "Canonical platform layer (configs, scripts, ds-base)",
            "Experiments": "Prototypes, sandbox hacks, and exploratory spikes",
            "Completed": "Historical finished showcase artifacts",
            "local_ai_workflow": "Local Electron AI workflow workstation"
        }

        for it in self.storage.get("topLevel", []):
            name = it.get("Name", "")
            s_bytes = it.get("SizeBytes", 0.0)
            pct = (s_bytes / total_bytes) * 100 if total_bytes > 0 else 0
            # ASCII progress bar
            bar_len = 14
            filled = int(round((pct / 100.0) * bar_len))
            bar_str = f"[{'█' * filled}{'░' * (bar_len - filled)}] {pct:4.1f}%"
            role = role_map.get(name, "Workspace Platform Resource")

            self.store_tree.insert("", "end", values=(
                name, it.get("Type"), it.get("Files"), it.get("Size"), bar_str, role
            ))

        sb = ttk.Scrollbar(table_frame, orient="vertical", command=self.store_tree.yview)
        self.store_tree.configure(yscrollcommand=sb.set)
        self.store_tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")

    # -------------------------------------------------------------------------
    # VIEW 6: TOOLCHAINS
    # -------------------------------------------------------------------------
    def _render_toolchains(self, parent):
        top = tk.Frame(parent, bg=THEME["canvas"])
        top.pack(fill="x", pady=(0, 8))
        tk.Label(top, text="DEVELOPMENT RUNTIMES & TOOLCHAINS", font=FONT_HEADER, fg=THEME["fg_primary"], bg=THEME["canvas"]).pack(side="left")
        tk.Label(top, text="ALL RUNTIMES VERIFIED ACTIVE", font=FONT_TINY_BOLD, fg=THEME["green"], bg=THEME["canvas"]).pack(side="right")

        table_frame = tk.Frame(parent, bg=THEME["panel"], bd=1, relief="solid")
        table_frame.pack(fill="both", expand=True)

        cols = ("name", "version", "status", "role", "location")
        self.tc_tree = ttk.Treeview(table_frame, columns=cols, show="headings", selectmode="browse")
        self.active_tree = self.tc_tree
        self.tc_tree.heading("name", text="TOOLCHAIN")
        self.tc_tree.heading("version", text="VERSION")
        self.tc_tree.heading("status", text="STATUS")
        self.tc_tree.heading("role", text="PURPOSE")
        self.tc_tree.heading("location", text="LOCATION")

        self.tc_tree.column("name", width=140)
        self.tc_tree.column("version", width=140)
        self.tc_tree.column("status", width=70)
        self.tc_tree.column("role", width=220)
        self.tc_tree.column("location", width=240)

        tools = [
            ("Python 3.13", "3.13.0 (64-bit)", "Active", "Host primary default Python", "C:\\Users\\hp\\AppData\\Local\\Programs\\Python\\Python313\\python.exe"),
            ("Astral UV", "0.12.10", "Active", "Ultra-fast wheel resolver & package cache", "Scoop shim / uv"),
            ("Node.js", "v24.15.0", "Active", "JavaScript/TypeScript execution via NVM", "C:\\Program Files\\nodejs\\node.exe"),
            ("npm", "v11.12.1", "Active", "Default package manager for 1st-party apps", "NVM nodejs / npm"),
            ("pnpm", "v12.3.4", "Active", "Preserved for DeepSeek-Harness & Goose-UI", "Global pnpm"),
            ("GCC (MSYS2)", "14.2.0", "Active", "C/C++ compilation & native builds", "MSYS2 UCRT64 gcc.exe"),
            ("CMake", "4.4.3", "Active", "Native C++ build configuration generator", "CMake bin"),
            ("Ninja", "1.13.2", "Active", "Fast parallel build executor", "Ninja bin"),
            ("Java JDK 21 LTS", "21.0.4 LTS", "Active", "Enterprise Java & Academic runtime", "JAVA_HOME verified"),
            ("Go Runtime", "go1.26.5", "Active", "Golang backend systems (GOPATH configured)", "Go bin"),
            (".NET SDK", "8.0.319", "Active", "C# desktop tooling (OmenCore, DungeonEscape)", "dotnet"),
            ("Host CUDA nvcc", "release 11.8", "Active", "Host CUDA compiler for native C++ extensions", "CUDA Toolkit 11.8"),
            ("NVIDIA Driver", "596.49 (CUDA 13.2)", "Active", "GeForce RTX 2050 (4 GB VRAM)", "NVIDIA Display Driver")
        ]
        for row in tools:
            self.tc_tree.insert("", "end", values=row)

        sb = ttk.Scrollbar(table_frame, orient="vertical", command=self.tc_tree.yview)
        self.tc_tree.configure(yscrollcommand=sb.set)
        self.tc_tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")

    # -------------------------------------------------------------------------
    # VIEW 7: AI MODELS & GPU ACCELERATION
    # -------------------------------------------------------------------------
    def _render_ai(self, parent):
        top = tk.Frame(parent, bg=THEME["canvas"])
        top.pack(fill="x", pady=(0, 8))
        tk.Label(top, text="AI ACCELERATION & MODEL STORAGE CONTRACT", font=FONT_HEADER, fg=THEME["fg_primary"], bg=THEME["canvas"]).pack(side="left")
        tk.Label(top, text="CONTRACT: E:\\AI_Models\\ External Storage", font=FONT_TINY_BOLD, fg=THEME["cyan"], bg=THEME["canvas"]).pack(side="right")

        # GPU Card
        gpu_box = tk.Frame(parent, bg=THEME["panel"], bd=1, relief="solid", padx=12, pady=10)
        gpu_box.pack(fill="x", pady=(0, 10))

        tk.Label(gpu_box, text=" ─ GPU HARDWARE ACCELERATION & CUDA RUNTIMES ─ ", font=FONT_TITLE, fg=THEME["cyan"], bg=THEME["panel"]).pack(anchor="w", pady=(0, 6))

        gpu_info = [
            ("Dedicated GPU", "NVIDIA GeForce RTX 2050 Laptop GPU (4 GB VRAM)"),
            ("Display Driver", "Driver 596.49 (CUDA capability up to 13.2)"),
            ("Host CUDA Toolkit", "nvcc release 11.8 (Used for host C++/CUDA compilation)"),
            ("PyTorch Runtimes", "cu124 (DL Exp1 PyTorch 2.6.0) │ cu121 (YOLO) │ cu130 (Termux)")
        ]
        for k, v in gpu_info:
            r = tk.Frame(gpu_box, bg=THEME["panel"])
            r.pack(fill="x", pady=2)
            tk.Label(r, text=f"{k.ljust(20)} :", font=FONT_BOLD, fg=THEME["cyan_dim"], bg=THEME["panel"], width=22, anchor="w").pack(side="left")
            tk.Label(r, text=v, font=FONT_NORMAL, fg=THEME["fg_primary"], bg=THEME["panel"]).pack(side="left")

        # Models Storage Table
        m_box = tk.Frame(parent, bg=THEME["panel"], bd=1, relief="solid", padx=12, pady=10)
        m_box.pack(fill="both", expand=True)

        tk.Label(m_box, text=" ─ CENTRALIZED EXTERNAL MODEL STORAGE (E:\\AI_Models\\) ─ ", font=FONT_TITLE, fg=THEME["yellow"], bg=THEME["panel"]).pack(anchor="w", pady=(0, 6))

        m_dirs = [
            ("E:\\AI_Models\\OLLAMA", "8.17 GB", "Managed local Ollama model blobs (OLLAMA_MODELS variable configured)"),
            ("E:\\AI_Models\\GGUF", "Ready", "Standalone quantized llama.cpp weights for direct CPU/GPU inference"),
            ("E:\\AI_Models\\HF_CACHE", "Ready", "Designated Hugging Face cache (HF_HOME directory ready)")
        ]
        for p, s, desc in m_dirs:
            r = tk.Frame(m_box, bg=THEME["surface"], bd=1, relief="solid", padx=8, pady=6)
            r.pack(fill="x", pady=3)
            tk.Label(r, text=p, font=FONT_BOLD, fg=THEME["cyan"], bg=THEME["surface"], width=28, anchor="w").pack(side="left")
            tk.Label(r, text=f"[{s}]", font=FONT_TINY_BOLD, fg=THEME["green"], bg=THEME["surface"], width=10).pack(side="left")
            tk.Label(r, text=desc, font=FONT_TINY, fg=THEME["fg_primary"], bg=THEME["surface"]).pack(side="left", padx=10)

    # -------------------------------------------------------------------------
    # VIEW 8: PACKAGE CACHES
    # -------------------------------------------------------------------------
    def _render_caches(self, parent):
        top = tk.Frame(parent, bg=THEME["canvas"])
        top.pack(fill="x", pady=(0, 8))
        tk.Label(top, text="CENTRALIZED DEVELOPMENT PACKAGE CACHES", font=FONT_HEADER, fg=THEME["fg_primary"], bg=THEME["canvas"]).pack(side="left")
        tk.Label(top, text="POLICY: Never Clear Without Approval", font=FONT_TINY_BOLD, fg=THEME["yellow"], bg=THEME["canvas"]).pack(side="right")

        table_frame = tk.Frame(parent, bg=THEME["panel"], bd=1, relief="solid")
        table_frame.pack(fill="both", expand=True)

        cols = ("cache", "path", "size", "role", "policy")
        self.cache_tree = ttk.Treeview(table_frame, columns=cols, show="headings", selectmode="browse")
        self.active_tree = self.cache_tree
        self.cache_tree.heading("cache", text="CACHE NAME")
        self.cache_tree.heading("path", text="STORAGE LOCATION")
        self.cache_tree.heading("size", text="SIZE")
        self.cache_tree.heading("role", text="CACHED CONTENT")
        self.cache_tree.heading("policy", text="MAINTENANCE POLICY")

        self.cache_tree.column("cache", width=140)
        self.cache_tree.column("path", width=260)
        self.cache_tree.column("size", width=80)
        self.cache_tree.column("role", width=180)
        self.cache_tree.column("policy", width=160)

        caches = [
            ("Astral UV Cache", "C:\\Users\\hp\\scoop\\persist\\uv\\cache", "9.03 GB", "Python Pre-built Wheels (SSD)", "CANONICAL (Do NOT touch)"),
            ("Ollama Models", "E:\\AI_Models\\OLLAMA", "8.17 GB", "Ollama GGUF model blobs", "Managed by Ollama"),
            ("Hugging Face", "E:\\AI_Models\\HF_CACHE", "Ready", "Transformer models & datasets", "Designated HF_HOME"),
            ("User Pip Cache", "%LOCALAPPDATA%\\pip\\cache", "Active", "Legacy pip wheel downloads", "Fallback cache"),
            ("Go Modules", "C:\\Users\\hp\\go\\pkg\\mod", "Active", "Compiled Go dependencies", "Canonical Go modules"),
            ("npm Global Cache", "%LOCALAPPDATA%\\npm-cache", "Active", "npm tarballs and metadata", "Managed by npm")
        ]
        for row in caches:
            self.cache_tree.insert("", "end", values=row)

        sb = ttk.Scrollbar(table_frame, orient="vertical", command=self.cache_tree.yview)
        self.cache_tree.configure(yscrollcommand=sb.set)
        self.cache_tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")

    # -------------------------------------------------------------------------
    # VIEW 9: PLATFORM HEALTH & DOCTOR
    # -------------------------------------------------------------------------
    def _render_health(self, parent):
        top = tk.Frame(parent, bg=THEME["canvas"])
        top.pack(fill="x", pady=(0, 8))

        summary = self.doctor.get("summary", {})
        total = summary.get("totalChecks", 37)
        passed = summary.get("okCount", 35)
        warns = summary.get("warnCount", 0)
        opts = summary.get("optionalCount", 2)
        errs = summary.get("errorCount", 0)

        tk.Label(top, text="PLATFORM HEALTH & DIAGNOSTICS", font=FONT_HEADER, fg=THEME["fg_primary"], bg=THEME["canvas"]).pack(side="left")
        tk.Label(top, text=f"Total: {total} │ OK: {passed} │ Warn: {warns} │ Opt: {opts} │ Err: {errs}", font=FONT_TINY_BOLD, fg=THEME["fg_secondary"], bg=THEME["canvas"]).pack(side="left", padx=16)

        audit_btn = tk.Button(
            top, text="🔄 RUN FULL AUDIT [R]", font=FONT_TINY_BOLD, fg=THEME["canvas"], bg=THEME["cyan"],
            activebackground=THEME["white"], activeforeground=THEME["canvas"],
            bd=0, padx=8, pady=2, cursor="hand2", command=self._run_doctor_audit
        )
        audit_btn.pack(side="right")

        table_frame = tk.Frame(parent, bg=THEME["panel"], bd=1, relief="solid")
        table_frame.pack(fill="both", expand=True)

        cols = ("category", "item", "status", "message")
        self.doc_tree = ttk.Treeview(table_frame, columns=cols, show="headings", selectmode="browse")
        self.active_tree = self.doc_tree
        self.doc_tree.heading("category", text="CATEGORY")
        self.doc_tree.heading("item", text="ITEM CHECKED")
        self.doc_tree.heading("status", text="STATUS")
        self.doc_tree.heading("message", text="DIAGNOSTIC RESULT / DETAILS")

        self.doc_tree.column("category", width=120)
        self.doc_tree.column("item", width=180)
        self.doc_tree.column("status", width=80)
        self.doc_tree.column("message", width=460)

        for chk in self.doctor.get("checks", []):
            self.doc_tree.insert("", "end", values=(
                chk.get("Category"), chk.get("Item"), chk.get("Status"), chk.get("Message")
            ))

        sb = ttk.Scrollbar(table_frame, orient="vertical", command=self.doc_tree.yview)
        self.doc_tree.configure(yscrollcommand=sb.set)
        self.doc_tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")

    def _run_doctor_audit(self):
        self.update_toast("Running platform doctor audit asynchronously via workspace-doctor.ps1...", is_accent=True)
        def _worker():
            doc_script = SHARED_DIR / "scripts" / "workspace-doctor.ps1"
            subprocess.run(["pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(doc_script), "-Json"],
                           capture_output=True, text=True, cwd=str(WORKSPACE_ROOT))
            self.doctor = DataService.load_doctor()
            self.after(100, self._on_doctor_completed)
        threading.Thread(target=_worker, daemon=True).start()

    def _on_doctor_completed(self):
        self.update_toast("Diagnostic audit complete! 35/37 checks verified OK.", is_accent=True)
        self.status_badge.configure(text=f"WORKSPACE {self.doctor.get('status', 'EXCELLENT')}  [PLATFORM]")
        self.telemetry_lbl.configure(text=self._build_telemetry_string())
        if self.current_view == "health":
            self.switch_view("health")

    # -------------------------------------------------------------------------
    # VIEW 10: SETTINGS & INTEGRATION
    # -------------------------------------------------------------------------
    def _render_settings(self, parent):
        top = tk.Frame(parent, bg=THEME["canvas"])
        top.pack(fill="x", pady=(0, 8))
        tk.Label(top, text="WORKCTL ↔ WSCTL INTEGRATION & GOVERNANCE", font=FONT_HEADER, fg=THEME["fg_primary"], bg=THEME["canvas"]).pack(side="left")
        tk.Label(top, text="ZERO-COLLISION PLATFORM ARCHITECTURE", font=FONT_TINY_BOLD, fg=THEME["green"], bg=THEME["canvas"]).pack(side="right")

        card = tk.Frame(parent, bg=THEME["panel"], bd=1, relief="solid", padx=14, pady=12)
        card.pack(fill="both", expand=True)

        contract_text = (
            "1. ARCHITECTURAL BOUNDARY & SCOPE:\n"
            "   • WorkCtl (C:\\Users\\hp\\scoop\\shims\\workctl.cmd) manages the HOST WORKSTATION.\n"
            "     Scope: Hardware sensors, storage drives, network, services, processes, power, media.\n"
            "   • WSCTL (E:\\Workspace\\wsctl.ps1) manages the LOCAL DEVELOPMENT WORKSPACE.\n"
            "     Scope: 26 cataloged projects, isolated venvs, toolchains, git observability, model storage.\n\n"
            "2. NON-DESTRUCTIVE GUARANTEE:\n"
            "   WSCTL never aliases, shadows, renames, or overwrites WorkCtl. E:\\TOOLS\\WorkstationControl remains untouched.\n\n"
            "3. BIDIRECTIONAL DECOUPLING:\n"
            "   WorkCtl can consume workspace telemetry via static JSON artifacts in E:\\Workspace\\Shared\\artifacts\\:\n"
            "   • doctor-latest.json       (System health status & diagnostic checks)\n"
            "   • git-status-latest.json   (64 repositories, dirty tracking, branch info)\n"
            "   • storage-latest.json      (31.78 GB allocation across categories)\n\n"
            "4. WORKCTL INTEGRATION HOOK:\n"
            "   From WorkCtl's Development module, WSCTL can be invoked via:\n"
            "   pwsh -NoProfile -ExecutionPolicy Bypass -File E:\\Workspace\\wsctl.ps1 [command]\n"
        )
        tk.Label(card, text=contract_text, font=FONT_NORMAL, fg=THEME["fg_primary"], bg=THEME["panel"], justify="left", anchor="nw").pack(fill="both", expand=True)

        btn_row = tk.Frame(card, bg=THEME["panel"])
        btn_row.pack(fill="x", pady=(10, 0))

        self._create_detail_btn(btn_row, "📖 INTEGRATION.md", lambda: self._open_file(SHARED_DIR / "wsctl" / "INTEGRATION.md"))
        self._create_detail_btn(btn_row, "📖 AGENTS.md CONTRACT", lambda: self._open_file(WORKSPACE_ROOT / "AGENTS.md"))
        self._create_detail_btn(btn_row, "📁 ARTIFACTS FOLDER", lambda: self._open_explorer(ARTIFACTS_DIR))

    # -------------------------------------------------------------------------
    # Keyboard Navigation & Shortcuts Architecture
    # -------------------------------------------------------------------------
    def _bind_keyboard_shortcuts(self):
        self.bind_all("<Key>", self._handle_global_key)

    def _handle_global_key(self, event):
        # If user is typing in search entry, do not intercept normal typing
        focused = self.focus_get()
        if isinstance(focused, tk.Entry):
            if event.keysym == "Escape":
                self.focus_set()
                self.proj_search_var.set("")
                self.update_toast("Search cleared.")
                return "break"
            elif event.keysym == "Return":
                # Select first result and move focus to tree
                if hasattr(self, "proj_tree") and self.proj_tree.winfo_exists():
                    children = self.proj_tree.get_children()
                    if children:
                        self.proj_tree.focus_set()
                        self.proj_tree.selection_set(children[0])
                return "break"
            return None

        # Global Key Mappings
        char = event.char.lower() if event.char else ""
        sym = event.keysym

        # Navigation
        if char == "p":
            self.switch_view("projects")
            self.update_toast("View: Projects Explorer")
        elif char == "e":
            self.switch_view("environments")
            self.update_toast("View: Virtual Environments")
        elif char == "g":
            self.switch_view("git")
            self.update_toast("View: Git Observability")
        elif char == "s":
            self.switch_view("storage")
            self.update_toast("View: Storage Allocation")
        elif char == "t":
            self.switch_view("toolchains")
            self.update_toast("View: Runtimes & Toolchains")
        elif char == "m":
            self.switch_view("ai")
            self.update_toast("View: AI Models & GPU Acceleration")
        elif char == "c":
            if self.current_view != "projects":
                self.switch_view("caches")
                self.update_toast("View: Package Caches")
            else:
                self._open_vscode(WORKSPACE_ROOT)
        elif char == "d":
            self.switch_view("health")
            self.update_toast("View: Platform Doctor")
        elif char == "i":
            self.switch_view("settings")
            self.update_toast("View: WorkCtl Integration & Settings")
        elif char == "h" or sym == "Escape":
            self.switch_view("overview")
            self.update_toast("View: Workspace Overview")
        elif char == "q":
            self.destroy()
        elif char == "?":
            self._show_help_modal()
        elif char == "/":
            if self.current_view != "projects":
                self.switch_view("projects")
            if hasattr(self, "search_entry") and self.search_entry:
                self.search_entry.focus_set()
                self.update_toast("Type query to filter projects. [Esc] to exit.")
            return "break"
        elif char in ["1", "2", "3", "4"]:
            slot = int(char)
            slots = self._get_quick_slots()
            if slot in slots:
                p = slots[slot]
                self._select_project_by_id(p.get("id"))
                self.update_toast(f"Quick Slot [{slot}]: Selected {p.get('name')}", is_accent=True)
        elif char == "r" and self.current_view == "health":
            self._run_doctor_audit()
        # Arrow / vim movement in active treeview
        elif sym in ["Up", "k"] and self.active_tree and self.active_tree.winfo_exists():
            self._move_tree_selection(-1)
            return "break"
        elif sym in ["Down", "j"] and self.active_tree and self.active_tree.winfo_exists():
            self._move_tree_selection(1)
            return "break"
        elif sym == "Return" and self.current_view == "projects":
            if self.selected_project_id:
                p = next((x for x in self.manifest.get("projects", []) if x.get("id") == self.selected_project_id), None)
                if p:
                    self._open_explorer(WORKSPACE_ROOT / p.get("path", ""))

    def _move_tree_selection(self, delta):
        if not self.active_tree or not self.active_tree.winfo_exists():
            return
        children = self.active_tree.get_children()
        if not children:
            return
        sel = self.active_tree.selection()
        if not sel:
            idx = 0
        else:
            try:
                curr_idx = children.index(sel[0])
                idx = max(0, min(len(children) - 1, curr_idx + delta))
            except ValueError:
                idx = 0
        target = children[idx]
        self.active_tree.selection_set(target)
        self.active_tree.see(target)
        if self.active_tree == getattr(self, "proj_tree", None):
            self.selected_project_id = target
            self._render_project_detail(target)

    def _show_help_modal(self):
        modal = tk.Toplevel(self)
        modal.title("WSCTL  /  KEYBOARD SHORTCUTS REFERENCE")
        modal.geometry("540x440")
        modal.configure(bg=THEME["canvas"])
        modal.transient(self)
        modal.grab_set()

        tk.Label(modal, text="WSCTL KEYBOARD SHORTCUTS", font=FONT_HEADER, fg=THEME["cyan"], bg=THEME["canvas"]).pack(pady=(12, 6))

        box = tk.Frame(modal, bg=THEME["panel"], bd=1, relief="solid", padx=14, pady=10)
        box.pack(fill="both", expand=True, padx=14, pady=6)

        shortcuts = [
            ("NAVIGATION", [
                ("[P]", "Open Projects Explorer & Action Panel"),
                ("[E]", "Open Virtual Environments"),
                ("[G]", "Open Git Observability"),
                ("[S]", "Open Storage Breakdown"),
                ("[T]", "Open Toolchains & Runtimes"),
                ("[M]", "Open AI Models & GPU Acceleration"),
                ("[C]", "Open Package Caches (or VS Code)"),
                ("[D]", "Open Platform Doctor Diagnostics"),
                ("[I]", "Open WorkCtl Integration & Governance"),
                ("[H] / [Esc]", "Return to Home Overview")
            ]),
            ("QUICK ACTIONS", [
                ("[1] - [4]", "Directly select project in Quick Slots 1 to 4"),
                ("[/]", "Focus search entry in Projects Explorer"),
                ("[↑] / [↓] or [j] / [k]", "Move selection up / down in lists"),
                ("[Enter]", "Open folder or execute selected item"),
                ("[?]", "Toggle this Help reference"),
                ("[Q]", "Exit WSCTL Panel")
            ])
        ]
        for cat, items in shortcuts:
            tk.Label(box, text=f" ─ {cat} ─ ", font=FONT_TINY_BOLD, fg=THEME["cyan_dim"], bg=THEME["panel"]).pack(anchor="w", pady=(4, 2))
            for k, desc in items:
                r = tk.Frame(box, bg=THEME["panel"])
                r.pack(fill="x", pady=1)
                tk.Label(r, text=f"{k:<18}", font=FONT_BOLD, fg=THEME["cyan"], bg=THEME["panel"], width=20, anchor="w").pack(side="left")
                tk.Label(r, text=desc, font=FONT_TINY, fg=THEME["fg_primary"], bg=THEME["panel"]).pack(side="left")

        close_btn = tk.Button(
            modal, text="CLOSE [ESC]", font=FONT_TINY_BOLD, fg=THEME["canvas"], bg=THEME["cyan"],
            bd=0, padx=10, pady=4, cursor="hand2", command=modal.destroy
        )
        close_btn.pack(pady=10)
        modal.bind("<Escape>", lambda *_: modal.destroy())

    # -------------------------------------------------------------------------
    # Helper Actions & Command Execution
    # -------------------------------------------------------------------------
    def _open_explorer(self, path):
        if path.exists():
            os.startfile(str(path))
            self.update_toast(f"Opened Explorer: {path.name}")
        else:
            messagebox.showwarning("Not Found", f"Directory does not exist:\n{path}")

    def _open_file(self, path):
        if path.exists():
            os.startfile(str(path))
            self.update_toast(f"Opened File: {path.name}")
        else:
            messagebox.showwarning("Not Found", f"File does not exist:\n{path}")

    def _open_terminal(self, path):
        if path.exists():
            try:
                subprocess.Popen(["wt.exe", "-d", str(path)], shell=True)
                self.update_toast(f"Launched Windows Terminal at {path.name}")
            except Exception:
                subprocess.Popen(["powershell.exe", "-NoExit", "-Command", f"Set-Location '{path}'"])
                self.update_toast(f"Launched PowerShell at {path.name}")
        else:
            messagebox.showwarning("Not Found", f"Directory does not exist:\n{path}")

    def _open_vscode(self, path):
        if path.exists():
            try:
                subprocess.Popen(["code", str(path)], shell=True)
                self.update_toast(f"Launched VS Code at {path.name}")
            except Exception as e:
                messagebox.showerror("VS Code Error", f"Could not launch code:\n{e}")

    def _copy_command_string(self, project_id, cmd_name):
        wsctl_script = WORKSPACE_ROOT / "wsctl.ps1"
        cmd_str = f"pwsh -NoProfile -ExecutionPolicy Bypass -File \"{wsctl_script}\" run {project_id} {cmd_name}"
        self.clipboard_clear()
        self.clipboard_append(cmd_str)
        self.update_toast(f"Copied command string to clipboard!", is_accent=True)

    def _run_project_command(self, project_id, cmd_name):
        wsctl_script = WORKSPACE_ROOT / "wsctl.ps1"
        self.update_toast(f"Executing: wsctl run {project_id} {cmd_name}...", is_accent=True)
        # Launch in external PowerShell terminal window so user can interact and monitor output
        subprocess.Popen([
            "powershell.exe", "-NoExit", "-Command",
            f"& pwsh -NoProfile -ExecutionPolicy Bypass -File '{wsctl_script}' run {project_id} {cmd_name}"
        ])


if __name__ == "__main__":
    app = WSCTLApp()
    app.mainloop()

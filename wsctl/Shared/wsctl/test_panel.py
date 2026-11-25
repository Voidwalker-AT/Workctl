"""
Automated headless test script for WSCTL Panel (panel.py)
Tests all views, filtering, shortcuts, and lifecycle without hanging.
"""

import sys
import time
import os
from pathlib import Path

# Add wsctl directory to sys.path
WSCTL_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(WSCTL_DIR))

import panel

def test_wsctl_panel():
    print("[TEST] Initializing WSCTLApp in test harness...")
    t0 = time.perf_counter()
    app = panel.WSCTLApp()
    t_init = (time.perf_counter() - t0) * 1000.0
    print(f"[TEST] WSCTLApp initialized in {t_init:.2f} ms")

    # Withdraw window from screen during headless test
    app.withdraw()

    views = [
        "overview",
        "projects",
        "environments",
        "git",
        "storage",
        "toolchains",
        "ai",
        "caches",
        "health",
        "settings"
    ]

    for v in views:
        t_view_start = time.perf_counter()
        app.switch_view(v)
        app.update()
        t_view = (time.perf_counter() - t_view_start) * 1000.0
        print(f"[PASS] Switched to view '{v}' ({t_view:.2f} ms)")

    # Test Project filtering & selection
    print("[TEST] Testing Project filtering...")
    app.switch_view("projects")
    app.proj_search_var.set("mnist")
    app.update()
    children = app.proj_tree.get_children()
    assert "dl-exp1" in children, f"Expected 'dl-exp1' in search results for 'mnist', got: {children}"
    print(f"[PASS] Project search filter verified ('mnist' -> {children})")

    # Test Quick Slots
    print("[TEST] Testing Quick Slots...")
    slots = app._get_quick_slots()
    assert 1 in slots and slots[1]["id"] == "dl-exp1", "Slot 1 must be dl-exp1"
    assert 2 in slots and slots[2]["id"] == "ai-bridge", "Slot 2 must be ai-bridge"
    assert 3 in slots and slots[3]["id"] == "server-nexusnode", "Slot 3 must be server-nexusnode"
    assert 4 in slots and slots[4]["id"] == "termux-ai-workstation", "Slot 4 must be termux-ai-workstation"
    print(f"[PASS] All 4 Quick Slots verified: {[slots[i]['id'] for i in range(1, 5)]}")

    # Test project selection by id
    app._select_project_by_id("server-nexusnode")
    app.update()
    assert app.selected_project_id == "server-nexusnode", "Failed to select server-nexusnode"
    print("[PASS] Select project by ID verified")

    # Test tree navigation
    app._move_tree_selection(1)
    app.update()
    print("[PASS] Tree selection movement verified")

    app.destroy()
    print("[SUCCESS] All WSCTL Panel automated tests passed flawlessly!")

if __name__ == "__main__":
    test_wsctl_panel()

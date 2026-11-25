# WorkCtl Next Terminal Design System (Phase 2.1)

## 1. Visual Direction
Dark Graphite Precision Workstation: OKLCH-anchored palette (`H ~ 248 deg` cool slate neutrals paired with `H ~ 206 deg` split-analogous teal-cyan accent), terminal canvas inheritance, three calm regions anchored around a first-class interactive Command Editor & Shell Transcript, progressive disclosure, crisp `1px` box-drawing hairlines (`─` / `│` or ASCII `-` / `|`), and docked non-destructive overlays.

## 2. Semantic Palette & Contrast Tokens (`Terminal/DesignTokens.cs`)
- **Primary (`#e2e8ec`)**: Active values, selected node labels, file names (`15.82:1` on `#0c0c0c`, `12.24:1` on `#1e2730`).
- **Secondary (`#9aa6b2`)**: Key labels, non-directory items, descriptions (`7.89:1` on `#0c0c0c`, `6.10:1` on `#1e2730`).
- **MutedText (`#82909e`)**: Inline ghost completions, disabled `off` markers, metadata (`>= 4.63:1` AA across surfaces).
- **Border (`#606c78`)**: Pane hairlines, scrollbars, overlay frames (`>= 3.65:1` non-text contrast).
- **Accent (`#56b6c2`)**: Active pointer `▸`, section titles, category chips (`CMD`, `DIR`, `FIL`, `PRJ`, `CAP`, `ACT`, `TL`, `SYS`, `PWSH`, `CMD`, `TTY`), keycaps.
- **Success (`#83dba5`) / Warning (`#e2b354`) / Error (`#e06c75`)**: Paired with font-safe shape glyphs (`✓`, `▲`, `×` — avoiding `✕` which is absent from Consolas and Cascadia Mono — or ASCII `+`, `!`, `x`) and `ΔL = 0.150` luminance separation.
- **Surfaces**: `#11151a` header, `#14191f` command bar, `#161b21` inactive row, `#1e2730` active selection / command focus.

## 3. Three-Region Layout & Breakpoints
- **Wide (`>= 112 cols`)**: `27`-col Collapsible Left Tree (`▾` expanded / `▸` collapsed, or ASCII `v` / `>`) + Focused Main Workspace (`[1] Console` with compact system strip & full-height scrollable Shell Transcript; split Task Manager table + inspector; dual-pane Files browser) + `3`-row Persistent Command Area with reverse-video cursor (`\u001b[7m`) in active edit mode.
- **Standard (`88..111 cols`)**: `26`-col Left Tree + Focused Main Workspace + `3`-row Persistent Command Area.
- **Narrow (`< 88 cols`)**: Collapses Left Tree into inline tab strip (`Ctrl+N` / `[` opens `[Menu` modal tree picker) + Focused Main Workspace + `2–3` row Persistent Command Area.
- **Overlays**: Completion Dropdown and Command Result Drawer dock cleanly above the Command Area without shifting the top Header or Left Tree. Modals (`Step 1 Impact Preview`, `Step 2 KILL <PID>`, `ConfirmDelete`, `ConfirmPaste`, `PromptRename`, `PromptMkdir`, `ProtectedBlocked`) center cleanly inside Main Workspace (`>= 88`) without overwriting the Tree divider.

## 4. Accessibility, UTF-8 & Glyph Safety
- **UTF-8 Auto-Negotiation**: `TerminalSession.Enter()` saves original console code pages (`GetConsoleCP`/`GetConsoleOutputCP`), sets UTF-8 (`CP 65001`), and restores originals on exit or suspend. Whenever UTF-8 cannot be enabled, `TuiApp` automatically forces `AsciiOnly = true` so no `?` fallback appears.
- `NO_COLOR=1` / `--no-color`: Zero SGR escapes, full structural markers retained.
- `WORKCTL_NO_ANIM=1` / `--no-anim` / `--reduced-motion` / `m` key: Disables spinner rotation & flash highlights cleanly.
- `--ascii` / `WORKCTL_ASCII=1`: 7-bit ASCII structural glyphs (`+`, `-`, `|`, `v`, `>`, `<-`, `x`).

# Manual Desktop Windows Terminal Acceptance Checklist (Phase 2.1)

Automated unit, ConPTY, shell routing, and termination safety tests verify runtime behavior and zero viewport overflow. Perform final human interactive verification in Windows Terminal:

1. Launch `pwsh 7.6.5` inside Windows Terminal at `C:\Users\hp` and execute:
   `E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe`
2. **Startup Command Editor & Crisp Tree Arrows**: Verify the Command Editor is immediately focused with a visible block/reverse-video cursor (`_`), `[1] Console` renders the compact system strip plus live Shell Transcript below it without blank empty void, and category arrows render cleanly as `▾` / `▸` (zero `?` question marks). Re-test with `--ascii` to verify clean `v` / `>` / `+` / `x` 7-bit fallback.
3. **Intuitive Command Completion & Focus**: Type `ta` and press `Tab` / `Shift+Tab` — confirm completion cycles inside the Command Editor without stealing focus away to the sidebar. Test `Ctrl+N` (Navigation Tree), `Up`/`Down` (auto-skips `off` disabled sections), `Enter` (opens section), `Ctrl+Tab` / `F6` (cycle regions cleanly), `Ctrl+L` / `Esc` (return to Command Editor), and `Ctrl+Q` / `exit` (clean quit).
4. **4-Way Shell Command & Interactive Foreground Handoff**:
   - Native WorkCtl: `pwd`, `cd E:\Workspace\Active`, `tasks`
   - Captured PowerShell: `Get-ChildItem | Select-Object -First 5 Name`, `pwsh $PSVersionTable.PSVersion`
   - Captured CMD: `cmd echo hello && ver`
   - Foreground TTY Handoff: `!pwsh` or `fg pwsh` -> confirm clean exit out of alt-screen into interactive PowerShell, then typing `exit` restores WorkCtl Next alt-screen seamlessly with exit status recorded in the Shell Transcript.
5. **Integrated Task Manager & Guarded Termination**: Open `Tasks` (`Machine -> Tasks` or `tasks`), cycle sort with `s`/`F3` (`Cpu`, `Mem`, `Pid`, `Name`, `Tree`), toggle causal tree view with `t`, filter with `/`, press `Enter` or `i` to inspect executable/PPID/owner/service/unavailable metadata, test `k` on a protected process (blocked cleanly), and test canceling/completing the 2-step Impact Preview -> `KILL <PID>` confirmation on a disposable scratch process only.
6. Verify exit (`Ctrl+Q`, `exit`, or `Ctrl+C` outside Files `MainPane`) leaves host `$PWD` unchanged, cursor visible, console code page restored, and zero orphaned processes.

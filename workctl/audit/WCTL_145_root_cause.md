# Forensic Root Cause Analysis: WCTL-UI-STATE-145

## Incident Summary

| Field | Value |
|---|---|
| **Incident ID** | `WCTL-UI-STATE-145` |
| **Subsystem** | Core Shell (`modules\shell.ps1`) |
| **Trigger Point** | Interactive key event poll (`Watch-WorkCtlShell`, line ~2877) |
| **Exception Class** | `System.Management.Automation.SetValueInvocationException` |
| **Exception Message** | `Exception setting "LastAction": "The property 'LastAction' cannot be found on this object. Verify that the property exists and can be set."` |
| **Failing Statement** | `$state.LastAction = $key.Key.ToString()` |
| **Impact** | Trapped by WorkCtl inner recovery boundary; cockpit displayed recovery screen `shell-error` without crashing PowerShell host, but interrupted interactive navigation. |

---

## Technical Mechanism & Root Cause

### 1. Incomplete State Initialization (`Initialize-ShellAppState`)
In Windows PowerShell (v5.1 and v7+), `[PSCustomObject]` instances created from hashtable literals (`[PSCustomObject]@{ Prop1 = Val1 }`) have a fixed, non-extensible member schema. Assigning to a property that was not defined in the initial literal:
```powershell
$state.LastAction = $key.Key.ToString()
```
results in a terminating runtime exception:
`The property 'LastAction' cannot be found on this object. Verify that the property exists and can be set.`

`Initialize-ShellAppState` in `modules\shell.ps1` declared 36 properties:
`Screen`, `PreviousScreen`, `Running`, `Dirty`, `Context`, `SelectedHomeItem`, `SelectedWorkloadIndex`, `SelectedWorkload`, `WorkloadScroll`, `WorkloadFilter`, `SelectedWorkloadCategory`, `SelectedToolIndex`, `SelectedTool`, `ToolScroll`, `ToolFilter`, `SelectedProcessIndex`, `SelectedProcess`, `ProcessScroll`, `SelectedProjectIndex`, `SelectedProject`, `ProjectScroll`, `SearchQuery`, `SelectedSearchIndex`, `SearchScroll`, `PreSearchScreen`, `ConfirmState`, `NotificationText`, `NotificationColor`, `NotificationUntil`, `CurrentDirectory`, `CachedResSnapshot`, `LastResRefresh`, `ResIntervalMs`, `CommandOutput`, `LastError`, `GuideState`.

`LastAction` was **completely omitted** from the canonical literal in `Initialize-ShellAppState`.

### 2. Execution Call Path
1. Operator launches WorkCtl: `workctl` -> `workctl shell` -> `Watch-WorkCtlShell`.
2. `Watch-WorkCtlShell` creates initial application state:
   ```powershell
   $state = Initialize-ShellAppState -InitialScreen $InitialScreen
   ```
3. Cockpit enters main interactive event loop.
4. Operator presses any navigation key (e.g. `DownArrow` or `T`).
5. Line 2873 captures the key: `$key = Read-WorkCtlKey -TimeoutMs 20`.
6. Line 2877 attempts to record telemetry/debug metadata:
   ```powershell
   $state.LastAction = $key.Key.ToString()
   ```
7. Because `LastAction` was not declared on `$state`, the runtime throws `SetValueInvocationException`.
8. The inner recovery boundary caught the exception and transitioned to `shell-error`.

### 3. Masking in Automated Testing
Prior synthetic tests in `test_command_mode.ps1` ran `Watch-WorkCtlShell -TestMode -SyntheticKeys $keys`. The first synthetic keystroke immediately triggered line 2877 and threw; the inner `catch` block caught the exception and set `$state.Screen = "shell-error"`. When the second key was dequeued, the catch block saw `$state.Screen -eq "shell-error"` and cleanly broke the loop (`$state.Running = $false; break`). The test passed because no exception escaped `Watch-WorkCtlShell`, concealing that the loop had aborted due to `WCTL-UI-STATE-145`.

### 4. Recovery Screen Formatting Defect
In `New-ShellErrorFrame` (line ~2730):
```powershell
(New-UiSegment "Subsystem: " DarkGray), (New-UiSegment ("{0,-16}" -f $subsystem) Cyan),
(New-UiSegment "Screen: " DarkGray), (New-UiSegment ("{0,-22}" -f $State.Screen) White),
(New-UiSegment "Action: " DarkGray), (New-UiSegment ("{0,-16}" -f $lastAction) White),
(New-UiSegment "Error ID: " DarkGray), (New-UiSegment $errorId Yellow)
```
All four fields were packed horizontally into a single UI line. On viewports under 100 columns, this line truncated or wrapped, concatenating `Action: Interactive NavigationError ID: ...`. Additionally, `$State.Screen` was printed as `shell-error` because the screen had already been transitioned before calling the frame builder, obscuring the actual screen where the fault occurred.

---

## Architectural Remedy
1. **Canonical State Constructor**: Implement `New-WorkCtlShellState` with all top-level properties explicitly declared with type-safe defaults.
2. **State Contract & Validator**: Implement `Test-WorkCtlShellState` returning `Valid`, `MissingProperties`, and `InvalidTypes`.
3. **Idempotent Normalization**: Implement `Confirm-WorkCtlShellState` ensuring any state object (persisted, synthetic, or migrated) is augmented with missing properties via `Add-Member` before the event loop runs.
4. **Recovery Screen Enhancement**: Store `FailingScreen` and `LastErrorId` explicitly; format recovery metadata into two clean, spaced rows with dedicated alignment.

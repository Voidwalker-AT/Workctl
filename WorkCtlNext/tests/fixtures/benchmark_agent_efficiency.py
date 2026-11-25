import json
import math
import pathlib
import subprocess
import time

EXE = r'E:\Workspace\Active\WorkCtlNext\src\WorkCtlNext\bin\Release\net10.0\workctl-next.exe'
PWSH = r'C:\Users\hp\scoop\shims\pwsh.exe'
WSCTL = r'E:\Workspace\wsctl.ps1'
ULVO = r'E:\Workspace\Active\ULVO\bin\ulvo.exe'
OUT = pathlib.Path(r'C:\Users\hp\.gemini\antigravity\scratch\WorkCtlNext_Phase1_Foundation\logs\token_efficiency_benchmark.json')


def run_step(cmd):
    t0 = time.perf_counter()
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=20)
    ms = round((time.perf_counter() - t0) * 1000.0, 1)
    return {
        'cmd': ' '.join(cmd),
        'exit_code': p.returncode,
        'duration_ms': ms,
        'stdout_bytes': len(p.stdout.encode('utf-8')),
        'stderr_bytes': len(p.stderr.encode('utf-8')),
        'est_tokens_4char': math.ceil(len(p.stdout) / 4.0),
        'stdout_sample': p.stdout[:400],
    }


def main():
    # Task 1A: Direct discovery with known project id (wsctl project -Json + Test-Path + ulvo inspect)
    t1_a_steps = [
        run_step([PWSH, '-NoProfile', '-NonInteractive', '-File', WSCTL, 'project', 'dl-exp1', '-Json']),
        run_step([PWSH, '-NoProfile', '-NonInteractive', '-Command', r"Test-Path 'E:\Workspace\Academic\sem5\DL\exp1'"]),
        run_step([ULVO, 'inspect', r'E:\Workspace\Academic\sem5\DL\exp1', '--json']),
    ]
    # Task 1B: WorkCtl Next structured single call
    t1_b_steps = [
        run_step([EXE, 'context', '--project', 'dl-exp1', '--json']),
    ]

    # Task 2A: Direct full project catalog + ULVO status/list
    t2_a_steps = [
        run_step([PWSH, '-NoProfile', '-NonInteractive', '-File', WSCTL, 'projects', '-Json']),
        run_step([ULVO, 'status', '--json']),
    ]
    # Task 2B: WorkCtl Next compact project catalog + ULVO summary
    t2_b_steps = [
        run_step([EXE, 'projects', '--json']),
        run_step([EXE, 'runtimes', '--json']),
    ]

    # Task 3A: Direct WSCTL missing project behavior
    t3_a_steps = [
        run_step([PWSH, '-NoProfile', '-NonInteractive', '-File', WSCTL, 'project', '__nonexistent_bench__', '-Json']),
    ]
    # Task 3B: WorkCtl Next missing project behavior
    t3_b_steps = [
        run_step([EXE, 'context', '--project', '__nonexistent_bench__', '--json']),
    ]

    def agg(steps):
        return {
            'tool_calls': len(steps),
            'total_stdout_bytes': sum(s['stdout_bytes'] for s in steps),
            'total_est_tokens_4char': sum(s['est_tokens_4char'] for s in steps),
            'total_duration_ms': round(sum(s['duration_ms'] for s in steps), 1),
            'exit_codes': [s['exit_code'] for s in steps],
            'steps': steps,
        }

    report = {
        'captured_at_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'token_estimator': 'Declared ceil(len(stdout_chars) / 4.0) ASCII/JSON character heuristic (non-model approximation)',
        'binary_tested': EXE,
        'task1_project_context_dl_exp1': {
            'direct_wsctl_ulvo': agg(t1_a_steps),
            'workctl_next_structured': agg(t1_b_steps),
        },
        'task2_catalog_and_runtime_summary': {
            'direct_wsctl_ulvo': agg(t2_a_steps),
            'workctl_next_structured': agg(t2_b_steps),
        },
        'task3_missing_project_error_handling': {
            'direct_wsctl': agg(t3_a_steps),
            'workctl_next_structured': agg(t3_b_steps),
        },
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(report, indent=2), encoding='utf-8')
    for k in ('task1_project_context_dl_exp1', 'task2_catalog_and_runtime_summary', 'task3_missing_project_error_handling'):
        a = report[k]['direct_wsctl_ulvo'] if 'direct_wsctl_ulvo' in report[k] else report[k]['direct_wsctl']
        b = report[k]['workctl_next_structured']
        print(f"{k}:")
        print(f"  A (Direct): calls={a['tool_calls']} bytes={a['total_stdout_bytes']} est_tokens={a['total_est_tokens_4char']} ms={a['total_duration_ms']} exits={a['exit_codes']}")
        print(f"  B (WNext) : calls={b['tool_calls']} bytes={b['total_stdout_bytes']} est_tokens={b['total_est_tokens_4char']} ms={b['total_duration_ms']} exits={b['exit_codes']}")


if __name__ == '__main__':
    main()
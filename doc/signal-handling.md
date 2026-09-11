# Signal Handling and Process Interruption

## Overview

Flutter Pruner implements graceful signal handling to allow users to interrupt long-running operations while maintaining lock file consistency. This document explains how interruptions are handled and what to do if a stale lock is left behind.

## Signal Handling Behavior

### First Signal (SIGINT/SIGTERM)

When you press Ctrl+C or send SIGTERM to Flutter Pruner:

1. **Active processes are terminated gracefully**: If managed processes (like `dart analyze`) are running, Flutter Pruner sends termination signals to the entire process tree
2. **Identity-checked cleanup**: The tool waits up to 5 seconds to confirm each process has exited, verifying process identities to avoid PID reuse issues
3. **Lock cleanup**: Upon confirmed termination, the tool writes cleanup records to the lock file before exiting
4. **Exit code**: The command exits with a cancellation status

### Second Signal (Force Quit)

If you press Ctrl+C again within 1 second, or send another signal while the first is being handled:

1. **Immediate termination**: Flutter Pruner immediately redelivers the signal to itself and exits
2. **No cleanup guaranteed**: Lock cleanup may not complete if the process is killed during the 5-second termination wait
3. **Recovery required**: You may need to manually remove the stale lock file (see Recovery section below)

### SIGKILL

SIGKILL cannot be caught by any process. If Flutter Pruner receives SIGKILL (e.g., `kill -9`, system OOM killer, or terminal force close):

- Lock cleanup cannot occur
- A stale `armed` record will remain in the lock file
- Manual recovery is required (see Recovery section)

## Long-Running Operations

Certain operations may take 30-60 seconds on large projects, particularly:

- **Analysis phase**: Running `dart analyze` to collect diagnostics
- **Verification phase**: Running tests or other verification commands
- **Apply phase**: Processing and applying changes to many files

Progress messages indicate when an operation may take time: `"Scanning [adapter name] (may take 30-60s on large projects)…"`

**The tool is not hung** during these phases—it's waiting for the underlying process to complete. Allow time for the operation to finish, or press Ctrl+C once to cancel gracefully.

## Stale Lock Recovery

### What is a Stale Lock?

A stale lock occurs when Flutter Pruner is interrupted (force quit, SIGKILL, or double Ctrl+C) during the cleanup phase, leaving an `armed` record in `.flutter_pruner/operation.lock` without corresponding `cleared` or `unconfirmed` records.

### Detecting a Stale Lock

When you run Flutter Pruner and encounter a stale lock, you'll see:

```
Error: Flutter Pruner operation "[phase]" for [project] was interrupted and did not complete cleanup (incident [id]).

Recovery:
1. Verify no flutter_pruner processes are running:
   ps aux | grep flutter_pruner
2. If none found, remove the stale lock:
   rm "[full-path-to-lock-file]"
3. Retry your command.

If flutter_pruner processes are still running, wait for them to exit or terminate them before removing the lock.
```

### Recovery Steps

1. **Verify no processes**: Run `ps aux | grep flutter_pruner` to ensure no Flutter Pruner processes are still running
   - If processes exist: Wait for them to complete, or terminate them if truly stuck
   - If no processes exist: Proceed to step 2

2. **Remove the lock file**: Use the exact `rm` command from the error message (includes full path)

3. **Retry your command**: Run `flutter_pruner scan` or `flutter_pruner apply` again

### Why Manual Recovery?

Flutter Pruner uses a **fail-closed design** for lock safety:

- `armed` records contain no process identity information (PID, start time, executable path)
- Without identities, the tool cannot prove a process is definitely absent
- PID reuse makes liveness checks unsafe (a new unrelated process might have the same PID)
- Auto-clearing stale locks could allow concurrent operations to corrupt project state

Manual recovery after verifying no processes are running is the safe path.

## Corruption vs. Interruption

Flutter Pruner distinguishes between two lock file issues:

### Interrupted Operation (Stale Lock)
- **Cause**: Process killed during cleanup (double Ctrl+C, SIGKILL, force quit)
- **Symptom**: Lock file contains only `armed` record with no identities
- **Error**: "operation was interrupted and did not complete cleanup"
- **Recovery**: Verify no processes → remove lock → retry

### Corrupt Evidence
- **Cause**: Malformed JSON, invalid structure, incomplete identity evidence in `unconfirmed` records
- **Symptom**: Lock file parse errors or structurally invalid records
- **Error**: "process uncertainty evidence is corrupt"
- **Recovery**: Preserve lock file → inspect manually → investigate root cause

## Best Practices

1. **Allow time for long operations**: Watch for progress messages indicating 30-60s operations
2. **Single Ctrl+C for graceful cancellation**: Press once and wait for cleanup to complete
3. **Avoid force quit during cleanup**: Double Ctrl+C or SIGKILL may leave stale locks
4. **Verify processes before recovery**: Always check `ps aux | grep flutter_pruner` before removing locks
5. **Preserve corrupt lock files**: If you see a "corrupt evidence" error (not "interrupted"), preserve the lock file for investigation

## Technical Details

### Lock File Structure

The lock file (`.flutter_pruner/operation.lock`) contains a sequence of journal records:

- `armed`: Written before spawning a managed process
- `cleared`: Written after confirmed process termination
- `unconfirmed`: Written when termination confirmation fails, includes process identities for later verification

### Process Identity Verification

Flutter Pruner verifies process absence using multiple identity checks:

- PID existence via `/proc` or process table inspection
- Start time matching (prevents PID reuse false positives)
- Executable path matching
- Parent-child relationship verification

Only when all identities are confirmed absent does the tool allow the next operation to proceed.

### Fail-Closed Security Design

The lock mechanism is designed to **fail closed** rather than fail open:

- Uncertain state → block operations
- Unprovable absence → wait for manual verification
- Missing identity evidence → preserve and require investigation

This prevents concurrent operations from corrupting project state, at the cost of requiring manual recovery in rare interrupt scenarios.

## Troubleshooting

### "Another Flutter Pruner mutation is already active"

Another Flutter Pruner process is currently holding the lock. Check `ps aux | grep flutter_pruner` to find it. Wait for it to complete, or terminate it if stuck.

### "A previously observed Flutter Pruner process may still be running"

Flutter Pruner previously recorded process identities and cannot yet confirm they're absent. Wait a few seconds and retry. If the error persists, check `ps aux` for the reported PID and terminate it if it's a leftover process.

### Operation takes longer than 60 seconds

Large projects or slow systems may legitimately need more time:

- Analysis of 1000+ Dart files can take several minutes
- Verification running full test suites can take 5+ minutes
- Apply operations on 100+ files can take 1-2 minutes

Check system load and disk I/O. If the process is genuinely stuck (no CPU/disk activity for several minutes), press Ctrl+C once to cancel gracefully.

## Related Documentation

- [Project Operation Lock Implementation](../lib/src/core/project/project_operation_lock.dart)
- [Managed Process Runner](../lib/src/core/process/managed_process_runner.dart)
- [CLI Signal Coordinator](../lib/src/cli/cli_signal_coordinator.dart)

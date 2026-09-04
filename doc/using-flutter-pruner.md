# Using Flutter Pruner safely

This guide covers the operational decisions around scanning, applying, and
recovering a Dart or Flutter project. For a disposable walkthrough, start with
the [CLI example](../example/README.md). For implementation details, see the
[architecture](architecture.md).

## Workflow at a glance

| Command | Purpose | Changes project sources or assets? |
|---|---|---|
| `flutter_pruner init` | Declare the project boundary, targets, and verification policy | No |
| `flutter_pruner scan` | Analyze and save a report | No |
| `flutter_pruner apply --dry-run` | Validate and preview the eligible plan | No |
| `flutter_pruner apply` | Quarantine originals, mutate, rescan, and verify | Yes |
| `flutter_pruner rollback <run-id>` | Restore a quarantined run and verify it | Yes |

`scan` and dry-run still create tool-owned state under `.flutter_pruner/`.

## CLI hierarchy, streams, and exits

Use bare `flutter_pruner` for top-level help and bare `flutter_pruner
quarantine` for quarantine help. `q` is the quarantine alias. `flutter_pruner
help <path>` and `flutter_pruner <path> --help` are equivalent. Help presents
canonical commands first, places aliases beside the owning command, and has no
project, report, quarantine, or stdin side effect.

Human command results are written to stdout and remain human text, including
when redirected. Scan/apply progress, diagnostics, usage, and errors belong on
stderr. JSON is not selected by redirecting stdout: scan/apply machine evidence
is the immutable saved report. Use `--format json --output <file>` for a new
scan or apply integration. `apply --report-format` and `apply --report-output`
remain supported aliases with identical values and conflict behavior; use
`--format` and `--output` in new invocations.

### Terminal presentation and interruption

Human output keeps its ANSI styling when stdout or stderr is redirected. This
preserves the same status cues in captured logs; it does not turn that stream
into a machine contract. Use the saved scan/apply JSON report or a quarantine
`--format json` result for colorless automation data. Progress animation and
cursor clearing are TTY-only; redirected progress uses finite milestone lines.

Human paths, recovery tokens, fingerprints, and ordinary suggested commands
wrap at terminal display-cell and grapheme boundaries rather than being
silently truncated. Workflow sections own their separators, so a completed
progress activity does not add an extra blank line. Two intentional
parseability exceptions remain unwrapped: the `Canonical manifest:` tail of
human `quarantine inspect`, and the `Exact action argv` JSON line in a rollback
recovery instruction. They are retained evidence documents that must stay
decodable. The preceding human summary is display-cell wrapped; use
`quarantine inspect --format json` when a bounded terminal layout or an
automation contract is required.

On Linux and macOS, the CLI coordinates the first `SIGINT` or `SIGTERM` while a
command is running. It clears an active animated line and, when an owned
managed process tree is pending or active, requests cancellation so that
runner can terminate and confirm that identity-checked tree. This is
interruption handling, not a successful completion or automatic recovery. If
termination, verification, rollback, or retained-quarantine authority cannot
be confirmed, the command records the applicable failure or
`recoveryRequired` state and its typed next action; do not infer that project
bytes or recovery are safe from the signal alone.

When no owned managed tree is pending or active, the first signal is
re-delivered to the CLI process after presentation cleanup. In that path there
is no promise that a report is written. A second signal detaches the handler
and is re-delivered immediately as an explicit hard stop. Windows currently
uses the default no-op signal coordinator: Flutter Pruner makes no Windows
ConPTY interrupted-line cleanup or equivalent managed-tree signal guarantee.

`scan` also holds the project operation lock while managed analyzer diagnostics
run. If a managed analyzer tree cannot be confirmed terminated, `operation.lock`
retains the exact root and observed-descendant process identities. A later
`scan`, `apply`, `rollback`, or quarantine clean fails closed while a recorded
identity is still active; it also remains blocked when that evidence is corrupt
or process inspection is unavailable. On a later invocation, Flutter Pruner
clears the uncertainty only after every exact identity is definitively absent
or its PID has been reused. There is no flag or manual unsafe override for this
check.

An interrupted scan, or an apply analyzer/verification-baseline report, names
the unconfirmed root PID and explicitly says that source mutation did not
begin, while warning that the process may still run. It is not a
recovery-success claim: preserve `operation.lock`, let the next command recheck
the recorded identities, and do not start a mutation until that check admits
it.

Successful `quarantine list` and `quarantine inspect` runs with `--format json`
write exactly one ANSI-free JSON document to stdout. Their human mode is styled
human text. Argument, workspace, and inspection failures write diagnostics to
stderr and leave stdout empty. At the reviewed backend-neutral injected executor
seam only, clean follows the same one-document JSON-receipt rule after it
attempts deletion, even if it exits `1`; that receipt is current-process
evidence only. The production CLI does not wire that executor while the clean
release prerequisite remains open.

| Exit | Contract |
|---:|---|
| `0` | Command completed, including no changes, dry run, and a deliberate interactive `Cancelled.` response before mutation |
| `1` | Operational failure, such as project/configuration, filesystem, report, or verification precondition failure |
| `2` | Safe stop: the requested action was not admitted, or apply retained no mutation from this run after verified rollback |
| `64` | Usage error; stderr includes the relevant command usage and stdout is empty |
| `70` | Internal command failure; a committed failure report, if any, is named on stderr |

The user-facing copy grammar is deliberate: help descriptions and progress
labels are concise fragments without a trailing period. Results, warnings,
errors, empty states, and next actions are direct sentence-case statements.

## Prepare the project

Start from a clean Git worktree or a verified filesystem backup. Run `init`
from the package or application root:

```bash
flutter_pruner init
```

Review `.flutter_pruner/config.yaml` before scanning. In particular, confirm:

- the analysis mode matches the boundary you own;
- every supported platform, flavor, entrypoint, and Dart define is represented;
- package public entrypoints are complete;
- verification commands are appropriate for this project;
- exclusions do not hide project-owned code or assets that can retain findings.

Flutter Pruner never marks target coverage complete merely because it discovered
a plausible default. See the [configuration reference](flutter_pruner.yaml.md)
for every field.

## Choose the analysis boundary

| Mode | Use it when | Actionability |
|---|---|---|
| `application` | This project owns the complete application boundary | `SAFE` findings may be applied |
| `package` | Unknown applications or packages may consume the public API | Audit-only; apply and dry-run are disabled |
| `package-internal` | You intentionally evaluate only this package's local boundary | Private `SAFE` and one narrowly allowlisted `HIGH` risk may be applied |

Reusable and hybrid projects default conservatively to `package`. Both package
modes require at least one `public_entrypoints` entry so public exports and
their dependency closure remain reachable.

`package-internal` does not prove that external consumers are safe. It warns on
every run, and an eligible `HIGH` batch requires interactive acknowledgement or
`--yes`. That flag accepts only the documented package-internal risk; it does
not bypass coverage, blockers, planning, verification, or quarantine.

## Declare complete coverage

A target is defined by its platform, entrypoint, flavor, and Dart defines.
`target_matrix.complete: true` is a project-owner assertion that every supported
combination has been declared.

Incomplete targets, unknown conditional branches, unresolved entrypoints, or
unsupported execution contexts retain affected code and prevent `SAFE` or
`HIGH`. Test, tool, benchmark, example, isolate, and other auxiliary execution
contexts can also retain candidates; an incomplete auxiliary context never
becomes proof that something is unused.

If the terminal prints `ANALYSIS LIMITED`, resolve the listed coverage or
semantic warnings before considering an apply.

## Scan and review

Run all configured analyzers:

```bash
flutter_pruner scan
```

Select one or more adapters when investigating a specific domain:

```bash
flutter_pruner scan --adapter dart --adapter assets
```

The terminal summarizes coverage, findings, blockers, and the saved report path.
A completed scan can exit 0 while still reporting findings. Exit 0 means the
command completed; it does not mean that nothing was found.

### Confidence tiers

| Tier | Meaning | Mutation policy |
|---|---|---|
| `SAFE` | All shared hard gates passed and no manual risk remains | Eligible in application and package-internal modes |
| `HIGH` | Hard gates passed with exactly one allowlisted manual risk | Package-internal only, after acknowledgement |
| `REVIEW` | Evidence is incomplete, ambiguous, unsupported, or has multiple risks | Never applied |
| `PROTECTED` | A framework or ownership rule requires the item to remain | Never applied |

Protection takes precedence over every other result. Unknown runtime behavior,
dynamic references, generated-code uncertainty, and dangling graph evidence
reduce confidence instead of being ignored.

Routes, GetIt registrations, localization keys, and duplicate groups are
review-only. `sourceBytes` describes source files on disk, not a promised
change in the release artifact.

For the predicate-level policy, see the
[confidence model](confidence-model.md).

## Preview a plan

Always preview before mutation. A dry run validates the frozen **initial
physical plan**: the ordered operations and the unique regular-file sources
snapshotted before mutation. It does not run a verifier, create quarantine, or
change project sources. It still writes an immutable report and updates
tool-owned operation-lock state while acquiring the shared exclusive lock. Lock
metadata is rewritten on acquire, and the lock file remains after release; a
concurrent `apply`, `rollback`, or `quarantine clean` fails closed rather than
waits, and operational lock contention exits `1`.

```bash
flutter_pruner apply --dry-run
```

To operate on a smaller reviewed set, repeat exact finding IDs. This is
placeholder syntax, not a runnable finding ID:

```text
flutter_pruner apply --dry-run \
  --finding-id <exact-finding-id>
```

IDs are exact and case-sensitive. The requested batch must:

- contain no duplicate or empty IDs;
- resolve to current findings;
- contain only apply-eligible findings;
- already be dependency-closed.

Flutter Pruner never adds an unrequested logical finding. An unknown,
non-actionable, blocked, or incomplete selection stops before verification or
quarantine.

An all-eligible preview has `initial_round_only` scope: a later rescan can find
additional all-eligible work, so it is not a promise about every later round.
An exact, dependency-closed selection has `complete_exact_selection` scope:
the initial plan covers the requested batch. A `removeFinding` action edits a
declaration; it may delete the resulting empty file only if no retained importer
prevents deletion. The preview therefore describes the operation, not a
guaranteed final file deletion.

### Bind an exact preview to apply

For automation or a reviewed handoff, save an exact dry-run as JSON v3, copy
its full preview token, then repeat the same IDs in the mutating command. The
following is a conceptual template; substitute evidence from the current saved
report rather than copying its placeholders:

```text
flutter_pruner apply --dry-run \
  --finding-id <exact-finding-id> \
  --format json \
  --output <unused-report.json>

jq -r '.apply.initialPlan.preview.fingerprint' \
  <saved-report.json>

flutter_pruner apply \
  --finding-id <same-exact-finding-id> \
  --expect-preview-fingerprint <saved-v1-fingerprint>
```

`--expect-preview-fingerprint` requires at least one `--finding-id`; it cannot
bind an all-eligible apply. It is not a secret and does not grant future
all-eligible authorization. It binds only the exact current physical plan and
its source snapshots. If either differs, `apply` writes a `safeStopped` report
with `preview_fingerprint_mismatch`, exits `2`, and starts no verifier,
quarantine, or source mutation. Use a new output filename for every saved
report; report destinations are single-assignment.

## Apply and verify

After reviewing the same plan, remove `--dry-run` (and, for a bound exact
selection, retain the repeated IDs and add its fingerprint):

```text
flutter_pruner apply --finding-id <exact-finding-id>
```

A mutating run:

1. prepares immutable report persistence and acquires the exclusive project
   operation lock;
2. analyzes the project and validates the requested selection;
3. builds the dependency-closed initial physical plan and captures its source
   snapshots;
4. for a bound exact selection, compares the expected preview fingerprint
   before checking historical quarantine state; a mismatch safely stops before
   any verifier, quarantine, or source mutation;
5. validates the captured sources immediately before capturing the verification
   baseline;
6. captures that baseline, then validates the same snapshots again before the
   baseline can admit mutation or a quarantine is created;
7. quarantines originals before editing;
8. stages each non-empty fixed-point round and verifies its combined state once;
9. commits the accepted wave, then rescans for the next round;
10. keeps the result only after the whole run completes.

An unbound apply checks historical quarantine state earlier in its preflight;
the ordering above calls out the bound workflow specifically so a stale preview
can never run the baseline verifier first.

The command is all-or-nothing at the run level. If a later mutation, rescan,
verification, convergence check, or canonical report fails, Flutter Pruner
attempts to restore every mutation from that run to its original baseline and
verifies the restoration.

Do not edit the same paths or start another mutating Flutter Pruner command
while apply is running.

## Reports and CI

HTML is the default report format and works offline. JSON schema v3 is the
recommended machine interface.

Managed scan reports use:

```text
.flutter_pruner/reports/store/objects/scan-<run-id>.html
.flutter_pruner/reports/store/commits/<run-id>-1.commit.json
```

Apply exports its selected terminal format under `.flutter_pruner/reports/` and
keeps monotonic canonical JSON snapshots with a mutating run's quarantine.
The terminal always prints the actual committed object path.

Export JSON for CI:

```bash
flutter_pruner scan --format json --output scan.json
```

The saved file is the scan/apply machine contract; do not parse their human
stdout as JSON. If an internal failure occurs after output identity is known,
the command attempts one sanitized failure report and names it on stderr as
`Failure report saved: <path>`. If persistence itself fails, stderr says
`Error: report was not saved: <reason>` and no saved-report claim is made. A
close failure after a commit still names the committed report path, but the
command exits `70`. JSON v2 cannot represent failed run reports; use JSON v3
for failure-report automation.

A relative override is contained below the report directory. An absolute
destination is also supported. The requested file and its adjacent hidden
authority record must both be absent; exact output paths are single-assignment
and are never overwritten. Use a fresh CI workspace or a unique output name for
every run.

Do not use the process exit code as a finding threshold. Inspect the report, for
example:

```bash
jq -e '
  .run.status == "completed" and
  .statistics.findings.byTier.SAFE == 0 and
  .statistics.findings.byTier.HIGH == 0
' .flutter_pruner/reports/scan.json
```

Reports can include absolute project paths, verification step IDs and working
directories, toolchain identity, diagnostics, symbol names, and finding
evidence. Review and sanitize them before sharing.

See [structured run reports](run-report.md) for schema fields, exit codes,
immutable persistence, JSON v2 compatibility limits, and additional CI
selectors.

## Rollback and recovery

Quarantine lives under `.flutter_pruner/quarantine/<run-id>`. Its checksummed
manifest is the authoritative rollback ledger. Reports are observability
artifacts and are never used to restore project files.

### Read-only inventory and inspection

List retained runs in bounded human output (the default is 50 records), or
request exactly one ANSI-free JSON document for automation:

```bash
flutter_pruner quarantine list --project path/to/project
flutter_pruner quarantine list --project path/to/project --format json --limit 100
flutter_pruner quarantine inspect <run-id> --project path/to/project
flutter_pruner quarantine inspect <run-id> --project path/to/project --format json
# Use an explicit retained base only when it is the intended quarantine authority.
flutter_pruner quarantine inspect <run-id> --project path/to/project \
  --quarantine path/to/retained/quarantine
```

Both surfaces evaluate manifest authority without modifying it. Human output
uses UTC timestamps; JSON fields such as `createdAtUtc` are UTC ISO-8601
timestamps. `list` includes invalid sibling directories as `ATTENTION` / JSON
`kind: "invalid"` entries rather than silently claiming that no quarantine
exists. Its valid **human** rows show lifecycle, path, selected authority,
repair guidance when needed, and cleanability; its valid **JSON** rows provide
the stable summary fields `runId`, `createdAtUtc`, `entryCount`, `path`,
`lifecycle`, `cleanable`, `recoveryRequired`, `journalRevision`, and
`payloadSha256`. Transaction detail, the authority name, repair action, and the
canonical manifest are **inspect-only** fields. `inspect` renders that complete
selected-authority evidence in both human and JSON formats. A repair-required
journal is still not repaired by either command: repair is a separate locked
mutation and must revalidate authority first.

### Quarantine clean: recoverable logical removal

Preview the exact evidence set before any clean attempt:

```bash
flutter_pruner quarantine clean <run-id> --dry-run --project path/to/project
flutter_pruner quarantine clean --all --dry-run --project path/to/project --format json
```

The plan records canonical bases, stable root identities, retained
destinations, complete no-follow tree hashes, authoritative manifest
revision/checksum, and a versioned fingerprint. An interactive `--all`
execution requires typing the displayed phrase
`clean-all <target-count> <12-hex-prefix>`; a non-interactive or JSON `--all`
execution requires the whole value with
`--confirm-clean-fingerprint <versioned-fingerprint>`. A mismatch is stale
evidence and exits `2`, so generate a fresh dry run. A targeted clean keeps its
existing positional syntax:

```bash
flutter_pruner quarantine clean <run-id> --project path/to/project
```

Production clean never recursively deletes the selected run. It anchors the
quarantine base with a native filesystem capability, durably records intent,
and moves each exact run without replacement into:

```text
<quarantine-base>/.clean-retained/v1/<operation-id>/runs/<run-id>
```

The move is identity-bound and crash-recoverable, but clean-all remains ordered
and non-atomic. Physical bytes remain on the same filesystem and no disk space
is reclaimed. A success receipt includes the operation ID, retained path, and
exact restore command. There is no purge or automatic-expiry command.

On restart, Flutter Pruner reconciles only exact states. A reviewed object still
at its active name terminalizes an intent that never moved; the same object at
its retained destination is committed only after its full tree digest matches.
Both-present, both-absent, reused names, collisions, content drift, unreadable
authority, or ambiguous native outcomes remain `recoveryRequired` and block a
new clean mutation.

Read retained authority or restore one run explicitly:

```bash
flutter_pruner quarantine retained list --project path/to/project
flutter_pruner quarantine retained inspect <operation-id> --project path/to/project
flutter_pruner quarantine retained restore <operation-id> <run-id> --project path/to/project
```

Restore revalidates retained identity and the complete tree digest, then uses
the same no-replace native move in reverse. An existing active name is a
collision and neither object is overwritten. Do not use an older Flutter
Pruner destructive clean against a quarantine base containing
`.clean-retained`.

`CLEAN-TOCTOU-1` is resolved only through release admission that binds the exact
candidate commit to hosted Linux `renameat2`, macOS `renameatx_np`, and Windows
NTFS conformance evidence. A missing, stale, skipped, or mismatched platform
artifact still blocks release. This gate is not operator-waivable and does not
change the local retained-byte semantics above.

### Restore one run

```bash
flutter_pruner rollback <run-id> --project path/to/project
```

Use `rollback <run-id> --clean` only when restoration has completed and the
active quarantine should be moved into retained recovery storage. It does not
delete bytes or reclaim disk space. Keeping the active quarantine until the
project has been reviewed remains the simplest recovery posture.

### If recovery is required

`recoveryRequired` means Flutter Pruner could not prove a fully authorized
terminal result. The uncertainty can concern working-copy bytes, the verifier,
retained run-original authority, or journal terminalization—even when the
transcript says original bytes were restored. Stop mutation and follow the
transcript's exact typed next action, normally inspect the retained quarantine.
Do not retry rollback, apply, or clean unless that transcript explicitly
permits it.

An interrupted managed process whose tree termination is unconfirmed is also a
recovery concern, not a normal cancellation result. Preserve the quarantine and
follow the report or recovery transcript before starting any new verifier or
mutation.

The transcript records uncertainty rather than presenting a partial success.
Only its typed state can say whether this run retained mutation, restored
original bytes, or left the working copy unknown.

### Read a rollback recovery transcript

`ROLLBACK RECOVERY REQUIRED` is a typed state report, not a generic retry
prompt. It distinguishes: no project bytes changed; original bytes restored;
restore outcome unknown; restored bytes invalidated before journal
terminalization; and authority snapshot failure before the working copy could
be revalidated. It likewise distinguishes a verifier that was not started,
failed to match its recorded baseline, threw before complete evidence, may
still be alive, or completed but could not authorize terminalization after
authority drift. The transcript also states whether quarantine is preserved,
recovery-required, authority-corrupt, or retained for recovery; and whether
optional `--clean` was not requested, not attempted, preserved by validation,
retained, or requires retained-journal recovery. Legacy `removed` and
`outcomeUnknown` values remain readable for older journals but are not emitted
by the production logical-clean path.

When the verifier process tree may still be alive, do **not** run `apply`,
`rollback`, or `quarantine clean`. Confirm termination independently, then use
the suggested `quarantine inspect` action. For ordinary argv (including spaces,
quotes, `$()`, backticks, semicolons, and ampersands), the renderer emits exact
arguments using host-appropriate POSIX or PowerShell quoting; it does not
substitute a display-safe path. Only terminal-unsafe controls, bidi controls,
or Unicode line separators switch the renderer to an exact JSON argv array and
an explicit `invoke without a shell` instruction. Decode and invoke that argv
directly; never reconstruct hostile path data through a shell. After a verified
rollback without `--clean`, the suggested targeted clean command is only a
follow-up for retained verified evidence; review a fresh clean dry run first.

The recovery header, typed state, certainty, and allowed next action map as
follows. `inspect` means inspect the retained run before another action; the
command supplies its exact suggested argv.

| Failure class | Typed state and mutation certainty | Exact next action |
|---|---|---|
| Manifest read, baseline evidence, selected-project mismatch, or failure to mark recovery-required before restore | Working copy `unchanged`; verification `notStarted`; quarantine `preserved` | `inspect` |
| Working-copy conflict or restore-phase failure before bytes mutate | Working copy `unchanged`; verification `notStarted`; quarantine `recoveryRequired` | `inspect` |
| Restore stopped after mutation | Working copy `outcomeUnknown` (project bytes may be partial); verification `notStarted`; quarantine `recoveryRequired` | `inspect` |
| Verification did not match baseline or threw before complete evidence | Working copy `originalBytesRestored`; verification `failed` or `exception`; quarantine `recoveryRequired` | `inspect` |
| Verifier termination unconfirmed | Working copy `originalBytesRestored`; verification `terminationUnconfirmed`; quarantine `recoveryRequired`; clean is not attempted | Independently confirm termination, then `inspect`; do not mutate first |
| Retained authority snapshot drift | Working copy `notRevalidatedAfterAuthorityFailure`; completed verification cannot authorize terminalization; quarantine `authorityCorruptRecoveryRequired` | `inspect` |
| Working-copy drift before terminalization | Working copy `restoredStateInvalidated`; prior verification `invalidatedByWorkingCopyRevalidation`; quarantine `recoveryRequired` | `inspect` |
| Terminalization precondition rejected or journal persistence failed | Working copy `originalBytesRestored`; verification `verified`; quarantine `recoveryRequired` | `inspect` |
| Verified rollback with `--clean` validation failure | `ROLLBACK COMPLETE WITH CLEANUP FAILURE`; project restore and verification are verified; quarantine is `preserved` | `list`, then `inspect` surviving evidence |
| Verified rollback with retained-move or journal failure | `ROLLBACK COMPLETE WITH CLEANUP FAILURE`; project restore and verification are verified; quarantine/clean is `recoveryRequired` and physical bytes are preserved wherever observed | Inspect the retained operation; do not retry clean blindly |

`ROLLBACK COMPLETE WITH CLEANUP FAILURE` is different from a failed rollback:
the project restore and verifier were successful, but logical quarantine clean
either failed validation before its move or could not prove a terminal retained
journal state. Durable intent is inspected on the next mutation attempt and is
terminalized automatically only when exact identity and tree evidence match;
otherwise inspect retained evidence and do not retry blindly.

### Rollback limits

For regular files, rollback restores captured bytes and POSIX permission bits
where the platform exposes them. It does not restore:

- extended attributes;
- ACLs;
- ownership (`uid`/`gid`);
- hard-link topology.

Use version control or a filesystem backup whenever those properties matter.
The transaction model protects documented process and path-race boundaries; it
is not a universal filesystem or sudden-power-loss transaction.

## Important analysis limits

- Static analysis can prove known references, but the absence of a runtime
  observation cannot prove that something is unused.
- Custom callback registries, reflection-like behavior, external deep links,
  platform manifests, and dynamic asset paths require explicit modeling or
  project policy.
- Built-in callback boundaries cover
  `PluginUtilities.getCallbackHandle`, `Isolate.spawn`, and
  `Workmanager.initialize`; custom registries remain a boundary.
- Generated-file provenance is evidence, not liveness. Generated uncertainty
  retains affected source rather than granting deletion authority.
- Package analysis cannot discover unknown external consumers.
- Source-byte totals are not release binary-size estimates.

Resolve uncertainty by improving configuration, adding a supported adapter, or
leaving the finding in `REVIEW`. Do not widen `SAFE` to obtain more findings.

## Common problems

| Symptom | What to do |
|---|---|
| “Run `flutter_pruner init`” | Initialize the selected project and review its configuration |
| `ANALYSIS LIMITED` | Resolve the listed target, parser, adapter, or blocker evidence |
| Package apply is refused | Keep audit-only `package` mode or explicitly choose the intended local boundary |
| Report collision | Choose an absent output path or use the automatic unique destination |
| `recoveryRequired` | Stop mutation; follow the transcript's typed next action—normally inspect, never retry by default |
| Report is too sensitive to share | Sanitize it or reproduce the issue with a public fixture |

## Related documentation

- [Project configuration](flutter_pruner.yaml.md)
- [Structured run reports](run-report.md)
- [Architecture](architecture.md)
- [Graph model](graph-model.md)
- [Confidence model](confidence-model.md)
- [V2 adapter behavior](v2-adapters.md)
- [Contributor guide](../CONTRIBUTING.md)

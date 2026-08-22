# Release Blocker Resolution Design

**Status:** Approved for implementation on 2026-08-22.

**Scope:** Resolve the hostile report-persistence race, the JSON v3 context
identity asymmetry, and the blocked O3/O4 corrected-oracle chain without
weakening fail-closed graph, confidence, apply, quarantine, or rollback
behavior.

## Safety authority

1. A pathname, token, hash, `stat`, or preceding identity comparison is an
   observation. It never authorizes a later rename, replacement, truncation,
   restoration, or deletion.
2. Report persistence may create new immutable objects only. It must not
   overwrite an existing regular file, empty file, link, reparse point, or
   directory.
3. Exclusive creation and all reads/writes use the same retained object
   handle. Reopening the object by pathname is forbidden.
4. Report objects are observations. Quarantine `manifest.json` remains the
   only apply/rollback authority.
5. A report object is not committed merely because its path exists. Authority
   begins only when an immutable commit record validates the complete object
   set by exact path, byte length, and SHA-256.
6. Ambiguity retains evidence and fails closed. Persistence and recovery never
   delete or rewrite an ambiguous artifact.
7. `REPORT READY` is emitted only after the commit record and every referenced
   object validate.
8. Unsupported platform, filesystem, path, or identity semantics fail before
   analysis, and before any apply mutation when persistence is required.

## Immutable report store

Default reports use an append-only store:

```text
.flutter_pruner/reports/store/
  objects/
    scan-<run-id>.json
    scan-<run-id>.html
    apply-<run-id>-<sequence>.json
    apply-<run-id>-export.html
  commits/
    <run-id>-<sequence>.commit.json
```

All generated names are single path components derived from validated run IDs,
roles, and sequence numbers. User strings never become store path components.

An explicitly selected exact `--output` path is single-assignment: both the
object and its adjacent commit record must be absent. Recurring automation must
use a run-ID template, an output directory, or the actual path reported by the
CLI. Existing final symlinks/reparse points are rejected. No unsafe overwrite
escape hatch is provided.

### Commit record schema v1

```json
{
  "magic": "flutter_pruner_report_commit",
  "schemaVersion": 1,
  "runId": "20260822T...-...",
  "sequence": 1,
  "command": "scan",
  "state": "committed",
  "completedAtUtc": "2026-08-22T00:00:00.000000Z",
  "objects": [
    {
      "role": "primary",
      "relativePath": "objects/scan-<run-id>.json",
      "format": "json",
      "reportSchemaVersion": 3,
      "byteLength": 1234,
      "sha256": "<64 lowercase hex>"
    }
  ],
  "payloadSha256": "<64 lowercase hex>"
}
```

`payloadSha256` hashes canonical compact JSON of every preceding field in the
listed key order, excluding `payloadSha256`. Validation requires exact keys,
canonical ordering, exact filename/run/sequence agreement, unique roles and
paths, confined object paths, regular no-follow objects, exact byte lengths,
and exact SHA-256 digests. Partial or malformed commit records are ignored.

Multiple outputs from one apply state transition share one commit record. A
valid commit is all-or-none authority for that object set.

### Persistence lifecycle

1. Freeze an anchored report-directory capability before analysis or apply.
2. Exclusively create each object relative to that capability.
3. Stream UTF-8 through the retained handle while counting bytes and hashing.
4. Flush, rewind, and read back through the same handle; length and digest must
   match the streamed values.
5. Exclusively create and write the commit record through another retained
   handle.
6. Flush and parse the commit record, then validate all objects through
   retained or newly anchored no-follow handles.
7. Revalidate directory reachability/identity and only then emit READY.

Object, commit, flush, close, validation, or reachability failures leave the
artifacts untouched and return a sanitized recovery-required result. The first
write/flush failure remains primary; close failures are secondary.

Recovery is read-only classification into committed, orphaned, partial,
corrupt, foreign, or unreachable. Storage reclamation is a separately
authorized, quiescent maintenance workflow and is not part of this design.

## Native capability boundary

Production code exposes capabilities rather than general filesystem mutation:

```dart
abstract interface class AnchoredReportDirectory {
  String get canonicalPath;

  Future<ExclusiveReportObject> createExclusive(String leaf);
  Future<ExistingReportObject> openExisting(String leaf);
  Future<void> verifyReachable();
  Future<void> close();
}

abstract interface class ExclusiveReportObject {
  Future<void> write(List<int> bytes);
  Future<void> flush();
  Future<void> rewind();
  Future<List<int>> read(int maximumBytes);
  Future<ReportObjectIdentity> identity();
  Future<void> close();
}
```

The interface deliberately exposes no rename, replace, unlink, recursive
delete, restore, or advisory lock.

- Linux and macOS use directory-relative `openat` with exclusive, no-follow,
  close-on-exec creation and retain the returned descriptor.
- Windows retains a canonical root-to-parent handle chain, rejects mutable
  reparse points, creates with `CREATE_NEW`, retains restrictive sharing, and
  identifies files with stable file IDs.
- Direct `dart:ffi` bindings target libc, libSystem, and Windows system DLLs so
  the declared Dart 3.9 floor remains unchanged. There is no compiled helper,
  build hook, or bundled native library.
- Initially accepted filesystems are macOS APFS, Linux ext4/tmpfs, and Windows
  NTFS. Others fail preflight until their process-level conformance evidence is
  added.

This design promises fail-closed process recovery. It does not claim sudden
power-loss durability until file and containing-directory metadata flushing is
proven on every supported filesystem.

## Scan and apply integration

`scan` creates one report object and one commit. A formatter or persistence
failure never creates a valid commit and never emits READY.

`apply` must use the same substrate for canonical quarantine reports and
external exports. Each material report state is immutable and receives a
monotonic sequence. A later failure report creates a new object and commit; it
never rewrites an earlier report. Canonical and external outputs for the same
state form one batch commit. Quarantine manifest state remains authoritative
if report persistence later fails.

The existing path-based writer inside `apply_command.dart` must be removed
before the writer blocker can be resolved.

## Execution-context identity

Production owns one private identity grammar; the independent benchmark oracle
implements the same documented wire grammar separately.

- Configured graph keys use `app:<suffix>`. `BuildTarget.name` remains its
  public raw/logical value and uses prefix-if-absent derivation.
- An auxiliary key uses `aux:<test|runtime|external>:<suffix>`.
- Suffixes are nonempty, contain no C0/DEL controls, and auxiliary suffixes do
  not begin with `app:` or `aux:`.
- `unattributed` is an integrity bucket, never an execution target.
- Full target tuples remain intact. Identity keys never replace platform,
  entrypoint, flavor, defines, environment, completeness, reason, or source
  target fields.
- Duplicate derived configured IDs and conflicting auxiliary definitions fail
  closed; they never use last-write-wins behavior.
- JSON v3 validates the complete configured/auxiliary/integrity context set
  before writing any byte.
- Public constructor signatures and valid JSON v3 wire values remain stable.
  JSON v2 bytes remain frozen.

The benchmark oracle must not import the production validator. Production
writer-to-independent-parser tests prove compatibility, not ground truth.

## Corrected-oracle remediation

The retained O3/O4 code is characterization evidence, not an accepted baseline.
Remediation uses fresh bounded gates:

1. `C0`: production context identity, aggregate uniqueness, and v3 preflight.
2. `O3-R1`: asset/duplicate finding states and inventory count/value bounds.
3. `O3-R2`: canonical relative-POSIX paths and graph-observation membership.
4. `O4-R1`: sibling-package ownership/back-edges/callbacks, invalid public
   owners, and symlink evidence.
5. `O4-R2`: constant pragma/full executable identity, retained-to-exact
   upgrades, and repeated show/hide semantics.

O5/O6 cannot consume O4 until both O4 gates pass fresh review. O7 waits for
accepted O3, O4, O5, and O6. Only O7's independent one-to-one join may produce
an accepted confusion matrix or deletion-authority claim.

AppFlowy and ServerBox must be recaptured at the accepted exact tool SHA with
project/config/package-config/report/root-manifest hashes. Existing observations
must not be relabeled as accepted evidence.

## Release-blocker evidence

The registry distinguishes at least:

- `report-writer-hostile-path-race`;
- `json-v3-context-integrity-asymmetry`;
- `corrected-oracle-o3-o4-incomplete`.

A status string alone cannot resolve a blocker. Every resolved entry declares
exact expected test IDs, required platforms, and required artifact hashes.
Verification rejects missing, deleted, skipped, or unobserved tests.

The writer blocker remains active until real child-process tests pass on the
supported OS/filesystem matrix for parent swaps, symlink/reparse insertion,
foreign collisions, short/interrupted writes, before/after errors, hash
mismatch, commit corruption, process death at every boundary, batch atomicity,
and concurrent CLI writers. Foreign bytes, hash, type, mode, pathname, and file
identity must remain unchanged.

The context blocker resolves only after C0's constructor, matrix, formatter,
and production-CLI-to-independent-parser gates pass. O3/O4 remain separately
active until their accepted artifacts exist.

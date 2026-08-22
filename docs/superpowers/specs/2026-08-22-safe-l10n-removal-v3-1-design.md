# Safe l10n Removal V3.1 Design

Date: 2026-08-22
Status: Approved

## Summary

V3.1 will make unused Flutter `gen-l10n` keys removable without weakening
Flutter Pruner's fail-closed confidence model. The rollout is intentionally
split:

1. **Stage 1 — internal mutation evidence.** Build and exercise the complete
   ARB editing, isolated generation, reconciliation, and verification pipeline.
   It produces internal evidence only. Public findings remain `REVIEW`, no
   l10n action is proposed, and the existing apply/quarantine path is unchanged.
2. **Promotion — public actionability.** After Stage 1 meets its evidence gate,
   add a family-level l10n action and atomic publication through quarantine.
   This work receives a separate implementation plan and approval.

This document fixes the architecture and safety contract for both stages. The
implementation plan created immediately after this design covers Stage 1 only.

## Context

The V2 l10n adapter already models configured ARB messages, generated
accessors, semantic Dart references, and scoped uncertainty. Its findings are
deliberately review-only. The current action capability and action builder know
how to mutate assets and selected Dart declarations/libraries, but they have no
operation that can safely edit a complete ARB family and reconcile generated
Dart output.

Deleting an ARB key is not a single-file text edit. A safe operation must:

- remove the message and optional `@message` metadata wherever present across
  the configured locale family;
- preserve every unrelated ARB byte;
- run the target project's exact `gen-l10n` semantics;
- account for every generated output byte as part of the same logical change;
- fail before live mutation if input, output, configuration, resolution, or
  toolchain identity is uncertain; and
- restore exact prior bytes and modes if a promoted transaction fails.

Flutter loads `l10n.yaml` from the project and uses it as the authoritative
configuration for `flutter gen-l10n`. Therefore output relocation through
ad-hoc command-line overrides is not a safe isolation boundary. Generation
must run in a project-shaped staging root, never in the selected project before
quarantine owns the mutation.

## Goals

- Prove a byte-preserving ARB family edit for an exact set of selected keys.
- Prove generated output using the selected project's configuration and exact
  Flutter toolchain in isolated staging.
- Distinguish pre-existing stale generated output from the delta caused by the
  selected removal batch.
- Produce deterministic, typed, reproducible internal evidence in Stage 1.
- Preserve all existing V2 scan, confidence, report, CLI, apply, and rollback
  behavior during Stage 1.
- Define the later atomic publication boundary for application and
  package-internal modes without enabling it prematurely.

## Non-goals

- General-purpose JSON editing or JSON comment/trailing-comma support.
- Editing ICU messages, placeholder metadata, locale identifiers, or l10n
  configuration values.
- Resolving or changing dependencies during generator/domain staging or a
  measured candidate transaction. Corpus provisioning may run an explicit,
  unmeasured offline resolution step before baseline identity is captured; no
  resolution is allowed after that capture.
- Treating generated-code provenance as independent liveness evidence.
- Enabling l10n mutation in package mode.
- Adding new adapters or changing go_router/GetIt behavior.
- Optimizing staging with hard links, symlinks, shared mutable caches, or
  concurrency before correctness evidence exists.
- Publishing, releasing, or changing the public report schema as part of
  Stage 1.

## Decisions

The approved product and safety decisions are:

- The rollout is staged.
- Stage 1 is internal-only; it adds no public CLI flag or report field.
- A batch contains every selected key in one configured ARB family and is
  atomic at the family boundary.
- ARB files are edited at byte-token spans and are never reserialized or
  formatted.
- `gen-l10n` runs only in isolated project-shaped staging.
- Baseline and candidate generation use independent materialized roots created
  from the same immutable snapshot.
- Generated Dart outputs are part of the later transaction and rollback
  contract; they are never regenerated as rollback.
- Promotion may support application `SAFE` and package-internal `HIGH` with the
  existing explicit external-consumer acknowledgement. Package mode remains
  scan-only.
- The present implementation plan stops after Stage 1. Promotion requires its
  own plan after the evidence checkpoint.

## Architecture

### High-level flow

```text
Existing V2 l10n scan (unchanged, REVIEW-only)
        |
        v
Internal candidate selector
        |
        v
L10nFamilySnapshot
        |-------------------------------|
        v                               v
baseline staging                 candidate staging
original ARBs                    byte-edited ARBs
        |                               |
flutter gen-l10n                flutter gen-l10n
        |                               |
        |---------------|---------------|
                        v
             output reconciliation
                        |
                        v
              staged verification
                        |
                        v
       L10nEvidenceVerdict(accepted/rejected)
```

Stage 1 has no edge from `L10nEvidenceVerdict` to `ApplyCommand`,
`RemovalPlanner`, `FindingActionBuilder`, `QuarantineManager`, or any public
formatter. The internal accuracy harness is its only orchestration entrypoint.

Promotion later introduces a fresh runtime staging pass followed by a
family-level atomic transaction. An evidence artifact from an earlier run is
never publication authority.

### Component boundaries

#### `L10nGenerationConfig`

This is an action-readiness configuration model layered beside the existing
scan-oriented `L10nConfig`. Stage 1 must not change how the V2 adapter
classifies current projects.

`L10nGenerationConfig` records:

- the exact `l10n.yaml` state, bytes, path, and SHA-256 when present;
- the effective values and defaults for every `gen-l10n` option supported by
  configuration schema v1;
- all input paths, including the ARB directory, template, and optional
  `header-file`;
- all output paths/roots, including the base localization library, one
  generated language library per distinct generator-selected base language,
  and optional `untranslated-messages-file`;
- options that affect generated bytes, such as formatting, escaping, deferred
  loading, nullable getters, named parameters, headers, and output class; and
- the toolchain compatibility identity used to interpret those options.

Configuration schema v1 supports exactly Flutter 3.38.7, 3.41.5, and 3.44.1,
the three target toolchains of the corrected natural corpus. The semantic
version selects an explicit option/output-rule table, while the exact Flutter
framework/engine revision and bundled Dart identity remain part of every run
identity. Any other Flutter version is `unsupportedConfiguration`; there is no
nearest-version fallback. Adding a version requires a new versioned table,
real-generator fixtures for every supported option/output shape, and refreshed
natural-project evidence.

An unknown option, unsupported option/toolchain combination, absolute I/O
path, non-regular file, symlink, or canonical path outside the selected project
rejects action readiness. `synthetic-package: true` remains unsupported.

The raw YAML is copied unchanged into staging. V3.1 does not translate YAML
into command-line overrides or rewrite its paths.

#### `ArbDocument`

`ArbDocument` is a dedicated byte-level parser/editor, separate from
`ArbInventory`. The inventory remains the semantic source for scan findings and
blockers; the document model owns mutation precision.

```dart
final class ArbDocument {
  final ImmutableBytes source;
  final List<ArbMember> members;
  final List<ArbDelimiter> delimiters;

  static ArbParseResult parse(Uint8List bytes);
  ArbEditResult removeMessages(Set<String> keys);
}
```

`ImmutableBytes` owns a defensive copy, offers read-only indexed access, and
returns a new copy when bytes must cross an API boundary. Neither a caller nor
an edit result can mutate the snapshot's backing storage. An `ArbMember` span
runs from the opening quote of its key through the final byte of its value; it
excludes surrounding whitespace and commas. An `ArbDelimiter` owns exactly one
comma byte and no whitespace.

The parser:

- accepts valid UTF-8 with an optional UTF-8 BOM;
- scans ASCII JSON structure directly to obtain byte offsets;
- decodes key string tokens using JSON rules, so literal and escaped-equivalent
  keys compare by decoded value;
- records top-level member and comma spans in source order; and
- validates the complete BOM-stripped document with `jsonDecode` before
  returning a usable document.

It rejects invalid UTF-8, UTF-16 BOMs, NUL, comments, trailing commas,
malformed JSON, a non-object top level, and duplicate decoded top-level keys.
A parse failure returns a typed failure and never a partial document.

#### `L10nFamilySnapshot`

The snapshot is immutable and binds one configured family plus one exact set of
selected l10n node IDs. It records canonical project-relative paths, roles,
original bytes or explicit absence, SHA-256, and POSIX mode where applicable
for:

- `pubspec.yaml`, `pubspec.lock`, and `l10n.yaml`;
- every configured ARB file and the template;
- an optional header file;
- the complete generated output family and untranslated sidecar;
- `.dart_tool/package_config.json` and package graph state when available; and
- every project-owned Dart source in the scanner's complete analyzer-root
  closure, plus each manifest/configuration input explicitly required by the
  fixed staged l10n verification policy.

Stage 1 does not copy an arbitrary repository tree. If the analyzer-root
closure or a required verification input cannot be enumerated without guessing,
the snapshot is rejected. Dependency sources named by package configuration are
read from their existing owned/cache locations and are never copied or mutated.

The snapshot also records selected finding/node IDs, decoded message keys,
configuration identity, dependency-resolution identity, and toolchain identity.

Every selected node must be a canonical template message in exactly this
family. Pseudo-keys beginning with `@`, duplicate selections, cross-family
selections, or a selected key absent from the template reject the snapshot.

#### `L10nArbMutationPlanner`

For each document, `removalMembers` is the union of selected decoded message
keys present in that document and each corresponding decoded `@message`
companion that is present. The planner removes exactly `removalMembers`. A
locale may legitimately omit the message. An orphan companion or other
inventory/document ambiguity rejects the whole batch.

All removal ranges are computed against the original bytes. The planner groups
adjacent members in `removalMembers` into runs:

- when a run has a following surviving member, it removes the members in the
  run and each delimiter after those members, leaving the delimiter before
  the run to connect the surviving neighbors;
- when a run is at the end, it removes the delimiter before the run and all
  delimiters inside it; and
- when every member is removed, it removes all member/delimiter spans while
  preserving braces, BOM, and unrelated whitespace.

The implementation coalesces non-overlapping spans and copies all remaining
byte ranges once. It does not perform sequential edits, because shifting offsets
would weaken the snapshot proof.

Postconditions require:

- every selected key and present companion is absent;
- every unselected member's exact byte token remains unchanged;
- `@@locale` and unrelated `@`/`@@` members remain unchanged;
- the result parses as a valid top-level JSON object; and
- no duplicate, orphan, or new semantic issue is introduced.

Whitespace made redundant by removal may remain. Byte preservation is more
important than cosmetic formatting.

#### `L10nStageMaterializer`

The materializer creates two private system-temporary directories outside the
selected project: `baseline` and `candidate`. Each is a minimal project-shaped
copy of the same `L10nFamilySnapshot`.

Materialization rules:

- copy bytes into new regular files; never hard-link or symlink;
- preserve required relative paths and recorded file modes;
- create only known directories beneath the staging root;
- reject any canonical containment or collision uncertainty;
- never run dependency resolution; and
- clean both roots after evidence collection.

A cleanup failure yields a rejected verdict. A surviving staging directory is
diagnostic residue only and is never trusted as authority for a later action.

#### `L10nGenerator`

`L10nGenerator` is a narrow interface implemented by an argv-only process
runner and replaceable with a fake in unit tests. Toolchain selection is
resolved and frozen in the original project before either staging root exists.
The resulting typed command is:

```text
canonicalFlutterExecutable
generationArgs
directVersionProbeArgs
selectorFileHashes
originalSelectionProbeEvidence
environmentOverrides
```

The staging process always invokes the canonical Flutter binary directly. It
never asks FVM or another current-directory-sensitive wrapper to select an SDK
from inside staging. For a wrapper-selected project, the resolver fingerprints
`.fvmrc`, `.fvm/fvm_config.json`, or another explicitly supported selector,
proves the wrapper's delegated Flutter identity in the original project, maps
it to a pre-provisioned canonical binary, and requires the direct binary probe
to match the delegated framework/engine/Dart identity. It does not install or
download an SDK. An absent/unknown selector or unprovable mapping is
`toolchainUnavailable`.

Its production implementation uses `ManagedProcessRunner` semantics: positive
timeout, bounded stdout/stderr, confirmed process-tree termination, and
process-tree resource observation. Stage 1 extends `ProcessExecutionRunner`
with default-preserving typed `environmentOverrides` and
`includeParentEnvironment` parameters and returns sampled peak RSS evidence;
existing callers use `includeParentEnvironment: true` with no overrides and
preserve current behavior. The l10n runner resolves the executable before
launch, fixes non-secret `CI`, analytics-suppression, and locale overrides,
does not replace `HOME` or `PUB_CACHE`, and includes its sorted override map in
the command identity.

The executable and arguments are explicit. Toolchain identity is the SHA-256 of
the canonical Flutter executable/SDK realpaths, selector-file hashes, original
selection probe, direct version-probe arguments/results, and exact bounded
stdout/stderr bytes separated by NUL bytes. The working directory is the
corresponding staging root.

When `l10n.yaml` exists, the generator invokes the command without attempting
to override YAML I/O fields. The runner does not invoke a shell or `pub get`.
Its environment disables analytics and preserves only the environment needed
to locate the already selected toolchain and dependency cache.

Non-zero exit, timeout, output truncation, or unconfirmed process-tree
termination rejects the run.

#### `L10nOutputReconciler`

The reconciler captures content/type/mode inventories immediately before and
after each generator invocation. The generation allowlist is computed before
the process starts from the typed configuration, ARB locale inventory, and the
supported toolchain's output-family rules.

Generator-created, modified, deleted, non-regular, or path-escaping content
outside the declared generated Dart family and optional untranslated sidecar
is an unexpected write and rejects the verdict. An output path whose ownership
or role cannot be proved rejects the family; V3.1 does not guess from a filename
suffix alone.

The baseline run uses unmodified inputs. Its path set, regular-file types,
bytes, and POSIX modes where applicable must reproduce the selected project's
current managed output state. If an expected generated output is absent live
but baseline generation creates it, the state is stale and rejects. If an
optional output is absent both live and after baseline generation, absence is
reproduced. A mismatch is `staleGeneratedOutput`, not part of the candidate
delta.

An existing file that claims generated provenance or occupies the configured
family namespace but is not in the precomputed expected output set also rejects
as stale/ambiguous even when the generator leaves it untouched. An unrelated
file in the same output directory may remain only when ownership outside the
generated family is proved and its type/bytes/mode stay unchanged.

The candidate run starts from an independent copy of the same snapshot, applies
the ARB edit, and then generates. Only the baseline-to-candidate difference is
the proposed generated change set.

Initial Stage 1 accepts replacements of the reproduced output set only. A new
or deleted candidate output is exercised as rejection evidence. The later
transaction format can represent explicit absence, but promotion cannot enable
creation/deletion until a separate supported-output fixture proves its path and
mode policy. A newly enabled POSIX output uses normalized mode `0644`, never the
staging process's ambient umask.

Tool-owned cache changes produced later by staged analysis are isolated from
generation reconciliation and are never publishable. Any verifier mutation of
ARB/config/generated source paths rejects the verdict.

#### `L10nStageVerifier`

Stage 1 uses a fixed internal l10n verification policy, not an arbitrary project
test policy. This keeps the materialized closure finite and prevents minimal
staging from becoming an undeclared full-repository copy. Baseline and candidate
run the same versioned policy, whose exact steps and hash are recorded.

Verification combines domain postconditions with the existing analyzer/graph
seams:

- reparse every candidate ARB and recheck exact removal/non-removal membership;
- verify the selected generated accessors are absent;
- verify retained message members still resolve through the generated family;
- reject dangling graph endpoints or new l10n blockers;
- rerun the analyzer-backed l10n scan over the materialized analyzer-root
  closure without dependency resolution;
- compare the versioned policy hash, analyzer/root-coverage identity, and
  toolchain identity between baseline and candidate; and
- ensure verification did not mutate any publishable input/output path.

Dependency packages may be read through the copied package configuration, but
the verifier does not resolve or update them. Full analyze/test policies are
exercised separately on disposable, complete corpus copies during
natural-project evidence. Every supported Flutter analyze/test command must
carry `--no-pub`; opaque/custom commands need a separately proven no-resolution
contract or are rejected for l10n evidence. Promotion applies the same rule to
its live candidate policy instead of silently using a dependency-resolving
default.

#### `L10nEvidenceVerdict`

The Stage 1 output is an internal immutable value:

```text
status: accepted | rejected
reasonCodes: stable, deterministically ordered set
familyFingerprint
selectionFingerprint
configurationIdentity
packageResolutionIdentity
toolchainIdentity
baselineInventoryHashes
candidateInventoryHashes
mutationSummary
verificationSummary
timingAndResourceMetrics
```

The initial exhaustive rejection-code enum is:

- `scanBlockerPresent`
- `invalidSelection`
- `unsupportedConfiguration`
- `invalidInputPath`
- `arbFamilyIncomplete`
- `arbParseFailure`
- `materializationFailed`
- `sourceDrift`
- `packageResolutionDrift`
- `toolchainUnavailable`
- `toolchainDrift`
- `editPostconditionFailed`
- `baselineGenerationFailed`
- `staleGeneratedOutput`
- `candidateGenerationFailed`
- `generatorOutputTruncated`
- `generatorTerminationUnconfirmed`
- `unexpectedStageWrite`
- `outputFamilyAmbiguous`
- `candidateVerificationFailed`
- `cleanupFailed`
- `internalFailure`

An accepted verdict has no reason codes. A rejected verdict has at least one.
Codes are ordered by enum declaration, while stage/path-specific detail stays
in deterministic evidence fields rather than creating free-form identities.

Stage 1 stores hashes, identities, metrics, reason codes, and bounded process
evidence in the internal accuracy artifact. It does not serialize source bytes
into public reports or expose a public schema commitment.

## Stage 1 Orchestration

The only Stage 1 caller is an internal accuracy harness under
`benchmark/accuracy/`. Its execution sequence is:

1. Run the unchanged scanner and select exact l10n candidates from its REVIEW
   findings.
2. Require a valid scan inventory with no blocker affecting a selected node or
   its family.
3. Load the stricter action-readiness configuration.
4. Build and hash the immutable family snapshot.
5. Parse every ARB with `ArbDocument` and build candidate replacement bytes.
6. Materialize independent baseline and candidate roots.
7. Run baseline generation and prove current managed output reproducibility.
8. Install only candidate ARB bytes in the candidate root and run candidate
   generation.
9. Reconcile the complete baseline/candidate delta.
10. Run the fixed domain verification policy in baseline and candidate staging.
11. Revalidate source/config/resolution/toolchain identity.
12. Attempt cleanup, fold its result into the verdict, and only then emit the
    final internal verdict and metrics.

At no point does Stage 1 call the live apply workflow or write to the selected
project.

## Stage 1 Public Invariants

Tests must prove all of these invariants:

- l10n findings remain `REVIEW` and `applyEligible: false`;
- l10n findings have no `proposedAction`;
- `ActionCapability` remains unchanged;
- application, package-internal, and package mode outputs remain unchanged;
- CLI arguments and help remain unchanged;
- terminal, JSON, and HTML report schemas/content remain unchanged except for
  already-existing nondeterministic timing fields;
- `RemovalPlanner`, `FindingActionBuilder`, `ApplyCommand`, quarantine
  manifests, rollback, and recovery gain no Stage 1 l10n execution path; and
- normal scan/apply never starts staging or `flutter gen-l10n` for l10n.

## Promotion Architecture

Promotion is not authorized by Stage 1 implementation. After the evidence gate
passes, a separate plan may add the following seams.

### Static action-readiness seam

The current synchronous `FindingGenerator` cannot discover a family-level
capability from only `adapterId` and one `GraphNode`. Promotion therefore adds a
core-owned `StaticActionReadinessResolver` step to `ProjectAnalyzer` after all
adapters and graph integrity finish, but before finding generation.

For built-in l10n nodes, the resolver performs only bounded static work: strict
action configuration loading, family/input/output ownership checks, blocker
projection, deterministic-inverse proof, and family-footprint enumeration. It
does not run Flutter or staging during ordinary scan. It returns an immutable
index keyed by canonical node ID:

```text
adapterId + nodeKind
familyId
configurationFingerprint
bounded mutation footprint identity
deterministic inverse kind
action risk scope
external-consumer exposure
```

`ProjectAnalyzer` awaits this resolver and passes the typed index to
`FindingGenerator`. The core verifies adapter ownership and node kind before an
entry can override the existing core allowlist, so a custom adapter cannot gain
mutation authority by copying metadata. Direct `FindingGenerator` callers with
no index retain current behavior. Stage 1 may exercise the resolver from the
internal harness, but it does not connect the index to production finding
generation.

Physical mutation breadth is not a confidence risk by itself. Promotion splits
the current overloaded scope concept into:

- `MutationFootprint`: the exact logical findings and physical paths owned by
  an atomic unit; and
- `ActionRiskScope`: `boundedSingle`, `boundedFamily`, or `openEnded`.

Existing narrow actions map to `boundedSingle`; existing broad actions map to
`openEnded`, preserving their current `broadRemovalScope` manual risk. A proven
l10n family maps to `boundedFamily`, so touching multiple mechanically derived
files does not add `broadRemovalScope`. Only `openEnded` creates that manual
risk.

### `L10nRemovalBatch`

One batch represents one configured ARB family and the exact selected set of
logical finding IDs. It owns:

- edited template and locale ARB mutations;
- every generated output replacement witnessed in fresh staging; its format
  can later represent a separately evidence-gated creation or deletion;
- original and candidate hashes/modes or explicit absence for every path;
- configuration, package-resolution, and toolchain fingerprints; and
- the complete logical finding ID set exactly once.

Generic same-origin or single-file grouping is insufficient. Locale files and
generated outputs must join the unit mechanically even when they do not appear
as the selected finding's origin.

### Fresh preflight and publication

Promotion runs the staging pipeline again immediately before live mutation. It
does not load an earlier Stage 1 change set. Before publication it revalidates
every live source/output path, type, hash, and mode.

Promotion defines an explicit l10n no-resolution verification default using
the resolved canonical Flutter toolchain: `flutter analyze --no-pub
--fatal-infos` followed by `flutter test --no-pub`. It does not silently reuse
the current dependency-resolving default. A project override is accepted only
when each command has a typed no-resolution contract; otherwise l10n mutation
rejects before quarantine begins.

The workflow then:

1. acquires the normal project mutation lock;
2. begins one V3 quarantine transaction before the first live change;
3. journals every existing file's exact bytes and mode;
4. supports an explicit `absent` before-state in the transaction model, while
   the initial promoted l10n cohort remains replacement-only until creation or
   deletion has its own evidence gate;
5. installs the already-generated ARB and Dart candidate bytes without running
   the generator in the selected project;
6. rescans and executes candidate verification after the complete physical
   write set is installed;
7. commits the transaction only if the complete family passes; and
8. otherwise restores every original byte/mode and removes only files whose
   journaled before-state was absent.

Rollback never runs `gen-l10n`. A candidate collision at a path journaled as
absent, manifest persistence failure, hash drift, verification failure, or
unconfirmed process termination prevents commit and enters the existing
rollback/recovery semantics. There is no partial per-key success.

Logical finding outcome accounting is per transaction's selected finding set,
not per physical file case.

### Confidence and mode policy

Promotion may add a l10n-specific action descriptor/capability only after the
Stage 1 gate passes.

- **Application mode:** a localization key may be reported `SAFE` only when the
  existing graph proves complete application closure, no scoped blocker
  affects it, the l10n family passes static action preflight, and the action
  type is supported. Actual execution still requires a newly accepted staged
  change set; a stale or failed runtime preflight skips/aborts mutation.
- **Package-internal mode:** a key is at most `HIGH`. L10n nodes must explicitly
  carry external-consumer exposure in the typed readiness index so the
  `externalConsumersNotScanned` manual risk and classification reason cannot be
  omitted accidentally. Apply requires the existing explicit user
  acknowledgement, and that manual risk must be the only remaining risk.
- **Package mode:** l10n remains scan-only because external consumers are an
  open world.

The generic package override is not weakened. Dynamic/custom lookup,
malformed or partial ARB input, generated resolver uncertainty, incomplete
root coverage, output ambiguity, or any other scoped blocker remains
disqualifying.

## Error and Recovery Semantics

Stage 1 errors are evidence rejection, never project recovery events, because
the selected project is read-only. The harness must still revalidate scoped
source hashes/modes and project status to prove this invariant.

Promotion distinguishes:

- **pre-mutation rejection:** no quarantine or live write begins;
- **transactional failure:** quarantine owns every affected path and rolls the
  whole family back;
- **recovery-required failure:** rollback completion cannot be proved, so the
  manifest remains authoritative and the existing recovery UX applies.

No error path may silently regenerate, accept a partial family, treat a stale
verdict as current, or write outside project-owned paths.

## Testing Strategy

### Parser and editor tests

Golden byte tests cover:

- first, middle, final, only, adjacent, non-adjacent, and all-member removal;
- compact/pretty JSON, arbitrary valid whitespace, CRLF, final newline, and
  UTF-8 BOM;
- escaped and non-ASCII keys, literal-versus-escaped duplicate collisions,
  nested objects/arrays, escaped punctuation, ICU plural/select text, and
  placeholder metadata;
- adjacent and separated `key`/`@key` pairs;
- `@@locale`, unrelated `@@` fields, unrelated metadata, and locale files that
  omit the selected message; and
- exact reconstruction proving every byte outside removal spans is unchanged.

Parameterized rejection tests cover malformed JSON/escapes, invalid encoding,
comments, trailing commas, duplicate decoded keys, orphan metadata,
locale-only keys, locale identity ambiguity, and stale source hashes.

### Family and staging tests

Fixture tests cover template plus multiple locales, missing locale messages,
plural/select/placeholder messages, custom directories/file/class/header,
optional untranslated output, deferred loading, absent/existing outputs,
stale siblings, symlinks, non-regular files, path escape, and output-family
ambiguity.

Expected outcomes are explicit: baseline-created missing output, generated
stale sibling, candidate output creation, and candidate output deletion reject;
an unrelated proven-owned sibling accepts only when it stays byte/type/mode
identical. Language-output fixtures include multiple regional locales sharing
one generated base-language file.

Process tests use a fake `L10nGenerator` for deterministic non-zero exit,
timeout, truncation, partial writes, unexpected writes, output creation/deletion,
and toolchain drift. A separately gated real Flutter fixture proves the actual
command/config contract.

The fixed Stage 1 verifier is tested against complete and deliberately
incomplete analyzer-root closures. Arbitrary project verification commands are
not silently downgraded or partially run in minimal staging.

### Failure injection

Inject failure before and after snapshotting, materialization, edit, baseline
generation, candidate generation, reconciliation, verification, revalidation,
and cleanup. Every Stage 1 failure must produce a rejected verdict while the
original worktree's scoped bytes, modes, and status remain unchanged.

Promotion tests later inject failure before and after every quarantine state
transition. They must prove all-or-nothing restoration, collision-safe handling
of initially absent files, exact manifest ownership of logical finding IDs, and
no unjournaled generated write.

### Regression tests

Existing l10n adapter tests retain REVIEW-only, non-actionable assertions.
Planner, action-builder, apply, manifest, rollback, and recovery tests must show
no new Stage 1 execution path. Existing V2 semantic counts, blocker identities,
and deterministic output remain unchanged.

## Natural-project Evidence

Stage 1 extends the retained SHA-pinned l10n corpus rather than replacing its
independent oracle. It includes Smooth App, GitJournal, and GSY's
normalized-equivalent ARB input. The original GSY duplicate-key input remains
`ANALYSIS LIMITED` and cannot become action evidence.

Before any Stage 1 production code is written, an independently reviewed and
committed mutation-readiness manifest freezes the expected positive and
negative sets. It labels selected keys, expected ARB member removals,
supported/rejected configuration state, expected family-batch outcome, and
exact allowed rejection reason classes. The manifest is created independently
of `L10nEvidenceVerdict`; its SHA-256 is retained with the run. Changing it
after implementation begins requires a documented oracle correction, design
review, and renewed approval rather than silently changing the denominator.

Evidence records exact repository SHA, Flutter/Dart identity, pubspec/lock,
package configuration, l10n configuration, and oracle version.

For each accepted staged candidate, the harness also installs the witnessed
change set into a disposable complete copy of the pinned corpus project, runs
the corpus's exact predeclared no-resolution verification policy, and restores
the copy. Provisioning may run `flutter pub get --offline` before the baseline
fingerprint is captured; every measured analyze/test command after capture uses
`--no-pub`. This is external mutation evidence, not a live-project Stage 1 write
and not a shortcut into the production apply path.

This produces a separate immutable `CorpusMutationEvidenceOutcome` containing
the candidate/family identity, installed change-set hash, policy hash, complete
command results, before/after managed fingerprints, and `passed`,
`fullPolicyFailed`, `restorationFailed`, or `provisioningFailed`. A passing
internal `L10nEvidenceVerdict` is necessary but not sufficient for this corpus
outcome or the Stage 1 exit gate.

Results are reported in two separate layers:

1. **Static detection:** retain independent TP/TN/FP/FN and prove the V2
   classification result does not regress.
2. **Mutation readiness:** accepted/rejected counts and reasons, candidate keys,
   families, ARB files/spans changed, companion metadata spans changed,
   generated paths enumerated/changed/created/deleted, generator/analyzer/
   verifier outcomes, and original-tree restoration checks.

Each oracle-removable key is exercised independently so a family batch cannot
hide the failing key. A second run removes the complete selected family batch
to prove atomic batch semantics.

The initial non-vacuous positive denominator is all 378 retained
oracle-removable l10n keys: Smooth App 323, normalized GSY 17, and GitJournal
38. The family denominator is three. All 378 individual candidates and all
three family batches must be attempted under their exact target toolchains:
Smooth App 3.38.7 from its repository `.fvmrc`, normalized GSY 3.44.1 from its
repository `.fvmrc`, and GitJournal 3.41.5 from the retained CI-selected
resolution evidence. The historical Smooth mutation run used Flutter 3.44.9;
it remains supporting evidence but cannot satisfy this new target-pin gate.
Failure to provision one pinned project/toolchain blocks the gate; it does not
shrink the denominator. The 2,224 retained used-key negatives must remain
non-candidates, and explicit malformed, blocker, stale-output, and
unexpected-write negative fixtures must reject with their predeclared reason
classes.

## Stage 1 Exit Gate

Stage 1 is complete only when fresh evidence proves:

- zero public l10n `SAFE`/`HIGH` findings and zero l10n proposed actions;
- no public CLI/report/apply/quarantine behavior change;
- no accepted candidate with malformed/partial ARB input, a relevant blocker,
  unresolved/dynamic/generated uncertainty, output ambiguity, source/config/
  resolution/toolchain drift, dangling endpoints, stale generated output, or
  failed baseline/candidate verification;
- zero unexpected staged writes for every accepted candidate;
- zero original-project byte, mode, or status drift;
- accepted eligible keys equal the predeclared 378 of 378 and accepted family
  batches equal three of three;
- disposable complete-copy no-resolution policies pass for all 378 individual
  candidates and all three family batches, with zero full-policy failures and
  381 of 381 proven restorations;
- all 2,224 static negative keys remain non-candidates and every predeclared
  mutation-negative fixture rejects for an allowed reason;
- candidate-level and whole-family evidence remain independently attributable;
  and
- the corpus result is reproducible from its recorded identities.

Performance is recorded, not optimized prematurely: cold/warm median stage
time, generator time, copied-byte count, and peak process-tree RSS. A proposed
optimization must be benchmarked and must preserve all semantic counts,
blockers, verdicts, and safety invariants. Hard links and shared mutable staging
remain forbidden.

Meeting this gate does not itself authorize promotion. The implementation stops
and requests approval for a separate promotion plan.

## Alternatives Rejected

### Generate in the selected project with output overrides

Rejected because `l10n.yaml` is authoritative and the command-line relocation
does not reliably isolate configured writes. It could mutate generated source
before quarantine owns the operation.

### Copy the complete project for every stage

Safer than in-place generation but unnecessarily expensive and noisy. A
minimal project-shaped copy has a smaller write surface and makes unexpected
writes attributable. Full copying is not an automatic fallback: if required
inputs cannot be enumerated, the verdict rejects rather than broadening scope.
This rejection applies to the core baseline/candidate generation sandbox. The
separately authorized natural-project evidence harness intentionally uses
complete disposable corpus copies to run each project's full verification
policy; those copies are not part of the production staging design.

### Reimplement Flutter's generator

Rejected because private generator behavior and emitted source change across
Flutter toolchains. The target toolchain remains authoritative.

### Extend the existing string-based ARB key scanner with mutation spans

Rejected because Dart string offsets are not UTF-8 byte offsets and because it
would couple read-only semantic inventory to mutation precision. A dedicated
byte document/editor gives the safety contract an isolated test seam.

### Build a generic JSON concrete-syntax-tree editor

Rejected as premature scope. V3.1 needs a strict ARB top-level member removal
operation, not a general JSON mutation framework.

## Authoritative Flutter References

- [Flutter internationalization documentation](https://docs.flutter.dev/ui/internationalization)
- [Flutter generated l10n source migration](https://docs.flutter.dev/release/breaking-changes/flutter-generate-i10n-source)
- [Flutter `gen-l10n` command source](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/commands/generate_localizations.dart)
- [Flutter localization generator source](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/localizations/gen_l10n.dart)
- [Flutter localization configuration source](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/localizations/localizations_utils.dart)
- [Smooth App pinned `.fvmrc` at the retained corpus commit](https://github.com/openfoodfacts/smooth-app/blob/bac71afd115f72e379c0b501b95e5ede20ecd636/.fvmrc)
- [GSY pinned `.fvmrc` at the retained corpus commit](https://github.com/CarGuo/gsy_github_app_flutter/blob/2b6c49008afc44b90fee869dedf8e59a86482953/.fvmrc)

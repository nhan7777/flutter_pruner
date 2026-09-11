# Safe l10n Removal V3.1 Stage 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and prove the internal-only Stage 1 pipeline that byte-edits a selected ARB family, reproduces and reconciles `gen-l10n` output in isolated staging, verifies the candidate without dependency resolution, and emits deterministic mutation-readiness evidence while every public l10n finding remains REVIEW-only and non-actionable.

**Architecture:** Add a private `action_readiness` domain beside the current V2 l10n scanner. The benchmark harness is the only caller: it freezes a scanner result and exact toolchain, captures an immutable family snapshot, creates independent baseline/candidate roots, runs the canonical Flutter binary, reconciles all writes, performs fixed in-process l10n verification, revalidates drift, cleans staging, and returns a typed verdict. A separate corpus layer installs defensively copied witnessed bytes only into disposable complete corpus clones and restores them after exact `--no-pub` policies.

**Tech Stack:** Dart 3.9+, `package:analyzer`, `package:crypto`, `package:path`, `package:pub_semver`, `package:test`, `package:yaml`, Flutter SDKs 3.38.7/3.41.5/3.44.1, existing `ProjectAnalyzer`, `DartAnalysisWorkspace`, and `ManagedProcessRunner` seams.

**Spec:** [Safe l10n Removal V3.1 Design](../specs/2026-08-22-safe-l10n-removal-v3-1-design.md)

## Global Constraints

- Stage 1 is internal evidence only. Do not add an import or call from `ProjectAnalyzer`, `FindingGenerator`, `ActionCapability`, `RemovalPlanner`, `FindingActionBuilder`, any CLI command/formatter, apply, quarantine, rollback, or recovery code into `action_readiness`.
- Do not modify `lib/src/adapters/l10n/l10n_config.dart`, `arb_inventory.dart`, `l10n_adapter.dart`, or `l10n_usage_resolver.dart` to make existing scans stricter or actionable. The new strict model is intentionally separate.
- Do not export any Stage 1 type from `lib/flutter_pruner.dart` and do not add a public CLI flag or report field.
- Never run `flutter gen-l10n`, `flutter pub get`, `dart pub get`, FVM, or another selector wrapper inside a staging root. Resolve the canonical Flutter binary in the original project before materialization.
- Generator/domain staging never resolves dependencies. Corpus provisioning may run one explicit unmeasured `flutter pub get --offline` before the baseline fingerprint; every measured Flutter analyze/test command includes `--no-pub`.
- Copy bytes into private system-temporary roots. Do not use symlinks, hard links, shared mutable staging, or concurrency.
- ARB edits operate on UTF-8 byte spans and never serialize or format JSON.
- Stage 1 accepts generated-output replacements only. A candidate output creation or deletion is rejection evidence, not a supported change.
- Keep source bytes, raw process output, absolute corpus locations, and environment values out of serialized evidence. Persist hashes, counts, stable relative paths, command identities, timings, and resource metrics.
- Before formatting an existing Dart file, invoke `flutter-minimal-diff`; format only touched Dart files. Do not run repository-wide `dart format` or `dart fix`.
- Each task ends with focused tests and its own local commit. Preserve unrelated work and do not push, merge, tag, release, or publish.
- If a target SDK, corpus identity, baseline policy, or restoration proof is unavailable, record a failed/blocked gate. Never shrink the 378-positive, 2,224-negative, 3-family, or 381-restoration denominator.

---

## File Map

### New private production files

- `lib/src/adapters/l10n/action_readiness/immutable_bytes.dart` — defensive byte values and validated byte spans.
- `lib/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart` — exhaustive Stage 1 rejection codes and stable failure detail.
- `lib/src/adapters/l10n/action_readiness/arb_document.dart` — strict byte-level ARB parser/editor.
- `lib/src/adapters/l10n/action_readiness/l10n_arb_mutation_planner.dart` — family-wide removal planning and postconditions.
- `lib/src/adapters/l10n/action_readiness/l10n_toolchain.dart` — original-project selector proof and canonical SDK identity.
- `lib/src/adapters/l10n/action_readiness/l10n_generation_config.dart` — strict schema-v1 `gen-l10n` configuration.
- `lib/src/adapters/l10n/action_readiness/l10n_family_snapshot.dart` — immutable family, resolution, closure, and file-state snapshot.
- `lib/src/adapters/l10n/action_readiness/l10n_family_preflight.dart` — scanner selection/static readiness gate.
- `lib/src/adapters/l10n/action_readiness/l10n_stage_materializer.dart` — independent baseline/candidate roots and cleanup.
- `lib/src/adapters/l10n/action_readiness/l10n_stage_inventory.dart` — stable before/after tree inventories.
- `lib/src/adapters/l10n/action_readiness/l10n_generator.dart` — fakeable canonical-binary `gen-l10n` runner.
- `lib/src/adapters/l10n/action_readiness/l10n_output_reconciler.dart` — baseline reproduction and candidate delta proof.
- `lib/src/adapters/l10n/action_readiness/l10n_generated_member_inspector.dart` — analyzer-backed generated API inspection.
- `lib/src/adapters/l10n/action_readiness/l10n_stage_verifier.dart` — fixed in-process l10n policy.
- `lib/src/adapters/l10n/action_readiness/l10n_evidence_verdict.dart` — immutable accepted/rejected evidence value.
- `lib/src/adapters/l10n/action_readiness/l10n_snapshot_revalidator.dart` — typed source/config/resolution/toolchain drift proof.
- `lib/src/adapters/l10n/action_readiness/l10n_evidence_pipeline.dart` — the Stage 1 orchestration boundary.

### Modified production file

- `lib/src/core/process/managed_process_runner.dart` — default-preserving environment controls, exact captured bytes, and sampled process-tree peak RSS.

### Independent benchmark/oracle files

- `benchmark/accuracy/build_l10n_mutation_readiness_manifest.dart` — independent manifest/GSY-normalization builder; it must not import product l10n code.
- `benchmark/accuracy/manifests/l10n-mutation-readiness-v1.json` — complete frozen 378-positive/2,224-negative oracle and corpus policy.
- `benchmark/accuracy/manifests/gsy-normalized-family-v1.json` — exact original hashes, duplicate-member removal byte spans, replacement hashes, and semantic hashes for every normalized GSY ARB.
- `benchmark/accuracy/src/l10n_mutation_manifest.dart` — strict immutable manifest reader.
- `benchmark/accuracy/src/corpus_mutation_evidence.dart` — disposable-corpus install, no-resolution policy, restoration, and typed outcome.
- `benchmark/accuracy/l10n_mutation_readiness.dart` — internal harness CLI; never registered as the product executable.
- `benchmark/accuracy/baselines/v3.1-l10n-stage1.json` — successful fresh gate artifact, created only after every denominator is satisfied.

### New tests and fixtures

- `test/adapters/l10n/action_readiness/immutable_bytes_test.dart`
- `test/adapters/l10n/action_readiness/arb_document_test.dart`
- `test/adapters/l10n/action_readiness/l10n_arb_mutation_planner_test.dart`
- `test/adapters/l10n/action_readiness/l10n_toolchain_test.dart`
- `test/adapters/l10n/action_readiness/l10n_generation_config_test.dart`
- `test/adapters/l10n/action_readiness/l10n_family_snapshot_test.dart`
- `test/adapters/l10n/action_readiness/l10n_family_preflight_test.dart`
- `test/adapters/l10n/action_readiness/l10n_stage_materializer_test.dart`
- `test/adapters/l10n/action_readiness/l10n_stage_inventory_test.dart`
- `test/adapters/l10n/action_readiness/l10n_generator_test.dart`
- `test/adapters/l10n/action_readiness/l10n_output_reconciler_test.dart`
- `test/adapters/l10n/action_readiness/l10n_generated_member_inspector_test.dart`
- `test/adapters/l10n/action_readiness/l10n_stage_verifier_test.dart`
- `test/adapters/l10n/action_readiness/l10n_snapshot_revalidator_test.dart`
- `test/adapters/l10n/action_readiness/l10n_evidence_pipeline_test.dart`
- `test/adapters/l10n/action_readiness/stage1_public_boundary_test.dart`
- `test/benchmark/accuracy/l10n_mutation_manifest_test.dart`
- `test/benchmark/accuracy/corpus_mutation_evidence_test.dart`
- `test/benchmark/accuracy/l10n_mutation_readiness_test.dart`
- `test/fixtures/l10n_action_readiness/` — standard, custom-config, parser golden, output-family, process, and negative fixture trees.

### Existing tests modified for the process contract

- `test/core/process/managed_process_runner_test.dart`
- `test/verification/verification_runner_test.dart`
- `test/apply/import_cleanup_runner_test.dart`
- `test/quarantine/quarantine_manager_test.dart`

---

## Task 1: Freeze the independent mutation-readiness oracle before production code

**Files:**

- Create: `benchmark/accuracy/build_l10n_mutation_readiness_manifest.dart`
- Create: `benchmark/accuracy/manifests/l10n-mutation-readiness-v1.json`
- Create: `benchmark/accuracy/manifests/gsy-normalized-family-v1.json`
- Create: `test/benchmark/accuracy/l10n_mutation_manifest_test.dart`

- [ ] Add a failing manifest-structure test that reads the manifest JSON using only `dart:convert` and asserts these exact denominators and identities:

```dart
expect(manifest['schemaVersion'], 1);
expect(manifest['oracleVersion'], 'l10n-mutation-readiness-v1');
expect(manifest['totals'], {
  'positiveKeys': 378,
  'negativeKeys': 2224,
  'families': 3,
  'individualMutationAttempts': 378,
  'familyMutationAttempts': 3,
  'requiredRestorations': 381,
});
expect(projectCounts, {
  'smooth': {'positive': 323, 'negative': 1457},
  'gsy': {'positive': 17, 'negative': 386},
  'gitjournal': {'positive': 38, 'negative': 381},
});
expect(toolchainVersions, {
  'smooth': '3.38.7',
  'gsy': '3.44.1',
  'gitjournal': '3.41.5',
});
```

- [ ] Assert the three retained oracle inputs have these SHA-256 identities before accepting their labels:

```dart
const expectedOracleHashes = {
  'smooth': '3ba9fb5be7bb70dcb68856cf4339c3e80626d30844fbc93dd7c81ecf5cc99020',
  'gsy': '9e113537db5e2a7b057bffc0d1ff74ce6799c2b31b36b89ff36bcf3afda65d35',
  'gitjournal': 'e07dafbb2b3cdecba0e928a08f0025ed8cc8bc161e0979dec73bb460b13ffc77',
};
```

- [ ] Assert every case has a unique canonical node ID, decoded key, truth label, expected scanner presence, and—only for positives—a nonempty sorted `expectedArbMembersByPath`. Assert every family declares `expectedConfigurationStatus: supported`, `expectedFamilyBatchStatus: accepted`, repository SHA, package-root-relative path, toolchain selection evidence, and an exact verification policy.

- [ ] Freeze a complete GitJournal retained toolchain selection record, not just a version string: framework version, framework revision, engine revision, bundled Dart version, the retained CI-resolution evidence SHA-256, direct `flutter --version --machine` argv, and exact bounded probe-output SHA-256. The direct 3.41.5 registry probe must match all four machine fields before the manifest is accepted.

- [ ] Predeclare the mutation-negative fixture matrix independently of production reason enums:

```dart
const expectedNegativeReasons = {
  'scan-blocker': ['scanBlockerPresent'],
  'pseudo-key-selection': ['invalidSelection'],
  'unknown-config-option': ['unsupportedConfiguration'],
  'path-escape': ['invalidInputPath'],
  'locale-only-key': ['arbFamilyIncomplete'],
  'malformed-arb': ['arbParseFailure'],
  'stale-live-output': ['staleGeneratedOutput'],
  'candidate-output-created': ['outputFamilyAmbiguous'],
  'candidate-output-deleted': ['outputFamilyAmbiguous'],
  'unexpected-stage-write': ['unexpectedStageWrite'],
  'source-drift': ['sourceDrift'],
  'package-resolution-drift': ['packageResolutionDrift'],
  'toolchain-drift': ['toolchainDrift'],
  'cleanup-failure': ['cleanupFailed'],
};
```

- [ ] Run the test and confirm it fails because the manifest files do not exist:

```sh
dart test test/benchmark/accuracy/l10n_mutation_manifest_test.dart
```

- [ ] Implement the independent builder without importing anything from `lib/src/adapters/l10n/`. It must accept explicit `--evidence-root`, `--smooth-repository`, `--gsy-repository`, `--gitjournal-repository`, `--gitjournal-flutter`, and `--output-directory` argv values; verify the three oracle hashes; verify repository SHAs; parse all oracle cases; directly probe the canonical GitJournal SDK; capture the existing product's public surface through an argv-only child process; and emit canonically sorted JSON with a final newline. Read corpus inputs from Git blobs at the declared commits (or a clean detached temporary tree), never from a possibly dirty repository working tree.

- [ ] In the same independent builder, normalize every duplicate decoded top-level member in each GSY ARB by retaining the last effective member, which matches JSON decoding semantics. Emit `gsy-normalized-family-v1.json` with relative path, original SHA-256, exact non-overlapping byte spans removed, replacement SHA-256, and canonical decoded-object SHA-256 for every changed ARB. Do not embed third-party source bytes. Reapply the spans to the pinned source, reparse every replacement, require zero decoded-key duplicates, and require decoded object equality with the original effective object.

- [ ] For each positive key, enumerate the exact message and present `@message` companion in every normalized family ARB and store those sorted member names by relative path. For each negative key, require that it remains in the normalized template inventory but emit no mutation authority.

- [ ] Before any production code exists, capture a normalized public-surface baseline for the existing l10n fixture: raw top-level/subcommand help SHA-256; normalized terminal, JSON, and HTML scan SHA-256 after removing only declared timing fields; ordered finding IDs/tiers/classification reasons/blocker identities; CLI option names; and report schema keys. Store this under `publicSurfaceBaseline` in the manifest so Task 16 compares bytes/semantics to a pre-code artifact rather than to newly generated expectations.

- [ ] Freeze these exact measured corpus policies in the manifest, with canonical Flutter resolved later by version rather than by the literal `flutter` token:

```text
smooth repository cwd: flutter analyze --no-pub --fatal-infos --fatal-warnings .
smooth package cwd:    flutter test --no-pub
gsy package cwd:       flutter analyze --no-pub
gsy package cwd:       flutter test --no-pub
gitjournal package cwd:flutter analyze --no-pub
gitjournal package cwd:flutter test --no-pub
```

  Record `packages/smooth_app` as Smooth's package root. Record the GSY and GitJournal repository roots as their package roots. Record required non-secret fixture overlays separately from the normalization overlay; do not embed secrets.

- [ ] Generate the two manifests from the retained 2026-08-18 evidence directory and pinned local corpus clones, then rerun the focused test:

```sh
dart run benchmark/accuracy/build_l10n_mutation_readiness_manifest.dart \
  --evidence-root /Users/nhan/Desktop/flutter_pruner_benchmar_sample/results/v2-natural-accuracy-2026-08-18 \
  --smooth-repository /Users/nhan/Desktop/flutter_pruner_benchmar_sample/smooth-app \
  --gsy-repository /Users/nhan/Desktop/flutter_pruner_benchmar_sample/gsy_github_app_flutter \
  --gitjournal-repository /Users/nhan/Desktop/flutter_pruner_benchmar_sample/GitJournal \
  --gitjournal-flutter /Users/nhan/fvm/versions/3.41.5/bin/flutter \
  --output-directory benchmark/accuracy/manifests
dart test test/benchmark/accuracy/l10n_mutation_manifest_test.dart
```

- [ ] Request an independent review of only the two generated manifests and builder. The reviewer must recompute the three source hashes, counts, repository SHAs, GSY semantic equality, at least ten positive member maps per project, at least ten negatives per project, all toolchain pins, and every policy argv. Do not begin Task 2 until that review has no open finding.

- [ ] Commit the frozen oracle before any `lib/src/adapters/l10n/action_readiness/` file exists:

```sh
git add benchmark/accuracy/build_l10n_mutation_readiness_manifest.dart benchmark/accuracy/manifests test/benchmark/accuracy/l10n_mutation_manifest_test.dart
git commit -m "test: freeze l10n mutation readiness oracle"
```

## Task 2: Add immutable byte primitives and stable failure identities

**Files:**

- Create: `lib/src/adapters/l10n/action_readiness/immutable_bytes.dart`
- Create: `lib/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart`
- Create: `test/adapters/l10n/action_readiness/immutable_bytes_test.dart`

- [ ] Write failing tests proving constructor inputs, returned copies, slices, maps, and sets cannot mutate retained bytes; span bounds reject eagerly; SHA-256 is over exact bytes; and equal content has equal hashes.

- [ ] Run the test and confirm the import/file failure:

```sh
dart test test/adapters/l10n/action_readiness/immutable_bytes_test.dart
```

- [ ] Implement these exact public-within-`src` values:

```dart
final class ByteSpan {
  ByteSpan(this.start, this.endExclusive) {
    if (start < 0 || endExclusive < start) {
      throw RangeError.range(endExclusive, start, null, 'endExclusive');
    }
  }

  final int start;
  final int endExclusive;
  int get length => endExclusive - start;
}

final class ImmutableBytes {
  factory ImmutableBytes.copyOf(List<int> source);

  int get length;
  int operator [](int index);
  String get sha256Hex;
  Uint8List copy();
  ImmutableBytes slice(ByteSpan span);
  bool contentEquals(ImmutableBytes other);
}
```

  Store a defensive `Uint8List` copy, never expose it, validate slice bounds, and cache a SHA-256 computed from the exact bytes.

- [ ] Define the exhaustive declaration-ordered failure code and stable detail value:

```dart
enum L10nEvidenceRejectionCode {
  scanBlockerPresent,
  invalidSelection,
  unsupportedConfiguration,
  invalidInputPath,
  arbFamilyIncomplete,
  arbParseFailure,
  materializationFailed,
  sourceDrift,
  packageResolutionDrift,
  toolchainUnavailable,
  toolchainDrift,
  editPostconditionFailed,
  baselineGenerationFailed,
  staleGeneratedOutput,
  candidateGenerationFailed,
  generatorOutputTruncated,
  generatorTerminationUnconfirmed,
  unexpectedStageWrite,
  outputFamilyAmbiguous,
  candidateVerificationFailed,
  cleanupFailed,
  internalFailure,
}

final class L10nEvidenceFailure {
  const L10nEvidenceFailure({
    required this.code,
    required this.stage,
    required this.detailCode,
    this.relativePath,
  });

  final L10nEvidenceRejectionCode code;
  final String stage;
  final String detailCode;
  final String? relativePath;
}
```

- [ ] Test deterministic sorting by enum index, then `stage`, `relativePath ?? ''`, and `detailCode`; do not use free-form exception text as identity.

- [ ] Run and commit:

```sh
dart test test/adapters/l10n/action_readiness/immutable_bytes_test.dart
git add lib/src/adapters/l10n/action_readiness test/adapters/l10n/action_readiness/immutable_bytes_test.dart
git commit -m "feat: add immutable l10n evidence values"
```

## Task 3: Parse and edit ARB documents at byte spans

**Files:**

- Create: `lib/src/adapters/l10n/action_readiness/arb_document.dart`
- Create: `test/adapters/l10n/action_readiness/arb_document_test.dart`
- Create fixtures: `test/fixtures/l10n_action_readiness/parser/`

- [ ] Add table-driven failing parser tests for UTF-8 BOM, CRLF, compact/pretty JSON, nested objects/arrays, ICU plural/select values, escaped punctuation, non-ASCII and escaped keys, and exact byte offsets.

- [ ] Add failing rejection tests for invalid UTF-8, UTF-16 BOMs, NUL, comments, trailing commas, malformed escapes/JSON, non-object roots, and duplicate decoded keys including literal-versus-escaped collisions.

- [ ] Run the focused test and confirm failure:

```sh
dart test test/adapters/l10n/action_readiness/arb_document_test.dart
```

- [ ] Implement the exact result model. Deep-freeze decoded maps/lists before exposing `decodedValue`:

```dart
enum ArbParseFailureKind {
  invalidUtf8,
  unsupportedBom,
  nulByte,
  comment,
  trailingComma,
  malformedJson,
  nonObjectRoot,
  duplicateDecodedKey,
}

sealed class ArbParseResult {
  const ArbParseResult();
}

final class ArbParseSuccess extends ArbParseResult {
  const ArbParseSuccess(this.document);
  final ArbDocument document;
}

final class ArbParseFailure extends ArbParseResult {
  const ArbParseFailure(this.kind, {this.byteOffset});
  final ArbParseFailureKind kind;
  final int? byteOffset;
}

final class ArbMember {
  const ArbMember({
    required this.decodedKey,
    required this.keySpan,
    required this.valueSpan,
    required this.memberSpan,
    required this.decodedValue,
  });

  final String decodedKey;
  final ByteSpan keySpan;
  final ByteSpan valueSpan;
  final ByteSpan memberSpan;
  final Object? decodedValue;
}

final class ArbDelimiter {
  const ArbDelimiter({
    required this.leftMemberIndex,
    required this.rightMemberIndex,
    required this.commaSpan,
  });

  final int leftMemberIndex;
  final int rightMemberIndex;
  final ByteSpan commaSpan;
}

sealed class ArbDocumentEditResult {
  const ArbDocumentEditResult();
}

final class ArbDocumentEditReady extends ArbDocumentEditResult {
  const ArbDocumentEditReady({
    required this.bytes,
    required this.removedSpans,
  });
  final ImmutableBytes bytes;
  final List<ByteSpan> removedSpans;
}

final class ArbDocumentEditRejected extends ArbDocumentEditResult {
  const ArbDocumentEditRejected(this.detailCode);
  final String detailCode;
}

final class ArbDocument {
  static ArbParseResult parse(List<int> bytes);

  final ImmutableBytes source;
  final List<ArbMember> members;
  final List<ArbDelimiter> delimiters;

  ArbMember? member(String decodedKey);
  ArbDocumentEditResult removeMembers(Set<String> decodedKeys);
}
```

- [ ] Implement a direct ASCII structural scan over UTF-8 bytes. Decode only JSON string/value slices for semantics, validate the entire BOM-stripped document with `jsonDecode`, and keep whitespace outside member/comma ownership. Do not reuse or modify `_TopLevelJsonKeyScanner` in `arb_inventory.dart`.

- [ ] Add exact reconstruction tests: apply the returned non-overlapping removal spans once, assert the result parses, and assert every byte outside those spans is identical to the input.

- [ ] Run and commit:

```sh
dart test test/adapters/l10n/action_readiness/arb_document_test.dart
git add lib/src/adapters/l10n/action_readiness/arb_document.dart test/adapters/l10n/action_readiness/arb_document_test.dart test/fixtures/l10n_action_readiness/parser
git commit -m "feat: add byte precise arb document editor"
```

## Task 4: Plan an atomic ARB-family removal

**Files:**

- Create: `lib/src/adapters/l10n/action_readiness/l10n_arb_mutation_planner.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_arb_mutation_planner_test.dart`

- [ ] Write failing golden tests for first, middle, final, only, all, adjacent, and non-adjacent removal runs; adjacent/separated message companions; omitted locale messages; BOM/CRLF/final newline; unrelated `@`/`@@` keys; and placeholder/plural/select values.

- [ ] Write failing whole-family rejection tests for empty/duplicate/pseudo-key selection, missing template message, orphan metadata, locale-only messages, document parse failure, and edit postcondition failure.

- [ ] Implement the result and plan types:

```dart
final class ArbRemoval {
  const ArbRemoval({required this.decodedKey, required this.span});
  final String decodedKey;
  final ByteSpan span;
}

sealed class L10nArbMutationPlanResult {
  const L10nArbMutationPlanResult();
}

final class L10nArbMutationPlanReady extends L10nArbMutationPlanResult {
  const L10nArbMutationPlanReady(this.plan);
  final L10nArbMutationPlan plan;
}

final class L10nArbMutationPlanRejected extends L10nArbMutationPlanResult {
  const L10nArbMutationPlanRejected(this.failures);
  final List<L10nEvidenceFailure> failures;
}

final class L10nArbMutationPlan {
  final Map<String, ImmutableBytes> candidateArbBytes;
  final Map<String, List<ArbRemoval>> removalsByPath;
  final String mutationFingerprint;
}

final class L10nArbMutationPlanner {
  static L10nArbMutationPlanResult plan({
    required String templatePath,
    required Map<String, ArbDocument> documentsByPath,
    required Iterable<String> selectedKeys,
  });
}
```

- [ ] Validate the ordered iterable before freezing it: reject empty strings, duplicate decoded keys, and pseudo-keys. Only after duplicate detection may the implementation build an immutable set. Implement the run algorithm from the spec: compute every range against original bytes; when a removal run has a surviving member after it, remove each member and its following delimiter; when the run is final, remove its preceding delimiter and internal delimiters; when all members are removed, preserve only BOM/braces/unowned whitespace. Coalesce ranges and copy survivors once.

- [ ] Reparse every candidate and prove selected/present companions absent, every unselected member token exact, locale identity unchanged, and no new duplicate/orphan/locale-only issue. Return only immutable sorted maps/lists.

- [ ] Run and commit:

```sh
dart test test/adapters/l10n/action_readiness/l10n_arb_mutation_planner_test.dart
git add lib/src/adapters/l10n/action_readiness/l10n_arb_mutation_planner.dart test/adapters/l10n/action_readiness/l10n_arb_mutation_planner_test.dart
git commit -m "feat: plan atomic arb family edits"
```

## Task 5: Extend managed process evidence without changing existing behavior

**Files:**

- Modify: `lib/src/core/process/managed_process_runner.dart`
- Modify: `test/core/process/managed_process_runner_test.dart`
- Modify fakes: `test/verification/verification_runner_test.dart`
- Modify fakes: `test/apply/import_cleanup_runner_test.dart`
- Modify fakes: `test/quarantine/quarantine_manager_test.dart`

- [ ] Invoke `flutter-minimal-diff`, then add failing tests for inherited environment defaults, explicit overrides, `includeParentEnvironment: false`, exact captured payload bytes including malformed UTF-8, and deterministic RSS parsing/summing across a root plus descendants.

- [ ] Change the interface with default-preserving named parameters; update every existing fake signature and make the delegating quarantine fake forward both values:

```dart
abstract interface class ProcessExecutionRunner {
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
    Map<String, String> environmentOverrides = const {},
    bool includeParentEnvironment = true,
  });
}
```

- [ ] Replace lossy output storage with defensively copied payload bytes while retaining the existing `text`, `capturedBytes`, `omittedBytes`, `truncated`, and truncation-notice behavior:

```dart
final class BoundedProcessOutput {
  BoundedProcessOutput({
    required List<int> capturedPayload,
    required this.omittedBytes,
  });

  Uint8List get capturedPayload;
  String get text;
  int get capturedBytes;
  final int omittedBytes;
  bool get truncated => omittedBytes > 0;
}
```

- [ ] Add resource evidence with an unsupported default so existing result construction remains source-compatible:

```dart
enum ProcessResourceObservationStatus { measured, unsupported, unreliable }

final class ProcessTreeResourceObservation {
  const ProcessTreeResourceObservation({
    required this.status,
    required this.sampleCount,
    this.sampledPeakRssBytes,
  });

  static const unsupported = ProcessTreeResourceObservation(
    status: ProcessResourceObservationStatus.unsupported,
    sampleCount: 0,
  );

  final ProcessResourceObservationStatus status;
  final int sampleCount;
  final int? sampledPeakRssBytes;
}
```

  Add `resourceObservation` to `ManagedProcessResult`, defaulting to `ProcessTreeResourceObservation.unsupported`.

- [ ] Pass an immutable environment copy to `Process.start`. On POSIX, sample `ps -axo pid=,ppid=,lstart=,state=,rss=` at the existing 100 ms interval, keep PID/lstart as the reuse-safe identity, sum live tracked-tree RSS KiB into bytes, and retain the peak/sample count. Sampling failure marks metrics unreliable and must not convert a successful command into failure.

- [ ] Add a macOS/Linux integration test with a long-enough parent/child process to observe RSS and a timeout test proving confirmed termination retains samples. Gate platform-specific assertions; retain current Windows/unsupported behavior.

- [ ] Run the complete affected set and commit:

```sh
dart test test/core/process/managed_process_runner_test.dart test/verification/verification_runner_test.dart test/apply/import_cleanup_runner_test.dart test/quarantine/quarantine_manager_test.dart
git add lib/src/core/process/managed_process_runner.dart test/core/process/managed_process_runner_test.dart test/verification/verification_runner_test.dart test/apply/import_cleanup_runner_test.dart test/quarantine/quarantine_manager_test.dart
git commit -m "feat: capture managed process environment and rss evidence"
```

## Task 6: Resolve and freeze the canonical Flutter toolchain

**Files:**

- Create: `lib/src/adapters/l10n/action_readiness/l10n_toolchain.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_toolchain_test.dart`
- Create fixtures: `test/fixtures/l10n_action_readiness/toolchains/`

- [ ] Write fake-runner tests for matching FVM delegation/direct probe, root `.fvmrc`, `.fvm/fvm_config.json`, selector disagreement, unknown selector shape, missing registry mapping, wrapper/direct identity mismatch, unsupported version, truncated/nonzero/timed-out/unconfirmed probes, selector mutation, and stable identity across map order.

- [ ] Implement immutable registry, selection, machine identity, and resolution values:

```dart
final class L10nSdkRegistry {
  L10nSdkRegistry(Map<Version, String> canonicalFlutterByVersion);
  String? executableFor(Version version);
}

sealed class L10nToolchainSelection {
  const L10nToolchainSelection();
}

final class ProjectSelectorSelection extends L10nToolchainSelection {
  const ProjectSelectorSelection();
}

final class RetainedEvidenceSelection extends L10nToolchainSelection {
  const RetainedEvidenceSelection({
    required this.expectedIdentity,
    required this.evidenceSha256,
    required this.probeOutputSha256,
  });
  final FlutterMachineIdentity expectedIdentity;
  final String evidenceSha256;
  final String probeOutputSha256;
}

final class FlutterMachineIdentity {
  const FlutterMachineIdentity({
    required this.frameworkVersion,
    required this.frameworkRevision,
    required this.engineRevision,
    required this.dartSdkVersion,
  });
  final Version frameworkVersion;
  final String frameworkRevision;
  final String engineRevision;
  final String dartSdkVersion;
}

sealed class L10nToolchainResolution {
  const L10nToolchainResolution();
}

final class L10nToolchainResolved extends L10nToolchainResolution {
  final String canonicalFlutterExecutable;
  final String canonicalSdkRoot;
  final L10nToolchainSelection selection;
  final List<String> generationArgs;
  final List<String> directProbeArgs;
  final Map<String, String> environmentOverrides;
  final Map<String, String> selectorHashesByRelativePath;
  final FlutterMachineIdentity machineIdentity;
  final String originalSelectionProbeSha256;
  final String identitySha256;
}

final class L10nToolchainRejected extends L10nToolchainResolution {
  const L10nToolchainRejected(this.failure);
  final L10nEvidenceFailure failure;
}
```

- [ ] Implement typed `L10nToolchainResolver.resolve` and `revalidate`:

```dart
sealed class L10nToolchainRevalidationResult {
  const L10nToolchainRevalidationResult();
}

final class L10nToolchainStillMatches
    extends L10nToolchainRevalidationResult {
  const L10nToolchainStillMatches(this.identitySha256);
  final String identitySha256;
}

final class L10nToolchainChanged extends L10nToolchainRevalidationResult {
  const L10nToolchainChanged(this.failure);
  final L10nEvidenceFailure failure;
}

abstract interface class L10nToolchainResolver {
  Future<L10nToolchainResolution> resolve({
    required Directory originalProjectRoot,
    required L10nSdkRegistry sdkRegistry,
    required L10nToolchainSelection selection,
  });

  Future<L10nToolchainRevalidationResult> revalidate({
    required Directory originalProjectRoot,
    required L10nToolchainResolved expected,
  });
}
```

  Implement `DefaultL10nToolchainResolver` with a `ProcessExecutionRunner` constructor dependency and the two interface methods above.

- [ ] Support only semantic versions 3.38.7, 3.41.5, and 3.44.1. For project selectors, fingerprint every present supported selector, reject conflict, run `fvm flutter --version --machine` only in the original root when FVM selected the SDK, and direct-probe the registry binary with `--version --machine`. For retained GitJournal evidence, bind the exact source/probe hashes and complete expected `FlutterMachineIdentity`; require the direct registry probe to match framework version/revision, engine revision, and Dart identity without inventing a selector.

- [ ] Canonicalize and require regular executable/SDK paths. Never treat `.fvm/flutter_sdk` symlink alone as authority. Require framework version/revision, engine revision, and bundled Dart version equality between delegated and direct probes.

- [ ] Use fixed sorted overrides `CI=true`, `FLUTTER_SUPPRESS_ANALYTICS=true`, `LANG=en_US.UTF-8`, and `LC_ALL=en_US.UTF-8`, with parent environment included. Do not override `HOME` or `PUB_CACHE`. Hash length/NUL-framed executable/SDK realpaths, selector path/hash pairs, selection evidence, probe argv and exact bounded output bytes, and overrides.

- [ ] Run and commit:

```sh
dart test test/adapters/l10n/action_readiness/l10n_toolchain_test.dart
git add lib/src/adapters/l10n/action_readiness/l10n_toolchain.dart test/adapters/l10n/action_readiness/l10n_toolchain_test.dart test/fixtures/l10n_action_readiness/toolchains
git commit -m "feat: freeze l10n flutter toolchain identity"
```

## Task 7: Load strict schema-v1 generation configuration

**Files:**

- Create: `lib/src/adapters/l10n/action_readiness/l10n_generation_config.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_generation_config_test.dart`
- Create fixtures: `test/fixtures/l10n_action_readiness/config/`

- [ ] Write failing table tests for each exact supported Flutter version and every recognized option/default. Verify that each version has its own immutable table even where values currently match.

- [ ] Cover the exact recognized key set and reject unknown keys, explicit null, wrong types, duplicate YAML keys, unsupported Flutter versions, `synthetic-package: true`, and simultaneous `header`/`header-file`. Preserve the current applicability rule: either `l10n.yaml` exists or the Flutter package declares `flutter.generate: true`; record the generation flag in configuration identity rather than changing V2 applicability.

```dart
const schemaV1Keys = {
  'arb-dir',
  'output-dir',
  'template-arb-file',
  'output-localization-file',
  'untranslated-messages-file',
  'output-class',
  'header',
  'header-file',
  'use-deferred-loading',
  'preferred-supported-locales',
  'required-resource-attributes',
  'nullable-getter',
  'format',
  'use-escaping',
  'suppress-warnings',
  'relax-syntax',
  'use-named-parameters',
  'synthetic-package',
};
```

- [ ] Implement the strict result/config API beside, not inside, current `L10nConfig`:

```dart
enum L10nGenerationSchemaVersion { flutter3387, flutter3415, flutter3441 }

sealed class L10nGenerationConfigLoadResult {
  const L10nGenerationConfigLoadResult();
}

final class L10nGenerationConfigReady
    extends L10nGenerationConfigLoadResult {
  const L10nGenerationConfigReady(this.config);
  final L10nGenerationConfig config;
}

final class L10nGenerationConfigRejected
    extends L10nGenerationConfigLoadResult {
  const L10nGenerationConfigRejected(this.failures);
  final List<L10nEvidenceFailure> failures;
}

abstract interface class L10nGenerationConfigLoader {
  Future<L10nGenerationConfigLoadResult> load({
    required ProjectContext project,
    required FlutterMachineIdentity toolchain,
  });
}

final class L10nGenerationConfig {
  final L10nGenerationSchemaVersion schemaVersion;
  final ImmutableBytes pubspecBytes;
  final ImmutableBytes? yamlBytes;
  final String arbDirectory;
  final String templateArbPath;
  final String outputDirectory;
  final String baseOutputPath;
  final String? untranslatedMessagesPath;
  final String? headerFilePath;
  final String? header;
  final String outputClass;
  final List<String> preferredSupportedLocales;
  final bool useDeferredLoading;
  final bool requiredResourceAttributes;
  final bool nullableGetter;
  final bool format;
  final bool useEscaping;
  final bool suppressWarnings;
  final bool relaxSyntax;
  final bool useNamedParameters;
  final bool useCrLfOutputs;
  final String configurationIdentity;
}
```

  Implement `DefaultL10nGenerationConfigLoader` as the sole production implementation of the interface.

- [ ] Resolve `header-file` relative to `arb-dir`, `untranslated-messages-file` relative to project root, and the base output beneath `output-dir`. Reject absolute/URI/control/backslash/percent/`..` ambiguity, symlink components, outside-root canonical paths, non-regular required inputs, and case-folded collisions. Permit absent outputs only when the nearest existing ancestor is safe.

- [ ] Preserve exact raw `l10n.yaml` bytes for staging. Derive generated CRLF behavior from exact `pubspec.yaml` bytes. Hash the versioned table ID, raw YAML presence/bytes, raw pubspec line-ending fact, and all effective typed values using length/NUL framing.

- [ ] Cross-check defaults and output rules against the pinned Flutter sources for all three tags, then run and commit:

```sh
dart test test/adapters/l10n/action_readiness/l10n_generation_config_test.dart
git add lib/src/adapters/l10n/action_readiness/l10n_generation_config.dart test/adapters/l10n/action_readiness/l10n_generation_config_test.dart test/fixtures/l10n_action_readiness/config
git commit -m "feat: model strict l10n generation config"
```

## Task 8: Preflight selection and capture an immutable family snapshot

**Files:**

- Create: `lib/src/adapters/l10n/action_readiness/l10n_family_snapshot.dart`
- Create: `lib/src/adapters/l10n/action_readiness/l10n_family_preflight.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_family_snapshot_test.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_family_preflight_test.dart`
- Create fixture: `test/fixtures/l10n_action_readiness/standard/`

- [ ] Write failing snapshot tests for defensive immutability, stable sorting/fingerprints, exact bytes/hash/mode, explicit absence, stage-projected package config, regional locales sharing one base-language output, custom header/output/sidecar, and no source drift during capture.

- [ ] Define the snapshot seam consumed by materialization:

```dart
enum L10nSnapshotRole {
  pubspec,
  lockfile,
  l10nConfig,
  arbTemplate,
  arbLocale,
  header,
  generatedBase,
  generatedLanguage,
  untranslatedSidecar,
  packageConfig,
  packageGraph,
  analyzerSource,
  verificationInput,
}

sealed class L10nSnapshotFileState {
  const L10nSnapshotFileState();
}

final class L10nSnapshotPresent extends L10nSnapshotFileState {
  final ImmutableBytes sourceBytes;
  final ImmutableBytes stageBytes;
  final String sourceSha256;
  final int? posixMode;
}

final class L10nSnapshotAbsent extends L10nSnapshotFileState {
  const L10nSnapshotAbsent();
}

final class L10nSnapshotEntry {
  final String relativePosixPath;
  final L10nSnapshotRole role;
  final L10nSnapshotFileState state;
}

final class L10nVerificationClosure {
  final Set<String> projectOwnedDartPaths;
  final String analyzerRootIdentity;
}

final class L10nProjectSemantics {
  final Map<dynamic, dynamic> pubspec;
  final String packageName;
  final AnalysisMode analysisMode;
  final TargetMatrix targetMatrix;
  final RootCoverage rootCoverage;
}

final class L10nFamilySnapshot {
  final Map<String, L10nSnapshotEntry> entries;
  final L10nArbMutationPlan mutationPlan;
  final Set<String> selectedNodeIds;
  final Set<String> selectedKeys;
  final Map<String, ArbGeneratedMemberKind>
      expectedGeneratedMemberKindsByKey;
  final Set<String> expectedGeneratedPaths;
  final String? optionalUntranslatedPath;
  final Set<String> analyzerClosurePaths;
  final Set<String> provenUnrelatedOutputSiblings;
  final String familyFingerprint;
  final String selectionFingerprint;
  final String configurationIdentity;
  final String packageResolutionIdentity;
  final String toolchainIdentity;
  final L10nProjectSemantics projectSemantics;
}
```

- [ ] For `.dart_tool/package_config.json`, keep exact live bytes/hash as `sourceBytes`, but create deterministic `stageBytes`: the selected package entry must use a relative URI resolving to the stage root; every external dependency root becomes a canonical absolute read-only file URI and is fingerprinted into `packageResolutionIdentity`. Reject an ambiguous/missing selected-package entry or any dependency root that cannot be canonicalized. All other entries use identical source/stage bytes.

- [ ] Reconstruct the closure immediately after the completed scan by creating a fresh `DartAnalysisWorkspace(analysis.project)` and freezing its `dartFiles` enumeration. This is the same deterministic project-source enumeration used by the analyzer adapters, but `AnalysisSnapshot` does not retain its workspace. Require every configured entrypoint/root-owned Dart file to be present, bind every path/hash/mode into `analyzerRootIdentity`, rerun the l10n-only analyzer before materialization, and require the same graph/finding fingerprint. Any intervening drift or enumeration disagreement rejects; do not modify `ProjectAnalyzer` or `AnalysisSnapshot` to expose Stage 1 state.

- [ ] Deep-copy the original pubspec, analysis mode, target matrix, and root coverage into `L10nProjectSemantics` so the staged verifier can construct a `ProjectContext` directly without config discovery. Freeze `ArbInventory.memberKind` for every template key as `expectedGeneratedMemberKindsByKey`, and retain the complete immutable `L10nArbMutationPlan` so verdict/corpus evidence can attribute message/companion spans without reparsing or losing its mutation fingerprint.

- [ ] Write failing preflight tests for an unsuccessful/missing l10n adapter run, wrong owner/kind/rule/origin/key metadata, duplicate/pseudo/cross-family selection, selected reachable/retained/protected node, active graph/input family blocker, incomplete analysis/target/root coverage, dangling graph endpoints, `ArbInventory`/`ArbDocument` disagreement, symlink/non-regular path, role/path collision, unsafe output sibling, and incomplete analyzer closure. Add a positive test proving the expected public classification reasons `unsupportedAction`, `nonDeterministicInverse`, and `broadRemovalScope` do not block internal evidence; Stage 1 evaluates graph blockers/reachability directly and never asks `ActionCapability` for mutation authority.

- [ ] Implement `L10nFamilyPreflight.capture`:

```dart
sealed class L10nFamilySnapshotResult {
  const L10nFamilySnapshotResult();
}

final class L10nFamilySnapshotReady extends L10nFamilySnapshotResult {
  const L10nFamilySnapshotReady(this.snapshot);
  final L10nFamilySnapshot snapshot;
}

final class L10nFamilySnapshotRejected extends L10nFamilySnapshotResult {
  const L10nFamilySnapshotRejected(this.failures);
  final List<L10nEvidenceFailure> failures;
}

abstract interface class L10nFamilySnapshotter {
  Future<L10nFamilySnapshotResult> capture({
    required AnalysisSnapshot analysis,
    required Iterable<String> selectedNodeIds,
    required L10nGenerationConfig config,
    required L10nToolchainResolved toolchain,
  });
}
```

  Implement `L10nFamilyPreflight` as the default `L10nFamilySnapshotter`.

- [ ] Compute the output family before staging from the versioned config table: base output plus one language output per distinct normalized base language using Flutter's first-dot filename split, and the optional sidecar. Capture missing configured outputs as `L10nSnapshotAbsent`; never synthesize empty bytes.

- [ ] Compare the byte parser against the unchanged semantic `ArbInventory`, call `L10nArbMutationPlanner` with the original iterable so duplicate selection remains observable, snapshot every required input/output/closure path and POSIX mode, sort all identities, then re-read hashes/modes once to reject source drift. Modes are nullable off POSIX; gate only mode assertions, never byte/hash checks, by platform.

- [ ] Run and commit:

```sh
dart test test/adapters/l10n/action_readiness/l10n_family_snapshot_test.dart test/adapters/l10n/action_readiness/l10n_family_preflight_test.dart
git add lib/src/adapters/l10n/action_readiness/l10n_family_snapshot.dart lib/src/adapters/l10n/action_readiness/l10n_family_preflight.dart test/adapters/l10n/action_readiness/l10n_family_snapshot_test.dart test/adapters/l10n/action_readiness/l10n_family_preflight_test.dart test/fixtures/l10n_action_readiness/standard
git commit -m "feat: capture l10n family readiness snapshot"
```

## Task 9: Materialize independent baseline and candidate roots

**Files:**

- Create: `lib/src/adapters/l10n/action_readiness/l10n_stage_materializer.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_stage_materializer_test.dart`

- [ ] Write failing tests for exact bytes/modes/relative paths, explicit absence, distinct baseline/candidate inodes, candidate-only ARB installation, system-temp containment outside the project, path escape, case-fold collision, symlink/non-regular parent, partial materialization cleanup, unsafe-to-delete roots, and injected cleanup failure.

- [ ] Implement the stage value/API:

```dart
final class L10nStageRoot {
  final Directory directory;
  final String identity;
  final Set<String> publishablePaths;
  bool get safeToDelete;
  void markUnsafeToDelete();
}

final class L10nStagePair {
  final L10nStageRoot baseline;
  final L10nStageRoot candidate;
  final int copiedBytes;
}

final class L10nStageCleanupLease {
  final List<L10nStageRoot> createdRoots;
  bool get consumed;
}

final class L10nStageMaterializationResult {
  final L10nStagePair? pair;
  final L10nStageCleanupLease cleanupLease;
  final List<L10nEvidenceFailure> failures;
  bool get ready => pair != null && failures.isEmpty;
}

final class L10nStageCleanupResult {
  final bool baselineRemoved;
  final bool candidateRemoved;
  final List<L10nEvidenceFailure> failures;
}

abstract interface class L10nStageMaterializer {
  Future<L10nStageMaterializationResult> materialize(
    L10nFamilySnapshot snapshot,
  );

  Future<List<L10nEvidenceFailure>> installCandidateArbs(
    L10nStageRoot candidate,
    Map<String, ImmutableBytes> replacements,
  );

  Future<L10nStageCleanupResult> cleanup(L10nStageCleanupLease lease);
}
```

  Implement `DefaultL10nStageMaterializer` as the filesystem-backed implementation.

- [ ] Materialize only `L10nSnapshotPresent.stageBytes`, create known parents beneath each unique root, preserve supported POSIX modes, and re-read every byte/hash/mode. Never read live source after snapshot capture. Candidate initially equals baseline; install only paths whose snapshot role is ARB and whose replacement key exactly matches.

- [ ] Register each created root in `L10nStageCleanupLease` before its first directory/file write, so even a rejected partial materialization returns a cleanup handle. Cleanup consumes that lease exactly once and only removes roots whose recorded canonical identity still matches. Verify absence after recursive deletion. A root marked unsafe after unconfirmed process termination remains diagnostic residue and returns `cleanupFailed` rather than claiming deletion.

- [ ] Run and commit:

```sh
dart test test/adapters/l10n/action_readiness/l10n_stage_materializer_test.dart
git add lib/src/adapters/l10n/action_readiness/l10n_stage_materializer.dart test/adapters/l10n/action_readiness/l10n_stage_materializer_test.dart
git commit -m "feat: isolate l10n baseline and candidate stages"
```

## Task 10: Capture stage inventories and run the canonical generator

**Files:**

- Create: `lib/src/adapters/l10n/action_readiness/l10n_stage_inventory.dart`
- Create: `lib/src/adapters/l10n/action_readiness/l10n_generator.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_stage_inventory_test.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_generator_test.dart`
- Create fixtures: `test/fixtures/l10n_action_readiness/process/`

- [ ] Write inventory tests for stable relative POSIX ordering, regular/directory/link/other types, content/mode changes, canonical escape recording without following links, and selective immutable byte capture for declared publishable paths.

- [ ] Implement inventory types:

```dart
enum L10nStageEntryKind { regularFile, directory, symbolicLink, other }

final class L10nStageEntry {
  final String relativePath;
  final L10nStageEntryKind kind;
  final String? sha256;
  final int? posixMode;
  final ImmutableBytes? capturedBytes;
}

final class L10nStageInventoryCapture {
  final Map<String, L10nStageEntry> entries;
  final List<String> invalidPaths;
  final String fingerprint;
}

final class L10nStageInventory {
  static Future<L10nStageInventoryCapture> capture(
    Directory root, {
    required Set<String> captureBytesFor,
  });
}
```

- [ ] Write fake process tests proving exact executable/argv/cwd/environment, no shell expansion, no `pub get`, phase-specific nonzero/timeout mapping, output truncation, unconfirmed termination, partial writes, unexpected writes, timing, and RSS capture.

- [ ] Implement the fakeable generator:

```dart
enum L10nGenerationPhase { baseline, candidate }

abstract interface class L10nGenerator {
  Future<L10nGenerationRun> generate({
    required L10nStageRoot stage,
    required L10nToolchainResolved toolchain,
    required L10nGenerationPhase phase,
    required Set<String> outputPaths,
  });
}

final class L10nGenerationRun {
  final L10nGenerationPhase phase;
  final L10nStageInventoryCapture before;
  final L10nStageInventoryCapture after;
  final ManagedProcessResult? processResult;
  final List<L10nEvidenceFailure> failures;
  final int elapsedMicros;
  final String commandIdentity;

  Map<String, Object?> toRedactedJson();
}

final class ProcessL10nGenerator implements L10nGenerator {
  ProcessL10nGenerator({
    ProcessExecutionRunner processRunner = const ManagedProcessRunner(),
    this.timeout = const Duration(minutes: 2),
    this.maxOutputBytesPerStream = 1024 * 1024,
  });
}
```

  `L10nGenerationRun` must retain phase, before/after inventories, exit/timing/resource evidence, exact bounded-output hashes/counts, and typed failures, but its JSON projection must not retain raw output.

- [ ] Invoke only `canonicalFlutterExecutable` with `generationArgs == ['gen-l10n']`, the staged cwd, fixed overrides, and inherited parent environment. Capture inventory immediately before and after even on nonzero/timeout/partial-write failure. On `ProcessTerminationUnconfirmedException`, mark the stage unsafe to delete.

- [ ] Add a separately gated real fixture test skipped unless `FLUTTER_PRUNER_L10N_TEST_SDK` names an exact supported canonical binary. It must prove raw `l10n.yaml` is honored, outputs stay inside the allowlist, and package configuration/lock hashes do not change.

- [ ] Run and commit:

```sh
dart test test/adapters/l10n/action_readiness/l10n_stage_inventory_test.dart test/adapters/l10n/action_readiness/l10n_generator_test.dart
git add lib/src/adapters/l10n/action_readiness/l10n_stage_inventory.dart lib/src/adapters/l10n/action_readiness/l10n_generator.dart test/adapters/l10n/action_readiness/l10n_stage_inventory_test.dart test/adapters/l10n/action_readiness/l10n_generator_test.dart test/fixtures/l10n_action_readiness/process
git commit -m "feat: run and inventory staged l10n generation"
```

## Task 11: Reproduce live output and reconcile the candidate delta

**Files:**

- Create: `lib/src/adapters/l10n/action_readiness/l10n_output_reconciler.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_output_reconciler_test.dart`
- Create fixtures: `test/fixtures/l10n_action_readiness/output_families/`

- [ ] Write failing cases for exact baseline reproduction, stale missing output, stale/provenance sibling, unrelated proven-owned unchanged sibling, unexpected file/link/type/mode/content write, sidecar behavior, custom output directory/class, regional locales sharing one base-language file, and candidate output creation/deletion rejection.

- [ ] Implement immutable allowlist/change-set values:

```dart
final class L10nGenerationAllowlist {
  final Set<String> replacementOutputPaths;
  final String? untranslatedSidecarPath;
  final Set<String> provenUnrelatedSiblingPaths;
}

final class L10nFileReplacement {
  final String relativePath;
  final ImmutableBytes beforeBytes;
  final ImmutableBytes afterBytes;
  final int? beforeMode;
  final int? afterMode;
}

final class L10nWitnessedChangeSet {
  final Map<String, L10nFileReplacement> arbReplacements;
  final Map<String, L10nFileReplacement> generatedReplacements;
  final String fingerprint;
}

sealed class L10nReconciliationResult {
  const L10nReconciliationResult();
}

final class L10nReconciliationReady extends L10nReconciliationResult {
  const L10nReconciliationReady(this.changeSet);
  final L10nWitnessedChangeSet changeSet;
}

final class L10nReconciliationRejected extends L10nReconciliationResult {
  const L10nReconciliationRejected(this.failures);
  final List<L10nEvidenceFailure> failures;
}

abstract interface class L10nOutputReconciler {
  L10nReconciliationResult reconcile({
    required L10nFamilySnapshot liveSnapshot,
    required L10nGenerationAllowlist allowlist,
    required L10nGenerationRun baseline,
    required L10nGenerationRun candidate,
  });
}
```

  Implement `DefaultL10nOutputReconciler` as the pure deterministic implementation.

- [ ] Compare each run's before/after tree. Any created/modified/deleted/type/mode path outside the precomputed allowlist is `unexpectedStageWrite`. Any expected baseline output whose type/bytes/mode differs from the live snapshot is `staleGeneratedOutput`. Any generated/provenance sibling without proven ownership is `outputFamilyAmbiguous` even when unchanged.

- [ ] Require candidate output path/type set to equal baseline output path/type set. Creation or deletion returns `outputFamilyAmbiguous`; do not normalize a mode or accept ambient umask. Build the witnessed generated replacement map only from baseline-after to candidate-after exact bytes/modes, and combine it with planner ARB replacements.

- [ ] Ensure an accepted result has no unexpected writes and only immutable sorted maps. Add fingerprint-order tests and prove source paths are project-relative only.

- [ ] Run and commit:

```sh
dart test test/adapters/l10n/action_readiness/l10n_output_reconciler_test.dart
git add lib/src/adapters/l10n/action_readiness/l10n_output_reconciler.dart test/adapters/l10n/action_readiness/l10n_output_reconciler_test.dart test/fixtures/l10n_action_readiness/output_families
git commit -m "feat: reconcile staged l10n output"
```

## Task 12: Verify ARBs, generated members, and the l10n graph in-process

**Files:**

- Create: `lib/src/adapters/l10n/action_readiness/l10n_generated_member_inspector.dart`
- Create: `lib/src/adapters/l10n/action_readiness/l10n_stage_verifier.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_generated_member_inspector_test.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_stage_verifier_test.dart`

- [ ] Write inspector tests for configured output class, removed getter/method still present, retained member missing/wrong shape/ambiguous, placeholder methods, nullable-getter differences, and generated library parse/resolution failure.

- [ ] Implement an analyzer-backed inspector that returns exact member identities rather than source grep:

```dart
final class L10nGeneratedMemberInspection {
  final Map<String, ArbGeneratedMemberKind> membersByMessageKey;
  final List<L10nEvidenceFailure> failures;
  final String identity;
}

final class L10nGeneratedMemberInspector {
  Future<L10nGeneratedMemberInspection> inspect({
    required ProjectContext stagedProject,
    required L10nGenerationConfig config,
    required Map<String, ArbGeneratedMemberKind>
        expectedMemberKindsByKey,
  });
}
```

- [ ] Define the fixed policy and verifier seam. Do not call generic `VerificationRunner` or arbitrary project commands:

```dart
final class L10nStageVerificationPolicy {
  static const schemaVersion = 1;
  static const steps = [
    'arb-postconditions',
    'generated-member-identity',
    'dart-l10n-graph',
    'publishable-path-immutability',
  ];
  String get hash;
}

abstract interface class L10nStageVerifier {
  Future<L10nStageVerificationResult> verify({
    required L10nStageRoot stage,
    required L10nFamilySnapshot snapshot,
    required Set<String> expectedRemovedKeys,
    required L10nToolchainResolved toolchain,
  });
}

final class L10nStageVerificationResult {
  final bool accepted;
  final List<L10nEvidenceFailure> failures;
  final String policyIdentity;
  final String analyzerRootIdentity;
  final String packageResolutionIdentity;
  final String toolchainIdentity;
  final String publishableBeforeIdentity;
  final String publishableAfterIdentity;
  final Map<String, Object?> summary;
}
```

  Implement `DefaultL10nStageVerifier` with a required `L10nGeneratedMemberInspector` dependency.

- [ ] Construct `ProjectContext` directly from staged root and `snapshot.projectSemantics`; do not call `ProjectContext.load`, discover user config, or resolve packages. Require copied package config to map the selected package to the stage and external packages to frozen read-only roots.

- [ ] Reparse all ARBs; prove selected members/companions absent and retained member tokens preserved; use `snapshot.expectedGeneratedMemberKindsByKey` to prove selected generated accessors absent and every retained template message has exactly one getter/method of the frozen expected shape; run `ProjectAnalyzer(project: staged, only: {'l10n'})`; reject dangling endpoints, new family-addressing blockers, incomplete closure, or identity drift.

- [ ] Inventory every publishable ARB/config/generated path before and after verification. Analyzer cache writes outside publishable paths may be retained only in verification evidence; any publishable mutation is `candidateVerificationFailed`.

- [ ] Add baseline-versus-candidate comparison tests for equal policy/analyzer-root/package/toolchain identities and deliberately incomplete closure, live-project package mapping, dangling endpoint, new blocker, policy mismatch, and publishable mutation.

- [ ] Run and commit:

```sh
dart test test/adapters/l10n/action_readiness/l10n_generated_member_inspector_test.dart test/adapters/l10n/action_readiness/l10n_stage_verifier_test.dart
git add lib/src/adapters/l10n/action_readiness/l10n_generated_member_inspector.dart lib/src/adapters/l10n/action_readiness/l10n_stage_verifier.dart test/adapters/l10n/action_readiness/l10n_generated_member_inspector_test.dart test/adapters/l10n/action_readiness/l10n_stage_verifier_test.dart
git commit -m "feat: verify staged l10n mutation evidence"
```

## Task 13: Orchestrate verdict, drift revalidation, and cleanup finality

**Files:**

- Create: `lib/src/adapters/l10n/action_readiness/l10n_evidence_verdict.dart`
- Create: `lib/src/adapters/l10n/action_readiness/l10n_snapshot_revalidator.dart`
- Create: `lib/src/adapters/l10n/action_readiness/l10n_evidence_pipeline.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_snapshot_revalidator_test.dart`
- Create: `test/adapters/l10n/action_readiness/l10n_evidence_pipeline_test.dart`

- [ ] Write verdict tests: accepted has no reason codes; rejected has at least one; codes/details are deterministic; every collection is immutable; serialization contains hashes/metrics but no source bytes, raw output, absolute paths, or environment values.

- [ ] Implement the internal output model:

```dart
enum L10nEvidenceStatus { accepted, rejected }

final class L10nEvidenceVerdict {
  final L10nEvidenceStatus status;
  final List<L10nEvidenceRejectionCode> reasonCodes;
  final List<L10nEvidenceFailure> failures;
  final String familyFingerprint;
  final String selectionFingerprint;
  final String configurationIdentity;
  final String packageResolutionIdentity;
  final String toolchainIdentity;
  final Map<String, String> baselineInventoryHashes;
  final Map<String, String> candidateInventoryHashes;
  final Map<String, Object?> mutationSummary;
  final Map<String, Object?> verificationSummary;
  final Map<String, Object?> timingAndResourceMetrics;

  Map<String, Object?> toInternalJson();
}

final class L10nEvidenceEvaluation {
  final L10nEvidenceVerdict verdict;
  final L10nWitnessedChangeSet? witnessedChangeSet;
}
```

- [ ] Write a typed drift revalidator before orchestrating the pipeline:

```dart
sealed class L10nSnapshotRevalidationResult {
  const L10nSnapshotRevalidationResult();
}

final class L10nSnapshotStillCurrent
    extends L10nSnapshotRevalidationResult {
  const L10nSnapshotStillCurrent({
    required this.sourceIdentity,
    required this.packageResolutionIdentity,
    required this.toolchainIdentity,
  });
  final String sourceIdentity;
  final String packageResolutionIdentity;
  final String toolchainIdentity;
}

final class L10nSnapshotDrifted extends L10nSnapshotRevalidationResult {
  const L10nSnapshotDrifted(this.failures);
  final List<L10nEvidenceFailure> failures;
}

abstract interface class L10nSnapshotRevalidator {
  Future<L10nSnapshotRevalidationResult> revalidate({
    required Directory originalProjectRoot,
    required L10nFamilySnapshot snapshot,
    required L10nToolchainResolved toolchain,
  });
}
```

  Implement `DefaultL10nSnapshotRevalidator` with required `L10nToolchainResolver` and `L10nGenerationConfigLoader` dependencies.

  The default implementation must re-read every source entry byte/hash/mode, raw l10n/pubspec/lock/package files, canonical external dependency roots, selected package mapping, supported selector/probe identity, and strict configuration identity. Return `sourceDrift`, `packageResolutionDrift`, or `toolchainDrift` with stable details; never collapse drift into `false` or exception text.

- [ ] Define request/dependency injection so every boundary can fail deterministically in tests:

```dart
final class L10nEvidenceRequest {
  final AnalysisSnapshot analysis;
  final List<String> selectedNodeIds;
  final L10nSdkRegistry sdkRegistry;
  final L10nToolchainSelection toolchainSelection;
}

final class L10nEvidencePipeline {
  L10nEvidencePipeline({
    required L10nToolchainResolver toolchainResolver,
    required L10nGenerationConfigLoader configLoader,
    required L10nFamilySnapshotter snapshotter,
    required L10nStageMaterializer materializer,
    required L10nGenerator generator,
    required L10nOutputReconciler reconciler,
    required L10nStageVerifier verifier,
    required L10nSnapshotRevalidator revalidator,
  });

  Future<L10nEvidenceEvaluation> evaluate(L10nEvidenceRequest request);
}
```

- [ ] Implement the exact sequence: unchanged scan/selection gate; toolchain resolution; strict config; snapshot/edit; independent materialization; baseline generation/reproduction; candidate ARB install/generation; reconciliation; baseline/candidate fixed verification; typed source/config/package/toolchain revalidation; cleanup; final verdict. Build the redacted mutation summary from `snapshot.mutationPlan`: selected keys, per-path message/companion removal byte spans, generated replacement paths, and mutation fingerprint; never discard this attribution when stages are cleaned.

- [ ] Always call cleanup with the returned `L10nStageCleanupLease` after any materialization attempt, including partial/rejected materialization. Fold `cleanupFailed` into the result and force rejection even if all earlier steps passed. Map expected errors to typed reason codes, unexpected errors to `internalFailure`, and never allow a partially built change set to escape a rejected evaluation.

- [ ] Add one injected failure at every boundary before/after snapshot, materialize, baseline generate, candidate install/generate, reconcile, each verification, each drift check, and cleanup. Hash source bytes/modes/status before/after every case and require no original-tree change. An unconfirmed process leaves only diagnostic staging residue and must never touch the source project.

- [ ] Run the full private-domain test directory and commit:

```sh
dart test test/adapters/l10n/action_readiness
git add lib/src/adapters/l10n/action_readiness/l10n_evidence_verdict.dart lib/src/adapters/l10n/action_readiness/l10n_snapshot_revalidator.dart lib/src/adapters/l10n/action_readiness/l10n_evidence_pipeline.dart test/adapters/l10n/action_readiness/l10n_snapshot_revalidator_test.dart test/adapters/l10n/action_readiness/l10n_evidence_pipeline_test.dart
git commit -m "feat: orchestrate internal l10n evidence verdict"
```

## Task 14: Add strict corpus manifest and disposable mutation evidence

**Files:**

- Create: `benchmark/accuracy/src/l10n_mutation_manifest.dart`
- Create: `benchmark/accuracy/src/corpus_mutation_evidence.dart`
- Create: `test/benchmark/accuracy/corpus_mutation_evidence_test.dart`
- Expand: `test/benchmark/accuracy/l10n_mutation_manifest_test.dart`

- [ ] Write strict reader tests that reject unknown/missing fields, unknown schema/version/project/truth/reason, duplicate IDs/keys, count drift, unsorted cases, wrong source SHA, a positive without exact member maps, a negative with mutation authority, a policy lacking `--no-pub`, shell argv, absolute working directory, and a changed denominator.

- [ ] Implement immutable scanner-independent manifest values. Do not import `L10nEvidenceVerdict` into the parser; map reason strings only at the harness boundary so the oracle remains independent of production output types.

- [ ] Define and test the corpus outcome seam:

```dart
enum CorpusMutationEvidenceStatus {
  passed,
  fullPolicyFailed,
  restorationFailed,
  provisioningFailed,
}

final class L10nMutationProjectManifest {
  final String id;
  final String repositoryRevision;
  final String packageRootRelative;
  final String toolchainVersion;
  final List<CorpusVerificationCommand> verificationPolicy;
}

final class CorpusVerificationCommand {
  final String workingDirectoryRelativeToRepository;
  final List<String> argumentsAfterCanonicalFlutter;
  final String identity;
}

final class CorpusMutationEvidenceOutcome {
  final CorpusMutationEvidenceStatus status;
  final String candidateIdentity;
  final String familyIdentity;
  final String installedChangeSetHash;
  final String policyHash;
  final List<Map<String, Object?>> commandResults;
  final String beforeManagedFingerprint;
  final String afterManagedFingerprint;
  final bool restorationVerified;
}

final class CorpusProjectView {
  final Directory repositoryRoot;
  final Directory packageRoot;
  final String repositoryRevision;
  final String provisionedBaselineFingerprint;
  final String baselineGitStatusIdentity;
}

sealed class CorpusProjectViewCreationResult {
  const CorpusProjectViewCreationResult();
}

final class CorpusProjectViewReady extends CorpusProjectViewCreationResult {
  const CorpusProjectViewReady(this.view);
  final CorpusProjectView view;
}

final class CorpusProjectViewRejected extends CorpusProjectViewCreationResult {
  const CorpusProjectViewRejected(this.outcome);
  final CorpusMutationEvidenceOutcome outcome;
}

abstract interface class CorpusProjectViewFactory {
  Future<CorpusProjectViewCreationResult> create({
    required L10nMutationProjectManifest project,
    required String retainedRepositoryPath,
    required String canonicalFlutterExecutable,
  });
}
```

- [ ] Implement a policy validator allowing only canonical Flutter `analyze`, `test`, and explicitly declared build commands. Every analyze/test argv must contain `--no-pub`; every build command must also contain `--no-pub`. Reject FVM/wrapper/shell/custom commands and any working directory outside the disposable repository.

- [ ] Implement `CorpusProjectViewFactory` with disposable local clones at the exact repository SHA, with no network. Apply manifest-declared non-secret overlays and the complete GSY normalized family before provisioning. Permit one unmeasured canonical `flutter pub get --offline` in the package root, then capture the baseline repository/package/config/lock/toolchain fingerprint. No resolution command is allowed after this capture. This provisioned view is the only project root passed to the unchanged scanner and internal pipeline; the retained corpus clone remains read-only.

- [ ] Install a defensively copied `L10nWitnessedChangeSet` only into the disposable clone; validate every before hash/mode, write exact after bytes/modes, run the complete policy sequentially, then restore exact before bytes/modes in reverse path order. Rehash all managed paths and compare Git status to the captured post-provisioning baseline status, which may already contain declared overlays. A failed policy still attempts restoration; failed restoration is authoritative over policy status.

- [ ] Use fakes to prove provisioning failure, policy failure, partial install, source drift, command timeout/truncation/unconfirmed termination, successful restoration, restoration failure, no write to original clones, and no call to production apply/quarantine.

- [ ] Run and commit:

```sh
dart test test/benchmark/accuracy/l10n_mutation_manifest_test.dart test/benchmark/accuracy/corpus_mutation_evidence_test.dart
git add benchmark/accuracy/src/l10n_mutation_manifest.dart benchmark/accuracy/src/corpus_mutation_evidence.dart test/benchmark/accuracy/l10n_mutation_manifest_test.dart test/benchmark/accuracy/corpus_mutation_evidence_test.dart
git commit -m "feat: verify l10n changes in disposable corpora"
```

## Task 15: Build the internal accuracy harness and fresh Stage 1 gate artifact

**Files:**

- Create: `benchmark/accuracy/l10n_mutation_readiness.dart`
- Create: `test/benchmark/accuracy/l10n_mutation_readiness_test.dart`
- Create only after a completely successful run: `benchmark/accuracy/baselines/v3.1-l10n-stage1.json`

- [ ] Write fake harness tests for one individual candidate, one family batch, one static negative, one mutation-negative fixture, resume from an already-passed case, reject stale partial evidence, deterministic JSON, and exit nonzero unless every configured denominator is met.

- [ ] Implement argv parsing with explicit inputs and no product CLI registration:

```text
--manifest <repo-relative manifest>
--corpus-root <absolute retained-corpus parent>
--sdk <version=canonical-flutter-path>   # exactly three occurrences
--output <result json>
--resume <existing result json>          # optional, identity-checked
--case <project:key>                      # optional smoke selection
--family <project>                        # optional family smoke selection
```

- [ ] For every attempt, create a provisioned `CorpusProjectView` first, then run the unchanged scanner and internal pipeline against that disposable view. For GSY, apply and verify `gsy-normalized-family-v1.json` before the scanner; separately run the raw pinned GSY input as a negative fixture and require `ANALYSIS LIMITED`/rejection. Never scan raw GSY and then swap normalized bytes underneath its `AnalysisSnapshot`.

- [ ] Compare each complete static l10n result to the frozen oracle: all 378 positives are candidates, all 2,224 negatives are non-candidates, zero public l10n SAFE/HIGH, zero report-projected `applyEligible`, and zero proposed actions. A mismatch blocks mutation evidence rather than relabeling the oracle.

- [ ] Run `L10nEvidencePipeline` independently for each of 378 positive keys and once for the complete positive batch in each of three families. For each accepted internal verdict, immediately run `CorpusMutationEvidenceOutcome` in the disposable complete clone, prove restoration, then discard or identity-reset that clone before the next case. Run every predeclared mutation-negative fixture and require one of only its allowed reasons.

- [ ] Emit stable project/case/family records with oracle, scan, verdict, corpus policy, restoration, bytes copied, stage/generator/policy durations, and sampled peak RSS identities. Do not emit raw bytes/output/absolute paths/environment values. Resume only when manifest/repository/config/package/toolchain/policy identities all match.

- [ ] Add a predeclared performance characterization for one lexically first positive per project. Record three `fresh-view-cold` samples, each with a newly provisioned disposable view and a new pipeline object, then one unmeasured priming run and five `restored-view-warm` samples that reuse only the provisioned complete view after exact restoration while still creating fresh baseline/candidate staging roots. Do not clear or mutate shared Flutter/pub caches, and label this scope explicitly rather than claiming machine-cold behavior.

- [ ] Compute deterministic odd-sample medians by sorting integer microseconds/bytes and selecting index `length ~/ 2`. Persist cold/warm sample counts and medians separately for total stage time, baseline generator time, candidate generator time, copied-byte count, and sampled peak process-tree RSS. Any failed sample blocks that project's performance record; it never disappears from the denominator and never triggers concurrency/caching optimization.

- [ ] Provision the missing exact Flutter 3.38.7 SDK outside the repository before the real run. Confirm 3.38.7, 3.41.5, and 3.44.1 canonical binaries all direct-probe successfully; never substitute 3.44.9 for Smooth.

- [ ] Run one real smoke candidate per project and one real family smoke with an external output path. Verify original corpus clones remain byte/mode/status clean:

```sh
dart run benchmark/accuracy/l10n_mutation_readiness.dart \
  --manifest benchmark/accuracy/manifests/l10n-mutation-readiness-v1.json \
  --corpus-root /Users/nhan/Desktop/flutter_pruner_benchmar_sample \
  --sdk 3.38.7=/Users/nhan/fvm/versions/3.38.7/bin/flutter \
  --sdk 3.41.5=/Users/nhan/fvm/versions/3.41.5/bin/flutter \
  --sdk 3.44.1=/Users/nhan/fvm/versions/3.44.1/bin/flutter \
  --output /tmp/flutter-pruner-l10n-stage1-smoke.json \
  --case smooth:about_this_app
```

- [ ] Start the complete sequential run with a durable output path and identity-checked resume. This is a long-running evidence gate; monitor it without introducing concurrency or shared mutable staging:

```sh
dart run benchmark/accuracy/l10n_mutation_readiness.dart \
  --manifest benchmark/accuracy/manifests/l10n-mutation-readiness-v1.json \
  --corpus-root /Users/nhan/Desktop/flutter_pruner_benchmar_sample \
  --sdk 3.38.7=/Users/nhan/fvm/versions/3.38.7/bin/flutter \
  --sdk 3.41.5=/Users/nhan/fvm/versions/3.41.5/bin/flutter \
  --sdk 3.44.1=/Users/nhan/fvm/versions/3.44.1/bin/flutter \
  --output /Users/nhan/Desktop/flutter_pruner_benchmar_sample/results/v3.1-l10n-stage1.json \
  --resume /Users/nhan/Desktop/flutter_pruner_benchmar_sample/results/v3.1-l10n-stage1.json
```

- [ ] Create the committed baseline only if the fresh result proves all of the following. Otherwise keep the task incomplete and report the exact blocking identities/reasons:

```dart
expect(summary.acceptedIndividualKeys, 378);
expect(summary.acceptedFamilyBatches, 3);
expect(summary.staticNegativeNonCandidates, 2224);
expect(summary.fullPolicyFailures, 0);
expect(summary.provenRestorations, 381);
expect(summary.requiredRestorations, 381);
expect(summary.unexpectedWritesForAccepted, 0);
expect(summary.originalProjectDriftCount, 0);
expect(summary.publicSafeL10n, 0);
expect(summary.publicHighL10n, 0);
expect(summary.publicProposedL10nActions, 0);
```

- [ ] Copy the redaction-safe result projection to `benchmark/accuracy/baselines/v3.1-l10n-stage1.json`, retain the full external artifact SHA-256, rerun its schema test, and commit:

```sh
dart test test/benchmark/accuracy/l10n_mutation_readiness_test.dart
git add benchmark/accuracy/l10n_mutation_readiness.dart benchmark/accuracy/baselines/v3.1-l10n-stage1.json test/benchmark/accuracy/l10n_mutation_readiness_test.dart
git commit -m "test: prove l10n stage one mutation readiness"
```

## Task 16: Lock public boundaries and run repository-wide verification

**Files:**

- Create: `test/adapters/l10n/action_readiness/stage1_public_boundary_test.dart`
- Modify only if a pre-existing assertion is missing: `test/adapters/l10n_adapter_test.dart`

- [ ] Add an integration test over `test/fixtures/l10n_test` that runs the normal analyzer and asserts every l10n `Finding` remains REVIEW with `proposedAction == null` in application, package-internal, and package modes. Assert `applyEligible == false` only on the report/JSON projection, because it is not a `Finding` field.

- [ ] Add an architecture-boundary test that scans production imports beneath `lib/src/analysis`, `lib/src/core/confidence`, `lib/src/cli`, `lib/src/apply`, and `lib/src/quarantine` and rejects any import/reference to `adapters/l10n/action_readiness`. Assert `lib/flutter_pruner.dart` does not export it.

- [ ] Snapshot source bytes/modes before and after normal scan/apply-planning tests and assert no staging directory or `flutter gen-l10n` process is started. Construct a real localization-key `GraphNode`, pass it to `ActionCapability.forFinding(adapterId: 'l10n', node: localizationNode)`, require `supported == false`, and do not change the enum/action builder.

- [ ] Invoke the product executable and formatter seams against the same fixture used by Task 1. Remove only the declared timing fields, then require exact equality with the manifest's frozen top-level/subcommand help hashes, CLI option names, terminal/JSON/HTML hashes, report schema keys, ordered finding IDs/tiers/classification reasons, and blocker identities. Add no Stage 1 field to any projection.

- [ ] Re-run the retained V2 natural-accuracy comparison and require the existing 378 l10n TP, 2,224 l10n TN, zero FP/FN, REVIEW-only tiers, blocker identities, and deterministic normalized scan fingerprints. Run the existing apply/planner/quarantine/rollback/recovery tests to prove no new l10n action or manifest case exists.

- [ ] Invoke `flutter-minimal-diff`, format only touched Dart files, and verify formatting without rewriting unrelated code:

```sh
dart format lib/src/adapters/l10n/action_readiness lib/src/core/process/managed_process_runner.dart benchmark/accuracy test/adapters/l10n/action_readiness test/benchmark/accuracy test/core/process/managed_process_runner_test.dart test/verification/verification_runner_test.dart test/apply/import_cleanup_runner_test.dart test/quarantine/quarantine_manager_test.dart
git diff --check
```

- [ ] Run focused l10n/process/benchmark tests, then the complete analyzer/test/package gates:

```sh
dart test test/adapters/l10n test/core/process/managed_process_runner_test.dart test/benchmark/accuracy
dart test test/cli/scan_command_test.dart test/cli/apply_command_test.dart test/cli/formatters/human_formatter_test.dart test/cli/formatters/json_formatter_test.dart test/cli/formatters/html_formatter_test.dart test/quarantine/manifest_test.dart test/cli/rollback_command_test.dart test/reporting/report_recovery_inspector_test.dart
dart analyze --fatal-infos
dart test
dart pub publish --dry-run
```

- [ ] Re-run the Stage 1 baseline schema/identity validation without rerunning the long corpus unless code or any bound identity changed. If production/config/toolchain/policy/oracle identity changed, invalidate the baseline and rerun Task 15 rather than accepting stale evidence.

- [ ] Request a final code review focused on fail-closed behavior, source ownership, no-resolution enforcement, byte immutability, cleanup finality, public boundary, exact denominator, and original-tree restoration. Resolve every finding and rerun the affected gate.

- [ ] Commit only the regression boundary changes:

```sh
git add test/adapters/l10n/action_readiness/stage1_public_boundary_test.dart test/adapters/l10n_adapter_test.dart
git commit -m "test: lock l10n stage one public boundaries"
```

- [ ] Stop after Stage 1. Report the exact evidence artifact SHA, commit SHAs, test/analyzer/dry-run results, 378/378 individual results, 3/3 family results, 2,224/2,224 static negatives, 381/381 restorations, and any retained staging residue. Request separate approval and a new plan before promotion, apply/quarantine integration, or public confidence changes.

---

## Spec Coverage Checklist

- Oracle frozen and independently reviewed before production code: Task 1.
- Immutable bytes and exact ARB token removal: Tasks 2–4.
- Exact supported config/toolchain identity: Tasks 6–7.
- Complete family/closure/resolution snapshot: Task 8.
- Independent isolated roots and cleanup: Task 9.
- Canonical `gen-l10n`, bounded output, termination, and RSS evidence: Tasks 5 and 10.
- Baseline reproduction, write allowlist, replacement-only candidate delta: Task 11.
- Fixed domain verification with no dependency resolution: Task 12.
- Exhaustive deterministic verdict and drift checks: Task 13.
- Complete-copy policy, restoration, natural corpus, and exit denominator: Tasks 14–15.
- Scoped cold/warm medians, copied bytes, and process-tree RSS: Task 15.
- REVIEW-only/no-action/no-public-path invariants: Task 16.
- Promotion/apply/quarantine/public report changes: explicitly excluded from every task.

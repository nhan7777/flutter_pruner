# Safe l10n Removal V3.1 Stage 2 (Promotion) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote Stage 1's internal mutation evidence pipeline to public actionability. Enable l10n findings to propose safe removal actions, integrate with apply/quarantine workflow, and support atomic family-level mutations with rollback guarantees while preserving Flutter Pruner's fail-closed confidence model.

**Prerequisites:** 
- Stage 1 complete with all 16 tasks passing
- 378/378 positives, 2,224/2,224 negatives, 3/3 families, 381/381 restorations validated
- Public boundaries locked (no Stage 1 leakage)

**Architecture:** Add `StaticActionReadinessResolver` as a core-owned step in `ProjectAnalyzer` after adapters finish. Introduce `L10nRemovalBatch` for family-level atomic transactions. Integrate with `QuarantineManager` for V3 transactions supporting journal → install → verify → commit/rollback workflow. Update `ActionCapability`, `FindingGenerator`, and `RemovalPlanner` to recognize l10n family-level actions with `boundedFamily` risk scope.

**Tech Stack:** Dart 3.9+, existing Stage 1 action_readiness domain, `ProjectAnalyzer`, `FindingGenerator`, `ActionCapability`, `RemovalPlanner`, `QuarantineManager`, `package:test`.

**Spec:** [Safe l10n Removal V3.1 Design](../specs/2026-08-22-safe-l10n-removal-v3-1-design.md) — Promotion Architecture section (line 508+)

## Global Constraints

- Promotion builds on Stage 1's internal pipeline without modifying its contracts.
- Static action-readiness resolution runs during ordinary scan but does NOT execute Flutter or staging at scan time.
- Fresh preflight runs the complete staging pipeline immediately before live mutation. Never load an earlier Stage 1 evidence artifact as publication authority.
- L10n mutations are atomic at the family boundary. No partial per-key success.
- Quarantine journals exact bytes/modes, installs candidate bytes (never regenerates), verifies in-place, and commits or restores all-or-nothing.
- Rollback never runs `gen-l10n`. Restoration uses journaled bytes only.
- Application mode may reach `SAFE` confidence. Package-internal mode is `HIGH` max with explicit acknowledgement. Package mode remains scan-only.
- L10n verification default is explicit no-resolution: `flutter analyze --no-pub --fatal-infos` + `flutter test --no-pub`. Project overrides require typed no-resolution contracts.
- Generic package override is not weakened. Any scoped blocker (dynamic lookup, malformed ARB, incomplete coverage, output ambiguity) disqualifies.
- Before formatting an existing Dart file, invoke `flutter-minimal-diff`; format only touched files.
- Each task ends with focused tests and its own local commit. Do not push, merge, tag, release, or publish.

---

## File Map

### New core production files

- `lib/src/core/confidence/mutation_footprint.dart` — exact logical findings + physical paths owned by an atomic unit.
- `lib/src/core/confidence/action_risk_scope.dart` — `boundedSingle`, `boundedFamily`, `openEnded` enumeration.
- `lib/src/core/confidence/static_action_readiness_resolver.dart` — core-owned resolver step for family-level capabilities.
- `lib/src/core/confidence/action_readiness_index.dart` — immutable index keyed by node ID, returned by resolver.

### New l10n production files

- `lib/src/adapters/l10n/l10n_removal_batch.dart` — family-level atomic batch: ARB edits + generated outputs + fingerprints + finding IDs.
- `lib/src/adapters/l10n/l10n_action_descriptor.dart` — l10n-specific action descriptor with family-level metadata.
- `lib/src/adapters/l10n/l10n_action_capability.dart` — l10n-specific capability factory integrated with `ActionCapability`.
- `lib/src/adapters/l10n/l10n_publication_preflight.dart` — fresh staging pipeline runner before live mutation.
- `lib/src/adapters/l10n/l10n_verification_policy.dart` — explicit no-resolution verification policy.

### Modified core production files

- `lib/src/core/analysis/project_analyzer.dart` — integrate `StaticActionReadinessResolver` after adapters, before finding generation.
- `lib/src/core/finding/finding_generator.dart` — accept action readiness index, propagate to l10n findings.
- `lib/src/core/confidence/action_capability.dart` — delegate to l10n-specific capability when index available.
- `lib/src/apply/removal_planner.dart` — recognize l10n family-level batches.
- `lib/src/apply/finding_action_builder.dart` — build l10n removal actions from batch.

### Modified quarantine files

- `lib/src/quarantine/quarantine_manager.dart` — support V3 transactions with journal → install → verify → commit/rollback.
- `lib/src/quarantine/quarantine_transaction.dart` — add `absent` before-state support for initial l10n cohort.
- `lib/src/quarantine/quarantine_manifest.dart` — track family-level logical finding IDs.

### CLI integration

- `lib/src/cli/commands/apply_command.dart` — handle l10n family-level actions.
- `lib/src/cli/formatters/finding_formatter.dart` — display l10n actionable findings with family context.

### New tests

- `test/core/confidence/mutation_footprint_test.dart`
- `test/core/confidence/action_risk_scope_test.dart`
- `test/core/confidence/static_action_readiness_resolver_test.dart`
- `test/core/confidence/action_readiness_index_test.dart`
- `test/adapters/l10n/l10n_removal_batch_test.dart`
- `test/adapters/l10n/l10n_action_descriptor_test.dart`
- `test/adapters/l10n/l10n_action_capability_test.dart`
- `test/adapters/l10n/l10n_publication_preflight_test.dart`
- `test/adapters/l10n/l10n_verification_policy_test.dart`
- `test/integration/l10n_apply_integration_test.dart` — end-to-end apply workflow
- `test/integration/l10n_rollback_integration_test.dart` — failure/rollback scenarios

### Modified tests

- `test/core/analysis/project_analyzer_test.dart` — resolver integration
- `test/core/finding/finding_generator_test.dart` — index propagation
- `test/core/confidence/action_capability_test.dart` — l10n delegation
- `test/apply/removal_planner_test.dart` — l10n batch recognition
- `test/quarantine/quarantine_manager_test.dart` — V3 transaction support

---

## Task Breakdown

### Task 1: Core action risk scope and mutation footprint primitives

**Goal:** Introduce `ActionRiskScope` and `MutationFootprint` to split the overloaded scope concept.

**Files to create:**
- `lib/src/core/confidence/action_risk_scope.dart`
- `lib/src/core/confidence/mutation_footprint.dart`
- `test/core/confidence/action_risk_scope_test.dart`
- `test/core/confidence/mutation_footprint_test.dart`

**Requirements:**

- [ ] Define `ActionRiskScope` enum with three values:
  ```dart
  enum ActionRiskScope {
    /// Single file/declaration, existing narrow actions
    boundedSingle,
    
    /// Family-level proven actions (l10n ARB family + generated outputs)
    boundedFamily,
    
    /// Open-ended broad actions (existing broadRemovalScope behavior)
    openEnded,
  }
  ```

- [ ] Implement `MutationFootprint` class capturing:
  ```dart
  final class MutationFootprint {
    /// Logical finding IDs owned by this atomic unit
    final Set<String> findingIds;
    
    /// Physical file paths that will be mutated
    final Set<String> physicalPaths;
    
    /// Action risk scope classification
    final ActionRiskScope riskScope;
    
    /// Family identifier for family-level actions (null for single actions)
    final String? familyId;
  }
  ```

- [ ] Add validation: `boundedFamily` must have non-null `familyId`, `boundedSingle` must have exactly one finding ID (may have multiple paths for generated outputs).

- [ ] Write tests covering:
  - Enum serialization/deserialization
  - Footprint validation rules
  - Single-file action → `boundedSingle`
  - L10n family action → `boundedFamily` with family ID
  - Broad action → `openEnded`

- [ ] Commit:
  ```sh
  git add lib/src/core/confidence/action_risk_scope.dart \
          lib/src/core/confidence/mutation_footprint.dart \
          test/core/confidence/action_risk_scope_test.dart \
          test/core/confidence/mutation_footprint_test.dart
  git commit -m "feat(core): add action risk scope and mutation footprint primitives"
  ```

---

### Task 2: Action readiness index structure

**Goal:** Define the immutable index structure returned by `StaticActionReadinessResolver`.

**Files to create:**
- `lib/src/core/confidence/action_readiness_index.dart`
- `test/core/confidence/action_readiness_index_test.dart`

**Requirements:**

- [ ] Define `ActionReadinessEntry` capturing per-node readiness:
  ```dart
  final class ActionReadinessEntry {
    final String adapterId;
    final NodeKind nodeKind;
    final String familyId;
    final String configurationFingerprint;
    final MutationFootprint mutationFootprint;
    final DeterministicInverseKind inverseKind;
    final ActionRiskScope riskScope;
    final bool hasExternalConsumerExposure;
  }
  ```

- [ ] Define `ActionReadinessIndex` as immutable map:
  ```dart
  final class ActionReadinessIndex {
    final Map<String, ActionReadinessEntry> _entries;
    
    ActionReadinessIndex(Map<String, ActionReadinessEntry> entries)
        : _entries = Map.unmodifiable(entries);
    
    ActionReadinessEntry? operator [](String nodeId) => _entries[nodeId];
    
    bool containsNode(String nodeId) => _entries.containsKey(nodeId);
    
    Iterable<ActionReadinessEntry> get entries => _entries.values;
    
    static final ActionReadinessIndex empty = 
        ActionReadinessIndex(const {});
  }
  ```

- [ ] Add factory constructors for empty index and from-entries builder.

- [ ] Implement equality/hashCode for value semantics (index comparison in tests).

- [ ] Write tests:
  - Empty index behavior
  - Single entry lookup
  - Multiple entries with different adapter IDs
  - Node ID normalization (canonical format)
  - Immutability (attempting to modify map throws)

- [ ] Commit:
  ```sh
  git add lib/src/core/confidence/action_readiness_index.dart \
          test/core/confidence/action_readiness_index_test.dart
  git commit -m "feat(core): add action readiness index structure"
  ```

---

### Task 3: Static action readiness resolver interface and core integration

**Goal:** Add `StaticActionReadinessResolver` interface and integrate into `ProjectAnalyzer`.

**Files to create:**
- `lib/src/core/confidence/static_action_readiness_resolver.dart`
- `test/core/confidence/static_action_readiness_resolver_test.dart`

**Files to modify:**
- `lib/src/core/analysis/project_analyzer.dart`
- `test/core/analysis/project_analyzer_test.dart`

**Requirements:**

- [ ] Define `StaticActionReadinessResolver` interface:
  ```dart
  abstract interface class StaticActionReadinessResolver {
    /// Resolve action readiness after all adapters finish, before finding generation.
    /// Returns index keyed by canonical node ID.
    /// Must perform only bounded static work (no Flutter execution, no staging).
    Future<ActionReadinessIndex> resolve({
      required ReachabilityGraph graph,
      required ProjectContext project,
      required GraphIntegrityReport integrity,
    });
  }
  ```

- [ ] Create `NoOpResolver` implementation returning empty index (default):
  ```dart
  final class NoOpActionReadinessResolver 
      implements StaticActionReadinessResolver {
    const NoOpActionReadinessResolver();
    
    @override
    Future<ActionReadinessIndex> resolve({
      required ReachabilityGraph graph,
      required ProjectContext project,
      required GraphIntegrityReport integrity,
    }) async => ActionReadinessIndex.empty;
  }
  ```

- [ ] Modify `ProjectAnalyzer` to accept optional resolver in constructor:
  ```dart
  final StaticActionReadinessResolver _actionReadinessResolver;
  
  ProjectAnalyzer({
    // ... existing params
    StaticActionReadinessResolver? actionReadinessResolver,
  }) : _actionReadinessResolver = 
           actionReadinessResolver ?? const NoOpActionReadinessResolver();
  ```

- [ ] Update `analyze()` method to run resolver after adapters, before finding generation:
  ```dart
  // After all adapters complete and integrity is computed
  final actionReadinessIndex = await _actionReadinessResolver.resolve(
    graph: graph,
    project: project,
    integrity: integrity,
  );
  
  // Pass index to FindingGenerator
  final findings = _findingGenerator.generate(
    graph: graph,
    project: project,
    graphIntegrity: integrity,
    reportingNodeSchemes: reportingNodeSchemes,
    actionReadinessIndex: actionReadinessIndex, // NEW
  );
  ```

- [ ] Write tests:
  - Default NoOp resolver returns empty index
  - Custom resolver integration (fake resolver returning test entries)
  - Resolver called after adapters, before findings
  - Resolver errors propagate correctly

- [ ] Update existing `ProjectAnalyzer` tests to verify backward compatibility (no resolver provided = no change in behavior).

- [ ] Commit:
  ```sh
  git add lib/src/core/confidence/static_action_readiness_resolver.dart \
          lib/src/core/analysis/project_analyzer.dart \
          test/core/confidence/static_action_readiness_resolver_test.dart \
          test/core/analysis/project_analyzer_test.dart
  git commit -m "feat(core): integrate static action readiness resolver into ProjectAnalyzer"
  ```

---

### Task 4: FindingGenerator index propagation

**Goal:** Update `FindingGenerator` to accept action readiness index and make it available during finding classification.

**Files to modify:**
- `lib/src/core/finding/finding_generator.dart`
- `test/core/finding/finding_generator_test.dart`

**Requirements:**

- [ ] Add optional `actionReadinessIndex` parameter to `generate()` method:
  ```dart
  List<Finding> generate({
    required ReachabilityGraph graph,
    required ProjectContext project,
    required GraphIntegrityReport graphIntegrity,
    required Set<String> reportingNodeSchemes,
    ActionReadinessIndex? actionReadinessIndex, // NEW
  })
  ```

- [ ] Store index in generator context during generation (field or closure scope).

- [ ] Make index available to confidence/capability classification logic (pass to `ActionCapability.forFinding` or store for later access).

- [ ] Preserve existing behavior when index is null or empty: findings remain REVIEW-only as before.

- [ ] Write tests:
  - No index provided → existing behavior (REVIEW-only l10n findings)
  - Empty index provided → same as no index
  - Index with entry for node → capability lookup uses index
  - Index with entry for different adapter → no effect on other adapters

- [ ] Commit:
  ```sh
  git add lib/src/core/finding/finding_generator.dart \
          test/core/finding/finding_generator_test.dart
  git commit -m "feat(core): propagate action readiness index through FindingGenerator"
  ```

---

### Task 5: L10n removal batch model

**Goal:** Define `L10nRemovalBatch` representing one family-level atomic transaction.

**Files to create:**
- `lib/src/adapters/l10n/l10n_removal_batch.dart`
- `test/adapters/l10n/l10n_removal_batch_test.dart`

**Requirements:**

- [ ] Define `L10nArbMutation` for one ARB file edit:
  ```dart
  final class L10nArbMutation {
    final String relativePath;
    final ImmutableBytes originalBytes;
    final String originalHash;
    final ImmutableBytes candidateBytes;
    final String candidateHash;
    final int mode;
  }
  ```

- [ ] Define `L10nGeneratedOutputMutation` for generated Dart files:
  ```dart
  final class L10nGeneratedOutputMutation {
    final String relativePath;
    final ImmutableBytes? originalBytes; // null if absent before
    final String? originalHash;
    final ImmutableBytes candidateBytes;
    final String candidateHash;
    final int mode;
  }
  ```

- [ ] Define `L10nRemovalBatch`:
  ```dart
  final class L10nRemovalBatch {
    final String familyId;
    final Set<String> selectedKeys;
    final Set<String> findingIds;
    
    final List<L10nArbMutation> arbMutations;
    final List<L10nGeneratedOutputMutation> generatedOutputMutations;
    
    final String configurationFingerprint;
    final String packageResolutionFingerprint;
    final String toolchainFingerprint;
    
    final MutationFootprint footprint;
  }
  ```

- [ ] Add validation:
  - At least one ARB mutation
  - At least one finding ID
  - Footprint must be `boundedFamily` with matching `familyId`
  - All paths must be relative to project root
  - No duplicate paths across ARB and generated mutations

- [ ] Add factory constructor from Stage 1 `L10nEvidenceVerdict`:
  ```dart
  factory L10nRemovalBatch.fromEvidence({
    required L10nEvidenceVerdict evidence,
    required Set<String> findingIds,
  })
  ```

- [ ] Write tests:
  - Batch construction from evidence
  - Validation rules
  - Single key removal
  - Multiple keys removal
  - Template + multiple locales
  - Generated outputs (existing + new files for later)
  - Footprint consistency

- [ ] Commit:
  ```sh
  git add lib/src/adapters/l10n/l10n_removal_batch.dart \
          test/adapters/l10n/l10n_removal_batch_test.dart
  git commit -m "feat(l10n): add removal batch model for family-level transactions"
  ```

---

### Task 6: L10n verification policy

**Goal:** Define explicit no-resolution verification policy for l10n mutations.

**Files to create:**
- `lib/src/adapters/l10n/l10n_verification_policy.dart`
- `test/adapters/l10n/l10n_verification_policy_test.dart`

**Requirements:**

- [ ] Define `L10nVerificationPolicy` with explicit no-resolution contract:
  ```dart
  final class L10nVerificationPolicy {
    final String flutterBinaryPath;
    
    /// Default l10n verification: no dependency resolution
    static const List<String> defaultAnalyzeCommand = [
      'analyze',
      '--no-pub',
      '--fatal-infos',
    ];
    
    static const List<String> defaultTestCommand = [
      'test',
      '--no-pub',
    ];
    
    /// Validate that project verification override has no-resolution contract
    static bool hasNoResolutionContract(List<String> command) {
      return command.contains('--no-pub') || 
             command.contains('--no-deps');
    }
  }
  ```

- [ ] Add policy validation:
  ```dart
  enum VerificationPolicyValidation {
    accepted,
    rejectedNoContract,
    rejectedResolutionRequired,
  }
  
  VerificationPolicyValidation validateOverride({
    required List<String> analyzeCommand,
    required List<String> testCommand,
  })
  ```

- [ ] Rejection when project override lacks no-resolution contract (commands without `--no-pub`).

- [ ] Write tests:
  - Default policy accepted
  - Override with `--no-pub` accepted
  - Override with `--no-deps` accepted
  - Override without no-resolution contract rejected
  - Override with implicit resolution (`flutter test` alone) rejected

- [ ] Commit:
  ```sh
  git add lib/src/adapters/l10n/l10n_verification_policy.dart \
          test/adapters/l10n/l10n_verification_policy_test.dart
  git commit -m "feat(l10n): add explicit no-resolution verification policy"
  ```

---

### Task 7: L10n publication preflight ~~[OBSOLETE - SKIP]~~

**Status:** ~~Task không cần thiết - chức năng đã được implement sẵn trong `L10nEvidencePipeline`.~~

**Lý do skip:**
1. `L10nEvidencePipeline.evaluate()` đã có drift detection qua `L10nSnapshotRevalidator`
2. Pipeline đã revalidate source hashes, config, và toolchain trong mỗi lần chạy
3. Việc tạo wrapper mỏng chỉ delegate đến pipeline là over-engineering
4. API trong plan mô tả không khớp với codebase thực tế:
   - Plan giả định `runFreshPreflight` với `ProjectContext` và `L10nFamilySnapshot`
   - Thực tế pipeline cần `L10nEvidenceRequest` với `AnalysisSnapshot`
   - Pipeline trả về `L10nEvidenceEvaluation` (chứa verdict + witnessedChangeSet)

**Quyết định:** Skip Task 7, tiếp tục Task 8.

---

**ORIGINAL OBSOLETE REQUIREMENTS** (giữ lại để tham khảo):

~~**Goal:** Fresh staging pipeline runner immediately before live mutation.~~

~~**Files to create:**~~
- ~~`lib/src/adapters/l10n/l10n_publication_preflight.dart`~~
- ~~`test/adapters/l10n/l10n_publication_preflight_test.dart`~~

~~**Requirements:**~~

- ~~[ ] Define `L10nPublicationPreflight` orchestrating fresh staging~~
- ~~[ ] Preflight steps: revalidate paths/hashes/modes, run pipeline, detect drift~~
- ~~[ ] Drift detection: source/config/toolchain/output changes → reject~~
- ~~[ ] Never load earlier Stage 1 evidence as authority. Always rerun.~~
- ~~[ ] Write tests for drift detection scenarios~~

---

### Task 8: L10n action descriptor and capability

**Goal:** L10n-specific action descriptor with family-level metadata and capability factory.

**Files to create:**
- `lib/src/adapters/l10n/l10n_action_descriptor.dart`
- `lib/src/adapters/l10n/l10n_action_capability.dart`
- `test/adapters/l10n/l10n_action_descriptor_test.dart`
- `test/adapters/l10n/l10n_action_capability_test.dart`

**Files to modify:**
- `lib/src/core/confidence/action_capability.dart`
- `test/core/confidence/action_capability_test.dart`

**Requirements:**

- [ ] Define `L10nActionDescriptor`:
  ```dart
  final class L10nActionDescriptor {
    final String familyId;
    final Set<String> selectedKeys;
    final MutationFootprint footprint;
    final bool hasExternalConsumerExposure;
    
    ActionRiskScope get riskScope => ActionRiskScope.boundedFamily;
  }
  ```

- [ ] Define `L10nActionCapability` factory:
  ```dart
  final class L10nActionCapability {
    static ActionCapability forLocalizationKey({
      required GraphNode node,
      required ActionReadinessEntry readinessEntry,
      required ProjectContext project,
    }) {
      // Check node is localization key
      // Check no scoped blockers
      // Determine confidence based on mode
      // Return capability with descriptor
    }
  }
  ```

- [ ] Update `ActionCapability.forFinding` to delegate to l10n capability when:
  - Node is `NodeKind.localizationKey`
  - Action readiness index has entry for this node

- [ ] Confidence rules:
  - **Application mode:** `SAFE` when complete closure + no blockers + action supported
  - **Package-internal mode:** `HIGH` max, `externalConsumersNotScanned` manual risk
  - **Package mode:** unsupported (scan-only)

- [ ] Manual risks preserved:
  - `externalConsumersNotScanned` for package-internal
  - Any other scoped blocker → unsupported

- [ ] Write tests:
  - Application mode → SAFE finding
  - Package-internal mode → HIGH finding with manual risk
  - Package mode → unsupported
  - Scoped blocker present → unsupported
  - No readiness entry → unsupported (existing Stage 1 behavior)
  - ActionCapability delegates to l10n capability for l10n nodes

- [ ] Commit:
  ```sh
  git add lib/src/adapters/l10n/l10n_action_descriptor.dart \
          lib/src/adapters/l10n/l10n_action_capability.dart \
          lib/src/core/confidence/action_capability.dart \
          test/adapters/l10n/l10n_action_descriptor_test.dart \
          test/adapters/l10n/l10n_action_capability_test.dart \
          test/core/confidence/action_capability_test.dart
  git commit -m "feat(l10n): add action descriptor and capability with confidence rules"
  ```

---

### Task 9: L10n static readiness resolver implementation

**Goal:** Implement concrete l10n resolver performing bounded static work.

**Files to create:**
- `lib/src/adapters/l10n/l10n_static_readiness_resolver.dart`
- `test/adapters/l10n/l10n_static_readiness_resolver_test.dart`

**Requirements:**

- [ ] Implement `L10nStaticReadinessResolver`:
  ```dart
  final class L10nStaticReadinessResolver 
      implements StaticActionReadinessResolver {
    
    @override
    Future<ActionReadinessIndex> resolve({
      required ReachabilityGraph graph,
      required ProjectContext project,
      required GraphIntegrityReport integrity,
    }) async {
      // 1. Load strict L10nGenerationConfig (from action_readiness)
      // 2. Find all l10n nodes in graph
      // 3. For each family:
      //    - Check ownership (project-owned paths)
      //    - Check blockers (graph integrity, scoped blockers)
      //    - Compute deterministic inverse (ARB edit)
      //    - Enumerate footprint (ARB files + generated outputs)
      //    - Determine external consumer exposure
      // 4. Return index keyed by node ID
      // Must perform NO Flutter execution, NO staging
    }
  }
  ```

- [ ] Static checks only:
  - Strict config loading (reuse `L10nGenerationConfig.load`)
  - Family/input/output ownership verification
  - Blocker projection from graph
  - Deterministic inverse proof (ARB byte-edit proven in Stage 1)
  - Footprint enumeration (ARB files + expected gen-l10n outputs from config)

- [ ] Adapter ownership verification:
  - Core verifies `adapterId == 'l10n'` and `nodeKind == NodeKind.localizationKey`
  - Custom adapters cannot gain authority by copying metadata

- [ ] External consumer exposure:
  - Application mode: false (closed world)
  - Package-internal mode: true if package has external dependents
  - Package mode: true (open world, scan-only)

- [ ] Write tests:
  - Application project with complete closure → entries created
  - Package-internal project → entries with external exposure
  - Package mode → no entries (scan-only)
  - Scoped blocker present → no entry for blocked nodes
  - Malformed config → no entries (rejection at preflight)
  - Multiple families → separate entries per family
  - Resolver performs no Flutter execution (mock filesystem only)

- [ ] Commit:
  ```sh
  git add lib/src/adapters/l10n/l10n_static_readiness_resolver.dart \
          test/adapters/l10n/l10n_static_readiness_resolver_test.dart
  git commit -m "feat(l10n): implement static action readiness resolver"
  ```

---

### Task 10: Quarantine V3 transaction support

**Goal:** Extend `QuarantineManager` to support journal → install → verify → commit/rollback workflow.

**Files to modify:**
- `lib/src/quarantine/quarantine_manager.dart`
- `lib/src/quarantine/quarantine_transaction.dart`
- `lib/src/quarantine/quarantine_manifest.dart`
- `test/quarantine/quarantine_manager_test.dart`
- `test/quarantine/quarantine_transaction_test.dart`

**Requirements:**

- [ ] Extend `QuarantineTransaction` to support `absent` before-state:
  ```dart
  enum FileBeforeState {
    existing, // has journaled bytes/mode
    absent,   // path did not exist before transaction
  }
  
  final class QuarantineFileEntry {
    final String relativePath;
    final FileBeforeState beforeState;
    final ImmutableBytes? beforeBytes; // null when absent
    final String? beforeHash;
    final int? beforeMode;
    final ImmutableBytes afterBytes;
    final String afterHash;
    final int afterMode;
  }
  ```

- [ ] Update `QuarantineManager.beginTransaction()` to accept family-level logical IDs:
  ```dart
  Future<QuarantineTransaction> beginTransaction({
    required Set<String> logicalFindingIds,
    required String transactionKind, // 'v3-l10n-family'
  })
  ```

- [ ] Implement journal phase:
  ```dart
  Future<void> journalFile({
    required String relativePath,
    required Directory projectRoot,
  }) async {
    // 1. Check if file exists
    // 2. If exists: read bytes, compute hash, get mode
    // 3. Store as 'existing' with bytes/hash/mode
    // 4. If absent: store as 'absent'
  }
  ```

- [ ] Implement install phase (candidate bytes without regeneration):
  ```dart
  Future<void> installCandidateBytes({
    required String relativePath,
    required ImmutableBytes candidateBytes,
    required int mode,
  })
  ```

- [ ] Implement commit phase:
  ```dart
  Future<void> commit() async {
    // 1. Persist manifest with logical finding IDs
    // 2. Mark transaction complete
    // 3. Release lock
  }
  ```

- [ ] Implement rollback phase:
  ```dart
  Future<void> rollback() async {
    // 1. For each entry:
    //    - If beforeState == existing: restore bytes/mode
    //    - If beforeState == absent: delete file
    // 2. Verify restoration (hash check)
    // 3. Remove manifest if transaction never committed
    // 4. Release lock
  }
  ```

- [ ] All-or-nothing guarantee: rollback restores every file or enters recovery state.

- [ ] Write tests:
  - Journal existing file → restore on rollback
  - Journal absent file, install candidate → delete on rollback
  - Multiple files journaled → all restored on rollback
  - Commit successful → manifest persisted
  - Rollback after commit → no-op (already committed)
  - Hash drift during transaction → rollback
  - Unconfirmed process termination → recovery state

- [ ] Commit:
  ```sh
  git add lib/src/quarantine/quarantine_manager.dart \
          lib/src/quarantine/quarantine_transaction.dart \
          lib/src/quarantine/quarantine_manifest.dart \
          test/quarantine/quarantine_manager_test.dart \
          test/quarantine/quarantine_transaction_test.dart
  git commit -m "feat(quarantine): add V3 transaction support with journal/install/rollback"
  ```

---

### Task 11: RemovalPlanner l10n batch recognition

**Goal:** Update `RemovalPlanner` to recognize and group l10n family-level batches.

**Files to modify:**
- `lib/src/apply/removal_planner.dart`
- `test/apply/removal_planner_test.dart`

**Requirements:**

- [ ] Extend `RemovalPlanner.plan()` to recognize l10n findings with family-level descriptors:
  ```dart
  // When finding has L10nActionDescriptor:
  // 1. Group by familyId
  // 2. Each family becomes one batch
  // 3. Batch includes all findings for that family
  ```

- [ ] Create `L10nFamilyRemovalPlan`:
  ```dart
  final class L10nFamilyRemovalPlan extends RemovalPlan {
    final String familyId;
    final Set<Finding> findings;
    final L10nRemovalBatch batch;
    
    @override
    MutationFootprint get footprint => batch.footprint;
  }
  ```

- [ ] Planner groups findings by family, runs fresh preflight per family, builds batch.

- [ ] Validation:
  - All findings in batch must be from same family
  - All findings must be l10n localization keys
  - Batch must be fresh (preflight just ran)

- [ ] Write tests:
  - Single l10n finding → one family plan
  - Multiple findings same family → grouped into one plan
  - Multiple findings different families → separate plans
  - Mixed l10n + non-l10n findings → separate plans
  - Fresh preflight runs for each family before planning

- [ ] Commit:
  ```sh
  git add lib/src/apply/removal_planner.dart \
          test/apply/removal_planner_test.dart
  git commit -m "feat(apply): add l10n family batch recognition to RemovalPlanner"
  ```

---

### Task 12: FindingActionBuilder l10n batch execution

**Goal:** Build l10n removal actions from batch, integrate with quarantine workflow.

**Files to modify:**
- `lib/src/apply/finding_action_builder.dart`
- `test/apply/finding_action_builder_test.dart`

**Requirements:**

- [ ] Extend `FindingActionBuilder` to handle `L10nFamilyRemovalPlan`:
  ```dart
  Future<ActionResult> executeL10nFamilyRemoval({
    required L10nFamilyRemovalPlan plan,
    required QuarantineManager quarantine,
    required Directory projectRoot,
  }) async {
    // 1. Begin V3 quarantine transaction
    // 2. Journal all ARB files
    // 3. Journal all generated output files (or mark absent)
    // 4. Install ARB candidate bytes
    // 5. Install generated output candidate bytes
    // 6. Run verification policy (no-resolution)
    // 7. If verification passes: commit transaction
    // 8. If verification fails: rollback transaction
    // 9. Return result with logical finding outcomes
  }
  ```

- [ ] Verification step runs:
  - `flutter analyze --no-pub --fatal-infos`
  - `flutter test --no-pub`
  - Both must succeed for commit

- [ ] Failure handling:
  - Verification failure → rollback, report failure
  - Hash drift detected → rollback, report drift
  - Process termination → rollback, enter recovery

- [ ] Success accounting:
  - Per logical finding ID (not per physical file)
  - All findings in batch succeed or fail together

- [ ] Write tests:
  - Successful family removal (journal → install → verify → commit)
  - Verification failure → rollback
  - Hash drift during transaction → rollback
  - Multiple families → independent transactions
  - Rollback verification (bytes restored exactly)

- [ ] Commit:
  ```sh
  git add lib/src/apply/finding_action_builder.dart \
          test/apply/finding_action_builder_test.dart
  git commit -m "feat(apply): implement l10n family removal action execution"
  ```

---

### Task 13: CLI apply command integration

**Goal:** Enable `apply` command to handle l10n family-level actions.

**Files to modify:**
- `lib/src/cli/commands/apply_command.dart`
- `test/cli/commands/apply_command_test.dart`

**Requirements:**

- [ ] Update `ApplyCommand` to recognize l10n actionable findings in scan results.

- [ ] Display l10n findings with family context:
  ```
  Found 3 safe l10n removals in family 'app_localizations':
    - unused_greeting (lib/l10n/app_en.arb)
    - unused_farewell (lib/l10n/app_en.arb)
    - unused_title (lib/l10n/app_en.arb)
  
  This will edit 3 ARB files and regenerate 2 Dart files.
  ```

- [ ] Prompt for confirmation showing family-level scope.

- [ ] Execute l10n family removals through updated `RemovalPlanner` and `FindingActionBuilder`.

- [ ] Report outcomes per family:
  ```
  ✓ Applied l10n family 'app_localizations': 3 keys removed
  ```

- [ ] Error reporting:
  ```
  ✗ Failed to apply l10n family 'app_localizations': verification failed
    All changes rolled back.
  ```

- [ ] Write tests:
  - Apply command with l10n findings
  - Confirmation prompt displays family context
  - Successful application reports outcomes
  - Failed application reports rollback
  - Mixed l10n + non-l10n findings handled separately

- [ ] Commit:
  ```sh
  git add lib/src/cli/commands/apply_command.dart \
          test/cli/commands/apply_command_test.dart
  git commit -m "feat(cli): integrate l10n family removal into apply command"
  ```

---

### Task 14: CLI finding formatter l10n display

**Goal:** Update finding formatter to display l10n actionable findings with family context.

**Files to modify:**
- `lib/src/cli/formatters/finding_formatter.dart`
- `test/cli/formatters/finding_formatter_test.dart`

**Requirements:**

- [ ] Update `FindingFormatter` to recognize l10n findings with action descriptors.

- [ ] Format l10n findings grouped by family:
  ```
  L10n Family: app_localizations
  ├─ unused_greeting (SAFE)
  │  lib/l10n/app_en.arb:15
  │  Action: Remove from 3 ARB files + regenerate 2 Dart files
  ├─ unused_farewell (SAFE)
  │  lib/l10n/app_en.arb:42
  │  Action: Remove from 3 ARB files + regenerate 2 Dart files
  └─ unused_title (SAFE)
     lib/l10n/app_en.arb:8
     Action: Remove from 3 ARB files + regenerate 2 Dart files
  
  Family-level removal: 3 keys, 3 ARB files, 2 generated files
  ```

- [ ] Show mutation footprint for each family (file count, paths).

- [ ] Display confidence level and manual risks:
  - SAFE (application mode)
  - HIGH + externalConsumersNotScanned (package-internal mode)

- [ ] Write tests:
  - Single l10n finding formatted
  - Multiple findings same family grouped
  - Multiple families displayed separately
  - Footprint displayed correctly
  - Confidence + manual risks shown

- [ ] Commit:
  ```sh
  git add lib/src/cli/formatters/finding_formatter.dart \
          test/cli/formatters/finding_formatter_test.dart
  git commit -m "feat(cli): update finding formatter for l10n family-level display"
  ```

---

### Task 15: End-to-end integration tests

**Goal:** Prove complete apply workflow for l10n family removals.

**Files to create:**
- `test/integration/l10n_apply_integration_test.dart`
- `test/integration/l10n_rollback_integration_test.dart`

**Requirements:**

- [ ] Create `l10n_apply_integration_test.dart` covering:
  ```dart
  test('complete l10n family removal workflow', () async {
    // 1. Create test project with l10n configuration
    // 2. Add unused localization keys
    // 3. Run analyzer (ProjectAnalyzer with L10nStaticReadinessResolver)
    // 4. Verify l10n findings are SAFE (not REVIEW)
    // 5. Run apply command
    // 6. Verify ARB files edited correctly
    // 7. Verify generated Dart files updated
    // 8. Verify quarantine manifest created
    // 9. Verify project still builds and tests pass
  });
  
  test('multiple families removal', () async {
    // Same workflow with multiple families
    // Verify independent transactions per family
  });
  
  test('mixed l10n and non-l10n removals', () async {
    // Verify l10n and non-l10n findings handled separately
  });
  ```

- [ ] Create `l10n_rollback_integration_test.dart` covering:
  ```dart
  test('rollback after verification failure', () async {
    // 1. Create project, run apply
    // 2. Inject verification failure
    // 3. Verify all changes rolled back
    // 4. Verify original bytes restored exactly
    // 5. Verify project state unchanged
  });
  
  test('rollback after hash drift', () async {
    // 1. Begin transaction
    // 2. External process modifies ARB file
    // 3. Detect drift, trigger rollback
    // 4. Verify rollback successful
  });
  
  test('recovery after unconfirmed termination', () async {
    // 1. Begin transaction
    // 2. Simulate process kill
    // 3. Verify recovery state entered
    // 4. Verify manifest marks recovery needed
  });
  ```

- [ ] Use real Flutter SDK (gated behind availability check).

- [ ] Use disposable system-temp projects for safety.

- [ ] Cleanup after tests (quarantine transaction cleanup).

- [ ] Commit:
  ```sh
  git add test/integration/l10n_apply_integration_test.dart \
          test/integration/l10n_rollback_integration_test.dart
  git commit -m "test: add end-to-end l10n apply and rollback integration tests"
  ```

---

### Task 16: Public boundary verification and documentation

**Goal:** Verify Promotion changes don't break existing behavior and document the new capabilities.

**Files to create:**
- `test/adapters/l10n/promotion_public_boundary_test.dart`
- `docs/l10n_removal_guide.md`

**Files to modify:**
- `CHANGELOG.md`
- `README.md`

**Requirements:**

- [ ] Create `promotion_public_boundary_test.dart`:
  ```dart
  test('l10n findings become actionable in application mode', () async {
    // Verify SAFE confidence for application projects
  });
  
  test('l10n findings remain HIGH in package-internal mode', () async {
    // Verify HIGH + manual risk for package-internal
  });
  
  test('l10n findings remain scan-only in package mode', () async {
    // Verify no action proposed in package mode
  });
  
  test('non-l10n findings unchanged', () async {
    // Verify existing adapters not affected
  });
  
  test('backward compatibility without resolver', () async {
    // ProjectAnalyzer without resolver → existing behavior
  });
  ```

- [ ] Create `docs/l10n_removal_guide.md`:
  ```markdown
  # L10n Removal Guide
  
  ## Overview
  Flutter Pruner can now safely remove unused l10n keys...
  
  ## Requirements
  - Application or package-internal mode
  - Complete `l10n.yaml` configuration
  - Standard `gen-l10n` setup
  
  ## How it works
  1. Scan identifies unused keys
  2. Static analysis determines family-level actionability
  3. Apply runs fresh staging pipeline
  4. Quarantine manages atomic transaction
  5. Rollback restores on failure
  
  ## Confidence levels
  - Application mode: SAFE
  - Package-internal mode: HIGH (requires acknowledgement)
  - Package mode: scan-only
  
  ## Limitations
  - Replacement-only (no creation/deletion yet)
  - No-resolution verification required
  - Family-level atomic transactions
  ```

- [ ] Update `CHANGELOG.md`:
  ```markdown
  ## [Unreleased]
  
  ### Added
  - L10n removal support for application and package-internal modes
  - Family-level atomic transactions with rollback
  - Static action readiness resolution
  - Explicit no-resolution verification policy
  - Quarantine V3 transaction support
  
  ### Changed
  - L10n findings now actionable (SAFE/HIGH) in eligible projects
  - ActionCapability delegates to adapter-specific logic
  - RemovalPlanner handles family-level batches
  ```

- [ ] Update `README.md` to mention l10n support.

- [ ] Run full test suite to verify no regressions.

- [ ] Commit:
  ```sh
  git add test/adapters/l10n/promotion_public_boundary_test.dart \
          docs/l10n_removal_guide.md \
          CHANGELOG.md \
          README.md
  git commit -m "docs: add l10n removal guide and verify public boundaries"
  ```

---

## Success Criteria

- [ ] All 16 tasks completed with passing tests
- [ ] L10n findings report SAFE confidence in application mode
- [ ] L10n findings report HIGH confidence in package-internal mode with manual risk
- [ ] L10n findings remain scan-only in package mode
- [ ] Apply command successfully removes l10n keys through family-level transactions
- [ ] Quarantine transaction rolls back on verification failure
- [ ] Original bytes restored exactly on rollback
- [ ] No regression in existing adapters or apply workflows
- [ ] Integration tests prove end-to-end workflow
- [ ] Documentation complete and accurate

## Post-Stage-2 Validation

After Stage 2 completion, run:

1. Full test suite: `dart test`
2. Accuracy benchmark on GSY corpus (if applicable)
3. Manual smoke test on real project with l10n configuration
4. Verify rollback behavior with injected failures
5. Verify no-resolution verification policy enforced

Report:
- All task commit SHAs
- Test results (passed/total)
- Integration test outcomes
- Any retained staging residue
- Documentation completeness

Request user approval before releasing or tagging.

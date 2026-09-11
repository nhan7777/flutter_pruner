# V3 Stage 2: L10n Removal Implementation

## Overview

Stage 2 promotes l10n localization key removal from REVIEW-only (Stage 1) to fully automated removal with quarantine protection. This document describes the implementation completed in September 2026.

## Core Concepts

### Action Readiness Architecture

**ActionReadinessIndex** (`lib/src/core/confidence/promotion_index.dart`)
- Immutable index mapping node IDs to readiness entries
- Built by adapters during analysis phase
- Consumed by FindingGenerator and RemovalPlanner
- Single source of truth for which findings are action-ready

**ActionReadinessEntry** - Per-node metadata containing:
- `adapterId`: Which adapter owns this action (e.g., 'l10n')
- `familyId`: Logical grouping for atomic units (e.g., 'app_localizations')
- `mutationFootprint`: Exact logical findings + physical paths affected
- `inverseKind`: How to undo the mutation (quarantineJournal, regeneration)
- `riskScope`: Classification (boundedSingle, boundedFamily, openEnded)

**MutationFootprint** (`lib/src/core/confidence/mutation_footprint.dart`)
- `findingIds`: Logical finding IDs being addressed
- `physicalPaths`: Files that will be modified
- `riskScope`: Action risk scope classification
- `familyId`: Optional family identifier for family-level actions

**ActionRiskScope** (`lib/src/core/confidence/action_risk_scope.dart`)
- `boundedSingle`: Single file/declaration (existing narrow actions)
- `boundedFamily`: Family-level proven actions (l10n ARB family + generated outputs)
- `openEnded`: Broad actions (existing broadRemovalScope behavior)

### L10n Removal Pipeline

**1. Evidence Collection** (`L10nEvidencePipeline`)
- Captures pre-mutation state of l10n family
- Creates isolated staging directory with ARB files
- Takes snapshot of all analyzer-visible sources
- Validates no concurrent mutations during capture

**2. Mutation Execution** (`L10nMutationExecutor`)
- Removes keys from ARB files using exact JSON manipulation
- Regenerates Dart output via `flutter gen-l10n`
- Protected by quarantine transaction (snapshot + rollback capability)
- Atomic per-family: all keys in family removed together

**3. Verification** (`L10nStageVerifier`)
- Compares baseline vs candidate generated outputs
- Validates only selected keys removed, retained keys unchanged
- Checks generated member signatures match expectations
- Rejects if any drift detected in protected paths

**4. Integration** (`apply_command.dart`)
- Groups findings by familyId into atomic units
- Executes one family at a time via L10nMutationExecutor
- Runs verification after each family
- Commits on success, rolls back on failure

## File Structure

### Core Infrastructure
```
lib/src/core/confidence/
  ├── promotion_index.dart          # ActionReadinessIndex + Entry + InverseKind
  ├── action_risk_scope.dart        # Risk scope classification enum
  └── mutation_footprint.dart       # Logical + physical mutation scope
```

### L10n Action Readiness
```
lib/src/adapters/l10n/action_readiness/
  ├── l10n_evidence_pipeline.dart   # Evidence collection orchestrator
  ├── l10n_family_preflight.dart    # Pre-mutation validation + snapshot
  ├── l10n_stage_materializer.dart  # Staging directory + generator runner
  ├── l10n_stage_verifier.dart      # Post-mutation verification
  ├── l10n_generated_member_inspector.dart  # Signature verification
  ├── l10n_mutation_executor.dart   # Main mutation + verification coordinator
  └── l10n_action_readiness_resolver.dart   # Builds ActionReadinessIndex
```

### Integration Points
```
lib/src/adapters/l10n/
  └── l10n_adapter.dart            # Stage 2 export (internal use only)

lib/src/analysis/
  └── project_analyzer.dart        # Calls ActionReadinessResolver after adapters

lib/src/apply/
  ├── removal_planner.dart         # Groups findings by familyId
  └── finding_action_builder.dart  # Uses ActionReadinessIndex

lib/src/cli/commands/
  └── apply_command.dart           # L10nMutationExecutor integration
```

## Public API Boundaries

### Stage 1 (Current Public API)
- ✅ L10n findings remain REVIEW-only (no proposedAction)
- ✅ ActionCapability.forFinding() returns unsupported for l10n
- ✅ No action_readiness exports in `lib/flutter_pruner.dart`

### Stage 2 (Internal Implementation)
- ⚠️ All action_readiness code is **internal implementation**
- ⚠️ L10nMutationExecutor is CLI-only, not exposed to adapters
- ⚠️ ActionReadinessIndex flows through analysis but not in public API

**Design principle**: Stage 2 adds automated removal capability internally without changing the public adapter contract. External adapter authors still see l10n as REVIEW-only.

## Testing

### Test Coverage
- **811 tests** in `test/adapters/l10n/` covering:
  - Evidence pipeline: 27 tests (state machine, error folding, cleanup)
  - Family preflight: 127 tests (ARB validation, package projection)
  - Stage materializer: 53 tests (staging setup, generator invocation)
  - Stage verifier: 198 tests (drift detection, signature validation)
  - Generated inspector: 48 tests (member signature extraction)
  - Executor integration: Full pipeline orchestration

### Test Organization
```
test/adapters/l10n/action_readiness/
  ├── l10n_evidence_pipeline_test.dart       # Pipeline orchestration
  ├── l10n_family_preflight_test.dart        # Pre-mutation validation
  ├── l10n_stage_materializer_test.dart      # Staging + generation
  ├── l10n_stage_verifier_test.dart          # Post-mutation checks
  ├── l10n_generated_member_inspector_test.dart  # Signature parsing
  ├── stage1_public_boundary_test.dart       # Public API verification
  └── ...
```

### Public Boundary Verification
`stage1_public_boundary_test.dart` enforces:
1. L10n findings have `proposedAction == null`
2. L10n nodes return `ActionCapability.supported == false`
3. No `action_readiness` imports in public production paths
4. `lib/flutter_pruner.dart` does not export action_readiness
5. No staging directories created during normal scan

## Usage

### CLI Workflow
```bash
# 1. Scan project (Stage 1 - finds l10n keys)
flutter_pruner scan

# 2. Apply removal (Stage 2 - removes keys with verification)
flutter_pruner apply --finding-id l10n:app:unused_key_1

# 3. Rollback if needed
flutter_pruner rollback --transaction-id <txn>
```

### Internal Flow
1. **Analysis**: L10nAdapter generates l10n findings, L10nActionReadinessResolver builds ActionReadinessIndex
2. **Planning**: RemovalPlanner groups findings by familyId into atomic units
3. **Execution**: ApplyCommand calls L10nMutationExecutor for each family
4. **Verification**: L10nStageVerifier checks generated output correctness
5. **Commit/Rollback**: QuarantineManager commits or restores based on verification

## Key Design Decisions

### Family-Level Atomicity
**Decision**: Remove all keys in a family together, not individually.

**Rationale**:
- ARB files don't support partial edits (would need custom parser)
- `flutter gen-l10n` regenerates entire output class
- Verification requires comparing full generated member set
- Simpler to reason about: one family = one transaction

### Quarantine Protection
**Decision**: Use existing QuarantineManager for all file mutations.

**Rationale**:
- Proven rollback mechanism already in place
- Snapshot before mutation, restore on verification failure
- Consistent with existing apply command safety model

### No Public API Changes
**Decision**: Keep action_readiness internal, don't expose to adapters.

**Rationale**:
- Stage 2 is enhancement to CLI apply command, not adapter contract change
- External adapters don't need to know about action readiness
- Simpler migration path: Stage 1 → Stage 2 without breaking changes

### Deterministic Inverse via Regeneration
**Decision**: L10n uses `DeterministicInverseKind.regeneration` not `quarantineJournal`.

**Rationale**:
- Generated Dart files are reproducible from ARB sources
- Verification explicitly checks regeneration correctness
- Quarantine still provides rollback for ARB mutations

## Performance Characteristics

### Staging Overhead
- **One-time setup per family**: Create temp dir, copy ARB files, snapshot analyzer sources
- **Typical cost**: 50-200ms depending on project size
- **Amortized**: Multiple keys in same family share staging cost

### Verification Cost
- **Baseline generation**: Run `flutter gen-l10n` on original ARBs (~50ms)
- **Candidate generation**: Run `flutter gen-l10n` on mutated ARBs (~50ms)
- **Comparison**: Parse and diff generated Dart (~10-30ms)
- **Total per family**: ~150-300ms

### Memory
- **Peak usage**: ~2.5GB for 400+ case benchmark (Gitjournal)
- **Staging storage**: Temporary, cleaned up after verification

## Migration Path

### Stage 1 → Stage 2 (Current)
- [x] Core data structures (ActionReadinessIndex, MutationFootprint, ActionRiskScope)
- [x] L10n evidence pipeline (capture, materialize, verify)
- [x] L10n mutation executor (remove + regenerate)
- [x] CLI integration (RemovalPlanner grouping, ApplyCommand execution)
- [x] 811 tests covering full pipeline

### Future Stages
- **Stage 3**: Promote to public adapter API (expose ActionReadinessIndex)
- **Stage 4**: Support other generated code families (JSON serialization, etc.)
- **Stage 5**: Concurrent family execution (if profiling shows benefit)

## Limitations & Future Work

### Current Limitations
1. **Family-level only**: Cannot remove individual keys, must remove all selected keys in family together
2. **Sequential execution**: One family at a time (could parallelize if needed)
3. **CLI-only**: Not exposed to programmatic API consumers

### Potential Enhancements
1. **Parallel family execution**: Run multiple families concurrently if no shared ARB files
2. **Incremental key removal**: Support removing keys one-by-one if demand exists
3. **Public API exposure**: Make ActionReadinessIndex available to adapter authors
4. **Generalize to other generated code**: Apply same pattern to JSON, GraphQL, etc.

## References

- Original V3 Shared View investigation: `docs/v3_shared_view_investigation.md`
- Stage 2 implementation plan: `$CLAUDE_JOB_DIR/tmp/v3_stage2_implementation_plan.md`
- Accuracy benchmark fixtures: `benchmark/accuracy/corpus/`

---

**Last updated**: September 3, 2026  
**Implementation status**: ✅ Complete (Tasks 1-16)  
**Test status**: ✅ 812/812 tests passing
